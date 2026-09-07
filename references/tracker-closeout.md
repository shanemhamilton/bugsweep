# Tracker resolution and run closeout

Use this protocol before preflight and after `finalize.sh`. Its job is to make each run
operationally complete without turning `.bugsweep/state/` into a second issue tracker or
leaving disposable Git refs behind.

## Resolve one system of record before preflight

Choose the first source that explicitly identifies the project's tracker:

1. A tracker item, provider, project, or workspace named by the user or invocation.
2. Repository instructions such as `AGENTS.md`, `CLAUDE.md`, or contributing docs.
3. Repository-local Beads, but only when `.beads/` exists and `bd` is callable.

Hosting is not evidence of tracker use. A GitHub remote does not prove GitHub Issues is the
system of record; likewise, do not infer Linear or Jira without project evidence. If several
trackers are documented, use the one named for bugs/engineering work. Never create the same
finding in several systems.

Use the project's existing CLI, connector, or app. Do not install an SDK or write a provider
adapter. Before preflight, perform a read-only lookup and verify that the available interface
supports create/update and readback. If no single tracker can be resolved, stop before any
branch is created and ask the user to name the system of record.

At the start of a later run, retry any `.bugsweep/state/tracker-outbox.jsonl` entries before
preflight. Use their original idempotency keys; do not create a new branch while a prior
closeout is incomplete.

## What becomes a ticket

Create or update work for:

- confirmed bugs not fixed because the run was detect-only or below the fix floor;
- quarantined fixes, regressions, unavailable execution/native-review evidence, approval
  declines/timeouts, and provider check `PROOF_ERROR` results;
- a landing/cleanup failure that leaves actionable code work;
- `closeout_unexpected_dirt` escrowed by `finalize.sh`;
- one run-level follow-up item for an incomplete audited frontier when the project expects
  Bugsweep to continue later.

Do not ticket rejected candidates, style observations, or one ticket per unreviewed batch.
Uncovered batches belong in a single run follow-up, not in speculative bug tickets.

## Idempotent upsert and readback

Derive a stable key from repository identity plus the finding's normalized root cause and
primary location. Reuse the ledger's stable finding key when present. Search the chosen
tracker for that key before creating; update an existing open item instead of duplicating it.

Each bug item includes:

- Bugsweep stable key and run ID;
- severity, category, affected file/line, and full architectural path when applicable;
- concrete trigger, bad outcome, root cause, and evidence;
- verification result and why it did not land;
- minimal proposed fix and focused checks;
- report path and recovery-bundle path/digest when code was escrowed.

After every create/update, read the item back. Append one JSON line to
`<RUN_DIR>/tracker-receipts.jsonl` with `provider`, `project`, `item_id`, `url` when
available, `finding_key`, `operation`, and `readback_verified: true`. Append a matching
`tracker_recorded` ledger event. A command reporting success without readback is not a
receipt.

When unique commits are escrowed, the verified receipt must also contain
`recovery_bundle` with the exact `<RUN_DIR>/recovery.bundle` path and `recovery_sha256`
with that file's SHA-256 digest. Closeout binds both fields to the independently reviewed
branch tip before allowing deletion.

Every `fixed`, `quarantined`, and `confirmed_unfixed` bug ID on an unlanded branch must have
a matching receipt `finding_key` (or `bug_id`). When `follow_up[]` is non-empty, also write
one run-level receipt keyed `run:<run-id>:follow-up`. `closeout.sh` refuses discard if any
required key is missing.

If the tracker becomes unavailable, append the same intended payload and idempotency key to
`.bugsweep/state/tracker-outbox.jsonl`, set the outcome to `INCOMPLETE_TRACKER`, and preserve
the verified recovery bundle. The per-run marker under
`.bugsweep/state/closeout-blocked/<run-id>.json` keeps later preflight blocked. Never claim
the tracker write happened.

## Branch disposition

Classify from `run-summary.json` and the exact state in `state.env`; never select a branch by
timestamp, newest commit, or `bugsweep/*` glob.

### Verified fixes can land

Use `scripts/integrate.sh` with the recorded original target and exact run branch. It
constructs the merge away from the target ref, runs the post-merge quality gate, and
advances the target with compare-and-swap. Then run
`scripts/closeout.sh <RUN_DIR> landed`; it proves containment and removes only the exact
owned worktree and branch. Closeout also reads `integrate-results.json`, the Referee
verdict events, and approved-mode approval events; Git ancestry alone is insufficient.
The integration receipt must name the exact source tip, gated target tip, and gate command.
An already-contained branch is re-gated to produce current evidence. Verdict and approval
events must occur in the required order before reproduction or mutation. After every
multi-fix integration, re-run each original regression test against the final combined tree
with a new `reverify <RUN_DIR> <BUG_ID> <SHA>` request and preserve its separate
`fix_reverified` receipt; it does not replace the original red/green proof.
This is local only; never push as part of Bugsweep closeout.

### No unique commits

Run `scripts/closeout.sh <RUN_DIR> recorded`. It proves the exact branch is contained and
that `run-summary.json` has no actionable unresolved work before removing owned resources.

### Unique commits cannot land

Before discarding anything, escrow and verify recovery outside the linked worktree:

```bash
git bundle create "<RUN_DIR>/recovery.bundle" "refs/heads/<EXACT_RUN_BRANCH>"
git bundle verify "<RUN_DIR>/recovery.bundle"
git rev-parse "<EXACT_RUN_BRANCH>" > "<RUN_DIR>/recovery.tip"
(sha256sum "<RUN_DIR>/recovery.bundle" 2>/dev/null \
  || shasum -a 256 "<RUN_DIR>/recovery.bundle") > "<RUN_DIR>/recovery.bundle.sha256"
```

Record the bundle path, tip, and digest in the tracker item or durable outbox. Then obtain a
fresh independent review of the exact branch, impact, and recovery commands. Write
`<RUN_DIR>/deletion-review.json` with `approved: true`, the exact `branch`, exact `tip`, and
`bundle_sha256`. Finally run `scripts/closeout.sh <RUN_DIR> recorded`. It verifies the
tracker readback, bundle, review, and clean worktree before exact discard. If independent
review is unavailable, do not delete unique work; return `INCOMPLETE_CLEANUP` and block the
next preflight. Never remove a dirty worktree; restore or narrowly commit its owned changes
first.

Recovery is explicit:

```bash
git fetch "<RUN_DIR>/recovery.bundle" \
  "refs/heads/<EXACT_RUN_BRANCH>:refs/heads/recovered/<run-id>"
```

## Terminal readback

Check the exact branch ref and exact canonical worktree path from `state.env`. Also confirm
the user's checkout branch/status equals the preflight snapshot. Do not use a zero count of
all `bugsweep/*` branches as proof; older/user-owned refs are outside this run.

- `COMPLETED_LANDED`: verified changes are on the recorded local target, tracker receipts
  cover any remaining action, and no run-owned Git resource remains.
- `COMPLETED_RECORDED`: all action is read back from the tracker with verified recovery where
  needed, and no run-owned Git resource remains.
- `INCOMPLETE_TRACKER`: a tracker write/readback remains queued. Never call this done.
- `INCOMPLETE_CLEANUP`: the exact branch/worktree or user-checkout restoration is unresolved.
  Never create another Bugsweep branch until it is reconciled.

On either incomplete outcome, keep the run's marker under `closeout-blocked/`;
`preflight.sh` refuses another run while any marker exists. `closeout.sh` removes only its
own marker after tracker and exact-resource readback both succeed.

Normal exits route through closeout. An interrupt or hard kill can bypass in-process cleanup;
the next ordinary invocation blocks on stale exact-owned state before creating a new branch.
Do not promise immediate cleanup after a signal.
