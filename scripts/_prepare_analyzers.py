#!/usr/bin/env python3
"""Produce coordinator-owned, receipt-bound SARIF import descriptors.

This helper is the only analyzer producer.  It accepts only analyzer commands
already frozen in ``execution-preparation.json`` from installed host config,
and routes them through ``scripts._execution.run_command``.  It never discovers
or downloads tools.  The resulting manifest is data-only input to the SARIF
normalizer; its descriptors cannot choose a source tree or host artifact root.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import stat
import sys
import time
from pathlib import Path, PurePosixPath
from typing import Any, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts._execution import canonical_json_bytes, run_command, validate_execution_receipt

_MAX_CONFIGS = 2
_MAX_MANIFEST_BYTES = 128 * 1024
_MAX_SARIF_BYTES = 16 * 1024 * 1024
_TOOLS = frozenset({"codeql", "semgrep"})
_SHA = __import__("re").compile(r"^[0-9a-f]{64}$")


def _digest(value: object) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def _read_json(path: Path, maximum: int = _MAX_MANIFEST_BYTES) -> dict[str, object]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError("expected bounded regular JSON")
        raw = os.read(fd, maximum + 1)
        if len(raw) > maximum or os.fstat(fd).st_size != info.st_size:
            raise ValueError("JSON changed while read")
    finally:
        os.close(fd)
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("expected JSON object")
    return value


def _relative(value: object) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError("expected relative output path")
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value or any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError("expected relative output path")
    return value


def _source_identity(run: Path, state: Mapping[str, object]) -> tuple[dict[str, str], dict[str, object]]:
    sources = _read_json(run / "source-digests.json", 16 * 1024 * 1024)
    frozen = state.get("source_files")
    if not isinstance(frozen, list) or set(sources) != set(frozen) or len(sources) > 100_000:
        raise ValueError("source digest map is not the frozen full inventory")
    normalized: dict[str, str] = {}
    for path, digest in sources.items():
        _relative(path)
        if not isinstance(digest, str) or not _SHA.fullmatch(digest):
            raise ValueError("invalid source digest")
        normalized[path] = digest
    normalized = dict(sorted(normalized.items()))
    return normalized, {"kind": "content-manifest-sha256", "sha256": _digest(normalized), "source_file_sha256": normalized}


def _configurations(state: Mapping[str, object]) -> list[dict[str, object]]:
    raw = state.get("analyzer_configs", [])
    if not isinstance(raw, list) or len(raw) > _MAX_CONFIGS:
        raise ValueError("analyzer config is not bounded")
    result: list[dict[str, object]] = []
    seen: set[str] = set()
    for item in raw:
        if not isinstance(item, Mapping) or set(item) != {"tool", "tool_version", "command", "sarif_path", "uri_base_ids"}:
            raise ValueError("invalid frozen analyzer configuration")
        tool, version, command = item["tool"], item["tool_version"], item["command"]
        if tool not in _TOOLS or tool in seen or not isinstance(version, str) or not version or len(version.encode()) > 256:
            raise ValueError("invalid analyzer tool")
        if not isinstance(command, list) or not command or any(not isinstance(x, str) or not x or "\x00" in x for x in command):
            raise ValueError("invalid analyzer argv")
        sarif_path = _relative(item["sarif_path"])
        bases = item["uri_base_ids"]
        if not isinstance(bases, Mapping) or len(bases) > 32:
            raise ValueError("invalid analyzer URI bases")
        result.append({"tool": tool, "tool_version": version, "command": command, "sarif_path": sarif_path, "uri_base_ids": dict(bases)})
        seen.add(tool)
    return result


def _write_once(path: Path, value: Mapping[str, object]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    raw = canonical_json_bytes(value)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    try:
        os.write(fd, raw)
    finally:
        os.close(fd)


def _publish_manifest(run: Path, value: Mapping[str, object]) -> None:
    """Keep a write-once history while atomically advancing the public pointer."""
    history = run / "analyzer-artifacts" / "manifest-history" / (hashlib.sha256(canonical_json_bytes(value)).hexdigest() + ".json")
    _write_once(history, value)
    destination = run / "analyzer-imports.json"
    temporary = destination.with_name("." + destination.name + ".next")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError("manifest temporary path already exists")
    _write_once(temporary, value)
    os.replace(temporary, destination)


def produce(run_dir: Path | str) -> dict[str, object]:
    run = Path(run_dir).resolve(strict=True)
    state = _read_json(run / "execution-preparation.json")
    if state.get("schema_version") != 1 or not isinstance(state.get("run_id"), str) or not isinstance(state.get("target_root"), str):
        raise ValueError("invalid execution preparation")
    if state.get("analyzer_enabled") is not True:
        return {"available": False, "reason": "analyzers_disabled"}
    target = Path(state["target_root"]).resolve(strict=True)
    sources, identity = _source_identity(run, state)
    configs = _configurations(state)
    timeout = state.get("analyzer_timeout_seconds", 300)
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("analyzer timeout must be positive and finite")
    artifact_root = run / "analyzer-artifacts"
    artifact_root.mkdir(mode=0o700, exist_ok=True)
    if artifact_root.is_symlink() or artifact_root.resolve(strict=True) != artifact_root:
        raise ValueError("analyzer artifact root is not canonical")
    imports: list[dict[str, object]] = []
    policy_base = state.get("policy")
    policy = {**policy_base, "target_root": str(target), "source_identity": identity} if isinstance(policy_base, Mapping) else None
    for config in configs:
        tool = str(config["tool"])
        invocation_dir = artifact_root / tool
        deadline = min(float(state["deadline_epoch"]), time.time() + timeout)
        receipt = run_command(config["command"], target, invocation_dir, deadline, policy,
                              predeclared_outputs=({"path": config["sarif_path"], "kind": "sarif", "max_bytes": _MAX_SARIF_BYTES},))
        reasons = validate_execution_receipt(receipt, sources)
        outputs = receipt.get("outputs") if isinstance(receipt, Mapping) else None
        output = next((item for item in outputs or [] if isinstance(item, Mapping) and item.get("kind") == "sarif"), None)
        expected_receipt = invocation_dir / "execution-receipt.json"
        if (reasons or receipt.get("command") != config["command"] or receipt.get("command_sha256") != _digest(config["command"])
                or not isinstance(output, Mapping) or output.get("path") is None or output.get("sha256") is None
                or output.get("bytes") is None or not expected_receipt.is_file() or expected_receipt.is_symlink()):
            continue
        artifact = Path(str(output["path"]))
        if artifact.is_symlink() or artifact.resolve(strict=True) != artifact or artifact_root not in artifact.parents:
            continue
        receipt_sha = hashlib.sha256(expected_receipt.read_bytes()).hexdigest()
        analysis_receipt = {
            "schema_version": 1, "run_id": state["run_id"], "target_root": str(target),
            "tool": tool, "tool_version": config["tool_version"], "command": config["command"],
            "command_sha256": _digest(config["command"]), "source_identity": identity,
            "source_file_sha256": sources, "source_manifest_sha256": identity["sha256"],
            "uri_base_ids": config["uri_base_ids"], "execution_receipt_path": str(expected_receipt),
            "execution_receipt_sha256": receipt_sha, "artifact_path": str(artifact),
            "artifact_sha256": output["sha256"], "artifact_bytes": output["bytes"],
        }
        analysis_path = invocation_dir / "analysis-receipt.json"
        _write_once(analysis_path, analysis_receipt)
        imports.append({"tool": tool, "analysis_receipt_path": str(analysis_path),
                        "analysis_receipt_sha256": hashlib.sha256(analysis_path.read_bytes()).hexdigest()})
    manifest: dict[str, object] = {"schema_version": 1, "run_id": state["run_id"], "target_root": str(target),
        "source_identity": identity, "source_file_sha256": sources, "source_manifest_sha256": identity["sha256"],
        "configured_tools": [config["tool"] for config in configs], "imports": imports}
    _publish_manifest(run, manifest)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir")
    args = parser.parse_args()
    try:
        print(canonical_json_bytes(produce(args.run_dir)).decode())
    except (OSError, ValueError, TypeError, UnicodeError, json.JSONDecodeError) as exc:
        print(canonical_json_bytes({"available": False, "error": str(exc)}).decode())
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
