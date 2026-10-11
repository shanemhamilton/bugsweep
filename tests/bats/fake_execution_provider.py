#!/usr/bin/env python3
"""Test-only execution provider for structured Bugsweep Bats coverage.

This driver patches the external provider boundary in-process and then calls
_real_ proof orchestration. It emits receipts labelled ``synthetic-test-only``;
those receipts are deliberately not evidence of Docker isolation. No target
command is executed by this helper.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from scripts import _execution, _proof  # noqa: E402


_ACTIVE: dict[str, Any] = {}


def _sha(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")
    ).hexdigest()


def _sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _readback(command: Sequence[str]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "kind": "docker-inspect-readback",
        "analysis": {
            "Config": {"Entrypoint": [command[0]], "Cmd": list(command[1:])},
            "HostConfig": {"Privileged": False, "ReadonlyRootfs": True, "NetworkMode": "none"},
            "NetworkSettings": {"Networks": {}},
            "Mounts": [{"Destination": "/workspace"}, {"Destination": "/bugsweep-output"}],
        },
    }


def _native_id() -> tuple[str, str]:
    native = _ACTIVE.get("native_id") or "synthetic::test_check"
    if "::" in native:
        return tuple(native.split("::", 1))  # type: ignore[return-value]
    return "synthetic", native


def _fake_run_command(
    command: Sequence[str],
    cwd: str | Path,
    output_dir: str | Path,
    _deadline_epoch: float,
    policy: Mapping[str, Any],
    *,
    predeclared_outputs: Sequence[Mapping[str, Any]] = (),
    **_unused: Any,
) -> dict[str, Any]:
    """Return a structurally valid synthetic receipt without running argv."""
    destination = Path(output_dir)
    destination.mkdir(parents=True, exist_ok=False)
    identity = policy.get("source_identity")
    if not isinstance(identity, Mapping):
        raise ValueError("synthetic provider requires source identity")
    source_files = identity.get("source_file_sha256")
    if not isinstance(source_files, Mapping) or not source_files:
        raise ValueError("synthetic provider requires source files")
    source_files = dict(sorted(source_files.items()))
    manifest = _sha(source_files)
    report_name = "report.xml"
    for declared in predeclared_outputs:
        if isinstance(declared, Mapping) and declared.get("kind") == "junit" and isinstance(declared.get("path"), str):
            report_name = str(declared["path"])
            break
    report = destination / report_name
    log = destination / "stdout.log"
    classname, test_name = _native_id()
    phase = _ACTIVE.get("phase")
    if phase == "repro":
        outcome = os.environ.get("FAKE_REPRO_OUTCOME", "failure")
        is_failure = outcome in {"failure", "fail", "still-red"}
        failure_type = os.environ.get("FAKE_REPRO_FAILURE_KIND", "assertion")
        message = os.environ.get("FAKE_REPRO_FAILURE_MESSAGE", _ACTIVE.get("expected_message", "expected assertion"))
    else:
        outcome = os.environ.get("FAKE_CHECK_OUTCOME", "pass")
        is_failure = outcome in {"failure", "fail", "regression"}
        failure_type = "AssertionError"
        message = "synthetic check failure"
    failure = f'<failure type="{failure_type}">{message}</failure>' if is_failure else ""
    report.write_text(
        f'<testsuite><testcase classname="{classname}" name="{test_name}">{failure}</testcase></testsuite>',
        encoding="utf-8",
    )
    log.write_text("synthetic-test-only\n", encoding="utf-8")
    readback_data = _readback(list(command))
    readback = destination / "readback.json"
    readback.write_text(
        json.dumps(readback_data, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False),
        encoding="utf-8",
    )
    exit_code = 1 if is_failure else 0
    return {
        "schema_version": 1,
        "provider": "synthetic-test-only",
        "termination": "exited",
        "exit_code": exit_code,
        "command": list(command),
        "command_sha256": _sha(list(command)),
        "config_sha256": _sha("synthetic-config"),
        "environment_sha256": _sha("synthetic-environment"),
        "backend": {"name": "docker", "engine_sha256": "e" * 64, "image_digest": "a" * 64},
        "backend_readback_path": str(readback),
        "backend_readback_sha256": _sha_bytes(readback.read_bytes()),
        "backend_readback_verified": True,
        "capabilities": {
            "isolation": "verified",
            "network": "verified_denied",
            "deadline": "process_group_term_kill_reap",
            "output_import": "trusted_side",
            "evidence_tier": "verified_backend",
        },
        "source_identity": {
            "kind": "content-manifest-sha256",
            "sha256": manifest,
            "source_file_sha256": source_files,
        },
        "source_manifest_sha256": manifest,
        "outputs": [
            {"kind": "junit", "path": str(report)},
            {"kind": "stdout", "path": str(log)},
        ],
    }


def _run(action: str, phase: str, run_dir: Path, bug_id: str | None = None, request_path: Path | None = None) -> int:
    if action == "repro":
        if request_path is None or bug_id is None:
            raise SystemExit("repro requires BUG_ID and request path")
        request = json.loads(request_path.read_text(encoding="utf-8"))
        test = request.get("test", {})
        _ACTIVE.clear()
        _ACTIVE.update({
            "phase": "repro",
            "native_id": test.get("native_id"),
            "expected_message": test.get("expected_failure_message"),
        })
        return _proof._run_repro(phase, run_dir, bug_id, request_path)
    if action == "checks":
        _ACTIVE.clear()
        _ACTIVE["phase"] = "checks"
        return _proof._run_checks(phase, run_dir)
    raise SystemExit(f"unknown action: {action}")


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        raise SystemExit("usage: fake_execution_provider.py checks PHASE RUN_DIR | repro PHASE RUN_DIR BUG_ID REQUEST")
    action, phase, run_dir = argv[1], argv[2], Path(argv[3])
    if action == "checks":
        if len(argv) != 4:
            raise SystemExit("usage: fake_execution_provider.py checks PHASE RUN_DIR")
        bug_id = request = None
    else:
        if len(argv) != 6:
            raise SystemExit("usage: fake_execution_provider.py repro PHASE RUN_DIR BUG_ID REQUEST")
        bug_id, request = argv[4], Path(argv[5])
    _execution.run_command, original_run = _fake_run_command, _execution.run_command
    _execution.validate_execution_receipt, original_validate = (lambda *_args, **_kwargs: []), _execution.validate_execution_receipt
    try:
        return _run(action, phase, run_dir, bug_id, request)
    finally:
        _execution.run_command = original_run
        _execution.validate_execution_receipt = original_validate


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
