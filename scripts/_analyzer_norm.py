#!/usr/bin/env python3
"""Bounded entrypoint for legacy raw output or trusted SARIF import receipts."""
from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import Mapping

_MAX_MANIFEST_BYTES = 128 * 1024
_MAX_IMPORTS = 16
_SHA = __import__("re").compile(r"^[0-9a-f]{64}$")
DEFAULT_LIMITS = {"max_hits": 200, "max_import_bytes": 16 * 1024 * 1024,
                  "max_results_per_import": 1000, "max_trace_steps": 32,
                  "max_string_bytes": 4096}


def _read_bounded_json(path: str, maximum: int) -> dict[str, object] | None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        return None
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
            return None
        raw = bytearray()
        while len(raw) <= maximum:
            chunk = os.read(fd, min(64 * 1024, maximum + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        after = os.fstat(fd)
        if len(raw) > maximum or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            return None
        value = json.loads(bytes(raw))
        return value if isinstance(value, dict) else None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        return None
    finally:
        os.close(fd)


def _load_raw_by_tool(manifest_path: str) -> dict[str, object]:
    manifest = _read_bounded_json(manifest_path, _MAX_MANIFEST_BYTES)
    if manifest is None:
        return {}
    raw_by_tool: dict[str, object] = {}
    for tool, raw_path in manifest.items():
        if not isinstance(raw_path, str):
            continue
        value = _read_bounded_json(raw_path, 16 * 1024 * 1024)
        if value is not None:
            raw_by_tool[tool] = value
    return raw_by_tool


def _trusted_context() -> dict[str, object] | None:
    prep = _read_bounded_json(os.environ.get("EXECUTION_PREPARATION_PATH", ""), _MAX_MANIFEST_BYTES)
    sources = _read_bounded_json(os.environ.get("SOURCE_DIGESTS_PATH", ""), 16 * 1024 * 1024)
    run_dir = os.environ.get("RUN_DIR")
    source_root = prep.get("target_root") if prep else None
    if prep is None or sources is None or not run_dir or not isinstance(source_root, str) or not Path(source_root).is_absolute():
        return None
    try:
        run = Path(run_dir).resolve(strict=True)
        root = Path(source_root).resolve(strict=True)
        if run == root or root in run.parents or prep.get("schema_version") != 1 or prep.get("target_root") != str(root):
            return None
        frozen = prep.get("source_files")
        if not isinstance(frozen, list) or len(frozen) > 100_000 or set(frozen) != set(sources):
            return None
        normalized: dict[str, str] = {}
        for name, digest in sources.items():
            if not isinstance(name, str) or not isinstance(digest, str) or not _SHA.fullmatch(digest):
                return None
            normalized[name] = digest
        canonical = hashlib.sha256(json.dumps(dict(sorted(normalized.items())), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
        configs = prep.get("analyzer_configs", [])
        if not isinstance(prep.get("run_id"), str) or not isinstance(configs, list) or len(configs) > 2:
            return None
        configured_tools = []
        for item in configs:
            if not isinstance(item, Mapping) or item.get("tool") not in {"codeql", "semgrep"}:
                return None
            configured_tools.append(item["tool"])
        if len(set(configured_tools)) != len(configured_tools):
            return None
        limits = prep.get("analyzer_limits")
        if (not isinstance(limits, Mapping) or set(limits) != set(DEFAULT_LIMITS)
                or any(type(value) is not int or not 0 < value <= 16 * 1024 * 1024
                       for value in limits.values())):
            return None
        return {"run_id": prep["run_id"], "target_root": str(root), "source_file_sha256": dict(sorted(normalized.items())),
                "source_manifest_sha256": canonical, "artifact_root": str(run / "analyzer-artifacts"),
                "receipt_root": str(run / "analyzer-artifacts"), "configured_tools": tuple(sorted(configured_tools)),
                "limits": limits}
    except OSError:
        return None


def _load_sarif_manifest(path: str, context: Mapping[str, object] | None) -> list[dict[str, object]]:
    raw = _read_bounded_json(path, _MAX_MANIFEST_BYTES)
    if raw is None or raw.get("schema_version") != 1:
        return []
    imports = raw.get("imports")
    if not isinstance(imports, list) or len(imports) > _MAX_IMPORTS:
        return []
    # The initial coordinator manifest is intentionally empty.  A non-empty
    # manifest must bind exactly to frozen coordinator state, never self-name a
    # root, source map, or tool configuration.
    if imports:
        if context is None or any(raw.get(key) != context[key] for key in ("run_id", "target_root", "source_file_sha256", "source_manifest_sha256")):
            return []
    return [item for item in imports if isinstance(item, dict)]


def _write_new(path: str, value: Mapping[str, object]) -> None:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8") + b"\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    try:
        offset = 0
        while offset < len(raw):
            offset += os.write(fd, raw[offset:])
    finally:
        os.close(fd)


def _env_int(name: str, default: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError:
        return default
    return value if 0 < value <= 16 * 1024 * 1024 else default


def main() -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from bench.scorer.analyzer_norm import import_sarif_results, normalize_hits  # noqa: E402

    max_hits = _env_int("MAX_HITS", 200)
    sarif_manifest = os.environ.get("SARIF_IMPORT_MANIFEST")
    if sarif_manifest:
        prep = _read_bounded_json(os.environ.get("EXECUTION_PREPARATION_PATH", ""), _MAX_MANIFEST_BYTES)
        if prep is None:
            print("analyzers: frozen execution preparation unavailable", file=sys.stderr)
            return 2
        if prep.get("analyzer_enabled") is not True:
            print("analyzers: disabled in frozen run configuration", file=sys.stderr)
            return 10
        context = _trusted_context()
        if context is None:
            print("analyzers: frozen source or settings unavailable", file=sys.stderr)
            return 2
        imports = _load_sarif_manifest(sarif_manifest, context)
        result = import_sarif_results(imports, context["target_root"],
                                     configured_tools=context["configured_tools"],
                                     **context["limits"], trusted_context=context)
    else:
        hits = normalize_hits(_load_raw_by_tool(os.environ["RAW_MANIFEST"]), max_hits=max_hits)
        result = {"hits": hits, "count": len(hits)}
    _write_new(sys.argv[1], result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
