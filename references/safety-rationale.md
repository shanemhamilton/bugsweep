# Why bugsweep is safe to run unattended

The safety does not depend on the AI behaving well. It depends on three structural
properties, two of which are enforced by deterministic shell scripts, not by the model.

1. **Quarantine by construction.** `preflight.sh` cuts a fresh `bugsweep/<timestamp>`
   branch from your HEAD and works only there. Your original branch is never committed
   to. The worst case for any run is a branch you delete — there is no path by which an
   overnight run damages your real work.

2. **Your work is preserved deterministically.** Uncommitted changes are stashed before
   anything happens and restored by `finalize.sh` afterward. The scripts record the
   stash reference and original branch in `state.env`, so restore works even if the run
   is interrupted and finalize is run later.

3. **No fix survives without proof.** Every fix is a single commit, and `run_checks.sh`
   re-runs your tests/typecheck/build after each one. A fix that introduces any new
   failure is reverted automatically and the bug is quarantined for a human. The branch
   never ends on a failing checkpoint.

Things bugsweep structurally cannot do (no script ever calls them, and the SKILL
forbids them): push to a remote, open a PR, merge, force-push, rewrite history, delete
files or directories, run `rm -rf`, `git reset --hard` your content, or modify a
protected branch.

The human is the only merge gate. bugsweep produces a reviewable branch and a report;
you decide what, if anything, lands.

## Bounding cost

`guard.sh` enforces hard caps on iterations, wall-clock runtime, and total fixes, and
stops automatically once the codebase converges (no new confirmed bugs for N
iterations). Tune these in `config/bugsweep.config.json`. There is no way for the loop
to run indefinitely.

## Supply-chain note

bugsweep is plain markdown plus short, readable shell scripts — no third-party runtime
dependencies, no network calls, no telemetry. Read every script in `scripts/` before
you trust it; that's the point of owning the skill rather than installing an opaque one.
