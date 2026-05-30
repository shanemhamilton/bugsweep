"""Offline precision scorer — judges non-GT confirmed findings in a results dir.

Usage:
    python3 -m bench.scorer.precision_score <results-dir>

Reads:
    <results-dir>/bugsweep/<case_id>/run-<n>/report.md
    <results-dir>/ground_truths.json
    <results-dir>/provenance.json

Writes:
    <results-dir>/precision_track.jsonl

Then re-renders:
    <results-dir>/leaderboard.md

Environment variables (same as run.sh):
    BENCH_JUDGE_BACKEND    "codex" or "openai" (default: "openai")
    BENCH_JUDGE_MODEL      model id (default: "gpt-4o-judge")
    OPENAI_API_KEY         required when BENCH_JUDGE_BACKEND=openai
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Sequence

from bench.scorer.extract import extract_findings
from bench.scorer.judge import CodexClient, JudgeClient, OpenAIClient, judge_match
from bench.scorer.parse_report import confirmed_section
from bench.scorer.precision import (
    DEFAULT_PRECISION_SAMPLE,
    PrecisionCaseResult,
    score_precision,
)

ARM_BUGSWEEP = "bugsweep"
DEFAULT_JUDGE_BACKEND = "openai"
DEFAULT_JUDGE_MODEL = "gpt-4o-judge"


def score_results_dir(
    results_dir: Path,
    client: JudgeClient,
    model: str,
    arm: str = ARM_BUGSWEEP,
    max_sample: int = DEFAULT_PRECISION_SAMPLE,
) -> list[PrecisionCaseResult]:
    """Score precision for every case-run report under results_dir/arm.

    Returns one PrecisionCaseResult per (case, run) where report.md exists.
    Runs without report.md (ERROR/SKIP) are silently skipped.
    """
    arm_dir = results_dir / arm
    if not arm_dir.is_dir():
        return []

    gt_data: dict = json.loads(
        (results_dir / "ground_truths.json").read_text(encoding="utf-8")
    )
    results: list[PrecisionCaseResult] = []
    for case_dir in sorted(arm_dir.iterdir()):
        if not case_dir.is_dir():
            continue
        case_id = case_dir.name
        gt = dict(gt_data.get(case_id, {}))
        gt.setdefault("category", "")

        for run_dir in sorted(case_dir.glob("run-*")):
            try:
                run_n = int(run_dir.name.split("-", 1)[1])
            except (IndexError, ValueError):
                continue
            report = run_dir / "report.md"
            if not report.is_file():
                continue

            section = confirmed_section(report)
            all_findings = extract_findings(section, client, model)

            gt_matched_bug_ids: set[str] = set()
            for f in all_findings:
                finding_map = {"file": f.file, "line": f.line, "rationale": f.rationale}
                judgement = judge_match(finding_map, gt, client, model)
                if judgement.match:
                    gt_matched_bug_ids.add(f.bug_id)

            total, judged = score_precision(
                all_findings, gt_matched_bug_ids, client, model, max_sample
            )
            real = sum(1 for sf in judged if sf.judgement.is_real)
            precision = real / len(judged) if judged else 0.0

            results.append(
                PrecisionCaseResult(
                    case_id=case_id,
                    run=run_n,
                    arm=arm,
                    total_confirmed=total,
                    sampled=len(judged),
                    real=real,
                    precision=precision,
                    findings=tuple(judged),
                )
            )
    return results


def write_precision_track(
    results: list[PrecisionCaseResult],
    out_path: Path,
) -> None:
    """Write one JSONL record per PrecisionCaseResult to out_path."""
    with out_path.open("w", encoding="utf-8") as fh:
        for r in results:
            record = {
                "case_id": r.case_id,
                "run": r.run,
                "arm": r.arm,
                "total_confirmed": r.total_confirmed,
                "sampled": r.sampled,
                "real": r.real,
                "precision": r.precision,
                "findings": [
                    {
                        "bug_id": sf.bug_id,
                        "file": sf.file,
                        "rationale": sf.rationale,
                        "is_real": sf.judgement.is_real,
                        "confidence": sf.judgement.confidence,
                        "reason": sf.judgement.reason,
                    }
                    for sf in r.findings
                ],
            }
            fh.write(json.dumps(record) + "\n")


def main(argv: Sequence[str]) -> int:  # pragma: no cover
    """Run precision scoring on a results directory and re-render the leaderboard."""
    from bench.scorer.leaderboard import load_verdicts, render_leaderboard

    if len(argv) != 1:
        sys.stderr.write(
            "usage: python3 -m bench.scorer.precision_score <results-dir>\n"
        )
        return 2

    results_dir = Path(argv[0])
    backend = os.environ.get("BENCH_JUDGE_BACKEND", DEFAULT_JUDGE_BACKEND)
    model = os.environ.get("BENCH_JUDGE_MODEL", DEFAULT_JUDGE_MODEL)

    client: JudgeClient
    if backend == "codex":
        client = CodexClient()
    else:
        client = OpenAIClient(api_key=os.environ.get("OPENAI_API_KEY", ""))

    precision_results = score_results_dir(results_dir, client, model)

    out_path = results_dir / "precision_track.jsonl"
    write_precision_track(precision_results, out_path)
    sys.stderr.write(f"precision_score: wrote {out_path}\n")

    verdicts = load_verdicts(results_dir / "verdicts.jsonl")
    ground_truths = json.loads(
        (results_dir / "ground_truths.json").read_text(encoding="utf-8")
    )
    provenance = json.loads(
        (results_dir / "provenance.json").read_text(encoding="utf-8")
    )
    bugsweep_verdicts = [v for v in verdicts if v.arm == ARM_BUGSWEEP]
    baseline_verdicts = [v for v in verdicts if v.arm != ARM_BUGSWEEP]

    markdown = render_leaderboard(
        bugsweep=bugsweep_verdicts,
        baseline=baseline_verdicts,
        ground_truths=ground_truths,
        provenance=provenance,
        precision_results=precision_results,
    )
    leaderboard_path = results_dir / "leaderboard.md"
    leaderboard_path.write_text(markdown, encoding="utf-8")
    sys.stderr.write(f"precision_score: re-rendered {leaderboard_path}\n")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv[1:]))
