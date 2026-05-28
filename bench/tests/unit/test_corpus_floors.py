"""Enforce the detection-corpus floors and schema conformance.

The bugsweep benchmark only counts when its cases are (a) disclosed AFTER the
model runner's training cutoff (so detections cannot be memorized) and (b)
include enough genuinely cross-file bugs to exercise architectural reasoning.
These tests pin those floors and verify every committed case validates against
the authoritative schema with well-formed git SHAs.
"""

import datetime
import json
from pathlib import Path

import pytest
from jsonschema.validators import Draft202012Validator

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_PATH = REPO_ROOT / "bench" / "corpus" / "schema.json"
CASES_DIR = REPO_ROOT / "bench" / "corpus" / "cases"

# Training-data cutoff for the model under benchmark; cases disclosed on or
# before this date may be memorized and do not count toward the post-cutoff
# floor.
RUNNER_CUTOFF = datetime.date(2025, 3, 1)

SHA_LENGTH = 40


def _case_paths() -> list[Path]:
    return sorted(CASES_DIR.glob("*.json"))


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _load_cases() -> list[dict]:
    return [_load(path) for path in _case_paths()]


def _disclosure_date(case: dict) -> datetime.date:
    return datetime.date.fromisoformat(case["source"]["disclosure_date"])


def _is_post_cutoff(case: dict) -> bool:
    return _disclosure_date(case) > RUNNER_CUTOFF


def _is_hex_sha(value: str) -> bool:
    if len(value) != SHA_LENGTH:
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return True


def test_post_cutoff_floor() -> None:
    cases = _load_cases()
    post_cutoff = [case for case in cases if _is_post_cutoff(case)]
    assert len(post_cutoff) >= 8, (
        f"expected >=8 post-cutoff cases (disclosure_date > {RUNNER_CUTOFF}), "
        f"found {len(post_cutoff)} of {len(cases)}"
    )


def test_cross_file_post_cutoff_floor() -> None:
    cases = _load_cases()
    cross_file_post_cutoff = [
        case for case in cases if case["cross_file"] and _is_post_cutoff(case)
    ]
    assert len(cross_file_post_cutoff) >= 4, (
        "expected >=4 cases that are BOTH cross_file AND post-cutoff "
        f"(disclosure_date > {RUNNER_CUTOFF}), found {len(cross_file_post_cutoff)}"
    )


def test_all_cases_validate_against_schema() -> None:
    schema = _load(SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)

    paths = _case_paths()
    assert paths, f"no corpus cases found under {CASES_DIR}"

    for path in paths:
        case = _load(path)
        errors = sorted(validator.iter_errors(case), key=lambda err: err.path)
        assert not errors, (
            f"{path.name} failed schema validation: "
            + "; ".join(error.message for error in errors)
        )


@pytest.mark.parametrize("path", _case_paths(), ids=lambda p: p.name)
def test_shas_are_40_hex(path: Path) -> None:
    case = _load(path)
    for field in ("pre_fix_commit", "fix_commit"):
        sha = case["source"][field]
        assert _is_hex_sha(sha), f"{path.name}: source.{field} is not 40-hex: {sha!r}"
