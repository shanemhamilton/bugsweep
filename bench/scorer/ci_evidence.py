"""Fail-closed receipts from the native GitHub Actions API."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from argparse import ArgumentParser
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path, PurePosixPath
from typing import Any


REQUIRED_JOBS = frozenset(
    f"{os_name} / Python {python}"
    for os_name in ("ubuntu-24.04", "macos-14")
    for python in ("3.12", "3.13")
)
FULL_GIT_GATE = "Full Git-backed CI contract"
GH_TIMEOUT_SECONDS = 30
MAX_GH_OUTPUT_BYTES = 1_000_000
_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_SHA = re.compile(r"^[a-f0-9]{40}$")
_SHA256 = re.compile(r"^[a-f0-9]{64}$")


def _valid_request(repository: str, workflow_path: str, source_commit: str, run_id: int, run_attempt: int) -> bool:
    if not isinstance(repository, str) or not isinstance(workflow_path, str) or not isinstance(source_commit, str):
        return False
    path = PurePosixPath(workflow_path)
    return (
        bool(_REPOSITORY.fullmatch(repository))
        and path.parts == (".github", "workflows", path.name)
        and path.name.endswith((".yml", ".yaml"))
        and bool(_SHA.fullmatch(source_commit))
        and type(run_id) is int and run_id > 0
        and type(run_attempt) is int and run_attempt > 0
    )


def validate_ci_receipt(
    receipt: Mapping[str, Any], *, repository: str, workflow_path: str, source_commit: str
) -> list[str]:
    """Return reasons unless raw GitHub workflow, run, and job evidence agrees."""
    reasons: list[str] = []
    if not isinstance(receipt, Mapping):
        return ["receipt_not_object"]
    run_id, run_attempt = receipt.get("run_id"), receipt.get("run_attempt")
    if not _valid_request(repository, workflow_path, source_commit, run_id, run_attempt):
        return ["invalid_ci_evidence_request"]
    run = receipt.get("run")
    workflow = receipt.get("workflow")
    jobs = receipt.get("jobs")
    if not isinstance(run, Mapping) or not isinstance(workflow, Mapping) or not isinstance(jobs, Sequence) or isinstance(jobs, (str, bytes)):
        return ["native_github_receipt_missing"]
    if receipt.get("schema_version") != 1 or receipt.get("kind") != "cross_platform_ci":
        reasons.append("receipt_schema_mismatch")
    if receipt.get("repository") != repository:
        reasons.append("receipt_repository_mismatch")
    if receipt.get("workflow_path") != workflow_path or workflow.get("path") != workflow_path:
        reasons.append("workflow_path_mismatch")
    if receipt.get("source_commit") != source_commit or run.get("head_sha") != source_commit:
        reasons.append("run_source_commit_mismatch")
    if type(run.get("id")) is not int or run["id"] < 1 or run_id != run.get("id"):
        reasons.append("run_id_mismatch")
    if type(run.get("run_attempt")) is not int or run["run_attempt"] < 1 or run_attempt != run.get("run_attempt"):
        reasons.append("run_attempt_mismatch")
    if receipt.get("jobs_run_id") != run_id:
        reasons.append("jobs_run_id_mismatch")
    if receipt.get("jobs_run_attempt") != run_attempt:
        reasons.append("jobs_run_attempt_mismatch")
    if type(workflow.get("id")) is not int or workflow["id"] < 1 or type(run.get("workflow_id")) is not int or run["workflow_id"] < 1 or run.get("workflow_id") != workflow.get("id"):
        reasons.append("workflow_id_mismatch")
    for field in ("repository", "head_repository"):
        value = run.get(field)
        if not isinstance(value, Mapping) or value.get("full_name") != repository:
            reasons.append(f"run_{field}_mismatch")
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        reasons.append("workflow_not_successful")
    by_name: dict[str, Mapping[str, Any]] = {}
    for job in jobs:
        if isinstance(job, Mapping) and isinstance(job.get("name"), str) and job["name"] not in by_name:
            by_name[job["name"]] = job
        elif isinstance(job, Mapping) and job.get("name") in REQUIRED_JOBS:
            reasons.append(f"duplicate_job:{job['name']}")
    for name in sorted(REQUIRED_JOBS):
        job = by_name.get(name)
        if job is None:
            reasons.append(f"missing_job:{name}")
            continue
        if job.get("status") != "completed" or job.get("conclusion") != "success":
            reasons.append(f"job_not_successful:{name}")
        if type(job.get("id")) is not int or job["id"] < 1:
            reasons.append(f"job_id_missing:{name}")
        if type(job.get("run_id")) is not int or job.get("run_id") != run_id:
            reasons.append(f"job_run_id_mismatch:{name}")
        if job.get("head_sha") != source_commit:
            reasons.append(f"job_source_commit_mismatch:{name}")
        expected_runner = name.split(" / ", 1)[0]
        labels = job.get("labels")
        if not isinstance(labels, Sequence) or isinstance(labels, (str, bytes)) or expected_runner not in labels:
            reasons.append(f"runner_label_mismatch:{name}")
        steps = job.get("steps")
        gates = [step for step in steps if isinstance(step, Mapping) and step.get("name") == FULL_GIT_GATE] if isinstance(steps, Sequence) and not isinstance(steps, (str, bytes)) else []
        if not gates:
            reasons.append(f"full_git_gate_missing:{name}")
        elif len(gates) != 1:
            reasons.append(f"full_git_gate_duplicate:{name}")
        elif gates[0].get("status") != "completed" or gates[0].get("conclusion") != "success":
            reasons.append(f"full_git_gate_not_successful:{name}")
    return reasons


def _gh_request(path: str) -> Mapping[str, Any]:
    try:
        completed = subprocess.run(
            ["gh", "api", "--method", "GET", path], text=True, capture_output=True,
            check=False, timeout=GH_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"GitHub API timed out after {GH_TIMEOUT_SECONDS}s for {path}") from exc
    output_bytes = len(completed.stdout.encode("utf-8")) + len(completed.stderr.encode("utf-8"))
    if output_bytes > MAX_GH_OUTPUT_BYTES:
        raise RuntimeError(f"GitHub API response exceeds {MAX_GH_OUTPUT_BYTES} bytes for {path}")
    if completed.returncode:
        raise RuntimeError(f"GitHub API request failed for {path}: {completed.stderr.strip()[:1_000]}")
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"GitHub API returned invalid JSON for {path}") from exc
    if not isinstance(value, Mapping):
        raise RuntimeError(f"GitHub API returned a non-object for {path}")
    return value


def capture_ci_receipt(
    *, repository: str, workflow_path: str, source_commit: str, run_id: int, run_attempt: int,
    request: Callable[[str], Mapping[str, Any]] = _gh_request,
) -> dict[str, Any]:
    """Capture and validate one GitHub-hosted quality workflow attempt, read-only."""
    if not _valid_request(repository, workflow_path, source_commit, run_id, run_attempt):
        raise ValueError("invalid CI evidence request")
    prefix = f"repos/{repository}/actions"
    workflow = request(f"{prefix}/workflows/{workflow_path.rsplit('/', 1)[-1]}")
    run = request(f"{prefix}/runs/{run_id}")
    # GitHub's job payload exposes run_id and head_sha, but no run_attempt;
    # the attempt is bound by this attempt-scoped endpoint URL.
    jobs_response = request(f"{prefix}/runs/{run_id}/attempts/{run_attempt}/jobs?per_page=100")
    jobs = jobs_response.get("jobs")
    if not isinstance(jobs, list) or jobs_response.get("total_count") != len(jobs):
        raise ValueError("GitHub API returned incomplete workflow jobs")
    receipt = {
        "schema_version": 1,
        "kind": "cross_platform_ci",
        "repository": repository,
        "workflow_path": workflow_path,
        "source_commit": source_commit,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "jobs_run_id": run_id,
        "jobs_run_attempt": run_attempt,
        "workflow": dict(workflow),
        "run": dict(run),
        "jobs": jobs,
    }
    reasons = validate_ci_receipt(receipt, repository=repository, workflow_path=workflow_path, source_commit=source_commit)
    if reasons:
        raise ValueError("invalid GitHub Actions CI evidence: " + ", ".join(reasons))
    return receipt


def build_ci_artifact(receipt: Mapping[str, Any], *, source_manifest_sha256: str) -> dict[str, Any]:
    """Envelope a validated native receipt for the frozen evidence reducer."""
    repository = receipt.get("repository")
    workflow_path = receipt.get("workflow_path")
    source_commit = receipt.get("source_commit")
    if not isinstance(repository, str) or not isinstance(workflow_path, str) or not isinstance(source_commit, str) or not _SHA256.fullmatch(source_manifest_sha256):
        raise ValueError("invalid CI evidence artifact identity")
    reasons = validate_ci_receipt(
        receipt, repository=repository, workflow_path=workflow_path, source_commit=source_commit
    )
    if reasons:
        raise ValueError("invalid GitHub Actions CI evidence: " + ", ".join(reasons))
    return {
        "schema_version": 1,
        "kind": "cross_platform_ci",
        "producer": "ci_evidence.py",
        "producer_version": "1",
        "authority": "trusted_coordinator",
        "tested_source_manifest_sha256": source_manifest_sha256,
        "tested_revision": source_commit,
        "invocation_id": f"actions:{receipt['run_id']}:{receipt['run_attempt']}",
        "result": "passed",
        "limitations": [],
        "payload": dict(receipt),
    }


def main(argv: Sequence[str] | None = None) -> int:
    """Write a new receipt from read-only GitHub API calls; never overwrite one."""
    parser = ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest="command", required=True)
    capture = command.add_parser("capture")
    capture.add_argument("--repository", required=True)
    capture.add_argument("--workflow-path", required=True)
    capture.add_argument("--source-commit", required=True)
    capture.add_argument("--run-id", required=True, type=int)
    capture.add_argument("--run-attempt", required=True, type=int)
    capture.add_argument("--source-manifest-sha256", required=True)
    capture.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        receipt = capture_ci_receipt(
            repository=args.repository, workflow_path=args.workflow_path,
            source_commit=args.source_commit, run_id=args.run_id,
            run_attempt=args.run_attempt,
        )
        artifact = build_ci_artifact(receipt, source_manifest_sha256=args.source_manifest_sha256)
        with args.output.open("x", encoding="utf-8") as handle:
            json.dump(artifact, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"ci evidence capture failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":  # pragma: no cover - covered through main()
    raise SystemExit(main())
