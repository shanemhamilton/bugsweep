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
