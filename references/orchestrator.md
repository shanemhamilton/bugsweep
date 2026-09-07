# Orchestrator contract — fanning out N worktree-isolated subagents

This is the playbook for the pattern `references/autonomous-maintenance.md` doesn't cover:
one Opus (or equivalent) **orchestrator** session that fans out up to 5 worktree-isolated
bugsweep subagents to find and fix bugs in parallel, then reviews and locally integrates
eligible results — while the orchestrator itself never hunts. If you want a single sequential
`/bugsweep --autonomous` run on a schedule, see `references/autonomous-maintenance.md`
instead; this doc is for the multi-subagent fan-out case.

Every mechanic below is cited to a real script/flag/field in this repo. Nothing here invents
a flag, a code, or a file that doesn't exist — see the failure-taxonomy table for grep
evidence on every stable token.

## The contract, in one paragraph

The orchestrator partitions the hunt frontier across N ≤ 5 subagents
(`scripts/partition.sh`), dispatches each one into its own isolated git worktree
(`scripts/preflight.sh --worktree --concurrent`) to run a normal `/bugsweep --autonomous` (or
`--approve`) loop, and then — critically — **does not hunt itself**. It waits for each
subagent to finish, reads its `<RUN_DIR>/run-summary.json` (never its own re-derivation of
findings), decides fix order and integration order from that machine-readable contract,
integrates eligible branches one at a time, preserves each original red/green proof, and
re-verifies every original regression test against the final combined tree. A remote push is
separate from Bugsweep. Before ending, it writes down the combined follow-up frontier so the next
session (human or orchestrator) knows exactly where coverage is still thin.

## Step 1 — Create one orchestrator-owned coordination directory

`scripts/partition.sh`'s `shard` mode needs a directory to resolve the hunt frontier from,
**before** any subagent has run `context-build.md` (so no subagent's own `<RUN_DIR>` exists
yet to hand it). `partition.sh frontier`/`shard` only requires the directory to exist
(`[ -d "$run_dir" ]` — `scripts/partition.sh:100,118`) — it does not need to be a
preflight-created run dir with `state.env`. Create one plain directory for this orchestrator
invocation, e.g.:

```bash
ORCH_DIR=".bugsweep/orchestrator-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ORCH_DIR"
```

This same directory is reused for two more things below (the shared rollup file, and
`integrate.sh --run-dir`), so one directory carries the whole orchestrator session's state.
It lives under `.bugsweep/`, which is already git-ignored (`.gitignore:2`).

## Step 2 — Partition the frontier: `scripts/partition.sh`

Real interface (`scripts/partition.sh:13-16`):

```text
partition.sh frontier <RUN_DIR>                  list batch ids, one per line, in frontier order
partition.sh shard    <RUN_DIR> <N> <INDEX>       deterministic pre-partition: batch ids for shard INDEX (0-based) of N
partition.sh claim    <RUN_ID> <RUN_DIR> [OWNER]  atomically self-claim the next unclaimed batch id
partition.sh claims   <RUN_ID>                    list already-claimed batch ids for RUN_ID
```

Two coordination modes (`scripts/partition.sh:18-28`):

- **Shard (orchestrator-driven, recommended default).** Call `shard <ORCH_DIR> <N> <I>` once
  per subagent, up front, before dispatch (`I` = 0..N-1). It's a pure function of
  `(frontier, N, index)` — no shared state, no locking, byte-identical on repeated calls
  (verified by `tests/bats/partition.bats`'s determinism test). The first call generates
  `<ORCH_DIR>/recon-plan.json` on the fly via `recon-plan.sh` + `git ls-files`
  (`scripts/partition.sh:79-90`); every later call reuses it. Hand subagent `I` its exact
  batch-id list as part of its dispatch prompt.
- **Claim (self-claim, for uneven batch sizes).** Pick one `RUN_ID` string shared by every
  subagent in this wave (e.g. the orchestrator's own session id). Each subagent repeatedly
  calls `claim <RUN_ID> <ITS_OWN_RUN_DIR>` — using its **own** `<RUN_DIR>` (from its own
  `preflight.sh --worktree --concurrent`, once that exists) is fine here even though every subagent's
  `<RUN_DIR>` is a different path: `recon-plan.sh`'s determinism contract guarantees every
  sibling independently computes the same batch-id set in the same order, so the shared
  claims registry (keyed by `RUN_ID`, not by `RUN_DIR`) is a valid coordination point
  regardless of which `RUN_DIR` each caller passes. A subagent hunts whatever batch id
  `claim` returns (`CLAIMED_BATCH=<id>`) and calls `claim` again for the next one, until it
  gets `NO_BATCHES_LEFT=1`.

**Important gap to be honest about:** `partition.sh` computes the assignment, but
`prompts/context-build.md` and `prompts/hunt.md` have no built-in "only process these batch
ids" flag — `context-build.md` processes every non-deferred batch "in `recon.json`'s order"
(verified: `prompts/context-build.md:141`). The orchestrator's dispatch prompt to each
subagent must explicitly state the restriction ("hunt only batch ids: 2, 5, 9, ...") as an
instruction the subagent follows, not something a script enforces for it.

## Step 3 — Dispatch each subagent: `scripts/preflight.sh --worktree --concurrent`

`--worktree --concurrent` mode is what makes intentional fan-out safe:

- Cuts a **new linked git worktree** under `<main-repo-root>/.bugsweep/worktrees/<id>`, on a
  collision-free branch `bugsweep/<ts>-<pid>-<rand>` cut from the user's current HEAD.
- **Never reads, stashes, or switches** the user's own working tree/branch/index — the
  worktree is cut straight from HEAD, so there's nothing to restore and `STASH=none` is
  reported.
- The protected-branch-dirty guard is **skipped** in this mode (nothing to entangle —
  `scripts/preflight.sh:93-100`). The retired `bugsweep-prepare.sh` helper does not apply;
  current maintenance guidance requires worktree isolation and leaves the user's checkout
  untouched.
- `id` = timestamp + pid + short random suffix, so simultaneous starts (the norm when 5
  subagents launch together) never collide, even under pid reuse.
- The tested/documented concurrency ceiling is **5** siblings (`scripts/preflight.sh:15,240,337-338`)
  — this is the assumption the locking/lease/index-write paths were hardened against, not a
  hard-enforced config cap. Staying at N ≤ 5 is a recommendation grounded in what's actually
  been reviewed for this concurrency level, not an arbitrary number.

Stable output contract (`scripts/preflight.sh:392-396,400`): `RUN_DIR=`, `BRANCH=`,
`ORIG_BRANCH=`, `STASH=`, `WORKTREE=<path>` (worktree mode only), then `PREFLIGHT_OK`.

Each subagent then runs the **normal, unmodified** bugsweep loop inside its worktree
(`/bugsweep --autonomous` or `--approve`, scoped to its assigned batch ids per Step 2) —
context-build → research → hunt → challenge → referee → fix → `guard.sh` → finalize. Nothing
about the hunt/fix/finalize loop itself changes for worktree mode.

## Step 4 — The orchestrator does not hunt. It waits, then reads.

This is the core rule from the problem statement: **the orchestrator is not a hunter.** It
never runs context-build/hunt/challenge/referee itself. Its only inputs are each finished
subagent's on-disk artifacts.

### The fast path: one shared rollup file across all N subagents

`finalize.sh` has an existing, opt-in, concurrency-safe digest mechanism built for exactly
this (bugsweep-6w8, `scripts/finalize.sh:342-424,637`): set `BUGSWEEP_ROLLUP_FILE` to a
shared path and every subagent's `finalize.sh` call appends one line to it. The append is a
single `printf ... >> "$rollup_file"`, which is atomic under `PIPE_BUF` on every POSIX
filesystem, so concurrent finalize calls from different worktrees never interleave
(`scripts/finalize.sh:550-552`). Point it at the orchestrator's coordination directory:

```bash
BUGSWEEP_ROLLUP_FILE="${ORCH_DIR}/rollup.log" bash scripts/finalize.sh "<SUBAGENT_RUN_DIR>"
```

**Operational note:** the Bash tool's shell state does not persist across separate tool
calls, so tell each subagent to set this inline on the exact command line that invokes
`finalize.sh` (as above), not via a separate `export` in an earlier call.

Each line has this exact shape (`scripts/finalize.sh:543-548`):

```text
<date> <repo> <branch> - confirmed C/H/M/L - fixed F quarantined Q - coverage x/y - <stop_reason> - ACTION: land|discard|review (<report path>)
```

`ACTION` is derived straight from `run-summary.json`'s arrays, most-actionable first
(`scripts/finalize.sh:362-373,524-531`):

| fixed[] | confirmed_unfixed[] or quarantined[] | ACTION |
|---|---|---|
| non-empty | (either) | `land` — real fix commits worth integrating |
| empty | non-empty | `review` — findings exist but nothing to merge; needs a human/orchestrator call |
| empty | empty | `discard` — clean run, nothing to do |

Use this to triage fast: `ACTION=land` branches are integrate candidates (Step 5);
`ACTION=review` branches contribute to the follow-up frontier (Step 6) but aren't merge
candidates themselves; `ACTION=discard` branches need no further action.

### The detailed path: each subagent's `run-summary.json`

For fix ordering and root-cause judgment, read every subagent's
`<RUN_DIR>/run-summary.json` (schema: `schemas/run-summary.schema.json`). Required fields
(`schemas/run-summary.schema.json:8-19`): `schema_version`, `mode`, `status`, `stop_reason`,
`coverage`, `counts`, `fixed`, `quarantined`, `confirmed_unfixed`, `findings`.

- **`status`** is one of `complete` / `partial` / `stalled`
  (`schemas/run-summary.schema.json:28-31`) — see the taxonomy table for exactly what
  triggers each.
- **`root_cause_clusters[]`** (optional, `schemas/run-summary.schema.json:97-114`) — this is
  the "spot broader issues" signal. Confirmed/fixed findings sharing a category (or
  `category::variant`) cluster together; singletons are excluded; ordered size-descending.
  A cluster of size ≥ 2 across a subagent's findings (or, more usefully, across *multiple
  subagents'* findings once you've read them all) is the orchestrator's evidence for "this
  isn't one bug, it's a pattern" — worth a systemic fix or a dedicated follow-up thread
  rather than N one-off patches.
- **`follow_up[]`** (optional, `schemas/run-summary.schema.json:115-131`) — the "where to
  look next" handoff: `kind` is one of `uncovered_batch` / `stale_file` / `high_risk_file` /
  `quarantined`, ordered exactly that way and capped at `FOLLOW_UP_CAP` (50,
  `bench/scorer/run_summary.py:132`). Union every subagent's `follow_up[]` for Step 6.
- **`flaky[]`** is retained in the summary schema for old runs only. The current structured
  check gate does not classify later passes as a waiver: a newly observed failing, missing, or
  skipped native identity remains a regression.

## Step 5 — Decide fix order, then integrate: `scripts/integrate.sh`

`integrate.sh` (bugsweep-5e8) merges an **ordered** list of already-verified branches into a
target one at a time, re-running the quality gate after **each** merge, and stops cleanly
(preserving every remaining branch) on the first conflict or regression
(`scripts/integrate.sh:1-25`). The orchestrator supplies the order — that's the "orchestrator
decides fix order" part of the contract. A reasonable default: land `ACTION=land` branches
first, most `counts.critical`/`counts.high` first (or fewest touched files first, to
minimize conflict surface) — this ordering heuristic is orchestrator judgment, not something
`integrate.sh` itself decides.

Real usage (`scripts/integrate.sh:36`):

```bash
bash scripts/integrate.sh [--run-dir RUN_DIR] [--delete-merged] <target-branch> <branch1> [branch2 ...]
```

**Always pass a dedicated provider-prepared `--run-dir "$INTEGRATION_RUN_DIR"`.** It is not
the plain coordination directory. Before merging, start an isolated worktree from the target
branch with the operator-owned execution policy, then use that run's prepared `check-plan.json`
and provider-verified `baseline.json`. `integrate.sh` requires both files and rejects a plain
directory (`scripts/integrate.sh:112-116`):

```bash
git checkout "$TARGET_BRANCH"
bash scripts/preflight.sh --worktree --execution-policy /absolute/external-policy.json
# Read RUN_DIR and WORKTREE from preflight output.
INTEGRATION_RUN_DIR="<RUN_DIR>"
bash scripts/run_checks.sh baseline "$INTEGRATION_RUN_DIR"
```

The frozen plan records the native check commands, source identity, and required-untrusted
provider policy. `integrate.sh` exports each merged tree and runs those same frozen native
checks through that provider; it does not run a host shell command or accept a legacy quality
gate override. Keep `ORCH_DIR` for partitioning and rollups, and read integration receipts from
`$INTEGRATION_RUN_DIR/integration-check-results/`.

`integrate.sh` runs from the orchestrator's own main-repo checkout (not inside any
subagent's worktree) — branches created in a linked worktree are ordinary refs, visible and
mergeable from the main checkout like any other local branch.

Per-branch outcome codes (`scripts/integrate.sh:199-291`, printed as
`BRANCH_RESULT=<branch>:<code>`): `merged`, `already_contained`, `conflict`, `gate_failed`,
`gate_dirtied_tree`, `update_failed`, `skipped_after_stop`. Overall
`INTEGRATE_RESULT=complete` or `INTEGRATE_RESULT=stopped` (exit 1 on `stopped`), plus
`STOPPED_AT=`, `MERGED_COUNT=`, `ALREADY_CONTAINED_COUNT=`, `PRESERVED_COUNT=`,
`RESULTS_JSON=<path>` (`scripts/integrate.sh:508-525`). On `stopped`, every remaining branch
is preserved untouched for the orchestrator to reorder or defer to the follow-up frontier —
never re-run blindly with the same order.

`--delete-merged` deletes a branch only after merge-base containment proof, never a force
operation (`scripts/integrate.sh:350-366`).

## Step 6 — Optional remote delivery

`integrate.sh` never pushes (`scripts/integrate.sh:45-47`) — advancing the target branch
locally is as far as any script in this repo goes. Pushing the target remains a separate,
explicit action outside Bugsweep closeout. After `INTEGRATE_RESULT=complete`, review the
resulting diff and `report.md` from each landed subagent. Do not push a target that stopped
mid-integration, and never force-push.

## Step 7 — Teardown

`finalize.sh` is not teardown. For every subagent, call `closeout.sh <RUN_DIR> landed` after
successful integration, or `closeout.sh <RUN_DIR> recorded` after tracker readback and
verified recovery escrow. The session is incomplete while any subagent's exact branch,
worktree, or closeout-blocked marker remains. `bugsweep-cleanup.sh --reap-worktrees` is a
manual, preserve-biased crash-recovery tool, not a substitute for tracker closeout.

## Step 8 — Record follow-up and close every run

Union every subagent's `follow_up[]` and note every `root_cause_clusters[]` entry of size ≥ 2.
Follow [`tracker-closeout.md`](tracker-closeout.md): idempotently upsert the project's
existing tracker, read back receipts, then land or escrow/discard every exact run branch.
Use one run-level item for uncovered frontier and distinct items for confirmed bugs; do not
turn every unreviewed batch into a speculative bug. The session is successful only when
each subagent is `COMPLETED_LANDED` or `COMPLETED_RECORDED` with no owned Git resources.

---

## Copy-paste orchestrator prompt

```text
Run bugsweep as an orchestrator across this repository. Fan out up to 5 worktree-isolated
bugsweep subagents to find and fix bugs in parallel. You are the orchestrator — you do NOT
hunt for bugs yourself. Each subagent runs its own full hunt/fix/finalize loop
(/bugsweep --autonomous or --approve) inside an isolated git worktree
(scripts/preflight.sh --worktree --concurrent). Your job is only to:

1. Partition the hunt frontier across the subagents so they cover disjoint batches
   (scripts/partition.sh shard|claim), then dispatch them with their assigned batch ids.
2. Wait for each subagent to finish, then read its <RUN_DIR>/run-summary.json — never
   re-derive its findings by hunting yourself. Use root_cause_clusters to spot broader,
   systemic issues (not just one-off bugs) and use follow_up plus each subagent's
   quarantined/confirmed_unfixed findings to build the next-session frontier.
3. Review every subagent's fixes (diff + report.md) before integrating — do not blind-merge.
   Decide integration order yourself, then integrate the verified branches with
   bash "$SKILL_ROOT/scripts/integrate.sh" --run-dir <INTEGRATION_RUN_DIR> <target> <branch1> [branch2 ...],
   which re-runs the quality gate after every merge and stops cleanly on the first conflict
   or regression.
4. After each integration, run `python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" reverify <RUN_DIR> <BUG_ID> <SHA>` and then `bash "$SKILL_ROOT/scripts/repro.sh" reverify <RUN_DIR> <BUG_ID> <REQUEST_PATH>` for every original regression test. Preserve each separate `fix_reverified` receipt.
5. Upsert unresolved findings and the combined follow-up frontier into the project's
   documented tracker with stable keys and readback receipts. Escrow and discard any exact
   run branch that cannot land, following the independent deletion check.
6. End only after exact readback proves every run-owned branch/worktree is absent. Do not
   push as part of Bugsweep closeout; never force-push or skip a failed gate.

Constraints: never touch the user's real branch/tree from inside a subagent (that's what
--worktree isolation is for); never bypass the frozen provider check gate; never delete by prefix;
delete an uncontained exact run branch only after verified recovery escrow, tracker/outbox
receipt, and independent review; on the first INTEGRATE_RESULT=stopped, stop integrating
rather than reordering blindly, then record and close out the remaining branches.
```

This encodes the four required elements: **up to 5 subagents** (step 1 / opening line),
**orchestrator does not hunt** (opening line, step 2), **review and final-tree reverify
before optional delivery** (steps 3-5), and **follow-up planning** (step 5).

## Orchestrator checklist

- [ ] `mkdir -p "$ORCH_DIR"` — one coordination directory for this session.
- [ ] Partition the frontier: `partition.sh shard "$ORCH_DIR" <N> <I>` per subagent (N ≤ 5),
      or agree a shared `RUN_ID` for self-claim mode.
- [ ] Dispatch each subagent with its batch-id list; each runs
      `preflight.sh --worktree --concurrent` → normal hunt/fix loop →
      `BUGSWEEP_ROLLUP_FILE="$ORCH_DIR/rollup.log" bash "$SKILL_ROOT/scripts/finalize.sh" "<its RUN_DIR>"`.
- [ ] Do not hunt. Read `$ORCH_DIR/rollup.log` for fast triage (`ACTION=`), then each
      subagent's `run-summary.json` for `root_cause_clusters`/`follow_up`/full findings.
- [ ] Create the dedicated target-based provider run, then keep its frozen plan and verified
      baseline in `$INTEGRATION_RUN_DIR` before the first integration.
- [ ] Decide integration order from the findings just read.
- [ ] `bash "$SKILL_ROOT/scripts/integrate.sh" --run-dir "$INTEGRATION_RUN_DIR" "$TARGET_BRANCH" <branches...>`.
- [ ] For each original test: `python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" reverify "<ORIGINAL_RUN_DIR>" <BUG_ID> <SHA>`, then `bash "$SKILL_ROOT/scripts/repro.sh" reverify "$ORCH_DIR" <BUG_ID> <REQUEST_PATH>`.
- [ ] Review the diff/report and final-tree reverify receipt for every merged branch before optional delivery.
- [ ] `git push` (no `--force`) only after review passes.
- [ ] Run `bash "$SKILL_ROOT/scripts/closeout.sh" <RUN_DIR> landed|recorded` for every subagent.
- [ ] Upsert the combined follow-up frontier and unresolved findings in the documented tracker.
- [ ] Read back tracker receipts and prove every exact run branch/worktree is absent.

## Failure taxonomy

Stable codes an orchestrator can branch on, and exactly what emits each one. Every entry
below is grep-verified against the script that emits it — see the cited script:line/token.
Where a candidate name from the problem statement doesn't correspond to a real emitted
token, that's called out explicitly rather than invented.

| Code / signal | Emitted by | Meaning | Orchestrator action |
|---|---|---|---|
| `PROOF_ERROR` | `scripts/_proof.py` check gate | The frozen plan, source identity, provider receipt, native result, or baseline cannot be verified. | Do not integrate. Preserve the run and route the missing evidence or provider failure for human action. No host-shell or degraded fallback is allowed. |
| `REGRESSION` | `scripts/_proof.py` check gate | A native check/test identity is newly failing, missing, or changed from a prior pass. A later passing run does not waive the observed regression. | Quarantine the owned change as required by `prompts/fix.md`; preserve the receipt and recovery state. |
| `quarantine` (ledger event) | Recorded by the fix/closeout flow and reduced into `run-summary.json` | An attempted fix cannot land because its required evidence or final verification failed. | Treat it as a tracker follow-up with its immutable proof or failure receipt; do not retry by weakening the provider requirements. |
| `OK` | `scripts/_proof.py` check gate | The provider verified the frozen check plan against the current source with no newly failing native identity. | Continue only to the separate immutable repro and review gates; `OK` alone never authorizes a fix or integration. |
| `status: "complete"` | `bench/scorer/run_summary.py:185` (report.md was written; `report_is_stub=false`) | The subagent finished normally and wrote a real report. `stop_reason` is `null`. | Normal — read `findings`/`fixed`/`quarantined` as usual. |
| `status: "partial"` | `bench/scorer/run_summary.py:186-187`, `stop_reason` = the fixed string at `bench/scorer/run_summary.py:118-121` | `report.md` was never written (stub), but **some** hunt batches were covered before stopping. The candidate name "PARTIAL_TIMEOUT" is **not accurate as literally named** — this status is not specifically about a timeout; it fires for any mid-hunt stop (context-build stall, crash, etc.) as long as `covered > 0`. | Treat as a run that needs a follow-up pass on its uncovered batches (`follow_up[kind=uncovered_batch]`); do not assume it exhausted its frontier. |
| `status: "stalled"` | `bench/scorer/run_summary.py:186,188`, `stop_reason` = the fixed string at `bench/scorer/run_summary.py:114-117` | `report.md` was never written **and** zero batches were covered. This is the real analog of the candidate name "STALLED_NO_REPORT." | The subagent made no progress at all — re-dispatch its whole shard rather than treating it as partially done. |
| `STOP <reason>` (mid-loop, distinct from the above) | `scripts/guard.sh:63-68`: `iteration_cap_reached(i/max)`, `runtime_cap_reached(elapsed/max,...)`, `fix_cap_reached(f/max)`, `converged_no_new_bugs(streak=n)` | Loop-level budget signal checked at phase boundaries. Runtime/iteration/convergence finalize; `fix_cap_reached` switches to detect-and-record mode. This differs from `run-summary.json.stop_reason`, which reflects report completeness. | Respect the exact reason. Never stop discovery merely because the mutation cap was reached, and never claim uncovered frontier as complete. |
| `CLEANUP_RESULT=conflict` | `scripts/bugsweep-cleanup.sh:1173` | The single-branch merge gate (`bugsweep-cleanup.sh`, not `integrate.sh`) hit a merge conflict. | Same remediation as `integrate.sh`'s `conflict` below — this is the analog for the single-branch companion script, referenced in `references/autonomous-maintenance.md`, not the multi-branch orchestrator path. |
| `conflict` (per-branch, `BRANCH_RESULT=<branch>:conflict`) | `scripts/integrate.sh:227-232` | Merging this branch into the integration tip conflicted; aborted cleanly, branch preserved untouched, target ref never moved. The real analog of the candidate name "MERGE_CONFLICT" for the multi-branch orchestrator path. | Stop reordering blindly; ticket the conflict, escrow recovery, then close out the exact branch. |
| `CLEANUP_RESULT=tests_failed` | `scripts/bugsweep-cleanup.sh:1147,1154` | The optional `BUGSWEEP_TEST_CMD` re-verify failed before merge (single-branch companion script). The real analog of the candidate name "TESTS_FAILED." | Leave the branch for manual review; do not force. |
| `gate_failed` (per-branch) | `scripts/integrate.sh:254-259` | The multi-branch orchestrator's analog of `tests_failed`: the quality gate (which may include more than tests) failed after merging this branch; the merge commit is abandoned, target ref never moved. Note the **literal token differs** from `bugsweep-cleanup.sh`'s `tests_failed` even though the underlying condition is the same class of failure. | Stop integrating; ticket the failed gate, escrow recovery, and close out the exact branch. |
| `gate_dirtied_tree` (per-branch) | `scripts/integrate.sh:242-250` | The quality gate command left tracked or untracked changes in the tree — a contract violation (gate commands must be tree-neutral). | This means the repo's own test/build command needs fixing (writes inside the repo instead of outside it) — not something to retry as-is. |
| `update_failed` (per-branch) | `scripts/integrate.sh:279-286` | A concurrent process advanced the target branch out from under this integrate run (compare-and-swap on `update-ref` failed). Never reported as `merged` in this case. | Re-run integrate.sh after confirming no other process is also integrating into the same target — this repo's integrate flow is meant to be single-writer per target branch. |
| `REAP_RESULT=skipped_locked` | `scripts/bugsweep-cleanup.sh:1076` | The manual crash-recovery reaper found its coordination lock busy and skipped rather than proceeding unlocked. | Non-fatal; retry the explicit crash-recovery call after the other reaper finishes. |
| Worktree preserved as still-active | `scripts/bugsweep-cleanup.sh:618-625` (`ledger_active_within()`), surfaced via the `WORKTREES_PRESERVED=<n>` counter (`scripts/bugsweep-cleanup.sh:928`) | `--reap-worktrees` found a worktree whose `ledger.jsonl` was written within the grace window — the run looks alive despite a lapsed lease — and preserved it rather than reaping it. **Not a discrete top-level result code** (it's a per-worktree reason folded into `REAP_RESULT=ok`'s preserved count), but the closest real analog of the candidate name "DEFERRED_ACTIVE_TREE." | Leave it; a genuinely dead run is reaped automatically once its ledger goes quiescent past the grace window. |
| `RESULT=SKIP` (exit 10) | `scripts/bugsweep-prepare.sh:35,86-96` | Legacy helper output retained only for compatibility; current Bugsweep instructions never invoke this in-place dirty-tree workflow. | Do not route new runs through it. Use `preflight.sh --worktree`; use `--concurrent` only for intentional orchestrator fan-out. |

## Scheduling this orchestrator

Drop-in scheduled-task manifests (both clearly labeled templates — see each file's own
header for exactly what's verified vs. what you must fill in):

- `templates/scheduled-tasks/bugsweep-orchestrator.claude-scheduled-task.SKILL.md.template`
  — Claude Code scheduled-task format (frontmatter shape verified against this machine's
  installed `~/.claude/scheduled-tasks/*/SKILL.md`; the cron/interval trigger itself is
  registered separately through Claude Code's own scheduled-task tooling, not a field in
  this file).
- `templates/scheduled-tasks/bugsweep-orchestrator.codex-automation.toml.template` — Codex
  `automation.toml` format (top-level key set verified against this machine's installed
  `~/.codex/automations/*/automation.toml`; `created_at`/`updated_at` are tool-assigned).

Both embed the same copy-paste orchestrator prompt from this doc as their task body/prompt.
