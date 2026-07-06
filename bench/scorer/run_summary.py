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
    finding["fixed"] = fixed
    return finding


def _empty_counts() -> dict[str, int]:
    return {"critical": 0, "high": 0, "medium": 0, "low": 0, "architectural": 0}


def reduce_run(
    *,
    ledger_path: Path,
    recon_path: Path,
    report_is_stub: bool,
    mode: str | None,
) -> dict[str, Any]:
    """Reduce one run's on-disk state into a schema-valid run-summary dict.

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
    }
