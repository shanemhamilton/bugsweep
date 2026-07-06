"""Merge N run-summary.json objects (``bench.scorer.run_summary.reduce_run``
output) into one session-level view (bugsweep-xdw).

Why this exists: a single run-summary.json answers "what happened in this
run?". An overnight/nightshift session runs bugsweep multiple times (e.g. once
per repo, or multiple passes over one repo) and needs one aggregate view to
decide "how did the whole session go?" without a scheduler re-deriving that
logic from N separate files each time.

Merge rules (ground truth for this module; see tests in
bench/tests/unit/test_session_summary.py for the executable spec)
------------------------------------------------------------------
* ``totals`` — per-severity counts summed across every run's ``counts``.
  Missing/malformed ``counts`` (e.g. an older run-summary.json predating a
  severity key) contribute 0 for the missing keys — never raises.
* ``root_cause_clusters`` — re-derived ACROSS runs from every run's
  ``findings[]`` (NOT from each run's already-size-filtered
  ``root_cause_clusters[]``), grouping by finding ``category`` and applying
  the size>=2 threshold at the SESSION level. This is the point of a
  multi-run session view: two runs that each confirm ONE "xss" bug (2 total —
  a textbook broader-issue signal) yield a session cluster of size 2, even
  though neither run's per-run clusters contained it. ``size`` is the count of
  contributing findings, ``files`` is their deduped union, and
  ``representative`` is the lexicographically smallest bug_id — so the result
  is invariant to caller-supplied summary order (a caller that globs unsorted
  gets a reproducible aggregate). Ordered size descending, then cluster name
  ascending (same order/threshold as a single run's clusters, via the shared
  ``run_summary.build_clusters``).
* ``follow_up`` — concatenated across runs in run order, then deduped by
  ``(kind, ref)`` keeping the FIRST occurrence (first run's detail wins).
  Order is otherwise preserved as encountered (no cap is applied here — the
  per-run FOLLOW_UP_CAP already bounds each contributor; the session view
  keeps everything after dedup, since a scheduler triaging across runs wants
  the full deduped picture).
* ``runs`` — the per-run ``status`` values, in the order the summaries were
  passed in.
* ``run_count`` — the number of runs merged. Present so a scheduler can tell
  the zero-run case (``run_count == 0``) apart from a genuine all-complete
  session (see ``worst_status``).
* ``worst_status`` — the roll-up of ``runs``:
    - ``no_runs`` if there are NO runs at all — a scheduler that globbed for
      run-summary.json and matched nothing (every run crashed pre-finalize, or
      a path misconfig) must NOT read this as a clean success; ``no_runs`` is
      a non-success sentinel it can branch on (review BLOCKER 1).
    - ``stalled`` if EVERY run stalled — a session where nothing ever
      progressed is fully stalled.
    - ``partial`` if the runs are a MIX of outcomes (some stalled/partial,
      some complete) — mixed signals mean the session made uneven progress.
    - ``complete`` if every run completed.
  This mirrors the single-run status semantics (stalled < partial <
  complete) but is deliberately not a simple "worst wins" (a session with 9
  complete runs and 1 stalled run is "partial", not "stalled" — one dead run
  should not fully mask real progress elsewhere).

Pure function: no I/O, no subprocess — callers (scripts/aggregate-summaries.sh
via a thin Python entrypoint, analogous to scripts/_run_summary_reduce.py)
read the run-summary.json files from disk and pass the parsed dicts in.
"""

from __future__ import annotations

from typing import Any

from bench.scorer.run_summary import build_clusters

SESSION_SCHEMA_VERSION = 1

#: worst_status sentinel for a zero-run session — distinct from "complete" so a
#: scheduler cannot mistake "matched no run-summary.json files" for success.
_WORST_STATUS_NO_RUNS = "no_runs"

_SEVERITIES = ("critical", "high", "medium", "low", "architectural")


def _empty_totals() -> dict[str, int]:
    return {severity: 0 for severity in _SEVERITIES}


def _merge_totals(summaries: list[dict[str, Any]]) -> dict[str, int]:
    totals = _empty_totals()
    for summary in summaries:
        counts = summary.get("counts")
        if not isinstance(counts, dict):
            continue
        for severity in _SEVERITIES:
            value = counts.get(severity)
            if isinstance(value, int):
                totals[severity] += value
    return totals


def _merge_clusters(summaries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Re-cluster across runs from each summary's ``findings[]`` (review
    BLOCKER 2): group every categorized finding by ``category`` and apply the
    size>=2 threshold at the SESSION level via the shared
    ``run_summary.build_clusters`` — so a category that was a singleton within
    each run but reaches size 2 across runs surfaces as a session cluster.
    Tolerant of a missing/malformed ``findings`` list or non-dict entries."""
    groups: dict[str, list[dict[str, Any]]] = {}
    for summary in summaries:
        findings = summary.get("findings") or []
        if not isinstance(findings, list):
            continue
        for finding in findings:
            if not isinstance(finding, dict):
                continue
            category = finding.get("category")
            if not category or not isinstance(category, str):
                continue
            groups.setdefault(category, []).append(finding)
    return build_clusters(groups)


def _merge_follow_up(summaries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[Any, Any]] = set()
    merged: list[dict[str, Any]] = []
    for summary in summaries:
        follow_up = summary.get("follow_up") or []
        if not isinstance(follow_up, list):
            continue
        for entry in follow_up:
            if not isinstance(entry, dict):
                continue
            key = (entry.get("kind"), entry.get("ref"))
            if key in seen:
                continue
            seen.add(key)
            merged.append(entry)
    return merged


def _worst_status(statuses: list[str]) -> str:
    if not statuses:
        return _WORST_STATUS_NO_RUNS
    unique = set(statuses)
    if unique == {"complete"}:
        return "complete"
    if unique == {"stalled"}:
        return "stalled"
    return "partial"


def merge_summaries(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    """Merge a list of run-summary.json dicts into one session-summary dict.

    Pure function: never raises on missing/malformed optional keys (mirrors
    ``run_summary.reduce_run``'s tolerance contract) — a summary dict may be
    missing ``findings``/``follow_up``/``counts`` entirely (an older
    run-summary.json predating bugsweep-xdw) and still merges cleanly. Invariant
    to the order in which summaries are supplied (clusters re-derive a stable
    representative; totals/dedup/roll-up are order-independent aside from
    follow_up's documented first-occurrence-wins dedup).
    """
    statuses = [
        s.get("status") for s in summaries if isinstance(s.get("status"), str)
    ]

    return {
        "schema_version": SESSION_SCHEMA_VERSION,
        "totals": _merge_totals(summaries),
        "root_cause_clusters": _merge_clusters(summaries),
        "follow_up": _merge_follow_up(summaries),
        "runs": statuses,
        "run_count": len(statuses),
        "worst_status": _worst_status(statuses),
    }
