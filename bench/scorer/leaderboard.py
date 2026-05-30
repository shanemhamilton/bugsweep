"""Render the benchmark ``leaderboard.md`` from per-run verdicts + provenance.

``render_leaderboard`` is a PURE function (no I/O) so the unit suite can drive it
to full coverage; the thin :func:`main` reads the on-disk run artifacts and
writes ``leaderboard.md`` (excluded from coverage). The rendered document is the
most-attacked output, so it must surface, unambiguously:

* a 3-column per-case table — bugsweep verdict | baseline verdict | ground-truth;
* per-arm detection rate with Wilson confidence intervals (from ``score.py``);
* the bugsweep−baseline paired delta WITH each arm's ERROR/SKIPPED counts beside
  it (so an arm that errored cannot inflate the delta unnoticed);
* a headline LABELED ``bugsweep @ <commit>`` — never a release version like
  ``v0.1.0`` (the benchmarked artifact is a specific commit, design row 55);
* a post/pre-cutoff (contamination) split, with the post-cutoff inconclusive
  floor honored; and
* a provenance block ENUMERATING every field in :data:`PROVENANCE_FIELDS`, with
  an explicit ``(unknown)`` marker for any field the caller omitted.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

from bench.scorer.precision import DEFAULT_PRECISION_SAMPLE, PrecisionCaseResult
from bench.scorer.score import (
    DETECTED,
    CaseRunVerdict,
    aggregate_arm,
    paired_delta,
    summarize_arm,
)

# Provenance fields enumerated by the leaderboard. The renderer emits a row per
# field even when the caller omits it, so the block always documents what SHOULD
# be present. Order is the audit-reading order.
PROVENANCE_FIELDS: tuple[str, ...] = (
    "runner_model_id",
    "runner_cutoff_date",
    "judge_model_id",
    "judge_prompt_hash",
    "bugsweep_commit",
    "case_verified_shas",
    "container_image_digest",
    "egress_proxy_image",
    "line_window",
    "k",
)

UNKNOWN_MARKER = "(unknown)"
ARM_BUGSWEEP = "bugsweep"
ARM_BASELINE = "baseline"
PERCENT_SCALE = 100.0
RATE_DECIMALS = 1


def render_leaderboard(
    *,
    bugsweep: Sequence[CaseRunVerdict],
    baseline: Sequence[CaseRunVerdict],
    ground_truths: Mapping[str, Mapping[str, Any]],
    provenance: Mapping[str, Any],
    precision_results: Sequence[PrecisionCaseResult] | None = None,
) -> str:
    """Render the full leaderboard markdown from resolved verdicts + provenance.

    Pure: takes already-resolved per-run verdicts for both arms, the per-case
    ground truth, and a provenance mapping; returns the markdown string.
    """
    commit = str(provenance.get("bugsweep_commit", UNKNOWN_MARKER))
    sections = [
        _headline(commit),
        _per_case_table(bugsweep, baseline, ground_truths),
        _detection_rates(bugsweep, baseline),
        _paired_delta_section(bugsweep, baseline),
        _cutoff_split(bugsweep, baseline),
        render_precision_section(list(precision_results) if precision_results else []),
        _provenance_block(provenance),
    ]
    return "\n\n".join(sections) + "\n"


def _headline(commit: str) -> str:
    # The benchmarked artifact is a specific commit, NOT a release version.
    return f"# Leaderboard — bugsweep @ {commit}"


def _per_case_table(
    bugsweep: Sequence[CaseRunVerdict],
    baseline: Sequence[CaseRunVerdict],
    ground_truths: Mapping[str, Mapping[str, Any]],
) -> str:
    bugsweep_by_case = _verdict_label_by_case(bugsweep)
    baseline_by_case = _verdict_label_by_case(baseline)
    case_ids = sorted(
        set(bugsweep_by_case) | set(baseline_by_case) | set(ground_truths)
    )
    header = (
        "## Per-case verdicts\n\n"
        "| case | bugsweep | baseline | ground-truth |\n"
        "| --- | --- | --- | --- |"
    )
    rows = [
        "| {case} | {bug} | {base} | {gt} |".format(
            case=case_id,
            bug=bugsweep_by_case.get(case_id, UNKNOWN_MARKER),
            base=baseline_by_case.get(case_id, UNKNOWN_MARKER),
            gt=_ground_truth_label(ground_truths.get(case_id)),
        )
        for case_id in case_ids
    ]
    if not rows:
        rows = ["| _(no cases)_ | | | |"]
    return "\n".join([header, *rows])


def _detection_rates(
    bugsweep: Sequence[CaseRunVerdict],
    baseline: Sequence[CaseRunVerdict],
) -> str:
    bs_agg = aggregate_arm(bugsweep)
    bl_agg = aggregate_arm(baseline)
    bs_sum = summarize_arm(bugsweep)
    bl_sum = summarize_arm(baseline)
    header = (
        "## Detection rate (95% Wilson CI)\n\n"
        "| arm | detected@>=1 | detected@majority | hit-rate | "
        "completed | Wilson CI | status |\n"
        "| --- | --- | --- | --- | --- | --- | --- |"
    )
    rows = [
        _rate_row(ARM_BUGSWEEP, bs_agg, bs_sum),
        _rate_row(ARM_BASELINE, bl_agg, bl_sum),
    ]
    return "\n".join([header, *rows])


def _rate_row(arm: str, agg: Any, summary: Any) -> str:
    return (
        "| {arm} | {at1} | {maj} | {rate} | {completed} | "
        "[{low}, {high}] | {status} |"
    ).format(
        arm=arm,
        at1=summary.detected_at_1,
        maj=summary.detected_at_majority,
        rate=_pct(agg.hit_rate),
        completed=agg.completed,
        low=_pct(agg.wilson_low),
        high=_pct(agg.wilson_high),
        status=summary.status,
    )


def _paired_delta_section(
    bugsweep: Sequence[CaseRunVerdict],
    baseline: Sequence[CaseRunVerdict],
) -> str:
    delta = paired_delta(bugsweep, baseline)
    return (
        "## Paired delta (bugsweep − baseline)\n\n"
        f"- paired cases (both arms completed): {delta.paired_n}\n"
        f"- detected@>=1 delta: {_pct(delta.delta)} pp\n"
        f"- bugsweep excluded — ERROR: {delta.bugsweep_error_count}, "
        f"SKIPPED: {delta.bugsweep_skipped_count}\n"
        f"- baseline excluded — ERROR: {delta.baseline_error_count}, "
        f"SKIPPED: {delta.baseline_skipped_count}"
    )


def _cutoff_split(
    bugsweep: Sequence[CaseRunVerdict],
    baseline: Sequence[CaseRunVerdict],
) -> str:
    """Render the contamination (post/pre-cutoff) split for both arms."""
    post_bugsweep = [v for v in bugsweep if v.post_cutoff]
    pre_bugsweep = [v for v in bugsweep if not v.post_cutoff]
    post_baseline = [v for v in baseline if v.post_cutoff]
    pre_baseline = [v for v in baseline if not v.post_cutoff]
    post = _split_block(
        "Post-cutoff", post_bugsweep, post_baseline, note_inconclusive=True
    )
    pre = _split_block("Pre-cutoff", pre_bugsweep, pre_baseline)
    return (
        "## Contamination split\n\n"
        "Cases are split by `disclosure_date` vs the runner model cutoff.\n\n"
        f"{post}\n\n{pre}"
    )


def _split_block(
    label: str,
    bugsweep: Sequence[CaseRunVerdict],
    baseline: Sequence[CaseRunVerdict],
    *,
    note_inconclusive: bool = False,
) -> str:
    bs_agg = aggregate_arm(bugsweep)
    bl_agg = aggregate_arm(baseline)
    bs_sum = summarize_arm(bugsweep)
    bl_sum = summarize_arm(baseline)
    lines = [
        f"### {label}",
        f"- bugsweep: detected@majority {bs_sum.detected_at_majority}, "
        f"hit-rate {_pct(bs_agg.hit_rate)} (completed {bs_agg.completed})",
        f"- baseline: detected@majority {bl_sum.detected_at_majority}, "
        f"hit-rate {_pct(bl_agg.hit_rate)} (completed {bl_agg.completed})",
    ]
    if note_inconclusive:
        lines.append(f"- status: {bs_sum.status} (post-cutoff inconclusive floor)")
    return "\n".join(lines)


def render_precision_section(
    precision_results: Sequence[PrecisionCaseResult],
    max_sample: int = DEFAULT_PRECISION_SAMPLE,
) -> str:
    """Render the ## Precision track section; shows a placeholder when empty."""
    if not precision_results:
        return (
            "## Precision track\n\n"
            "_(no data — run `python3 -m bench.scorer.precision_score <results-dir>`)_"
        )
    by_arm: dict[str, list[PrecisionCaseResult]] = {}
    for r in precision_results:
        by_arm.setdefault(r.arm, []).append(r)

    header = (
        "## Precision track\n\n"
        f"Sample: up to {max_sample} non-GT confirmed findings per case-run.\n\n"
        "| arm | case-runs | total confirmed | sampled | real | precision |\n"
        "| --- | --- | --- | --- | --- | --- |"
    )
    rows = []
    for arm_name, arm_rs in sorted(by_arm.items()):
        total_sampled = sum(r.sampled for r in arm_rs)
        total_real = sum(r.real for r in arm_rs)
        rows.append(
            "| {arm} | {runs} | {total} | {sampled} | {real} | {prec} |".format(
                arm=arm_name,
                runs=len(arm_rs),
                total=sum(r.total_confirmed for r in arm_rs),
                sampled=total_sampled,
                real=total_real,
                prec=_pct(total_real / total_sampled if total_sampled > 0 else 0.0),
            )
        )
    return "\n".join([header, *rows])


def _provenance_block(provenance: Mapping[str, Any]) -> str:
    header = "## Provenance\n\n| field | value |\n| --- | --- |"
    rows = [
        f"| {field} | {_provenance_value(provenance, field)} |"
        for field in PROVENANCE_FIELDS
    ]
    return "\n".join([header, *rows])


def _provenance_value(provenance: Mapping[str, Any], field: str) -> str:
    if field not in provenance:
        return UNKNOWN_MARKER
    value = provenance[field]
    if isinstance(value, Mapping):
        if not value:
            return UNKNOWN_MARKER
        return "; ".join(f"{key}={val}" for key, val in value.items())
    return str(value)


def _verdict_label_by_case(
    verdicts: Sequence[CaseRunVerdict],
) -> dict[str, str]:
    """Collapse a case's runs into one cell: DETECTED if any run detected."""
    by_case: dict[str, list[str]] = {}
    for verdict in verdicts:
        by_case.setdefault(verdict.case_id, []).append(verdict.verdict)
    labels: dict[str, str] = {}
    for case_id, run_verdicts in by_case.items():
        if DETECTED in run_verdicts:
            labels[case_id] = DETECTED
        else:
            # Stable: the worst non-detected verdict observed (ERROR/SKIPPED/
            # NOT_DETECTED) sorted so the cell is deterministic.
            labels[case_id] = sorted(set(run_verdicts))[0]
    return labels


def _ground_truth_label(ground_truth: Mapping[str, Any] | None) -> str:
    if not ground_truth:
        return UNKNOWN_MARKER
    description = str(ground_truth.get("description", "")).strip()
    if not description:
        return UNKNOWN_MARKER
    # Keep the table cell compact; the full description lives in the case JSON.
    return description.splitlines()[0]


def _pct(rate: float) -> str:
    return f"{rate * PERCENT_SCALE:.{RATE_DECIMALS}f}%"


def load_verdicts(path: Path) -> list[CaseRunVerdict]:  # pragma: no cover
    verdicts: list[CaseRunVerdict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        verdicts.append(
            CaseRunVerdict(
                case_id=str(record["case_id"]),
                run=int(record["run"]),
                arm=str(record["arm"]),
                verdict=str(record["verdict"]),
                post_cutoff=bool(record["post_cutoff"]),
            )
        )
    return verdicts


def main(argv: Sequence[str]) -> int:  # pragma: no cover
    """Read ``<results-dir>`` run artifacts and write ``leaderboard.md``.

    Expects, under the results dir:
      verdicts.jsonl   one JSON object per (case, run, arm) line
      ground_truths.json   {case_id: {description, category, ...}}
      provenance.json      the enumerated provenance mapping
    """
    if len(argv) != 1:
        sys.stderr.write("usage: python -m bench.scorer.leaderboard <results-dir>\n")
        return 2
    results_dir = Path(argv[0])
    verdicts = load_verdicts(results_dir / "verdicts.jsonl")
    ground_truths = json.loads(
        (results_dir / "ground_truths.json").read_text(encoding="utf-8")
    )
    provenance = json.loads(
        (results_dir / "provenance.json").read_text(encoding="utf-8")
    )
    bugsweep = [v for v in verdicts if v.arm == ARM_BUGSWEEP]
    baseline = [v for v in verdicts if v.arm == ARM_BASELINE]
    markdown = render_leaderboard(
        bugsweep=bugsweep,
        baseline=baseline,
        ground_truths=ground_truths,
        provenance=provenance,
    )
    (results_dir / "leaderboard.md").write_text(markdown, encoding="utf-8")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv[1:]))
