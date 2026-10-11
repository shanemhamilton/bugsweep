#!/usr/bin/env python3
"""Test-only landed evidence producer using the real proof validators.

The provider boundary is simulated by ``run_command``.  Receipt, suite, fix,
reverification, and review validation remains the production implementation.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts import _execution as execution  # noqa: E402
from scripts import _proof as proof  # noqa: E402
from scripts import _review_evidence as review_evidence  # noqa: E402


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def file_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_from_root(root: Path) -> dict[str, str]:
    return execution._capture_source_files(root, allow_git_pointer=True, allow_symlinks=False)


def _copy_source(root: Path, destination: Path, sources: Mapping[str, str]) -> None:
    destination.mkdir(mode=0o700, exist_ok=True)
    for relative, expected in sources.items():
        source = root / relative
        raw = source.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise RuntimeError(f"source changed while capturing fixture: {relative}")
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(raw)


def _limits() -> dict[str, object]:
    return {
        "wall_clock_seconds": 60,
        "max_turns": 10,
        "max_input_tokens": 1000,
        "max_output_tokens": 1000,
        "max_spend_usd": 1,
        "enforcement": {
            "wall_clock_seconds": "test provider deadline",
            "max_turns": "test provider turn counter",
            "max_input_tokens": "test provider usage",
            "max_output_tokens": "test provider usage",
            "max_spend_usd": "test provider account cap",
        },
    }


def _review_profile(run: Path) -> dict[str, object]:
    trusted = run.parent / "review-provider-trusted"
    trusted.mkdir(mode=0o700, exist_ok=True)
    secret = trusted / "provider-key"
    secret.write_text("synthetic-test-only\n", encoding="utf-8")
    secret.chmod(0o600)
    policy_file = trusted / "proxy-policy.json"
    policy_file.write_text('{"allowed_paths":["/v1/responses"]}\n', encoding="utf-8")
    internal_id, egress_id, proxy_id = (value * 64 for value in "abc")
    proxy_image = "e" * 64
    limits = _limits()
    proxy_receipt = {
        "schema_version": 1,
        "owner": "bench/lib/proxy.sh",
        "host": "codex",
        "internal_network": {"name": "bugsweep-internal-test", "id": internal_id},
        "egress_network": {"name": "bugsweep-egress-test", "id": egress_id},
        "proxy": {"container_name": "bugsweep-proxy-test", "container_id": proxy_id, "image_digest": f"sha256:{proxy_image}"},
        "upstream": {"host": "api.openai.com", "allowed_paths": ["/v1/responses"]},
        "limits": limits,
        "policy": {"mount": "/etc/bugsweep/proxy-policy.json", "sha256": file_digest(policy_file), "nonsecret": True},
        "secret": {"mount": "/run/secrets/provider-key", "mode": "0600", "outside_target_and_results": True},
    }
    proxy_receipt_path = trusted / "proxy-receipt.json"
    proxy_receipt_path.write_bytes(canonical(proxy_receipt))
    return {
        "host": "codex",
        "proxy_receipt": {"path": str(proxy_receipt_path), "sha256": file_digest(proxy_receipt_path), "schema_version": 1, "owner": "bench/lib/proxy.sh"},
        "internal_network": {"name": "bugsweep-internal-test", "id": internal_id},
        "egress_network": {"name": "bugsweep-egress-test", "id": egress_id},
        "proxy": {"container_name": "bugsweep-proxy-test", "container_id": proxy_id, "image_digest": proxy_image},
        "proxy_image_id": f"sha256:{proxy_image}",
        "upstream": {"host": "api.openai.com", "allowed_paths": ["/v1/responses"]},
        "analysis": {"entrypoint": "/usr/local/bin/bench-host-adapter", "entrypoint_sha256": "f" * 64},
        "client": {"inert_credential_literal": "benchmark-inert-client-credential"},
        "arms": {arm: {"skill_revision": f"{arm}-revision", "skill_content_sha256": value * 64} for arm, value in (("current", "1"), ("previous", "2"), ("baseline", "3"))},
        "limits": limits,
        "proxy_policy": {"mount": "/etc/bugsweep/proxy-policy.json", "sha256": file_digest(policy_file), "nonsecret": True},
    }


def _policy(run: Path, target: Path, sources: Mapping[str, str], *, approved: bool, profile: Mapping[str, object] | None = None) -> dict[str, object]:
    policy: dict[str, object] = {
        "schema_version": 1,
        "mode": "required-untrusted",
        "backend": "docker",
        "canonical_engine_path": "/usr/bin/docker",
        "engine_sha256": "a" * 64,
        "image": "bugsweep/test@sha256:" + "c" * 64,
        "target_root": str(target.resolve()),
        "scratch_root": str((run / "scratch").resolve()),
        "source_identity": {"kind": "content-manifest-sha256", "sha256": digest(sources), "source_file_sha256": dict(sorted(sources.items()))},
        "uid": "65534:65534",
        "pids_limit": 64,
        "memory_bytes": 16 * 1024 * 1024,
        "cpus": 1.0,
        "term_grace_seconds": 1,
        "network_mode": "approved-proxy-only" if approved else "none",
        "image_env_allowlist": {},
        "source_mount_mode": "archive-ro" if approved else "worktree-rw",
    }
    if approved:
        policy["benchmark_profile"] = dict(profile or {})
    (run / "scratch").mkdir(mode=0o700, exist_ok=True)
    return policy


def _analysis_readback(policy: Mapping[str, object], target: Path, scratch: Path, command: list[str], container_id: str, container_name: str, environment: Mapping[str, str]) -> dict[str, object]:
    target_env = execution._target_environment(environment, policy["image_env_allowlist"], "/bugsweep-output")
    network_name, network_id = execution._analysis_network(policy, target_env)
    profile = policy.get("benchmark_profile") if isinstance(policy.get("benchmark_profile"), Mapping) else None
    labels: dict[str, object] = {"org.bugsweep.invocation": container_name.removeprefix("bugsweep-")}
    if profile is not None:
        labels.update({"org.bugsweep.adapter.sha256": profile["analysis"]["entrypoint_sha256"], "org.bugsweep.arms.sha256": digest(profile["arms"])})
    source_read_only = policy.get("source_mount_mode") == "archive-ro"
    analysis = {
        "Id": container_id,
        "Name": "/" + container_name,
        "Config": {"Image": policy["image"], "User": policy["uid"], "WorkingDir": "/workspace", "Entrypoint": [command[0]], "Cmd": command[1:], "Labels": labels, "Env": [f"{key}={value}" for key, value in target_env.items()]},
        "HostConfig": {"NetworkMode": network_name, "IpcMode": "none", "Privileged": False, "ReadonlyRootfs": True, "PidsLimit": policy["pids_limit"], "Memory": policy["memory_bytes"], "MemorySwap": policy["memory_bytes"], "NanoCpus": 1_000_000_000, "CapDrop": ["ALL"], "CapAdd": [], "SecurityOpt": ["no-new-privileges:true"], "Binds": [], "Devices": [], "DeviceRequests": [], "PidMode": "", "PortBindings": {}, "Links": [], "VolumesFrom": [], "ExtraHosts": [], "PublishAllPorts": False, "Tmpfs": {"/tmp": "rw,noexec,nosuid,nodev,size=67108864"}, "Mounts": [{"Type": "bind", "Source": str(target), "Target": "/workspace", "ReadOnly": source_read_only}, {"Type": "bind", "Source": str(scratch), "Target": "/bugsweep-output", "ReadOnly": False}]},
        "NetworkSettings": {"Networks": {} if policy["network_mode"] == "none" else {network_name: {"NetworkID": network_id}}},
        "Mounts": [{"Type": "bind", "Source": str(target), "Destination": "/workspace", "RW": not source_read_only}, {"Type": "bind", "Source": str(scratch), "Destination": "/bugsweep-output", "RW": True}],
    }
    if policy["network_mode"] == "none":
        return analysis
    profile = policy["benchmark_profile"]
    proxy = profile["proxy"]
    internal = profile["internal_network"]
    egress = profile["egress_network"]
    trusted = Path(profile["proxy_receipt"]["path"]).parent
    secret, policy_file = trusted / "provider-key", trusted / "proxy-policy.json"
    proxy_analysis = {
        "Id": proxy["container_id"], "Name": "/" + proxy["container_name"], "Image": "sha256:" + proxy["image_digest"],
        "Config": {"Image": "example.invalid/proxy@sha256:" + proxy["image_digest"], "Entrypoint": ["/usr/local/bin/bugsweep-provider-proxy"], "Cmd": None, "User": "65534:65534", "WorkingDir": "/", "Env": ["BUGSWEEP_PROXY_POLICY=/etc/bugsweep/proxy-policy.json"]},
        "HostConfig": {"NetworkMode": egress["name"], "IpcMode": "none", "PidMode": "", "Privileged": False, "ReadonlyRootfs": True, "PidsLimit": 64, "Memory": 134217728, "MemorySwap": 134217728, "NanoCpus": 1_000_000_000, "CapDrop": ["ALL"], "CapAdd": [], "SecurityOpt": ["no-new-privileges:true"], "Binds": [], "Devices": [], "DeviceRequests": [], "PortBindings": {}, "Links": [], "VolumesFrom": [], "ExtraHosts": [], "PublishAllPorts": False, "RestartPolicy": {"Name": "no"}, "Tmpfs": {"/tmp": "rw,noexec,nosuid,nodev,size=16777216"}, "Mounts": [{"Type": "bind", "Source": str(secret), "Target": "/run/secrets/provider-key", "ReadOnly": True}, {"Type": "bind", "Source": str(policy_file), "Target": "/etc/bugsweep/proxy-policy.json", "ReadOnly": True}]},
        "Mounts": [{"Type": "bind", "Source": str(secret), "Destination": "/run/secrets/provider-key", "RW": False}, {"Type": "bind", "Source": str(policy_file), "Destination": "/etc/bugsweep/proxy-policy.json", "RW": False}],
        "NetworkSettings": {"Networks": {internal["name"]: {"NetworkID": internal["id"]}, egress["name"]: {"NetworkID": egress["id"]}}},
    }
    return {**analysis, "Networks": None, "proxy": proxy_analysis, "network_data": [
        {"Id": internal["id"], "Name": internal["name"], "Internal": True, "Containers": {container_id: {}, proxy["container_id"]: {}}},
        {"Id": egress["id"], "Name": egress["name"], "Internal": False, "Containers": {proxy["container_id"]: {}}},
    ]}


def _receipt(command: list[str], target: Path, output: Path, policy: Mapping[str, object], *, exit_code: int = 0, native: bytes = b"ok\n", predeclared_outputs: Sequence[Mapping[str, object]] = (), environment: Mapping[str, str] | None = None) -> dict[str, object]:
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    sources = source_from_root(target)
    source_identity = {"kind": "content-manifest-sha256", "sha256": digest(sources), "source_file_sha256": sources}
    current_policy = {**policy, "target_root": str(target.resolve()), "source_identity": source_identity}
    scratch = Path(policy["scratch_root"]) / ("provider-" + uuid.uuid4().hex)
    scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
    stdout, stderr = output / "stdout.log", output / "stderr.log"
    stdout.write_bytes(native)
    stderr.write_bytes(b"")
    container_id, container_name = uuid.uuid4().hex * 2, "bugsweep-" + uuid.uuid4().hex
    environment_allowlist = execution._validate_environment(environment or {})
    readback = _analysis_readback(current_policy, target, scratch, command, container_id, container_name, environment_allowlist)
    networks = readback.pop("network_data", None)
    readback.pop("Networks", None)
    if networks is not None:
        proxy = readback.pop("proxy")
        readback = {"schema_version": 1, "kind": "docker-inspect-readback", "analysis": readback, "proxy": proxy, "networks": networks}
    else:
        readback = {"schema_version": 1, "kind": "docker-inspect-readback", "analysis": readback}
    readback_path = output / "backend-readback.json"
    readback_path.write_bytes(canonical(readback))
    readback_sha = file_digest(readback_path)
    declared = execution._validate_outputs(predeclared_outputs)
    for item in declared:
        report = output / str(item["path"])
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text("<testsuite/>\n", encoding="utf-8")
    applied = None
    if current_policy["network_mode"] == "approved-proxy-only":
        limits = dict(current_policy["benchmark_profile"]["limits"])
        applied = {**limits, "enforced": False, "reason": "limit_enforcement_unverified"}
    receipt: dict[str, object] = {
        "schema_version": 1, "invocation_id": uuid.uuid4().hex, "command": command, "command_sha256": digest(command),
        "config_sha256": execution.execution_config_sha256(current_policy, declared), "environment_sha256": execution.execution_environment_sha256(environment_allowlist),
        "cwd": str(target.resolve()), "source_identity": source_identity, "source_manifest_sha256": source_identity["sha256"],
        "execution_policy": current_policy, "environment_allowlist": environment_allowlist, "declared_outputs": declared,
        "backend": {"name": "docker", "engine_path": "/usr/bin/docker", "engine_sha256": "a" * 64, "image_digest": "c" * 64, "container_id": container_id, "container_name": container_name},
        "backend_readback_path": str(readback_path), "backend_readback_sha256": readback_sha, "backend_readback_verified": True,
        "mount_inventory_sha256": execution._mount_inventory(target), "applied_limits": applied,
        "capabilities": {"isolation": "verified", "network": "approved_proxy_only_verified" if current_policy["network_mode"] == "approved-proxy-only" else "verified_denied", "deadline": "process_group_term_kill_reap", "output_import": "trusted_side", "evidence_tier": "verified_backend"},
        "started_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "finished_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        "exit_code": exit_code, "termination": "exited", "reason": None,
        "outputs": [{"kind": "stdout", "path": str(stdout), "sha256": file_digest(stdout), "bytes": stdout.stat().st_size}, {"kind": "stderr", "path": str(stderr), "sha256": file_digest(stderr), "bytes": stderr.stat().st_size}, {"kind": "backend-readback", "path": str(readback_path), "sha256": readback_sha, "bytes": readback_path.stat().st_size}, *[{"kind": item["kind"], "path": str(output / str(item["path"])), "sha256": file_digest(output / str(item["path"])), "bytes": (output / str(item["path"])).stat().st_size} for item in declared]],
        "stdout_path": str(stdout), "stdout_sha256": file_digest(stdout), "stderr_path": str(stderr), "stderr_sha256": file_digest(stderr),
    }
    required_network = "approved-proxy-only" if current_policy["network_mode"] == "approved-proxy-only" else "denied"
    errors = execution.validate_execution_receipt(receipt, sources, required_network)
    if errors:
        raise RuntimeError("test fixture receipt rejected: " + ", ".join(errors))
    return receipt


def prepare_reviews(run: Path, source_root: Path, run_id: str, bug_id: str) -> None:
    sources = source_from_root(source_root)
    source_sha = digest(sources)
    profile = _review_profile(run)
    policy = _policy(run, source_root, sources, approved=True, profile=profile)
    (run / "source-digests.json").write_bytes(canonical(sources))
    before_root = run.parent / "proof-before-source"
    shutil.rmtree(before_root, ignore_errors=True)
    _copy_source(source_root, before_root, sources)
    (run / "before-source-digests.json").write_bytes(canonical(sources))
    (run / "execution-preparation.json").write_bytes(canonical({"run_id": run_id, "target_root": str(source_root.resolve()), "source_files": sorted(sources), "review_hosts": {"codex": "test-model"}, "deadline_epoch": 4102444800, "review_prompt_sha256": hashlib.sha256(review_evidence.INSTRUCTIONS.encode()).hexdigest()}))
    policy_path = run / "review-policy.json"
    policy_path.write_bytes(canonical(policy))
    original = execution.run_command
    counter = 0

    def provider(command, cwd, output_dir, deadline, policy, **_kwargs):
        nonlocal counter
        counter += 1
        verdict = {"verdict": "CONFIRMED", "trigger": "A bounded input reaches the vulnerable path", "trace": ["app.txt:1"], "evidence": ["The simulated native review captured this source-bound evidence"]}
        events = b"\n".join(json.dumps(event).encode() for event in ({"type": "thread.started", "thread_id": f"native-{counter}"}, {"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps(verdict)}}, {"type": "turn.completed"})) + b"\n"
        return _receipt(command, Path(cwd), Path(output_dir), policy, native=events)

    execution.run_command = provider
    try:
        candidate = {"file": "app.txt", "line": 1, "claim": "A bounded input reaches the vulnerable path", "trigger": "Input reaches the vulnerable path"}
        for _ in range(3):
            prepared = review_evidence.prepare_review(run, run_id, bug_id, "referee", "codex", "test-model", source_sha, source_root, candidate)
            review_evidence.run_review(Path(prepared["path"]), policy_path, 4102444800)
    finally:
        execution.run_command = original


def finalize_evidence(run: Path, repo: Path, source_root: Path, run_id: str, branch: str, bug_id: str) -> None:
    final_sources = source_from_root(source_root)
    before_sources = json.loads((run / "before-source-digests.json").read_bytes())
    if not isinstance(before_sources, dict):
        raise RuntimeError("test fixture is missing its pre-integration source snapshot")
    source_sha = digest(final_sources)
    (run / "source-digests.json").write_bytes(canonical(final_sources))
    denied_policy = _policy(run, source_root, final_sources, approved=False)
    suite_execution = _receipt(["/bin/true"], source_root, run / "check-artifacts" / "suite", denied_policy)
    suite = {"schema_version": 1, "run_id": run_id, "phase": "verify", "source_file_sha256": final_sources, "source_manifest_sha256": source_sha, "checks": [{"check": "test", "status": "pass", "command_sha256": suite_execution["command_sha256"], "config_sha256": suite_execution["config_sha256"], "environment_sha256": suite_execution["environment_sha256"], "execution": suite_execution}], "regressions": [], "proof_error": False, "execution_policy_mode": "required-untrusted"}
    if not proof.validate_suite_receipt(suite, run_id, final_sources).get("complete"):
        raise RuntimeError("test fixture suite receipt rejected")
    suite_path = run / "check-results-verify.json"
    suite_path.write_bytes(canonical(suite))
    before_root = run.parent / "proof-before-source"
    if source_from_root(before_root) != before_sources:
        raise RuntimeError("test fixture pre-integration source snapshot changed")
    before_policy = _policy(run, before_root, before_sources, approved=False)
    before_execution = _receipt(["/bin/true"], before_root, run / "proof-artifacts" / "before", before_policy, exit_code=1)
    after_execution = _receipt(["/bin/true"], source_root, run / "proof-artifacts" / "after", denied_policy)
    test = {"path": "regression_fixture.txt", "native_id": "test_regression_fixture", "sha256": before_sources["regression_fixture.txt"], "expected_failure_type": "assertion", "expected_failure_message": "expected failure"}
    proof_receipt: dict[str, object] = {"schema_version": 1, "run_id": run_id, "bug_id": bug_id, "command_sha256": after_execution["command_sha256"], "config_sha256": after_execution["config_sha256"], "environment_sha256": after_execution["environment_sha256"], "execution_policy_mode": "required-untrusted", "source_manifest_sha256": source_sha, "review_source_file_sha256": before_sources, "review_source_manifest_sha256": digest(before_sources), "suite_receipt_path": "check-results-verify.json", "suite_receipt_sha256": file_digest(suite_path), "original_request_sha256": "1" * 64, "post_revision_sha256": "2" * 64, "test": test, "intended_source_files": ["app.txt"], "before": {"source_file_sha256": before_sources, "exit_code": 1, "test_outcome": {"native_id": "test_regression_fixture", "status": "failure", "failure_type": "assertion", "message": "expected failure"}, "structured_report_sha256": "3" * 64, "structured_report_path": "before-report.xml", "log_sha256": "4" * 64, "log_path": "before.log", "execution": before_execution}, "after": {"source_file_sha256": final_sources, "exit_code": 0, "test_outcome": {"native_id": "test_regression_fixture", "status": "pass", "failure_type": None, "message": None}, "structured_report_sha256": "5" * 64, "structured_report_path": "after-report.xml", "log_sha256": "6" * 64, "log_path": "after.log", "execution": after_execution}, "status": "verified"}
    if not proof.validate_fix_proof(proof_receipt, run_id, bug_id, final_sources).get("complete"):
        raise RuntimeError("test fixture fix proof rejected")
    proof_path = run / "proofs" / f"{bug_id}.json"
    proof_path.parent.mkdir(parents=True, exist_ok=True)
    proof_path.write_bytes(canonical(proof_receipt))
    reverify_execution = _receipt(["/bin/true"], source_root, run / "proof-artifacts" / "reverify", denied_policy)
    reverified = {"schema_version": 1, "event": "fix_reverified", "run_id": run_id, "bug_id": bug_id, "original_proof_path": f"proofs/{bug_id}.json", "original_proof_sha256": digest(proof_receipt), "original_source_manifest_sha256": source_sha, "original_fix_commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", branch], text=True).strip(), "final_source_file_sha256": final_sources, "final_source_manifest_sha256": source_sha, "test": test, "command_sha256": reverify_execution["command_sha256"], "config_sha256": reverify_execution["config_sha256"], "environment_sha256": reverify_execution["environment_sha256"], "execution_policy_mode": "required-untrusted", "suite_receipt_path": "check-results-verify.json", "suite_receipt_sha256": file_digest(suite_path), "after": {"source_file_sha256": final_sources, "exit_code": 0, "test_outcome": {"native_id": "test_regression_fixture", "status": "pass", "failure_type": None, "message": None}, "execution": reverify_execution}, "status": "verified"}
    if not proof.validate_fix_reverification(reverified, proof_receipt, run_id, bug_id, final_sources).get("complete"):
        raise RuntimeError("test fixture reverification rejected")
    reverify_path = run / "reverified" / f"{bug_id}.json"
    reverify_path.parent.mkdir(parents=True, exist_ok=True)
    reverify_path.write_bytes(canonical(reverified))
    with (run / "ledger.jsonl").open("a", encoding="utf-8") as ledger:
        ledger.write(json.dumps({"event": "fix_reverified", "bug_id": bug_id, "path": str(reverify_path.relative_to(run)), "sha256": file_digest(reverify_path), "original_fix_commit": reverified["original_fix_commit"]}, sort_keys=True) + "\n")


def main(argv: list[str]) -> int:
    if argv[0] == "prepare-reviews":
        prepare_reviews(Path(argv[1]), Path(argv[2]), argv[3], argv[4])
    elif argv[0] == "finalize-evidence":
        finalize_evidence(Path(argv[1]), Path(argv[2]), Path(argv[3]), argv[4], argv[5], argv[6])
    else:
        raise SystemExit("usage: landed_fixture.py prepare-reviews|finalize-evidence ...")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
