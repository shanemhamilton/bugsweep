"""Validate the corpus detection-case JSON Schema (draft 2020-12).

A valid fixture case MUST pass; a fixture missing a required top-level field
(``cross_file``) MUST fail. This pins the schema contract that WU2's real cases
and WU3's runner depend on.
"""

import json
from pathlib import Path

import jsonschema
import pytest
from jsonschema.validators import Draft202012Validator

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_PATH = REPO_ROOT / "bench" / "corpus" / "schema.json"
FIXTURES = REPO_ROOT / "bench" / "tests" / "fixtures"
VALID_CASE = FIXTURES / "case_valid.json"
INVALID_CASE = FIXTURES / "case_invalid.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def schema() -> dict:
    return _load(SCHEMA_PATH)


def test_schema_is_itself_a_valid_draft_2020_12_schema(schema: dict) -> None:
    # Raises SchemaError if the schema document is malformed.
    Draft202012Validator.check_schema(schema)


def test_valid_case_passes(schema: dict) -> None:
    jsonschema.validate(instance=_load(VALID_CASE), schema=schema)


def test_invalid_case_fails_on_missing_cross_file(schema: dict) -> None:
    instance = _load(INVALID_CASE)
    assert "cross_file" not in instance, "invalid fixture must actually omit cross_file"
    with pytest.raises(jsonschema.ValidationError) as exc:
        jsonschema.validate(instance=instance, schema=schema)
    assert "cross_file" in str(exc.value)


def test_cwe_is_optional(schema: dict) -> None:
    instance = _load(VALID_CASE)
    instance.pop("cwe", None)
    # Removing the optional cwe must NOT cause a validation error.
    jsonschema.validate(instance=instance, schema=schema)
