# Contributing to Bugsweep

Bugsweep combines Claude/Codex instructions with deterministic Bash and Python helpers.
Keep changes narrow and verify the observable behavior, especially across producer and
consumer boundaries. Read [SERVICE-INVENTORY.md](SERVICE-INVENTORY.md) before adding a
helper; reuse the execution provider, canonical serialization and proof validators.

The model investigates and proposes edits. Coordinator code owns execution, immutable
evidence and exact resource cleanup. Target commands must not execute in a host-shell
fallback. Preserve unrelated files and the user's checkout; no prefix-based deletion,
remote mutation or fabricated evidence.

## Local checks

The default gate excludes Git-backed fixtures and uses temporary coverage files:

```bash
BUGSWEEP_BATS_VERSION=1.10.0 BUGSWEEP_SHELLCHECK_VERSION=0.10.0 bash scripts/quality-check.sh
```

The gate measures Coverage.py aggregate line-and-branch coverage for the scorer and
installer helper separately, requiring at least 80% in each. It does not report a
separate function-coverage percentage.

Those variables declare the installed versions; they do not install anything. CI supplies
checksum-verified tools. For focused Python changes, use cache-disabled tests:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -p no:cacheprovider bench/tests/unit/test_fix_proof.py
```

`common.sh` performs Git discovery when sourced. Do not source it, run the complete Bats
suite, or run `test_mark_batch_covered.py` in sessions that prohibit Git. Authorized CI
uses the separate `BUGSWEEP_FULL_GIT_CI=1 ... quality-check.sh --full-git-ci` path for those
fixtures. Bash targets 3.2 compatibility; use `bash -n` and ShellCheck for changed scripts.

Mocks can prove that parsers and orchestration reject specific counterexamples. They do
not establish actual Docker containment, host compatibility, budget enforcement, human
calibration, or held-out benchmark outcomes. Release evidence must come from the frozen
protocol's real producers and survive independent artifact verification.

## Changes and review

Keep the main skill short and put detailed phase behavior in existing prompts/references.
If a contract changes, update its real producer, consumer, schema, documentation and the
smallest regression check that exposes the failure. Do not patch only a synthetic fixture.

For anti-pattern catalogs, add the focused stack entry under `references/antipatterns/`
and route it in `index.md`. Catalogs guide investigation; they never confirm a bug.

A pull request should state the resulting behavior, relevant checks, and remaining real
verification limits. Do not present source landing as deployment or release. Contributions
use the repository's MIT license.
