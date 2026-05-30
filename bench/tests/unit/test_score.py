"""Tests for ``bench.scorer.score``.

This is the scorer core: it folds the file-overlap gate and the LLM judge into
a per-(case, run, arm) verdict, then aggregates per arm (hit-rate, detected@≥1,
detected@majority, Wilson CI) and pairs the two arms into a delta computed only
over cases both arms COMPLETED — surfacing each arm's ERROR/SKIPPED counts.
ERROR/SKIPPED are excluded from the rate denominator. Below the post-cutoff
floor (<6 completed) the result is "inconclusive". Calibration rows round-trip
through CSV, and ``apply_overrides`` lets a human verdict supersede the judge's.
"""

import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.judge import Judgement  # noqa: E402
from bench.scorer.localize import GateResult  # noqa: E402
from bench.scorer.score import (  # noqa: E402
    DETECTED,
    ERROR,
    NOT_DETECTED,
    SKIPPED,
    CaseRunVerdict,
    CalibrationRow,
    aggregate_arm,
    apply_overrides,
    paired_delta,
    score_case_run,
    summarize_arm,
    wilson_interval,
    write_calibration,
)

# --- score_case_run: DETECTED iff some finding's JUDGE matches. Localization is
# folded into the judge (same bug AND same file); the file-overlap gate is logged
# evidence, never a filter, so it must NOT gate the verdict. An exact-path gate
# has a model-dependent false-negative rate that would bias a cross-model run. ---


def _gate(passed: bool) -> GateResult:
    return GateResult(passed=passed, line_close=passed, category_match=passed)


def _judge(match: bool, confidence: int = 80) -> Judgement:
    return Judgement(
        match=match, confidence=confidence, reason="t", model="m", prompt_hash="h"
    )


def test_detected_when_a_finding_judge_matches() -> None:
    assert score_case_run([(_gate(True), _judge(True))]) == DETECTED


def test_not_detected_when_no_findings() -> None:
    assert score_case_run([]) == NOT_DETECTED


def test_not_detected_when_judge_rejects_despite_gate_pass() -> None:
    # the judge governs; a gate-pass with a judge rejection is NOT a detection.
    assert score_case_run([(_gate(True), _judge(False))]) == NOT_DETECTED


def test_detected_when_judge_matches_even_if_gate_fails() -> None:
    # the file-overlap gate is demoted to evidence: a judge match on a finding the
    # path-gate would have dropped (model wrote the path differently) still counts.
    # This is the cross-model validity fix.
    assert score_case_run([(_gate(False), _judge(True))]) == DETECTED


def test_not_detected_when_all_judges_reject() -> None:
    pairs = [(_gate(True), _judge(False)), (_gate(False), _judge(False))]
    assert score_case_run(pairs) == NOT_DETECTED


def test_detected_when_at_least_one_judge_matches() -> None:
    pairs = [(_gate(False), _judge(False)), (_gate(True), _judge(True))]
    assert score_case_run(pairs) == DETECTED


# --- wilson_interval: pin a well-known reference value ---


def test_wilson_known_value_n100_k50() -> None:
    low, high = wilson_interval(hits=50, n=100)
    assert round(low, 3) == 0.404
    assert round(high, 3) == 0.596


def test_wilson_all_hits() -> None:
    low, high = wilson_interval(hits=10, n=10)
    assert 0.0 < low < 1.0
    assert round(high, 3) == 1.0 or high <= 1.0


def test_wilson_zero_n_returns_zero_zero() -> None:
    assert wilson_interval(hits=0, n=0) == (0.0, 0.0)


# --- aggregate_arm: hit-rate, detected@>=1, detected@majority, exclusions ---


def _verdict(
    case_id: str, run: int, verdict: str, *, post_cutoff: bool = True
) -> CaseRunVerdict:
    return CaseRunVerdict(
        case_id=case_id,
        run=run,
        arm="bugsweep",
        verdict=verdict,
        post_cutoff=post_cutoff,
    )


def test_aggregate_all_pass() -> None:
    verdicts = [_verdict("c1", r, DETECTED) for r in (1, 2, 3)]
    agg = aggregate_arm(verdicts)
    assert agg.completed == 3
    assert agg.hits == 3
    assert agg.hit_rate == 1.0


def test_aggregate_all_fail() -> None:
    verdicts = [_verdict("c1", r, NOT_DETECTED) for r in (1, 2, 3)]
    agg = aggregate_arm(verdicts)
    assert agg.hits == 0
    assert agg.hit_rate == 0.0


def test_error_and_skipped_excluded_from_denominator() -> None:
    verdicts = [
        _verdict("c1", 1, DETECTED),
        _verdict("c2", 1, NOT_DETECTED),
        _verdict("c3", 1, ERROR),
        _verdict("c4", 1, SKIPPED),
    ]
    agg = aggregate_arm(verdicts)
    assert agg.completed == 2  # only DETECTED + NOT_DETECTED count
    assert agg.hits == 1
    assert agg.hit_rate == 0.5
    assert agg.error_count == 1
    assert agg.skipped_count == 1


# --- detected@>=1 and detected@majority over k=3 runs of one case ---


def test_detected_at_least_one() -> None:
    verdicts = [
        _verdict("c1", 1, NOT_DETECTED),
        _verdict("c1", 2, NOT_DETECTED),
        _verdict("c1", 3, DETECTED),
    ]
    summary = summarize_arm(verdicts)
    assert summary.detected_at_1 == 1
    assert summary.detected_at_majority == 0  # only 1 of 3 → not majority


def test_detected_at_majority_exact_tie_two_of_three() -> None:
    verdicts = [
        _verdict("c1", 1, DETECTED),
        _verdict("c1", 2, DETECTED),
        _verdict("c1", 3, NOT_DETECTED),
    ]
    summary = summarize_arm(verdicts)
    assert summary.detected_at_majority == 1  # 2 of 3 IS majority


def test_detected_at_majority_one_of_three_is_not_majority() -> None:
    verdicts = [
        _verdict("c1", 1, DETECTED),
        _verdict("c1", 2, NOT_DETECTED),
        _verdict("c1", 3, NOT_DETECTED),
    ]
    summary = summarize_arm(verdicts)
    assert summary.detected_at_majority == 0


# --- inconclusive floor: < 6 completed post-cutoff cases ---


def _completed_cases(n: int, post_cutoff: bool = True) -> list[CaseRunVerdict]:
    return [
        CaseRunVerdict(
            case_id=f"c{i}",
            run=1,
            arm="bugsweep",
            verdict=DETECTED,
            post_cutoff=post_cutoff,
        )
        for i in range(n)
    ]


def test_inconclusive_below_floor() -> None:
    summary = summarize_arm(_completed_cases(5))
    assert summary.status == "inconclusive"


def test_conclusive_at_floor() -> None:
    summary = summarize_arm(_completed_cases(6))
    assert summary.status != "inconclusive"


def test_pre_cutoff_completed_cases_do_not_count_toward_floor() -> None:
    # 5 post-cutoff + 3 pre-cutoff completed → still inconclusive (only 5 count).
    verdicts = _completed_cases(5, post_cutoff=True) + _completed_cases(
        3, post_cutoff=False
    )
    summary = summarize_arm(verdicts)
    assert summary.status == "inconclusive"


# --- paired delta over cases BOTH arms completed; per-arm error/skipped beside ---


def test_paired_delta_only_over_both_completed_with_asymmetric_errors() -> None:
    bugsweep = [
        _bs("c1", DETECTED),
        _bs("c2", DETECTED),
        _bs("c3", DETECTED),  # baseline ERRORed on c3 → excluded from pairing
    ]
    baseline = [
        _bl("c1", NOT_DETECTED),
        _bl("c2", DETECTED),
        _bl("c3", ERROR),
    ]
    result = paired_delta(bugsweep, baseline)
    # Paired set = {c1, c2}: bugsweep 2/2, baseline 1/2 → delta = 0.5.
    assert result.paired_n == 2
    assert round(result.delta, 3) == 0.5
    assert result.bugsweep_error_count == 0
    assert result.baseline_error_count == 1
    assert result.baseline_skipped_count == 0


def test_paired_delta_surfaces_both_arms_skipped_counts() -> None:
    bugsweep = [_bs("c1", DETECTED), _bs("c2", SKIPPED)]
    baseline = [_bl("c1", NOT_DETECTED), _bl("c2", DETECTED)]
    result = paired_delta(bugsweep, baseline)
    assert result.paired_n == 1  # only c1 completed in both arms
    assert result.bugsweep_skipped_count == 1


def test_paired_delta_no_shared_completed_cases_is_zero() -> None:
    # Arms completed disjoint cases → empty paired set → delta 0.0.
    bugsweep = [_bs("c1", DETECTED)]
    baseline = [_bl("c2", DETECTED)]
    result = paired_delta(bugsweep, baseline)
    assert result.paired_n == 0
    assert result.delta == 0.0


# --- calibration.csv writer + apply_overrides ---


def test_write_calibration_round_trips(tmp_path: Path) -> None:
    rows = [
        CalibrationRow(
            case_id="c1",
            run=1,
            arm="bugsweep",
            judge_verdict=DETECTED,
            judge_confidence=90,
            human_verdict="",
            override_reason="",
        )
    ]
    out = tmp_path / "calibration.csv"
    write_calibration(rows, out)
    with out.open(encoding="utf-8", newline="") as handle:
        read = list(csv.DictReader(handle))
    assert read[0]["case_id"] == "c1"
    assert read[0]["judge_verdict"] == DETECTED
    assert set(read[0].keys()) == {
        "case_id",
        "run",
        "arm",
        "judge_verdict",
        "judge_confidence",
        "human_verdict",
        "override_reason",
    }


def test_apply_overrides_blank_falls_through_to_judge() -> None:
    rows = [
        CalibrationRow(
            "c1", 1, "bugsweep", DETECTED, 90, human_verdict="", override_reason=""
        ),
        CalibrationRow(
            "c2", 1, "bugsweep", DETECTED, 50, human_verdict="   ", override_reason=""
        ),
    ]
    resolved = apply_overrides(rows)
    assert resolved[0].verdict == DETECTED  # blank → judge_verdict
    assert resolved[1].verdict == DETECTED  # whitespace-only → judge_verdict


def test_apply_overrides_non_blank_overrides_judge() -> None:
    rows = [
        CalibrationRow(
            "c1",
            1,
            "bugsweep",
            judge_verdict=DETECTED,
            judge_confidence=90,
            human_verdict=NOT_DETECTED,
            override_reason="judge over-credited",
        )
    ]
    resolved = apply_overrides(rows)
    assert resolved[0].verdict == NOT_DETECTED  # human verdict wins


def _bs(case_id: str, verdict: str, post_cutoff: bool = True) -> CaseRunVerdict:
    return CaseRunVerdict(
        case_id=case_id, run=1, arm="bugsweep", verdict=verdict, post_cutoff=post_cutoff
    )


def _bl(case_id: str, verdict: str, post_cutoff: bool = True) -> CaseRunVerdict:
    return CaseRunVerdict(
        case_id=case_id, run=1, arm="baseline", verdict=verdict, post_cutoff=post_cutoff
    )
