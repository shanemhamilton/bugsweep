"""GitHub Actions CI evidence must be native, complete, and successful."""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.ci_evidence import build_ci_artifact, capture_ci_receipt, validate_ci_receipt


REPOSITORY = "acme/bugsweep"
WORKFLOW_PATH = ".github/workflows/quality.yml"
SOURCE_COMMIT = "a" * 40
JOBS = [
    "ubuntu-24.04 / Python 3.12",
    "ubuntu-24.04 / Python 3.13",
    "macos-14 / Python 3.12",
    "macos-14 / Python 3.13",
]


def _receipt() -> dict:
    return {
        "schema_version": 1,
        "kind": "cross_platform_ci",
        "repository": REPOSITORY,
        "workflow_path": WORKFLOW_PATH,
        "source_commit": SOURCE_COMMIT,
        "run_id": 123,
        "run_attempt": 2,
        "jobs_run_id": 123,
        "jobs_run_attempt": 2,
        "workflow": {"id": 99, "path": WORKFLOW_PATH},
        "run": {
            "id": 123,
            "run_attempt": 2,
            "workflow_id": 99,
            "head_sha": SOURCE_COMMIT,
            "status": "completed",
            "conclusion": "success",
            "repository": {"full_name": REPOSITORY},
            "head_repository": {"full_name": REPOSITORY},
        },
        "jobs": [
            {
                "id": index + 1,
                "run_id": 123,
                "head_sha": SOURCE_COMMIT,
                "name": name,
                "status": "completed",
                "conclusion": "success",
                "labels": [name.split(" / ")[0]],
                "steps": [
                    {
                        "name": "Full Git-backed CI contract",
                        "status": "completed",
                        "conclusion": "success",
                    }
                ],
            }
            for index, name in enumerate(JOBS)
        ],
    }


def test_validates_exact_native_workflow_run_and_all_matrix_jobs() -> None:
    assert validate_ci_receipt(_receipt(), repository=REPOSITORY, workflow_path=WORKFLOW_PATH, source_commit=SOURCE_COMMIT) == []


def test_rejects_pass_flag_without_native_job_step_evidence() -> None:
    receipt = _receipt()
    receipt["result"] = "passed"
    receipt["jobs"][0]["steps"] = []
    assert "full_git_gate_missing:ubuntu-24.04 / Python 3.12" in validate_ci_receipt(receipt, repository=REPOSITORY, workflow_path=WORKFLOW_PATH, source_commit=SOURCE_COMMIT)


def test_rejects_cross_repository_commit_attempt_and_incomplete_matrix() -> None:
    receipt = _receipt()
    receipt["run"]["head_repository"]["full_name"] = "fork/bugsweep"
    receipt["run"]["head_sha"] = "b" * 40
    receipt["run"]["run_attempt"] = 1
    receipt["jobs"].pop()
    reasons = validate_ci_receipt(receipt, repository=REPOSITORY, workflow_path=WORKFLOW_PATH, source_commit=SOURCE_COMMIT)
    assert {"run_head_repository_mismatch", "run_source_commit_mismatch", "run_attempt_mismatch", "missing_job:macos-14 / Python 3.13"} <= set(reasons)


def test_rejects_duplicate_matrix_job_even_if_one_copy_passes() -> None:
    receipt = _receipt()
    receipt["jobs"].append(copy.deepcopy(receipt["jobs"][0]))
    assert "duplicate_job:ubuntu-24.04 / Python 3.12" in validate_ci_receipt(receipt, repository=REPOSITORY, workflow_path=WORKFLOW_PATH, source_commit=SOURCE_COMMIT)


def test_rejects_jobs_without_native_lineage_runner_or_exactly_one_gate() -> None:
    receipt = _receipt()
    job = receipt["jobs"][0]
    job["run_id"] = 999
    job["head_sha"] = "b" * 40
    job["labels"] = ["renamed-runner"]
    job["steps"].append(copy.deepcopy(job["steps"][0]))
    reasons = validate_ci_receipt(receipt, repository=REPOSITORY, workflow_path=WORKFLOW_PATH, source_commit=SOURCE_COMMIT)
    assert {
        "job_run_id_mismatch:ubuntu-24.04 / Python 3.12",
        "job_source_commit_mismatch:ubuntu-24.04 / Python 3.12",
        "runner_label_mismatch:ubuntu-24.04 / Python 3.12",
        "full_git_gate_duplicate:ubuntu-24.04 / Python 3.12",
    } <= set(reasons)


def test_rejects_missing_native_identifiers_and_attempt_endpoint_binding() -> None:
    receipt = _receipt()
    receipt["workflow"]["id"] = None
    receipt["jobs_run_attempt"] = 1
    reasons = validate_ci_receipt(receipt, repository=REPOSITORY, workflow_path=WORKFLOW_PATH, source_commit=SOURCE_COMMIT)
    assert {"workflow_id_mismatch", "jobs_run_attempt_mismatch"} <= set(reasons)


def test_capture_fetches_workflow_run_and_attempt_jobs_without_caller_pass_flags() -> None:
    receipt = _receipt()
    replies = {
        f"repos/{REPOSITORY}/actions/workflows/quality.yml": receipt["workflow"],
        f"repos/{REPOSITORY}/actions/runs/123": receipt["run"],
        f"repos/{REPOSITORY}/actions/runs/123/attempts/2/jobs?per_page=100": {"total_count": 4, "jobs": receipt["jobs"]},
    }
    calls = []

    def request(path: str) -> dict:
        calls.append(path)
        return copy.deepcopy(replies[path])

    assert capture_ci_receipt(repository=REPOSITORY, workflow_path=WORKFLOW_PATH, source_commit=SOURCE_COMMIT, run_id=123, run_attempt=2, request=request) == receipt
    assert calls == list(replies)


def test_capture_cli_creates_new_receipt_file(tmp_path: Path, monkeypatch) -> None:
    receipt = _receipt()
    output = tmp_path / "receipt.json"
    monkeypatch.setattr(
        "bench.scorer.ci_evidence.capture_ci_receipt", lambda **_: receipt
    )
    from bench.scorer.ci_evidence import main

    manifest = "d" * 64
    assert main(["capture", "--repository", REPOSITORY, "--workflow-path", WORKFLOW_PATH,
                 "--source-commit", SOURCE_COMMIT, "--run-id", "123", "--run-attempt", "2",
                 "--source-manifest-sha256", manifest,
                 "--output", str(output)]) == 0
    assert json.loads(output.read_text()) == build_ci_artifact(receipt, source_manifest_sha256=manifest)
    assert main(["capture", "--repository", REPOSITORY, "--workflow-path", WORKFLOW_PATH,
                 "--source-commit", SOURCE_COMMIT, "--run-id", "123", "--run-attempt", "2",
                 "--source-manifest-sha256", manifest,
                 "--output", str(output)]) == 2
