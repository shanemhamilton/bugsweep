"""Structured check-result parsing and comparison; deliberately no subprocesses."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Mapping
from xml.etree import ElementTree


_FAILURES = {"failure", "fail", "failed"}
_ERRORS = {"error", "errors", "setup_error", "import_error", "timeout"}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _proof_error(*reasons: str) -> dict[str, Any]:
    return {"status": "proof_error", "tests": {}, "reasons": list(reasons)}


def parse_junit(path: Path | str) -> dict[str, Any]:
    """Read JUnit without guessing from logs. Errors and zero tests fail closed."""
    report = Path(path)
    try:
        root = ElementTree.parse(report).getroot()
    except (OSError, ElementTree.ParseError):
        return _proof_error("malformed_junit")

    tests: dict[str, str] = {}
    details: dict[str, dict[str, str | None]] = {}
    had_error = False
    for case in root.iter("testcase"):
        name = case.get("name")
        classname = case.get("classname")
        if not name:
            return _proof_error("missing_native_id")
        native_id = f"{classname}::{name}" if classname else name
        if native_id in tests:
            return _proof_error("duplicate_native_id")
        children = {child.tag.rsplit("}", 1)[-1] for child in case}
        if children & _ERRORS:
            had_error = True
            tests[native_id] = "error"
            details[native_id] = {"failure_type": "error", "message": None}
        elif "failure" in children:
            tests[native_id] = "failure"
            failure = next(child for child in case if child.tag.rsplit("}", 1)[-1] == "failure")
            raw_type = failure.get("type", "")
            details[native_id] = {
                "failure_type": "assertion" if "assert" in raw_type.lower() or not raw_type else raw_type,
                "message": (failure.text or failure.get("message") or "").strip() or None,
            }
        elif "skipped" in children:
            tests[native_id] = "skipped"
            details[native_id] = {"failure_type": None, "message": None}
        else:
            tests[native_id] = "pass"
            details[native_id] = {"failure_type": None, "message": None}
    if not tests:
        return _proof_error("no_tests")
    if had_error:
        return {"status": "proof_error", "tests": tests, "details": details, "reasons": ["error"], "sha256": sha256_file(report)}
    return {"status": "ok", "tests": tests, "details": details, "reasons": [], "sha256": sha256_file(report)}


def parse_native_results(value: Mapping[str, Any]) -> dict[str, Any]:
    """Normalize a native adapter result; it must carry explicit test identities."""
    raw_tests = value.get("tests")
    if not isinstance(raw_tests, list) or not raw_tests:
        return _proof_error("no_tests")
    tests: dict[str, str] = {}
    had_error = False
    for item in raw_tests:
        if not isinstance(item, Mapping):
            return _proof_error("malformed_native_results")
        native_id, status = item.get("native_id"), item.get("status")
        if not isinstance(native_id, str) or not native_id or not isinstance(status, str):
            return _proof_error("missing_native_id")
        if native_id in tests:
            return _proof_error("duplicate_native_id")
        tests[native_id] = status
        had_error |= status in _ERRORS
    return {
        "status": "proof_error" if had_error else "ok",
        "tests": tests,
        "reasons": ["error"] if had_error else [],
    }


def compare_check_results(baseline: Mapping[str, Any], current: Mapping[str, Any]) -> dict[str, Any]:
    """Detect additions to the failing identity set, never aggregate counts."""
    check = current.get("check", baseline.get("check"))
    if not isinstance(check, str) or not check:
        return {"status": "proof_error", "regressions": [], "reasons": ["missing_check"]}
    if baseline.get("status") == "proof_error" or current.get("status") == "proof_error":
        return {"status": "proof_error", "regressions": [], "reasons": ["structured_result_error"]}

    old_tests, new_tests = baseline.get("tests"), current.get("tests")
    if isinstance(old_tests, Mapping) and isinstance(new_tests, Mapping):
        regressions = sorted({
            test_id
            for test_id, state in new_tests.items()
            if state in _FAILURES | _ERRORS and old_tests.get(test_id) not in _FAILURES | _ERRORS
        } | {
            test_id
            for test_id, state in old_tests.items()
            if state == "pass" and new_tests.get(test_id) != "pass"
        })
    else:
        old_status = baseline.get("status")
        new_status = current.get("status")
        regressions = [f"check:{check}"] if old_status in {"pass", "ok"} and new_status in {"fail", "failure", "error"} else []
    return {"status": "regression" if regressions else "ok", "regressions": regressions}


def load_structured_result(path: Path | str, kind: str) -> dict[str, Any]:
    if kind == "junit":
        return parse_junit(path)
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return _proof_error("malformed_native_results")
    return parse_native_results(value) if isinstance(value, Mapping) else _proof_error("malformed_native_results")
