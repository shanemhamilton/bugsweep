"""Pure structured-check parsing and regression decisions."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from scripts._check_results import compare_check_results, parse_junit


def _junit(cases: str) -> str:
    return f'<?xml version="1.0"?><testsuite tests="2">{cases}</testsuite>'


def test_junit_preserves_native_failure_identity(tmp_path: Path) -> None:
    report = tmp_path / "report.xml"
    report.write_text(
        _junit('<testcase classname="pkg.test_auth" name="test_denies" />'
               '<testcase classname="pkg.test_auth" name="test_allows"><failure>wrong</failure></testcase>'),
        encoding="utf-8",
    )

    result = parse_junit(report)

    assert result["status"] == "ok"
    assert result["tests"] == {
        "pkg.test_auth::test_denies": "pass",
        "pkg.test_auth::test_allows": "failure",
    }


def test_junit_setup_or_import_error_is_not_a_test_failure(tmp_path: Path) -> None:
    report = tmp_path / "report.xml"
    report.write_text(_junit('<testcase classname="pkg" name="collect"><error>ImportError</error></testcase>'), encoding="utf-8")

    result = parse_junit(report)

    assert result["status"] == "proof_error"
    assert "error" in result["reasons"]


def test_junit_with_no_tests_is_proof_error(tmp_path: Path) -> None:
    report = tmp_path / "report.xml"
    report.write_text('<testsuite tests="0" />', encoding="utf-8")

    assert parse_junit(report)["status"] == "proof_error"


def test_swapped_failures_are_a_regression_even_when_counts_match() -> None:
    baseline = {"check": "test", "status": "ok", "tests": {"a::test": "failure", "b::test": "pass"}}
    current = {"check": "test", "status": "ok", "tests": {"a::test": "pass", "b::test": "failure"}}

    result = compare_check_results(baseline, current)

    assert result == {"status": "regression", "regressions": ["b::test"]}


def test_unstructured_check_falls_back_conservatively_to_check_status() -> None:
    assert compare_check_results(
        {"check": "lint", "status": "pass"}, {"check": "lint", "status": "fail"}
    ) == {"status": "regression", "regressions": ["check:lint"]}


def test_missing_or_skipped_previously_passing_test_is_a_regression() -> None:
    baseline = {"check": "test", "status": "ok", "tests": {"a::test": "pass"}}

    assert compare_check_results(baseline, {"check": "test", "status": "ok", "tests": {}}) == {
        "status": "regression", "regressions": ["a::test"]
    }
    assert compare_check_results(baseline, {"check": "test", "status": "ok", "tests": {"a::test": "skipped"}}) == {
        "status": "regression", "regressions": ["a::test"]
    }
