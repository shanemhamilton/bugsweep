# Phase: Fix

You apply the smallest change that fixes a CONFIRMED bug, then prove you didn't break
anything. One bug at a time. If you cannot fix it safely, quarantine it — do not guess.

## Protocol (per confirmed bug, in severity order)

0. **Repro, best-effort (see `prompts/repro.md`).** Before editing anything, if this bug
   has a reproducible shape, synthesize a minimal failing test and confirm it is red:
   ```bash
   bash scripts/repro.sh pre "<RUN_DIR>" "<BUG-ID>" "<repro command>"
   ```
   `REPRO=red_confirmed` means step 3b below now gates this fix in addition to step 3.
   `REPRO=unreproduced` or `REPRO=none` (including simply skipping this step for a bug with
   no reproducible shape — see `prompts/repro.md`'s skip conditions) means this bug falls
   back to EXACTLY today's suite-only gating (steps 3–4, unchanged) — never let a repro
   that didn't pan out stop you from proceeding to fix the bug.
1. **Minimal change only.** Edit only what's needed to correct the behavior. Do NOT
   refactor, rename, reformat, restructure, "improve", or touch unrelated lines. A fix
   that changes 3 lines is reviewable; one that changes 300 is not, and breaks the trust
   contract.
   In `--approve` mode, approval was obtained before the Repro/Fix phase began. Do not
   broaden the approved edit; a material change requires a new approval before mutation.
2. **Match the codebase.** Use the existing patterns, validation helpers, and error
   conventions already in the file. Don't introduce a new dependency or pattern.
3. **Run the checks:**
   ```bash
   bash scripts/run_checks.sh verify "<RUN_DIR>"
   ```
3b. **Repro gate — only when step 0 printed `REPRO=red_confirmed`.** In ADDITION to step 3
   (never instead of it), run:
   ```bash
   bash scripts/repro.sh post "<RUN_DIR>" "<BUG-ID>"
   ```
   `REPRO=confirmed` (exit 0) means the fix satisfied its repro — proceed to step 4 using
   step 3's result exactly as before. `REPRO=failed` (exit 1) means the repro is STILL red
   after the fix: treat this **exactly like a `REGRESSION`** in step 4 below, even if step 3
   printed `OK` — the general suite passing does not prove THIS bug is fixed when a
   purpose-built repro says otherwise. Skip this step entirely — no additional gate, step
   4's decision depends on step 3 alone, unchanged — whenever step 0 printed
   `REPRO=unreproduced` or `REPRO=none`, or was never run for this bug.
4. **Decide from the result:**
   - Step 3 printed `OK` with no new failures, AND (step 3b was not run, OR step 3b printed
     `REPRO=confirmed`) → stage only this bug's owned files, inspect the staged diff, and
     commit exactly this one fix:
     `git add -- <owned-files> && git commit -m "fix(bugsweep): BUG-<n> <short title>"`
     Append a `fix_committed` event to the ledger with the bug id, final severity, file,
     commit sha, and the Referee-preserved `priority_reason_codes` list (empty when the
     candidate had no priority seed). Closeout fails closed when severity is absent or unknown.
   - Step 3 printed `NO_CHECKS`, or printed `OK` with `FLAKY=`/`FLAKY_TEST=` → do not
     auto-land. Commit only if needed to escrow the exact fix, mark it review-required, and
     route it through tracker + recovery-bundle closeout.
   - Step 3 printed `REGRESSION`, OR step 3b printed `REPRO=failed` → revert your changes
     immediately:
     - uncommitted: restore only the exact files this fix touched; never use a repo-wide
       checkout or clean
     - already committed: `git revert --no-edit HEAD`
     Then append the bug to the ledger `quarantine` list with the failure detail and the same
     Referee-preserved `priority_reason_codes` (cite
     `repro_failed` when step 3b is what triggered the revert, so a human can tell the two
     apart). Move on.
5. End with a clean owned worktree: every touched file is in this bug's commit or restored.
   Unexpected generated/unrelated dirt quarantines the fix; never absorb it with broad staging.

## When NOT to auto-fix (quarantine instead)

- The fix would require changing a public API/contract or many call sites.
- The correct behavior is genuinely ambiguous and needs a product decision.
- There are no automated checks AND the change is non-trivial (see references/no-tests.md).
- Two attempts to fix it both regressed the checks.

Quarantined bugs go in the report under "needs human" with enough detail for someone to
fix them by hand. Never leave the branch with a failing checkpoint commit.
