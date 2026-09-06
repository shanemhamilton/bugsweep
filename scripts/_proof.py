"""Fail-closed v1 validation for executable fix proof receipts."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import uuid
from pathlib import Path
from typing import Any, Mapping

try:  # Supports both `python -m scripts._proof` and shell entrypoint execution.
    from scripts._check_results import compare_check_results, parse_junit
except ModuleNotFoundError:  # pragma: no cover - exercised by shell entrypoint
    from _check_results import compare_check_results, parse_junit


_HASH_LENGTH = 64


def _canonical_sha256(value: Mapping[str, Any]) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")
    ).hexdigest()


def _sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _valid_hash(value: Any) -> bool:
    return isinstance(value, str) and len(value) == _HASH_LENGTH and all(ch in "0123456789abcdef" for ch in value)


def _result(receipt: Mapping[str, Any] | Any, reasons: list[str]) -> dict[str, Any]:
    receipt_sha256 = _canonical_sha256(receipt) if isinstance(receipt, Mapping) else None
    return {
        "complete": not reasons,
        "status": "verified" if not reasons else "proof_error",
        "reasons": reasons,
        "receipt_sha256": receipt_sha256,
    }


def _source_map(value: Any) -> dict[str, str] | None:
    if not isinstance(value, Mapping) or not value:
        return None
    result = dict(value)
    return result if all(isinstance(path, str) and path and _valid_hash(digest) for path, digest in result.items()) else None


def _trusted_execution(value: Any, source_files: Mapping[str, str]) -> bool:
    if not isinstance(value, Mapping) or value.get("termination") != "exited":
        return False
    backend, capabilities = value.get("backend"), value.get("capabilities")
    manifest = _canonical_sha256(source_files)
    identity = value.get("source_identity")
    return (
        isinstance(backend, Mapping)
        and backend.get("name") == "docker"
        and _valid_hash(backend.get("engine_sha256"))
        and _valid_hash(backend.get("image_digest"))
        and isinstance(value.get("backend_readback_path"), str)
        and _valid_hash(value.get("backend_readback_sha256"))
        and value.get("backend_readback_verified") is True
        and isinstance(capabilities, Mapping)
        and capabilities.get("isolation") == "verified"
        and capabilities.get("network") == "verified_denied"
        and capabilities.get("deadline") == "process_group_term_kill_reap"
        and capabilities.get("output_import") == "trusted_side"
        and capabilities.get("evidence_tier") == "verified_backend"
        and isinstance(identity, Mapping)
        and identity.get("kind") == "content-manifest-sha256"
        and identity.get("source_file_sha256") == dict(sorted(source_files.items()))
        and identity.get("sha256") == manifest
        and value.get("source_manifest_sha256") == manifest
    )


def _execution_reason(value: Any, source_files: Mapping[str, str]) -> str:
    if isinstance(value, Mapping) and isinstance(value.get("capabilities"), Mapping):
        capabilities = value["capabilities"]
        if capabilities.get("isolation") == "configured_unverified" or capabilities.get("network") == "configured_denied_unverified":
            return "execution_isolation_unverified"
    return "execution_receipt_invalid"


def _provider_execution_reasons(value: Any, source_files: Mapping[str, str]) -> list[str]:
    """Delegate live receipt and inspect validation to the shared provider."""
    if not isinstance(value, Mapping):
        return ["execution_receipt_invalid"]
    try:
        from scripts._execution import validate_execution_receipt
        reasons = validate_execution_receipt(value, source_files)
    except (ImportError, OSError, TypeError, ValueError):
        return ["execution_validator_unavailable"]
    if not isinstance(reasons, list) or not all(isinstance(reason, str) for reason in reasons):
        return ["execution_validator_invalid"]
    return [f"execution_{reason}" for reason in reasons]


def validate_check_names(records: list[Mapping[str, Any]]) -> list[str]:
    names = [item.get("check") for item in records]
    if not all(isinstance(name, str) and name for name in names):
        return ["invalid_check_name"]
    return [f"duplicate_check:{name}" for name in sorted({name for name in names if names.count(name) > 1})]


def validate_artifact_digests(receipt: Mapping[str, Any], root: Path | str) -> list[str]:
    """Verify receipt-declared private artifacts without following paths outside its run."""
    base = Path(root).resolve()
    reasons: list[str] = []
    for phase in ("before", "after"):
        record = receipt.get(phase)
        if not isinstance(record, Mapping):
            continue
        for kind in ("structured_report", "log"):
            raw_path, expected = record.get(f"{kind}_path"), record.get(f"{kind}_sha256")
            if not isinstance(raw_path, str) or not raw_path:
                reasons.append(f"missing_{phase}_{kind}_path")
                continue
            path = (base / raw_path).resolve()
            if base not in path.parents or not path.is_file():
                reasons.append(f"missing_{phase}_{kind}")
                continue
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                reasons.append(f"tampered_{phase}_{kind}")
        execution = record.get("execution")
        if isinstance(execution, Mapping):
            raw_readback, expected_readback = execution.get("backend_readback_path"), execution.get("backend_readback_sha256")
            readback = Path(raw_readback).resolve() if isinstance(raw_readback, str) and Path(raw_readback).is_absolute() else (base / raw_readback).resolve() if isinstance(raw_readback, str) else None
            if readback is None or base not in readback.parents or not readback.is_file():
                reasons.append(f"missing_{phase}_backend_readback")
            elif _sha256_file(readback) != expected_readback:
                reasons.append(f"tampered_{phase}_backend_readback")
            else:
                try:
                    readback_data = json.loads(readback.read_text(encoding="utf-8"))
                    analysis = readback_data["analysis"]
                    config, host, network, mounts = analysis["Config"], analysis["HostConfig"], analysis["NetworkSettings"], analysis["Mounts"]
                    command = execution["command"]
                    valid = (
                        isinstance(command, list) and command
                        and config.get("Entrypoint") == [command[0]] and config.get("Cmd") == command[1:]
                        and host.get("Privileged") is False and host.get("ReadonlyRootfs") is True
                        and host.get("NetworkMode") == "none" and network.get("Networks") in ({}, None)
                        and isinstance(mounts, list) and {mount.get("Destination") for mount in mounts if isinstance(mount, Mapping)} == {"/workspace", "/bugsweep-output"}
                    )
                    if not valid:
                        raise ValueError("unsafe inspect")
                except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                    reasons.append(f"invalid_{phase}_backend_readback")
    raw_suite, expected_suite = receipt.get("suite_receipt_path"), receipt.get("suite_receipt_sha256")
    if not isinstance(raw_suite, str) or not raw_suite:
        reasons.append("missing_suite_receipt_path")
    else:
        suite = (base / raw_suite).resolve()
        if base not in suite.parents or not suite.is_file():
            reasons.append("missing_suite_receipt")
        elif hashlib.sha256(suite.read_bytes()).hexdigest() != expected_suite:
            reasons.append("tampered_suite_receipt")
    return reasons


def validate_fix_proof(
    receipt: Mapping[str, Any] | Any,
    expected_run: str,
    expected_bug: str,
    current_source_digests: Mapping[str, str] | Any,
) -> dict[str, Any]:
    """Validate only immutable v1 executable evidence. Legacy is readable, never eligible."""
    if not isinstance(receipt, Mapping):
        return _result(receipt, ["malformed_receipt"])
    reasons: list[str] = []
    if receipt.get("schema_version") != 1:
        reasons.append("unsupported_schema")
    if receipt.get("run_id") != expected_run:
        reasons.append("run_id_mismatch")
    if receipt.get("bug_id") != expected_bug:
        reasons.append("bug_id_mismatch")
    if receipt.get("status") != "verified":
        reasons.append("receipt_not_verified")
    if receipt.get("execution_policy_mode") != "required-untrusted":
        reasons.append("untrusted_execution_required")
    if receipt.get("source_manifest_sha256") != _canonical_sha256(current_source_digests) if isinstance(current_source_digests, Mapping) else True:
        reasons.append("source_manifest_mismatch")
    for key in ("command_sha256", "config_sha256", "environment_sha256", "original_request_sha256", "post_revision_sha256"):
        if not _valid_hash(receipt.get(key)):
            reasons.append(f"invalid_{key}")

    test = receipt.get("test")
    if not isinstance(test, Mapping):
        return _result(receipt, reasons + ["missing_test"])
    native_id = test.get("native_id")
    if not isinstance(native_id, str) or not native_id or not _valid_hash(test.get("sha256")):
        reasons.append("invalid_test_identity")
    expected_type = test.get("expected_failure_type")
    expected_message = test.get("expected_failure_message")
    if expected_type != "assertion" or not isinstance(expected_message, str) or not expected_message:
        reasons.append("invalid_expected_assertion")
    review_sources = _source_map(receipt.get("review_source_file_sha256"))
    if review_sources is None or receipt.get("review_source_manifest_sha256") != _canonical_sha256(review_sources):
        reasons.append("invalid_review_source_identity")

    before, after = receipt.get("before"), receipt.get("after")
    if not isinstance(before, Mapping) or not isinstance(after, Mapping):
        return _result(receipt, reasons + ["missing_before_after"])
    for phase, record, expected_status in (("before", before, "failure"), ("after", after, "pass")):
        outcome = record.get("test_outcome")
        if not isinstance(outcome, Mapping) or outcome.get("native_id") != native_id:
            reasons.append(f"{phase}_native_id")
            continue
        if outcome.get("status") != expected_status:
            reasons.append(f"{phase}_outcome")
        if phase == "before":
            if outcome.get("failure_type") != "assertion":
                reasons.append("before_failure_type")
            message = outcome.get("message")
            if not isinstance(message, str) or expected_message not in message:
                reasons.append("before_failure_message")
            if not isinstance(record.get("exit_code"), int) or record.get("exit_code") == 0:
                reasons.append("before_exit_code")
        elif not isinstance(record.get("exit_code"), int) or record.get("exit_code") != 0:
            reasons.append("after_exit_code")
        for key in ("structured_report_sha256", "log_sha256"):
            if not _valid_hash(record.get(key)):
                reasons.append(f"invalid_{phase}_{key}")
        source_files = _source_map(record.get("source_file_sha256"))
        if source_files is None or not _trusted_execution(record.get("execution"), source_files):
            reasons.append(f"{phase}_{_execution_reason(record.get('execution'), source_files or {})}")
        else:
            reasons.extend(f"{phase}_{reason}" for reason in _provider_execution_reasons(record.get("execution"), source_files))
        execution = record.get("execution")
        if not isinstance(execution, Mapping):
            continue
        for key in ("command_sha256", "config_sha256", "environment_sha256"):
            if execution.get(key) != receipt.get(key):
                reasons.append(f"{phase}_{key}_mismatch")
        test_path = test.get("path")
        if source_files is None or not isinstance(test_path, str) or source_files.get(test_path) != test.get("sha256"):
            reasons.append(f"{phase}_test_sha256_mismatch")

    before_sources = _source_map(before.get("source_file_sha256"))
    after_sources = _source_map(after.get("source_file_sha256"))
    current_sources = _source_map(current_source_digests)
    intended = receipt.get("intended_source_files")
    if not isinstance(intended, list) or not intended or not all(isinstance(path, str) and path for path in intended):
        reasons.append("invalid_intended_source_files")
    elif len(set(intended)) != len(intended):
        reasons.append("duplicate_intended_source_files")
    elif before_sources is None or after_sources is None:
        reasons.append("missing_source_digests")
    else:
        changed = sorted(path for path in set(before_sources) | set(after_sources) if before_sources.get(path) != after_sources.get(path))
        if changed != sorted(intended):
            reasons.append("unintended_source_change")
    if after_sources is None or current_sources is None or after_sources != current_sources:
        reasons.append("current_source_mismatch")
    if before_sources is not None and review_sources is not None:
        test_path = test.get("path")
        for path, digest in review_sources.items():
            if path != test_path and before_sources.get(path) != digest:
                reasons.append("review_source_mismatch")
                break
    suite_path, suite_sha = receipt.get("suite_receipt_path"), receipt.get("suite_receipt_sha256")
    if not isinstance(suite_path, str) or not suite_path or not _valid_hash(suite_sha):
        reasons.append("missing_suite_receipt_binding")
    return _result(receipt, list(dict.fromkeys(reasons)))


def validate_fix_reverification(
    receipt: Mapping[str, Any] | Any,
    original_proof: Mapping[str, Any] | Any,
    expected_run: str,
    expected_bug: str,
    current_source_digests: Mapping[str, str] | Any,
) -> dict[str, Any]:
    """Validate final-tree evidence without changing an immutable red-to-green proof."""
    if not isinstance(receipt, Mapping) or not isinstance(original_proof, Mapping):
        return _result(receipt, ["malformed_reverification"])
    original_after = original_proof.get("after")
    original_sources = _source_map(original_after.get("source_file_sha256")) if isinstance(original_after, Mapping) else None
    original_result = validate_fix_proof(original_proof, expected_run, expected_bug, original_sources)
    current_sources = _source_map(current_source_digests)
    reasons = [] if original_result["complete"] else ["original_proof_invalid"]
    if receipt.get("schema_version") != 1 or receipt.get("event") != "fix_reverified":
        reasons.append("invalid_reverification_schema")
    if receipt.get("run_id") != expected_run or receipt.get("bug_id") != expected_bug:
        reasons.append("reverification_identity_mismatch")
    if receipt.get("status") != "verified":
        reasons.append("reverification_not_verified")
    if receipt.get("original_proof_path") != f"proofs/{expected_bug}.json":
        reasons.append("original_proof_path_mismatch")
    if receipt.get("original_proof_sha256") != _canonical_sha256(original_proof):
        reasons.append("original_proof_sha256_mismatch")
    if receipt.get("original_source_manifest_sha256") != (original_proof.get("source_manifest_sha256")):
        reasons.append("original_source_manifest_mismatch")
    commit = receipt.get("original_fix_commit")
    if not isinstance(commit, str) or len(commit) not in {40, 64} or any(ch not in "0123456789abcdef" for ch in commit):
        reasons.append("invalid_original_fix_commit")
    if current_sources is None or receipt.get("final_source_file_sha256") != current_sources:
        reasons.append("final_source_mismatch")
    elif receipt.get("final_source_manifest_sha256") != _canonical_sha256(current_sources):
        reasons.append("final_source_manifest_mismatch")
    if receipt.get("test") != original_proof.get("test"):
        reasons.append("reverification_test_mismatch")
    after = receipt.get("after")
    if not isinstance(after, Mapping):
        reasons.append("missing_reverification_execution")
    else:
        execution = after.get("execution")
        if current_sources is None or not _trusted_execution(execution, current_sources):
            reasons.append(_execution_reason(execution, current_sources or {}))
        else:
            reasons.extend(_provider_execution_reasons(execution, current_sources))
        if after.get("source_file_sha256") != current_sources:
            reasons.append("reverification_execution_source_mismatch")
        outcome = after.get("test_outcome")
        test = receipt.get("test")
        if not isinstance(outcome, Mapping) or not isinstance(test, Mapping) or outcome.get("native_id") != test.get("native_id") or outcome.get("status") != "pass":
            reasons.append("reverification_test_not_green")
        if after.get("exit_code") != 0:
            reasons.append("reverification_exit_code")
        for key in ("command_sha256", "config_sha256", "environment_sha256"):
            if not _valid_hash(receipt.get(key)) or not isinstance(execution, Mapping) or receipt.get(key) != execution.get(key) or receipt.get(key) != original_proof.get(key):
                reasons.append(f"reverification_{key}_mismatch")
    suite_path, suite_sha = receipt.get("suite_receipt_path"), receipt.get("suite_receipt_sha256")
    if not isinstance(suite_path, str) or not suite_path or not _valid_hash(suite_sha):
        reasons.append("missing_suite_receipt_binding")
    return _result(receipt, list(dict.fromkeys(reasons)))


def _inside(root: Path, relative: str) -> Path | None:
    candidate = (root / relative).resolve()
    return candidate if root == candidate or root in candidate.parents else None


def _digest_sources(root: Path, expected: Mapping[str, Any]) -> dict[str, str] | None:
    result: dict[str, str] = {}
    for relative in expected:
        if not isinstance(relative, str) or not relative:
            return None
        path = _inside(root, relative)
        if path is None or not path.is_file():
            return None
        result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def _policy_for_source(policy: Mapping[str, Any], source_files: Mapping[str, str]) -> dict[str, Any]:
    """Use the coordinator's full externally trusted source manifest unchanged."""
    identity = policy.get("source_identity")
    if not isinstance(identity, Mapping):
        raise ValueError("missing trusted source identity")
    if identity.get("source_file_sha256") != dict(sorted(source_files.items())):
        raise ValueError("request source map does not match trusted full manifest")
    if identity.get("sha256") != _canonical_sha256(source_files):
        raise ValueError("trusted source manifest hash mismatch")
    return dict(policy)


def _stable_policy(policy: Any) -> dict[str, Any] | None:
    if not isinstance(policy, Mapping):
        return None
    return {key: value for key, value in policy.items() if key != "source_identity"}


def _stable_check_plan(request: Mapping[str, Any]) -> dict[str, Any]:
    result = dict(request)
    result.pop("source_file_sha256", None)
    policy = _stable_policy(result.get("execution_policy"))
    result["execution_policy"] = policy
    return result


def _validate_post_request(original: Mapping[str, Any], post: Any, bug_id: str) -> list[str]:
    if not isinstance(post, Mapping):
        return ["malformed_post_request"]
    reasons: list[str] = []
    for key in ("run_id", "target_root", "command", "test", "intended_source_files", "deadline_epoch", "junit_path", "review_source_file_sha256", "review_source_manifest_sha256"):
        if post.get(key) != original.get(key):
            reasons.append(f"post_{key}_mismatch")
    if original.get("bug_id") != bug_id or post.get("bug_id") != bug_id:
        reasons.append("post_bug_id_mismatch")
    if _stable_policy(post.get("before_execution_policy")) != _stable_policy(original.get("before_execution_policy")):
        reasons.append("post_before_policy_mismatch")
    if _stable_policy(post.get("after_execution_policy")) != _stable_policy(original.get("before_execution_policy")):
        reasons.append("post_stable_policy_mismatch")
    source = _source_map(post.get("source_file_sha256"))
    after_policy = post.get("after_execution_policy")
    if source is None or not isinstance(after_policy, Mapping):
        reasons.append("post_missing_after_source")
    else:
        try:
            _policy_for_source(after_policy, source)
        except ValueError:
            reasons.append("post_after_source_mismatch")
    suite = post.get("suite_receipt")
    if not isinstance(suite, Mapping) or set(suite) != {"immutable_path", "immutable_sha256"}:
        reasons.append("post_missing_suite_pointer")
    return reasons


def _relative_artifact(run_dir: Path, raw: Any) -> str | None:
    if not isinstance(raw, str):
        return None
    path = Path(raw).resolve()
    if run_dir not in path.parents or not path.is_file():
        return None
    return str(path.relative_to(run_dir))


def _receipt_output(receipt: Mapping[str, Any], kind: str) -> str | None:
    for output in receipt.get("outputs", []):
        if isinstance(output, Mapping) and output.get("kind") == kind:
            path = output.get("path")
            if isinstance(path, str):
                return path
    path = receipt.get(f"{kind}_path")
    return path if isinstance(path, str) else None


def _proof_error_file(run_dir: Path, bug_id: str, reasons: list[str]) -> int:
    state = run_dir / "proofs" / f"{bug_id}.json"
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({"schema_version": 1, "run_id": run_dir.name, "bug_id": bug_id, "status": "proof_error", "reasons": reasons}, sort_keys=True), encoding="utf-8")
    print("REPRO=proof_error")
    return 1


def _append_fix_reverified_event(run_dir: Path, receipt_path: Path, receipt: Mapping[str, Any]) -> dict[str, Any]:
    """Atomically append the coordinator-owned closeout binding for one receipt."""
    event = {
        "schema_version": 1,
        "event": "fix_reverified",
        "run_id": receipt["run_id"],
        "bug_id": receipt["bug_id"],
        "path": str(receipt_path.relative_to(run_dir)),
        "sha256": _sha256_file(receipt_path),
        "original_fix_commit": receipt["original_fix_commit"],
    }
    raw = json.dumps(event, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8") + b"\n"
    ledger = run_dir / "ledger.jsonl"
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(ledger, flags, 0o600)
    try:
        if os.write(fd, raw) != len(raw):
            raise OSError("short ledger append")
        os.fsync(fd)
    finally:
        os.close(fd)
    directory_fd = os.open(run_dir, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return event


def _run_repro(phase: str, run_dir: Path, bug_id: str, request_path: Path | None) -> int:
    """Run a structured repro only through the externally trusted execution provider."""
    if phase not in {"pre", "post", "reverify"} or "/" in bug_id or ".." in bug_id:
        return _proof_error_file(run_dir, bug_id.replace("/", "_"), ["invalid_bug_id"])
    state_path = run_dir / "proofs" / f"{bug_id}.json"
    prestate_path = run_dir / "proofs" / f"{bug_id}.prestate.json"
    state_path.parent.mkdir(parents=True, exist_ok=True)
    def fail(reasons: list[str]) -> int:
        # A final proof is immutable: later malformed/reverification calls may
        # report failure but must never replace its original red-to-green data.
        if phase in {"post", "reverify"} and state_path.is_file():
            print("REPRO=proof_error")
            return 1
        return _proof_error_file(run_dir, bug_id, reasons)
    try:
        if phase == "pre":
            if request_path is None:
                return fail(["legacy_raw_command"])
            request = json.loads(request_path.read_text(encoding="utf-8"))
            original_request = request
        else:
            state = json.loads(prestate_path.read_text(encoding="utf-8"))
            original_request = state["request"]
            if request_path is None:
                return fail(["missing_post_request"])
            request = json.loads(request_path.read_text(encoding="utf-8"))
    except (OSError, KeyError, json.JSONDecodeError):
        return fail(["missing_request"])
    if not isinstance(request, Mapping):
        return fail(["malformed_request"])
    if request.get("bug_id") != bug_id:
        return fail(["request_bug_id_mismatch"])
    if phase in {"post", "reverify"}:
        post_errors = _validate_post_request(original_request, request, bug_id)
        if post_errors:
            return fail(post_errors)
    if phase == "post" and state_path.exists():
        return fail(["post_already_recorded"])
    target_root = request.get("target_root")
    command = request.get("command")
    policy = request.get("before_execution_policy" if phase == "pre" else "after_execution_policy")
    deadline = request.get("deadline_epoch")
    test, source = request.get("test"), request.get("source_file_sha256")
    junit_path = request.get("junit_path")
    if not isinstance(target_root, str) or not isinstance(command, list) or not isinstance(policy, Mapping) or not isinstance(deadline, (int, float)) or not isinstance(test, Mapping) or not isinstance(source, Mapping) or not isinstance(junit_path, str):
        return fail(["malformed_request"])
    root = Path(target_root).resolve()
    current_sources = _digest_sources(root, source)
    test_path = _inside(root, str(test.get("path", "")))
    if current_sources is None or test_path is None or not test_path.is_file() or hashlib.sha256(test_path.read_bytes()).hexdigest() != test.get("sha256"):
        return fail(["source_or_test_changed"])
    if phase == "pre" and current_sources != source:
        return fail(["source_changed_before_repro"])
    execution_dir = run_dir / "fix-proof-artifacts" / bug_id / f"{phase}-{uuid.uuid4().hex}"
    try:
        from scripts._execution import run_command
        execution = run_command(command, root, execution_dir, float(deadline), _policy_for_source(policy, current_sources), predeclared_outputs=({"path": junit_path, "kind": "junit", "max_bytes": 10_000_000},))
    except (ImportError, ValueError, OSError) as exc:
        return fail([f"execution_error:{type(exc).__name__}"])
    if not isinstance(execution, Mapping) or not _trusted_execution(execution, current_sources):
        return fail([_execution_reason(execution, current_sources)])
    if _digest_sources(root, current_sources) != current_sources:
        return fail(["source_changed_during_execution"])
    report = _receipt_output(execution, "junit")
    log = _receipt_output(execution, "stdout")
    report_relative, log_relative = _relative_artifact(run_dir, report), _relative_artifact(run_dir, log)
    if report_relative is None or log_relative is None:
        return fail(["missing_execution_artifact"])
    parsed = parse_junit(run_dir / report_relative)
    native_id = test.get("native_id")
    detail = parsed.get("details", {}).get(native_id, {}) if isinstance(parsed.get("details"), Mapping) else {}
    outcome = {"native_id": native_id, "status": parsed.get("tests", {}).get(native_id), "failure_type": detail.get("failure_type"), "message": detail.get("message")}
    phase_record = {
        "source_file_sha256": current_sources,
        "exit_code": execution.get("exit_code"),
        "test_outcome": outcome,
        "structured_report_path": report_relative,
        "structured_report_sha256": hashlib.sha256((run_dir / report_relative).read_bytes()).hexdigest(),
        "log_path": log_relative,
        "log_sha256": hashlib.sha256((run_dir / log_relative).read_bytes()).hexdigest(),
        "execution": execution,
    }
    if phase == "pre":
        state = {"request": request, "original_request_sha256": _canonical_sha256(request), "before": phase_record, "schema_version": 1, "run_id": request.get("run_id"), "bug_id": bug_id, "status": "pending"}
        prestate_path.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
        if parsed.get("status") != "ok" or outcome["status"] != "failure" or outcome["failure_type"] != "assertion" or test.get("expected_failure_message") not in (outcome["message"] or ""):
            return fail(["before_not_expected_assertion"])
        print("REPRO=red_confirmed")
        return 0
    try:
        suite_pointer = request["suite_receipt"]
        suite_relative = suite_pointer["immutable_path"]
        suite_path = _inside(run_dir, suite_relative)
        suite_sha = suite_pointer["immutable_sha256"]
        if suite_path is None or not suite_path.is_file() or _sha256_file(suite_path) != suite_sha:
            raise ValueError("invalid suite pointer")
        suite_receipt = json.loads(suite_path.read_text(encoding="utf-8"))
        if not validate_suite_receipt(suite_receipt, request.get("run_id"), current_sources)["complete"]:
            raise ValueError("invalid suite receipt")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return fail(["missing_suite_receipt_binding"])
    if phase == "reverify":
        try:
            original_proof = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return fail(["missing_original_proof"])
        original_after = original_proof.get("after") if isinstance(original_proof, Mapping) else None
        original_sources = _source_map(original_after.get("source_file_sha256")) if isinstance(original_after, Mapping) else None
        if original_sources is None:
            return fail(["missing_original_source"])
        reverified = {
            "schema_version": 1, "event": "fix_reverified", "run_id": request.get("run_id"), "bug_id": bug_id,
            "original_proof_path": str(state_path.relative_to(run_dir)), "original_proof_sha256": _canonical_sha256(original_proof),
            "original_fix_commit": request.get("original_fix_commit"),
            "original_source_manifest_sha256": original_proof.get("source_manifest_sha256"),
            "final_source_file_sha256": current_sources, "final_source_manifest_sha256": _canonical_sha256(current_sources),
            "command_sha256": execution.get("command_sha256"), "config_sha256": execution.get("config_sha256"),
            "environment_sha256": execution.get("environment_sha256"), "test": test,
            "suite_receipt_path": suite_relative, "suite_receipt_sha256": suite_sha,
            "after": phase_record, "status": "verified",
        }
        result = validate_fix_reverification(reverified, original_proof, request.get("run_id"), bug_id, current_sources)
        result["reasons"].extend(f"original_{reason}" for reason in validate_artifact_digests(original_proof, run_dir))
        result["reasons"].extend(validate_artifact_digests(reverified, run_dir))
        if result["reasons"]:
            reverified["status"] = "proof_error"
        output = state_path.with_name(f"{bug_id}.reverified-{uuid.uuid4().hex}.json")
        output.write_text(json.dumps(reverified, sort_keys=True), encoding="utf-8")
        if reverified["status"] == "verified":
            try:
                event = _append_fix_reverified_event(run_dir, output, reverified)
            except (OSError, ValueError, KeyError):
                print("REPRO=proof_error")
                return 1
            print(f"REVERIFY_RECEIPT={output}")
            print(f"REVERIFY_SHA256={event['sha256']}")
            print("REPRO=reverified")
            return 0
        print("REPRO=proof_error")
        return 1
    receipt = {
        "schema_version": 1, "run_id": request.get("run_id"), "bug_id": bug_id,
        "command_sha256": state["before"]["execution"].get("command_sha256"),
        "config_sha256": state["before"]["execution"].get("config_sha256"),
        "environment_sha256": state["before"]["execution"].get("environment_sha256"),
        "test": test, "intended_source_files": request.get("intended_source_files"),
        "execution_policy_mode": policy.get("mode"), "source_manifest_sha256": _canonical_sha256(current_sources),
        "review_source_file_sha256": request.get("review_source_file_sha256"),
        "review_source_manifest_sha256": request.get("review_source_manifest_sha256"),
        "suite_receipt_path": suite_relative, "suite_receipt_sha256": suite_sha,
        "original_request_sha256": state.get("original_request_sha256"),
        "post_revision_sha256": _canonical_sha256(request),
        "before": state.get("before"), "after": phase_record, "status": "verified",
    }
    result = validate_fix_proof(receipt, request.get("run_id"), bug_id, current_sources)
    result["reasons"].extend(validate_artifact_digests(receipt, run_dir))
    if result["reasons"]:
        receipt["status"] = "proof_error"
    state_path.write_text(json.dumps(receipt, sort_keys=True), encoding="utf-8")
    if receipt["status"] == "verified":
        print("REPRO=confirmed")
        return 0
    print("REPRO=proof_error")
    return 1


def validate_suite_receipt(
    receipt: Mapping[str, Any] | Any, expected_run: str, expected_source_digests: Mapping[str, str] | Any
) -> dict[str, Any]:
    """Fail-closed suite evidence gate used by lifecycle before an auto-land."""
    if not isinstance(receipt, Mapping):
        return _result(receipt, ["malformed_suite_receipt"])
    reasons: list[str] = []
    if receipt.get("schema_version") != 1 or receipt.get("phase") != "verify":
        reasons.append("invalid_suite_schema")
    if receipt.get("run_id") != expected_run:
        reasons.append("run_id_mismatch")
    expected_sources = _source_map(expected_source_digests)
    if expected_sources is None or receipt.get("source_file_sha256") != expected_sources:
        reasons.append("current_source_mismatch")
    elif receipt.get("source_manifest_sha256") != _canonical_sha256(expected_sources):
        reasons.append("source_manifest_mismatch")
    checks = receipt.get("checks")
    if not isinstance(checks, list) or not checks:
        reasons.append("no_checks")
    else:
        for check in checks:
            if not isinstance(check, Mapping):
                reasons.append("malformed_check")
                continue
            execution = check.get("execution")
            if check.get("status") != "pass":
                reasons.append("suite_check_not_pass")
            if not isinstance(execution, Mapping) or execution.get("exit_code") != 0:
                reasons.append("suite_execution_not_zero")
            source_files = _source_map(receipt.get("source_file_sha256"))
            if source_files is None or not _trusted_execution(execution, source_files):
                reasons.append(_execution_reason(execution, source_files or {}))
            else:
                reasons.extend(_provider_execution_reasons(execution, source_files))
            for key in ("command_sha256", "config_sha256", "environment_sha256"):
                if not _valid_hash(check.get(key)):
                    reasons.append(f"invalid_{key}")
                elif not isinstance(execution, Mapping) or check.get(key) != execution.get(key):
                    reasons.append(f"check_{key}_mismatch")
    if receipt.get("proof_error") is not False:
        reasons.append("suite_proof_error")
    if receipt.get("execution_policy_mode") != "required-untrusted":
        reasons.append("untrusted_execution_required")
    if receipt.get("regressions") != []:
        reasons.append("suite_regression")
    return _result(receipt, list(dict.fromkeys(reasons)))


def _check_record(run_dir: Path, request: Mapping[str, Any], entry: Mapping[str, Any], index: int) -> dict[str, Any]:
    name, command = entry.get("name"), entry.get("command")
    if not isinstance(name, str) or not name or not isinstance(command, list):
        return {"check": str(name or index), "status": "proof_error", "reason": "malformed_check_plan"}
    target = request.get("target_root")
    policy, deadline = request.get("execution_policy"), request.get("deadline_epoch")
    if not isinstance(target, str) or not isinstance(policy, Mapping) or not isinstance(deadline, (int, float)):
        return {"check": name, "status": "proof_error", "reason": "missing_execution_policy"}
    report_path = entry.get("junit_path")
    declared = () if not isinstance(report_path, str) else ({"path": report_path, "kind": "junit", "max_bytes": 10_000_000},)
    output_dir = run_dir / "check-artifacts" / uuid.uuid4().hex / f"{index}-{name}"
    try:
        from scripts._execution import run_command
        source_files = _digest_sources(Path(target).resolve(), request.get("source_file_sha256", {}))
        if source_files is None:
            return {"check": name, "status": "proof_error", "reason": "missing_source_digests"}
        execution = run_command(command, target, output_dir, float(deadline), _policy_for_source(policy, source_files), predeclared_outputs=declared)
    except (ImportError, ValueError, OSError) as exc:
        return {"check": name, "status": "proof_error", "reason": f"execution_error:{type(exc).__name__}"}
    record: dict[str, Any] = {
        "check": name,
        "status": "proof_error" if execution.get("termination") != "exited" else ("pass" if execution.get("exit_code") == 0 else "fail"),
        "command_sha256": execution.get("command_sha256"),
        "config_sha256": execution.get("config_sha256"), "environment_sha256": execution.get("environment_sha256"),
        "execution": execution,
    }
    source_files = _digest_sources(Path(target).resolve(), request.get("source_file_sha256", {}))
    if source_files is None or not _trusted_execution(execution, source_files):
        record["status"] = "proof_error"
        record["reason"] = _execution_reason(execution, source_files or {})
    elif _digest_sources(Path(target).resolve(), source_files) != source_files:
        record["status"] = "proof_error"
        record["reason"] = "source_changed_during_execution"
    if isinstance(report_path, str):
        report = _receipt_output(execution, "junit")
        parsed = parse_junit(report) if report else {"status": "proof_error", "reasons": ["missing_junit"]}
        record["tests"] = parsed.get("tests", {})
        record["test_details"] = parsed.get("details", {})
        record["structured_status"] = parsed.get("status")
        if parsed.get("status") == "proof_error" or (record["status"] == "pass" and any(v in {"failure", "error"} for v in parsed.get("tests", {}).values())):
            record["status"] = "proof_error"
            record["reason"] = "structured_result_error"
    return record


def _run_checks(phase: str, run_dir: Path) -> int:
    plan_path = run_dir / "check-plan.json"
    try:
        request = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        print("PROOF_ERROR")
        return 1
    if not isinstance(request, Mapping) or not isinstance(request.get("checks"), list) or not request["checks"]:
        print("PROOF_ERROR")
        return 1
    source = request.get("source_file_sha256")
    target = request.get("target_root")
    current = _digest_sources(Path(target).resolve(), source) if isinstance(target, str) and isinstance(source, Mapping) else None
    if current is None:
        print("PROOF_ERROR")
        return 1
    records = [_check_record(run_dir, request, entry, index) if isinstance(entry, Mapping) else {"check": str(index), "status": "proof_error", "reason": "malformed_check_plan"} for index, entry in enumerate(request["checks"])]
    name_errors = validate_check_names(records)
    receipt = {"schema_version": 1, "run_id": request.get("run_id"), "phase": phase, "plan_sha256": _canonical_sha256(_stable_check_plan(request)), "source_file_sha256": current, "source_manifest_sha256": _canonical_sha256(current), "checks": records, "regressions": [], "proof_error": bool(name_errors) or any(item.get("status") == "proof_error" for item in records), "proof_errors": name_errors, "execution_policy_mode": request.get("execution_policy", {}).get("mode") if isinstance(request.get("execution_policy"), Mapping) else None}
    immutable_dir = run_dir / "check-results"
    immutable_dir.mkdir(exist_ok=True)
    immutable = immutable_dir / f"{phase}-{uuid.uuid4().hex}.json"
    destination = run_dir / ("baseline.json" if phase == "baseline" else "check-results-verify.json")
    pointer = {"immutable_path": str(immutable.relative_to(run_dir)), "immutable_sha256": None}
    def persist() -> None:
        immutable.write_text(json.dumps(receipt, sort_keys=True), encoding="utf-8")
        pointer["immutable_sha256"] = _sha256_file(immutable)
        destination.write_text(json.dumps({**receipt, **pointer}, sort_keys=True), encoding="utf-8")
    if phase == "verify":
        (run_dir / "source-digests.json").write_text(json.dumps(current, sort_keys=True), encoding="utf-8")
    if phase == "baseline":
        persist()
        if receipt["proof_error"]:
            print("PROOF_ERROR")
            return 1
        print(f"BASELINE_OVERALL={sum(item.get('status') != 'pass' for item in records)}")
        return 0
    try:
        baseline = json.loads((run_dir / "baseline.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        print("PROOF_ERROR")
        return 1
    if baseline.get("plan_sha256") != receipt["plan_sha256"]:
        receipt["proof_error"] = True
        receipt["proof_errors"] = ["stable_check_plan_mismatch"]
        persist()
        print("PROOF_ERROR")
        return 1
    baseline_records = [item for item in baseline.get("checks", []) if isinstance(item, Mapping)]
    baseline_name_errors = validate_check_names(baseline_records)
    if name_errors or baseline_name_errors:
        receipt["proof_error"] = True
        receipt["proof_errors"] = [*name_errors, *baseline_name_errors]
        persist()
        print("PROOF_ERROR")
        return 1
    before = {item["check"]: item for item in baseline_records}
    regressions: list[str] = []
    proof_error = False
    for current_record in records:
        old = before.get(current_record.get("check"))
        if old is None:
            proof_error = True
            continue
        compared = compare_check_results(old, current_record)
        regressions.extend(compared.get("regressions", []))
        proof_error |= compared.get("status") == "proof_error" or current_record.get("status") == "proof_error"
    if set(before) != {item["check"] for item in records}:
        proof_error = True
    receipt["regressions"] = sorted(set(regressions))
    receipt["proof_error"] = proof_error
    persist()
    if proof_error:
        print("PROOF_ERROR")
        return 1
    if regressions:
        print("REGRESSION")
        return 1
    print("OK")
    return 0


def _main(argv: list[str]) -> int:
    if len(argv) >= 5 and argv[1] == "repro" and argv[2] in {"pre", "post", "reverify"}:
        request = Path(argv[5]) if len(argv) == 6 else None
        return _run_repro(argv[2], Path(argv[3]), argv[4], request)
    if len(argv) == 4 and argv[1] == "checks" and argv[2] in {"baseline", "verify"}:
        return _run_checks(argv[2], Path(argv[3]))
    if len(argv) != 6 or argv[1] != "validate":
        print("usage: _proof.py validate <receipt.json> <run_id> <bug_id> <source-digests.json>", file=sys.stderr)
        return 2
    try:
        receipt = json.loads(Path(argv[2]).read_text(encoding="utf-8"))
        current = json.loads(Path(argv[5]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(json.dumps({"complete": False, "status": "proof_error", "reasons": [f"read_error:{type(exc).__name__}"]}))
        return 1
    result = validate_fix_proof(receipt, argv[3], argv[4], current)
    receipt_path = Path(argv[2]).resolve()
    run_dir = receipt_path.parent.parent if receipt_path.parent.name == "proofs" else receipt_path.parent
    artifact_reasons = validate_artifact_digests(receipt, run_dir) if isinstance(receipt, Mapping) else []
    if artifact_reasons:
        result["complete"] = False
        result["status"] = "proof_error"
        result["reasons"] = list(dict.fromkeys([*result["reasons"], *artifact_reasons]))
    print(json.dumps(result, sort_keys=True))
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
