"""Final human-calibration artifacts are derived from actual review records."""

import json
import sys
from pathlib import Path

import pytest
from jsonschema.validators import Draft202012Validator

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.calibration import build_blinded_packets, freeze_sample
import bench.scorer.calibration_finalize as finalizer


def _records(count=2):
    frame = [
        {"candidate_id": f"c{index}", "experiment_id": "e", "host": "codex", "arm": ("current_skill", "previous_release", "no_skill_baseline")[index % 3], "category": "logic", "severity": "high", "status": "rejected" if index % 6 >= 3 else "confirmed", "case_id": f"case-{index // 6}", "repository": f"repo-{index // 12}", "evidence": {}}
        for index in range(count)
    ]
    frozen = freeze_sample(frame, seed=1)
    packets, unblinding = build_blinded_packets(frame, frozen)
    labels = [
        {"review_id": packet["review_id"], "reviewer_id": reviewer, "role": "primary", "label": "real", "reason": "human observation", "seconds": 1}
        for packet in packets for reviewer in ("a", "b")
    ]
    return {"frame": frame, "frozen": frozen, "unblinding": unblinding, "labels": labels, "adjudications": []}


def test_finalizer_emits_schema_valid_passed_artifact_from_complete_human_records(monkeypatch) -> None:
    def complete(records, receipts):
        from bench.scorer.calibration import evaluation_calibration_from_records
        calibration = evaluation_calibration_from_records(records, receipts)
        # Only transport verification is mocked; all sample, label and metric
        # calculations use a complete synthetic frame. No live human claim.
        calibration["hosts"]["codex"]["frame_complete"] = True
        return calibration
    monkeypatch.setattr(finalizer, "evaluation_calibration_from_records", complete)
    artifact, summary = finalizer.build_human_calibration_artifact(
        _records(60), [{"host": "codex", "arm": arm, "accounting_state": "complete", "usage": {"cost_usd": 1, "cost_source": "actual"}} for arm in ("current_skill", "previous_release", "no_skill_baseline")], source_manifest_sha256="a" * 64, tested_revision="r1", invocation_id="i1"
    )
    schema = json.loads((Path(__file__).resolve().parents[2] / "schemas" / "evidence-artifact.schema.json").read_text())
    Draft202012Validator(schema).validate(artifact)
    assert artifact["result"] == "passed"
    assert artifact["payload"]["labels"] == summary["calibration"]["labels"]
    assert summary["status"] == "passed"
    assert len(artifact["payload"]["reviewed_candidate_ids"]) == 60
    assert len(artifact["payload"]["labels"]) == 120


def test_finalizer_blocks_incomplete_human_records_without_inventing_labels() -> None:
    records = _records()
    records["labels"] = records["labels"][:1]
    artifact, summary = finalizer.build_human_calibration_artifact(
        records, [], source_manifest_sha256="a" * 64, tested_revision=None, invocation_id=None
    )
    schema = json.loads((Path(__file__).resolve().parents[2] / "schemas" / "evidence-artifact.schema.json").read_text())
    Draft202012Validator(schema).validate(artifact)
    assert artifact["result"] == "blocked"
    assert artifact["payload"]["labels"] == []
    assert artifact["payload"]["reviewed_candidate_ids"] == []
    assert summary["status"] == "blocked"
    assert "human_measurement_incomplete" in summary["reasons"]
