"""Tests for ``bench.scorer.analyzer_norm`` (bugsweep-042).

Static-analyzer seeding: ``scripts/analyzers.sh`` runs off-the-shelf analyzers
(semgrep, gosec, bandit, ...) and writes their RAW per-tool JSON to disk. This
module is the pure, tool-agnostic reduction that turns that raw JSON into a
single normalized hit list the Hunter can read as candidate seeds and the
Referee can use for corroboration.

Contract (see module docstring in analyzer_norm.py for the authoritative
shape): each normalized hit is
    {tool, rule_id, severity(critical|high|medium|low), file, line, message}
deduped, capped at ``max_hits`` (highest-severity first), and returned in a
fully deterministic order so two reductions of the same input never differ.

These are pure-function tests: no subprocess, no filesystem beyond what the
test itself constructs, no network — mirrors the run_summary.py test style.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.analyzer_norm import normalize_hits  # noqa: E402

# ---------------------------------------------------------------------------
# Minimal realistic raw fixtures per supported tool.
# ---------------------------------------------------------------------------

SEMGREP_RAW = {
    "results": [
        {
            "check_id": "python.lang.security.audit.dangerous-subprocess-use",
            "path": "app/util.py",
            "start": {"line": 42},
            "end": {"line": 42},
            "extra": {
                "message": "Detected subprocess call with shell=True.",
                "severity": "ERROR",
            },
        },
        {
            "check_id": "python.lang.correctness.useless-comparison",
            "path": "app/other.py",
            "start": {"line": 10},
            "end": {"line": 10},
            "extra": {
                "message": "Useless comparison.",
                "severity": "WARNING",
            },
        },
    ]
}

GOSEC_RAW = {
    "Issues": [
        {
            "rule_id": "G104",
            "details": "Errors unhandled.",
            "severity": "MEDIUM",
            "confidence": "HIGH",
            "file": "main.go",
            "line": "88",
        }
    ]
}

BANDIT_RAW = {
    "results": [
        {
            "test_id": "B602",
            "test_name": "subprocess_popen_with_shell_equals_true",
            "issue_text": "subprocess call with shell=True identified.",
            "issue_severity": "HIGH",
            "filename": "app/legacy.py",
            "line_number": 17,
        }
    ]
}


# ---------------------------------------------------------------------------
# Shape + severity mapping
# ---------------------------------------------------------------------------


def test_normalizes_semgrep_hit_shape() -> None:
    hits = normalize_hits({"semgrep": SEMGREP_RAW})
    assert hits, "expected at least one normalized hit from semgrep fixture"
    hit = next(h for h in hits if h["file"] == "app/util.py")
    assert hit == {
        "tool": "semgrep",
        "rule_id": "python.lang.security.audit.dangerous-subprocess-use",
        "severity": "critical",
        "file": "app/util.py",
        "line": 42,
        "message": "Detected subprocess call with shell=True.",
    }


def test_semgrep_warning_maps_to_medium() -> None:
    hits = normalize_hits({"semgrep": SEMGREP_RAW})
    hit = next(h for h in hits if h["file"] == "app/other.py")
    assert hit["severity"] == "medium"


def test_normalizes_gosec_hit_shape() -> None:
    hits = normalize_hits({"gosec": GOSEC_RAW})
    assert hits == [
        {
            "tool": "gosec",
            "rule_id": "G104",
            "severity": "medium",
            "file": "main.go",
            "line": 88,
            "message": "Errors unhandled.",
        }
    ]


def test_normalizes_bandit_hit_shape() -> None:
    hits = normalize_hits({"bandit": BANDIT_RAW})
    assert hits == [
        {
            "tool": "bandit",
            "rule_id": "B602",
            "severity": "high",
            "file": "app/legacy.py",
            "line": 17,
            "message": "subprocess call with shell=True identified.",
        }
    ]


def test_combines_multiple_tools_in_one_call() -> None:
    hits = normalize_hits({"semgrep": SEMGREP_RAW, "gosec": GOSEC_RAW, "bandit": BANDIT_RAW})
    tools = {h["tool"] for h in hits}
    assert tools == {"semgrep", "gosec", "bandit"}


# ---------------------------------------------------------------------------
# Dedup
# ---------------------------------------------------------------------------


def test_dedupes_identical_hits_from_same_tool() -> None:
    raw = {
        "results": [
            {
                "check_id": "rule.dup",
                "path": "app/dup.py",
                "start": {"line": 5},
                "extra": {"message": "same finding", "severity": "ERROR"},
            },
            {
                "check_id": "rule.dup",
                "path": "app/dup.py",
                "start": {"line": 5},
                "extra": {"message": "same finding", "severity": "ERROR"},
            },
        ]
    }
    hits = normalize_hits({"semgrep": raw})
    assert len(hits) == 1


def test_does_not_dedupe_across_different_rule_ids_same_location() -> None:
    raw = {
        "results": [
            {
                "check_id": "rule.a",
                "path": "app/dup.py",
                "start": {"line": 5},
                "extra": {"message": "finding a", "severity": "ERROR"},
            },
            {
                "check_id": "rule.b",
                "path": "app/dup.py",
                "start": {"line": 5},
                "extra": {"message": "finding b", "severity": "ERROR"},
            },
        ]
    }
    hits = normalize_hits({"semgrep": raw})
    assert len(hits) == 2


# ---------------------------------------------------------------------------
# Cap + ordering (highest severity first, then deterministic tie-break)
# ---------------------------------------------------------------------------


def test_caps_at_max_hits_keeping_highest_severity_first() -> None:
    raw = {
        "results": [
            {
                "check_id": f"rule.{i}",
                "path": f"app/f{i}.py",
                "start": {"line": i},
                "extra": {
                    "message": "m",
                    "severity": "ERROR" if i % 2 == 0 else "WARNING",
                },
            }
            for i in range(10)
        ]
    }
    hits = normalize_hits({"semgrep": raw}, max_hits=4)
    assert len(hits) == 4
    assert all(h["severity"] == "critical" for h in hits)


def test_deterministic_order_across_repeated_calls() -> None:
    raw = {
        "results": [
            {
                "check_id": f"rule.{i}",
                "path": f"app/f{i}.py",
                "start": {"line": i},
                "extra": {"message": "m", "severity": "WARNING"},
            }
            for i in range(20)
        ]
    }
    first = normalize_hits({"semgrep": raw})
    second = normalize_hits({"semgrep": raw})
    assert first == second


def test_default_max_hits_is_200() -> None:
    raw = {
        "results": [
            {
                "check_id": f"rule.{i}",
                "path": f"app/f{i}.py",
                "start": {"line": i},
                "extra": {"message": "m", "severity": "WARNING"},
            }
            for i in range(250)
        ]
    }
    hits = normalize_hits({"semgrep": raw})
    assert len(hits) == 200


def test_severity_sort_order_is_critical_high_medium_low() -> None:
    raw = {
        "results": [
            {
                "check_id": "rule.low",
                "path": "app/low.py",
                "start": {"line": 1},
                "extra": {"message": "m", "severity": "INFO"},
            },
            {
                "check_id": "rule.crit",
                "path": "app/crit.py",
                "start": {"line": 1},
                "extra": {"message": "m", "severity": "ERROR"},
            },
            {
                "check_id": "rule.med",
                "path": "app/med.py",
                "start": {"line": 1},
                "extra": {"message": "m", "severity": "WARNING"},
            },
        ]
    }
    hits = normalize_hits({"semgrep": raw})
    assert [h["severity"] for h in hits] == ["critical", "medium", "low"]


# ---------------------------------------------------------------------------
# Robustness — never raises on malformed/missing tool output
# ---------------------------------------------------------------------------


def test_empty_input_returns_empty_list() -> None:
    assert normalize_hits({}) == []


def test_unknown_tool_name_is_ignored_not_raised() -> None:
    hits = normalize_hits({"some-future-tool": {"anything": True}})
    assert hits == []


def test_malformed_semgrep_payload_does_not_raise() -> None:
    hits = normalize_hits({"semgrep": {"results": "not-a-list"}})
    assert hits == []


def test_missing_fields_are_tolerated() -> None:
    raw = {"results": [{"check_id": "rule.x", "path": "app/x.py"}]}
    hits = normalize_hits({"semgrep": raw})
    assert len(hits) == 1
    assert hits[0]["line"] is None
    assert hits[0]["severity"] == "low"


def test_gosec_and_bandit_unknown_severity_defaults_to_low() -> None:
    gosec_raw = {
        "Issues": [
            {
                "rule_id": "G999",
                "details": "unknown sev",
                "severity": "WEIRD",
                "file": "x.go",
                "line": "1",
            }
        ]
    }
    hits = normalize_hits({"gosec": gosec_raw})
    assert hits[0]["severity"] == "low"


def test_gosec_non_dict_payload_does_not_raise() -> None:
    assert normalize_hits({"gosec": "not-a-dict"}) == []


def test_gosec_issues_not_a_list_does_not_raise() -> None:
    assert normalize_hits({"gosec": {"Issues": "nope"}}) == []


def test_gosec_skips_non_dict_issue_entries() -> None:
    hits = normalize_hits({"gosec": {"Issues": ["not-a-dict", None, 42]}})
    assert hits == []


def test_bandit_non_dict_payload_does_not_raise() -> None:
    assert normalize_hits({"bandit": "not-a-dict"}) == []


def test_bandit_results_not_a_list_does_not_raise() -> None:
    assert normalize_hits({"bandit": {"results": "nope"}}) == []


def test_bandit_skips_non_dict_result_entries() -> None:
    hits = normalize_hits({"bandit": {"results": ["not-a-dict", None]}})
    assert hits == []


def test_semgrep_skips_non_dict_result_entries() -> None:
    raw = {"results": ["not-a-dict", None]}
    assert normalize_hits({"semgrep": raw}) == []


def test_semgrep_non_dict_payload_does_not_raise() -> None:
    assert normalize_hits({"semgrep": "not-a-dict"}) == []


def test_line_number_bool_is_not_treated_as_int() -> None:
    # bool is an int subclass in Python; a raw `true`/`false` line number must
    # normalize to None rather than silently becoming line 1 or line 0.
    raw = {
        "results": [
            {
                "check_id": "rule.bool",
                "path": "app/bool.py",
                "start": {"line": True},
                "extra": {"message": "m", "severity": "ERROR"},
            }
        ]
    }
    hits = normalize_hits({"semgrep": raw})
    assert hits[0]["line"] is None


def test_line_number_non_numeric_string_is_none() -> None:
    hits = normalize_hits(
        {"gosec": {"Issues": [{"rule_id": "G1", "file": "x.go", "line": "not-a-number"}]}}
    )
    assert hits[0]["line"] is None
