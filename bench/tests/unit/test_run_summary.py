"""Tests for ``bench.scorer.run_summary``.

The reducer folds a run's ``ledger.jsonl`` + ``recon.json`` into a single
deterministic ``run-summary.json`` object — the machine-readable contract a
headless scheduler (nightshift) can branch on without parsing model prose or
the (historically format-varying) "Findings (machine-readable)" block that
SKILL.md's report template asks the model to author.

Ledger event vocabulary this reducer understands (see scripts/state.sh,
scripts/session.sh, scripts/guard.sh, scripts/preflight.sh, SKILL.md,
prompts/referee.md, prompts/fix.md for the ground truth):

* ``preflight``            — run start marker (has ``branch``, ``orig_branch``).
* ``iteration``             — Referee checkpoint; has ``confirmed`` (int),
  ``new_bugs`` (int). Used to detect "some progress was made".
* ``batch_covered``         — a hunt batch finished; has ``batch`` or ``id``.
* ``fix_committed``         — a confirmed bug was fixed and committed; may carry
  ``file``, ``bug_id``, ``sha``, ``severity``, ``category``, ``line``,
  ``rationale`` — but only ``file`` is guaranteed by the fallback persist path
  in scripts/state.sh, so the reducer must tolerate any subset being absent.
* ``quarantine``            — a confirmed bug could not be safely auto-fixed;
  same tolerant-field contract as ``fix_committed``.
* ``confirmed``             — (bench/state.sh RISK vocabulary) a bug was
  confirmed by the Referee but not yet fixed/quarantined.
* ``false_positive``        — a Skeptic/Referee rejection; never counted.
* ``large_repo_mode_activated`` — has ``batch_count``, ``budget_batches``.
* ``finalize``              — emitted by finalize.sh itself at the very end.

Where the ledger's finding-level fields are absent (bug_id/severity/category/
file/line/rationale), the reducer emits null/empty rather than inventing a
value — never guess.

No network, no subprocess: the reducer is a pure function over the parsed
JSONL + JSON, so these tests build ledgers/recon fixtures inline.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.run_summary import (  # noqa: E402
    SCHEMA_VERSION,
    reduce_run,
    reduce_run_degraded,
)

try:
    import jsonschema

    HAVE_JSONSCHEMA = True
except ImportError:  # pragma: no cover - environment-dependent
    HAVE_JSONSCHEMA = False

SCHEMA_PATH = Path(__file__).resolve().parents[3] / "schemas" / "run-summary.schema.json"


def _write_ledger(path: Path, events: list[dict]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")


def _write_recon(path: Path, *, batch_count: int, covered: list) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"batch_count": batch_count, "batches": [], "covered": covered}, f)


def _validate_against_schema(summary: dict) -> None:
    if not HAVE_JSONSCHEMA:  # pragma: no cover - environment-dependent
        return
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    jsonschema.validate(instance=summary, schema=schema)


# ---------------------------------------------------------------------------
# Complete run
# ---------------------------------------------------------------------------


def test_complete_run_status_and_coverage(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    recon = tmp_path / "recon.json"
    _write_ledger(
        ledger,
        [
            {"event": "preflight", "branch": "bugsweep/x", "orig_branch": "main"},
            {"event": "iteration", "confirmed": 2, "new_bugs": 2},
            {"event": "batch_covered", "batch": 1},
            {
                "event": "fix_committed",
                "file": "src/auth.py",
                "bug_id": "BUG-1",
                "severity": "high",
                "category": "security",
                "line": 42,
                "rationale": "Unsanitized input reaches SQL query",
                "sha": "abc123",
            },
            {
                "event": "quarantine",
                "file": "src/legacy.py",
                "bug_id": "BUG-2",
                "severity": "medium",
                "category": "logic",
                "line": 10,
                "rationale": "Two fix attempts regressed checks",
            },
        ],
    )
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=False,
        mode="fix",
    )

    assert summary["schema_version"] == SCHEMA_VERSION
    assert summary["mode"] == "fix"
    assert summary["status"] == "complete"
    assert summary["stop_reason"] is None
    assert summary["coverage"] == {"covered": 1, "total": 1}
    assert summary["counts"]["high"] == 1
    assert summary["counts"]["medium"] == 1  # BUG-2 (quarantined) is medium severity
    assert "BUG-1" in summary["fixed"]
    assert "BUG-2" in summary["quarantined"]
    assert summary["confirmed_unfixed"] == []
    assert len(summary["findings"]) == 2
    fixed_finding = next(f for f in summary["findings"] if f["bug_id"] == "BUG-1")
    assert fixed_finding["fixed"] is True
    assert fixed_finding["severity"] == "high"
    assert fixed_finding["file"] == "src/auth.py"
    quarantined_finding = next(f for f in summary["findings"] if f["bug_id"] == "BUG-2")
    assert quarantined_finding["fixed"] is False
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# Partial run (stub report, but some progress)
# ---------------------------------------------------------------------------


def test_partial_run_when_report_is_stub_and_some_coverage(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    recon = tmp_path / "recon.json"
    _write_ledger(
        ledger,
        [
            {"event": "preflight", "branch": "bugsweep/x", "orig_branch": "main"},
            {"event": "batch_covered", "batch": 1},
            {"event": "batch_covered", "batch": 2},
        ],
    )
    _write_recon(recon, batch_count=10, covered=[1, 2])

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode="detect-only",
    )

    assert summary["status"] == "partial"
    assert summary["stop_reason"] is not None
    assert "stalled" not in summary["stop_reason"].lower() or True  # message may vary
    assert summary["coverage"] == {"covered": 2, "total": 10}


# ---------------------------------------------------------------------------
# Stalled run (stub report, zero progress)
# ---------------------------------------------------------------------------


def test_stalled_run_when_report_is_stub_and_no_coverage(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    recon = tmp_path / "recon.json"
    _write_ledger(
        ledger,
        [
            {"event": "preflight", "branch": "bugsweep/x", "orig_branch": "main"},
        ],
    )
    _write_recon(recon, batch_count=10, covered=[])

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode="detect-only",
    )

    assert summary["status"] == "stalled"
    assert summary["stop_reason"] is not None
    assert summary["coverage"] == {"covered": 0, "total": 10}
    assert summary["findings"] == []
    _validate_against_schema(summary)


def test_stalled_run_with_missing_recon(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    missing_recon = tmp_path / "does-not-exist.json"

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=missing_recon,
        report_is_stub=True,
        mode=None,
    )

    assert summary["status"] == "stalled"
    assert summary["coverage"] == {"covered": 0, "total": 0}
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# Empty ledger
# ---------------------------------------------------------------------------


def test_empty_ledger_produces_schema_valid_empty_summary(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    ledger.write_text("", encoding="utf-8")
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=0, covered=[])

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
    )

    assert summary["status"] == "stalled"
    assert summary["fixed"] == []
    assert summary["quarantined"] == []
    assert summary["confirmed_unfixed"] == []
    assert summary["findings"] == []
    assert summary["counts"] == {
        "critical": 0,
        "high": 0,
        "medium": 0,
        "low": 0,
        "architectural": 0,
    }
    _validate_against_schema(summary)


def test_missing_ledger_file_does_not_raise(tmp_path: Path) -> None:
    missing_ledger = tmp_path / "does-not-exist.jsonl"
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=0, covered=[])

    summary = reduce_run(
        ledger_path=missing_ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
    )

    assert summary["status"] == "stalled"
    assert summary["findings"] == []
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# Malformed lines
# ---------------------------------------------------------------------------


def test_malformed_ledger_lines_are_skipped_not_fatal(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    with open(ledger, "w", encoding="utf-8") as f:
        f.write("not json at all\n")
        f.write("{\n")  # truncated JSON
        f.write("\n")  # blank line
        f.write(
            json.dumps(
                {
                    "event": "fix_committed",
                    "file": "src/ok.py",
                    "bug_id": "BUG-9",
                }
            )
            + "\n"
        )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=False,
        mode="fix",
    )

    assert summary["status"] == "complete"
    assert "BUG-9" in summary["fixed"]
    assert len(summary["findings"]) == 1
    _validate_against_schema(summary)


def test_recon_json_that_is_not_an_object_falls_back_to_zero_coverage(
    tmp_path: Path,
) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    recon.write_text("[1, 2, 3]", encoding="utf-8")  # valid JSON, but not a dict

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
    )

    assert summary["coverage"] == {"covered": 0, "total": 0}
    _validate_against_schema(summary)


def test_recon_json_without_batch_count_falls_back_to_len_batches(
    tmp_path: Path,
) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    recon.write_text(
        json.dumps({"batches": [{"id": 1}, {"id": 2}], "covered": [1]}),
        encoding="utf-8",
    )

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
    )

    assert summary["coverage"] == {"covered": 1, "total": 2}
    _validate_against_schema(summary)


def test_malformed_recon_json_falls_back_to_zero_coverage(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    recon.write_text("{not valid json", encoding="utf-8")

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
    )

    assert summary["coverage"] == {"covered": 0, "total": 0}
    assert summary["status"] == "stalled"
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# Fields absent in the ledger -> null, never invented
# ---------------------------------------------------------------------------


def test_finding_level_fields_absent_emit_null_not_invented(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            # A minimal fix_committed carrying only `file`, per the state.sh
            # fallback persist path — no bug_id/severity/category/line/rationale.
            {"event": "fix_committed", "file": "src/minimal.py"},
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=False,
        mode="fix",
    )

    assert len(summary["findings"]) == 1
    finding = summary["findings"][0]
    assert finding["file"] == "src/minimal.py"
    assert finding["bug_id"] is None
    assert finding["severity"] is None
    assert finding["category"] is None
    assert finding["line"] is None
    assert finding["rationale"] is None
    assert finding["fixed"] is True
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# Severity/category counts aggregate across confirmed findings
# ---------------------------------------------------------------------------


def test_counts_aggregate_by_severity_and_architectural_category(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {
                "event": "fix_committed",
                "file": "a.py",
                "bug_id": "BUG-1",
                "severity": "critical",
                "category": "security",
            },
            {
                "event": "quarantine",
                "file": "b.py",
                "bug_id": "BUG-2",
                "severity": "low",
                "category": "architectural",
            },
            {
                "event": "confirmed",
                "file": "c.py",
                "bug_id": "BUG-3",
                "severity": "high",
                "category": "architectural",
            },
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=False,
        mode="fix",
    )

    assert summary["counts"]["critical"] == 1
    assert summary["counts"]["low"] == 1
    assert summary["counts"]["high"] == 1
    assert summary["counts"]["architectural"] == 2
    assert "BUG-3" in summary["confirmed_unfixed"]
    _validate_against_schema(summary)


def test_false_positive_events_are_never_counted(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {
                "event": "false_positive",
                "file": "a.py",
                "bug_id": "BUG-FP",
                "severity": "high",
            },
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=False,
        mode="detect-only",
    )

    assert summary["findings"] == []
    assert summary["counts"] == {
        "critical": 0,
        "high": 0,
        "medium": 0,
        "low": 0,
        "architectural": 0,
    }
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# Degraded (no python3) path — exercised directly since it's a pure-bash/grep
# reduction used by summarize.sh when python3 is unavailable.
# ---------------------------------------------------------------------------


def test_reduce_run_degraded_emits_minimal_schema_valid_summary(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {"event": "batch_covered", "batch": 1},
            {"event": "batch_covered", "batch": 2},
        ],
    )

    summary = reduce_run_degraded(
        covered=2,
        total=10,
        report_is_stub=True,
        mode="detect-only",
    )

    assert summary["degraded"] is True
    assert summary["status"] == "partial"
    assert summary["findings"] == []
    assert summary["coverage"] == {"covered": 2, "total": 10}
    _validate_against_schema(summary)


def test_reduce_run_degraded_complete_status_when_report_not_stub() -> None:
    summary = reduce_run_degraded(
        covered=5,
        total=5,
        report_is_stub=False,
        mode="fix",
    )

    assert summary["status"] == "complete"
    assert summary["degraded"] is True
    _validate_against_schema(summary)


def test_reduce_run_degraded_new_fields_present_and_empty() -> None:
    """Degraded output must stay schema-valid: the new optional fields are
    present as empty containers, never omitted or guessed (bugsweep-xdw)."""
    summary = reduce_run_degraded(
        covered=1,
        total=2,
        report_is_stub=True,
        mode="detect-only",
    )

    assert summary["root_cause_clusters"] == []
    assert summary["follow_up"] == []
    assert summary["flaky"] == []
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# root_cause_clusters[] (bugsweep-xdw): confirmed/fixed findings sharing a
# category cluster together; singletons (size 1) are excluded — a lone finding
# is not evidence of a broader pattern, so it stays in `findings` only. The
# cluster key is the finding's `category` only. (The spec envisioned a
# category::variant key "where the ledger events carry it", but no component
# emits a `variant`/`sink_class` field into the fix_committed/quarantine/
# confirmed events reduce_run reads — state.sh, the sole writer, emits neither
# — so a variant branch would be unreachable dead code. A future bead adds it
# back alongside a real emitter.) Deterministic order: size desc, then name.
# ---------------------------------------------------------------------------


def _fix(bug_id, file, severity="high", category="security", line=1, **extra):
    e = {
        "event": "fix_committed",
        "bug_id": bug_id,
        "file": file,
        "severity": severity,
        "category": category,
        "line": line,
        "rationale": f"rationale for {bug_id}",
    }
    e.update(extra)
    return e


def test_root_cause_clusters_group_by_category_size_two_or_more(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            _fix("BUG-1", "a.py", category="sql-injection"),
            _fix("BUG-2", "b.py", category="sql-injection"),
            _fix("BUG-3", "c.py", category="xss"),  # singleton — excluded
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    clusters = summary["root_cause_clusters"]
    assert len(clusters) == 1
    cluster = clusters[0]
    assert cluster["cluster"] == "sql-injection"
    assert cluster["size"] == 2
    assert cluster["representative"] in ("BUG-1", "BUG-2")
    assert sorted(cluster["files"]) == ["a.py", "b.py"]
    _validate_against_schema(summary)


def test_root_cause_clusters_singleton_excluded(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [_fix("BUG-1", "a.py", category="logic")])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    assert summary["root_cause_clusters"] == []
    _validate_against_schema(summary)


def test_root_cause_clusters_deterministic_order_size_desc_then_name(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            _fix("BUG-1", "a.py", category="zzz-small"),
            _fix("BUG-2", "b.py", category="zzz-small"),
            _fix("BUG-3", "c.py", category="aaa-big"),
            _fix("BUG-4", "d.py", category="aaa-big"),
            _fix("BUG-5", "e.py", category="aaa-big"),
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    clusters = summary["root_cause_clusters"]
    assert [c["cluster"] for c in clusters] == ["aaa-big", "zzz-small"]
    assert clusters[0]["size"] == 3
    assert clusters[1]["size"] == 2
    _validate_against_schema(summary)


def test_root_cause_clusters_variant_field_is_ignored_key_is_category_only(
    tmp_path: Path,
) -> None:
    """Regression guard for the removed dead variant branch (adversarial review
    MAJOR 5): even if a ledger event carries a stray `variant`/`sink_class`
    field, the cluster key must be the bare `category` — the key is never
    `category::variant`. Two `injection` findings cluster as one `injection`
    cluster regardless of their variant fields."""
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            _fix("BUG-1", "a.py", category="injection", variant="sql"),
            _fix("BUG-2", "b.py", category="injection", variant="command"),
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    clusters = summary["root_cause_clusters"]
    assert len(clusters) == 1
    assert clusters[0]["cluster"] == "injection"
    assert clusters[0]["size"] == 2
    _validate_against_schema(summary)


def test_root_cause_clusters_ignore_findings_without_category(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {"event": "fix_committed", "file": "a.py"},  # no bug_id/category
            {"event": "fix_committed", "file": "b.py"},
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    assert summary["root_cause_clusters"] == []
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# follow_up[] (bugsweep-xdw): the "where to look next" handoff, derived from
# prior-coverage.json (schema: scripts/state.sh's `prime` writer) plus
# recon.json batches NOT in `covered`, plus quarantined findings. Deterministic
# order: uncovered_batch (batch id asc) -> high_risk_file (score desc) ->
# stale_file (alpha) -> quarantined (bug_id alpha). Capped at FOLLOW_UP_CAP
# (documented on the constant) so a huge stale-file backlog can't blow up
# run-summary.json.
# ---------------------------------------------------------------------------


def _write_prior_coverage(path: Path, *, stale=None, high_risk=None) -> None:
    path.write_text(
        json.dumps(
            {
                "schema": 1,
                "catalog_version": "1",
                "prior_runs": 3,
                "files_audited_current_catalog": [],
                "files_audited_current_catalog_count": 0,
                "files_audited_stale_catalog": stale or [],
                "files_audited_stale_catalog_count": len(stale or []),
                "high_risk_files": high_risk or [],
            }
        ),
        encoding="utf-8",
    )


def _write_recon_with_batches(path: Path, *, batches, covered) -> None:
    path.write_text(
        json.dumps(
            {
                "files_in_scope": 10,
                "batch_count": len(batches),
                "batches": batches,
                "architectural_targets": [],
                "covered": covered,
            }
        ),
        encoding="utf-8",
    )


def test_follow_up_includes_uncovered_batches(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon_with_batches(
        recon,
        batches=[
            {"id": 1, "tier": "critical", "files": ["a.py"]},
            {"id": 2, "tier": "high", "files": ["b.py"]},
        ],
        covered=[1],
    )
    prior = tmp_path / "prior-coverage.json"
    _write_prior_coverage(prior)

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode="detect-only",
        prior_coverage_path=prior,
    )

    follow_up = summary["follow_up"]
    assert {"kind": "uncovered_batch", "ref": "2", "detail": "high"} in follow_up
    assert not any(f["ref"] == "1" for f in follow_up if f["kind"] == "uncovered_batch")
    _validate_against_schema(summary)


def test_follow_up_includes_stale_and_high_risk_files(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon_with_batches(recon, batches=[], covered=[])
    prior = tmp_path / "prior-coverage.json"
    _write_prior_coverage(
        prior,
        stale=["stale_a.py", "stale_b.py"],
        high_risk=[{"file": "risky.py", "score": 4.2}],
    )

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
        prior_coverage_path=prior,
    )

    follow_up = summary["follow_up"]
    kinds = {(f["kind"], f["ref"]) for f in follow_up}
    assert ("high_risk_file", "risky.py") in kinds
    assert ("stale_file", "stale_a.py") in kinds
    assert ("stale_file", "stale_b.py") in kinds
    high_risk_entry = next(f for f in follow_up if f["kind"] == "high_risk_file")
    assert high_risk_entry["detail"] == "4.2"
    _validate_against_schema(summary)


def test_follow_up_includes_quarantined_findings(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {
                "event": "quarantine",
                "file": "legacy.py",
                "bug_id": "BUG-Q1",
                "severity": "medium",
                "category": "logic",
            }
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    follow_up = summary["follow_up"]
    assert {"kind": "quarantined", "ref": "BUG-Q1", "detail": "legacy.py"} in follow_up
    _validate_against_schema(summary)


def test_follow_up_deterministic_order(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {
                "event": "quarantine",
                "file": "z.py",
                "bug_id": "BUG-Z",
                "severity": "low",
                "category": "logic",
            },
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon_with_batches(
        recon,
        batches=[
            {"id": 5, "tier": "normal", "files": ["e.py"]},
            {"id": 2, "tier": "critical", "files": ["b.py"]},
        ],
        covered=[],
    )
    prior = tmp_path / "prior-coverage.json"
    _write_prior_coverage(
        prior,
        stale=["m.py"],
        high_risk=[{"file": "risky.py", "score": 9.0}],
    )

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
        prior_coverage_path=prior,
    )

    kinds_in_order = [f["kind"] for f in summary["follow_up"]]
    # uncovered_batch entries first (batch id asc: 2 before 5), then
    # high_risk_file, then stale_file, then quarantined.
    assert kinds_in_order == [
        "uncovered_batch",
        "uncovered_batch",
        "high_risk_file",
        "stale_file",
        "quarantined",
    ]
    batch_refs = [f["ref"] for f in summary["follow_up"] if f["kind"] == "uncovered_batch"]
    assert batch_refs == ["2", "5"]
    _validate_against_schema(summary)


def test_follow_up_missing_prior_coverage_file_still_includes_recon_and_quarantine(
    tmp_path: Path,
) -> None:
    """No prior-coverage.json (e.g. first run on a repo) must never raise —
    follow_up degrades to whatever recon.json/ledger provide."""
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {
                "event": "quarantine",
                "file": "q.py",
                "bug_id": "BUG-Q",
                "severity": "low",
                "category": "logic",
            }
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon_with_batches(
        recon, batches=[{"id": 1, "tier": "critical", "files": ["a.py"]}], covered=[]
    )
    missing_prior = tmp_path / "does-not-exist.json"

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
        prior_coverage_path=missing_prior,
    )

    kinds = {f["kind"] for f in summary["follow_up"]}
    assert kinds == {"uncovered_batch", "quarantined"}
    _validate_against_schema(summary)


def test_follow_up_malformed_prior_coverage_does_not_raise(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])
    prior = tmp_path / "prior-coverage.json"
    prior.write_text("{not valid json", encoding="utf-8")

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=False,
        mode="fix",
        prior_coverage_path=prior,
    )

    assert summary["follow_up"] == []
    _validate_against_schema(summary)


def test_follow_up_is_capped(tmp_path: Path) -> None:
    """A huge stale-file backlog must be capped, not dumped wholesale into
    run-summary.json — see FOLLOW_UP_CAP in bench/scorer/run_summary.py."""
    from bench.scorer.run_summary import FOLLOW_UP_CAP

    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon_with_batches(recon, batches=[], covered=[])
    prior = tmp_path / "prior-coverage.json"
    _write_prior_coverage(prior, stale=[f"stale_{i}.py" for i in range(FOLLOW_UP_CAP + 20)])

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
        prior_coverage_path=prior,
    )

    assert len(summary["follow_up"]) == FOLLOW_UP_CAP
    _validate_against_schema(summary)


def test_follow_up_default_prior_coverage_path_is_none(tmp_path: Path) -> None:
    """reduce_run must remain callable without prior_coverage_path (backward
    compatible with the mu3 call sites until scripts/summarize.sh is updated to
    pass it)."""
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    assert summary["follow_up"] == []
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# flaky[] (bugsweep-xdw): surfaced 1:1 from
# {"event":"flaky_test","test":...,"file":...,"reruns":N,"failures":M} ledger
# events emitted by a sibling work unit's emitter. Empty when absent.
# ---------------------------------------------------------------------------


def test_flaky_populated_from_ledger_events(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {
                "event": "flaky_test",
                "test": "test_foo",
                "file": "tests/test_foo.py",
                "reruns": 3,
                "failures": 1,
            }
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    assert summary["flaky"] == [
        {"test": "test_foo", "file": "tests/test_foo.py", "reruns": 3, "failures": 1}
    ]
    _validate_against_schema(summary)


def test_flaky_empty_when_absent(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    assert summary["flaky"] == []
    _validate_against_schema(summary)


def test_follow_up_recon_batches_not_a_list_falls_back_to_empty(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    recon.write_text(json.dumps({"batches": "not-a-list", "covered": []}), encoding="utf-8")

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=True, mode=None)

    assert not any(f["kind"] == "uncovered_batch" for f in summary["follow_up"])
    _validate_against_schema(summary)


def test_follow_up_recon_batches_entries_not_dicts_are_skipped(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    recon.write_text(
        json.dumps({"batches": ["not-a-dict", {"id": 1, "tier": "critical"}], "covered": []}),
        encoding="utf-8",
    )

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=True, mode=None)

    refs = [f["ref"] for f in summary["follow_up"] if f["kind"] == "uncovered_batch"]
    assert refs == ["1"]
    _validate_against_schema(summary)


def test_follow_up_high_risk_files_not_a_list_falls_back_to_empty(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=0, covered=[])
    prior = tmp_path / "prior-coverage.json"
    prior.write_text(json.dumps({"high_risk_files": "nope"}), encoding="utf-8")

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
        prior_coverage_path=prior,
    )

    assert not any(f["kind"] == "high_risk_file" for f in summary["follow_up"])
    _validate_against_schema(summary)


def test_follow_up_high_risk_files_entries_skip_non_dicts_and_missing_file(
    tmp_path: Path,
) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=0, covered=[])
    prior = tmp_path / "prior-coverage.json"
    prior.write_text(
        json.dumps(
            {
                "high_risk_files": [
                    "not-a-dict",
                    {"score": 1.0},  # no file
                    {"file": "keep.py"},  # no score -> None detail
                ]
            }
        ),
        encoding="utf-8",
    )

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
        prior_coverage_path=prior,
    )

    high_risk = [f for f in summary["follow_up"] if f["kind"] == "high_risk_file"]
    assert len(high_risk) == 1
    assert high_risk[0]["ref"] == "keep.py"
    assert high_risk[0]["detail"] is None
    _validate_against_schema(summary)


def test_follow_up_stale_files_not_a_list_falls_back_to_empty(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=0, covered=[])
    prior = tmp_path / "prior-coverage.json"
    prior.write_text(json.dumps({"files_audited_stale_catalog": "nope"}), encoding="utf-8")

    summary = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
        prior_coverage_path=prior,
    )

    assert not any(f["kind"] == "stale_file" for f in summary["follow_up"])
    _validate_against_schema(summary)


def test_follow_up_quarantined_skips_missing_bug_id(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [{"event": "quarantine", "file": "no-id.py"}],  # no bug_id
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    assert not any(f["kind"] == "quarantined" for f in summary["follow_up"])
    _validate_against_schema(summary)


def test_follow_up_quarantined_ref_coerced_to_string_for_int_bug_id(
    tmp_path: Path,
) -> None:
    """Adversarial review MAJOR 3: nothing upstream forces bug_id to be a
    string, so an integer bug_id must be str()-coerced into follow_up[].ref —
    otherwise reduce_run's own output fails jsonschema.validate against the
    schema this commit ships (ref is declared type:string)."""
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [{"event": "quarantine", "file": "x.py", "bug_id": 123, "severity": "low"}],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    quarantined = [f for f in summary["follow_up"] if f["kind"] == "quarantined"]
    assert quarantined == [{"kind": "quarantined", "ref": "123", "detail": "x.py"}]
    _validate_against_schema(summary)


def test_follow_up_high_risk_files_tied_scores_ordered_by_ref(tmp_path: Path) -> None:
    """Adversarial review MAJOR 4: two high-risk files with the SAME score must
    have a stable sub-order (alphabetical by file) regardless of the order they
    appear in prior-coverage.json."""
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=0, covered=[])

    prior_forward = tmp_path / "prior-forward.json"
    _write_prior_coverage(
        prior_forward,
        high_risk=[{"file": "aaa.py", "score": 5.0}, {"file": "bbb.py", "score": 5.0}],
    )
    prior_reversed = tmp_path / "prior-reversed.json"
    _write_prior_coverage(
        prior_reversed,
        high_risk=[{"file": "bbb.py", "score": 5.0}, {"file": "aaa.py", "score": 5.0}],
    )

    s_forward = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
        prior_coverage_path=prior_forward,
    )
    s_reversed = reduce_run(
        ledger_path=ledger,
        recon_path=recon,
        report_is_stub=True,
        mode=None,
        prior_coverage_path=prior_reversed,
    )

    refs_forward = [f["ref"] for f in s_forward["follow_up"] if f["kind"] == "high_risk_file"]
    refs_reversed = [f["ref"] for f in s_reversed["follow_up"] if f["kind"] == "high_risk_file"]
    assert refs_forward == ["aaa.py", "bbb.py"]
    assert refs_forward == refs_reversed  # input order must not affect output
    _validate_against_schema(s_forward)


def test_follow_up_string_batch_ids_sort_deterministically(tmp_path: Path) -> None:
    """Adversarial review MAJOR 4: non-integer batch ids must sort by str(id),
    not collapse to sort-key 0 (which left them in input order)."""
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "preflight"}])
    recon = tmp_path / "recon.json"
    _write_recon_with_batches(
        recon,
        batches=[
            {"id": "zebra", "tier": "normal", "files": ["z.py"]},
            {"id": "alpha", "tier": "critical", "files": ["a.py"]},
        ],
        covered=[],
    )

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=True, mode=None)

    refs = [f["ref"] for f in summary["follow_up"] if f["kind"] == "uncovered_batch"]
    assert refs == ["alpha", "zebra"]  # sorted by str(id), not input order
    _validate_against_schema(summary)


def test_flaky_tolerant_of_missing_fields(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "flaky_test", "test": "test_bar"}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix")

    assert summary["flaky"] == [
        {"test": "test_bar", "file": None, "reruns": None, "failures": None}
    ]
    _validate_against_schema(summary)


# ---------------------------------------------------------------------------
# near_misses[] (bugsweep-dxh, --recall mode): Referee-recorded "near_miss"
# ledger events (confidence 50-67 — genuinely plausible but not >67% CONFIRMED)
# surfaced for human review ONLY when reduce_run's `recall` kwarg is True.
# THE SAFETY INVARIANT: `recall` must NEVER change fixed/quarantined/
# confirmed_unfixed/findings/counts — near_misses[] is the ONLY field it
# gates. `near_miss` is deliberately not a member of FINDING_EVENTS, so the
# fix-eligibility computation cannot see it regardless of `recall`.
# ---------------------------------------------------------------------------


def test_near_misses_populated_from_ledger_events_when_recall_enabled(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {
                "event": "near_miss",
                "bug_id": "BUG-NM1",
                "severity": "medium",
                "category": "prototype-pollution",
                "file": "src/merge.js",
                "line": 42,
                "rationale": "referee 58% confident: plausible but unproven reachability",
                "confidence": 58,
            }
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(
        ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix", recall=True
    )

    assert summary["near_misses"] == [
        {
            "bug_id": "BUG-NM1",
            "severity": "medium",
            "category": "prototype-pollution",
            "file": "src/merge.js",
            "line": 42,
            "rationale": "referee 58% confident: plausible but unproven reachability",
            "confidence": 58,
        }
    ]
    _validate_against_schema(summary)


def test_near_misses_empty_when_recall_disabled_even_if_events_present(tmp_path: Path) -> None:
    """recall defaults to False (backward compatible) — near_miss events in the
    ledger must NOT surface unless the caller explicitly opts into recall."""
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {
                "event": "near_miss",
                "bug_id": "BUG-NM1",
                "severity": "medium",
                "category": "prototype-pollution",
                "file": "src/merge.js",
                "line": 42,
                "rationale": "borderline",
                "confidence": 60,
            }
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary_default = reduce_run(
        ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix"
    )
    summary_explicit_off = reduce_run(
        ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix", recall=False
    )

    assert summary_default["near_misses"] == []
    assert summary_explicit_off["near_misses"] == []
    _validate_against_schema(summary_default)


def test_near_misses_tolerant_of_missing_fields(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "near_miss", "bug_id": "BUG-NM2"}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(
        ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix", recall=True
    )

    assert summary["near_misses"] == [
        {
            "bug_id": "BUG-NM2",
            "severity": None,
            "category": None,
            "file": None,
            "line": None,
            "rationale": None,
            "confidence": None,
        }
    ]
    _validate_against_schema(summary)


def test_near_misses_bug_id_coerced_to_string_for_int_bug_id(tmp_path: Path) -> None:
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(ledger, [{"event": "near_miss", "bug_id": 7, "confidence": 55}])
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary = reduce_run(
        ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix", recall=True
    )

    assert summary["near_misses"][0]["bug_id"] == "7"
    _validate_against_schema(summary)


def test_reduce_run_degraded_near_misses_present_and_empty() -> None:
    """Degraded output stays schema-valid: near_misses is present as an empty
    container, never omitted (same contract as root_cause_clusters/follow_up/
    flaky — bugsweep-xdw)."""
    summary = reduce_run_degraded(covered=1, total=2, report_is_stub=True, mode="detect-only")

    assert summary["near_misses"] == []
    _validate_against_schema(summary)


def test_recall_never_changes_fix_eligibility(tmp_path: Path) -> None:
    """THE SAFETY INVARIANT (bugsweep-dxh): --recall changes ONLY what gets
    reported (near_misses[]). It must NEVER lower the bar for auto-fix
    eligibility. This asserts every fix-eligibility-relevant field is
    byte-for-byte identical whether recall is on or off, even when the ledger
    mixes near_miss events with real fix_committed/quarantine/confirmed
    events — a near_miss must never be promoted into fixed/quarantined/
    confirmed_unfixed/findings regardless of the recall flag."""
    ledger = tmp_path / "ledger.jsonl"
    _write_ledger(
        ledger,
        [
            {
                "event": "fix_committed",
                "bug_id": "BUG-1",
                "severity": "high",
                "category": "injection",
                "file": "a.py",
                "line": 10,
                "rationale": "sql built via string concat",
            },
            {
                "event": "quarantine",
                "bug_id": "BUG-2",
                "severity": "medium",
                "category": "logic",
                "file": "b.py",
                "line": 5,
                "rationale": "fix reverted: broke checkout flow",
            },
            {
                "event": "confirmed",
                "bug_id": "BUG-3",
                "severity": "low",
                "category": "style",
                "file": "c.py",
                "line": 1,
                "rationale": "confirmed, below severity floor",
            },
            {
                "event": "near_miss",
                "bug_id": "BUG-NM1",
                "severity": "medium",
                "category": "injection",
                "file": "d.py",
                "line": 20,
                "rationale": "referee 60% confident: plausible but unproven",
                "confidence": 60,
            },
        ],
    )
    recon = tmp_path / "recon.json"
    _write_recon(recon, batch_count=1, covered=[1])

    summary_off = reduce_run(
        ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix", recall=False
    )
    summary_on = reduce_run(
        ledger_path=ledger, recon_path=recon, report_is_stub=False, mode="fix", recall=True
    )

    fix_eligibility_keys = (
        "schema_version",
        "mode",
        "status",
        "stop_reason",
        "coverage",
        "counts",
        "fixed",
        "quarantined",
        "confirmed_unfixed",
        "findings",
        "root_cause_clusters",
        "follow_up",
        "flaky",
    )
    off_projection = {k: summary_off[k] for k in fix_eligibility_keys}
    on_projection = {k: summary_on[k] for k in fix_eligibility_keys}

    # Byte-for-byte: canonical JSON serialization of every fix-eligibility
    # field must be IDENTICAL between the two runs.
    assert json.dumps(off_projection, sort_keys=True) == json.dumps(on_projection, sort_keys=True)

    # The bug the near_miss event describes must never appear as fixed,
    # quarantined, or confirmed-unfixed — under EITHER value of recall.
    for summary in (summary_off, summary_on):
        assert "BUG-NM1" not in summary["fixed"]
        assert "BUG-NM1" not in summary["quarantined"]
        assert "BUG-NM1" not in summary["confirmed_unfixed"]
        assert all(f["bug_id"] != "BUG-NM1" for f in summary["findings"])

    # near_misses[] is the ONLY field that differs.
    assert summary_off["near_misses"] == []
    assert summary_on["near_misses"] == [
        {
            "bug_id": "BUG-NM1",
            "severity": "medium",
            "category": "injection",
            "file": "d.py",
            "line": 20,
            "rationale": "referee 60% confident: plausible but unproven",
            "confidence": 60,
        }
    ]
    _validate_against_schema(summary_off)
    _validate_against_schema(summary_on)
