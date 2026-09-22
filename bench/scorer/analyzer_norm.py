"""Normalize raw off-the-shelf static-analyzer output into one hit shape (bugsweep-042).

The current producer runs explicitly configured CodeQL/Semgrep commands through
the shared provider. ``scripts/analyzers.sh`` imports the receipt-bound SARIF.
Legacy raw parsers remain for historical fixtures. This module treats all tool
output as untrusted data and produces a deduped, capped, ordered hit list:

    {tool, rule_id, severity, file, line, message}

``severity`` is normalized to the closed set ``critical|high|medium|low`` (see
``_SEVERITY_MAP`` below for the per-tool mapping). Consumers:

* ``prompts/hunt.md`` — the Hunter reads ``analyzer-hits.json`` as candidate
  SEEDS (locations to prioritize investigating), never as pre-confirmed
  findings — every seed still requires full independent verification.
* Model reviews may inspect the cited source, but an analyzer hit never changes
  confidence, confirms a bug, or removes the normal proof requirements.

Design mirrors ``bench/scorer/run_summary.py``: a pure function, no
subprocess, no network, never raises on malformed/missing per-tool input —
retain explicit unavailable/rejected states instead of calling missing evidence
a completed zero-hit scan.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable, Mapping
from urllib.parse import unquote, urlsplit

#: Hits are capped and ordered by this rank (index 0 = kept first on cap / tie-break).
_SEVERITY_ORDER: tuple[str, ...] = ("critical", "high", "medium", "low")
_SEVERITY_RANK: dict[str, int] = {name: i for i, name in enumerate(_SEVERITY_ORDER)}
_DEFAULT_MAX_HITS = 200
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_SUPPORTED_SARIF_TOOLS = frozenset({"codeql", "semgrep"})
_DEFAULT_MAX_IMPORT_BYTES = 16 * 1024 * 1024
_DEFAULT_MAX_RESULTS_PER_IMPORT = 1_000
_DEFAULT_MAX_TRACE_STEPS = 32
_DEFAULT_MAX_STRING_BYTES = 4 * 1024
_DEFAULT_MAX_REGION = 10_000_000
_MAX_IMPORTS = 16

# This is deliberately a capability statement, not a parser claim.  Imported
# CodeQL/Semgrep results can carry precise cross-file paths for the first
# supported stacks; Bugsweep itself does not build graphs for other languages.
_CAPABILITY_LANGUAGES = {
    "python": "precise_semantic",
    "javascript": "precise_semantic",
    "typescript": "precise_semantic",
    "go": "heuristic_file",
    "java": "heuristic_file",
    "other": "heuristic_file",
}

#: Per-tool raw severity token (uppercased) -> normalized bugsweep severity.
#: Anything not listed here (including a missing/unrecognized token) falls back
#: to "low" — never invent a higher severity than the tool actually reported.
_SEMGREP_SEVERITY_MAP: dict[str, str] = {
    "ERROR": "critical",
    "WARNING": "medium",
    "INFO": "low",
}
_GOSEC_SEVERITY_MAP: dict[str, str] = {
    "HIGH": "high",
    "MEDIUM": "medium",
    "LOW": "low",
}
_BANDIT_SEVERITY_MAP: dict[str, str] = {
    "HIGH": "high",
    "MEDIUM": "medium",
    "LOW": "low",
}


def _normalize_severity(raw: Any, mapping: dict[str, str]) -> str:
    token = str(raw).strip().upper() if raw is not None else ""
    return mapping.get(token, "low")


def _as_int_or_none(value: Any) -> int | None:
    if isinstance(value, bool):  # bool is an int subclass; never treat as a line number
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        stripped = value.strip()
        if stripped.lstrip("-").isdigit():
            return int(stripped)
    return None


def _parse_semgrep(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        return []
    results = raw.get("results")
    if not isinstance(results, list):
        return []
    hits: list[dict[str, Any]] = []
    for r in results:
        if not isinstance(r, dict):
            continue
        extra = r.get("extra") if isinstance(r.get("extra"), dict) else {}
        hits.append(
            {
                "tool": "semgrep",
                "rule_id": r.get("check_id"),
                "severity": _normalize_severity(extra.get("severity"), _SEMGREP_SEVERITY_MAP),
                "file": r.get("path"),
                "line": _as_int_or_none((r.get("start") or {}).get("line")),
                "message": extra.get("message"),
            }
        )
    return hits


def _parse_gosec(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        return []
    issues = raw.get("Issues")
    if not isinstance(issues, list):
        return []
    hits: list[dict[str, Any]] = []
    for r in issues:
        if not isinstance(r, dict):
            continue
        hits.append(
            {
                "tool": "gosec",
                "rule_id": r.get("rule_id"),
                "severity": _normalize_severity(r.get("severity"), _GOSEC_SEVERITY_MAP),
                "file": r.get("file"),
                "line": _as_int_or_none(r.get("line")),
                "message": r.get("details"),
            }
        )
    return hits


def _parse_bandit(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        return []
    results = raw.get("results")
    if not isinstance(results, list):
        return []
    hits: list[dict[str, Any]] = []
    for r in results:
        if not isinstance(r, dict):
            continue
        hits.append(
            {
                "tool": "bandit",
                "rule_id": r.get("test_id"),
                "severity": _normalize_severity(r.get("issue_severity"), _BANDIT_SEVERITY_MAP),
                "file": r.get("filename"),
                "line": _as_int_or_none(r.get("line_number")),
                "message": r.get("issue_text"),
            }
        )
    return hits


#: One parser per supported tool. Adding a new analyzer to scripts/analyzers.sh's
#: detection table only requires a matching entry here — same "easily extensible
#: table" pattern the bead asks the shell side to follow.
_PARSERS: dict[str, Callable[[Any], list[dict[str, Any]]]] = {
    "semgrep": _parse_semgrep,
    "gosec": _parse_gosec,
    "bandit": _parse_bandit,
}


def _dedup_key(hit: dict[str, Any]) -> tuple[Any, ...]:
    return (hit["tool"], hit["rule_id"], hit["file"], hit["line"], hit["message"])


def normalize_hits(
    raw_by_tool: dict[str, Any],
    max_hits: int = _DEFAULT_MAX_HITS,
) -> list[dict[str, Any]]:
    """Reduce ``{tool_name: raw_tool_json}`` into one normalized hit list.

    Pure function: never raises. A tool with no parser, or whose payload
    doesn't match its expected shape, silently contributes zero hits — this
    is a best-effort enhancement layer (see analyzers.sh header), not a
    contract any single tool's output must satisfy.

    Output is:
      * deduped on (tool, rule_id, file, line, message);
      * ordered by severity (critical > high > medium > low) then by
        (tool, rule_id, file, line) for a fully deterministic tie-break;
      * capped at ``max_hits``, keeping the highest-severity hits first.
    """
    hits: list[dict[str, Any]] = []
    seen: set[tuple[Any, ...]] = set()

    for tool_name, raw in (raw_by_tool or {}).items():
        parser = _PARSERS.get(tool_name)
        if parser is None:
            continue
        for hit in parser(raw):
            key = _dedup_key(hit)
            if key in seen:
                continue
            seen.add(key)
            hits.append(hit)

    def _sort_key(hit: dict[str, Any]) -> tuple[Any, ...]:
        rank = _SEVERITY_RANK.get(hit["severity"], len(_SEVERITY_ORDER))
        return (
            rank,
            str(hit.get("tool") or ""),
            str(hit.get("rule_id") or ""),
            str(hit.get("file") or ""),
            hit.get("line") if hit.get("line") is not None else -1,
        )

    hits.sort(key=_sort_key)

    cap = max_hits if isinstance(max_hits, int) and max_hits >= 0 else _DEFAULT_MAX_HITS
    return hits[:cap]


def _canonical_digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ).hexdigest()


def _bounded_string(value: object, limit: int) -> str | None:
    if not isinstance(value, str) or "\x00" in value or len(value.encode("utf-8")) > limit:
        return None
    return value


def _relative_path(value: object) -> str | None:
    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        return None
    path = PurePosixPath(value)
    if path.is_absolute() or value != path.as_posix() or any(part in {"", ".", ".."} for part in path.parts):
        return None
    return value


def _digest_file(path: Path, max_bytes: int) -> tuple[str, int] | None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        return None
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > max_bytes:
            return None
        digest = hashlib.sha256()
        size = 0
        while True:
            chunk = os.read(fd, 64 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > max_bytes:
                return None
            digest.update(chunk)
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            return None
        return digest.hexdigest(), size
    finally:
        os.close(fd)


def _within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _read_regular_bytes(path: Path, max_bytes: int) -> bytes | None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        return None
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > max_bytes:
            return None
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, min(64 * 1024, max_bytes + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                return None
            chunks.append(chunk)
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            return None
        return b"".join(chunks)
    finally:
        os.close(fd)


def _trusted_context(raw: object, source_root: Path) -> tuple[dict[str, str], str, Path, Path, str] | tuple[None, str, None, None, None]:
    """Validate coordinator state supplied out-of-band from import descriptors.

    Descriptors are untrusted data.  They cannot choose the source inventory,
    execution receipt location, or artifact root; those are fixed by the
    coordinator-owned preparation/readback state passed by the entrypoint.
    """
    if not isinstance(raw, Mapping):
        return None, "trusted_context_missing", None, None, None
    run_id = raw.get("run_id")
    target_root = raw.get("target_root")
    source_files, manifest_sha = _source_map(raw.get("source_file_sha256"))
    artifact_root_raw, receipt_root_raw = raw.get("artifact_root"), raw.get("receipt_root")
    if (
        not isinstance(run_id, str) or not run_id or len(run_id.encode("utf-8")) > 256
        or not isinstance(target_root, str) or target_root != str(source_root)
        or source_files is None or raw.get("source_manifest_sha256") != manifest_sha
        or not isinstance(artifact_root_raw, str) or not isinstance(receipt_root_raw, str)
    ):
        return None, "trusted_context_invalid", None, None, None
    try:
        artifact_root, receipt_root = Path(artifact_root_raw).resolve(strict=True), Path(receipt_root_raw).resolve(strict=True)
        if (not Path(artifact_root_raw).is_absolute() or Path(artifact_root_raw) != artifact_root
                or not Path(receipt_root_raw).is_absolute() or Path(receipt_root_raw) != receipt_root
                or not artifact_root.is_dir() or not receipt_root.is_dir()):
            return None, "trusted_context_invalid", None, None, None
    except OSError:
        return None, "trusted_context_invalid", None, None, None
    return source_files, manifest_sha, artifact_root, receipt_root, run_id


def _provider_receipt(
    descriptor: Mapping[str, object], source_root: Path, context: tuple[dict[str, str], str, Path, Path, str], max_bytes: int
) -> tuple[Mapping[str, object], Path, str, int] | tuple[None, None, str, None]:
    """Read a coordinator analysis receipt and verify its provider receipt.

    The outer descriptor is merely a pointer.  Every tool, source, command,
    URI-base and artifact claim comes from the write-once analysis receipt;
    the execution provider then validates Docker readback from its own
    authority files.  No descriptor-supplied root or capability flag is used.
    """
    source_files, source_sha, artifact_root, receipt_root, run_id = context
    path_raw, expected_sha = descriptor.get("analysis_receipt_path"), descriptor.get("analysis_receipt_sha256")
    if not isinstance(path_raw, str) or not isinstance(expected_sha, str) or not _SHA256_RE.fullmatch(expected_sha):
        return None, None, "analysis_receipt_invalid", None
    try:
        path = Path(path_raw)
        resolved = path.resolve(strict=True)
        if not path.is_absolute() or path != resolved or path.is_symlink() or not _within(resolved, receipt_root):
            return None, None, "analysis_receipt_untrusted", None
    except OSError:
        return None, None, "analysis_receipt_unavailable", None
    observed_receipt = _digest_file(resolved, 128 * 1024)
    if observed_receipt is None or observed_receipt[0] != expected_sha:
        return None, None, "analysis_receipt_changed", None
    analysis_raw = _read_regular_bytes(resolved, 128 * 1024)
    try:
        analysis = json.loads(analysis_raw) if analysis_raw is not None and hashlib.sha256(analysis_raw).hexdigest() == expected_sha else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        analysis = None
    if analysis is None:
        return None, None, "analysis_receipt_unparseable", None
    if not isinstance(analysis, Mapping):
        return None, None, "analysis_receipt_invalid", None
    tool, version = analysis.get("tool"), analysis.get("tool_version")
    source = analysis.get("source_identity")
    command, command_sha = analysis.get("command"), analysis.get("command_sha256")
    execution_path, execution_sha = analysis.get("execution_receipt_path"), analysis.get("execution_receipt_sha256")
    artifact_path, artifact_sha, artifact_bytes = analysis.get("artifact_path"), analysis.get("artifact_sha256"), analysis.get("artifact_bytes")
    if (
        analysis.get("schema_version") != 1 or analysis.get("run_id") != run_id
        or analysis.get("target_root") != str(source_root) or tool not in _SUPPORTED_SARIF_TOOLS
        or not isinstance(version, str) or not version or len(version.encode("utf-8")) > 256
        or not isinstance(source, Mapping) or source != {"kind": "content-manifest-sha256", "sha256": source_sha, "source_file_sha256": source_files}
        or analysis.get("source_file_sha256") != source_files or analysis.get("source_manifest_sha256") != source_sha
        or not isinstance(command, list) or not command or any(not isinstance(x, str) or not x or "\x00" in x for x in command)
        or not isinstance(command_sha, str) or _canonical_digest(command) != command_sha
        or not isinstance(execution_path, str) or not isinstance(execution_sha, str) or not _SHA256_RE.fullmatch(execution_sha)
        or not isinstance(artifact_path, str) or not isinstance(artifact_sha, str) or not _SHA256_RE.fullmatch(artifact_sha)
        or not isinstance(artifact_bytes, int) or isinstance(artifact_bytes, bool) or not 0 <= artifact_bytes <= max_bytes
    ):
        return None, None, "analysis_receipt_unbound", None
    try:
        execution = Path(execution_path)
        execution_resolved = execution.resolve(strict=True)
        artifact = Path(artifact_path)
        artifact_resolved = artifact.resolve(strict=True)
        if (not execution.is_absolute() or execution != execution_resolved or execution.is_symlink() or not _within(execution_resolved, receipt_root)
                or not artifact.is_absolute() or artifact != artifact_resolved or artifact.is_symlink() or not _within(artifact_resolved, artifact_root)):
            return None, None, "provider_path_untrusted", None
    except OSError:
        return None, None, "provider_artifact_unavailable", None
    execution_observed = _digest_file(execution_resolved, max_bytes)
    if execution_observed is None or execution_observed[0] != execution_sha:
        return None, None, "execution_receipt_changed", None
    execution_raw = _read_regular_bytes(execution_resolved, max_bytes)
    try:
        execution_value = json.loads(execution_raw) if execution_raw is not None and hashlib.sha256(execution_raw).hexdigest() == execution_sha else None
        from scripts._execution import validate_execution_receipt
        reasons = validate_execution_receipt(execution_value, source_files, required_network="denied")
    except (ImportError, UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
        return None, None, "execution_receipt_invalid", None
    if execution_value is None:
        return None, None, "execution_receipt_changed", None
    outputs = execution_value.get("outputs") if isinstance(execution_value, Mapping) else None
    sarif_output = next((item for item in outputs or [] if isinstance(item, Mapping) and item.get("kind") == "sarif"), None)
    if (
        reasons or not isinstance(execution_value, Mapping) or execution_value.get("command") != command
        or execution_value.get("command_sha256") != command_sha or not isinstance(sarif_output, Mapping)
        or sarif_output.get("path") != str(artifact_resolved) or sarif_output.get("sha256") != artifact_sha
        or sarif_output.get("bytes") != artifact_bytes
    ):
        return None, None, "execution_receipt_unverified", None
    observed = _digest_file(artifact_resolved, max_bytes)
    if observed is None or observed[0] != artifact_sha or observed[1] != artifact_bytes:
        return None, None, "artifact_digest_mismatch", None
    return analysis, artifact_resolved, artifact_sha, artifact_bytes


def _source_map(raw: object) -> tuple[dict[str, str], str | None]:
    if not isinstance(raw, Mapping) or not raw or len(raw) > 10_000:
        return {}, None
    result: dict[str, str] = {}
    for name, digest in raw.items():
        path = _relative_path(name)
        if path is None or not isinstance(digest, str) or not _SHA256_RE.fullmatch(digest):
            return {}, None
        result[path] = digest
    return dict(sorted(result.items())), _canonical_digest(dict(sorted(result.items())))


def _source_identity(raw: Mapping[str, object]) -> tuple[dict[str, str], str] | tuple[None, str]:
    identity = raw.get("source_identity")
    if not isinstance(identity, Mapping) or set(identity) - {"kind", "sha256", "source_file_sha256"}:
        return None, "source_identity_invalid"
    digest = identity.get("sha256")
    descriptor_files = raw.get("source_file_sha256")
    embedded_files = identity.get("source_file_sha256")
    if descriptor_files is not None and embedded_files is not None and descriptor_files != embedded_files:
        return None, "source_identity_mismatch"
    mapped, computed = _source_map(
        descriptor_files if descriptor_files is not None else embedded_files
    )
    if (
        identity.get("kind") != "content-manifest-sha256"
        or not isinstance(digest, str)
        or not _SHA256_RE.fullmatch(digest)
        or computed != digest
    ):
        return None, "source_identity_mismatch"
    return mapped, digest


def _current_source_map_matches(source_root: Path, source_files: Mapping[str, str]) -> bool:
    """Verify the coordinator's complete direct map still matches this tree."""
    for relative, expected in source_files.items():
        candidate = source_root / relative
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            return False
        if resolved != candidate or not _within(resolved, source_root):
            return False
        observed = _digest_file(resolved, 128 * 1024 * 1024)
        if observed is None or observed[0] != expected:
            return False
    return True


def _strict_unquote(value: str) -> str | None:
    if re.search(r"%(?![0-9A-Fa-f]{2})", value):
        return None
    decoded = unquote(value)
    # A second encoded separator/traversal is ambiguous evidence, not a path.
    if "\x00" in decoded or re.search(r"%[0-9A-Fa-f]{2}", decoded):
        return None
    return decoded


def _base_roots(raw: object, source_root: Path) -> dict[str, Path] | None:
    if raw is None:
        return {}
    if not isinstance(raw, Mapping) or len(raw) > 32:
        return None
    bases: dict[str, Path] = {}
    for base_id, relative in raw.items():
        if not isinstance(base_id, str) or not base_id or len(base_id.encode("utf-8")) > 256:
            return None
        path = _relative_path(relative)
        if path is None and relative != ".":
            return None
        candidate = source_root if relative == "." else source_root / path
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            return None
        if candidate != resolved or not resolved.is_dir() or not _within(resolved, source_root):
            return None
        bases[base_id] = resolved
    return bases


def _resolve_location(
    raw: object,
    source_root: Path,
    base_roots: Mapping[str, Path],
    source_files: Mapping[str, str],
    source_map_current: bool,
    max_string_bytes: int,
) -> tuple[dict[str, object] | None, str | None]:
    if not isinstance(raw, Mapping):
        return None, "location_invalid"
    physical = raw.get("physicalLocation")
    if not isinstance(physical, Mapping):
        return None, "location_invalid"
    artifact = physical.get("artifactLocation")
    if not isinstance(artifact, Mapping):
        return None, "location_invalid"
    uri = _bounded_string(artifact.get("uri"), max_string_bytes)
    base_id = artifact.get("uriBaseId")
    if uri is None or (base_id is not None and not isinstance(base_id, str)):
        return None, "location_invalid"
    parsed = urlsplit(uri)
    if parsed.query or parsed.fragment or parsed.netloc:
        return None, "uri_query_fragment_or_authority"
    if parsed.scheme:
        if parsed.scheme != "file" or parsed.netloc:
            return None, "uri_scheme_rejected"
        decoded = _strict_unquote(parsed.path)
        if decoded is None or "\\" in decoded or re.match(r"^[A-Za-z]:", decoded):
            return None, "uri_path_rejected"
        candidate = Path(decoded)
        if not candidate.is_absolute():
            return None, "file_uri_not_absolute"
        allowed = base_roots.get(base_id, source_root) if base_id else source_root
    else:
        decoded = _strict_unquote(uri)
        relative = _relative_path(decoded) if decoded is not None else None
        if relative is None:
            return None, "relative_uri_rejected"
        if base_id is not None:
            if base_id not in base_roots:
                return None, "uri_base_unmapped"
            allowed = base_roots[base_id]
        else:
            allowed = source_root
        candidate = allowed / relative
    try:
        # Existing paths must not use a symlink to turn an apparently in-scope
        # URI into an out-of-scope source reference.
        resolved = candidate.resolve(strict=True)
        if not _within(resolved, allowed) or not _within(resolved, source_root):
            return None, "source_path_escape"
        if resolved != candidate:
            return None, "source_path_symlink"
    except OSError:
        parent = candidate.parent.resolve(strict=False)
        if not _within(parent, allowed) or not _within(parent, source_root):
            return None, "source_path_escape"
        resolved = candidate
    try:
        relative_path = resolved.relative_to(source_root).as_posix()
    except ValueError:
        return None, "source_path_escape"
    if _relative_path(relative_path) is None:
        return None, "source_path_escape"
    region = physical.get("region") if isinstance(physical.get("region"), Mapping) else {}
    region_values: dict[str, int | None] = {}
    for field in ("startLine", "startColumn", "endLine", "endColumn"):
        raw_value = region.get(field)
        value = _as_int_or_none(raw_value)
        if raw_value is not None and (value is None or not 1 <= value <= _DEFAULT_MAX_REGION):
            return None, "region_out_of_bounds"
        region_values[field] = value
    line, column = region_values["startLine"], region_values["startColumn"]
    if region_values["endLine"] is not None and line is not None and region_values["endLine"] < line:
        return None, "region_out_of_bounds"
    evidence_status, evidence_reason = "unverified", "source_digest_missing"
    expected = source_files.get(relative_path)
    if not source_map_current:
        evidence_reason = "source_manifest_mismatch"
    elif expected is not None and resolved.is_file():
        observed = _digest_file(resolved, 128 * 1024 * 1024)
        if observed is not None and observed[0] == expected:
            evidence_status, evidence_reason = "verified", None
        else:
            evidence_reason = "source_digest_mismatch"
    location: dict[str, object] = {"file": relative_path, "line": line, "column": column}
    location["evidence_status"] = evidence_status
    if evidence_reason is not None:
        location["evidence_reason"] = evidence_reason
    return location, None


def _sarif_severity(level: object) -> str:
    return {"error": "critical", "warning": "medium", "note": "low", "none": "low"}.get(
        str(level).lower(), "low"
    )


def _sarif_driver_matches(tool: str, run: Mapping[str, object], max_string_bytes: int) -> bool:
    metadata = run.get("tool")
    driver = metadata.get("driver") if isinstance(metadata, Mapping) else None
    name = _bounded_string(driver.get("name"), max_string_bytes) if isinstance(driver, Mapping) else None
    return name is not None and name.lower().replace("-", "") == tool


def _trace(
    result: Mapping[str, object], source_root: Path, base_roots: Mapping[str, Path], source_files: Mapping[str, str], source_map_current: bool, max_steps: int, max_string_bytes: int
) -> list[dict[str, object]]:
    flows = result.get("codeFlows")
    if not isinstance(flows, list):
        return []
    trace: list[dict[str, object]] = []
    for flow in flows:
        if len(trace) >= max_steps or not isinstance(flow, Mapping):
            break
        threads = flow.get("threadFlows")
        if not isinstance(threads, list):
            continue
        for thread in threads:
            if len(trace) >= max_steps or not isinstance(thread, Mapping):
                break
            locations = thread.get("locations")
            if not isinstance(locations, list):
                continue
            for step in locations:
                if len(trace) >= max_steps:
                    break
                wrapped = step.get("location") if isinstance(step, Mapping) else None
                location, _ = _resolve_location(wrapped, source_root, base_roots, source_files, source_map_current, max_string_bytes)
                if location is not None:
                    trace.append({key: value for key, value in location.items() if key in {"file", "line", "column"}})
    return trace


def import_sarif_results(
    imports: Iterable[Mapping[str, object]] | None,
    source_root: Path | str,
    *,
    configured_tools: Iterable[str] = (),
    max_hits: int = _DEFAULT_MAX_HITS,
    max_import_bytes: int = _DEFAULT_MAX_IMPORT_BYTES,
    max_results_per_import: int = _DEFAULT_MAX_RESULTS_PER_IMPORT,
    max_trace_steps: int = _DEFAULT_MAX_TRACE_STEPS,
    max_string_bytes: int = _DEFAULT_MAX_STRING_BYTES,
    trusted_context: Mapping[str, object] | None = None,
) -> dict[str, object]:
    """Import configured SARIF 2.1 reports as data-only analyzer hints.

    This function never starts a tool or network request.  A configured tool
    with no accepted artifact remains ``unavailable``/``rejected`` rather than
    silently becoming a zero-finding scan.  Imported paths and traces are
    ranking hints only; callers must not use them to remove scope or confirm a
    finding.
    """
    max_hits = _bounded_limit(max_hits, _DEFAULT_MAX_HITS, 2_000)
    max_import_bytes = _bounded_limit(max_import_bytes, _DEFAULT_MAX_IMPORT_BYTES, _DEFAULT_MAX_IMPORT_BYTES)
    max_results_per_import = _bounded_limit(max_results_per_import, _DEFAULT_MAX_RESULTS_PER_IMPORT, 2_000)
    max_trace_steps = _bounded_limit(max_trace_steps, _DEFAULT_MAX_TRACE_STEPS, 64)
    max_string_bytes = _bounded_limit(max_string_bytes, _DEFAULT_MAX_STRING_BYTES, 4 * 1024)
    tools = tuple(sorted({tool for tool in configured_tools if tool in _SUPPORTED_SARIF_TOOLS}))
    availability: dict[str, dict[str, str]] = {
        tool: {"state": "unavailable", "reason": "artifact_not_imported"} for tool in tools
    }
    report: dict[str, object] = {
        "schema_version": 1,
        "analysis_ran": False,
        "ranking_hints_only": True,
        "count": 0,
        "hits": [],
        "imports": [],
        "availability": availability,
        "capabilities": {"languages": dict(_CAPABILITY_LANGUAGES)},
    }
    try:
        root = Path(source_root).resolve(strict=True)
    except OSError:
        for status in availability.values():
            status.update({"state": "unavailable", "reason": "source_root_unavailable"})
        return report
    if not root.is_dir():
        return report
    context = _trusted_context(trusted_context, root)
    raw_imports: list[Mapping[str, object]] = []
    try:
        iterator = iter(imports or ())
        for _ in range(_MAX_IMPORTS + 1):
            descriptor = next(iterator, None)
            if descriptor is None:
                break
            if len(raw_imports) >= _MAX_IMPORTS:
                for status in availability.values():
                    status.update({"state": "rejected", "reason": "import_count_exceeded"})
                return report
            if isinstance(descriptor, Mapping):
                raw_imports.append(descriptor)
    except TypeError:
        return report
    all_hits: list[dict[str, Any]] = []
    import_records: list[dict[str, object]] = []
    outcomes: dict[str, list[dict[str, str]]] = {tool: [] for tool in tools}
    for descriptor in raw_imports:
        if not isinstance(descriptor, Mapping):
            continue
        if context[0] is None:
            continue
        tool = descriptor.get("tool")
        if tool not in tools:
            continue
        analysis, artifact, artifact_reason, artifact_size = _provider_receipt(descriptor, root, context, max_import_bytes)
        if analysis is None or artifact is None:
            outcomes[tool].append({"state": "rejected", "reason": artifact_reason})
            continue
        if analysis.get("tool") != tool:
            outcomes[tool].append({"state": "rejected", "reason": "analysis_receipt_tool_mismatch"})
            continue
        version = _bounded_string(analysis.get("tool_version"), 256)
        source_files, identity = _source_identity(analysis)
        bases = _base_roots(analysis.get("uri_base_ids"), root)
        if source_files is None or identity != context[1] or source_files != context[0] or bases is None:
            outcomes[tool].append({"state": "rejected", "reason": "source_or_provenance_invalid"})
            continue
        source_map_current = _current_source_map_matches(root, context[0])
        try:
            raw_payload = _read_regular_bytes(artifact, max_import_bytes)
            if raw_payload is None or len(raw_payload) > max_import_bytes or hashlib.sha256(raw_payload).hexdigest() != artifact_reason:
                outcomes[tool].append({"state": "rejected", "reason": "artifact_changed"})
                continue
            payload = json.loads(raw_payload)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            outcomes[tool].append({"state": "rejected", "reason": "sarif_unparseable"})
            continue
        if not isinstance(payload, Mapping) or payload.get("version") != "2.1.0":
            outcomes[tool].append({"state": "rejected", "reason": "unsupported_sarif_version"})
            continue
        runs = payload.get("runs")
        if (
            not isinstance(runs, list)
            or not runs
            or len(runs) > 64
            or any(
                not isinstance(run, Mapping)
                or not _sarif_driver_matches(tool, run, max_string_bytes)
                or (run.get("results") is not None and not isinstance(run.get("results"), list))
                for run in runs
            )
        ):
            outcomes[tool].append({"state": "rejected", "reason": "sarif_runs_invalid"})
            continue
        accepted = 0
        rejected = 0
        result_rows = 0
        for run in runs:
            if not isinstance(run, Mapping):
                rejected += 1
                continue
            results = run.get("results") or []
            if len(results) > max_results_per_import:
                # A truncated run cannot truthfully be called an imported zero.
                rejected += len(results)
                result_rows += len(results)
                break
            for result in results:
                if len(all_hits) >= max_hits:
                    break
                result_rows += 1
                if not isinstance(result, Mapping):
                    rejected += 1
                    continue
                rule_id = _bounded_string(result.get("ruleId"), max_string_bytes)
                message = result.get("message")
                text = _bounded_string(message.get("text"), max_string_bytes) if isinstance(message, Mapping) else None
                locations = result.get("locations")
                primary = locations[0] if isinstance(locations, list) and locations else None
                location, _ = _resolve_location(primary, root, bases, source_files, source_map_current, max_string_bytes)
                if rule_id is None or text is None or location is None:
                    rejected += 1
                    continue
                hit: dict[str, Any] = {
                    "tool": tool,
                    "rule_id": rule_id,
                    "severity": _sarif_severity(result.get("level")),
                    "file": location["file"],
                    "line": location["line"],
                    "message": text,
                    "evidence_status": location["evidence_status"],
                    "provenance": {
                        "tool": tool,
                        "tool_version": version,
                        "artifact_sha256": artifact_reason,
                        "source_manifest_sha256": identity,
                        "analysis_receipt_sha256": descriptor.get("analysis_receipt_sha256"),
                        "execution_receipt_sha256": analysis.get("execution_receipt_sha256"),
                        "command_sha256": analysis.get("command_sha256"),
                    },
                }
                if "evidence_reason" in location:
                    hit["evidence_reason"] = location["evidence_reason"]
                trace = _trace(result, root, bases, source_files, source_map_current, max_trace_steps, max_string_bytes)
                if trace:
                    hit["trace"] = trace
                all_hits.append(hit)
                accepted += 1
        import_records.append(
            {
                "tool": tool,
                "tool_version": version,
                "artifact_sha256": artifact_reason,
                "artifact_bytes": artifact_size,
                "source_manifest_sha256": identity,
                "source_manifest_current": source_map_current,
                "accepted_results": min(accepted, 2_000),
                "rejected_results": min(rejected, 2_000),
                "analysis_receipt_sha256": descriptor.get("analysis_receipt_sha256"),
                "execution_receipt_sha256": analysis.get("execution_receipt_sha256"),
                "command_sha256": analysis.get("command_sha256"),
            }
        )
        outcomes[tool].append(
            {"state": "rejected", "reason": "result_count_exceeded"}
            if rejected >= max_results_per_import and result_rows >= max_results_per_import
            else ({"state": "rejected", "reason": "no_accepted_results"}
                  if result_rows and not accepted else {"state": "imported", "reason": "imported"})
        )
    for tool, tool_outcomes in outcomes.items():
        # A contradictory descriptor set remains rejected; a later success
        # must never erase an earlier provenance failure.
        rejected = next((item for item in tool_outcomes if item["state"] == "rejected"), None)
        if rejected is not None:
            # Treat contradictory descriptors for one tool as a rejected set;
            # do not retain hints while describing that tool as unavailable.
            all_hits[:] = [hit for hit in all_hits if hit.get("tool") != tool]
            availability[tool] = rejected
        elif tool_outcomes:
            availability[tool] = tool_outcomes[-1]
    all_hits.sort(key=lambda hit: (_SEVERITY_RANK.get(hit["severity"], 99), hit["tool"], hit["rule_id"], hit["file"], hit["line"] or -1))
    report["hits"] = all_hits[:max_hits]
    report["count"] = len(report["hits"])
    report["imports"] = import_records
    return report


def _bounded_limit(value: object, default: int, maximum: int) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 < value <= maximum else default
