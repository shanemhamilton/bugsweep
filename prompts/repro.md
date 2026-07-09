# Phase: Repro (executable proof, best-effort)

You turn a CONFIRMED bug's described trigger into an EXECUTABLE test: a minimal test that
FAILS while the bug is present and PASSES once it is genuinely fixed. This raises precision
(a bug you cannot reproduce is downgraded, not force-fitted) and hardens the Fix phase (a
fix must make the repro go green, not just leave the general suite unbothered).

This phase is **best-effort and entirely skippable**. It runs once per CONFIRMED bug,
immediately before `prompts/fix.md`'s protocol for that bug, and only for bugs with a
reproducible shape. Skipping it is not a failure of the run — it degrades cleanly to
today's suite-only gating (see "Skip conditions" below).

## Protocol (per confirmed bug, before editing anything)

1. **Decide if this bug has a reproducible shape.** A good candidate has a single,
   nameable triggering condition — a function call with specific inputs, an HTTP request
   with a specific payload, a CLI invocation with specific flags — that the Referee's
   finding already describes (`why_wrong` / `manifests` from `prompts/hunt.md`'s output).
   See "Skip conditions" for when NOT to attempt one.

2. **Detect the repo's test framework and conventions.** Reuse whatever
   `scripts/run_checks.sh` already resolved (`config/bugsweep.config.json`'s
   `.commands.test`, or its auto-detect: pytest, `npm test`/jest/vitest, `go test`,
   `cargo test`, bats, ...). Look at an existing test file in the repo's own test
   directory (`tests/`, `__tests__/`, `spec/`, ...) for its import style, assertion
   helpers, and naming convention, so the repro fits in rather than looking bolted-on.

3. **Write ONE minimal test that asserts the CORRECT behavior — not the buggy one.**
   Call the exact code path from the finding with the concrete input that triggers it, and
   assert what the correct output/state/status SHOULD be. Getting this backwards (asserting
   the current, buggy behavior) silently inverts the whole gate — double-check the
   assertion encodes the fix's goal, not its absence.
   - Prefer placing the file inside the project's own test discovery path (e.g.
     `tests/test_bug_<n>.py`, `__tests__/bug-<n>.test.js`) so the project's OWN
     `commands.test` picks it up automatically once committed alongside the fix.
   - If the project has no conventional test directory (a bare script/CLI repo), write a
     small standalone script under `<RUN_DIR>/repro-<BUG-ID>.sh` instead — it never
     pollutes the target repo, and you record its exact invocation in step 4.
   - Keep it minimal: one test, one assertion path, no unrelated setup/teardown changes.

4. **Confirm it is RED before touching any fix code:**
   ```bash
   bash scripts/repro.sh pre "<RUN_DIR>" "<BUG-ID>" "<repro command>"
   ```
   Read the printed line:
   - `REPRO=red_confirmed` — the repro demonstrates the bug. Proceed to `prompts/fix.md`;
     its step 3b will gate the fix on this repro going green.
   - `REPRO=unreproduced` — the command PASSED before any fix was applied, meaning it did
     NOT demonstrate the bug (a wrong assertion, or the bug isn't reachable the way you
     wrote it). Do not retry indefinitely — one more attempt at most. If you still can't get
     it red, delete the misleading test file (never leave a broken/misleading test behind)
     and proceed to `prompts/fix.md` anyway — this bug simply falls back to suite-only
     gating, exactly like `REPRO=none`.
   - `REPRO=none` — printed when you pass an empty command (see "Skip conditions" below).

## Skip conditions (call `scripts/repro.sh pre "<RUN_DIR>" "<BUG-ID>" ""`, or simply
skip this phase entirely for this bug — `scripts/repro.sh post` safely defaults to
`REPRO=none` either way)

- No test framework/runner is detected for this repo (`run_checks.sh baseline` reported
  `NO_CHECKS`, or `.commands.test`/auto-detect resolved to nothing). Follow
  `references/no-tests.md` as usual.
- The bug's shape genuinely isn't a minimal-test shape: a broad architectural/cross-file
  finding with no single triggering call, a documentation/config-only issue, or a trigger
  that needs infrastructure a unit test can't deterministically stand up (a live network
  dependency, precise wall-clock timing, a multi-process race).
- Two attempts to write a failing test both came back `REPRO=unreproduced`.

None of these are errors. `scripts/repro.sh post` always degrades to `REPRO=none` (no
additional gate) whenever `pre` was skipped, recorded `none`, or recorded `unreproduced` —
see its header comment for the exact contract. The Fix phase proceeds exactly as it always
has for these bugs.

## Never let this phase block Fix

Repro synthesis is strictly additive evidence, not a prerequisite. A `REPRO=none` or
`REPRO=unreproduced` result is not a failure of the bugsweep run and must never stop you
from proceeding to `prompts/fix.md`. The only thing this phase changes is: when a repro WAS
confirmed red, the Fix phase's revert decision now also depends on that repro going green
after the fix (see `prompts/fix.md` step 3b and `scripts/repro.sh`'s header for the full
contract) — it can only make the revert decision MORE strict, never less.
