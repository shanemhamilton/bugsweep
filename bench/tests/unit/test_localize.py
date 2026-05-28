"""Tests for ``bench.scorer.localize``.

The hard gate is file overlap: a finding only counts if its (path-normalized)
file is one of the ground-truth files. ``line_close`` (finding line within
±window of any ground-truth hunk) and ``category_match`` are evidence the
scorer surfaces, NOT gates. These tests pin the boundary behavior, path
normalization, multi-file ground truth, and the "file matches, line far"
case where ``passed`` is still True but ``line_close`` is False.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.localize import GateResult, gate  # noqa: E402

GT = {
    "files": ["app/db/query.py"],
    "hunks": [{"file": "app/db/query.py", "start": 42, "end": 51}],
    "category": "sql-injection",
}

MULTI_GT = {
    "files": ["app/a.py", "service/b.go"],
    "hunks": [
        {"file": "app/a.py", "start": 10, "end": 20},
        {"file": "service/b.go", "start": 100, "end": 110},
    ],
    "category": "security",
}


def test_returns_gate_result() -> None:
    assert isinstance(
        gate({"file": "app/db/query.py", "line": 47, "category": "x"}, GT), GateResult
    )


def test_file_overlap_passes() -> None:
    finding = {"file": "app/db/query.py", "line": 47, "category": "sql-injection"}
    assert gate(finding, GT).passed is True


def test_no_overlap_fails() -> None:
    assert (
        gate({"file": "other.py", "line": 5, "category": "security"}, GT).passed
        is False
    )


def test_line_evidence_within_window_far_line_still_passes() -> None:
    # File overlap passes; line is evidence only. Line 80 is well outside the
    # padded range [32, 61] of hunk [42, 51] (window 10), so it is not close.
    result = gate(
        {"file": "app/db/query.py", "line": 80, "category": "logic"}, GT, window=10
    )
    assert result.passed is True
    assert result.line_close is False


def test_line_close_true_inside_window() -> None:
    result = gate(
        {"file": "app/db/query.py", "line": 47, "category": "x"}, GT, window=10
    )
    assert result.line_close is True


def test_line_close_exactly_at_lower_window_boundary() -> None:
    # hunk start 42, window 10 → 32 is exactly on the boundary (inclusive).
    result = gate(
        {"file": "app/db/query.py", "line": 32, "category": "x"}, GT, window=10
    )
    assert result.line_close is True


def test_line_close_exactly_at_upper_window_boundary() -> None:
    # hunk end 51, window 10 → 61 is exactly on the boundary (inclusive).
    result = gate(
        {"file": "app/db/query.py", "line": 61, "category": "x"}, GT, window=10
    )
    assert result.line_close is True


def test_line_just_past_upper_window_is_not_close() -> None:
    result = gate(
        {"file": "app/db/query.py", "line": 62, "category": "x"}, GT, window=10
    )
    assert result.line_close is False


def test_path_normalization_leading_dot_slash() -> None:
    finding = {"file": "./app/db/query.py", "line": 47, "category": "sql-injection"}
    assert gate(finding, GT).passed is True


def test_path_normalization_leading_and_trailing_slash() -> None:
    finding = {"file": "/app/db/query.py/", "line": 47, "category": "x"}
    gt = {
        "files": ["app/db/query.py"],
        "hunks": [{"file": "app/db/query.py", "start": 1, "end": 2}],
    }
    assert gate(finding, gt).passed is True


def test_path_normalization_double_slash() -> None:
    finding = {"file": "app//db/query.py", "line": 47, "category": "x"}
    assert gate(finding, GT).passed is True


def test_path_case_preserved_mismatch_fails() -> None:
    # Case is preserved as-is, so a case difference is a genuine mismatch.
    finding = {"file": "App/DB/Query.py", "line": 47, "category": "x"}
    assert gate(finding, GT).passed is False


def test_multi_file_ground_truth_second_file_matches() -> None:
    finding = {"file": "service/b.go", "line": 105, "category": "security"}
    result = gate(finding, MULTI_GT)
    assert result.passed is True
    assert result.line_close is True


def test_multi_file_line_close_uses_any_hunk() -> None:
    # File matches app/a.py; line near app/a.py's hunk is close even though
    # the other hunk (service/b.go) is far away.
    finding = {"file": "app/a.py", "line": 15, "category": "security"}
    assert gate(finding, MULTI_GT).line_close is True


def test_category_match_exact() -> None:
    finding = {"file": "app/db/query.py", "line": 47, "category": "sql-injection"}
    assert gate(finding, GT).category_match is True


def test_category_match_compatible_with_broad_case_category() -> None:
    # Case category is broad ("security"); finding uses a specific lens.
    finding = {"file": "app/a.py", "line": 15, "category": "sql-injection"}
    assert gate(finding, MULTI_GT).category_match is True


def test_category_mismatch() -> None:
    finding = {"file": "app/db/query.py", "line": 47, "category": "race-condition"}
    assert gate(finding, GT).category_match is False


def test_empty_findings_file_fails() -> None:
    assert gate({"file": "", "line": 1, "category": "x"}, GT).passed is False


def test_non_int_line_is_not_close() -> None:
    # A missing/non-int line cannot be evidence; file overlap still gates.
    result = gate({"file": "app/db/query.py", "category": "x"}, GT)
    assert result.passed is True
    assert result.line_close is False
