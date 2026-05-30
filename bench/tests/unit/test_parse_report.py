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

from bench.scorer.parse_report import (  # noqa: E402
    Finding,
    confirmed_section,
    parse_report,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE = REPO_ROOT / "bench" / "tests" / "fixtures" / "report_detect_only.md"
RELEASED_SKILL_FIXTURE = (
    REPO_ROOT / "bench" / "tests" / "fixtures" / "released-skill-js-cookie-report.md"
)
# A second live-captured report whose H3 headers use the multi-location form
# (`a:4` + `b:24`) and same-file shorthand (`a:24` + `:29`). It exposed a parser
# false-negative: the ground-truth file was dropped, scoring NOT_DETECTED.
RELEASED_SKILL_MULTILOC_FIXTURE = (
    REPO_ROOT
    / "bench"
    / "tests"
    / "fixtures"
    / "released-skill-js-cookie-report-multiloc.md"
)

SECTION = "## Confirmed but not fixed (detect-only or below severity floor)"
# Claude paraphrases the parenthetical; the parser must still anchor on this.
SECTION_PARAPHRASED = "## Confirmed but not fixed (detect-only)"


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


# ---------------------------------------------------------------------------
# Released-skill (H3) format — the as-installed bugsweep skill emits its
# findings as `### BUG-N · sev · cat · `file:line`` H3 headers, with the cause
# on the next bold line. The benchmark measures this format honestly, with no
# SKILL.md modification required.
# ---------------------------------------------------------------------------


def test_released_skill_fixture_extracts_all_seven_findings() -> None:
    """The real captured report from a live smoke run yields all 7 findings."""
    findings = parse_report(RELEASED_SKILL_FIXTURE)
    assert [f.bug_id for f in findings] == [
        "BUG-1",
        "BUG-2",
        "BUG-3",
        "BUG-4",
        "BUG-5",
        "BUG-6",
        "BUG-7",
    ]


def test_released_skill_first_finding_pins_ground_truth_match() -> None:
    """BUG-1 must localize to the case's ground-truth file (src/assign.mjs)."""
    first = parse_report(RELEASED_SKILL_FIXTURE)[0]
    assert first.bug_id == "BUG-1"
    assert first.severity == "medium"
    assert first.category == "architectural"  # qualifier (T2) stripped.
    assert first.file == "src/assign.mjs"
    assert first.line == 4
    assert "Prototype-chain walk" in first.rationale


def test_section_header_is_prefix_matched_against_claude_paraphrasing() -> None:
    """Claude shortens '(detect-only or below severity floor)' → '(detect-only)'."""
    text = (
        f"{SECTION_PARAPHRASED}\n"
        "### BUG-1 · medium · architectural (T2) · `src/assign.mjs:4`\n"
        "**Prototype-chain walk.**\n"
    )
    findings = parse_report(text)
    assert len(findings) == 1 and findings[0].bug_id == "BUG-1"


def test_h3_format_strips_backticks_from_file_line_token() -> None:
    text = (
        f"{SECTION}\n"
        "### BUG-X · high · injection · `pkg/x.go:42`\n"
        "**Cause line.**\n"
    )
    findings = parse_report(text)
    assert findings[0].file == "pkg/x.go" and findings[0].line == 42


def test_h3_format_canonicalizes_line_range_to_first_line() -> None:
    """The released skill writes `file:N-M` for span bugs; pin canonical N."""
    text = (
        f"{SECTION}\n"
        "### BUG-X · medium · architectural · `src/api.mjs:24-43`\n"
        "**Span bug spanning many lines.**\n"
    )
    findings = parse_report(text)
    assert findings[0].file == "src/api.mjs"
    assert findings[0].line == 24


def test_h3_category_qualifier_is_stripped() -> None:
    """`architectural (T2)` → `architectural`; bare categories pass through."""
    text = (
        f"{SECTION}\n"
        "### BUG-X · medium · architectural (T2) · `src/x.mjs:1`\n"
        "**A.**\n"
        "### BUG-Y · medium · sql-injection · `src/y.py:1`\n"
        "**B.**\n"
    )
    findings = parse_report(text)
    assert findings[0].category == "architectural"
    assert findings[1].category == "sql-injection"


def test_h3_skips_blank_lines_when_locating_the_cause_line() -> None:
    """A blank line between the H3 header and its bold cause must be tolerated."""
    text = (
        f"{SECTION}\n"
        "### BUG-X · medium · arch · `src/x.mjs:1`\n"
        "\n"
        "**bold cause after a blank line.**\n"
    )
    findings = parse_report(text)
    assert findings[0].rationale == "bold cause after a blank line."


def test_h3_without_following_bold_line_falls_back_to_empty_cause() -> None:
    text = (
        f"{SECTION}\n"
        "### BUG-X · medium · arch · `src/x.mjs:1`\n"
    )
    findings = parse_report(text)
    assert findings[0].rationale == ""


def test_h3_takes_non_bold_following_line_as_cause_verbatim() -> None:
    """If the next non-blank line isn't a `**bold**` block, take it verbatim."""
    text = (
        f"{SECTION}\n"
        "### BUG-X · medium · arch · `src/x.mjs:1`\n"
        "plain paragraph cause text\n"
    )
    findings = parse_report(text)
    assert findings[0].rationale == "plain paragraph cause text"


def test_h3_with_wrong_field_count_is_skipped() -> None:
    text = (
        f"{SECTION}\n"
        "### BUG-X · only-two-fields\n"
        "**ignored**\n"
    )
    assert parse_report(text) == []


def test_h3_with_invalid_file_line_token_is_skipped() -> None:
    text = (
        f"{SECTION}\n"
        "### BUG-X · medium · arch · `notafile`\n"
        "**ignored**\n"
    )
    assert parse_report(text) == []


def test_mixed_bullet_and_h3_in_same_section_both_extracted() -> None:
    """Belt-and-suspenders: the bullet WU1 line + the H3 form coexist cleanly."""
    text = (
        f"{SECTION}\n"
        "- BUG-001 · critical · sql-injection · app/db/users.py:88 · bullet cause\n"
        "### BUG-002 · medium · arch · `src/x.mjs:4`\n"
        "**h3 cause.**\n"
    )
    findings = parse_report(text)
    assert [f.bug_id for f in findings] == ["BUG-001", "BUG-002"]
    assert findings[1].rationale == "h3 cause."


def test_section_prefix_does_not_match_unrelated_lookalike_header() -> None:
    """'## Confirmed but not fixedXXX' (no space) must not anchor the parse."""
    text = (
        "## Confirmed but not fixedXXX\n"
        "- BUG-X · low · logic · src/x.py:1 · should NOT be parsed\n"
    )
    assert parse_report(text) == []


def test_bullet_with_backticked_file_line_still_parses() -> None:
    """Forward-compatible: bullet form may also wrap file:line in backticks."""
    text = (
        f"{SECTION}\n"
        "- BUG-X · low · logic · `src/x.py:1` · backticked bullet\n"
    )
    findings = parse_report(text)
    assert findings[0].file == "src/x.py" and findings[0].line == 1


# ---------------------------------------------------------------------------
# confirmed_section — the raw section text the LLM extractor consumes. The
# regex layer's only remaining job on the real path is finding this boundary.
# ---------------------------------------------------------------------------


def test_confirmed_section_returns_raw_section_text_verbatim() -> None:
    text = (
        "# bugsweep report\n"
        f"{SECTION}\n"
        "- **B5-1 · medium · model/notification.go:113** — SSRF (any format).\n"
        "## How to review\n"
        "git diff ...\n"
    )
    section = confirmed_section(text)
    assert "B5-1" in section and "model/notification.go" in section
    # boundary respected: the next H2 and beyond are excluded
    assert "How to review" not in section and "git diff" not in section


def test_confirmed_section_absent_header_returns_empty() -> None:
    assert confirmed_section("# wger\n## Self-hosting\nrun docker\n") == ""


# ---------------------------------------------------------------------------
# Multi-location H3 headers — the as-released skill lists several locations for
# one bug, e.g. `a:4` + `b:24`, and a same-file shorthand `a:24` + `:29`. The
# gate keys on a single file, so the FIRST quoted location is canonical.
# Regression: a multi-location header dropped the ground-truth file and scored
# NOT_DETECTED even though the bug was found (live run 20260529T201923Z).
# ---------------------------------------------------------------------------


def test_h3_multi_location_emits_one_finding_per_location() -> None:
    """Each cited location becomes its own Finding (same bug_id), so the
    file-overlap gate localizes the bug regardless of which file is listed first."""
    text = (
        f"{SECTION}\n"
        "### BUG-4 · medium · architectural · `src/assign.mjs:4` + `src/api.mjs:24`\n"
        "**`for…in` without `hasOwnProperty` propagates prototype pollution.**\n"
    )
    findings = parse_report(text)
    assert [(f.bug_id, f.file, f.line) for f in findings] == [
        ("BUG-4", "src/assign.mjs", 4),
        ("BUG-4", "src/api.mjs", 24),
    ]


def test_h3_ground_truth_file_listed_second_still_localizes() -> None:
    """Regression for the order-dependence bug: the released skill does not
    guarantee the ground-truth file is listed first in a multi-location header."""
    text = (
        f"{SECTION}\n"
        "### BUG-Z · medium · architectural · `src/api.mjs:24` + `src/assign.mjs:4`\n"
        "**Prototype pollution via the assign helper.**\n"
    )
    findings = parse_report(text)
    files = {f.file for f in findings}
    assert "src/assign.mjs" in files


def test_h3_same_file_line_shorthand_inherits_previous_file() -> None:
    """`src/api.mjs:24` + `:29`: the bare `:29` inherits the previous file."""
    text = (
        f"{SECTION}\n"
        "### BUG-8 · low · architectural · `src/api.mjs:24` + `:29`\n"
        "**Two related call sites in one file.**\n"
    )
    findings = parse_report(text)
    assert [(f.file, f.line) for f in findings] == [
        ("src/api.mjs", 24),
        ("src/api.mjs", 29),
    ]


def test_h3_bare_line_shorthand_without_prior_file_is_skipped() -> None:
    """A `:line` shorthand with no preceding file has nothing to inherit and is
    dropped rather than producing a finding with an empty file path."""
    text = (
        f"{SECTION}\n"
        "### BUG-X · medium · arch · `:5`\n"
        "**Cause.**\n"
    )
    assert parse_report(text) == []


def test_h3_malformed_location_in_multi_is_skipped_others_kept() -> None:
    """A non-`file:line` token among several is skipped; valid ones still emit."""
    text = (
        f"{SECTION}\n"
        "### BUG-X · medium · arch · `notafile` + `src/x.mjs:1`\n"
        "**Cause.**\n"
    )
    findings = parse_report(text)
    assert [(f.file, f.line) for f in findings] == [("src/x.mjs", 1)]


def test_h3_unterminated_backtick_location_still_parses() -> None:
    """A malformed header with an opening but no closing backtick falls back to
    the remainder after the backtick rather than dropping the finding."""
    text = (
        f"{SECTION}\n"
        "### BUG-X · medium · arch · `src/x.mjs:1\n"
        "**Cause.**\n"
    )
    findings = parse_report(text)
    assert findings[0].file == "src/x.mjs"
    assert findings[0].line == 1


def test_multiloc_fixture_localizes_ground_truth_assign_mjs() -> None:
    """The live multi-location report must yield a src/assign.mjs:4 finding so
    the file-overlap gate localizes the js-cookie prototype-pollution bug."""
    findings = parse_report(RELEASED_SKILL_MULTILOC_FIXTURE)
    assign_hits = [f for f in findings if f.file == "src/assign.mjs"]
    assert assign_hits, "no finding localized to src/assign.mjs"
    assert any(f.line == 4 for f in assign_hits)
