"""Finalize actual blinded human reviews into trusted calibration evidence."""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

from bench.harness import digest, write_once
from bench.scorer.calibration import evaluation_calibration_from_records
from bench.scorer.evaluation import _read_frozen_json

METRIC_NAMES = ("serious_precision_lower", "baseline_precision_upper", "review_time_ratio", "cost_per_serious_ratio", "unresolved_fraction")
MINIMUM_HUMAN_SAMPLE = 60


def _finite_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value))


def _artifact_labels(calibration: Mapping[str, Any]) -> list[dict[str, Any]]:
    labels = calibration.get("labels")
    if not isinstance(labels, list):
        return []
    required = ("candidate_id", "review_id", "reviewer_id", "role", "label", "seconds", "reason")
    if any(not isinstance(row, Mapping) or any(field not in row for field in required) for row in labels):
        return []
    return [dict(row) for row in labels]


def _completion_reasons(calibration: Mapping[str, Any]) -> list[str]:
    reasons: list[str] = []
    summary = calibration.get("summary")
    hosts = calibration.get("hosts")
    if not isinstance(summary, Mapping) or not isinstance(hosts, Mapping) or not hosts:
        return ["calibration_malformed"]
    if len(calibration.get("sampled_candidate_ids", [])) < MINIMUM_HUMAN_SAMPLE:
        reasons.append("fewer_than_60_human_reviews")
    for host in hosts.values():
        if not isinstance(host, Mapping):
            reasons.append("calibration_malformed")
            continue
        if host.get("frame_complete") is not True:
            reasons.append("native_frame_incomplete")
        if host.get("actual_humans") is not True or host.get("review_time_complete") is not True:
            reasons.append("human_measurement_incomplete")
        if host.get("rejection_audit_complete") is not True:
            reasons.append("rejection_audit_unavailable")
    metrics = calibration.get("metrics")
    if not isinstance(metrics, Mapping) or any(not _finite_number(metrics.get(name)) for name in METRIC_NAMES):
        reasons.append("metrics_incomplete")
    if not _artifact_labels(calibration) or calibration.get("labels_sha256") != digest(_artifact_labels(calibration)):
        reasons.append("canonical_labels_invalid")
    return sorted(set(reasons))


def build_human_calibration_artifact(
    records: Mapping[str, Any],
    receipts: Sequence[Mapping[str, Any]],
    *,
    source_manifest_sha256: str,
    tested_revision: str | None,
    invocation_id: str | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Recompute from immutable native evidence and return evidence plus summary."""
    if not isinstance(source_manifest_sha256, str) or len(source_manifest_sha256) != 64 or any(char not in "0123456789abcdef" for char in source_manifest_sha256):
        raise ValueError("source manifest digest is invalid")
    calibration = evaluation_calibration_from_records(records, receipts)
    labels = _artifact_labels(calibration)
    reasons = _completion_reasons(calibration)
    exact_census = any(
        isinstance(host, Mapping) and host.get("serious_precision_basis") == "exact_finite_census"
        for host in calibration.get("hosts", {}).values()
    )
    limitations = ["finite_corpus_census_not_population_inference"] if exact_census else ["cluster_bootstrap_unavailable_for_unsupported_or_overlapping_cluster_design"]
    if reasons:
        limitations.extend(reasons)
    metrics = calibration.get("metrics") if isinstance(calibration.get("metrics"), Mapping) else {}
    completed = not reasons
    artifact = {
        "schema_version": 1,
        "kind": "human_calibration",
        "producer": "calibration_finalize.py",
        "producer_version": "1",
        "authority": "trusted_coordinator",
        "tested_source_manifest_sha256": source_manifest_sha256,
        "tested_revision": tested_revision,
        "invocation_id": invocation_id,
        "result": "passed" if completed else "blocked",
        "limitations": limitations,
        "payload": {
            "frame_sha256": calibration.get("frame_sha256"),
            "calibration_sha256": digest(calibration),
            "reviewed_candidate_ids": calibration.get("sampled_candidate_ids", []) if completed else [],
            "labels": labels if completed else [],
            "labels_sha256": calibration.get("labels_sha256") if completed else digest([]),
            "metrics": {name: metrics.get(name) for name in METRIC_NAMES} if completed else {name: None for name in METRIC_NAMES},
        },
    }
    return artifact, {"schema_version": 1, "status": artifact["result"], "reasons": reasons, "calibration": calibration}


def _native_receipts(records: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    roots = records.get("input_roots")
    if not isinstance(roots, Mapping) or not isinstance(roots.get("results"), str):
        raise ValueError("calibration records lack immutable native input roots")
    receipts = _read_frozen_json(Path(roots["results"]) / "benchmark-receipts.json", "benchmark receipts")
    if not isinstance(receipts, list) or not all(isinstance(receipt, Mapping) for receipt in receipts):
        raise ValueError("native benchmark receipts are malformed")
    return receipts


def main(argv: Sequence[str] | None = None) -> int:  # pragma: no cover
    parser = argparse.ArgumentParser(description="Finalize completed human calibration records without model execution")
    parser.add_argument("--records", type=Path, required=True, help="absolute calibration-records.json exported from native benchmark evidence")
    parser.add_argument("--labels", type=Path, required=True, help="absolute completed primary-label JSON array")
    parser.add_argument("--adjudications", type=Path, required=True, help="absolute completed adjudication JSON array")
    parser.add_argument("--output-dir", type=Path, required=True, help="new directory for evidence and summary")
    parser.add_argument("--source-manifest-sha256", required=True)
    parser.add_argument("--tested-revision")
    parser.add_argument("--invocation-id")
    args = parser.parse_args(argv)
    try:
        records = _read_frozen_json(args.records, "calibration records")
        labels = _read_frozen_json(args.labels, "human labels")
        adjudications = _read_frozen_json(args.adjudications, "human adjudications")
        if not isinstance(records, Mapping) or not isinstance(labels, list) or not isinstance(adjudications, list) or args.output_dir.exists() or not args.output_dir.parent.is_dir():
            raise ValueError("inputs are malformed or output directory is not new")
        completed = {**records, "labels": labels, "adjudications": adjudications}
        artifact, summary = build_human_calibration_artifact(completed, _native_receipts(completed), source_manifest_sha256=args.source_manifest_sha256, tested_revision=args.tested_revision, invocation_id=args.invocation_id)
        args.output_dir.mkdir(mode=0o700)
        write_once(args.output_dir / "completed-calibration-records.json", completed)
        write_once(args.output_dir / "human-calibration.json", artifact)
        write_once(args.output_dir / "human-calibration-summary.json", summary)
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"calibration_finalize: {exc}\n")
        return 2
    sys.stderr.write(f"calibration_finalize: {artifact['result']} ({', '.join(summary['reasons']) or 'complete'})\n")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
