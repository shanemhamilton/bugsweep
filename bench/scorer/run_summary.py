"""Reduce a bugsweep run's ``ledger.jsonl`` + ``recon.json`` into ``run-summary.json``.

Why this exists: the "Findings (machine-readable)" JSON block in ``report.md``
is MODEL-emitted (per the SKILL.md report template) and has varied across runs
— a headless scheduler (nightshift) cannot reliably parse it, and a
partial/stalled run's stub report (``scripts/finalize.sh``'s
``_emit_stub_report``) has no structured block at all. This module is the
deterministic, script-side reduction that ``scripts/summarize.sh`` calls (via
a small inline Python entrypoint) so ``run-summary.json`` always exists after
finalize, on both the real-report and stub/partial paths.

Event -> summary field mapping (ground truth: scripts/state.sh, session.sh,
guard.sh, preflight.sh, SKILL.md, prompts/referee.md, prompts/fix.md)
------------------------------------------------------------------------
* ``preflight``                  -> run start marker; not otherwise reduced.
* ``iteration``                  -> Referee checkpoint (``confirmed``,
  ``new_bugs``); contributes to "was there progress" but not to findings.
* ``batch_covered``               -> counted only via recon.json's ``covered``
  list (the ledger event doesn't carry a stable id we can dedupe against
  reliably outside recon; recon.json is the source of truth for coverage).
* ``fix_committed``               -> one finding, ``fixed: true``. Any of
  ``bug_id``/``severity``/``category``/``file``/``line``/``rationale`` may be
  absent (the ``scripts/state.sh`` fallback persist path only guarantees
  ``file``) — absent fields are emitted as ``null``, never invented.
* ``quarantine``                  -> one finding, ``fixed: false`` (needs
  human). Same tolerant-field contract as ``fix_committed``.
* ``confirmed``                   -> one finding, ``fixed: false``
  (confirmed-but-not-yet-fixed-or-quarantined).
* ``false_positive``              -> never counted; explicitly excluded.
* ``large_repo_mode_activated``   -> not reduced into findings (informational).
* ``finalize``                    -> emitted by finalize.sh itself; ignored
  (it is written to the ledger AFTER summarize.sh runs, so it is never present
  in the ledger at reduction time; excluded from FINDING_EVENTS defensively).

``status`` derivation
----------------------
* ``complete``  — the real report.md was written (``report_is_stub=False``).
* ``partial``   — the report was a stub AND some progress was made (recon
  coverage > 0).
* ``stalled``   — the report was a stub AND no coverage progress was recorded
  (covered == 0, including when recon.json is missing/malformed).

This mirrors what ``scripts/finalize.sh``'s ``_emit_stub_report`` can already
detect (it decides whether to call the stub-writer at all) — the caller passes
that same boolean through as ``report_is_stub`` so status derivation never
duplicates or drifts from the stub-detection logic already in bash.

``root_cause_clusters[]``, ``follow_up[]``, ``flaky[]`` (bugsweep-xdw)
-----------------------------------------------------------------------
Additive, OPTIONAL fields (schema_version stays 1 — see the schema's
description for the versioning rule: only breaking/removed/renamed fields
bump schema_version; new optional fields never do).

* ``root_cause_clusters[]`` — groups this run's FINDING_EVENTS findings (the
  same events counted in ``findings``/``counts`` above) by the finding's
  ``category``. A cluster of size 1 is not a cluster — it is excluded (a
  singleton finding is not evidence of a broader pattern; it stays visible
  only in ``findings``). Ordering is deterministic: size descending, then
  cluster name ascending; ``representative`` is the lexicographically smallest
  bug_id so the result is member-order-independent. (The cluster key is
  category-only: no component emits a ``variant``/``sink_class`` field into
  the fix_committed/quarantine/confirmed events this reducer reads, so a
  category::variant key would be unreachable dead code — a future bead adds it
  back alongside a real emitter.)
* ``follow_up[]`` — the "where to look next" handoff for the next session,
  built from three sources (never invented, absent -> that source
  contributes nothing):
    1. ``uncovered_batch`` — ``recon.json``'s ``batches[]`` whose ``id`` is
       NOT in ``covered``; ``detail`` is the batch's ``tier`` if present.
    2. ``high_risk_file`` / ``stale_file`` — read from ``prior-coverage.json``
       (schema: ``scripts/state.sh``'s ``prime`` writer): ``high_risk_files``
       (``[{file, score}]``) and ``files_audited_stale_catalog`` (``[file,
       ...]``) respectively. ``prior-coverage.json`` is optional input (a
       fresh repo's first run has none) — missing/malformed -> those two
       kinds simply contribute zero entries, never an error.
    3. ``quarantined`` — this run's quarantined findings (bug_id + file).
  Deterministic order: uncovered_batch (batch id ascending) -> high_risk_file
  (score descending) -> stale_file (alphabetical) -> quarantined
  (alphabetical by bug_id). Capped at ``FOLLOW_UP_CAP`` entries total (applied
  after ordering, so the cap always drops the lowest-priority tail) — a large
  stale-file backlog must never make run-summary.json unbounded.
* ``flaky[]`` — one entry per ``{"event": "flaky_test", "test", "file",
  "reruns", "failures"}`` ledger event (emitted by a sibling work unit's test
  runner instrumentation). Same tolerant-field contract as FINDING_EVENTS:
  any of ``test``/``file``/``reruns``/``failures`` may be absent and is
  emitted as ``null``, never invented. Empty array when no such events exist
  (e.g. the emitter hasn't landed yet, or no flakiness was observed).

``near_misses[]`` (bugsweep-dxh, ``--recall`` mode)
-----------------------------------------------------
Additive, OPTIONAL field (schema_version stays 1 — same versioning rule as
the bugsweep-xdw fields above).

* One entry per ``{"event": "near_miss", "bug_id", "severity", "category",
  "file", "line", "rationale", "confidence"}`` ledger event. Per
  ``prompts/referee.md``'s recall-mode instructions, the Referee emits this
  event ONLY for DISPUTED/REJECTED items it is genuinely torn on (confidence
  50-67 — plausible but not the >67% required for CONFIRMED). Same
  tolerant-field contract as FINDING_EVENTS: any field may be absent and is
  emitted as ``null``, never invented; ``bug_id`` is str()-coerced like
  ``_finding_from_event`` does.
* Gated ENTIRELY by ``reduce_run``'s ``recall`` keyword (default ``False``,
  backward compatible): when ``recall`` is falsy, ``near_misses`` is always
  ``[]``, regardless of whether ``near_miss`` events exist in the ledger.
  When truthy, every ``near_miss`` event in the ledger is surfaced.
* **THE SAFETY INVARIANT**: ``near_miss`` is deliberately NOT a member of
  ``FINDING_EVENTS`` (see below), so it can never contribute to
  ``fixed``/``quarantined``/``confirmed_unfixed``/``findings``/``counts`` —
  those are computed from a single loop over ``FINDING_EVENTS`` lines only,
  untouched by ``recall``. ``recall`` therefore changes ONLY the
  ``near_misses`` key of the returned dict; it can never promote a near-miss
  into fix-eligibility, and it can never suppress a real finding. This
  property is asserted directly by
  ``test_recall_never_changes_fix_eligibility`` in
  ``bench/tests/unit/test_run_summary.py``.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

#: Ledger events that represent a single confirmed-bug finding, and whether
#: that event means the bug was fixed. Order defines no precedence; each event
#: line produces exactly one finding entry.
FINDING_EVENTS: dict[str, bool] = {
    "fix_committed": True,
    "quarantine": False,
    "confirmed": False,
}

#: Findings-level fields tolerated on any FINDING_EVENTS line. Anything absent
#: is emitted as null/empty — never invented (see module docstring).
_FINDING_FIELDS = ("bug_id", "severity", "category", "file", "line", "rationale")

_SEVERITIES = ("critical", "high", "medium", "low")
_ARCHITECTURAL_CATEGORY = "architectural"

_STOP_REASON_STALLED = (
    "report.md was never written and no hunt batches were covered — the run "
    "stalled before making any progress (e.g. during context-build)."
)
_STOP_REASON_PARTIAL = (
    "report.md was never written but some hunt batches were covered — the run "
    "made partial progress before stopping (e.g. during the architectural hunt)."
)

#: Minimum cluster size for ``root_cause_clusters[]`` — a singleton finding is
#: not evidence of a broader pattern (see module docstring).
_MIN_CLUSTER_SIZE = 2

#: Maximum number of entries in ``follow_up[]`` (applied after deterministic
#: ordering, so the cap always drops the lowest-priority tail: quarantined
#: findings and low-score stale files are dropped before uncovered batches or
#: high-risk files). Chosen to keep run-summary.json bounded even against a
#: large stale-file backlog from prior-coverage.json.
FOLLOW_UP_CAP = 50

#: Fields tolerated on a ``flaky_test`` ledger event; absent -> null, never
#: invented (same tolerance contract as _FINDING_FIELDS).
_FLAKY_FIELDS = ("test", "file", "reruns", "failures")

#: Fields tolerated on a ``near_miss`` ledger event (bugsweep-dxh, --recall
#: mode); absent -> null, never invented (same tolerance contract as
#: _FINDING_FIELDS, plus ``confidence`` — the Referee's numeric confidence,
#: expected in the 50-67 "plausible but not CONFIRMED" band per
#: prompts/referee.md. This reducer does not enforce that range: the Referee
#: is responsible for only emitting near_miss events inside it; the reducer's
#: job is tolerant surfacing, not re-validating upstream judgment.
_NEAR_MISS_FIELDS = ("bug_id", "severity", "category", "file", "line", "rationale", "confidence")


def _iter_ledger_events(ledger_path: Path) -> list[dict[str, Any]]:
    """Parse ``ledger_path`` as JSONL, skipping blank/malformed lines.

    Never raises: a missing file yields ``[]``; a line that isn't a JSON
    object is silently skipped (mirrors ``scripts/state.sh``'s persist
    reduction, which has the same tolerance for a mid-write/truncated line).
    """
    if not ledger_path.is_file():
        return []
    events: list[dict[str, Any]] = []
    for line in ledger_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(parsed, dict):
            events.append(parsed)
    return events


def _read_recon_coverage(recon_path: Path) -> tuple[int, int]:
    """Return ``(covered, total)`` from ``recon.json``, or ``(0, 0)`` on any
    absence/parse failure (never raises — a broken/missing recon file must
    never fail the reduction, only report zero coverage)."""
    if not recon_path.is_file():
        return (0, 0)
    try:
        data = json.loads(recon_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, ValueError):
        return (0, 0)
    if not isinstance(data, dict):
        return (0, 0)
    covered_list = data.get("covered") or []
    covered = len(covered_list) if isinstance(covered_list, list) else 0
    total = data.get("batch_count")
    if not isinstance(total, int):
        batches = data.get("batches") or []
        total = len(batches) if isinstance(batches, list) else 0
    return (covered, total)


def _derive_status(*, report_is_stub: bool, covered: int) -> tuple[str, str | None]:
    if not report_is_stub:
        return ("complete", None)
    if covered > 0:
        return ("partial", _STOP_REASON_PARTIAL)
    return ("stalled", _STOP_REASON_STALLED)


def _finding_from_event(event: dict[str, Any], *, fixed: bool) -> dict[str, Any]:
    finding: dict[str, Any] = {field: event.get(field) for field in _FINDING_FIELDS}
    line = finding.get("line")
    finding["line"] = line if isinstance(line, int) else None
    # bug_id is a schema type:string identifier (e.g. "BUG-1"), but nothing
    # upstream forces the ledger to write it as a string — coerce a present
    # non-string (e.g. an integer) so findings[], the fixed/quarantined/
    # confirmed_unfixed id-lists, and every downstream consumer stay schema-
    # valid (review MAJOR 3). Absent stays None, never invented.
    bug_id = finding.get("bug_id")
    finding["bug_id"] = str(bug_id) if bug_id is not None else None
    finding["fixed"] = fixed
    return finding


def _empty_counts() -> dict[str, int]:
    return {"critical": 0, "high": 0, "medium": 0, "low": 0, "architectural": 0}


def _cluster_key(event: dict[str, Any]) -> str | None:
    """Return the ``root_cause_clusters`` grouping key for a FINDING_EVENTS
    ledger line, or ``None`` when the event carries no category (never
    invented — an uncategorized finding cannot be clustered). The key is the
    bare ``category``: no component emits a ``variant``/``sink_class`` field
    into the events reduce_run reads, so a category::variant key would be
    unreachable (see module docstring)."""
    category = event.get("category")
    if not category or not isinstance(category, str):
        return None
    return category


def build_clusters(members_by_key: dict[str, list[dict[str, Any]]]) -> list[dict[str, Any]]:
    """Turn a ``cluster_key -> [member dicts]`` grouping into the ordered
    ``root_cause_clusters[]`` shape, dropping clusters below _MIN_CLUSTER_SIZE.

    Shared by ``_build_root_cause_clusters`` (per-run, members are ledger
    events) and ``session_summary._merge_clusters`` (per-session, members are
    findings) so the size-threshold, representative (lowest bug_id — order
    invariant), file-union, and ordering (size desc, then cluster name asc)
    rules live in exactly one place. ``size`` is the count of contributing
    members; ``representative`` is the lexicographically smallest bug_id so the
    result is independent of member/input order."""
    clusters: list[dict[str, Any]] = []
    for key, members in members_by_key.items():
        if len(members) < _MIN_CLUSTER_SIZE:
            continue
        bug_ids = sorted(str(m["bug_id"]) for m in members if m.get("bug_id"))
        files = sorted({m["file"] for m in members if m.get("file")})
        clusters.append(
            {
                "cluster": key,
                "size": len(members),
                "representative": bug_ids[0] if bug_ids else None,
                "files": files,
            }
        )
    clusters.sort(key=lambda c: (-c["size"], c["cluster"]))
    return clusters


def _build_root_cause_clusters(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Group this run's FINDING_EVENTS lines by ``_cluster_key``, then reduce
    via ``build_clusters`` (size < _MIN_CLUSTER_SIZE excluded; deterministic
    order)."""
    groups: dict[str, list[dict[str, Any]]] = {}
    for event in events:
        if event.get("event") not in FINDING_EVENTS:
            continue
        key = _cluster_key(event)
        if key is None:
            continue
        groups.setdefault(key, []).append(event)
    return build_clusters(groups)


def _read_prior_coverage(prior_coverage_path: Path | None) -> dict[str, Any]:
    """Return the parsed ``prior-coverage.json`` dict, or ``{}`` on any
    absence/parse failure (never raises — mirrors ``_read_recon_coverage``'s
    tolerance; schema: ``scripts/state.sh``'s ``prime`` writer)."""
    if prior_coverage_path is None or not prior_coverage_path.is_file():
        return {}
    try:
        data = json.loads(prior_coverage_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _uncovered_batch_entries(recon_path: Path) -> list[dict[str, Any]]:
    """``uncovered_batch`` follow_up entries: recon.json's ``batches[]`` whose
    ``id`` is not in ``covered``, ordered by batch id ascending."""
    if not recon_path.is_file():
        return []
    try:
        data = json.loads(recon_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, ValueError):
        return []
    if not isinstance(data, dict):
        return []

    batches = data.get("batches") or []
    if not isinstance(batches, list):
        return []
    covered_ids = set(data.get("covered") or [])

    entries = []
    for batch in batches:
        if not isinstance(batch, dict):
            continue
        batch_id = batch.get("id")
        if batch_id is None or batch_id in covered_ids:
            continue
        entries.append((batch_id, batch.get("tier")))

    # Integer ids sort numerically ascending; any non-int id (string batch id)
    # sorts after all ints, then lexicographically by str(id) — so every
    # ordering is well-defined and input-order-independent (review MAJOR 4).
    entries.sort(key=lambda pair: (0, pair[0]) if isinstance(pair[0], int) else (1, str(pair[0])))
    return [
        {"kind": "uncovered_batch", "ref": str(batch_id), "detail": tier}
        for batch_id, tier in entries
    ]


def _high_risk_file_entries(prior_coverage: dict[str, Any]) -> list[dict[str, Any]]:
    """``high_risk_file`` follow_up entries, ordered by score descending."""
    high_risk = prior_coverage.get("high_risk_files") or []
    if not isinstance(high_risk, list):
        return []
    rows = []
    for item in high_risk:
        if not isinstance(item, dict):
            continue
        file_ = item.get("file")
        if not file_:
            continue
        score = item.get("score")
        rows.append((file_, score))
    # Primary: score descending. Secondary: file ascending — so files tied on
    # score have a stable order regardless of prior-coverage.json's list order
    # (review MAJOR 4).
    rows.sort(
        key=lambda pair: (-(pair[1] if isinstance(pair[1], (int, float)) else 0), pair[0])
    )
    return [
        {
            "kind": "high_risk_file",
            "ref": file_,
            "detail": str(score) if score is not None else None,
        }
        for file_, score in rows
    ]


def _stale_file_entries(prior_coverage: dict[str, Any]) -> list[dict[str, Any]]:
    """``stale_file`` follow_up entries, ordered alphabetically."""
    stale = prior_coverage.get("files_audited_stale_catalog") or []
    if not isinstance(stale, list):
        return []
    files = sorted({f for f in stale if isinstance(f, str)})
    return [{"kind": "stale_file", "ref": f, "detail": None} for f in files]


def _quarantined_entries(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """``quarantined`` follow_up entries, ordered alphabetically by bug_id.

    ``ref`` is str()-coerced: nothing upstream forces bug_id to be a string, so
    an integer bug_id must not leak through as a non-string ref (which would
    fail the schema's ``ref: type=string``; review MAJOR 3)."""
    rows = []
    for event in events:
        if event.get("event") != "quarantine":
            continue
        bug_id = event.get("bug_id")
        if not bug_id:
            continue
        rows.append((str(bug_id), event.get("file")))
    rows.sort(key=lambda pair: pair[0])
    return [{"kind": "quarantined", "ref": bug_id, "detail": file_} for bug_id, file_ in rows]


def _build_follow_up(
    *,
    events: list[dict[str, Any]],
    recon_path: Path,
    prior_coverage_path: Path | None,
) -> list[dict[str, Any]]:
    """Assemble the ``follow_up[]`` handoff in deterministic priority order
    (see module docstring), then apply FOLLOW_UP_CAP."""
    prior_coverage = _read_prior_coverage(prior_coverage_path)
    follow_up = (
        _uncovered_batch_entries(recon_path)
        + _high_risk_file_entries(prior_coverage)
        + _stale_file_entries(prior_coverage)
        + _quarantined_entries(events)
    )
    return follow_up[:FOLLOW_UP_CAP]


def _build_flaky(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """One entry per ``flaky_test`` ledger event, tolerant of absent fields."""
    return [
        {field: event.get(field) for field in _FLAKY_FIELDS}
        for event in events
        if event.get("event") == "flaky_test"
    ]


def _build_near_misses(events: list[dict[str, Any]], *, recall: bool) -> list[dict[str, Any]]:
    """One entry per ``near_miss`` ledger event, tolerant of absent fields —
    ONLY when ``recall`` is truthy (bugsweep-dxh's ``--recall`` mode).

    This function is the field's SOLE gate. ``recall`` must never reach the
    fixed/quarantined/confirmed_unfixed/findings/counts computation in
    ``reduce_run`` — ``near_miss`` is not a member of ``FINDING_EVENTS``, so
    that computation is identical regardless of ``recall``. Keeping this as
    the one and only recall-gated call site is what makes the safety
    invariant (near-misses are reporting-only, never fix-eligible) verifiable
    by inspection, not just by test.
    """
    if not recall:
        return []
    near_misses: list[dict[str, Any]] = []
    for event in events:
        if event.get("event") != "near_miss":
            continue
        entry: dict[str, Any] = {field: event.get(field) for field in _NEAR_MISS_FIELDS}
        line = entry.get("line")
        entry["line"] = line if isinstance(line, int) else None
        confidence = entry.get("confidence")
        entry["confidence"] = confidence if isinstance(confidence, int) else None
        bug_id = entry.get("bug_id")
        entry["bug_id"] = str(bug_id) if bug_id is not None else None
        near_misses.append(entry)
    return near_misses


def reduce_run(
    *,
    ledger_path: Path,
    recon_path: Path,
    report_is_stub: bool,
    mode: str | None,
    prior_coverage_path: Path | None = None,
    recall: bool = False,
) -> dict[str, Any]:
    """Reduce one run's on-disk state into a schema-valid run-summary dict.

    ``prior_coverage_path`` is optional (default ``None``) for backward
    compatibility with existing callers; when omitted, ``follow_up[]`` simply
    has no ``high_risk_file``/``stale_file`` entries (see
    ``_build_follow_up``).

    ``recall`` (default ``False``, backward compatible; bugsweep-dxh) gates
    ONLY the ``near_misses[]`` field — see ``_build_near_misses``. It never
    affects ``fixed``/``quarantined``/``confirmed_unfixed``/``findings``/
    ``counts``, which are computed from ``FINDING_EVENTS`` lines alone and
    never see ``near_miss`` events regardless of this flag.

    Pure function: no subprocess, no network. Never raises on missing or
    malformed input files — this is the backstop that must produce a valid
    ``run-summary.json`` even for a run that stalled before writing anything.
    """
    events = _iter_ledger_events(ledger_path)
    covered, total = _read_recon_coverage(recon_path)
    status, stop_reason = _derive_status(report_is_stub=report_is_stub, covered=covered)

    findings: list[dict[str, Any]] = []
    fixed: list[str] = []
    quarantined: list[str] = []
    confirmed_unfixed: list[str] = []
    counts = _empty_counts()

    for event in events:
        name = event.get("event")
        if name not in FINDING_EVENTS:
            continue
        is_fixed = FINDING_EVENTS[name]
        finding = _finding_from_event(event, fixed=is_fixed)
        findings.append(finding)

        bug_id = finding["bug_id"]
        if name == "fix_committed" and bug_id:
            fixed.append(bug_id)
        elif name == "quarantine" and bug_id:
            quarantined.append(bug_id)
        elif name == "confirmed" and bug_id:
            confirmed_unfixed.append(bug_id)

        severity = finding["severity"]
        if severity in _SEVERITIES:
            counts[severity] += 1
        if finding["category"] == _ARCHITECTURAL_CATEGORY:
            counts[_ARCHITECTURAL_CATEGORY] += 1

    return {
        "schema_version": SCHEMA_VERSION,
        "mode": mode,
        "status": status,
        "stop_reason": stop_reason,
        "coverage": {"covered": covered, "total": total},
        "counts": counts,
        "fixed": fixed,
        "quarantined": quarantined,
        "confirmed_unfixed": confirmed_unfixed,
        "findings": findings,
        "root_cause_clusters": _build_root_cause_clusters(events),
        "follow_up": _build_follow_up(
            events=events, recon_path=recon_path, prior_coverage_path=prior_coverage_path
        ),
        "flaky": _build_flaky(events),
        "near_misses": _build_near_misses(events, recall=recall),
    }


def reduce_run_degraded(
    *,
    covered: int,
    total: int,
    report_is_stub: bool,
    mode: str | None,
) -> dict[str, Any]:
    """The degraded-mode summary ``scripts/summarize.sh`` falls back to when
    python3 is unavailable: status/stop_reason/coverage only, computed from
    grep-able ledger/recon values the caller (bash) already extracted; empty
    findings (extracting findings without python3 is not attempted — never
    guess), and ``"degraded": true`` so a consumer can distinguish this from a
    full reduction.
    """
    status, stop_reason = _derive_status(report_is_stub=report_is_stub, covered=covered)
    return {
        "schema_version": SCHEMA_VERSION,
        "mode": mode,
        "status": status,
        "stop_reason": stop_reason,
        "degraded": True,
        "coverage": {"covered": covered, "total": total},
        "counts": _empty_counts(),
        "fixed": [],
        "quarantined": [],
        "confirmed_unfixed": [],
        "findings": [],
        "root_cause_clusters": [],
        "follow_up": [],
        "flaky": [],
        "near_misses": [],
    }
