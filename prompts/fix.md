# Phase: Fix

Fix one confirmed bug at a time with the smallest source change. Preserve the approved scope,
ownership, ticket requirements, and lifecycle rules. If evidence cannot be produced through the
required provider, block the fix and record it for a human; keep detecting and reporting.

## Required sequence

1. Confirm that Referee evidence is eligible and the Repro phase produced
   `REPRO=red_confirmed`. The immutable red proof must bind one native test identity, one exact
   expected assertion failure, and the reviewed pre-fix source map. Without it, do not edit.
2. Edit only the declared intended production files. Do not alter the regression test after the
   red proof, broaden the approved change, refactor adjacent code, or add dependencies.
3. Refresh the check plan and run the full project-native checks only through the configured
   required-untrusted provider. The provider must return a verified receipt with verified network
   denial, deadline enforcement, source identity, and the configured suite identities. No host
   evaluation, untimed command, or fallback can substitute.

   ```bash
   python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" checks "<RUN_DIR>"
   bash "$SKILL_ROOT/scripts/run_checks.sh" verify "<RUN_DIR>"
   python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" repro-post "<RUN_DIR>" "<BUG-ID>"
   bash "$SKILL_ROOT/scripts/repro.sh" post "<RUN_DIR>" "<BUG-ID>" "<POST_REQUEST.json>"
   ```

   Require both a provider-verified all-suite receipt and `REPRO=confirmed`. A passing general
   suite does not replace the exact red-to-green assertion.
4. Validate the immutable proof before committing:

   ```bash
   python3 -B "$SKILL_ROOT/scripts/_proof.py" validate "<RUN_DIR>/proofs/<BUG-ID>.json" "<RUN_ID>" "<BUG-ID>" "<RUN_DIR>/source-digests.json"
   ```

   Any proof error, regression, missing provider capability, changed source identity, or failed
   expected test is a quarantine condition. Restore only this bug's owned files (or revert only
   its committed change); never use a broad checkout or clean.
5. Only then stage the owned files, inspect the staged diff, commit the single fix, preserve the
   Referee priority attribution, and append the required `fix_committed` ledger event. Maintain
   clean owned worktree and normal tracker/closeout evidence.
6. When later fixes change the final tree, keep the original proof immutable and run a separate
   `reverify` request for every earlier fix. Land only if every original proof and every final
   reverification remains valid; otherwise quarantine the affected fix with the failure detail.

Never auto-fix a public-contract change, ambiguous product behavior, a change requiring broad
call-site edits, or a fix without the required execution evidence. Those belong in the human
review/tracker path with the confirmed trigger and the exact missing proof capability.
