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
* ``batch_covered``               -> coverage handshake: a batch counts only
  when its id appears in both this ledger event and recon.json's ``covered``
  list. Either surface alone is treated as an incomplete checkpoint.
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
* ``partial``   — the report was a stub AND some progress was confirmed by the
  recon/ledger coverage handshake (covered > 0).
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
       not in the intersection of ``recon.covered`` and ledger
       ``batch_covered`` events; ``detail`` is the batch's ``tier`` if present.
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

``vote_split`` on high/critical findings (bugsweep-hcj)
---------------------------------------------------------
Additive, OPTIONAL field on each ``findings[]`` entry (schema_version stays 1
— same versioning rule as the fields above).

* A SINGLE Referee adjudication is not enough independent evidence to decide
  whether a HIGH/CRITICAL finding becomes fix-eligible (and therefore gets
  auto-edited). Per ``prompts/referee.md``'s K-vote majority section, for
  severity >= high the Referee performs K independent adjudications with
  varied framing and records each vote to the ledger as
  ``{"event": "referee_vote", "bug_id", "severity", "verdict"}`` where
  ``verdict`` is the literal string ``"CONFIRMED"`` or ``"NOT_CONFIRMED"``.
* ``majority_gate()`` is the pure, unit-testable rule (no ledger, no I/O)
  that turns a raw verdict list into ``{"confirmed", "total", "eligible"}``:
  ``eligible`` requires a STRICT MAJORITY of ``"CONFIRMED"`` votes — more
  confirmed than every other outcome combined. A tie is NOT eligible
  (conservative by design: a lone or non-majority CONFIRMED must never
  promote a high/critical finding).
* ``reduce_run`` attaches ``vote_split`` to a ``findings[]`` entry ONLY when
  BOTH: (a) the finding's severity is ``"high"`` or ``"critical"``, and (b)
  at least one matching ``referee_vote`` event exists in the ledger for that
  finding's ``bug_id`` (str()-coerced the same way finding-level ``bug_id``
  is). Otherwise the key is simply absent — never invented, never a guessed
  default.
* **Low-severity path UNCHANGED**: a ``medium``/``low`` finding never gets a
  ``vote_split``, even if stray ``referee_vote`` events happen to reference
  its ``bug_id`` — single-pass eligibility, exactly as before this field
  existed.
* **Scope**: this field is reporting-only. It never retroactively removes a
  bug_id from ``fixed``/``quarantined``/``confirmed_unfixed`` — those already
  reflect what the live Referee/orchestrator wrote to the ledger, which is
  where the majority gate is actually enforced (before the
  ``fix_committed``/``quarantine``/``confirmed`` event is ever written; see
  ``prompts/referee.md``). ``vote_split`` makes that decision auditable
  after the fact in the machine-readable summary.

``repro`` on every finding (bugsweep-hty)
-------------------------------------------
Additive, OPTIONAL field on each ``findings[]`` entry (schema_version stays 1
— same versioning rule as the fields above). Unlike ``vote_split``, this
field is **always** attached (default ``"none"``) rather than conditionally
absent — see ``_repro_for_bug``.

* A described trigger is not executable proof. Per ``prompts/repro.md`` and
  ``scripts/repro.sh``, a confirmed bug with a reproducible shape gets a
  minimal test synthesized and run through a red (pre-fix) -> green
  (post-fix) cycle, ADDITIONAL to (never instead of) the suite-green check
  ``scripts/run_checks.sh verify`` already performs.
* Each terminal outcome of that cycle appends exactly one ledger event,
  ``{"event": "repro_status", "bug_id", "status"}``, where ``status`` is one
  of:
    - ``"none"`` — no repro command was available (no framework detected, or
      the bug's shape isn't reproducible as a minimal test).
    - ``"unreproduced"`` — a repro was attempted but did NOT fail before the
      fix, so it never demonstrated the bug; falls back to suite-only gating,
      exactly like ``"none"``.
    - ``"confirmed"`` — the repro FAILED before the fix and PASSED after it
      (the strongest evidence a fix actually resolved the bug). Only ever
      seen on a ``fix_committed`` finding.
    - ``"failed"`` — the repro was still RED after the fix, meaning the fix
      must have been reverted and quarantined per ``prompts/fix.md``'s step
      3b. Only ever seen on a ``quarantine`` finding.
* ``_repro_for_bug`` looks up the ``repro_status`` event(s) matching a
  finding's ``bug_id`` (str()-coerced, same contract as ``_votes_for_bug``)
  and returns the LAST matching status found (ledger-order tolerant, though
  in practice exactly one terminal event is ever written per bug_id).
  ``bug_id is None``, or no matching event exists at all (the repro phase
  was skipped for this bug, e.g. because no framework was detected), both
  default to ``"none"`` — the same value ``scripts/repro.sh`` itself emits
  for a bug with no repro command, so an untouched finding reads identically
  to one that explicitly declined to attempt reproduction (see the bead's
  design note: "no framework or non-reproducible shape => mark repro:
  none").
* **Safety invariant**: ``repro_status`` is deliberately NOT a member of
  ``FINDING_EVENTS`` (same isolation pattern as ``referee_vote`` and
  ``near_miss``), so it can never itself contribute to
  ``fixed``/``quarantined``/``confirmed_unfixed``/``findings``/``counts`` —
  those are computed from ``FINDING_EVENTS`` lines alone. ``repro`` is
  reporting-only: it never changes which list a bug_id lands in, it only
  annotates the finding that a real ``fix_committed``/``quarantine``/
  ``confirmed`` ledger line already produced.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, cast

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

#: Ledger event recording a single Referee K-vote adjudication (bugsweep-hcj).
#: Deliberately NOT a member of FINDING_EVENTS — same isolation pattern as
#: ``near_miss`` — so a vote can never itself contribute to fixed/
#: quarantined/confirmed_unfixed/counts; it only informs the ``vote_split``
#: attached to a finding that already came from a real FINDING_EVENTS line.
_VOTE_EVENT = "referee_vote"

#: The literal verdict string a referee_vote event must carry to count as a
#: confirming vote in majority_gate(). Anything else (including the
#: "NOT_CONFIRMED" string, None, or a malformed/unexpected value) counts
#: against the majority — tolerant, never invented.
_VOTE_CONFIRMED = "CONFIRMED"

#: Severities for which reduce_run looks for referee_vote events and attaches
#: vote_split. Per prompts/referee.md (bugsweep-hcj), only severity >= high
#: runs K independent adjudications; medium/low stay single-pass and never
#: get a vote_split (see module docstring).
_VOTE_ELIGIBLE_SEVERITIES = frozenset({"critical", "high"})

#: Ledger event recording the repro gate's terminal outcome for one bug_id
#: (bugsweep-hty), emitted by scripts/repro.sh. Deliberately NOT a member of
#: FINDING_EVENTS — same isolation pattern as ``referee_vote``/``near_miss``
#: — so it can never itself contribute to fixed/quarantined/
#: confirmed_unfixed/counts; it only informs the ``repro`` field attached to
#: a finding that already came from a real FINDING_EVENTS line.
_REPRO_EVENT = "repro_status"

#: The default/fallback repro status: no repro command was available, or the
#: repro phase was never attempted/recorded for this bug_id. Matches the
#: value scripts/repro.sh itself emits for a bug with no repro command (see
#: module docstring).
_REPRO_DEFAULT = "none"

#: The full closed set of statuses scripts/repro.sh ever writes to a
#: repro_status ledger event. A status value outside this set (a malformed
#: or future-version event) is tolerated but ignored — never invented, never
#: trusted blindly (same defensive posture as majority_gate's verdict
#: tolerance).
_REPRO_STATUSES = frozenset({"none", "unreproduced", "confirmed", "failed"})


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


def _batch_ids(values: object) -> set[int]:
    """Return valid positive integer batch IDs from an array-like field."""
    if not isinstance(values, list):
        return set()
    ids: set[int] = set()
    for value in values:
        if isinstance(value, int) and not isinstance(value, bool) and value > 0:
            ids.add(value)
    return ids


def _ledger_covered_ids(events: list[dict[str, Any]]) -> set[int]:
    """Return deduplicated batch ids from valid ``batch_covered`` events."""
    ids: set[int] = set()
    for event in events:
        if event.get("event") != "batch_covered":
            continue
        batch_id = event.get("batch", event.get("id"))
        if isinstance(batch_id, int) and not isinstance(batch_id, bool) and batch_id > 0:
            ids.add(batch_id)
    return ids


def _read_recon_coverage(
    recon_path: Path,
    ledger_covered_ids: set[int],
    verified_covered_ids: set[int] | None = None,
) -> tuple[int, int]:
    """Return handshake-confirmed ``(covered, total)`` from ``recon.json``.

    A batch counts only when its id is present in both ``recon.covered`` and a
    parsed ledger ``batch_covered`` event. Absence or parse failure returns
    ``(0, 0)``; malformed state never raises.
    """
    if not recon_path.is_file():
        return (0, 0)
    try:
        data = json.loads(recon_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, ValueError):
        return (0, 0)
    if not isinstance(data, dict):
        return (0, 0)
    raw_batches = data.get("batches") or []
    batch_ids = (
        {
            batch["id"]
            for batch in raw_batches
            if isinstance(batch, dict)
            and isinstance(batch.get("id"), int)
            and not isinstance(batch.get("id"), bool)
            and batch["id"] > 0
        }
        if isinstance(raw_batches, list)
        else set()
    )
    covered_ids = _batch_ids(data.get("covered") or []) & ledger_covered_ids & batch_ids
    if verified_covered_ids is not None:
        covered_ids &= verified_covered_ids
    covered = len(covered_ids)
    # Concrete, valid batch IDs are the only coverage denominator. A malformed
    # or inconsistent batch_count (including bool, which is an int subclass)
    # must not produce an impossible or schema-invalid summary.
    total = len(batch_ids)
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


def _repro_for_bug(events: list[dict[str, Any]], bug_id: str | None) -> str:
    """Return the repro-gate status recorded for ``bug_id`` (bugsweep-hty),
    defaulting to ``_REPRO_DEFAULT`` ("none") when ``bug_id`` is ``None`` or
    no matching ``repro_status`` event exists.

    Mirrors ``_votes_for_bug``'s matching contract (``bug_id`` str()-coerced
    the same way finding-level ``bug_id`` is) but returns a single status
    string rather than a list: exactly one terminal ``repro_status`` event is
    ever written per bug_id in practice (see scripts/repro.sh), but if more
    than one somehow exists, the LAST one in ledger order wins — the same
    "most recent state wins" tolerance the rest of this module applies to
    ledger replay. A status value outside ``_REPRO_STATUSES`` (malformed or
    from a future version) is skipped rather than trusted, leaving whatever
    the last VALID status was (or the default, if none was ever valid).
    """
    if bug_id is None:
        return _REPRO_DEFAULT
    status = _REPRO_DEFAULT
    for event in events:
        if event.get("event") != _REPRO_EVENT:
            continue
        event_bug_id = event.get("bug_id")
        if event_bug_id is None or str(event_bug_id) != bug_id:
            continue
        value = event.get("status")
        if isinstance(value, str) and value in _REPRO_STATUSES:
            status = value
    return status


def majority_gate(verdicts: list[str]) -> dict[str, Any]:
    """Pure majority-vote gate for K independent Referee adjudications
    (bugsweep-hcj).

    A high/critical finding becomes fix-eligible ONLY on a STRICT MAJORITY of
    ``verdicts`` equal to the literal string ``"CONFIRMED"`` — strictly more
    confirmed votes than every other outcome combined. A tie is NOT eligible:
    deliberately conservative, mirroring ``prompts/referee.md``'s existing
    "when in doubt, default to NOT CONFIRMED" rule — a single lone CONFIRMED
    vote, or an even split, must never promote a critical/high finding.

    ``verdicts`` is the raw per-adjudication verdict list (e.g.
    ``["CONFIRMED", "CONFIRMED", "NOT_CONFIRMED"]``). Any value other than the
    literal string ``"CONFIRMED"`` counts as a non-confirming vote — tolerant
    of ``"NOT_CONFIRMED"``, ``None``, or any other value; never raises.

    Returns ``{"confirmed": <n>, "total": <k>, "eligible": <bool>}``. An empty
    vote list is never eligible (``0/0`` — no votes cast means nothing was
    confirmed).

    Pure function: no I/O, no ledger access. This is what
    ``bench/tests/unit/test_run_summary.py`` exercises directly with MOCKED
    vote sets (2/3 -> eligible, 1/3 -> not eligible, ties -> not eligible).
    """
    total = len(verdicts)
    confirmed = sum(1 for v in verdicts if v == _VOTE_CONFIRMED)
    eligible = total > 0 and confirmed * 2 > total
    return {"confirmed": confirmed, "total": total, "eligible": eligible}


def _votes_for_bug(events: list[dict[str, Any]], bug_id: str) -> list[str]:
    """Raw ``verdict`` values from every ``referee_vote`` ledger event whose
    ``bug_id`` (str()-coerced, same contract as ``_finding_from_event``)
    matches ``bug_id``. Order follows ledger order; malformed/absent
    ``bug_id`` on a vote event is skipped rather than guessed."""
    votes: list[str] = []
    for event in events:
        if event.get("event") != _VOTE_EVENT:
            continue
        event_bug_id = event.get("bug_id")
        if event_bug_id is None or str(event_bug_id) != bug_id:
            continue
        votes.append(cast(str, event.get("verdict")))
    return votes


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


def _uncovered_batch_entries(
    recon_path: Path,
    ledger_covered_ids: set[int],
    verified_covered_ids: set[int] | None = None,
) -> list[dict[str, Any]]:
    """Return batches outside the two-surface coverage intersection."""
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
    covered_ids = _batch_ids(data.get("covered") or []) & ledger_covered_ids
    if verified_covered_ids is not None:
        covered_ids &= verified_covered_ids

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
    rows.sort(key=lambda pair: (-(pair[1] if isinstance(pair[1], (int, float)) else 0), pair[0]))
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
    ledger_covered_ids: set[int],
    verified_covered_ids: set[int] | None,
) -> list[dict[str, Any]]:
    """Assemble the ``follow_up[]`` handoff in deterministic priority order
    (see module docstring), then apply FOLLOW_UP_CAP."""
    prior_coverage = _read_prior_coverage(prior_coverage_path)
    follow_up = (
        _uncovered_batch_entries(recon_path, ledger_covered_ids, verified_covered_ids)
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
    verified_covered_ids: set[int] | None = None,
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
    ledger_covered_ids = _ledger_covered_ids(events)
    covered, total = _read_recon_coverage(recon_path, ledger_covered_ids, verified_covered_ids)
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

        # repro (bugsweep-hty): always attached, defaulting to "none" — see
        # _repro_for_bug. Unlike vote_split's conditional-absence pattern,
        # every finding gets a repro classification, matching the design
        # note "no framework or non-reproducible shape => mark repro: none".
        finding["repro"] = _repro_for_bug(events, bug_id)

        severity = finding["severity"]
        if severity in _SEVERITIES:
            counts[severity] += 1
        if finding["category"] == _ARCHITECTURAL_CATEGORY:
            counts[_ARCHITECTURAL_CATEGORY] += 1

        # vote_split (bugsweep-hcj): additive, OPTIONAL — attached ONLY for
        # severity >= high AND only when referee_vote events actually exist
        # for this bug_id. Low/medium severity is never touched (single-pass,
        # unchanged); a high/critical finding with no recorded votes simply
        # has no vote_split key (never invented). See module docstring.
        if bug_id and severity in _VOTE_ELIGIBLE_SEVERITIES:
            votes = _votes_for_bug(events, bug_id)
            if votes:
                finding["vote_split"] = majority_gate(votes)

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
            events=events,
            recon_path=recon_path,
            prior_coverage_path=prior_coverage_path,
            ledger_covered_ids=ledger_covered_ids,
            verified_covered_ids=verified_covered_ids,
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
