"""The reducer accepts only a frozen, native cross-platform CI artifact."""

from __future__ import annotations

import copy
import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.ci_evidence import build_ci_artifact
from bench.scorer.evaluation import reduce_evaluation
from bench.tests.unit.test_ci_evidence import REPOSITORY, SOURCE_COMMIT, WORKFLOW_PATH, _receipt
from bench.tests.unit.test_evaluation import _inputs


MANIFEST = "d" * 64


def _write(root: Path, artifact: dict) -> str:
    raw = json.dumps(artifact, sort_keys=True, separators=(",", ":")).encode()
    (root / "ci.json").write_bytes(raw)
    return hashlib.sha256(raw).hexdigest()


def _requirements(digest: str, subject: dict | None = None) -> list[dict]:
    ci = {
        "kind": "cross_platform_ci", "path": "ci.json", "digest": digest,
        "schema_version": 1, "producer": "ci_evidence.py",
        "source_manifest_sha256": MANIFEST,
        "subject": subject or {
            "repository": REPOSITORY, "workflow_path": WORKFLOW_PATH,
            "source_commit": SOURCE_COMMIT, "run_id": 123, "run_attempt": 2,
        },
    }
    absent = [
        {"kind": kind, "path": f"{kind}.json", "digest": "e" * 64,
         "schema_version": 1, "producer": "test", "source_manifest_sha256": MANIFEST}
        for kind in ("host_invocations", "human_calibration", "sandbox_negative",
                     "analyzer_compatibility", "installer_recovery", "independent_final_review")
    ]
    return [ci, *absent]


def _evaluate(root: Path, artifact: dict, subject: dict | None = None) -> dict:
    protocol, schedule, receipts = _inputs()
    return reduce_evaluation(
        protocol, schedule, receipts, required_evidence=_requirements(_write(root, artifact), subject),
        evidence_root=root,
    )


def test_reducer_accepts_valid_ci_artifact_but_six_other_requirements_block_release(tmp_path: Path) -> None:
    artifact = build_ci_artifact(_receipt(), source_manifest_sha256=MANIFEST)
    result = _evaluate(tmp_path, artifact)
    assert "invalid_required_evidence:cross_platform_ci" not in result["verification"]["reasons"]
    assert result["release_eligibility"] is False
    assert "unreadable_required_evidence:host_invocations" in result["verification"]["reasons"]


@pytest.mark.parametrize("mutation", ["subject", "attempt", "revision", "job_failed", "gate_missing"])
def test_reducer_rejects_mismatched_or_failed_ci_evidence(tmp_path: Path, mutation: str) -> None:
    artifact = build_ci_artifact(_receipt(), source_manifest_sha256=MANIFEST)
    subject = None
    if mutation == "subject":
        subject = {"repository": REPOSITORY, "workflow_path": WORKFLOW_PATH,
                   "source_commit": SOURCE_COMMIT, "run_id": 999, "run_attempt": 2}
    elif mutation == "attempt":
        artifact["payload"]["run_attempt"] = 1
    elif mutation == "revision":
        artifact["tested_revision"] = "b" * 40
    elif mutation == "job_failed":
        artifact["payload"]["jobs"][0]["conclusion"] = "failure"
    else:
        artifact["payload"]["jobs"][0]["steps"] = []
    result = _evaluate(tmp_path, artifact, subject)
    assert "invalid_required_evidence:cross_platform_ci" in result["verification"]["reasons"]
