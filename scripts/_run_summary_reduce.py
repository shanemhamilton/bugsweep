#!/usr/bin/env python3
"""Thin entrypoint invoked by scripts/summarize.sh's Tier 1 (python3 available)
reduction path. All actual logic lives in the unit-tested, coverage-measured
``bench/scorer/run_summary.reduce_run`` — this file only wires environment
variables (set by summarize.sh) to that pure function and writes the result.

Inputs (env vars, set by scripts/summarize.sh):
  RUN_DIR         - absolute path to the run directory (ledger.jsonl, recon.json).
  REPORT_IS_STUB  - "true" or "false".
  MODE            - the bugsweep run mode, or empty for null.
  RECALL          - "true" or "false" (bugsweep-dxh --recall mode; default "false"
                    when unset). Gates ONLY run-summary.json's near_misses[] field
                    — see bench/scorer/run_summary.py's reduce_run 'recall' param.
  BUGSWEEP_ROOT   - the skill root, so bench/scorer is importable regardless of cwd.

Argv[1]: output path to write run-summary.json to.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main() -> int:
    sys.path.insert(0, os.environ["BUGSWEEP_ROOT"])
    from bench.scorer.run_summary import reduce_run  # noqa: E402  (path set above)

    run_dir = Path(os.environ["RUN_DIR"])
    mode = os.environ.get("MODE") or None
    report_is_stub = os.environ.get("REPORT_IS_STUB") == "true"
    recall = os.environ.get("RECALL") == "true"

    summary = reduce_run(
        ledger_path=run_dir / "ledger.jsonl",
        recon_path=run_dir / "recon.json",
        report_is_stub=report_is_stub,
        mode=mode,
        # bugsweep-xdw: preflight.sh writes prior-coverage.json into the run
        # dir (see scripts/state.sh's `prime`); reduce_run tolerates it being
        # absent (e.g. a first run on a repo has none) — see run_summary.py's
        # _read_prior_coverage.
        prior_coverage_path=run_dir / "prior-coverage.json",
        # bugsweep-dxh: gates ONLY near_misses[]; never fixed/quarantined/
        # confirmed_unfixed/findings — see reduce_run's docstring.
        recall=recall,
    )

    out_path = sys.argv[1]
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
