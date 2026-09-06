"""The v1 executable-fix proof eligibility gate is pure and fail-closed."""

from __future__ import annotations

import copy
import hashlib
import json
import sys
import types
from pathlib import Path

import jsonschema
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from scripts._proof import _canonical_sha256, _check_record, _policy_for_source, _run_repro, _stable_check_plan, _validate_post_request, validate_artifact_digests, validate_check_names, validate_fix_proof, validate_suite_receipt


def _sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


@pytest.fixture(autouse=True)
def _mock_shared_execution_validator(monkeypatch):
    """Proof tests exercise their own receipt boundaries with a pure provider stub."""
    import scripts._execution as execution_provider

    monkeypatch.setattr(execution_provider, "validate_execution_receipt", lambda receipt, source, required_network="denied": [])


def _execution(source: dict[str, str], *, configured_only: bool = False) -> dict:
    manifest = hashlib.sha256(json.dumps(source, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    readback = _readback()
    return {
        "termination": "exited", "command": ["cmd"], "command_sha256": _sha("cmd"), "config_sha256": _sha("cfg"), "environment_sha256": _sha("env"),
        "backend": {"name": "docker", "engine_sha256": _sha("engine"), "image_digest": _sha("image")},
        "backend_readback_path": "readback.json", "backend_readback_sha256": _sha256_json(readback), "backend_readback_verified": True,
        "capabilities": {"isolation": "configured_unverified" if configured_only else "verified", "network": "configured_denied_unverified" if configured_only else "verified_denied", "deadline": "process_group_term_kill_reap", "output_import": "trusted_side", "evidence_tier": "configuration_only" if configured_only else "verified_backend"},
        "source_identity": {"kind": "content-manifest-sha256", "sha256": manifest, "source_file_sha256": source},
        "source_manifest_sha256": manifest,
    }


def _sha256_json(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")).hexdigest()


def _readback() -> dict:
    return {
        "schema_version": 1, "kind": "docker-inspect-readback",
        "analysis": {
            "Config": {"Entrypoint": ["cmd"], "Cmd": []},
            "HostConfig": {"Privileged": False, "ReadonlyRootfs": True, "NetworkMode": "none"},
            "NetworkSettings": {"Networks": {}},
            "Mounts": [{"Destination": "/workspace"}, {"Destination": "/bugsweep-output"}],
        },
    }


def _policy(source: dict[str, str]) -> dict:
    return {
        "mode": "required-untrusted",
        "source_identity": {
            "kind": "content-manifest-sha256",
            "sha256": hashlib.sha256(json.dumps(source, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")).hexdigest(),
            "source_file_sha256": source,
        },
    }


def _suite_receipt(source: dict[str, str]) -> dict:
    return {
        "schema_version": 1, "run_id": "run-1", "phase": "verify",
        "source_file_sha256": source, "source_manifest_sha256": _sha256_json(source),
        "proof_error": False, "regressions": [], "execution_policy_mode": "required-untrusted",
        "checks": [{
            "status": "pass", "command_sha256": _sha("cmd"), "config_sha256": _sha("cfg"),
            "environment_sha256": _sha("env"), "execution": {**_execution(source), "exit_code": 0},
        }],
    }


def _receipt() -> dict:
    before = {"src/auth.py": _sha("broken"), "tests/test_auth.py": _sha("test source")}
    after = {"src/auth.py": _sha("fixed"), "tests/test_auth.py": _sha("test source")}
    review = {"src/auth.py": _sha("broken")}
    return {
        "schema_version": 1,
        "run_id": "run-1",
        "bug_id": "BUG-1",
        "command_sha256": _sha("cmd"),
        "config_sha256": _sha("cfg"),
        "environment_sha256": _sha("env"),
        "execution_policy_mode": "required-untrusted",
        "source_manifest_sha256": hashlib.sha256(json.dumps(after, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        "review_source_file_sha256": review,
        "review_source_manifest_sha256": hashlib.sha256(json.dumps(review, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        "suite_receipt_path": "check-results/verify.json",
        "suite_receipt_sha256": _sha("suite receipt"),
        "original_request_sha256": _sha("original request"),
        "post_revision_sha256": _sha("post request"),
        "test": {
            "path": "tests/test_auth.py",
            "native_id": "tests.test_auth::test_denies_bad_token",
            "sha256": _sha("test source"),
            "expected_failure_type": "assertion",
            "expected_failure_message": "denied",
        },
        "intended_source_files": ["src/auth.py"],
        "before": {
            "source_file_sha256": before,
            "exit_code": 1,
            "test_outcome": {"native_id": "tests.test_auth::test_denies_bad_token", "status": "failure", "failure_type": "assertion", "message": "denied"},
            "structured_report_sha256": _sha("before report"),
            "structured_report_path": "before-report.xml",
            "log_sha256": _sha("before log"),
            "log_path": "before.log",
            "execution": _execution(before),
        },
        "after": {
            "source_file_sha256": after,
            "exit_code": 0,
            "test_outcome": {"native_id": "tests.test_auth::test_denies_bad_token", "status": "pass", "failure_type": None, "message": None},
            "structured_report_sha256": _sha("after report"),
            "structured_report_path": "after-report.xml",
            "log_sha256": _sha("after log"),
            "log_path": "after.log",
            "execution": _execution(after),
        },
        "status": "verified",
    }


def test_exact_expected_assertion_red_to_green_is_eligible() -> None:
    receipt = _receipt()
    result = validate_fix_proof(receipt, "run-1", "BUG-1", receipt["after"]["source_file_sha256"])

    assert result["complete"] is True
    assert result["status"] == "verified"
    assert result["reasons"] == []


def test_canonical_digest_matches_provider_for_non_ascii_source_paths() -> None:
    value = {"src/café.py": _sha("fixed")}
    expected = hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")
    ).hexdigest()

    assert _canonical_sha256(value) == expected


def test_v1_receipt_matches_the_published_schema() -> None:
    schema = json.loads((Path(__file__).resolve().parents[3] / "schemas" / "fix-proof.schema.json").read_text(encoding="utf-8"))
    jsonschema.validate(_receipt(), schema)


def test_configuration_only_isolation_cannot_make_red_green_auto_eligible() -> None:
    receipt = _receipt()
    receipt["before"]["execution"] = _execution(receipt["before"]["source_file_sha256"], configured_only=True)
    receipt["after"]["execution"] = _execution(receipt["after"]["source_file_sha256"], configured_only=True)

    result = validate_fix_proof(receipt, "run-1", "BUG-1", receipt["after"]["source_file_sha256"])

    assert result["complete"] is False
    assert "before_execution_isolation_unverified" in result["reasons"]
    assert "after_execution_isolation_unverified" in result["reasons"]


def test_phase_execution_identity_must_match_receipt_hashes_and_test_digest() -> None:
    receipt = _receipt()
    receipt["after"]["execution"]["command_sha256"] = _sha("another command")

    result = validate_fix_proof(receipt, "run-1", "BUG-1", receipt["after"]["source_file_sha256"])

    assert result["complete"] is False
    assert "after_command_sha256_mismatch" in result["reasons"]


def test_reviewed_production_source_must_match_pre_fix_snapshot() -> None:
    receipt = _receipt()
    receipt["review_source_file_sha256"] = {"src/auth.py": _sha("not reviewed source")}
    receipt["review_source_manifest_sha256"] = hashlib.sha256(json.dumps(receipt["review_source_file_sha256"], sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    result = validate_fix_proof(receipt, "run-1", "BUG-1", receipt["after"]["source_file_sha256"])

    assert result["complete"] is False
    assert "review_source_mismatch" in result["reasons"]


def test_request_subset_cannot_replace_trusted_full_source_manifest() -> None:
    full = {"src.py": _sha("source"), "untouched.py": _sha("untouched")}

    with pytest.raises(ValueError, match="full manifest"):
        _policy_for_source(_policy(full), {"src.py": _sha("source")})


def test_post_request_cannot_change_frozen_command_or_review_identity() -> None:
    before = {"src.py": _sha("before")}
    original = {
        "run_id": "run-1", "bug_id": "BUG-1", "target_root": "/target", "command": ["pytest"], "test": {"path": "test.py"},
        "intended_source_files": ["src.py"], "deadline_epoch": 1, "junit_path": "report.xml",
        "review_source_file_sha256": before, "review_source_manifest_sha256": hashlib.sha256(json.dumps(before, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        "before_execution_policy": _policy(before),
    }
    post = {**original, "command": ["other"], "source_file_sha256": {"src.py": _sha("after")}, "after_execution_policy": _policy({"src.py": _sha("after")}), "suite_receipt": {"immutable_path": "check-results/x.json", "immutable_sha256": _sha("suite")}}

    assert "post_command_mismatch" in _validate_post_request(original, post, "BUG-1")


def test_duplicate_check_names_are_proof_errors() -> None:
    assert validate_check_names([{"check": "test"}, {"check": "test"}]) == ["duplicate_check:test"]


def test_nonzero_target_exit_stays_failed_when_junit_is_ok(tmp_path: Path, monkeypatch) -> None:
    target, run = tmp_path / "target", tmp_path / "run"
    target.mkdir(); run.mkdir()
    (target / "src.py").write_text("source", encoding="utf-8")

    def run_command(command, cwd, output_dir, deadline_epoch, policy, **_kwargs):
        output_dir.mkdir(parents=True)
        report = output_dir / "report.xml"
        report.write_text('<testsuite><testcase classname="pkg" name="test_ok" /></testsuite>', encoding="utf-8")
        source = {"src.py": _sha("source")}
        return {"exit_code": 1, **_execution(source), "outputs": [{"kind": "junit", "path": str(report)}]}

    monkeypatch.setitem(sys.modules, "scripts._execution", types.SimpleNamespace(run_command=run_command, validate_execution_receipt=lambda receipt, source, required_network="denied": []))
    source = {"src.py": _sha("source")}
    request = {"target_root": str(target), "execution_policy": _policy(source), "deadline_epoch": 9_999_999_999, "source_file_sha256": source}

    record = _check_record(run, request, {"name": "test", "command": ["pytest"], "junit_path": "report.xml"}, 0)

    assert record["status"] == "fail"


def test_wrong_before_failure_is_proof_error_not_eligibility() -> None:
    receipt = _receipt()
    receipt["before"]["test_outcome"]["failure_type"] = "import"

    result = validate_fix_proof(receipt, "run-1", "BUG-1", receipt["after"]["source_file_sha256"])

    assert result["complete"] is False
    assert result["status"] == "proof_error"
    assert "before_failure_type" in result["reasons"]


def test_timeout_shaped_null_exit_is_proof_error() -> None:
    receipt = _receipt()
    receipt["after"]["exit_code"] = None

    result = validate_fix_proof(receipt, "run-1", "BUG-1", receipt["after"]["source_file_sha256"])

    assert result["complete"] is False
    assert "after_exit_code" in result["reasons"]


def test_tampered_current_source_or_unintended_change_fails_closed() -> None:
    receipt = _receipt()
    receipt["after"]["source_file_sha256"]["src/other.py"] = _sha("surprise")
    current = copy.deepcopy(receipt["after"]["source_file_sha256"])

    result = validate_fix_proof(receipt, "run-1", "BUG-1", current)

    assert result["complete"] is False
    assert "unintended_source_change" in result["reasons"]


def test_legacy_or_unreproduced_record_can_never_become_eligible() -> None:
    receipt = _receipt()
    receipt["schema_version"] = 0
    receipt["status"] = "unreproduced"

    result = validate_fix_proof(receipt, "run-1", "BUG-1", receipt["after"]["source_file_sha256"])

    assert result["complete"] is False
    assert result["status"] == "proof_error"


def test_artifact_hashes_are_bound_to_private_run_paths(tmp_path: Path) -> None:
    receipt = _receipt()
    for phase, payload in (("before", "before report"), ("after", "after report")):
        (tmp_path / receipt[phase]["structured_report_path"]).write_text(payload, encoding="utf-8")
        (tmp_path / receipt[phase]["log_path"]).write_text(f"{phase} log", encoding="utf-8")
    (tmp_path / "readback.json").write_text(
        json.dumps(_readback(), sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False),
        encoding="utf-8",
    )
    suite = tmp_path / receipt["suite_receipt_path"]
    suite.parent.mkdir()
    suite.write_text("suite receipt", encoding="utf-8")

    assert validate_artifact_digests(receipt, tmp_path) == []
    (tmp_path / "after.log").write_text("modified", encoding="utf-8")
    assert validate_artifact_digests(receipt, tmp_path) == ["tampered_after_log"]


def test_readback_inspection_is_verified_not_just_receipt_boolean(tmp_path: Path) -> None:
    receipt = _receipt()
    for phase, payload in (("before", "before report"), ("after", "after report")):
        (tmp_path / receipt[phase]["structured_report_path"]).write_text(payload, encoding="utf-8")
        (tmp_path / receipt[phase]["log_path"]).write_text(f"{phase} log", encoding="utf-8")
    unsafe = _readback()
    unsafe["analysis"]["HostConfig"]["Privileged"] = True
    (tmp_path / "readback.json").write_text(
        json.dumps(unsafe, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False), encoding="utf-8"
    )
    for phase in ("before", "after"):
        receipt[phase]["execution"]["backend_readback_sha256"] = _sha256_json(unsafe)
    suite = tmp_path / receipt["suite_receipt_path"]
    suite.parent.mkdir()
    suite.write_text("suite receipt", encoding="utf-8")

    assert validate_artifact_digests(receipt, tmp_path) == ["invalid_before_backend_readback", "invalid_after_backend_readback"]


def test_reverify_binds_a_multi_fix_final_tree_without_rewriting_original_proof(tmp_path: Path, monkeypatch) -> None:
    target, run = tmp_path / "target", tmp_path / "run"
    target.mkdir(); run.mkdir()
    source, other, test = target / "src.py", target / "other.py", target / "test_src.py"
    source.write_text("broken", encoding="utf-8"); test.write_text("assertion test", encoding="utf-8")
    other.write_text("unfixed", encoding="utf-8")
    calls: list[list[str]] = []

    def run_command(command, cwd, output_dir, deadline_epoch, policy, **_kwargs):
        calls.append(command)
        output_dir.mkdir(parents=True)
        failing = len(calls) == 1
        report = output_dir / "report.xml"; log = output_dir / "stdout.log"
        report.write_text(
            '<testsuite><testcase classname="tests.test_src" name="test_bug">'
            + ('<failure type="AssertionError">denied</failure>' if failing else '')
            + '</testcase></testsuite>', encoding="utf-8")
        log.write_text("log", encoding="utf-8")
        readback = output_dir / "readback.json"; readback.write_text(
            json.dumps(_readback(), sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False),
            encoding="utf-8",
        )
        source_map = {
            "src.py": _sha((cwd / "src.py").read_text(encoding="utf-8")),
            "other.py": _sha((cwd / "other.py").read_text(encoding="utf-8")),
            "test_src.py": _sha((cwd / "test_src.py").read_text(encoding="utf-8")),
        }
        return {"termination": "exited", "exit_code": 1 if failing else 0, **_execution(source_map), "backend_readback_path": str(readback), "outputs": [{"kind": "junit", "path": str(report)}, {"kind": "stdout", "path": str(log)}]}

    monkeypatch.setitem(sys.modules, "scripts._execution", types.SimpleNamespace(run_command=run_command, validate_execution_receipt=lambda receipt, source, required_network="denied": []))
    request = {
        "run_id": "run-1", "bug_id": "BUG-1", "target_root": str(target), "command": ["pytest", "-q"],
        "before_execution_policy": _policy({"src.py": _sha("broken"), "other.py": _sha("unfixed"), "test_src.py": _sha("assertion test")}),
        "after_execution_policy": _policy({"src.py": _sha("fixed"), "other.py": _sha("unfixed"), "test_src.py": _sha("assertion test")}),
        "deadline_epoch": 9999999999,
        "test": {"path": "test_src.py", "native_id": "tests.test_src::test_bug", "sha256": _sha("assertion test"), "expected_failure_type": "assertion", "expected_failure_message": "denied"},
        "source_file_sha256": {"src.py": _sha("broken"), "other.py": _sha("unfixed"), "test_src.py": _sha("assertion test")}, "intended_source_files": ["src.py"], "junit_path": "report.xml",
        "review_source_file_sha256": {"src.py": _sha("broken")},
        "review_source_manifest_sha256": hashlib.sha256(json.dumps({"src.py": _sha("broken")}, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
    }
    request_path = run / "request.json"; request_path.write_text(json.dumps(request), encoding="utf-8")

    assert _run_repro("pre", run, "BUG-1", request_path) == 0
    source.write_text("fixed", encoding="utf-8")
    immutable = run / "check-results" / "verify.json"
    immutable.parent.mkdir()
    post_request_source = {"src.py": _sha("fixed"), "other.py": _sha("unfixed"), "test_src.py": _sha("assertion test")}
    suite_receipt = _suite_receipt(post_request_source)
    immutable.write_text(
        json.dumps(suite_receipt, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False),
        encoding="utf-8",
    )
    post_request = copy.deepcopy(request)
    post_request["source_file_sha256"] = post_request_source
    post_request["suite_receipt"] = {"immutable_path": str(immutable.relative_to(run)), "immutable_sha256": _sha256_json(suite_receipt)}
    post_path = run / "post-request.json"; post_path.write_text(json.dumps(post_request), encoding="utf-8")
    assert _run_repro("post", run, "BUG-1", post_path) == 0
    original_path = run / "proofs" / "BUG-1.json"
    original = json.loads(original_path.read_text(encoding="utf-8"))
    assert original["after"]["source_file_sha256"] == post_request_source
    assert _run_repro("post", run, "BUG-1", post_path) == 1
    assert json.loads(original_path.read_text(encoding="utf-8")) == original

    other.write_text("fixed too", encoding="utf-8")
    final_sources = {"src.py": _sha("fixed"), "other.py": _sha("fixed too"), "test_src.py": _sha("assertion test")}
    final_suite = _suite_receipt(final_sources)
    final_immutable = run / "check-results" / "verify-final.json"
    final_immutable.write_text(json.dumps(final_suite, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False), encoding="utf-8")
    reverify = copy.deepcopy(post_request)
    reverify["source_file_sha256"] = final_sources
    reverify["after_execution_policy"] = _policy(final_sources)
    reverify["suite_receipt"] = {"immutable_path": str(final_immutable.relative_to(run)), "immutable_sha256": _sha256_json(final_suite)}
    reverify["original_fix_commit"] = "a" * 40
    reverify_path = run / "reverify-request.json"; reverify_path.write_text(json.dumps(reverify), encoding="utf-8")
    assert _run_repro("reverify", run, "BUG-1", reverify_path) == 0
    reverified = json.loads(next((run / "proofs").glob("BUG-1.reverified-*.json")).read_text(encoding="utf-8"))
    assert reverified["original_proof_sha256"] == _canonical_sha256(original)
    assert reverified["final_source_file_sha256"] == final_sources
    receipt_path = next((run / "proofs").glob("BUG-1.reverified-*.json"))
    event = json.loads((run / "ledger.jsonl").read_text(encoding="utf-8"))
    assert event == {
        "schema_version": 1, "event": "fix_reverified", "run_id": "run-1", "bug_id": "BUG-1",
        "path": str(receipt_path.relative_to(run)), "sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
        "original_fix_commit": "a" * 40,
    }
    failed = copy.deepcopy(reverify)
    failed["original_fix_commit"] = "not-a-commit"
    failed_path = run / "failed-reverify-request.json"; failed_path.write_text(json.dumps(failed), encoding="utf-8")
    assert _run_repro("reverify", run, "BUG-1", failed_path) == 1
    assert (run / "ledger.jsonl").read_text(encoding="utf-8") == json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
    assert calls == [["pytest", "-q"], ["pytest", "-q"], ["pytest", "-q"], ["pytest", "-q"]]


def test_stable_check_plan_excludes_only_dynamic_source_identity() -> None:
    first = {"source_file_sha256": {"src.py": _sha("before")}, "execution_policy": _policy({"src.py": _sha("before")}), "checks": [{"name": "test", "command": ["pytest"]}]}
    second = {"source_file_sha256": {"src.py": _sha("after")}, "execution_policy": _policy({"src.py": _sha("after")}), "checks": [{"name": "test", "command": ["pytest"]}]}

    assert _stable_check_plan(first) == _stable_check_plan(second)


def test_suite_validator_rejects_existing_or_new_failures() -> None:
    source = {"src.py": _sha("fixed")}
    receipt = {
        "schema_version": 1, "run_id": "run-1", "phase": "verify", "source_file_sha256": source,
        "source_manifest_sha256": hashlib.sha256(json.dumps(source, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        "proof_error": False, "regressions": [], "execution_policy_mode": "required-untrusted",
        "checks": [{"status": "fail", "command_sha256": _sha("cmd"), "config_sha256": _sha("cfg"), "environment_sha256": _sha("env"), "execution": {**_execution(source), "exit_code": 1}}],
    }
    assert validate_suite_receipt(receipt, "run-1", source)["complete"] is False
    receipt["regressions"] = ["new::test"]
    assert validate_suite_receipt(receipt, "run-1", source)["complete"] is False


def test_suite_check_hashes_must_bind_the_execution_receipt() -> None:
    source = {"src.py": _sha("fixed")}
    receipt = _suite_receipt(source)
    receipt["checks"][0]["config_sha256"] = _sha("other config")

    result = validate_suite_receipt(receipt, "run-1", source)

    assert result["complete"] is False
    assert "check_config_sha256_mismatch" in result["reasons"]
