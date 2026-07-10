#!/usr/bin/env python3
"""I/O boundary for ``scripts/priority-context.sh``.

All repository-derived prose is treated as bounded data.  Git is invoked only
with local read operations; issue and project signal adapters read local JSONL
files and never call a tracker CLI or a network service.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from bench.scorer.priority_context import (  # noqa: E402
    build_priority_context,
    normalize_repo_path,
    reprioritize_recon,
    sanitize_text,
)

HARD_RECENT_COMMITS = 500
HARD_LOCAL_ISSUES = 50
HARD_PROJECT_SIGNALS = 50
HARD_SIGNAL_FILES = 5
HARD_SIGNAL_PATHS_PER_RECORD = 200
HARD_SIGNAL_GLOBS_PER_RECORD = 20
HARD_SIGNAL_GLOB_BYTES = 256
HARD_LOG_BYTES = 64 * 1024
HARD_TOTAL_SIGNAL_BYTES = 256 * 1024
HARD_JSON_BYTES = 2 * 1024 * 1024
HARD_JSONL_LINE_BYTES = 64 * 1024
HARD_AUDIT_BYTES = 32 * 1024 * 1024
HARD_PROMOTED_FILES = 1_000
_FIX_RE = re.compile(r"\b(fix(?:es|ed)?|bug(?:fix)?|patch(?:es|ed)?|hotfix)\b", re.I)
_REVERT_RE = re.compile(r"^\s*revert\b|\brevert(?:ed|ing)?\b", re.I)
_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_.:/-]{1,80}$")
_ACTIVE_STATUSES = {"active", "open", "investigating", "in_progress", "blocked"}
_INACTIVE_STATUSES = {"closed", "resolved", "dismissed", "inactive"}
_SIGNAL_KINDS = {
    "runtime_incident",
    "incident",
    "release_blocker",
    "regression",
    "project_priority",
}
_SEVERITIES = {"critical", "high", "medium", "low"}
_PRIORITY_REASON_CODES = {
    "active_incident",
    "baseline_failure",
    "changed_since_last_run",
    "cold_sink",
    "content_changed_since_audit",
    "critical_path",
    "fix_history",
    "git_history",
    "live_sink",
    "local_bug_issue",
    "maybe_sink",
    "prior_bug_history",
    "project_priority",
    "release_blocker",
    "reopened_conclusion",
    "revert_history",
    "runtime_without_test_change",
    "stale_audit",
    "user_impact",
    "variant_match",
}
_PATH_TOKEN_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])(?:\./)?[A-Za-z0-9_@+.-]+" r"(?:/[A-Za-z0-9_@+.-]+)*\.[A-Za-z0-9_+.-]+"
)


def _open_bounded(path: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError(f"not a regular file: {path}")
    return fd


def _read_bounded(path: Path, max_bytes: int) -> bytes:
    fd = _open_bounded(path)
    try:
        chunks: list[bytes] = []
        remaining = max_bytes + 1
        while remaining > 0:
            chunk = os.read(fd, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > max_bytes:
            raise OSError(f"file exceeds {max_bytes} byte cap: {path}")
        return data
    finally:
        os.close(fd)


def _load_json(path: Path, *, max_bytes: int = HARD_JSON_BYTES) -> dict[str, Any]:
    try:
        data = json.loads(_read_bounded(path, max_bytes).decode("utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _config_int(
    values: Mapping[str, Any], key: str, default: int, minimum: int, maximum: int
) -> int:
    try:
        parsed = int(values.get(key, default))
    except (TypeError, ValueError):
        parsed = default
    return max(minimum, min(maximum, parsed))


def _load_jsonl(path: Path, *, max_records: int, max_bytes: int) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    consumed = 0
    try:
        fd = _open_bounded(path)
        with os.fdopen(fd, "rb", closefd=True) as handle:
            while consumed < max_bytes and len(records) < max_records:
                remaining = max_bytes - consumed
                raw = handle.readline(min(HARD_JSONL_LINE_BYTES + 1, remaining + 1))
                if not raw:
                    break
                consumed += len(raw)
                if len(raw) > HARD_JSONL_LINE_BYTES or not raw.endswith(b"\n"):
                    # Drain an overlong physical line in bounded chunks. It is
                    # malformed data and never reaches json.loads.
                    while raw and not raw.endswith(b"\n") and consumed < max_bytes:
                        raw = handle.readline(
                            min(HARD_JSONL_LINE_BYTES + 1, max_bytes - consumed + 1)
                        )
                        consumed += len(raw)
                    continue
                try:
                    value = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if isinstance(value, dict):
                    records.append(value)
    except OSError:
        pass
    return records


def _load_jsonl_tail(path: Path, *, max_records: int, max_bytes: int) -> list[dict[str, Any]]:
    """Read the newest bounded suffix of an append-only JSONL file."""

    try:
        fd = _open_bounded(path)
        with os.fdopen(fd, "rb", closefd=True) as handle:
            size = os.fstat(handle.fileno()).st_size
            offset = max(0, size - max_bytes)
            handle.seek(offset)
            data = handle.read(max_bytes)
    except OSError:
        return []
    if offset:
        newline = data.find(b"\n")
        data = b"" if newline < 0 else data[newline + 1 :]
    if data and not data.endswith(b"\n"):
        newline = data.rfind(b"\n")
        data = b"" if newline < 0 else data[: newline + 1]
    records: list[dict[str, Any]] = []
    for raw in data.splitlines()[-max_records:]:
        if not raw or len(raw) > HARD_JSONL_LINE_BYTES:
            continue
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


def _git_env() -> dict[str, str]:
    env = os.environ.copy()
    env["GIT_NO_LAZY_FETCH"] = "1"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    return env


def _git_result(
    repo: Path, args: Sequence[str], *, max_bytes: int = 2 * 1024 * 1024
) -> tuple[str, bool]:
    """Run a local Git read with an allocation-time stdout cap."""

    try:
        process = subprocess.Popen(
            ["git", "-C", str(repo), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_git_env(),
        )
    except OSError:
        return "", False
    chunks = bytearray()
    overflow = False

    def _drain() -> None:
        nonlocal overflow
        assert process.stdout is not None
        while True:
            chunk = process.stdout.read(64 * 1024)
            if not chunk:
                return
            if len(chunks) + len(chunk) <= max_bytes:
                chunks.extend(chunk)
            else:
                overflow = True

    reader = threading.Thread(target=_drain, daemon=True)
    reader.start()
    timed_out = False
    try:
        return_code = process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
        return_code = process.wait(timeout=5)
    reader.join(timeout=5)
    if return_code != 0 or timed_out or overflow or reader.is_alive():
        return "", False
    return bytes(chunks).decode("utf-8", errors="replace"), True


def _git(repo: Path, args: Sequence[str], *, max_bytes: int = 2 * 1024 * 1024) -> str:
    return _git_result(repo, args, max_bytes=max_bytes)[0]


def _valid_commit(repo: Path, value: str | None) -> bool:
    if not value:
        return False
    try:
        completed = subprocess.run(
            ["git", "-C", str(repo), "cat-file", "-e", f"{value}^{{commit}}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=_git_env(),
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return completed.returncode == 0


def _tracked_files(repo: Path, exclude_globs: Iterable[str]) -> list[str]:
    raw = _git(repo, ["ls-files", "-z"], max_bytes=16 * 1024 * 1024)
    excluded = tuple(g for g in exclude_globs if isinstance(g, str) and g)
    files = {
        value
        for value in raw.split("\x00")
        if value and not any(fnmatch.fnmatch(value, glob) for glob in excluded)
    }
    return sorted(files)


def _recent_commits(repo: Path, head: str, count: int, tracked: set[str]) -> list[dict[str, Any]]:
    raw = _git(
        repo,
        [
            "log",
            "-n",
            str(count),
            "--no-color",
            "--pretty=format:%x1e%H%x1f%s",
            "--name-only",
            head,
            "--",
        ],
        max_bytes=4 * 1024 * 1024,
    )
    records: list[dict[str, Any]] = []
    for block in raw.split("\x1e"):
        block = block.strip("\n")
        if not block or "\x1f" not in block:
            continue
        header, *path_lines = block.splitlines()
        sha, subject = header.split("\x1f", 1)
        if _REVERT_RE.search(subject):
            kind = "revert"
        elif "hotfix" in subject.lower():
            kind = "hotfix"
        elif _FIX_RE.search(subject):
            kind = "fix"
        else:
            kind = "change"
        files = sorted(
            {
                normalized
                for raw_path in path_lines
                if (normalized := normalize_repo_path(raw_path.strip(), tracked)) is not None
            }
        )
        records.append(
            {
                "sha": sha[:40],
                "subject": sanitize_text(subject, 200),
                "kind": kind,
                "files": files,
            }
        )
    return records


def _change_window(
    repo: Path,
    previous_head: str | None,
    current_head: str,
    recent_commits: Sequence[Mapping[str, Any]],
    tracked: set[str],
) -> tuple[dict[str, str], str]:
    changes: dict[str, str] = {}
    if _valid_commit(repo, previous_head) and _valid_commit(repo, current_head):
        raw, diff_ok = _git_result(
            repo,
            ["diff", "--name-status", "-M", str(previous_head), current_head, "--"],
            max_bytes=4 * 1024 * 1024,
        )
        if diff_ok:
            for line in raw.splitlines():
                fields = line.split("\t")
                if len(fields) < 2:
                    continue
                status = fields[0]
                candidate = fields[-1] if status.startswith(("R", "C")) else fields[1]
                path = normalize_repo_path(candidate, tracked)
                if path is None:
                    continue
                kind = {
                    "A": "added",
                    "M": "modified",
                    "R": "renamed",
                    "C": "copied",
                    "T": "type_changed",
                }.get(status[:1], "changed")
                changes[path] = kind
            return dict(sorted(changes.items())), "since_last_run"

    for commit in recent_commits:
        for raw_path in commit.get("files", []) or []:
            path = normalize_repo_path(raw_path, tracked)
            if path is not None and path not in changes:
                changes[path] = "recent"
    return dict(sorted(changes.items())), "bounded_recent_fallback"


def _git_blob_oids(repo: Path, head: str, paths: Iterable[str]) -> dict[str, str]:
    """Resolve exact Git blob OIDs in bounded argv/output chunks."""

    ordered = sorted(set(paths))
    result: dict[str, str] = {}
    chunk: list[str] = []
    chars = 0

    def flush(values: list[str]) -> None:
        if not values:
            return
        raw = _git(repo, ["ls-tree", "-z", head, "--", *values], max_bytes=2 * 1024 * 1024)
        for record in raw.split("\x00"):
            if not record or "\t" not in record:
                continue
            metadata, path = record.split("\t", 1)
            parts = metadata.split()
            if len(parts) == 3 and parts[1] in {"blob", "commit"}:
                result[path] = parts[2]

    for path in ordered:
        if chunk and (len(chunk) >= 200 or chars + len(path) > 32_000):
            flush(chunk)
            chunk = []
            chars = 0
        chunk.append(path)
        chars += len(path)
    flush(chunk)
    return result


def _content_changed_since_hunt(
    repo: Path, audit_log: Path, tracked: set[str], current_head: str
) -> tuple[set[str], str]:
    latest: dict[str, tuple[int, str]] = {}
    for record in _load_jsonl_tail(audit_log, max_records=200_000, max_bytes=HARD_AUDIT_BYTES):
        if record.get("outcome") != "audited" or not record.get("blob_oid"):
            continue
        path = normalize_repo_path(record.get("file"), tracked)
        if path is None:
            continue
        try:
            run = int(record.get("run", 0))
        except (TypeError, ValueError):
            continue
        prior_fingerprint = latest.get(path)
        if prior_fingerprint is None or run > prior_fingerprint[0]:
            latest[path] = (run, str(record["blob_oid"]))

    changed: set[str] = set()
    current_oids = _git_blob_oids(repo, current_head, latest)
    for path, (_, old_oid) in latest.items():
        current_oid = current_oids.get(path)
        if current_oid and current_oid != old_oid:
            changed.add(path)
    return changed, "ok" if latest else "no_fingerprints"


def _extract_tracked_paths(log_path: Path, tracked: set[str]) -> list[str]:
    try:
        text = _read_bounded(log_path, HARD_LOG_BYTES).decode("utf-8", errors="replace")
    except OSError:
        return []
    found: set[str] = set()
    for token in _PATH_TOKEN_RE.findall(text):
        path = normalize_repo_path(token, tracked)
        if path is not None:
            found.add(path)
    return sorted(found)


def _baseline_context(
    run_dir: Path, tracked: set[str]
) -> tuple[dict[str, Any], dict[str, list[str]], str]:
    baseline = _load_json(run_dir / "baseline.json")
    if not baseline:
        return {}, {}, "missing"
    hits: dict[str, list[str]] = {}
    for check in baseline.get("checks", []) or []:
        if not isinstance(check, Mapping) or check.get("status") != "fail":
            continue
        name = sanitize_text(check.get("check"), 40)
        if name:
            hits[name] = _extract_tracked_paths(run_dir / f"baseline-{name}.log", tracked)
    return baseline, hits, "ok"


def _file_scope_tokens(record: Mapping[str, Any]) -> list[object]:
    values: list[object] = []
    for key in ("files", "file_scope"):
        raw = record.get(key)
        if isinstance(raw, list):
            values.extend(raw)
        elif isinstance(raw, str):
            values.extend(re.split(r"[,\s]+", raw))
    for key in ("description", "notes"):
        raw = record.get(key)
        if not isinstance(raw, str):
            continue
        for match in re.finditer(r"file_scope\s*:\s*([^\n]+)", raw, re.I):
            values.extend(re.split(r"[,\s]+", match.group(1)))
    return [str(value).strip(" \t,;()[]{}\"'") for value in values if str(value).strip()]


def _safe_identifier(value: object) -> str:
    candidate = str(value or "")
    return candidate if _SAFE_ID_RE.fullmatch(candidate) else ""


def _local_issues(
    repo: Path, common_root: Path, tracked: set[str]
) -> tuple[list[dict[str, Any]], str]:
    candidates = [_safe_relative_signal_path(common_root, ".beads/issues.jsonl")]
    if repo != common_root:
        candidates.append(_safe_relative_signal_path(repo, ".beads/issues.jsonl"))
    path = next(
        (candidate for candidate in candidates if candidate is not None and candidate.is_file()),
        None,
    )
    if path is None:
        return [], "missing"
    issues: list[dict[str, Any]] = []
    for record in _load_jsonl(path, max_records=10_000, max_bytes=4 * 1024 * 1024):
        status = str(record.get("status") or "open").lower()
        issue_type = str(record.get("issue_type") or "").lower()
        raw_labels = record.get("labels")
        labels = (
            {str(label).lower() for label in raw_labels}
            if isinstance(raw_labels, list)
            else ({raw_labels.lower()} if isinstance(raw_labels, str) else set())
        )
        if status not in {"open", "in_progress", "blocked"}:
            continue
        if issue_type != "bug" and not ({"bug", "regression"} & labels):
            continue
        files = sorted(
            {
                normalized
                for raw_path in _file_scope_tokens(record)
                if (normalized := normalize_repo_path(raw_path, tracked)) is not None
            }
        )
        if not files:
            continue
        issue_id = _safe_identifier(record.get("id"))
        if not issue_id:
            continue
        issues.append(
            {
                "id": issue_id,
                "priority": record.get("priority", 3),
                "files": files,
            }
        )
    issues.sort(
        key=lambda item: (
            _config_int(item, "priority", 3, 0, 4),
            str(item["id"]),
        )
    )
    return issues[:HARD_LOCAL_ISSUES], "ok"


def _safe_relative_signal_path(root: Path, value: object) -> Path | None:
    if not isinstance(value, str) or not value or value.startswith(("/", "~", "\\")):
        return None
    parts = Path(value).parts
    if ".." in parts:
        return None
    candidate = root / value
    try:
        root_resolved = root.resolve(strict=True)
        resolved = candidate.resolve(strict=False)
        if os.path.commonpath([str(root_resolved), str(resolved)]) != str(root_resolved):
            return None
        if candidate.is_symlink():
            return None
    except (OSError, ValueError):
        return None
    return resolved


def _parse_epoch(value: object) -> int | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        parsed = int(value)
        return parsed if parsed > 0 else None
    if not isinstance(value, str) or not value:
        return None
    if value.isdigit():
        parsed = int(value)
        return parsed if parsed > 0 else None
    try:
        parsed_dt = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed_dt.tzinfo is None:
        parsed_dt = parsed_dt.replace(tzinfo=dt.timezone.utc)
    return int(parsed_dt.timestamp())


def _nonnegative_int(value: object, default: int = 0) -> int:
    try:
        parsed = int(str(value))
    except (TypeError, ValueError):
        return default
    return max(0, parsed)


def _project_signals(
    repo: Path,
    common_root: Path,
    tracked: set[str],
    configured_files: Sequence[object],
    max_glob_matches: int,
    reference_epoch: int,
    max_age_seconds: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, int], str]:
    paths: list[Path] = []
    for value in list(configured_files)[:HARD_SIGNAL_FILES]:
        base = common_root if str(value).startswith(".bugsweep/") else repo
        path = _safe_relative_signal_path(base, value)
        if path is not None:
            paths.append(path)

    records: list[dict[str, Any]] = []
    unmapped: list[dict[str, Any]] = []
    health = {
        "accepted": 0,
        "expired": 0,
        "inactive": 0,
        "malformed": 0,
        "unmapped": 0,
        "overmatched": 0,
    }
    any_file = False
    consumed = 0
    for path in paths:
        if not path.is_file():
            continue
        any_file = True
        remaining = max(0, HARD_TOTAL_SIGNAL_BYTES - consumed)
        if remaining <= 0:
            break
        try:
            consumed += min(path.stat().st_size, remaining)
        except OSError:
            pass
        for record in _load_jsonl(path, max_records=HARD_PROJECT_SIGNALS, max_bytes=remaining):
            if len(records) + len(unmapped) >= HARD_PROJECT_SIGNALS:
                break
            status = str(record.get("status") or "").lower()
            kind = str(record.get("kind") or "").lower()
            severity = str(record.get("severity") or "").lower()
            signal_id = _safe_identifier(record.get("id"))
            source = _safe_identifier(record.get("source"))
            confidence = _nonnegative_int(record.get("confidence"), 50)
            observed_at = _parse_epoch(record.get("observed_at"))
            expires_at = _parse_epoch(record.get("expires_at"))
            raw_files = record.get("files", [])
            raw_globs = record.get("globs", [])
            if status in _INACTIVE_STATUSES:
                health["inactive"] += 1
                continue
            if (
                status not in _ACTIVE_STATUSES
                or kind not in _SIGNAL_KINDS
                or severity not in _SEVERITIES
                or not signal_id
                or not source
                or confidence > 100
                or not isinstance(raw_files, list)
                or not isinstance(raw_globs, list)
                or len(raw_files) > HARD_SIGNAL_PATHS_PER_RECORD
                or len(raw_globs) > HARD_SIGNAL_GLOBS_PER_RECORD
                or any(not isinstance(value, str) for value in raw_files + raw_globs)
                or any(
                    len(value.encode("utf-8", errors="ignore")) > HARD_SIGNAL_GLOB_BYTES
                    for value in raw_globs
                )
                or (reference_epoch > 0 and observed_at is None)
                or (
                    observed_at is not None
                    and reference_epoch > 0
                    and observed_at > reference_epoch + 300
                )
            ):
                health["malformed"] += 1
                continue
            if reference_epoch > 0 and (
                (expires_at is not None and expires_at < reference_epoch)
                or (
                    expires_at is None
                    and observed_at is not None
                    and observed_at + max_age_seconds < reference_epoch
                )
            ):
                health["expired"] += 1
                continue
            files = {
                normalized
                for raw_path in raw_files
                if (normalized := normalize_repo_path(raw_path, tracked)) is not None
            }
            for raw_glob in raw_globs:
                matches: list[str] = []
                for tracked_path in tracked:
                    if not fnmatch.fnmatchcase(tracked_path, raw_glob):
                        continue
                    matches.append(tracked_path)
                    if len(matches) > max_glob_matches:
                        break
                if len(matches) > max_glob_matches:
                    health["overmatched"] += 1
                else:
                    files.update(matches)
            normalized_record = {
                "id": signal_id,
                "source": source,
                "kind": kind,
                "severity": severity,
                "confidence": confidence,
                "observed_at": observed_at,
                "expires_at": expires_at,
                "environment": _safe_identifier(record.get("environment")),
                "release": _safe_identifier(record.get("release")),
                "component": _safe_identifier(record.get("component")),
                "flow": _safe_identifier(record.get("flow")),
                "affected_users": min(
                    1_000_000_000, _nonnegative_int(record.get("affected_users"))
                ),
                "occurrence_count": min(
                    1_000_000_000, _nonnegative_int(record.get("occurrence_count"))
                ),
                "files": sorted(files),
            }
            health["accepted"] += 1
            if files:
                records.append(normalized_record)
            else:
                health["unmapped"] += 1
                unmapped.append(
                    {key: value for key, value in normalized_record.items() if key != "files"}
                )
    records.sort(key=lambda item: (str(item["kind"]), str(item["id"])))
    unmapped.sort(key=lambda item: (str(item["kind"]), str(item["id"])))
    return records, unmapped, health, "ok" if any_file else "missing"


def _signal_yield(path: Path) -> tuple[list[dict[str, Any]], str]:
    """Aggregate bounded signal-to-outcome episodes without changing weights."""

    aggregates: dict[str, dict[str, int]] = {}
    seen: set[tuple[str, str, str]] = set()
    records = _load_jsonl_tail(path, max_records=200_000, max_bytes=HARD_AUDIT_BYTES)
    # Append-only state may contain more than one observation for an episode
    # when finalize is retried after a resumed run. Walk newest-to-oldest so the
    # final persisted outcome wins; older duplicates are ignored below.
    for record in reversed(records):
        reason = _safe_identifier(record.get("reason"))
        run_id = _safe_identifier(record.get("run_id"))
        file_path = str(record.get("file") or "")
        outcome = str(record.get("outcome") or "")
        if (
            reason not in _PRIORITY_REASON_CODES
            or not run_id
            or not file_path
            or outcome
            not in {
                "confirmed",
                "rejected",
                "no_finding",
                "not_reviewed",
                "unattributed",
            }
        ):
            continue
        episode_key = (run_id, file_path, reason)
        if episode_key in seen:
            continue
        seen.add(episode_key)
        counts = aggregates.setdefault(
            reason,
            {
                "observed": 0,
                "investigated": 0,
                "attributed": 0,
                "confirmed": 0,
                "rejected": 0,
                "no_finding": 0,
                "unattributed": 0,
            },
        )
        counts["observed"] += 1
        if record.get("investigated") is True:
            counts["investigated"] += 1
            if outcome in {"confirmed", "rejected", "no_finding"}:
                counts["attributed"] += 1
                counts[outcome] += 1
            elif outcome == "unattributed":
                counts["unattributed"] += 1

    rendered: list[dict[str, Any]] = []
    for reason in sorted(aggregates):
        counts = aggregates[reason]
        attributed = counts["attributed"]
        rendered.append(
            {
                "reason": reason,
                **counts,
                "confirmation_rate": round(counts["confirmed"] / attributed, 4)
                if attributed
                else 0.0,
            }
        )
    return rendered[:50], "ok" if records else "empty"


def _history_records(path: Path, tracked: set[str]) -> tuple[list[dict[str, Any]], str]:
    records = []
    for record in _load_jsonl(path, max_records=200_000, max_bytes=16 * 1024 * 1024):
        normalized = normalize_repo_path(record.get("file"), tracked)
        if normalized is None:
            continue
        clean = dict(record)
        clean["file"] = normalized
        records.append(clean)
    return records, "ok" if records else "empty"


def _exposure(path: Path, tracked: set[str]) -> tuple[dict[str, dict[str, Any]], str]:
    raw = _load_json(path)
    if not raw:
        return {}, "missing"
    result: dict[str, dict[str, Any]] = {}
    for item in raw.get("files", []) or []:
        if not isinstance(item, Mapping):
            continue
        normalized = normalize_repo_path(item.get("file"), tracked)
        if normalized is not None:
            result[normalized] = dict(item)
    return result, "degraded" if raw.get("degraded") else "ok"


def _line_paths(path: Path, tracked: set[str]) -> set[str]:
    try:
        lines = _read_bounded(path, 512 * 1024).decode("utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return set()
    return {
        normalized
        for raw in lines[:10_000]
        if (normalized := normalize_repo_path(raw.strip(), tracked)) is not None
    }


def _atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    _atomic_bytes(path, encoded)


def _atomic_bytes(path: Path, encoded: bytes) -> None:
    temp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{path.name}.tmp-",
            dir=path.parent,
            delete=False,
        ) as handle:
            temp_name = handle.name
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass


def build(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    common_root = Path(args.common_root).resolve()
    run_dir = Path(args.run_dir).resolve()
    config = _load_json(Path(args.config))
    raw_priority = config.get("priority")
    priority: dict[str, Any] = dict(raw_priority) if isinstance(raw_priority, dict) else {}
    raw_excludes = config.get("exclude_globs")
    excludes: list[str] = (
        [value for value in raw_excludes if isinstance(value, str)]
        if isinstance(raw_excludes, list)
        else []
    )

    tracked_list = _tracked_files(repo, excludes)
    tracked = set(tracked_list)
    if not tracked:
        raise RuntimeError("no tracked files available for priority collection")

    recent_count = _config_int(priority, "recent_commit_count", 50, 1, HARD_RECENT_COMMITS)
    max_targets = _config_int(priority, "max_targets", 50, 1, 200)
    max_reasons = _config_int(priority, "max_reasons_per_file", 5, 1, 8)
    promotion_limit = _config_int(priority, "promotion_limit", 8, 0, 20)
    promotion_file_budget = _config_int(priority, "max_promoted_files", 200, 0, HARD_PROMOTED_FILES)
    max_glob_matches = _config_int(priority, "max_glob_matches", 25, 1, 100)
    max_signal_age_hours = _config_int(priority, "max_signal_age_hours", 168, 1, 8_760)
    reference_epoch = _nonnegative_int(args.reference_epoch)

    current_head = (
        args.current_head
        if _valid_commit(repo, args.current_head)
        else _git(repo, ["rev-parse", "HEAD"]).strip()
    )
    if not _valid_commit(repo, current_head):
        raise RuntimeError("no readable HEAD commit")
    meta = _load_json(common_root / ".bugsweep" / "state" / "meta.json")
    previous_head: str | None = None
    branch = str(args.branch or "")
    per_branch = meta.get("last_run_heads")
    if branch and isinstance(per_branch, Mapping):
        branch_record = per_branch.get(branch)
        if isinstance(branch_record, Mapping):
            previous_head = str(branch_record.get("head") or "") or None
    elif not isinstance(per_branch, Mapping):
        # Compatibility only for state written before per-branch baselines.
        previous_head = str(meta.get("last_run_head") or "") or None

    recent = _recent_commits(repo, current_head, recent_count, tracked)
    changes, change_status = _change_window(repo, previous_head, current_head, recent, tracked)
    content_changed, fingerprint_status = _content_changed_since_hunt(
        repo, common_root / ".bugsweep" / "state" / "audit-log.jsonl", tracked, current_head
    )
    baseline, baseline_hits, baseline_status = _baseline_context(run_dir, tracked)
    history, history_status = _history_records(Path(args.history), tracked)
    exposure, exposure_status = _exposure(run_dir / "exposure.json", tracked)
    issues, issue_status = _local_issues(repo, common_root, tracked)
    raw_signal_files = priority.get("signal_files")
    signal_files: list[object] = (
        list(raw_signal_files)
        if isinstance(raw_signal_files, list)
        else [".bugsweep/priority-signals.jsonl"]
    )
    project, unmapped, signal_health, project_status = _project_signals(
        repo,
        common_root,
        tracked,
        signal_files,
        max_glob_matches,
        reference_epoch,
        max_signal_age_hours * 3600,
    )
    signal_yield, signal_yield_status = _signal_yield(
        common_root / ".bugsweep" / "state" / "priority-outcomes.jsonl"
    )

    raw_critical_globs = priority.get("critical_globs")
    critical_globs: list[object] = (
        list(raw_critical_globs) if isinstance(raw_critical_globs, list) else []
    )
    context = build_priority_context(
        tracked_files=tracked_list,
        current_head=current_head,
        previous_head=previous_head,
        change_window=changes,
        content_changed=content_changed,
        history_records=history,
        recent_commits=recent,
        baseline=baseline,
        baseline_file_hits=baseline_hits,
        exposure=exposure,
        prior_coverage=_load_json(run_dir / "prior-coverage.json"),
        reopened=_line_paths(run_dir / "reopened-conclusions.txt", tracked),
        variant_matches=_line_paths(run_dir / "variant-requeue.txt", tracked),
        issue_signals=issues,
        project_signals=project,
        critical_globs=[str(value) for value in critical_globs if isinstance(value, str)],
        max_targets=max_targets,
        promotion_limit=promotion_limit,
        max_reasons=max_reasons,
        max_glob_matches=max_glob_matches,
        promotion_file_budget=promotion_file_budget,
        signal_health=signal_health,
        unmapped_focus_signals=unmapped,
        signal_yield=signal_yield,
        source_status={
            "audit_fingerprints": fingerprint_status,
            "baseline": baseline_status,
            "change_window": change_status,
            "exposure": exposure_status,
            "git": "ok",
            "git_history": history_status,
            "local_issues": issue_status,
            "project_signals": project_status,
            "signal_outcomes": signal_yield_status,
        },
    )
    context["degraded"] = False
    _atomic_json(Path(args.output), context)
    return 0


def _recon_files(value: Mapping[str, Any]) -> Counter[str]:
    return Counter(
        path
        for batch in value.get("batches", []) or []
        if isinstance(batch, Mapping)
        for path in (batch.get("files", []) or [])
        if isinstance(path, str)
    )


def apply(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).resolve()
    recon_path = run_dir / "recon.json"
    context_path = run_dir / "priority-context.json"
    try:
        original_recon = _read_bounded(recon_path, HARD_JSON_BYTES)
        loaded_recon = json.loads(original_recon.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("recon.json missing/unreadable") from exc
    recon = loaded_recon if isinstance(loaded_recon, dict) else {}
    context = _load_json(context_path)
    if not recon or not context:
        raise RuntimeError("recon.json or priority-context.json missing/unreadable")
    before_files = _recon_files(recon)
    before_batch_ids = Counter(
        str(batch.get("id"))
        for batch in recon.get("batches", []) or []
        if isinstance(batch, Mapping)
    )
    result = reprioritize_recon(recon, context)
    after_files = _recon_files(result)
    after_batch_ids = Counter(
        str(batch.get("id"))
        for batch in result.get("batches", []) or []
        if isinstance(batch, Mapping)
    )
    if before_files != after_files or before_batch_ids != after_batch_ids:
        raise RuntimeError("priority application attempted to change recon scope")

    before_by_id = {
        str(batch["id"]): batch
        for batch in recon.get("batches", [])
        if isinstance(batch, Mapping) and "id" in batch
    }
    after_by_id = {
        str(batch["id"]): batch
        for batch in result.get("batches", [])
        if isinstance(batch, Mapping) and "id" in batch
    }
    promoted_batches = [
        batch_id
        for batch_id in after_by_id
        if before_by_id[batch_id].get("deferred") is True
        and after_by_id[batch_id].get("deferred") is False
    ]
    promoted_set = set(promoted_batches)
    file_to_batch = {
        path: batch_id
        for batch_id, batch in before_by_id.items()
        for path in (batch.get("files", []) or [])
        if isinstance(path, str)
    }
    already_in_budget: list[str] = []
    skipped: list[dict[str, str]] = []
    for path in context.get("promotion_candidates", []) or []:
        if not isinstance(path, str):
            continue
        batch_id = file_to_batch.get(path)
        if batch_id is None:
            skipped.append({"file": path, "reason": "outside_recon"})
        elif before_by_id[batch_id].get("deferred") is False:
            already_in_budget.append(path)
        elif batch_id not in promoted_set:
            skipped.append({"file": path, "reason": "budget_limited"})

    application = {
        "schema_version": 1,
        "scope_contract": "priority_only_whole_repo_remains_in_scope",
        "candidate_count": len(context.get("promotion_candidates", []) or []),
        "promoted_batches": promoted_batches,
        "promoted_batch_count": len(promoted_batches),
        "added_file_count": sum(
            len(after_by_id[batch_id].get("files", []) or []) for batch_id in promoted_batches
        ),
        "already_in_budget_candidates": sorted(set(already_in_budget)),
        "skipped_candidates": sorted(skipped, key=lambda item: (item["reason"], item["file"])),
    }
    _atomic_json(recon_path, result)
    try:
        _atomic_json(run_dir / "priority-application.json", application)
    except Exception as receipt_error:
        try:
            _atomic_bytes(recon_path, original_recon)
        except OSError as rollback_error:
            raise RuntimeError(
                "priority application receipt failed and exact recon rollback failed"
            ) from rollback_error
        raise RuntimeError(
            "priority application receipt failed; exact original recon restored"
        ) from receipt_error
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    build_parser = sub.add_parser("build")
    build_parser.add_argument("--repo", required=True)
    build_parser.add_argument("--common-root", required=True)
    build_parser.add_argument("--run-dir", required=True)
    build_parser.add_argument("--config", required=True)
    build_parser.add_argument("--history", required=True)
    build_parser.add_argument("--output", required=True)
    build_parser.add_argument("--current-head", default="")
    build_parser.add_argument("--branch", default="")
    build_parser.add_argument("--reference-epoch", default="0")
    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("--run-dir", required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        return build(args) if args.command == "build" else apply(args)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as exc:
        print(f"priority-context: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
