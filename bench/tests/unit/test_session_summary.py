"""Tests for ``bench.scorer.session_summary`` (bugsweep-xdw).

The session aggregator merges N per-run ``run-summary.json`` objects (as
produced by ``bench.scorer.run_summary.reduce_run``) into one session-level
view: totals per severity, a cross-run re-clustering of ``root_cause_clusters``
(summed sizes, keyed by cluster name), a deduped ``follow_up`` list (dedup key:
``(kind, ref)``), a per-run status list, and a worst-status roll-up.

Pure function, no I/O — these tests build run-summary dicts inline (the shape
mirrors ``reduce_run``'s output, but the aggregator only reads documented
keys, so a minimal hand-built dict is sufficient and keeps this suite
decoupled from run_summary's exact field set).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.session_summary import (  # noqa: E402
    SESSION_SCHEMA_VERSION,
    merge_summaries,
)

try:
    import jsonschema

    HAVE_JSONSCHEMA = True
except ImportError:  # pragma: no cover - environment-dependent
    HAVE_JSONSCHEMA = False

SCHEMA_PATH = (
    Path(__file__).resolve().parents[3] / "schemas" / "session-summary.schema.json"
)


def _validate_against_schema(session: dict) -> None:
    if not HAVE_JSONSCHEMA:  # pragma: no cover - environment-dependent
        return
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    jsonschema.validate(instance=session, schema=schema)


def _summary(
    *,
    status="complete",
    counts=None,
    clusters=None,
    follow_up=None,
    findings=None,
    run_id="run-1",
) -> dict:
    return {
        "schema_version": 1,
        "mode": "fix",
        "status": status,
        "stop_reason": None,
        "coverage": {"covered": 1, "total": 1},
        "counts": counts or {"critical": 0, "high": 0, "medium": 0, "low": 0, "architectural": 0},
        "fixed": [],
        "quarantined": [],
        "confirmed_unfixed": [],
        "findings": findings or [],
        "root_cause_clusters": clusters or [],
        "follow_up": follow_up or [],
        "flaky": [],
        "_run_id": run_id,  # test-only marker; aggregator must ignore unknown keys
    }


def _finding(bug_id, category, file, *, fixed=True):
    return {
        "bug_id": bug_id,
        "severity": "high",
        "category": category,
        "file": file,
        "line": 1,
        "fixed": fixed,
        "rationale": f"rationale for {bug_id}",
    }


# ---------------------------------------------------------------------------
# Totals per severity
# ---------------------------------------------------------------------------


def test_merge_totals_per_severity_sum_across_runs(tmp_path: Path) -> None:
    a = _summary(counts={"critical": 1, "high": 2, "medium": 0, "low": 0, "architectural": 0})
    b = _summary(counts={"critical": 0, "high": 1, "medium": 3, "low": 1, "architectural": 2})

    session = merge_summaries([a, b])

    assert session["schema_version"] == SESSION_SCHEMA_VERSION
    assert session["totals"] == {
        "critical": 1,
        "high": 3,
        "medium": 3,
        "low": 1,
        "architectural": 2,
    }
    _validate_against_schema(session)


def test_merge_empty_list_is_distinguishable_from_all_complete() -> None:
    """Adversarial review BLOCKER 1: a zero-run aggregate (a scheduler globbed
    and matched nothing — every run crashed pre-finalize, or a path misconfig)
    must NOT read as a clean success. run_count == 0 and worst_status is the
    non-success sentinel 'no_runs', so a scheduler can tell 'vacuously fine, 0
    runs' apart from 'N runs, all complete'."""
    session = merge_summaries([])

    assert session["totals"] == {
        "critical": 0,
        "high": 0,
        "medium": 0,
        "low": 0,
        "architectural": 0,
    }
    assert session["runs"] == []
    assert session["run_count"] == 0
    assert session["worst_status"] == "no_runs"
    assert session["worst_status"] != "complete"
    _validate_against_schema(session)


def test_merge_run_count_reflects_number_of_runs() -> None:
    session = merge_summaries([_summary(status="complete"), _summary(status="stalled")])

    assert session["run_count"] == 2
    _validate_against_schema(session)


# ---------------------------------------------------------------------------
# Cross-run cluster merge (adversarial review BLOCKER 2): clusters are
# re-derived from each run's findings[] and the size>=2 threshold is applied at
# the SESSION level — so two runs each confirming ONE same-category finding
# (2 total; the textbook "broader issue" signal) DO produce a session cluster,
# even though neither run's per-run root_cause_clusters[] contained it. Size is
# the count of contributing findings, files is their deduped union.
# ---------------------------------------------------------------------------


def test_merge_clusters_folds_in_findings_size_threshold_at_session_level() -> None:
    """The primary consumer (multi-run session): 2 runs × 1 same-category
    finding each => one session cluster of size 2."""
    a = _summary(findings=[_finding("X1", "xss", "a.py")])
    b = _summary(findings=[_finding("X2", "xss", "b.py")])

    session = merge_summaries([a, b])

    clusters = session["root_cause_clusters"]
    assert len(clusters) == 1
    assert clusters[0]["cluster"] == "xss"
    assert clusters[0]["size"] == 2
    assert sorted(clusters[0]["files"]) == ["a.py", "b.py"]
    _validate_against_schema(session)


def test_merge_clusters_session_singleton_excluded() -> None:
    """One same-category finding across the whole session is still a singleton
    at session level and is excluded."""
    a = _summary(findings=[_finding("X1", "xss", "a.py")])
    b = _summary(findings=[_finding("Y1", "logic", "b.py")])

    session = merge_summaries([a, b])

    assert session["root_cause_clusters"] == []
    _validate_against_schema(session)


def test_merge_clusters_across_runs_sums_size_and_unions_files() -> None:
    a = _summary(
        findings=[_finding("B1", "sql-injection", "a.py"), _finding("B2", "sql-injection", "b.py")]
    )
    b = _summary(
        findings=[_finding("B9", "sql-injection", "b.py"), _finding("B10", "sql-injection", "c.py")]
    )

    session = merge_summaries([a, b])

    clusters = session["root_cause_clusters"]
    assert len(clusters) == 1
    merged = clusters[0]
    assert merged["cluster"] == "sql-injection"
    assert merged["size"] == 4  # 2 findings per run
    assert sorted(merged["files"]) == ["a.py", "b.py", "c.py"]  # union, deduped
    _validate_against_schema(session)


def test_merge_clusters_distinct_names_stay_separate_ordered_by_size() -> None:
    a = _summary(findings=[_finding("S1", "small", "a.py"), _finding("S2", "small", "a2.py")])
    b = _summary(
        findings=[
            _finding("B1", "big", "b.py"),
            _finding("B2", "big", "b2.py"),
            _finding("B3", "big", "b3.py"),
            _finding("B4", "big", "b4.py"),
        ]
    )

    session = merge_summaries([a, b])

    assert [c["cluster"] for c in session["root_cause_clusters"]] == ["big", "small"]
    _validate_against_schema(session)


def test_merge_clusters_ignores_findings_without_category() -> None:
    a = _summary(findings=[{"bug_id": "N1", "file": "a.py", "fixed": True}])
    b = _summary(findings=[{"bug_id": "N2", "file": "b.py", "fixed": True}])

    session = merge_summaries([a, b])

    assert session["root_cause_clusters"] == []
    _validate_against_schema(session)


def test_merge_clusters_representative_is_input_order_invariant() -> None:
    """MINOR: merge_summaries must be invariant to caller-supplied summary
    order — a caller that globs unsorted must get a reproducible
    representative. Shuffled input => byte-identical output."""
    import json as _json

    a = _summary(findings=[_finding("AAA", "xss", "a.py")], run_id="run-a")
    b = _summary(findings=[_finding("BBB", "xss", "b.py")], run_id="run-b")

    forward = merge_summaries([a, b])
    reversed_ = merge_summaries([b, a])

    assert _json.dumps(forward, sort_keys=True) == _json.dumps(reversed_, sort_keys=True)
    # And specifically the representative is deterministic (lowest bug_id).
    assert forward["root_cause_clusters"][0]["representative"] == "AAA"
    _validate_against_schema(forward)


# ---------------------------------------------------------------------------
# follow_up dedup by (kind, ref)
# ---------------------------------------------------------------------------


def test_merge_follow_up_dedup_by_kind_and_ref() -> None:
    a = _summary(
        follow_up=[
            {"kind": "stale_file", "ref": "x.py", "detail": None},
            {"kind": "uncovered_batch", "ref": "3", "detail": "high"},
        ]
    )
    b = _summary(
        follow_up=[
            {"kind": "stale_file", "ref": "x.py", "detail": None},  # dup
            {"kind": "high_risk_file", "ref": "risky.py", "detail": "9.0"},
        ]
    )

    session = merge_summaries([a, b])

    pairs = [(f["kind"], f["ref"]) for f in session["follow_up"]]
    assert len(pairs) == len(set(pairs))  # no duplicate (kind, ref)
    assert ("stale_file", "x.py") in pairs
    assert ("uncovered_batch", "3") in pairs
    assert ("high_risk_file", "risky.py") in pairs
    assert len(session["follow_up"]) == 3
    _validate_against_schema(session)


# ---------------------------------------------------------------------------
# Per-run status list + worst-status roll-up
# ---------------------------------------------------------------------------


def test_merge_worst_status_any_stalled_rolls_up_to_partial() -> None:
    a = _summary(status="complete")
    b = _summary(status="stalled")

    session = merge_summaries([a, b])

    assert session["runs"] == ["complete", "stalled"]
    assert session["worst_status"] == "partial"
    _validate_against_schema(session)


def test_merge_worst_status_any_partial_rolls_up_to_partial() -> None:
    a = _summary(status="complete")
    b = _summary(status="partial")

    session = merge_summaries([a, b])

    assert session["worst_status"] == "partial"
    _validate_against_schema(session)


def test_merge_worst_status_all_complete_stays_complete() -> None:
    a = _summary(status="complete")
    b = _summary(status="complete")

    session = merge_summaries([a, b])

    assert session["worst_status"] == "complete"
    _validate_against_schema(session)


def test_merge_worst_status_single_stalled_run_is_stalled() -> None:
    """A lone stalled run (no other runs to soften it) rolls up to `stalled`
    itself, not `partial` — `partial` means "mixed outcomes across runs"."""
    a = _summary(status="stalled")

    session = merge_summaries([a])

    assert session["worst_status"] == "stalled"
    _validate_against_schema(session)


# ---------------------------------------------------------------------------
# Malformed/missing input tolerance — never raise.
# ---------------------------------------------------------------------------


def test_merge_tolerates_missing_optional_keys() -> None:
    minimal = {
        "schema_version": 1,
        "mode": None,
        "status": "complete",
        "stop_reason": None,
        "coverage": {"covered": 0, "total": 0},
        "counts": {"critical": 0, "high": 0, "medium": 0, "low": 0, "architectural": 0},
        "fixed": [],
        "quarantined": [],
        "confirmed_unfixed": [],
        "findings": [],
        # no root_cause_clusters / follow_up / flaky keys at all (older
        # run-summary.json predating bugsweep-xdw)
    }

    session = merge_summaries([minimal])

    assert session["root_cause_clusters"] == []
    assert session["follow_up"] == []
    assert session["runs"] == ["complete"]
    _validate_against_schema(session)


def test_merge_tolerates_malformed_counts_missing_severity_keys() -> None:
    bad = {
        "schema_version": 1,
        "status": "complete",
        "counts": {"critical": 2},  # missing high/medium/low/architectural
    }

    session = merge_summaries([bad])

    assert session["totals"]["critical"] == 2
    assert session["totals"]["high"] == 0
    _validate_against_schema(session)


def test_merge_tolerates_counts_not_a_dict() -> None:
    bad = {"schema_version": 1, "status": "complete", "counts": "nope"}

    session = merge_summaries([bad])

    assert session["totals"] == {
        "critical": 0,
        "high": 0,
        "medium": 0,
        "low": 0,
        "architectural": 0,
    }
    _validate_against_schema(session)


def test_merge_tolerates_findings_not_a_list() -> None:
    bad = {"schema_version": 1, "status": "complete", "findings": "nope"}

    session = merge_summaries([bad])

    assert session["root_cause_clusters"] == []
    _validate_against_schema(session)


def test_merge_tolerates_finding_entries_not_dicts_or_missing_category() -> None:
    bad = {
        "schema_version": 1,
        "status": "complete",
        "findings": [
            "not-a-dict",
            {"bug_id": "N1", "file": "a.py"},  # no category
            {"bug_id": "N2", "file": "b.py"},  # no category
        ],
    }

    session = merge_summaries([bad])

    assert session["root_cause_clusters"] == []
    _validate_against_schema(session)


def test_merge_follow_up_tolerates_not_a_list() -> None:
    bad = {"schema_version": 1, "status": "complete", "follow_up": "nope"}

    session = merge_summaries([bad])

    assert session["follow_up"] == []
    _validate_against_schema(session)


def test_merge_follow_up_tolerates_entries_not_dicts() -> None:
    bad = {"schema_version": 1, "status": "complete", "follow_up": ["not-a-dict"]}

    session = merge_summaries([bad])

    assert session["follow_up"] == []
    _validate_against_schema(session)
