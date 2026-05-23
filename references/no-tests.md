# When the project has no automated checks

Auto-revert relies on tests/typecheck/build to detect regressions. If `run_checks.sh`
reports `NO_CHECKS`, that safety net is absent, so behave more conservatively:

- **Prefer detect-only.** Recommend the user run without `--fix` and review findings by
  hand, or add even a minimal check command in `config/bugsweep.config.json`
  (`commands.typecheck` or `commands.build` is often enough to catch the worst
  regressions).
- **Only auto-fix the unambiguous.** Without checks, restrict autonomous fixes to
  changes whose correctness is obvious by inspection and local in scope (e.g. a missing
  null check, an inverted boolean, an off-by-one). Quarantine anything that touches
  control flow broadly or changes a contract.
- **Smaller commits, more detail.** Make each fix tiny and write a fuller commit message
  and ledger note, since the human review is now the only verification.
- **Suggest a check command.** In the report, point out that adding a test/typecheck/
  build command would let bugsweep fix far more aggressively and safely next time.

A configured check command always overrides auto-detection, so even a one-line
`tsc --noEmit`, `go build ./...`, or `python -m compileall .` meaningfully restores the
auto-revert guarantee.
