"""Security and lifecycle contract for the shared command executor."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import ModuleType
from typing import Any

import jsonschema
import pytest
from jsonschema.validators import Draft202012Validator


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "_execution.py"
SCHEMA = ROOT / "schemas" / "execution-receipt.schema.json"
LIMIT_SCHEMA = ROOT / "schemas" / "benchmark-limit-evidence.schema.json"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bugsweep_execution", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _native_policy(cwd: Path, scratch_parent: Path) -> dict[str, Any]:
    engine = Path(sys.executable).resolve(strict=True)
    source_path = cwd / "source.txt"
    if not source_path.exists():
        source_path.write_text("source\n", encoding="utf-8")
    source_files = {"source.txt": _sha256(source_path)}
    source_manifest = hashlib.sha256(
        json.dumps(source_files, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {
        "schema_version": 1,
        "mode": "trusted-worktree",
        "backend": "native",
        "canonical_engine_path": str(engine),
        "engine_sha256": _sha256(engine),
        "target_root": str(cwd.resolve(strict=True)),
        "scratch_root": str(scratch_parent.resolve(strict=True)),
        "source_identity": {
            "kind": "content-manifest-sha256",
            "sha256": source_manifest,
            "source_file_sha256": source_files,
        },
        "term_grace_seconds": 0.2,
    }


def _run_native(
    module: ModuleType,
    tmp_path: Path,
    command: list[str],
    *,
    deadline_seconds: float = 5,
    outputs: list[dict[str, object]] | None = None,
) -> tuple[dict[str, Any], Path]:
    cwd = tmp_path / "target"
    scratch = tmp_path / "scratch"
    output = tmp_path / "authority" / "invocation"
    cwd.mkdir()
    scratch.mkdir()
    output.parent.mkdir()
    policy = _native_policy(cwd, scratch)
    if command[0] == sys.executable:
        command[0] = str(Path(sys.executable).resolve(strict=True))
    receipt = module.run_command(
        command,
        cwd,
        output,
        time.time() + deadline_seconds,
        policy,
        {"LANG": "C.UTF-8"},
        outputs or (),
    )
    return receipt, output


def test_schema_and_success_receipt_are_valid_and_canonical(tmp_path: Path) -> None:
    module = _load_module()
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)

    receipt, output = _run_native(
        module,
        tmp_path,
        [sys.executable, "-c", "print('ok')"],
    )

    jsonschema.validate(receipt, schema)
    assert receipt["termination"] == "exited"
    assert receipt["exit_code"] == 0
    assert receipt["capabilities"]["isolation"] == "none"
    assert receipt["capabilities"]["evidence_tier"] == "host_execution"
    assert (output / "stdout.log").read_text(encoding="utf-8") == "ok\n"
    assert receipt["source_manifest_sha256"] == receipt["source_identity"]["sha256"]
    saved = (output / "execution-receipt.json").read_bytes()
    assert saved == module.canonical_json_bytes(receipt)


def test_default_policy_fails_closed_before_process_start(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    module = _load_module()
    cwd = tmp_path / "target"
    scratch = tmp_path / "scratch"
    output = tmp_path / "authority" / "invocation"
    cwd.mkdir()
    scratch.mkdir()
    output.parent.mkdir()
    called = False

    def forbidden(*_args: object, **_kwargs: object) -> None:
        nonlocal called
        called = True
        raise AssertionError("target process must not start")

    monkeypatch.setattr(module.subprocess, "Popen", forbidden)
    receipt = module.run_command(
        ["/bin/echo", "unsafe"], cwd, output, time.time() + 2, None, {}, ()
    )

    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    jsonschema.validate(receipt, schema)
    assert not called
    assert receipt["termination"] == "backend_unavailable"
    assert receipt["reason"] == "required_untrusted_backend_not_configured"


def test_rejects_shell_shape_and_authority_directory_inside_target(tmp_path: Path) -> None:
    module = _load_module()
    cwd = tmp_path / "target"
    scratch = tmp_path / "scratch"
    cwd.mkdir()
    scratch.mkdir()
    policy = _native_policy(cwd, scratch)

    with pytest.raises(ValueError, match="non-empty strings"):
        module.run_command("echo bad", cwd, tmp_path / "out", time.time() + 2, policy, {}, ())
    with pytest.raises(ValueError, match="outside the target"):
        module.run_command(
            [sys.executable, "-c", "pass"],
            cwd,
            cwd / "authority",
            time.time() + 2,
            policy,
            {},
            (),
        )


def test_environment_is_explicit_and_credentials_are_rejected(tmp_path: Path) -> None:
    module = _load_module()
    code = "import os; print(os.getenv('VISIBLE')); print(os.getenv('SECRET_TOKEN'))"
    receipt, output = _run_native(
        module,
        tmp_path,
        [sys.executable, "-c", code],
    )
    assert receipt["termination"] == "exited"
    assert (output / "stdout.log").read_text(encoding="utf-8") == "None\nNone\n"

    cwd = tmp_path / "other-target"
    scratch = tmp_path / "other-scratch"
    cwd.mkdir()
    scratch.mkdir()
    with pytest.raises(ValueError, match="credential-like"):
        module.run_command(
            [sys.executable, "-c", "pass"],
            cwd,
            tmp_path / "other-authority",
            time.time() + 2,
            _native_policy(cwd, scratch),
            {"AWS_SECRET_ACCESS_KEY": "nope"},
            (),
        )


def test_timeout_terminates_process_group_and_reaps(tmp_path: Path) -> None:
    module = _load_module()
    escaped = tmp_path / "descendant-escaped"
    child = (
        "import signal,time; from pathlib import Path; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(.5); "
        f"Path({str(escaped)!r}).write_text('escaped')"
    )
    parent = (
        "import signal,subprocess,sys,time; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        f"subprocess.Popen([sys.executable, '-c', {child!r}]); time.sleep(30)"
    )
    receipt, output = _run_native(
        module,
        tmp_path,
        [sys.executable, "-c", parent],
        deadline_seconds=0.15,
    )

    assert receipt["termination"] == "timeout"
    assert receipt["exit_code"] is not None
    assert receipt["capabilities"]["deadline"] == "process_group_term_kill_reap"
    assert (output / "execution-receipt.json").is_file()
    time.sleep(0.6)
    assert not escaped.exists()


def test_control_cancellation_reaps_before_propagating(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    module = _load_module()
    engine = Path(sys.executable).resolve(strict=True)
    reaped: list[object] = []

    class InterruptedProcess:
        def wait(self, timeout: float | None = None) -> int:
            del timeout
            raise KeyboardInterrupt

    monkeypatch.setattr(module.subprocess, "Popen", lambda *_args, **_kwargs: InterruptedProcess())
    monkeypatch.setattr(
        module,
        "_terminate_and_reap",
        lambda process, grace: reaped.append((process, grace)) or -9,
    )
    with pytest.raises(KeyboardInterrupt):
        module._control_capture(
            engine,
            _sha256(engine),
            [str(engine), "create"],
            tmp_path / "control.stdout",
            tmp_path / "control.stderr",
            1,
        )
    assert len(reaped) == 1


def test_cleanup_never_removes_a_container_without_its_invocation_label(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    module = _load_module()
    engine = Path(sys.executable).resolve(strict=True)
    monkeypatch.setattr(
        module,
        "_docker_json",
        lambda *_args, **_kwargs: [
            {
                "Name": "/bugsweep-" + "a" * 32,
                "Config": {"Labels": {"org.bugsweep.invocation": "b" * 32}},
            }
        ],
    )
    monkeypatch.setattr(
        module,
        "_control_engine",
        lambda *_args, **_kwargs: pytest.fail("foreign container must not be removed"),
    )
    assert not module._remove_owned_container(
        engine, _sha256(engine), "bugsweep-" + "a" * 32, tmp_path
    )


def test_imports_only_predeclared_regular_bounded_outputs(tmp_path: Path) -> None:
    module = _load_module()
    command = [
        sys.executable,
        "-c",
        "import os; from pathlib import Path; "
        "(Path(os.environ['BUGSWEEP_OUTPUT_DIR']) / 'report.xml').write_text('<testsuite/>')",
    ]
    receipt, output = _run_native(
        module,
        tmp_path,
        command,
        outputs=[{"path": "report.xml", "kind": "junit", "max_bytes": 1024}],
    )

    report = output / "report.xml"
    assert report.read_text(encoding="utf-8") == "<testsuite/>"
    assert any(item["kind"] == "junit" and item["sha256"] == _sha256(report) for item in receipt["outputs"])


def test_symlink_or_unexpected_scratch_output_rejects_import(tmp_path: Path) -> None:
    module = _load_module()
    symlink_command = [
        sys.executable,
        "-c",
        "import os; from pathlib import Path; "
        "(Path(os.environ['BUGSWEEP_OUTPUT_DIR']) / 'report.xml').symlink_to('/etc/passwd')",
    ]
    receipt, output = _run_native(
        module,
        tmp_path,
        symlink_command,
        outputs=[{"path": "report.xml", "kind": "junit", "max_bytes": 1024}],
    )
    assert receipt["reason"] == "output_import_rejected"
    assert receipt["capabilities"]["output_import"] == "rejected"
    assert not (output / "report.xml").exists()


def test_container_argv_is_pinned_and_target_metacharacters_remain_one_argument(tmp_path: Path) -> None:
    module = _load_module()
    target = tmp_path / "target"
    scratch = tmp_path / "scratch"
    target.mkdir()
    scratch.mkdir()
    engine = Path(sys.executable).resolve(strict=True)
    policy = {
        "schema_version": 1,
        "mode": "required-untrusted",
        "backend": "docker",
        "canonical_engine_path": str(engine),
        "engine_sha256": _sha256(engine),
        "image": "example.invalid/bugsweep@sha256:" + "b" * 64,
        "target_root": str(target.resolve()),
        "scratch_root": str(scratch.resolve()),
        "source_identity": _native_policy(target, scratch)["source_identity"],
        "uid": "65534:65534",
        "pids_limit": 64,
        "memory_bytes": 268435456,
        "cpus": 1.0,
        "term_grace_seconds": 1,
        "network_mode": "none",
        "image_env_allowlist": {},
    }
    invocation_scratch = scratch / "invocation"
    invocation_scratch.mkdir()
    token = "$(touch /tmp/pwned); echo hi"

    argv = module.build_backend_argv(
        ["/bin/sh", "-c", token],
        target,
        invocation_scratch,
        policy,
        "bugsweep-" + "c" * 32,
    )

    assert argv[0] == str(engine)
    assert argv[1] == "create"
    assert "--network" in argv and argv[argv.index("--network") + 1] == "none"
    assert "--ipc" in argv and argv[argv.index("--ipc") + 1] == "none"
    assert "--cap-drop" in argv and argv[argv.index("--cap-drop") + 1] == "ALL"
    assert "no-new-privileges:true" in argv
    assert policy["image"] in argv
    assert argv[argv.index("--entrypoint") + 1] == "/bin/sh"
    assert argv[-2:] == ["-c", token]
    assert argv.count(token) == 1

    with pytest.raises(ValueError, match="unsupported fields"):
        module.build_backend_argv(
            ["/bin/true"],
            target,
            invocation_scratch,
            {**policy, "mounts": ["/:/host"]},
            "bugsweep-" + "d" * 32,
        )
    with pytest.raises(module.ExecutionError, match="engine_identity_mismatch"):
        module.build_backend_argv(
            ["/bin/true"],
            target,
            invocation_scratch,
            {**policy, "engine_sha256": "0" * 64},
            "bugsweep-" + "e" * 32,
        )


def test_existing_authority_destination_is_never_overwritten(tmp_path: Path) -> None:
    module = _load_module()
    target = tmp_path / "target"
    scratch = tmp_path / "scratch"
    output = tmp_path / "authority"
    target.mkdir()
    scratch.mkdir()
    output.mkdir()
    sentinel = output / "execution-receipt.json"
    sentinel.write_text("preserve", encoding="utf-8")

    with pytest.raises(ValueError, match="fresh"):
        module.run_command(
            [str(Path(sys.executable).resolve()), "-c", "pass"],
            target,
            output,
            time.time() + 2,
            _native_policy(target, scratch),
            {},
            (),
        )
    assert sentinel.read_text(encoding="utf-8") == "preserve"


def test_source_digest_mismatch_blocks_before_launch(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    module = _load_module()
    target = tmp_path / "target"
    scratch = tmp_path / "scratch"
    authority = tmp_path / "authority"
    target.mkdir()
    scratch.mkdir()
    authority.mkdir()
    policy = _native_policy(target, scratch)
    (target / "source.txt").write_text("changed\n", encoding="utf-8")
    launched = False

    def forbidden(*_args: object, **_kwargs: object) -> None:
        nonlocal launched
        launched = True

    monkeypatch.setattr(module.subprocess, "Popen", forbidden)
    with pytest.raises(ValueError, match="source identity is incomplete or mismatched"):
        module.run_command(
            [str(Path(sys.executable).resolve()), "-c", "pass"],
            target,
            authority / "invocation",
            time.time() + 2,
            policy,
            {},
            (),
        )
    assert not launched

    other_target = tmp_path / "subset-target"
    other_scratch = tmp_path / "subset-scratch"
    other_target.mkdir()
    other_scratch.mkdir()
    subset_policy = _native_policy(other_target, other_scratch)
    (other_target / "unlisted-test.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    with pytest.raises(ValueError, match="source identity is incomplete or mismatched"):
        module.run_command(
            [str(Path(sys.executable).resolve()), "-c", "pass"],
            other_target,
            tmp_path / "subset-authority",
            time.time() + 2,
            subset_policy,
            {},
            (),
        )


def test_full_target_scan_rejects_socket_and_escaping_symlink(tmp_path: Path) -> None:
    module = _load_module()
    target = tmp_path / "target"
    target.mkdir()
    outside = tmp_path / "outside"
    outside.write_text("host data", encoding="utf-8")
    (target / "escape").symlink_to(outside)
    with pytest.raises(ValueError, match="symlink escapes"):
        module._mount_inventory(target)
    (target / "escape").unlink()

    short_target = Path(tempfile.mkdtemp(prefix="bse-", dir="/tmp"))
    endpoint = socket.socket(socket.AF_UNIX)
    try:
        endpoint.bind(str(short_target / "agent.sock"))
        with pytest.raises(ValueError, match="special file"):
            module._mount_inventory(short_target)
    finally:
        endpoint.close()
        shutil.rmtree(short_target)


def test_config_digest_excludes_dynamic_source_identity(tmp_path: Path) -> None:
    module = _load_module()
    target = tmp_path / "target"
    scratch = tmp_path / "scratch"
    target.mkdir()
    scratch.mkdir()
    first = _native_policy(target, scratch)
    second = json.loads(json.dumps(first))
    second["source_identity"] = {
        "kind": "content-manifest-sha256",
        "sha256": "2" * 64,
        "source_file_sha256": {"source.txt": "3" * 64},
    }
    second["target_root"] = "/different/invocation/target"
    second["scratch_root"] = "/different/invocation/scratch"

    assert module.execution_config_sha256(first, ()) == module.execution_config_sha256(second, ())


def test_verified_standard_docker_readback_has_an_eligible_capability(tmp_path: Path) -> None:
    module = _load_module()
    target = tmp_path / "target"
    scratch_root = tmp_path / "scratch"
    invocation_scratch = scratch_root / "invocation"
    target.mkdir()
    scratch_root.mkdir()
    invocation_scratch.mkdir()
    engine = Path(sys.executable).resolve(strict=True)
    policy = {
        "schema_version": 1,
        "mode": "required-untrusted",
        "backend": "docker",
        "canonical_engine_path": str(engine),
        "engine_sha256": _sha256(engine),
        "image": "example.invalid/bugsweep@sha256:" + "b" * 64,
        "target_root": str(target.resolve()),
        "scratch_root": str(scratch_root.resolve()),
        "source_identity": _native_policy(target, scratch_root)["source_identity"],
        "uid": "65534:65534",
        "pids_limit": 64,
        "memory_bytes": 268435456,
        "cpus": 1.0,
        "term_grace_seconds": 1,
        "network_mode": "none",
        "image_env_allowlist": {},
    }
    normalized, _, _, _ = module._validate_policy(policy, target)
    command = ["/bin/sh", "-c", "exit 0"]
    container_id = "c" * 64
    container_name = "bugsweep-" + "d" * 32
    expected_env = module._target_environment({}, {}, "/bugsweep-output")
    inspect = {
        "Id": container_id,
        "Name": "/" + container_name,
        "Config": {
            "Image": policy["image"],
            "User": policy["uid"],
            "WorkingDir": "/workspace",
            "Entrypoint": [command[0]],
            "Cmd": command[1:],
            "Env": [f"{key}={value}" for key, value in expected_env.items()],
            "Labels": {"org.bugsweep.invocation": "d" * 32},
        },
        "HostConfig": {
            "NetworkMode": "none",
            "IpcMode": "none",
            "Privileged": False,
            "ReadonlyRootfs": True,
            "PidsLimit": 64,
            "Memory": 268435456,
            "MemorySwap": 268435456,
            "NanoCpus": 1000000000,
            "CapDrop": ["ALL"],
            "CapAdd": None,
            "SecurityOpt": ["no-new-privileges:true"],
            "Binds": None,
            "Devices": [],
            "DeviceRequests": None,
            "PidMode": "",
            "PortBindings": {},
            "Links": None,
            "VolumesFrom": None,
            "PublishAllPorts": False,
            "Mounts": [
                {
                    "Type": "bind",
                    "Source": str(target),
                    "Target": "/workspace",
                    "ReadOnly": False,
                },
                {
                    "Type": "bind",
                    "Source": str(invocation_scratch),
                    "Target": "/bugsweep-output",
                    "ReadOnly": False,
                },
            ],
            "Tmpfs": {"/tmp": "rw,noexec,nosuid,nodev,size=67108864"},
        },
        "Mounts": [
            {"Type": "bind", "Destination": "/workspace", "Source": str(target), "RW": True},
            {
                "Type": "bind",
                "Destination": "/bugsweep-output",
                "Source": str(invocation_scratch),
                "RW": True,
            },
        ],
        "NetworkSettings": {"Networks": {}},
    }

    readback = {"schema_version": 1, "kind": "docker-inspect-readback", "analysis": inspect}
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    jsonschema.validate(readback, schema["$defs"]["backendReadback"])
    assert module.verify_backend_readback(
        readback,
        normalized,
        target,
        invocation_scratch,
        container_id,
        container_name,
        command,
        {},
    ) == "verified_denied"
    inspect["NetworkSettings"]["Networks"] = {
        "none": {"Gateway": "", "IPAddress": "", "GlobalIPv6Address": ""}
    }
    assert module.verify_backend_readback(
        readback,
        normalized,
        target,
        invocation_scratch,
        container_id,
        container_name,
        command,
        {},
    ) == "verified_denied"
    inspect["NetworkSettings"]["Networks"] = {}
    inspect["HostConfig"]["NetworkMode"] = "bridge"
    with pytest.raises(module.ExecutionError, match="host limits mismatch"):
        module.verify_backend_readback(
            readback,
            normalized,
            target,
            invocation_scratch,
            container_id,
            container_name,
            command,
            {},
        )
    inspect["HostConfig"]["NetworkMode"] = "none"
    with pytest.raises(module.ExecutionError, match="envelope mismatch"):
        module.verify_backend_readback(
            {**readback, "unexpected": {}},
            normalized,
            target,
            invocation_scratch,
            container_id,
            container_name,
            command,
            {},
        )

    archive_policy = {**policy, "source_mount_mode": "archive-ro"}
    archive_normalized, _, _, _ = module._validate_policy(archive_policy, target)
    archive_argv = module.build_backend_argv(
        command,
        target,
        invocation_scratch,
        archive_normalized,
        container_name,
        {},
    )
    assert f"type=bind,src={target},dst=/workspace,readonly" in archive_argv
    archive_inspect = json.loads(json.dumps(inspect))
    archive_inspect["HostConfig"]["Mounts"][0]["ReadOnly"] = True
    archive_inspect["Mounts"][0]["RW"] = False
    archive_readback = {
        "schema_version": 1,
        "kind": "docker-inspect-readback",
        "analysis": archive_inspect,
    }
    assert module.verify_backend_readback(
        archive_readback,
        archive_normalized,
        target,
        invocation_scratch,
        container_id,
        container_name,
        command,
        {},
    ) == "verified_denied"

    authority = tmp_path / "authority"
    authority.mkdir()
    stdout_path = authority / "stdout.log"
    stderr_path = authority / "stderr.log"
    stdout_path.write_text("ok\n", encoding="utf-8")
    stderr_path.write_bytes(b"")
    readback_path = authority / "backend-readback.json"
    raw = module.canonical_json_bytes(readback)
    readback_path.write_bytes(raw)
    readback_sha = hashlib.sha256(raw).hexdigest()
    source = normalized["source_identity"]
    receipt = {
        "schema_version": 1,
        "invocation_id": "4" * 32,
        "command": command,
        "command_sha256": hashlib.sha256(module.canonical_json_bytes(command)).hexdigest(),
        "config_sha256": module.execution_config_sha256(normalized, ()),
        "environment_sha256": module.execution_environment_sha256({}),
        "cwd": str(target),
        "source_identity": source,
        "source_manifest_sha256": source["sha256"],
        "execution_policy": normalized,
        "environment_allowlist": {},
        "declared_outputs": [],
        "backend": {
            "name": "docker",
            "engine_path": str(engine),
            "engine_sha256": policy["engine_sha256"],
            "image_digest": "b" * 64,
            "container_id": container_id,
            "container_name": container_name,
        },
        "backend_readback_path": str(readback_path),
        "backend_readback_sha256": readback_sha,
        "backend_readback_verified": True,
        "mount_inventory_sha256": module._mount_inventory(target),
        "applied_limits": None,
        "capabilities": {
            "isolation": "verified",
            "network": "verified_denied",
            "deadline": "process_group_term_kill_reap",
            "output_import": "trusted_side",
            "evidence_tier": "verified_backend",
        },
        "started_at": "2026-09-05T12:00:00.000000Z",
        "finished_at": "2026-09-05T12:00:01.000000Z",
        "exit_code": 0,
        "termination": "exited",
        "reason": None,
        "stdout_path": str(stdout_path),
        "stdout_sha256": _sha256(stdout_path),
        "stderr_path": str(stderr_path),
        "stderr_sha256": _sha256(stderr_path),
        "outputs": [
            {
                "kind": "stdout",
                "path": str(stdout_path),
                "sha256": _sha256(stdout_path),
                "bytes": stdout_path.stat().st_size,
            },
            {
                "kind": "stderr",
                "path": str(stderr_path),
                "sha256": _sha256(stderr_path),
                "bytes": stderr_path.stat().st_size,
            },
            {
                "kind": "backend-readback",
                "path": str(readback_path),
                "sha256": readback_sha,
                "bytes": len(raw),
            }
        ],
    }
    assert module.validate_execution_receipt(
        receipt, source["source_file_sha256"], "denied"
    ) == []
    missing_schema = json.loads(json.dumps(receipt))
    missing_schema.pop("schema_version")
    assert module.validate_execution_receipt(
        missing_schema, source["source_file_sha256"], "denied"
    ) == ["receipt_schema_invalid"]

    target_authority = target / "target-controlled-authority"
    target_authority.mkdir()
    moved = json.loads(json.dumps(receipt))
    for record in moved["outputs"]:
        original = Path(record["path"])
        replacement = target_authority / original.name
        replacement.write_bytes(original.read_bytes())
        record["path"] = str(replacement)
    moved["stdout_path"] = str(target_authority / "stdout.log")
    moved["stderr_path"] = str(target_authority / "stderr.log")
    moved["backend_readback_path"] = str(target_authority / "backend-readback.json")
    assert "backend_readback_authority_path_invalid" in module.validate_execution_receipt(
        moved, source["source_file_sha256"], "denied"
    )
    stdout_path.write_text("tampered\n", encoding="utf-8")
    assert "output_artifact_digest_mismatch" in module.validate_execution_receipt(
        receipt, source["source_file_sha256"], "denied"
    )


def test_benchmark_readback_requires_exact_secret_and_policy_mounts(tmp_path: Path) -> None:
    module = _load_module()
    target = tmp_path / "target"
    scratch = tmp_path / "scratch"
    trusted = tmp_path / "trusted"
    target.mkdir()
    scratch.mkdir()
    trusted.mkdir()
    secret = trusted / "provider-key"
    secret.write_text("test-only-placeholder", encoding="utf-8")
    secret.chmod(0o600)
    proxy_policy = trusted / "proxy-policy.json"
    proxy_policy.write_text('{"allowed_paths":["/v1/messages"]}\n', encoding="utf-8")
    internal_id, egress_id, analysis_id, proxy_id = (character * 64 for character in "abcd")
    internal_name, egress_name, proxy_name = (
        "bugsweep-internal-test",
        "bugsweep-egress-test",
        "bugsweep-proxy-test",
    )
    proxy_image = "example.invalid/proxy@sha256:" + "e" * 64
    limits = {
        "wall_clock_seconds": 60,
        "max_turns": 10,
        "max_input_tokens": 1000,
        "max_output_tokens": 1000,
        "max_spend_usd": 1,
        "enforcement": {
            "wall_clock_seconds": "coordinator deadline",
            "max_turns": "adapter counter",
            "max_input_tokens": "proxy usage",
            "max_output_tokens": "proxy usage",
            "max_spend_usd": "provider account cap",
        },
    }
    receipt = {
        "schema_version": 1,
        "owner": "bench/lib/proxy.sh",
        "run_id": "test-run",
        "host": "claude",
        "internal_network": {"name": internal_name, "id": internal_id},
        "egress_network": {"name": egress_name, "id": egress_id},
        "proxy": {
            "container_name": proxy_name,
            "container_id": proxy_id,
            "image_digest": "sha256:" + "e" * 64,
        },
        "upstream": {"host": "api.anthropic.com", "allowed_paths": ["/v1/messages"]},
        "limits": limits,
        "policy": {
            "mount": "/etc/bugsweep/proxy-policy.json",
            "sha256": _sha256(proxy_policy),
            "nonsecret": True,
        },
        "secret": {
            "mount": "/run/secrets/provider-key",
            "mode": "0600",
            "outside_target_and_results": True,
        },
    }
    receipt_path = trusted / "proxy-receipt.json"
    receipt_bytes = module.canonical_json_bytes(receipt)
    receipt_path.write_bytes(receipt_bytes)
    requested_profile = {
        "host": "claude",
        "proxy_receipt": {
            "path": str(receipt_path),
            "sha256": hashlib.sha256(receipt_bytes).hexdigest(),
            "schema_version": 1,
            "owner": "bench/lib/proxy.sh",
        },
        "internal_network": {"name": internal_name, "id": internal_id},
        "egress_network": {"name": egress_name, "id": egress_id},
        "proxy": {"container_name": proxy_name, "container_id": proxy_id, "image_digest": "e" * 64},
        "upstream": {"host": "api.anthropic.com", "allowed_paths": ["/v1/messages"]},
        "analysis": {
            "entrypoint": "/usr/local/bin/bench-host-adapter",
            "entrypoint_sha256": "f" * 64,
        },
        "client": {"inert_credential_literal": "benchmark-inert-client-credential"},
        "arms": {
            arm: {"skill_revision": arm + "-revision", "skill_content_sha256": character * 64}
            for arm, character in (("current", "1"), ("previous", "2"), ("baseline", "3"))
        },
        "limits": limits,
    }
    profile = module._validate_benchmark_profile(requested_profile, target, scratch)
    assert profile["proxy_image_id"] == "sha256:" + "e" * 64
    assert profile["proxy_policy"]["sha256"] == _sha256(proxy_policy)
    source_identity = _native_policy(target, scratch)["source_identity"]
    benchmark_policy = {
        "schema_version": 1,
        "mode": "required-untrusted",
        "backend": "docker",
        "canonical_engine_path": str(Path(sys.executable).resolve(strict=True)),
        "engine_sha256": _sha256(Path(sys.executable).resolve(strict=True)),
        "image": "example.invalid/analysis@sha256:" + "f" * 64,
        "target_root": str(target.resolve(strict=True)),
        "scratch_root": str(scratch.resolve(strict=True)),
        "source_identity": source_identity,
        "uid": "65534:65534",
        "pids_limit": 64,
        "memory_bytes": 268435456,
        "cpus": 1.0,
        "term_grace_seconds": 1,
        "network_mode": "approved-proxy-only",
        "image_env_allowlist": {},
        "benchmark_profile": requested_profile,
    }
    with pytest.raises(ValueError, match="requires an archive-ro source mount"):
        module._validate_policy(benchmark_policy, target)
    (target / ".git").write_text("gitdir: /outside/worktree\n", encoding="utf-8")
    benchmark_policy["source_mount_mode"] = "archive-ro"
    with pytest.raises(ValueError, match="must not contain .git metadata"):
        module._validate_policy(benchmark_policy, target)
    (target / ".git").unlink()
    (target / "source-link").symlink_to(target / "source.txt")
    with pytest.raises(ValueError, match="archive source contains a symbolic link"):
        module._validate_policy(benchmark_policy, target)
    (target / "source-link").unlink()
    normalized_benchmark, _, _, _ = module._validate_policy(benchmark_policy, target)
    assert normalized_benchmark["source_mount_mode"] == "archive-ro"
    policy = {
        "target_root": str(target),
        "scratch_root": str(scratch),
        "benchmark_profile": profile,
    }
    profile_for_readback = {
        "proxy": {"container_name": proxy_name, "container_id": proxy_id, "image_digest": "e" * 64},
        "proxy_image_id": "sha256:" + "e" * 64,
        "internal_network": {"name": internal_name, "id": internal_id},
        "egress_network": {"name": egress_name, "id": egress_id},
        "proxy_policy": {
            "mount": "/etc/bugsweep/proxy-policy.json",
            "sha256": _sha256(proxy_policy),
            "nonsecret": True,
        },
    }
    assert all(profile[key] == value for key, value in profile_for_readback.items())
    mount_pairs = [
        (str(secret), "/run/secrets/provider-key"),
        (str(proxy_policy), "/etc/bugsweep/proxy-policy.json"),
    ]
    readback = {
        "proxy": {
            "Id": proxy_id,
            "Name": "/" + proxy_name,
            "Image": "sha256:" + "e" * 64,
            "Config": {
                "Image": proxy_image,
                "Entrypoint": ["/usr/local/bin/bugsweep-provider-proxy"],
                "Cmd": None,
                "User": "65534:65534",
                "WorkingDir": "/",
                "Env": ["BUGSWEEP_PROXY_POLICY=/etc/bugsweep/proxy-policy.json"],
            },
            "HostConfig": {
                "NetworkMode": egress_name,
                "IpcMode": "none",
                "PidMode": "",
                "Privileged": False,
                "ReadonlyRootfs": True,
                "PidsLimit": 64,
                "Memory": 134217728,
                "MemorySwap": 134217728,
                "NanoCpus": 1000000000,
                "CapDrop": ["ALL"],
                "CapAdd": None,
                "SecurityOpt": ["no-new-privileges:true"],
                "Binds": None,
                "Devices": [],
                "DeviceRequests": None,
                "PortBindings": {},
                "Links": None,
                "VolumesFrom": None,
                "ExtraHosts": None,
                "PublishAllPorts": False,
                "RestartPolicy": {"Name": "no"},
                "Tmpfs": {"/tmp": "rw,noexec,nosuid,nodev,size=16777216"},
                "Mounts": [
                    {"Type": "bind", "Source": source, "Target": destination, "ReadOnly": True}
                    for source, destination in mount_pairs
                ]
            },
            "Mounts": [
                {"Type": "bind", "Source": source, "Destination": destination, "RW": False}
                for source, destination in mount_pairs
            ],
            "NetworkSettings": {
                "Networks": {
                    internal_name: {"NetworkID": internal_id},
                    egress_name: {"NetworkID": egress_id},
                }
            },
        },
        "networks": [
            {
                "Id": internal_id,
                "Name": internal_name,
                "Internal": True,
                "Containers": {analysis_id: {}, proxy_id: {}},
            },
            {
                "Id": egress_id,
                "Name": egress_name,
                "Internal": False,
                "Containers": {proxy_id: {}},
            },
        ],
    }

    module._verify_benchmark_dependencies(readback, policy, analysis_id)
    readback["proxy"]["HostConfig"]["Privileged"] = True
    with pytest.raises(module.ExecutionError, match="confinement or limits"):
        module._verify_benchmark_dependencies(readback, policy, analysis_id)
    readback["proxy"]["HostConfig"]["Privileged"] = False
    readback["proxy"]["Mounts"] = readback["proxy"]["Mounts"][:1]
    with pytest.raises(module.ExecutionError, match="mount readback"):
        module._verify_benchmark_dependencies(readback, policy, analysis_id)


def test_post_stop_limit_evidence_separates_source_from_live_verification(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    module = _load_module()
    schema = json.loads(LIMIT_SCHEMA.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    target, scratch, authority, sealed = (
        tmp_path / "target",
        tmp_path / "scratch",
        tmp_path / "authority",
        tmp_path / "sealed",
    )
    for directory in (target, scratch, authority, sealed):
        directory.mkdir()
    source_map = {"source.txt": "1" * 64}
    limits = {
        "wall_clock_seconds": 60,
        "max_turns": 2,
        "max_input_tokens": 4096,
        "max_output_tokens": 1024,
        "max_spend_usd": 1.0,
        "enforcement": {
            "wall_clock_seconds": "provider-deadline",
            "max_turns": "provider_proxy:atomic_turn_counter",
            "max_input_tokens": "provider_proxy:conservative_request_byte_ceiling",
            "max_output_tokens": "provider_proxy:rewrites_output_cap",
            "max_spend_usd": "provider_proxy:conservative_reservation",
        },
    }
    proxy_receipt_sha, policy_sha, source_sha = "2" * 64, "3" * 64, "4" * 64
    readback = {
        "proxy": {
            "Image": "sha256:" + "5" * 64,
            "Config": {"Labels": {"org.bugsweep.proxy.source.sha256": source_sha}},
        }
    }
    readback_path = authority / "backend-readback.json"
    readback_path.write_bytes(module.canonical_json_bytes(readback))
    execution = {
        "cwd": str(target),
        "started_at": "2026-09-05T12:00:00.000000Z",
        "finished_at": "2026-09-05T12:00:01.000000Z",
        "backend_readback_path": str(readback_path),
        "execution_policy": {
            "scratch_root": str(scratch),
            "benchmark_profile": {
                "proxy_receipt": {"sha256": proxy_receipt_sha},
                "proxy_policy": {"sha256": policy_sha},
                "proxy_image_id": "sha256:" + "5" * 64,
                "limits": limits,
            },
        },
    }
    monkeypatch.setattr(module, "validate_execution_receipt", lambda *_args, **_kwargs: [])
    event_log = sealed / "run.proxy-events.jsonl"
    event_log.write_text(
        '{"budget_charged_usd":0.1,"budget_overshoot_usd":0.0,"input_tokens":100,"kind":"bugsweep-proxy-usage","output_tokens":20,"status":"forwarded"}\n',
        encoding="utf-8",
    )
    expected_limits = {key: value for key, value in limits.items() if key != "enforcement"}
    evidence = {
        "schema_version": 1,
        "kind": "benchmark-limit-evidence",
        "owner": "bench/harness.py",
        "run_id": "run-1",
        "created_at": "2026-09-05T12:00:00.000000Z",
        "execution_receipt_sha256": module._digest(execution),
        "proxy_receipt_sha256": proxy_receipt_sha,
        "proxy_policy_sha256": policy_sha,
        "configured_limits": expected_limits,
        "source_evidence": {
            "proxy_image_digest": "sha256:" + "5" * 64,
            "provider_proxy_sha256": source_sha,
            "image_label_matches": True,
        },
        "lifecycle": {
            "proxy_drained": True,
            "proxy_removed": True,
            "internal_network_removed": True,
            "egress_network_removed": True,
        },
        "usage": {
            "event_log_path": str(event_log),
            "event_log_sha256": _sha256(event_log),
            "event_count": 1,
            "admitted_turns": 1,
            "rejected_requests": 0,
            "input_tokens": 100,
            "output_tokens": 20,
            "budget_charged_usd": 0.1,
            "budget_overshoot_usd": 0.0,
            "inflight_requests_at_stop": 0,
            "accounting_complete": True,
        },
        "live_cap_verified": False,
        "reason": "live_cap_verification_unavailable",
    }
    evidence_path = sealed / "run.limit-evidence.json"
    evidence_path.write_bytes(module.canonical_json_bytes(evidence))
    reference = {
        "path": str(evidence_path),
        "sha256": _sha256(evidence_path),
        "schema_version": 1,
        "owner": "bench/harness.py",
    }

    assert module.validate_benchmark_limit_evidence(
        reference, execution, source_map, source_sha, expected_limits
    ) == ["live_cap_unverified"]
    evidence["live_cap_verified"] = True
    evidence["reason"] = None
    evidence_path.write_bytes(module.canonical_json_bytes(evidence))
    reference["sha256"] = _sha256(evidence_path)
    assert "live_cap_claim_unsupported" in module.validate_benchmark_limit_evidence(
        reference, execution, source_map, source_sha, expected_limits
    )


def test_cli_runs_argv_and_emits_only_the_receipt(tmp_path: Path) -> None:
    target = tmp_path / "target"
    scratch = tmp_path / "scratch"
    authority = tmp_path / "authority"
    target.mkdir()
    scratch.mkdir()
    authority.mkdir()
    policy_path = authority / "execution-policy.json"
    policy_path.write_text(json.dumps(_native_policy(target, scratch)), encoding="utf-8")
    output = authority / "invocation"
    engine = str(Path(sys.executable).resolve(strict=True))

    completed = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--cwd",
            str(target),
            "--output-dir",
            str(output),
            "--deadline-epoch",
            str(time.time() + 5),
            "--policy",
            str(policy_path),
            "--",
            engine,
            "-c",
            "print('cli')",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={"PATH": os.environ.get("PATH", "")},
    )

    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout)["command"][-1] == "print('cli')"
    assert (output / "stdout.log").read_text(encoding="utf-8") == "cli\n"
