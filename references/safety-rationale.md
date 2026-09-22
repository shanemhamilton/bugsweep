# Why bugsweep is safe to run unattended

The safety does not depend on the AI behaving well. It depends on three structural
properties, most enforced by deterministic shell scripts rather than model prose.

1. **Isolation by construction.** `preflight.sh --worktree` cuts one exact ephemeral
   branch in a Bugsweep-owned linked worktree. The user's checkout is not switched,
   stashed, or edited during hunting.

2. **Ownership is exact.** `state.env` records the run branch, worktree, base SHA, and
   original target. Cleanup requires that exact branch argument and never infers ownership
   from a `bugsweep/*` prefix.

3. **No fix survives without evidence.** Every automatic fix needs immutable red/green
   assertion proof, a provider-verified suite receipt, and an eligible fresh native
   review under the frozen host/model and prompt contract. A missing execution policy,
   unavailable provider, unchecked result, or flaky result blocks automatic integration.

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
stops new loop work once the codebase converges (no new confirmed bugs for N iterations).
Tune these in `config/bugsweep.config.json`. An interrupt, unavailable evidence provider,
or incomplete tracker/cleanup recovery still requires terminal readback before the run can
be called complete.

## Supply-chain note

Bugsweep's automatic-fix path requires an operator-supplied, digest-pinned Docker policy.
Tests and analyzers run with denied network; native reviews use the separately verified
approved-proxy-only profile. Tracker access and optional advisory research remain
project-controlled. Read the installed scripts and execution policy before trusting an
automatic run.
