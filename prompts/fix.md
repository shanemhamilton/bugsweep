# Phase: Fix

You apply the smallest change that fixes a CONFIRMED bug, then prove you didn't break
anything. One bug at a time. If you cannot fix it safely, quarantine it — do not guess.

## Protocol (per confirmed bug, in severity order)

1. **Minimal change only.** Edit only what's needed to correct the behavior. Do NOT
   refactor, rename, reformat, restructure, "improve", or touch unrelated lines. A fix
   that changes 3 lines is reviewable; one that changes 300 is not, and breaks the trust
   contract.
2. **Match the codebase.** Use the existing patterns, validation helpers, and error
   conventions already in the file. Don't introduce a new dependency or pattern.
3. **Run the checks:**
   ```bash
   bash scripts/run_checks.sh verify "<RUN_DIR>"
   ```
4. **Decide from the result:**
   - `OK` / `NO_CHECKS` with no new failures → commit exactly this one fix:
     `git add -A && git commit -m "fix(bugsweep): BUG-<n> <short title>"`
     Append a `fix_committed` event to the ledger with the bug id, file, and commit sha.
   - `REGRESSION` → revert your changes immediately:
     - uncommitted: `git checkout -- . && git clean -fd -- <only files you touched>`
     - already committed: `git revert --no-edit HEAD`
     Then append the bug to the ledger `quarantine` list with the failure detail. Move on.
5. **In `--approve` mode**, show the user the diff and the bug explanation, and wait for
   approval before step 3's commit.

## When NOT to auto-fix (quarantine instead)

- The fix would require changing a public API/contract or many call sites.
- The correct behavior is genuinely ambiguous and needs a product decision.
- There are no automated checks AND the change is non-trivial (see references/no-tests.md).
- Two attempts to fix it both regressed the checks.

Quarantined bugs go in the report under "needs human" with enough detail for someone to
fix them by hand. Never leave the branch with a failing checkpoint commit.
