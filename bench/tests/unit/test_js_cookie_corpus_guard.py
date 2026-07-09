"""Regression guard (bugsweep-4yu), complementing bugsweep-dxh's
``tests/bats/prompts-guardrails.bats``: pins the js-cookie prototype-pollution
detection case's ground truth in the bench corpus.

bugsweep-dcs was a false negative where the Skeptic/Referee dismissed a real,
in-the-running-code prototype-pollution vulnerability (js-cookie's ``assign()``
helper copies enumerable keys without excluding ``__proto__``) as "upstream's
problem". bugsweep-dxh closed the PROMPT-level hole:
``tests/bats/prompts-guardrails.bats`` asserts ``prompts/challenge.md`` and
``prompts/referee.md`` forbid rejecting a finding on "it's upstream" / "no
call site in this codebase exploits it" / "it's pre-existing" grounds.

This test closes the CORPUS-level half, which that guard needs to have
anything to bite on: the benchmark case that models exactly the js-cookie
prototype-pollution vulnerability must keep existing, with the correct
ground-truth file/hunk, so a future corpus edit can never silently drop or
weaken the one case that actually exercises the bugsweep-dxh prompt guard end
to end. It deliberately does NOT re-test the prompt content itself (that is
prompts-guardrails.bats's job) — only that the corpus-side evidence backing it
is present and correct.
"""

import json
from pathlib import Path

import jsonschema

REPO_ROOT = Path(__file__).resolve().parents[3]
CASE_PATH = REPO_ROOT / "bench" / "corpus" / "cases" / "js-sec-js-cookie-46625.json"
SCHEMA_PATH = REPO_ROOT / "bench" / "corpus" / "schema.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_js_cookie_prototype_pollution_case_exists() -> None:
    assert CASE_PATH.is_file(), (
        f"expected the js-cookie prototype-pollution corpus case at {CASE_PATH} "
        "(backs the bugsweep-dxh/dcs no-reject-on-'upstream' regression guard "
        "in tests/bats/prompts-guardrails.bats)"
    )


def test_js_cookie_case_validates_against_the_corpus_schema() -> None:
    case = _load(CASE_PATH)
    schema = _load(SCHEMA_PATH)
    jsonschema.validate(instance=case, schema=schema)


def test_js_cookie_case_ground_truth_pins_the_assign_helper_prototype_pollution() -> None:
    case = _load(CASE_PATH)

    assert case["id"] == "js-sec-js-cookie-46625"
    assert case["language"] == "javascript"
    assert case["category"] == "security"
    assert case["cross_file"] is False

    ground_truth = case["ground_truth"]
    # The exact file/hunk a detection must overlap to be credited — if this
    # ever drifts from src/assign.mjs:2-8, the case would stop exercising the
    # real bugsweep-dcs false-negative scenario.
    assert ground_truth["files"] == ["src/assign.mjs"]
    assert ground_truth["hunks"] == [{"file": "src/assign.mjs", "start": 2, "end": 8}]

    description = ground_truth["description"].lower()
    assert "__proto__" in description
    assert "prototype pollution" in description


def test_js_cookie_case_source_matches_the_ghsa_advisory() -> None:
    case = _load(CASE_PATH)
    source = case["source"]
    assert source["repo"] == "https://github.com/js-cookie/js-cookie.git"
    assert "GHSA-qjx8-664m-686j" in source["advisory_url"]
