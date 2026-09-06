#!/usr/bin/env python3
"""Thin entrypoint invoked by scripts/aggregate-summaries.sh's Tier 1 (python3
available) path. All actual logic lives in the unit-tested, coverage-measured
``bench.scorer.session_summary.merge_summaries`` — this file only reads the
run-summary.json files named on argv, parses them, and writes the merged
session-summary.json (mirrors scripts/_run_summary_reduce.py's shape for
bench.scorer.run_summary.reduce_run).

Argv[1]: output path to write session-summary.json to.
Argv[2:]: one or more input run-summary.json paths to merge.

Env:
  BUGSWEEP_ROOT - the skill root, so bench/scorer is importable regardless of cwd.

A summary file that is missing or fails to parse as a JSON object is skipped
(never fatal) — the aggregate should reflect however many inputs were
actually readable rather than aborting the whole session view over one
corrupt file.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def _object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _load_summary(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f, object_pairs_hook=_object)
    except (OSError, json.JSONDecodeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    try:
        import jsonschema
    except ImportError:
        return None
    try:
        schema = json.loads((Path(__file__).resolve().parents[1] / "schemas" / "run-summary.schema.json").read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(data)
    except (OSError, ValueError, json.JSONDecodeError, jsonschema.ValidationError):
        return None
    return data


def main() -> int:
    sys.path.insert(0, os.environ["BUGSWEEP_ROOT"])
    from bench.scorer.session_summary import merge_summaries  # noqa: E402

    out_path = sys.argv[1]
    input_paths = sys.argv[2:]

    loaded = [_load_summary(path) for path in input_paths]
    summaries = [summary for summary in loaded if summary is not None]

    session = merge_summaries(summaries, invalid_input_count=len(loaded) - len(summaries))

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(session, f, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
