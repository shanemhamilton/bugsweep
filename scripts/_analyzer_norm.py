#!/usr/bin/env python3
"""Thin entrypoint invoked by scripts/analyzers.sh's Tier 1 (python3 available)
normalization path. All actual logic lives in the unit-tested, coverage-measured
``bench/scorer/analyzer_norm.normalize_hits`` — this file only wires the raw
per-tool JSON files analyzers.sh collected to that pure function and writes the
normalized result.

Inputs (env vars, set by scripts/analyzers.sh):
  RAW_MANIFEST  - path to a JSON file mapping tool name -> path to that tool's
                  raw output file, e.g. {"semgrep": "/run/semgrep.raw.json"}.
                  A tool whose raw file is missing/unreadable/unparseable is
                  silently treated as contributing zero hits (best-effort
                  enhancement, never a hard failure — see analyzers.sh header).
  MAX_HITS      - integer cap, as a string (analyzers.sh reads it from config).
  BUGSWEEP_ROOT - the skill root, so bench/scorer is importable regardless of cwd.

Argv[1]: output path to write the normalized analyzer-hits.json to.

Exit code is always 0 on a handled (even if degraded) outcome; a non-zero exit
means something unexpected happened and analyzers.sh's caller should log +
skip normalization (never fail the run — see SKILL.md trust contract).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def _load_raw_by_tool(manifest_path: str) -> dict[str, object]:
    """Read the tool->raw-file manifest and return {tool: parsed_json}.

    Never raises: a missing manifest, a missing/unreadable/unparseable
    per-tool file, or a non-dict manifest all degrade to "no raw payload for
    that tool" rather than aborting the whole reduction.
    """
    try:
        manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(manifest, dict):
        return {}

    raw_by_tool: dict[str, object] = {}
    for tool, raw_path in manifest.items():
        if not isinstance(raw_path, str):
            continue
        try:
            raw_by_tool[tool] = json.loads(Path(raw_path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
    return raw_by_tool


def main() -> int:
    sys.path.insert(0, os.environ["BUGSWEEP_ROOT"])
    from bench.scorer.analyzer_norm import normalize_hits  # noqa: E402  (path set above)

    manifest_path = os.environ["RAW_MANIFEST"]
    max_hits_raw = os.environ.get("MAX_HITS", "200")
    try:
        max_hits = int(max_hits_raw)
    except ValueError:
        max_hits = 200

    raw_by_tool = _load_raw_by_tool(manifest_path)
    hits = normalize_hits(raw_by_tool, max_hits=max_hits)

    out_path = sys.argv[1]
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"hits": hits, "count": len(hits)}, f, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
