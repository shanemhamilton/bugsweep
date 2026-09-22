# Phase: Repro (required executable proof)

For every fix-eligible confirmed bug, create one native regression test that asserts the
correct behavior. The test is part of the fix and must be unchanged across the proof.
Do not use host evaluation, a shell fallback, an untimed run, or an unverified provider.
If the required external execution policy or provider is unavailable, truthfully block the
fix and record the confirmed finding for human action; detection may continue.

Approval and scope rules still apply: in `--approve` mode approval must already cover this
test and the exact intended source files. Do not widen that set.

## Required sequence

1. Write one small project-native test with a stable native test identity. It must assert
   the intended correct result, name the exact assertion failure expected before the fix,
   and use the repository's normal test discovery and assertion style. Do not write a
   standalone run-directory substitute.
2. Produce a frozen pre-fix request. The request must name the command, native test id,
   expected assertion message, unchanged test path, intended production files, JUnit path,
   and the complete reviewed production-source digest map:

   ```bash
   python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" repro-pre "<RUN_DIR>" "<BUG-ID>" "<SPEC.json>"
   ```

   Use the returned `pre.json` path exactly; never pass a raw command to the proof runner.
3. Run the immutable red proof through the configured required-untrusted provider:

   ```bash
   bash "$SKILL_ROOT/scripts/repro.sh" pre "<RUN_DIR>" "<BUG-ID>" "<PRE_REQUEST.json>"
   ```

   Continue only on `REPRO=red_confirmed`: the same native test must fail as an assertion,
   with the declared message, against the frozen pre-fix source identity. Any other result
   blocks the fix. Do not reinterpret tool output or an ordinary process failure as red.
4. After the minimal production edit and a provider-verified suite receipt, create the
   post request and run the same test green:

   ```bash
   python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" repro-post "<RUN_DIR>" "<BUG-ID>"
   bash "$SKILL_ROOT/scripts/repro.sh" post "<RUN_DIR>" "<BUG-ID>" "<POST_REQUEST.json>"
   ```

   Continue only on `REPRO=confirmed`. The proof binds the same native identity, exact
   expected pre-fix assertion, source manifests, configured provider, verified network denial,
   deadline, logs, JUnit artifact, and suite receipt. The resulting proof is immutable.
5. For a final tree containing more than one fix, preserve each original proof and create a
   separate final-tree reverification event; never replace or rewrite the original proof:

   ```bash
   python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" reverify "<RUN_DIR>" "<BUG-ID>" "<ORIGINAL_FIX_COMMIT>"
   bash "$SKILL_ROOT/scripts/repro.sh" reverify "<RUN_DIR>" "<BUG-ID>" "<REVERIFY_REQUEST.json>"
   ```

   The producer requires the original commit as an argument. A successful run publishes
   `REVERIFY_RECEIPT`, `REVERIFY_SHA256`, and its bound `fix_reverified` ledger event.
   A failed or unavailable reverification blocks landing that fix. Record the block and keep
   the original evidence intact.

`confidence` is uncalibrated reviewer metadata, never a probability or an independence
claim. Analyzer output may narrow where to inspect, but cannot make a candidate red, green,
confirmed, or fix-eligible.
