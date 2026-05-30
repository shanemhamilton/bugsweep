"""Tests for ``bench.scorer.extract``.

The extractor turns a raw "Confirmed but not fixed" report section into
structured findings via one injected LLM call, so the brittle per-finding regex
parsing is replaced by a format-robust model call. No network: tests pass a
``FakeClient`` returning canned JSON. These pin the response parse, the
empty/unparseable fallthrough, the delimiting (the report section sits inside a
data region), line coercion, and that fileless/malformed items are skipped.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.extract import extract_findings, parse_json_block  # noqa: E402
from bench.scorer.parse_report import Finding  # noqa: E402

MODEL = "gpt-x"

# A bold/em-dash/batch-id section like opus-4-8 emits (the format the regex
# parser drops to zero findings).
BATCH_SECTION = (
    "### CRITICAL\n"
    "- **B5-1 · medium · model/notification.go:113-143 (+ controller/notification.go)** "
    "— SSRF. Non-admin notifications fetch a user URL with no allowlist.\n"
    "### HIGH\n"
    "- **B1-1 · high · cmd/dashboard/controller/oauth2.go:159-171** — OAuth binding takeover.\n"
)


class FakeClient:
    """In-process stand-in for the LLM client; records the last prompt."""

    def __init__(self, resp: str) -> None:
        self.resp = resp
        self.seen: dict[str, object] | None = None

    def complete(self, *, model: str, temperature: float, prompt: str) -> str:
        self.seen = {"model": model, "temperature": temperature, "prompt": prompt}
        return self.resp


def test_extracts_findings_from_bold_batch_format() -> None:
    client = FakeClient(
        '[{"bug_id":"B5-1","file":"model/notification.go","line":113,'
        '"rationale":"SSRF via unvalidated notification URL"},'
        '{"bug_id":"B1-1","file":"cmd/dashboard/controller/oauth2.go","line":159,'
        '"rationale":"OAuth binding takeover"}]'
    )
    findings = extract_findings(BATCH_SECTION, client, MODEL)
    assert [(f.bug_id, f.file, f.line) for f in findings] == [
        ("B5-1", "model/notification.go", 113),
        ("B1-1", "cmd/dashboard/controller/oauth2.go", 159),
    ]
    assert all(isinstance(f, Finding) for f in findings)


def test_section_text_sits_inside_a_delimited_data_region() -> None:
    client = FakeClient("[]")
    extract_findings("MARK_THE_SECTION", client, MODEL)
    assert client.seen is not None
    prompt = client.seen["prompt"]
    open_idx = prompt.index("<REPORT_SECTION>")
    close_idx = prompt.index("</REPORT_SECTION>")
    assert open_idx < prompt.index("MARK_THE_SECTION") < close_idx


def test_temperature_zero_and_model_pinned() -> None:
    client = FakeClient("[]")
    extract_findings("x", client, MODEL)
    assert client.seen["temperature"] == 0
    assert client.seen["model"] == MODEL


def test_empty_section_returns_no_findings_without_calling_the_model() -> None:
    client = FakeClient('[{"file":"a.py","line":1}]')
    assert extract_findings("   \n  ", client, MODEL) == []
    assert client.seen is None  # no LLM call for an empty section


def test_unparseable_response_falls_through_to_empty() -> None:
    assert extract_findings("s", FakeClient("the model rambled, no JSON"), MODEL) == []


def test_non_array_json_falls_through_to_empty() -> None:
    assert extract_findings("s", FakeClient('{"file":"a.py"}'), MODEL) == []


def test_bracketed_but_invalid_json_falls_through_to_empty() -> None:
    # brackets are present (so we attempt json.loads) but the content is invalid.
    assert extract_findings("s", FakeClient("[{file: not valid json}]"), MODEL) == []


def test_json_array_in_prose_is_extracted() -> None:
    client = FakeClient('Here you go:\n[{"bug_id":"X","file":"a.py","line":7}]\nDone.')
    findings = extract_findings("s", client, MODEL)
    assert findings[0].file == "a.py" and findings[0].line == 7


def test_line_coercion_handles_string_and_missing() -> None:
    client = FakeClient(
        '[{"file":"a.py","line":"42"},{"file":"b.py"},{"file":"c.py","line":null}]'
    )
    findings = extract_findings("s", client, MODEL)
    assert [(f.file, f.line) for f in findings] == [
        ("a.py", 42),
        ("b.py", 0),
        ("c.py", 0),
    ]


def test_fileless_and_nondict_items_are_skipped() -> None:
    client = FakeClient('[{"bug_id":"NoFile"}, "junk", {"file":"ok.py","line":1}]')
    findings = extract_findings("s", client, MODEL)
    assert [f.file for f in findings] == ["ok.py"]


# ---------------------------------------------------------------------------
# parse_json_block — JSON fast path (no LLM call when block is present)
# ---------------------------------------------------------------------------

_JSON_BLOCK_REPORT = """\
# bugsweep report — 2026-01-01T00:00:00Z

## Confirmed but not fixed (detect-only or below severity floor)
- BUG-1 · high · security · src/foo.py:42 · Prototype pollution via merge

## Findings (machine-readable)
```json
[
  {"bug_id": "BUG-1", "severity": "high", "category": "security",
   "file": "src/foo.py", "line": 42, "fixed": false,
   "rationale": "Prototype pollution via merge"},
  {"bug_id": "BUG-2", "severity": "medium", "category": "logic",
   "file": "lib/bar.js", "line": 10, "fixed": true,
   "rationale": "Off-by-one in loop bound"}
]
```

## How to review
git diff main..bugsweep/20260101
"""

_REPORT_WITHOUT_BLOCK = """\
# bugsweep report — 2026-01-01T00:00:00Z

## Confirmed but not fixed (detect-only or below severity floor)
- BUG-1 · high · security · src/foo.py:42 · Prototype pollution via merge

## How to review
git diff main..bugsweep/20260101
"""

_REPORT_WITH_MALFORMED_JSON = """\
# bugsweep report

## Findings (machine-readable)
```json
[{bug_id: not valid}]
```
"""

_REPORT_WITH_EMPTY_BLOCK = """\
# bugsweep report

## Findings (machine-readable)
```json
[]
```
"""


def test_parse_json_block_returns_not_fixed_findings() -> None:
    findings = parse_json_block(_JSON_BLOCK_REPORT)
    assert findings is not None
    assert len(findings) == 1
    f = findings[0]
    assert f.bug_id == "BUG-1"
    assert f.severity == "high"
    assert f.category == "security"
    assert f.file == "src/foo.py"
    assert f.line == 42
    assert f.rationale == "Prototype pollution via merge"


def test_parse_json_block_filters_out_fixed_entries() -> None:
    findings = parse_json_block(_JSON_BLOCK_REPORT)
    assert findings is not None
    assert all(f.bug_id != "BUG-2" for f in findings)


def test_parse_json_block_returns_none_when_section_absent() -> None:
    assert parse_json_block(_REPORT_WITHOUT_BLOCK) is None


def test_parse_json_block_returns_none_for_malformed_json() -> None:
    assert parse_json_block(_REPORT_WITH_MALFORMED_JSON) is None


def test_parse_json_block_returns_empty_list_for_empty_array() -> None:
    findings = parse_json_block(_REPORT_WITH_EMPTY_BLOCK)
    assert findings == []


def test_parse_json_block_skips_entries_missing_file() -> None:
    report = """\
## Findings (machine-readable)
```json
[{"bug_id": "X", "severity": "low", "category": "logic",
  "line": 1, "fixed": false, "rationale": "no file field"},
 {"bug_id": "Y", "severity": "low", "category": "logic",
  "file": "a.py", "line": 5, "fixed": false, "rationale": "ok"}]
```
"""
    findings = parse_json_block(report)
    assert findings is not None
    assert [f.file for f in findings] == ["a.py"]


def test_parse_json_block_treats_missing_fixed_key_as_not_fixed() -> None:
    report = """\
## Findings (machine-readable)
```json
[{"bug_id": "Z", "severity": "high", "category": "security",
  "file": "x.py", "line": 7, "rationale": "missing fixed key"}]
```
"""
    findings = parse_json_block(report)
    assert findings is not None
    assert findings[0].file == "x.py"


def test_parse_json_block_accepts_path(tmp_path: Path) -> None:
    report_file = tmp_path / "report.md"
    report_file.write_text(_JSON_BLOCK_REPORT, encoding="utf-8")
    findings = parse_json_block(report_file)
    assert findings is not None and len(findings) == 1
