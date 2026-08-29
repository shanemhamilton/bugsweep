# Why bugsweep is safe to run unattended

The safety does not depend on the AI behaving well. It depends on three structural
properties, most enforced by deterministic shell scripts rather than model prose.

1. **Isolation by construction.** `preflight.sh --worktree` cuts one exact ephemeral
   branch in a Bugsweep-owned linked worktree. The user's checkout is not switched,
   stashed, or edited during hunting.

2. **Ownership is exact.** `state.env` records the run branch, worktree, base SHA, and
   original target. Cleanup requires that exact branch argument and never infers ownership
   from a `bugsweep/*` prefix.

3. **No fix survives without proof.** Every fix is a single commit, and `run_checks.sh`
   re-runs your tests/typecheck/build after each one. A fix that introduces any new
   failure is reverted automatically and the bug is tracker-routed. Flaky or unchecked
   fixes are not auto-integrated.

4. **Unlanded work is escrowed.** Verified fixes locally integrate only after a post-merge
   gate. Anything that cannot land is idempotently recorded in the project's existing
   tracker and recovery-bundled before the exact run branch may be discarded.

Things Bugsweep closeout cannot do: push to a Git remote, open a PR, force-push, rewrite
history, delete by wildcard, or reset user content. Tracker upserts and guarded local
integration are the only external/local mutations added after hunting.

A run is successful only after exact readback proves its owned branch and worktree are
gone. Tracker or cleanup failures remain explicitly incomplete.

## Bounding cost

`guard.sh` enforces hard caps on iterations, wall-clock runtime, and total fixes, and
stops automatically once the codebase converges (no new confirmed bugs for N
iterations). Tune these in `config/bugsweep.config.json`. There is no way for the loop
to run indefinitely.

## Supply-chain note

Bugsweep is plain markdown plus short, readable shell scripts — no third-party runtime
dependencies and no telemetry. Network activity is limited to the project's existing
tracker and optional bounded advisory research. Read every script in `scripts/` before
you trust it; that's the point of owning the skill rather than installing an opaque one.
