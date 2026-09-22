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
from typing import Any, Mapping, Sequence

from bench.scorer.extract import extract_findings
from bench.scorer.evidence import load_packets
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
MAX_TRUSTED_SNAPSHOT_BYTES = 10_000_000


def load_trusted_sources(path: Path) -> Mapping[tuple[str, int], Mapping[str, Any]]:
    """Load the coordinator-produced, frozen source excerpt snapshot for CLI scoring."""
    try:
        if not path.is_absolute() or path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_TRUSTED_SNAPSHOT_BYTES:
            raise ValueError("trusted source snapshot must be an absolute bounded regular file")
        snapshot = json.loads(path.read_bytes())
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError("trusted source snapshot is unreadable") from exc
    if not isinstance(snapshot, Mapping) or snapshot.get("schema_version") != 1 or snapshot.get("authority") != "trusted_coordinator" or not isinstance(snapshot.get("cases"), Mapping):
        raise ValueError("trusted source snapshot has invalid authority or shape")
    result: dict[tuple[str, int], Mapping[str, Any]] = {}
    for case_id, runs in snapshot["cases"].items():
        if not isinstance(case_id, str) or not isinstance(runs, Mapping):
            raise ValueError("trusted source snapshot case map is invalid")
        for run, paths in runs.items():
            try:
                run_number = int(run)
            except (TypeError, ValueError) as exc:
                raise ValueError("trusted source snapshot run is invalid") from exc
            if run_number < 1 or not isinstance(paths, Mapping):
                raise ValueError("trusted source snapshot path map is invalid")
            for source_path, excerpt in paths.items():
                if not isinstance(source_path, str) or not isinstance(excerpt, Mapping) or excerpt.get("path") != source_path or not isinstance(excerpt.get("start_line"), int) or not isinstance(excerpt.get("end_line"), int) or excerpt["start_line"] < 1 or excerpt["end_line"] < excerpt["start_line"] or not isinstance(excerpt.get("source_sha256"), str) or len(excerpt["source_sha256"]) != 64 or any(char not in "0123456789abcdef" for char in excerpt["source_sha256"]) or not isinstance(excerpt.get("text"), str):
                    raise ValueError("trusted source snapshot excerpt is invalid")
            result[(case_id, run_number)] = dict(paths)
    return result


def score_results_dir(
    results_dir: Path,
    client: JudgeClient,
    model: str,
    arm: str = ARM_BUGSWEEP,
    max_sample: int = DEFAULT_PRECISION_SAMPLE,
    trusted_sources: Mapping[tuple[str, int], Mapping[str, Any]] | None = None,
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
            evidence_by_bug_id = load_packets(run_dir / "precision-evidence.jsonl")

            section = confirmed_section(report)
            all_findings = extract_findings(section, client, model)

            gt_matched_bug_ids: set[str] = set()
            for f in all_findings:
                finding_map = {"file": f.file, "line": f.line, "rationale": f.rationale}
                judgement = judge_match(finding_map, gt, client, model)
                if judgement.match:
                    gt_matched_bug_ids.add(f.bug_id)

            total, judged = score_precision(
                all_findings, gt_matched_bug_ids, client, model, max_sample,
                evidence_by_bug_id, (trusted_sources or {}).get((case_id, run_n)),
            )
            # Raw model output without source evidence is retained for audit only;
            # it cannot become a precision numerator.
            reviewed = sum(1 for sf in judged if sf.judgement.status == "reviewed")
            real = sum(1 for sf in judged if sf.judgement.status == "reviewed" and sf.judgement.is_real)
            precision = real / reviewed if reviewed else None

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
                    unverified=sum(1 for sf in judged if sf.judgement.status != "reviewed"),
                    reviewed=reviewed,
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
                "reviewed": r.reviewed,
                "findings": [
                    {
                        "bug_id": sf.bug_id,
                        "file": sf.file,
                        "rationale": sf.rationale,
                        "is_real": sf.judgement.is_real,
                        "confidence": sf.judgement.confidence,
                        "reason": sf.judgement.reason,
                        "status": sf.judgement.status,
                    }
                    for sf in r.findings
                ],
                "unverified": r.unverified,
            }
            fh.write(json.dumps(record) + "\n")


def main(argv: Sequence[str]) -> int:  # pragma: no cover
    """Run precision scoring on a results directory and re-render the leaderboard."""
    from bench.scorer.leaderboard import load_verdicts, render_leaderboard

    import argparse

    parser = argparse.ArgumentParser(description="Score Bugsweep precision with optional trusted source excerpts")
    parser.add_argument("results_dir", type=Path)
    parser.add_argument("--trusted-sources", type=Path, help="absolute coordinator snapshot JSON; absent snapshots leave findings unverified")
    parser.add_argument("--harness-results", type=Path, help="export native WU6 results for human review; results_dir must be new")
    parser.add_argument("--frozen-dir", type=Path, help="frozen WU6 protocol/schedule/order directory")
    parser.add_argument("--stage-block", default="full_pipeline", help="one frozen pipeline stage block to export (default: full_pipeline)")
    args = parser.parse_args(argv)
    results_dir = args.results_dir
    if args.harness_results:
        from bench.scorer.harness_results import import_harness_results, write_review_export
        try:
            if args.trusted_sources or args.frozen_dir is None:
                raise ValueError("native import requires --frozen-dir and cannot use --trusted-sources")
            bundle = import_harness_results(args.harness_results, args.frozen_dir, stage_block=args.stage_block)
            write_review_export(bundle, results_dir)
        except (OSError, ValueError) as exc:
            sys.stderr.write(f"precision_score: {exc}\n")
            return 2
        sys.stderr.write(f"precision_score: exported {len(bundle['frame'])} candidates for {bundle['stage_block']}; frame_complete={bundle['frame_complete']}\n")
        return 0
    if args.frozen_dir:
        parser.error("--frozen-dir requires --harness-results")
    backend = os.environ.get("BENCH_JUDGE_BACKEND", DEFAULT_JUDGE_BACKEND)
    model = os.environ.get("BENCH_JUDGE_MODEL", DEFAULT_JUDGE_MODEL)

    client: JudgeClient
    if backend == "codex":
        client = CodexClient()
    else:
        client = OpenAIClient(api_key=os.environ.get("OPENAI_API_KEY", ""))

    try:
        trusted_sources = load_trusted_sources(args.trusted_sources) if args.trusted_sources else None
    except ValueError as exc:
        sys.stderr.write(f"precision_score: {exc}\n")
        return 2
    precision_results = score_results_dir(results_dir, client, model, trusted_sources=trusted_sources)

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
