---
name: bugsweep
description: >-
  Autonomous, adversarial bug-hunting and auto-fix pipeline for a codebase. Builds a
  frozen-scope architecture model, researches stack-specific anti-patterns, then finds
  runtime behavioral bugs (security vulnerabilities, logic errors, race conditions,
  error-handling gaps, data-integrity bugs, and large cross-file/architectural bugs) and,
  when asked, fixes them autonomously on an ephemeral git branch with auto-revert
  safety. Every run lands verified work or records remaining action in the project's
  existing tracker, then removes the exact branch/worktree it created. Uses an adversarial
  Hunter → Skeptic → Referee review to keep false positives low, and persists audit state
  to disk so long unattended runs survive context resets and learn across runs. Use this
  skill whenever the user wants to "find bugs", "hunt bugs",
  "audit the code", "deep code review", "check for vulnerabilities before shipping", "run
  an unattended/overnight audit", or "make sure bugs don't reach production" — even if
  they don't say "bugsweep".
---

# bugsweep

A safe, auditable, autonomous bug-hunting pipeline. It separates **finding** a bug from
**challenging** it from **confirming** it from **fixing** it, so the model never
rubber-stamps its own guesses; it builds frozen-scope context so it can catch large
cross-file bugs; it primes itself with anti-patterns common to the stack under review; and
it routes every irreversible git operation through deterministic shell scripts so the
safety guarantees never depend on the model's judgment. All progress is written to disk so
a long run can reset context and continue without losing work.

## The trust contract (read first — it governs everything)

Non-negotiable. Scripts in `scripts/` enforce the irreversible parts; you enforce the
rest. If a rule can't be honored, STOP and report — never work around it.

1. **Isolate every run.** Preflight creates one exact `bugsweep/<run-id>` branch in a
   Bugsweep-owned linked worktree. Never switch the user's checkout or infer ownership from
   the `bugsweep/*` prefix. Persist the exact branch, worktree, base SHA, and original target.
2. **No Git remotes.** During preflight, hunt, fix, finalize, and closeout: no
   push/pull/fetch, PR, or force-push. Local integration is allowed only in fix modes after
   the configured quality gate. Project-tracker upserts are allowed; they are not permission
   to mutate source-control remotes or unrelated external state.
3. **Delete only owned disposable state.** No `git reset --hard` on user content, no
   history rewriting, and no wildcard/prefix cleanup. The only uncontained branch that may
   be discarded is the exact current run branch, after a verified recovery bundle and a
   tracker receipt exist. Follow the independent destructive-action check in
   [tracker-closeout.md](references/tracker-closeout.md).
4. **Preserve the user's work.** Worktree preflight never stashes, commits, switches, or
   cleans the user's checkout. Its starting branch, index, and files remain unchanged.
5. **One bug, one commit, auto-revert on regression.** Re-run checks after each fix; if a
   fix introduces a new failure that survives the flaky check below, revert it and
   quarantine the bug. A newly-failing test is reran `.verify.flaky_reruns` (default 3)
   times before that decision: only a **strict majority of rerun passes** reclassifies it
   as FLAKY and excludes it from the revert; a tie or a majority of rerun failures still
   reverts. **Precise, non-overclaimed safety:** the reruns share the initial run's
   working tree/environment (no per-rerun isolation), so this distinguishes "failed the
   majority of reruns" from "passed the majority" — NOT truly "deterministic" from
   "flaky." A monotonic **state-pollution** bug (a broken fix whose first run fails but
   leaves a marker/cache that makes later runs pass) can be misclassified as flaky; the
   majority vote raises the bar but does not eliminate this. Therefore **any fix that
   lands with a flaky classification is loudly surfaced** (flaky.jsonl + ledger +
   run-summary + the `FLAKY=`/`FLAKY_TEST=` lines) and must be reviewed — it is never
   silent. Full per-rerun isolation is a documented **future enhancement** (deferred to a
   follow-up bead). See `scripts/run_checks.sh` for the full mechanics and its baseline-flaky
   limitation.
6. **Fix only confirmed bugs** — findings must pass the full adversarial review first.
7. **Minimal surgical fixes only.** No refactoring, renaming, reformatting, or unrelated
   changes.
8. **Stay inside the caps** (iterations, runtime, fixes) and stop when converged.
9. **Everything is logged** to the run ledger so an overnight run is auditable.
10. **Close the loop.** Every confirmed-but-unfixed or quarantined bug is idempotently
    created or updated in the project's existing tracker. A run succeeds only as
    `COMPLETED_LANDED` or `COMPLETED_RECORDED`, and only after exact readback proves its
    branch and worktree are gone. Tracker or cleanup failures are incomplete, never done.

Rule 4 is implemented with `preflight.sh --worktree` for every run: no stash is taken and
none is needed; the user's branch, index, and files stay byte-for-byte untouched until an
authorized local integration at closeout.

Cross-run learning lives in `.bugsweep/state/`, not in temporary branches. Pruning a run
branch never erases coverage, risk, conclusions, variants, or tracker receipts.

## Modes

Parse the invocation; default to the SAFEST reading when ambiguous.

| Invocation | Behavior |
| --- | --- |
| `/bugsweep` | **Detect only.** Bounded planned audit, tracker upsert, no source changes. (Default.) |
| `/bugsweep --fix` | Find + adversarial-confirm + fix, locally integrate verified work, and clean up. Single bounded pass. |
| `/bugsweep --approve` | Like `--fix`, but PAUSE for the user's OK before each fix. |
| `/bugsweep --autonomous` | Find + confirm + fix, then **loop** until clean or a cap, with periodic context checkpoints/resets. The unattended/overnight mode. Implies `--fix --loop`. |
| `/bugsweep <path>` | Scope to a file or directory (combine with any flag). |
| `/bugsweep --severity <low\|medium\|high\|critical>` | Only fix bugs at/above this severity. |
| `/bugsweep --recall` | Also record plausible 50–67% confidence near-misses for human review; never fixes them. |
| `/bugsweep --update` | Update bugsweep to the latest version. Detects install location, runs `install.sh`, then exits. Re-invoke after updating. |

For unattended/overnight/"run all night"/fully autonomous behavior, use `--autonomous`.
Recommend a first-time `--approve` run to calibrate trust before `--autonomous`.

## Execution

### Step 0 — Preflight (deterministic safety setup)

**Version check (run this first, every invocation).** Detect the install location, compare
the local version against the published one, and handle `--update`:

```bash
# Locate the install — prefer Claude Code, fall back to Codex
_bs_dir=""
[ -d "$HOME/.claude/skills/bugsweep" ] && _bs_dir="$HOME/.claude/skills/bugsweep"
[ -z "$_bs_dir" ] && [ -d "$HOME/.codex/skills/bugsweep" ] && _bs_dir="$HOME/.codex/skills/bugsweep"

# Passive staleness check (non-blocking — a slow/offline network is silently ignored)
if [ -n "$_bs_dir" ]; then
  _bs_local=$(cat "$_bs_dir/VERSION" 2>/dev/null || echo "")
  _bs_remote=$(curl -sf --max-time 3 \
    https://raw.githubusercontent.com/shanemhamilton/bugsweep/main/VERSION 2>/dev/null || echo "")
  if [ -n "$_bs_local" ] && [ -n "$_bs_remote" ] && [ "$_bs_local" != "$_bs_remote" ]; then
    echo "⚠ bugsweep $_bs_remote is available (you have $_bs_local). Run /bugsweep --update to upgrade."
  fi
fi
```

**If `--update` was passed**, run the updater and stop — do not proceed to the hunt:
```bash
if [ -n "$_bs_dir" ]; then
  bash "$_bs_dir/install.sh"
  echo "✓ bugsweep updated. Re-invoke to start a fresh run on the new version."
else
  echo "✗ Could not locate bugsweep install (~/.claude/skills/bugsweep or ~/.codex/skills/bugsweep)."
  echo "  Re-install with: bash <(curl -fsSL https://raw.githubusercontent.com/shanemhamilton/bugsweep/main/install.sh)"
fi
# EXIT — do not run preflight or any hunt steps after --update
```

Before preflight, resolve exactly one project tracker and verify create/update plus readback
access. Follow [tracker-closeout.md](references/tracker-closeout.md). If no tracker is
documented or access cannot be verified, stop before creating a branch. Also snapshot the
exact initial local branch/worktree refs; this is ownership evidence, not a cleanup glob.

ALWAYS run preflight in the isolated worktree mode next, before reading any source file:
```bash
BUGSWEEP_LEASE_PID=$$ bash scripts/preflight.sh --mode detect --scope "<scope>" --worktree
BUGSWEEP_LEASE_PID=$$ bash scripts/preflight.sh --mode fix --scope "<scope>" --worktree
BUGSWEEP_LEASE_PID=$$ bash scripts/preflight.sh --mode approve --scope "<scope>" --worktree
BUGSWEEP_LEASE_PID=$$ bash scripts/preflight.sh --mode autonomous --scope "<scope>" --worktree
```
It verifies the repo is safe, leaves the user's checkout untouched, creates one isolated
worktree on `bugsweep/<run-id>`, and prints `RUN_DIR`, `BRANCH`, and `WORKTREE`. If it exits
non-zero, STOP and show the error verbatim. Capture all three; they are the only Git
resources this run owns. All artifacts live under `RUN_DIR`.

Preflight also persists `BUGSWEEP_DEADLINE_EPOCH` in `<RUN_DIR>/state.env`, derived from
`caps.max_runtime_minutes`. At every expensive phase boundary, call `guard.sh` and always
finalize on any `STOP*` result. Context-build's canonical checkpoint runs after **every**
batch, inside its own modeling loop (see Step 2 below and `prompts/context-build.md`'s
per-batch loop) — not once at the end and not "between large batches"; the hunt loop (Step
4) checks it at the start of every iteration and before each architectural target group or
coverage batch. Runtime, iteration, and convergence stops route through `finalize.sh`.
`fix_cap_reached` is different: it ends mutation but the remaining planned hunt continues
in detect-and-record mode:

```bash
guard_out="$(bash scripts/guard.sh "$RUN_DIR")"
case "$guard_out" in
  'STOP fix_cap_reached'*) DETECT_ONLY_REMAINDER=1 ;; # keep hunting; ticket further bugs
  STOP*) STOP_REASON="${guard_out#STOP }"; PROCEED_TO_CLOSEOUT=1 ;;
esac
```
When `PROCEED_TO_CLOSEOUT=1`, skip the remaining hunt phases and proceed directly to Step 5.

**The nightshift no-silence contract, stated honestly.** The guarantee that a wall-clock
deadline never produces silence comes from these VOLUNTARY, phase-boundary `guard.sh`
checks — the model checking in and choosing to finalize BEFORE its time budget runs out —
not from any mechanism that survives a hard process kill. No bash-level trap can catch an
interrupted phase here, because the expensive work between checkpoints is the *model's own
reasoning*, not a wrapped bash process; a `SIGKILL` of the agent (or an external harness
timeout) bypasses every checkpoint below it, the same way it bypasses any other in-process
cleanup. What this actually guarantees: as long as the model keeps following the
per-batch/per-iteration checkpoint discipline, it self-finalizes — emitting `report.md` +
`run-summary.json` — before its own internal deadline expires, instead of running the clock
to an external kill with nothing on disk.

**Operational corollary.** Because the guarantee depends on the model reaching its own
checkpoints before an external kill, whatever launches bugsweep as a subagent (an
orchestrator, a nightshift scheduler, a CI job) should set its own per-subagent wall-clock
limit *above* `caps.max_runtime_minutes`. `BUGSWEEP_DEADLINE_EPOCH` is the **inner** budget,
sized so bugsweep finishes and self-finalizes before any **outer** harness timeout fires —
it is not meant to race that outer timeout.

**Isolated runs (`--worktree`).** Every invocation uses `--worktree`; when several runs share
one repository (e.g. an orchestrator dispatching parallel subagents), preflight cuts each
run its own linked worktree under `.bugsweep/worktrees/` on a collision-free
`bugsweep/<ts>-<pid>-<rand>` branch and never touches the user's working tree, branch, or
index. An orchestrator must add `--concurrent`; ordinary runs omit it and block on any
prior mapped branch so an immediate crash retry cannot accumulate another branch. In this
mode `STASH=none` means "nothing to restore" (no stash is ever taken), not
"the tree was clean". Do all hunt/fix work inside the printed `WORKTREE=` path. Callers
should pass `BUGSWEEP_LEASE_PID=$$` so the run's lease tracks the shell that actually owns
the run (liveness for stale-lease reclaim). `finalize.sh` leaves the lease and exact owned
resources pending; `closeout.sh` releases the lease only after terminal readback.

**Crash recovery.** Normal runs never invoke the repository-wide reaper. They close only
their exact state-recorded branch/worktree through `closeout.sh`. The manual
`bugsweep-cleanup.sh --reap-worktrees` path exists only for abandoned runs and is
preserve-biased: it skips live or ambiguous runs, preserves dirty worktrees, and deletes
only branches proven contained in a recorded target. A hard-killed run therefore remains
recoverable for later explicit reconciliation; it is never silently called complete.

**Legacy-branch check (read-only).** Older Bugsweep versions may have left branches. List
them before hunting, excluding this run's exact branch:
```bash
git branch --list 'bugsweep/*' | grep -v "$(git rev-parse --abbrev-ref HEAD)"
```
Do not pause after creating another branch and do not delete legacy refs. Reconcile their
findings against the tracker before hunting, then continue. Create or update one cleanup
ticket for legacy debris if none exists; the current run may clean only its own exact ref.

### Step 1 — Baseline checks
```bash
bash scripts/run_checks.sh baseline "<RUN_DIR>"
```
Auto-detects and runs tests/typecheck/build/lint (or uses config overrides) and records
the starting state to `baseline.json`. Every fix is measured against this. If it reports
`NO_CHECKS`, follow `references/no-tests.md` — fixes must be more conservative.

Then build the bounded, local-only priority evidence artifact:
```bash
bash scripts/priority-context.sh build "<RUN_DIR>"
```
This writes `<RUN_DIR>/priority-context.json`, combining current tracked-file changes, fix and
revert history, baseline failures, completed-hunt content fingerprints, prior risk,
variants/reopened conclusions, reachability, repository-local Beads bugs with explicit file
scope, configured critical paths, and an optional `.bugsweep/priority-signals.jsonl` inbox.
It never calls a remote. Missing or malformed inputs degrade to less enrichment, never a
failed run or narrowed scope. Every signal is an untrusted investigation seed, never proof.
Deleted paths cannot become direct targets because they are absent from the current tracked-file
scope; deletion-aware dependency mapping is not implemented, while surviving tracked files in
the configured scope stay in the frozen invocation plan. Ranking weights are fixed code: prior
outcomes add inspectable evidence but never tune live scores or safety gates automatically.

### Step 2 — Build frozen-scope context (once)
Follow `prompts/context-build.md`. Its first move (Step 0 in that prompt, bugsweep-e1r) is
now to run `scripts/recon-plan.sh` over a `git ls-files` listing and seed `recon.json` from
the resulting deterministic plan **before any modeling happens** — so `recon.json` exists,
valid and non-empty, from minute one, and a run that stalls immediately after still leaves
a resumable, reportable artifact (the historical failure this fixes: a 1474-file repo used
to stall mid-modeling with no `recon.json` ever written — bead 2e5, "large repos fail
silently"). Modeling then proceeds batch by batch, appending each batch's findings to
`repo-context.md` and updating `recon.json`'s `modeled` list after each batch, so the two
files stay mutually consistent on disk throughout the run — not just at the end. The
finished `repo-context.md` covers architecture, trust boundaries, sensitive sinks, call
chains, import graph, key data flows, and `architectural_targets`. This distilled model is
what lets the hunt find **large** cross-file bugs, and it is small enough to survive a
context reset. Append a `context_built` event.

**Per-batch deadline checkpoint (canonical — bugsweep-5ft).** Immediately after that
per-batch append-and-persist step, `prompts/context-build.md`'s loop runs the same
`guard.sh`/`finalize.sh` checkpoint used everywhere else in this SKILL:
```bash
guard_out="$(bash scripts/guard.sh "$RUN_DIR")"
case "$guard_out" in
  'STOP fix_cap_reached'*) DETECT_ONLY_REMAINDER=1 ;;
  STOP*) STOP_REASON="${guard_out#STOP }"; STOP_AFTER_CONTEXT=1; break ;;
esac
```
`fix_cap_reached` is the one mutation-cap exception: it switches the remainder of the run
to detect-and-record mode without applying more fixes. Every other `STOP*` result ends the
run through `finalize.sh` immediately — do not start another batch. This is the **only**
deadline checkpoint context-build performs: there is no separate
"after context-build completes" check to reconcile with it, because the last batch's
checkpoint already covers that point, and there is no "between large batches" check either
— "between batches" **is** "after every batch." The identical `guard.sh`/`STOP*`/
`finalize.sh` pattern recurs at every later phase boundary: at the start of every hunt
iteration including iteration 1 (Step 4's loop-start check, which runs right after
research), and before each architectural target group or coverage batch inside the loop
(Step 4) — so a run that reaches the wall-clock deadline at any phase still produces a
partial, auditable output.

**Large-repo budget flag.** `scripts/recon-plan.sh` computes `large_repo_mode` and
`budget_batches` itself, from `batch_count` against a file-count threshold (`cfg_get
'.context.large_repo_file_threshold'`, default 800; first-pass cap `cfg_get
'.context.large_repo_first_pass_batches'`, default 40) — this is now known BEFORE modeling
starts, not after a full pass. If the plan's `large_repo_mode` is `true`, `recon.json` is
seeded with it immediately in Step 0 of `prompts/context-build.md`, and the
`large_repo_mode_activated` event
(`{"event":"large_repo_mode_activated","batch_count":<n>,"budget_batches":<n>}`) is
appended to the ledger as soon as the plan says so. This is a warning, not a stop — it
tells the loop when partial coverage is expected so it can emit an informative report
instead of silently running out of time. Batches beyond the cap are marked
`"deferred": true` in `recon.json`; `prompts/context-build.md` models only the
non-deferred batches this run and stops after the last one, so a large-repo run is bounded
instead of grinding through the whole tree. Deferred batches are never dropped — the
coverage-first frontier picks them up on a later run (and a batch the coverage-first pass
promotes to critical, e.g. a sink, is set `deferred: false` so it is always in-budget).

**Coverage-first scope (read `prior-coverage.json` next).** Preflight wrote
`<RUN_DIR>/prior-coverage.json` from bugsweep's cross-run state (`.bugsweep/state/`). By
this point `recon.json` already exists (seeded from the plan); prior coverage *reorders*
its batches in place: put never-audited, stale (older catalog version or audited too long
ago), high-risk, and all sink-bearing files in the critical tier; put
already-audited-and-fresh files in a final cheap re-confirmation tier. With no path argument,
the whole repo is in scope — Bugsweep finds latent bugs in old, unchanged code, it is not a
diff scanner. With `/bugsweep <path>`, only files under that path are coverage targets;
dependencies outside it may be read as context but never counted as covered or changed
unless the user expands scope. The selected scope is never permanently "done" while a
frontier remains. See `references/context-and-continuity.md`. (The per-batch
deadline checkpoint that guards this whole modeling phase is described above, right after
the batch loop it belongs to.)

### Step 3 — Research anti-patterns for this stack (once)
Follow `prompts/research.md`. Detect the languages/frameworks, load the matching catalogs
from `references/antipatterns/` (always include `generic.md`), optionally augment with
bounded web research if `research.allow_web_research` is true and a web tool exists, and
write `antipatterns.md` tailored to this repo. Append a `research_done` event.

### Step 4 — The loop
Repeat until a stop condition fires. At the start of each iteration:
```bash
guard_out="$(bash scripts/guard.sh "<RUN_DIR>")"
case "$guard_out" in
  'STOP fix_cap_reached'*) DETECT_ONLY_REMAINDER=1 ;;
  STOP*) STOP_REASON="${guard_out#STOP }"; break ;;
esac
```
The fix cap stops mutation, not discovery. Every other stop goes to Step 5. Otherwise run
one iteration:

**Optional pre-hunt analyzer seeding (bugsweep-042).** Before the first HUNT, if
`.analyzers.enabled` is `true` (default `false` — see `config/bugsweep.config.json`), run
`bash scripts/analyzers.sh "<RUN_DIR>"`. This best-effort step runs whichever off-the-shelf
static analyzers are installed (semgrep, gosec, bandit, ...) and writes `<RUN_DIR>/analyzer-hits.json`
for the Hunter to read as candidate seeds. It never fails the run — an absent tool or a
disabled config is a clean no-op.

1. **HUNT** — Dispatch a hunter (use a subagent / Task tool for context isolation if
   available) following `prompts/hunt.md` on the next uncovered batch. The hunter loads
   `repo-context.md` and `antipatterns.md` and runs BOTH the local lens (this batch) and
   the architectural lens (cross-file targets). On **iteration 1**, run a dedicated
   architectural hunt over the top-N `architectural_targets` (cap N so the hunt fits
   comfortably in one subagent context — typically 5–10 targets; if the list is longer,
   pick the highest-risk ones and note the rest for later iterations). This bounded hunt is
   what surfaces large cross-file bugs without stalling on huge repos. Remaining targets
   stay in the planned frontier; do not claim they were audited. Hunters never fix
   anything.
   Before each architectural target group or coverage batch, run `guard.sh`; if it prints
   a `STOP*` result. On `fix_cap_reached`, set `DETECT_ONLY_REMAINDER=1` and keep hunting
   without further mutation. On every other stop reason, call `finalize.sh` immediately.
2. **CHALLENGE (Skeptic)** — Dispatch a *separate* adversary following
   `prompts/challenge.md`. It actively tries to disprove each candidate, calibrated to
   punish dismissing real bugs twice as hard as missing a false-positive catch. Verdicts:
   UPHELD, REJECTED, or DISPUTED.
3. **REFEREE** — In every fix-capable mode, require a neutral arbiter following
   `prompts/referee.md` to independently rule every DISPUTED and UPHELD item. Its CONFIRMED
   list is the only thing eligible to fix.
   If `adversarial.referee_enabled` is false, detect mode may report Skeptic-UPHELD items as
   unconfirmed review candidates, but fix modes must stop before mutation; no component is
   allowed to silently replace the Referee.
   (This Hunter -> Skeptic -> Referee chain is the "adversarial checks".) For each confirmed
   bug with a transferable shape, the referee also synthesizes a **variant query** via
   `scripts/variants.sh add` so future runs hunt their frozen selected scope for siblings
   (WU1); preflight replays these and feeds in-scope matches into the frontier.
4. **FIX** (if `--fix`/`--approve`/`--autonomous`, unless
   `DETECT_ONLY_REMAINDER=1`) — For each confirmed bug at/above the
   severity floor, follow `prompts/fix.md`: apply the minimal change, then
   `bash scripts/run_checks.sh verify "<RUN_DIR>"`. If OK / no new failures → commit
   stage only the files belonging to that bug and commit
   (`git add -- <owned-files> && git commit -m "fix(bugsweep): <BUG-ID> <desc>"`). Inspect
   the staged diff before committing; unrelated or generated changes quarantine the fix.
   If `REGRESSION` →
   revert and quarantine. Never leave a red checkpoint. In `--approve`, ask before invoking
   Repro or Fix because Repro may write a test file; explain that an approved, verified fix
   will be locally integrated during closeout. A decline or timeout leaves no edit and
   records the bug in the tracker.
   On approval, append `{"event":"approval","bug_id":"<BUG-ID>","approved":true}` to
   `ledger.jsonl` before Repro starts. Closeout refuses an approved-mode landing without it.
   `verify` already reran the newly-failing test and applied the majority-flaky
   rule (see rule 5) before printing `REGRESSION`/`OK`, so `REGRESSION` means the failure
   survived the reruns. When `verify` prints `FLAKY=<n>`/`FLAKY_TEST=<id>` alongside `OK`,
   the fix is being COMMITTED with a flaky-classified test — record it and flag it for
   human review (per rule 5 this classification is shared-environment and can mask a
   state-pollution bug); do not auto-land a flaky-annotated `OK`. Record it in the tracker
   for review. Treat `NO_CHECKS` fixes the same way: never auto-land unverified code.
5. **Record + checkpoint** — Append the iteration result to `ledger.jsonl` (the Referee
   writes `{"event":"iteration","confirmed":<n>,"new_bugs":<n_new>}`). After the full
   Hunter → Skeptic → Referee chain finishes for a batch, run the checkpoint helper:
   ```bash
   checkpoint_out="$(bash scripts/mark-batch-covered.sh "<RUN_DIR>" "<batch-id>")"
   case "$checkpoint_out" in
     BATCH_COVERED=skipped_no_python)
       STOP_REASON=unverifiable_checkpoint; break ;;
   esac
   ```
   It records exact Git blob IDs, updates `recon.json.covered`, and emits the matching
   `batch_covered` event as one idempotent protocol. Do not write either coverage surface
   by hand. Context building records architecture progress separately in
   `recon.json.modeled`; it is not audit coverage. Only this post-adversarial checkpoint
   may populate `covered`. Python 3 is required for this exact Git-object checkpoint; the
   `skipped_no_python` branch leaves coverage untouched and finalizes with an incomplete report
   plus a degraded summary rather than claiming unverifiable work. That summary underreports
   coverage as zero and a generated stub has status `stalled`. Then run:
   ```bash
   bash scripts/session.sh checkpoint "<RUN_DIR>"
   ```
   This refreshes `SESSION.md`. If it prints `RESET_RECOMMENDED`, finish to a clean state
   (every fix committed or reverted, nothing mid-edit), then **reset/compact context** and
   immediately **rehydrate**: read `SESSION.md`, `repo-context.md`, `antipatterns.md`,
   `priority-context.json`, and `recon.json`, and tail `ledger.jsonl` before continuing. See
   `references/context-and-continuity.md`. Continuity is preserved because all progress is
   on disk; a reset only drops disposable working memory.

Stop conditions: all planned batches covered with no pending findings; a runtime/iteration
cap; or `no_progress_streak` only after the planned frontier is exhausted. A fix cap stops
mutation, not discovery. Non-`--autonomous` modes make one bounded pass over the planned
batches. Deferred large-repo batches make the result PARTIAL, never repo-clean.

### Step 5 — Finalize artifacts, resolve work, and clean up

**Write `<RUN_DIR>/report.md` before calling `finalize.sh`.** Include `PARTIAL` whenever
coverage is incomplete, including a large-repo deferral, cap, early interrupt, or
unexhausted frontier. If the model did not write a report, `finalize.sh` emits a stub from
the ledger and recon state.

```bash
bash scripts/finalize.sh "<RUN_DIR>"
```

This is an artifact checkpoint, not the terminal success signal. It persists cross-run
learning, creates `run-summary.json`, appends deterministic report sections, restores or
leaves the user's checkout untouched, writes `post-finalize-handoff.json`, and creates a
per-run closeout blocker. `BRANCH_PENDING_CLOSEOUT` is not success; do not end the run there.

Follow [tracker-closeout.md](references/tracker-closeout.md), in this order:

1. Read `run-summary.json`. Idempotently create or update tracker items for
   `confirmed_unfixed`, `quarantined`, approval-declined fixes, flaky/unchecked fixes, and
   actionable partial-run follow-up. Rejected candidates are not tickets. Persist and read
   back `tracker-receipts.jsonl` before cleanup.
2. If verified fixes are safe to land, integrate the exact run branch into the recorded
   original target with the existing post-merge quality gate and delete it only after
   containment proof:
   ```bash
   bash scripts/integrate.sh --run-dir "<RUN_DIR>" \
     "<ORIGINAL_BRANCH>" "<EXACT_RUN_BRANCH>"
   ```
   Local integration is part of `--fix`, `--approve`, and `--autonomous`; it never implies
   permission to push. Do not auto-land `NO_CHECKS`, flaky-annotated, approval-declined, or
   otherwise unverified changes.
3. After verified local integration, invoke the terminal exact-resource gate:
   ```bash
   bash scripts/closeout.sh "<RUN_DIR>" landed
   ```
   The gate requires `integrate-results.json` to bind the exact current source tip to a
   gated target tip. Already-contained work is re-gated rather than trusted by ancestry.
   Referee verdicts must precede each fix; in approved mode, approval must follow the
   verdict and precede reproduction or mutation.
4. If unique commits cannot land, export and verify `recovery.bundle` under `RUN_DIR`,
   attach its exact path as `recovery_bundle` and SHA-256 digest as `recovery_sha256` to a
   verified tracker receipt, and obtain the required fresh
   independent deletion check in `deletion-review.json`. Then invoke the same terminal gate:
   ```bash
   bash scripts/closeout.sh "<RUN_DIR>" recorded
   ```
   A clean run with no actionable work also uses `recorded`; the gate detects that its
   branch is already contained and needs no tracker receipt or bundle. Never use an omitted
   branch argument or a `bugsweep/*` deletion loop.
5. Run exact readback for the recorded branch and worktree. A successful run owns neither:
   ```bash
   git show-ref --verify --quiet "refs/heads/<EXACT_RUN_BRANCH>" && echo BRANCH_REMAINS
   git worktree list --porcelain | grep -F "<EXACT_RUN_WORKTREE>" && echo WORKTREE_REMAINS
   ```
6. Append the final `## Closeout receipt` section to `report.md` with the outcome, tracker
   receipt path/IDs, recovery bundle, and exact resource readback. This section is written
   after `finalize.sh`; do not guess these values in the pre-finalize prose.

Terminal states are `COMPLETED_LANDED` (verified fixes locally integrated) and
`COMPLETED_RECORDED` (actionable work recorded, recovery escrowed when needed). Only these
are success, and both require zero run-owned Git resources on readback. Tracker/readback
failure is `INCOMPLETE_TRACKER`; cleanup/readback failure is `INCOMPLETE_CLEANUP`. Record
the incomplete state and retry its idempotent closeout before any later run creates another
branch. Never claim "done" while the exact branch or worktree remains.

## What counts as a bug (and what to ignore)
FIND: security (injection, auth/authz bypass, SSRF, traversal, hardcoded secrets, unsafe
deserialization), logic (off-by-one, inverted conditions, wrong operators), error handling
(swallowed errors, missing null checks, unhandled rejections), concurrency/races, data
integrity (truncation, encoding, timezone, overflow, money precision), API-contract
violations, and cross-file/architectural gaps (a missing authz check on one path into a
sink; contract drift across a module boundary; untrusted input reaching a sink unvalidated).

IGNORE (linter/formatter jobs, not bugs): style, formatting, naming, unused imports,
missing type annotations that don't fault at runtime, TODOs, dependency versions, coverage
gaps. Flagging these erodes trust.

## Report structure
Write the finding sections in `<RUN_DIR>/report.md` before finalize, then append the
closeout receipt after tracker and cleanup readback. Present a condensed version. Use this
two-stage template:
```markdown
# bugsweep report — <timestamp>
**Run branch (ephemeral):** bugsweep/<run-id>   **Mode:** <mode>   **Iterations:** <n>
**Stack:** <detected>   **Baseline checks:** <summary>   **Final checks:** <summary>

## Summary
- Confirmed bugs: <n> (critical <n>, high <n>, medium <n>, low <n>); architectural: <n>
- Fixed & verified: <n>   Quarantined (needs human): <n>
- Coverage: <batches covered>/<total> batches [COMPLETE | PARTIAL — <stop reason>]; reviewed via Hunter→Skeptic→Referee

## Fixed
<one line per fix: BUG-ID · severity · lens · file:line · repro status · vote split for high/critical · what was wrong · commit sha>

## Quarantined / needs human
<one line per item: BUG-ID · stable finding key · severity · file:line · why it wasn't auto-fixed>

## Confirmed but not fixed (detect-only or below severity floor)
- <BUG-ID> · <stable finding key> · <severity> · <category> · <file>:<line> · <repro status> · <vote split for high/critical> · <one-line cause>

## Near misses (review, never auto-fixed)
<!-- Include only when recall mode is active. -->
- <BUG-ID> · <severity> · <category> · <file>:<line> · confidence <50–67> · <why plausible but unproven>

## Closeout receipt
<!-- Append after finalize + tracker + exact cleanup readback. -->
- Outcome: <COMPLETED_LANDED | COMPLETED_RECORDED | INCOMPLETE_TRACKER | INCOMPLETE_CLEANUP>
- Tracker receipts: <path and item IDs>
- Recovery bundle: <path or none>
- Owned branch/worktree remaining: <none or exact blocker>
```

Do **not** author a "Findings (machine-readable)" section yourself. `scripts/finalize.sh`
(via `scripts/summarize.sh`) appends that section automatically, generated from the
deterministic `<RUN_DIR>/run-summary.json` reduction of `ledger.jsonl` + `recon.json` — the
same script-emitted source of truth a headless scheduler reads. This keeps prose and JSON
from ever diverging, which a model-authored block (format varied run-to-run) could not
guarantee. Just write the prose sections above and stop; the machine-readable JSON block is
appended for you, including on a stub/partial report.

Do **not** author a priority-focus section either. `finalize.sh` appends
`## Priority focus (deterministic)` from `run-summary.json.priority` after exact coverage
verification. It includes actual applied promotions from `<RUN_DIR>/priority-application.json`,
top target outcomes, signal health, unmapped signals, and historical attributed yield without
relying on model prose. On the no-Python degraded path, do not synthesize a replacement section
or claim verified priority outcomes.

## References
- `references/context-and-continuity.md` — how state persists and how to reset safely.
- `references/antipatterns/` — the curated stack-specific catalogs (start at `index.md`).
- `references/safety-rationale.md` — why the design is safe; read if trust is questioned.
- `references/no-tests.md` — behavior when the project has no automated checks.
- `references/tuning.md` — what each config value does and how to tune for big repos.
- `references/priority-intelligence.md` — why-now signals, ranking, local adapters, and safety.
- `references/tracker-closeout.md` — tracker detection, idempotent ticketing, landing, escrow, and exact cleanup.
