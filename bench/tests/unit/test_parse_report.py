"""Tests for ``bench.scorer.parse_report``.

The scorer turns a bugsweep ``report.md`` (and the baseline arm's same-format
output) into a normalized list of ``Finding`` records by reading the structured
``·``-separated lines under the "Confirmed but not fixed" header. These tests
pin the parse contract and every documented edge case: a valid multi-finding
report, a missing section header, a malformed line that must be skipped (not
crash), an empty report, and the file:line token split.
"""

import sys
from pathlib import Path

# Make ``bench`` importable under a bare ``pytest`` invocation from the repo
# root: with the default ``prepend`` import mode and no ``__init__.py`` in the
# test dirs, pytest puts the test file's directory on ``sys.path`` instead of
# the repo root. The repo-root ``pyproject.toml`` (read-only here) lacks a
# ``pythonpath``/``importmode`` setting, so we inject the repo root ourselves.
# WU0 cleanup: add ``pythonpath = ["."]`` to ``[tool.pytest.ini_options]``.
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.parse_report import Finding, parse_report  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE = REPO_ROOT / "bench" / "tests" / "fixtures" / "report_detect_only.md"

SECTION = "## Confirmed but not fixed (detect-only or below severity floor)"


def test_parses_fixture_multi_finding() -> None:
    findings = parse_report(FIXTURE)
    assert len(findings) == 2
    assert all(isinstance(f, Finding) for f in findings)


def test_first_finding_fields() -> None:
    first = parse_report(FIXTURE)[0]
    assert first.bug_id == "BUG-001"
    assert first.severity == "critical"
    assert first.category == "sql-injection"
    assert first.file == "app/db/users.py"
    assert first.line == 88
    assert first.rationale == "user-controlled `email` interpolated into raw SQL"


def test_file_line_token_splits_into_file_and_int_line() -> None:
    second = parse_report(FIXTURE)[1]
    assert second.file == "app/files/download.py"
    assert second.line == 34
    assert isinstance(second.line, int)


def test_accepts_text_string_not_just_path() -> None:
    text = FIXTURE.read_text(encoding="utf-8")
    findings = parse_report(text)
    assert len(findings) == 2
    assert findings[0].bug_id == "BUG-001"


def test_accepts_path_passed_as_string() -> None:
    # A single-line argument that resolves to a real file is read as a path.
    findings = parse_report(str(FIXTURE))
    assert len(findings) == 2
    assert findings[0].bug_id == "BUG-001"


def test_accepts_pathlib_path_object() -> None:
    findings = parse_report(FIXTURE)
    assert findings[0].file == "app/db/users.py"


def test_wrong_field_count_line_is_skipped() -> None:
    # Has middots but only three fields → not the structured shape, skipped.
    text = f"{SECTION}\n- BUG-001 · critical · only-three-fields\n"
    assert parse_report(text) == []


def test_file_line_token_without_colon_is_skipped() -> None:
    text = f"{SECTION}\n- BUG-001 · critical · sql-injection · app/db/users.py · no colon\n"
    assert parse_report(text) == []


def test_missing_section_header_returns_empty() -> None:
    text = "# report\n\n## Summary\n- nothing structured here\n"
    assert parse_report(text) == []


def test_empty_report_returns_empty() -> None:
    assert parse_report("") == []


def test_malformed_line_is_skipped_not_crash() -> None:
    text = (
        f"{SECTION}\n"
        "- BUG-001 · critical · sql-injection · app/db/users.py:88 · ok line\n"
        "- this line has no middots and should be skipped\n"
        "- BUG-002 · high · path-traversal · app/x.py:notanumber · bad line number\n"
        "- BUG-003 · medium · logic · app/y.py:5 · second good line\n"
    )
    findings = parse_report(text)
    bug_ids = [f.bug_id for f in findings]
    assert bug_ids == ["BUG-001", "BUG-003"]


def test_baseline_arm_same_format_parses() -> None:
    # The baseline arm emits the same structured line without the surrounding
    # bugsweep report scaffolding; the parser keys only on the header.
    text = f"{SECTION}\n- BUG-009 · low · race-condition · pkg/worker.go:212 · TOCTOU on cache file\n"
    findings = parse_report(text)
    assert len(findings) == 1
    assert findings[0].file == "pkg/worker.go"
    assert findings[0].line == 212
    assert findings[0].category == "race-condition"


def test_section_ends_at_next_header() -> None:
    text = (
        f"{SECTION}\n"
        "- BUG-001 · critical · sql-injection · app/db/users.py:88 · in section\n"
        "## How to review\n"
        "- BUG-999 · low · logic · app/z.py:1 · this is outside the section\n"
    )
    findings = parse_report(text)
    assert [f.bug_id for f in findings] == ["BUG-001"]
