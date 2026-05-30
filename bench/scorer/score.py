"""Combine the gate and judge into per-case verdicts and per-arm aggregates.

A case-run is DETECTED iff at least one finding is confirmed by the
location-aware judge (same bug AND same file). The file-overlap gate is carried
as logged evidence only — it does NOT gate the verdict, because an exact-path
gate has a model-dependent false-negative rate that would bias a cross-model
comparison. ERROR/SKIPPED runs are reported separately and excluded from the rate
denominator. Per arm we report hit-rate, detected@≥1, detected@majority
(k=3 → ≥2/3), and a Wilson score interval; the bugsweep−baseline delta is
paired over cases both arms COMPLETED, with each arm's ERROR/SKIPPED counts
surfaced beside it. Below the post-cutoff floor (<6 completed) the arm status
is "inconclusive" rather than a rate. Calibration rows round-trip through CSV
and a human ``human_verdict`` (non-blank) overrides the judge's.
"""

from __future__ import annotations

import csv
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence, Tuple

from bench.scorer.judge import Judgement
from bench.scorer.localize import GateResult

DETECTED = "DETECTED"
NOT_DETECTED = "NOT_DETECTED"
ERROR = "ERROR"
SKIPPED = "SKIPPED"

COMPLETED_VERDICTS = frozenset({DETECTED, NOT_DETECTED})
DEFAULT_WILSON_Z = 1.96
POST_CUTOFF_FLOOR = 6
MAJORITY_NUMERATOR = 2  # majority of k=3 runs.
MAJORITY_DENOMINATOR = 3

CALIBRATION_COLUMNS = (
    "case_id",
    "run",
    "arm",
    "judge_verdict",
    "judge_confidence",
    "human_verdict",
    "override_reason",
)

GateJudgePair = Tuple[GateResult, Judgement]


@dataclass(frozen=True)
class CaseRunVerdict:
    """One arm's verdict for one case on one run."""

    case_id: str
    run: int
    arm: str
    verdict: str
    post_cutoff: bool


@dataclass(frozen=True)
class ArmAggregate:
    """Flat run-level aggregate for an arm (ERROR/SKIPPED excluded from rate)."""

    completed: int
    hits: int
    hit_rate: float
    error_count: int
    skipped_count: int
    wilson_low: float
    wilson_high: float


@dataclass(frozen=True)
class ArmSummary:
    """Per-case roll-up for an arm: detected@≥1, detected@majority, status."""

    detected_at_1: int
    detected_at_majority: int
    completed_post_cutoff_cases: int
    status: str


@dataclass(frozen=True)
class PairedDelta:
    """bugsweep−baseline delta over cases both arms completed, with exclusions."""

    paired_n: int
    delta: float
    bugsweep_error_count: int
    baseline_error_count: int
    bugsweep_skipped_count: int
    baseline_skipped_count: int


@dataclass(frozen=True)
class CalibrationRow:
    """One row of the human-calibration CSV."""

    case_id: str
    run: int
    arm: str
    judge_verdict: str
    judge_confidence: int
    human_verdict: str
    override_reason: str


@dataclass(frozen=True)
class ResolvedVerdict:
    """A calibration row after human overrides are applied."""

    case_id: str
    run: int
    arm: str
    verdict: str
    overridden: bool


def score_case_run(pairs: Sequence[GateJudgePair]) -> str:
    """Return DETECTED iff some finding's JUDGE matches the ground-truth bug.

    Localization is folded into the judge (same bug AND same file); the
    file-overlap ``gate_result`` is carried only as logged evidence and does NOT
    gate the verdict. An exact-path gate has a model-dependent false-negative
    rate (models write paths inconsistently), which would bias a cross-model
    comparison — so the judge, not the path string, decides.
    """
    for _gate_result, judgement in pairs:
        if judgement.match:
            return DETECTED
    return NOT_DETECTED


def wilson_interval(
    hits: int, n: int, z: float = DEFAULT_WILSON_Z
) -> tuple[float, float]:
    """Wilson score interval for a binomial proportion; ``n == 0`` → ``(0.0, 0.0)``."""
    if n == 0:
        return (0.0, 0.0)
    p = hits / n
    denom = 1.0 + z * z / n
    center = (p + z * z / (2.0 * n)) / denom
    margin = (z * math.sqrt(p * (1.0 - p) / n + z * z / (4.0 * n * n))) / denom
    return (center - margin, center + margin)


def aggregate_arm(
    verdicts: Iterable[CaseRunVerdict], z: float = DEFAULT_WILSON_Z
) -> ArmAggregate:
    """Flat run-level aggregate; ERROR/SKIPPED are counted but excluded from the rate."""
    items = list(verdicts)
    completed = [v for v in items if v.verdict in COMPLETED_VERDICTS]
    hits = sum(1 for v in completed if v.verdict == DETECTED)
    n = len(completed)
    hit_rate = hits / n if n else 0.0
    low, high = wilson_interval(hits, n, z)
    return ArmAggregate(
        completed=n,
        hits=hits,
        hit_rate=hit_rate,
        error_count=sum(1 for v in items if v.verdict == ERROR),
        skipped_count=sum(1 for v in items if v.verdict == SKIPPED),
        wilson_low=low,
        wilson_high=high,
    )


def summarize_arm(verdicts: Iterable[CaseRunVerdict]) -> ArmSummary:
    """Per-case roll-up: detected@≥1, detected@majority, and the inconclusive floor."""
    by_case = _group_completed_by_case(verdicts)
    detected_at_1 = 0
    detected_at_majority = 0
    post_cutoff_completed = 0
    for runs in by_case.values():
        post_cutoff_completed += 1 if any(v.post_cutoff for v in runs) else 0
        detections = sum(1 for v in runs if v.verdict == DETECTED)
        if detections >= 1:
            detected_at_1 += 1
        if detections * MAJORITY_DENOMINATOR >= MAJORITY_NUMERATOR * len(runs):
            detected_at_majority += 1
    status = (
        "inconclusive" if post_cutoff_completed < POST_CUTOFF_FLOOR else "conclusive"
    )
    return ArmSummary(
        detected_at_1=detected_at_1,
        detected_at_majority=detected_at_majority,
        completed_post_cutoff_cases=post_cutoff_completed,
        status=status,
    )


def paired_delta(
    bugsweep: Sequence[CaseRunVerdict],
    baseline: Sequence[CaseRunVerdict],
) -> PairedDelta:
    """Delta of detected@≥1 over cases both arms completed; exclusions reported beside."""
    bugsweep_cases = _group_completed_by_case(bugsweep)
    baseline_cases = _group_completed_by_case(baseline)
    shared = sorted(set(bugsweep_cases) & set(baseline_cases))
    bugsweep_rate = _detected_at_1_rate(bugsweep_cases, shared)
    baseline_rate = _detected_at_1_rate(baseline_cases, shared)
    return PairedDelta(
        paired_n=len(shared),
        delta=bugsweep_rate - baseline_rate,
        bugsweep_error_count=_count(bugsweep, ERROR),
        baseline_error_count=_count(baseline, ERROR),
        bugsweep_skipped_count=_count(bugsweep, SKIPPED),
        baseline_skipped_count=_count(baseline, SKIPPED),
    )


def write_calibration(rows: Iterable[CalibrationRow], path: Path) -> None:
    """Write calibration rows to ``path`` with the locked column order."""
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(CALIBRATION_COLUMNS))
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    "case_id": row.case_id,
                    "run": row.run,
                    "arm": row.arm,
                    "judge_verdict": row.judge_verdict,
                    "judge_confidence": row.judge_confidence,
                    "human_verdict": row.human_verdict,
                    "override_reason": row.override_reason,
                }
            )


def apply_overrides(rows: Iterable[CalibrationRow]) -> list[ResolvedVerdict]:
    """Resolve each row: a non-blank ``human_verdict`` wins; blank falls through."""
    resolved: list[ResolvedVerdict] = []
    for row in rows:
        human = row.human_verdict.strip()
        overridden = bool(human)
        verdict = human if overridden else row.judge_verdict
        resolved.append(
            ResolvedVerdict(
                case_id=row.case_id,
                run=row.run,
                arm=row.arm,
                verdict=verdict,
                overridden=overridden,
            )
        )
    return resolved


def _group_completed_by_case(
    verdicts: Iterable[CaseRunVerdict],
) -> dict[str, list[CaseRunVerdict]]:
    grouped: dict[str, list[CaseRunVerdict]] = {}
    for verdict in verdicts:
        if verdict.verdict in COMPLETED_VERDICTS:
            grouped.setdefault(verdict.case_id, []).append(verdict)
    return grouped


def _detected_at_1_rate(
    by_case: dict[str, list[CaseRunVerdict]],
    case_ids: Sequence[str],
) -> float:
    if not case_ids:
        return 0.0
    detected = sum(
        1
        for case_id in case_ids
        if any(v.verdict == DETECTED for v in by_case[case_id])
    )
    return detected / len(case_ids)


def _count(verdicts: Iterable[CaseRunVerdict], verdict: str) -> int:
    return sum(1 for v in verdicts if v.verdict == verdict)
