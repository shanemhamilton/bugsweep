"""Deterministic batch-planner for bugsweep's frozen-scope context-build step.

Why this exists (bugsweep-e1r): ``prompts/context-build.md`` used to build
``repo-context.md`` + ``recon.json`` in a single, un-checkpointed pass. On a
1474-file repo that pass stalled before ``recon.json`` was ever written —
leaving nothing to resume, reprioritize, or report (root cause behind bead
2e5, "large repos fail silently"). ``large_repo_mode`` in ``SKILL.md`` Step 2
was computed only AFTER ``recon.json`` was written, so it could never help a
build that never finished.

This module computes the batch plan BEFORE any modeling happens, from a bare
file list (produced by the caller via ``git ls-files``, per the existing
``exclude_globs`` convention in ``scripts/common.sh``). ``scripts/recon-plan.sh``
calls this (Tier 1: python3 available) to write ``recon-plan.json``, which
``prompts/context-build.md`` then uses to initialize ``recon.json`` from
minute one — so even a run that dies immediately after initialization leaves
a resumable, reportable artifact on disk.

Design
------
* **Chunking** — files are ordered by *top-level subtree*: the first path
  segment that names a directory. Files directly under the repo root (no
  directory segment) form their own ``"."`` group. Each group is then split
  into deterministic file-count and byte-count bounded batches. This avoids a
  large ``src`` directory becoming one unbounded model request while retaining
  natural package/module ordering.
* **Tier heuristic** — deliberately simple and documented here (not clever):
  a directory is ``critical`` if its name matches one of
  :data:`SINK_DIR_HINTS` (auth, api, handlers, ... — cheap textual proxies
  for "this subtree is likely to contain a sensitive sink or entry point"),
  ``low`` if it matches one of :data:`LOW_PRIORITY_DIR_HINTS` (docs, assets,
  static, ... — content unlikely to contain exploitable logic), else
  ``normal``. Determinism matters more than cleverness here: these are
  ORDERING hints, not a filter — every file still ends up in some batch.
* **Ordering** — batches sort ``critical`` -> ``normal`` -> ``low``, tie-broken
  by directory name ascending, so the same file list always produces a
  byte-identical plan (verified via ``json.dumps(..., sort_keys=True)``
  round-trip in tests) regardless of input order or dict/set iteration order
  upstream.
* **Sizing** — callers provide sizes from the audited tree. A missing size is
  explicit and is isolated in a one-file batch because its byte budget cannot
  be proved. A known file larger than the byte cap is also isolated and marked
  ``oversized``; it remains in scope instead of being silently dropped.
* **large_repo_mode** — a pure predicate over a file count vs.
  :data:`DEFAULT_FILE_THRESHOLD` (``cfg_get '.context.large_repo_file_threshold'``,
  default 800). When active, only the first
  :data:`DEFAULT_FIRST_PASS_BATCHES` (``cfg_get
  '.context.large_repo_first_pass_batches'``, default 40) ordered batches are
  eligible this pass (``deferred: false``); the rest are marked
  ``deferred: true`` so the coverage-first frontier (``prior-coverage.json`` /
  ``scripts/state.sh``) picks them up on a later run. Deferred batches are
  NEVER dropped from the plan — every in-scope file still appears in exactly
  one batch, satisfying context-build.md's coverage-first contract ("the
  frozen selected scope is always in scope").

No network, no subprocess: everything here is a pure function over an
in-memory file list, mirroring ``bench/scorer/run_summary.py``'s style so
this module is unit-testable and coverage-gated the same way.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Iterable

SCHEMA_VERSION = 1

#: Default file-count threshold above which large_repo_mode activates.
#: Mirrors ``cfg_get '.context.large_repo_file_threshold' '800'`` in
#: ``scripts/recon-plan.sh``.
DEFAULT_FILE_THRESHOLD = 800

#: Default cap on how many ordered batches are eligible in the first pass
#: once large_repo_mode is active. Mirrors ``cfg_get
#: '.context.large_repo_first_pass_batches' '40'``.
DEFAULT_FIRST_PASS_BATCHES = 40

# Conservative defaults for bounded model requests. The shell boundary may
# override these from project config.
DEFAULT_MAX_BATCH_FILES = 25
DEFAULT_MAX_BATCH_BYTES = 131_072

#: Directory-name hints for the "critical" tier: cheap textual proxies for
#: subtrees likely to hold sensitive sinks or entry points (auth/authz,
#: request routing/handling, payments, persistence, crypto). Intentionally a
#: flat, documented list rather than a "clever" classifier — determinism and
#: auditability matter more than recall here; the hunt's own sink detection
#: (reachability.sh) does the real work later. Matched against any path
#: segment, case-insensitively.
SINK_DIR_HINTS: frozenset[str] = frozenset(
    {
        "auth",
        "authz",
        "authn",
        "api",
        "handlers",
        "handler",
        "middleware",
        "controllers",
        "controller",
        "routes",
        "router",
        "security",
        "payment",
        "payments",
        "billing",
        "db",
        "database",
        "crypto",
        "webhooks",
        "webhook",
    }
)

#: Directory-name hints for the "low" tier: content unlikely to contain
#: exploitable application logic (documentation, static/binary assets).
#: Matched against any path segment, case-insensitively.
LOW_PRIORITY_DIR_HINTS: frozenset[str] = frozenset(
    {
        "docs",
        "doc",
        "documentation",
        "assets",
        "static",
        "public",
        "images",
        "img",
    }
)

_TIER_ORDER = {"critical": 0, "normal": 1, "low": 2}


def is_large_repo_mode(file_count: int, threshold: int = DEFAULT_FILE_THRESHOLD) -> bool:
    """True when ``file_count`` exceeds ``threshold`` (strictly greater than —
    a repo exactly at the threshold is not yet "large"). Pure function, no
    filesystem access, so it is trivially unit-testable against a fixture
    count without ever touching disk.
    """
    return file_count > threshold


def _top_level_dir(path: str) -> str:
    """Return the first directory segment of ``path``, or ``"."`` if the file
    is directly under the repo root (no directory segment)."""
    head, sep, _tail = path.partition("/")
    return head if sep else "."


def _classify_tier(directory: str) -> str:
    """Classify a batch directory into critical/normal/low using the
    documented, deliberately-simple hint lists above. The root batch
    (``"."``) is always ``normal`` — root-level files (README, setup.py,
    config) are neither a documented sink hint nor a low-priority hint."""
    if directory == ".":
        return "normal"
    segments = {seg.lower() for seg in directory.split("/") if seg}
    if segments & SINK_DIR_HINTS:
        return "critical"
    if segments & LOW_PRIORITY_DIR_HINTS:
        return "low"
    return "normal"


def _is_excluded(path: str, exclude_globs: Iterable[str]) -> bool:
    """Match ``path`` against a list of ``fnmatch``-style globs (the same
    dialect ``scripts/common.sh``'s ``bugsweep_exclude_globs`` /
    ``bugsweep_excluded`` use for the shell fallback paths), so the plan
    honors the exact same ``exclude_globs`` config the rest of bugsweep
    does."""
    import fnmatch

    return any(fnmatch.fnmatch(path, glob) for glob in exclude_globs)


def _positive_int(value: object, default: int) -> int:
    """Parse a positive cap without allowing malformed config to disable it."""

    try:
        parsed = int(str(value))
    except (TypeError, ValueError):
        return default
    return parsed if parsed > 0 else default


def _normalized_file_sizes(
    files: Iterable[str], file_sizes: Mapping[str, object] | None
) -> dict[str, int | None]:
    """Validate audited-tree sizes; absent/invalid values remain explicitly unknown."""

    source = file_sizes if isinstance(file_sizes, Mapping) else {}
    sizes: dict[str, int | None] = {}
    for path in files:
        value = source.get(path)
        if isinstance(value, bool):
            sizes[path] = None
            continue
        try:
            parsed = int(str(value))
        except (TypeError, ValueError):
            sizes[path] = None
            continue
        sizes[path] = parsed if parsed >= 0 else None
    return sizes


def _batch(
    *,
    batch_id: int,
    directory: str,
    tier: str,
    paths: list[str],
    sizes: Mapping[str, int | None],
    max_bytes: int,
) -> dict:
    missing = [path for path in paths if sizes.get(path) is None]
    oversized = [
        path for path in paths if sizes.get(path) is not None and sizes[path] > max_bytes
    ]
    known_bytes = sum(sizes[path] for path in paths if sizes.get(path) is not None)
    return {
        "id": batch_id,
        "dir": directory,
        "tier": tier,
        "files": list(paths),
        "file_count": len(paths),
        "byte_count": None if missing else known_bytes,
        "size_status": "missing" if missing else ("oversized" if oversized else "known"),
        "oversized": bool(oversized),
        "missing_size_files": missing,
        "deferred": False,
    }


def build_plan(
    *,
    files: Iterable[str],
    exclude_globs: Iterable[str] = (),
    file_threshold: int = DEFAULT_FILE_THRESHOLD,
    first_pass_batch_cap: int = DEFAULT_FIRST_PASS_BATCHES,
    file_sizes: Mapping[str, object] | None = None,
    max_batch_files: int = DEFAULT_MAX_BATCH_FILES,
    max_batch_bytes: int = DEFAULT_MAX_BATCH_BYTES,
) -> dict:
    """Build a deterministic ``recon-plan.json``-shaped dict from a bare file
    list.

    Pure function: no filesystem access beyond what the caller already
    resolved into ``files`` (e.g. ``git ls-files``). Same input (regardless
    of list/set type or ordering) always produces a byte-identical plan.

    Args:
        files: every in-scope file path, repo-root-relative. May be given as
            a list, set, or any iterable — output does not depend on input
            ordering or the iterable's type.
        exclude_globs: fnmatch-style globs to drop from scope (mirrors
            ``config/bugsweep.config.json``'s ``.exclude_globs``).
        file_threshold: file-count threshold for :func:`is_large_repo_mode`.
        first_pass_batch_cap: how many ordered batches are eligible
            (``deferred: false``) when large_repo_mode is active.
        file_sizes: optional repo-relative byte sizes from the audited tree.
            Missing or invalid entries are isolated as explicit unknown-size
            batches, never guessed or silently discarded.
        max_batch_files: maximum number of files in an ordinary batch.
        max_batch_bytes: maximum known bytes in an ordinary batch.

    Returns:
        A dict matching ``schemas/recon-plan.schema.json``: ``batches`` is a
        list of bounded batch records, ordered
        critical -> normal -> low (tie-broken by directory name), with
        sequential 1-based ``id``s. ``covered`` always starts empty — the
        caller (context-build.md, via recon-plan.sh) seeds ``recon.json``
        from this plan before any modeling occurs.
    """
    exclude_globs = tuple(exclude_globs)
    in_scope = sorted(
        {
            f
            for f in files
            if isinstance(f, str) and f and not _is_excluded(f, exclude_globs)
        }
    )
    max_batch_files = _positive_int(max_batch_files, DEFAULT_MAX_BATCH_FILES)
    max_batch_bytes = _positive_int(max_batch_bytes, DEFAULT_MAX_BATCH_BYTES)
    sizes = _normalized_file_sizes(in_scope, file_sizes)

    by_dir: dict[str, list[str]] = {}
    for path in in_scope:
        directory = _top_level_dir(path)
        by_dir.setdefault(directory, []).append(path)

    ordered_dirs = sorted(
        by_dir.keys(), key=lambda d: (_TIER_ORDER[_classify_tier(d)], d)
    )

    large_repo_mode = is_large_repo_mode(len(in_scope), file_threshold)
    budget_batches = first_pass_batch_cap if large_repo_mode else None

    batches: list[dict] = []
    next_id = 1
    oversized_files: list[str] = []
    missing_size_files: list[str] = []
    for directory in ordered_dirs:
        tier = _classify_tier(directory)
        current: list[str] = []
        current_bytes = 0

        def flush() -> None:
            nonlocal next_id, current, current_bytes
            if not current:
                return
            record = _batch(
                batch_id=next_id,
                directory=directory,
                tier=tier,
                paths=current,
                sizes=sizes,
                max_bytes=max_batch_bytes,
            )
            record["deferred"] = large_repo_mode and next_id > first_pass_batch_cap
            batches.append(record)
            oversized_files.extend(
                path
                for path in current
                if sizes.get(path) is not None and sizes[path] > max_batch_bytes
            )
            missing_size_files.extend(path for path in current if sizes.get(path) is None)
            next_id += 1
            current = []
            current_bytes = 0

        for path in sorted(by_dir[directory]):
            size = sizes.get(path)
            # Unknown sizes cannot prove a byte bound, so keep them isolated.
            if size is None:
                flush()
                current = [path]
                flush()
                continue
            # A known oversize file remains visible as a one-file exception.
            if size > max_batch_bytes:
                flush()
                current = [path]
                flush()
                continue
            if current and (
                len(current) >= max_batch_files or current_bytes + size > max_batch_bytes
            ):
                flush()
            current.append(path)
            current_bytes += size
        flush()

    return {
        "schema_version": SCHEMA_VERSION,
        "files_in_scope": len(in_scope),
        "batch_count": len(batches),
        "large_repo_mode": large_repo_mode,
        "budget_batches": budget_batches,
        "max_batch_files": max_batch_files,
        "max_batch_bytes": max_batch_bytes,
        "missing_size_files": sorted(missing_size_files),
        "oversized_files": sorted(oversized_files),
        "batches": batches,
        "covered": [],
    }
