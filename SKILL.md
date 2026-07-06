---
name: bugsweep
description: >-
  Autonomous, adversarial bug-hunting and auto-fix pipeline for a codebase. Builds a
  whole-repo architecture model, researches stack-specific anti-patterns, then finds
  runtime behavioral bugs (security vulnerabilities, logic errors, race conditions,
  error-handling gaps, data-integrity bugs, and large cross-file/architectural bugs) and,
  when asked, fixes them autonomously on a throwaway git branch with full auto-revert
  safety. Uses an adversarial Hunter -> Skeptic -> Referee review to keep false positives
  low, and persists all state to disk so long unattended runs survive context resets with
  full continuity. Use this skill whenever the user wants to "find bugs", "hunt bugs",
  "audit the code", "deep code review", "check for vulnerabilities before shipping", "run
  an unattended/overnight audit", or "make sure bugs don't reach production" — even if
  they don't say "bugsweep".
---

# bugsweep

A safe, auditable, autonomous bug-hunting pipeline. It separates **finding** a bug from
**challenging** it from **confirming** it from **fixing** it, so the model never
rubber-stamps its own guesses; it builds whole-repo context so it can catch large
cross-file bugs; it primes itself with anti-patterns common to the stack under review; and
it routes every irreversible git operation through deterministic shell scripts so the
safety guarantees never depend on the model's judgment. All progress is written to disk so
a long run can reset context and continue without losing work.

## The trust contract (read first — it governs everything)

Non-negotiable. Scripts in `scripts/` enforce the irreversible parts; you enforce the
rest. If a rule can't be honored, STOP and report — never work around it.

1. **Work only on a throwaway branch** (`bugsweep/<timestamp>`, created by preflight).
   Never commit to or switch the user onto their original branch.
2. **Core run never touches remotes.** During preflight, hunt, fix, and finalize: no
   push/pull/fetch, no PR, no merge. The human is the only merge gate. Post-finalize
   merge/push/delete actions are allowed only after an explicit approved continuation, or
   through the optional cleanup/merge-gate script the human configured.
3. **No destructive operations, ever.** No `git reset --hard` on user content, no force
   anything, no deleting files/dirs, no `rm -rf`, no history rewriting.
4. **Preserve the user's work.** Preflight stashes uncommitted changes; finalize restores
   them. Their starting branch and working tree end exactly as they began.
5. **One bug, one commit, auto-revert on regression.** Re-run checks after each fix; if a
   fix introduces ANY new failure, revert it and quarantine the bug.
6. **Fix only confirmed bugs** — findings must pass the full adversarial review first.
7. **Minimal surgical fixes only.** No refactoring, renaming, reformatting, or unrelated
   changes.
8. **Stay inside the caps** (iterations, runtime, fixes) and stop when converged.
9. **Everything is logged** to the run ledger so an overnight run is auditable.

The worst possible outcome of any run is a throwaway branch the user deletes. That is what
makes unattended autonomy safe.

## Modes

Parse the invocation; default to the SAFEST reading when ambiguous.

| Invocation | Behavior |
| --- | --- |
| `/bugsweep` | **Detect only.** Full pipeline, writes a report, no code changes. (Default.) |
| `/bugsweep --fix` | Find + adversarial-confirm + fix on the branch. Single pass. |
| `/bugsweep --approve` | Like `--fix`, but PAUSE for the user's OK before each fix. |
| `/bugsweep --autonomous` | Find + confirm + fix, then **loop** until clean or a cap, with periodic context checkpoints/resets. The unattended/overnight mode. Implies `--fix --loop`. |
| `/bugsweep <path>` | Scope to a file or directory (combine with any flag). |
| `/bugsweep --severity <low\|medium\|high\|critical>` | Only fix bugs at/above this severity. |
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

ALWAYS run preflight next, before reading any source file:
```bash
bash scripts/preflight.sh                     # detect / fix / approve modes
bash scripts/preflight.sh --mode autonomous   # when invoked with --autonomous
```
It verifies the repo is safe, refuses an unclean protected branch, stashes uncommitted
work, creates and checks out `bugsweep/<timestamp>`, and prints a `RUN_DIR` (under
`.bugsweep/`) plus the branch name. If it exits non-zero, STOP and show the user the error
verbatim. Capture `RUN_DIR`; all artifacts live there.

**Stale-branch check (do this right after preflight succeeds).** Unlanded fix branches
from prior runs are the #1 failure mode: because each run forks from current main, any fix
the human never landed gets **rediscovered and re-fixed every run**, spawning duplicate
branches and wasted iterations. Before hunting, list prior branches and surface them:
```bash
git branch --list 'bugsweep/*' | grep -v "$(git rev-parse --abbrev-ref HEAD)"
```
If any exist besides the one just created, PAUSE and tell the user: "N prior bugsweep
branches exist and were never landed or discarded — I'll re-find the same bugs unless they
are dealt with. Land or discard them first (see Step 5 handoff), or tell me to proceed
anyway." Do NOT delete anything yourself — the human owns the merge gate. This is read-only
detection; never touch remotes.

### Step 1 — Baseline checks
```bash
bash scripts/run_checks.sh baseline "<RUN_DIR>"
```
Auto-detects and runs tests/typecheck/build/lint (or uses config overrides) and records
the starting state to `baseline.json`. Every fix is measured against this. If it reports
`NO_CHECKS`, follow `references/no-tests.md` — fixes must be more conservative.

### Step 2 — Build whole-repo context (once)
Follow `prompts/context-build.md`. Produce `repo-context.md` (architecture, trust
boundaries, sensitive sinks, call chains, import graph, key data flows, and
`architectural_targets`) and `recon.json` (risk-ranked batch plan). This distilled model is
what lets the hunt find **large** cross-file bugs, and it is small enough to survive a
context reset. Append a `context_built` event.

**Large-repo budget flag.** After writing `recon.json`, compare `batch_count` against
`floor(max_runtime_minutes / observed_minutes_per_batch)`. On the very first run
`observed_minutes_per_batch` is unknown — use 10 as a conservative prior; update after
iteration 1. If `batch_count > budget_batches`, set `"large_repo_mode": true` and
`"budget_batches": <n>` in `recon.json` and append a `large_repo_mode_activated` event
(`{"event":"large_repo_mode_activated","batch_count":<n>,"budget_batches":<n>}`) to the
ledger. This is a warning, not a stop — it tells the loop when partial coverage is expected
so it can emit an informative report instead of silently running out of time.

**Coverage-first scope (read `prior-coverage.json` first).** Preflight wrote
`<RUN_DIR>/prior-coverage.json` from bugsweep's cross-run state (`.bugsweep/state/`). The
whole repo is ALWAYS in scope — bugsweep finds latent bugs in old, unchanged code, it is
not a diff scanner. Prior coverage only *reorders* batches: put never-audited, stale (older
catalog version or audited too long ago), high-risk, and all sink-bearing files in the
critical tier; put already-audited-and-fresh files in a final cheap re-confirmation tier.
Never drop a file from the plan. The repo is never permanently "done" while a frontier
remains. See `references/context-and-continuity.md`.

### Step 3 — Research anti-patterns for this stack (once)
Follow `prompts/research.md`. Detect the languages/frameworks, load the matching catalogs
from `references/antipatterns/` (always include `generic.md`), optionally augment with
bounded web research if `research.allow_web_research` is true and a web tool exists, and
write `antipatterns.md` tailored to this repo. Append a `research_done` event.

### Step 4 — The loop
Repeat until a stop condition fires. At the start of each iteration:
```bash
bash scripts/guard.sh "<RUN_DIR>"
```
If it prints `STOP <reason>`, go to Step 5. Otherwise run one iteration:

1. **HUNT** — Dispatch a hunter (use a subagent / Task tool for context isolation if
   available) following `prompts/hunt.md` on the next uncovered batch. The hunter loads
   `repo-context.md` and `antipatterns.md` and runs BOTH the local lens (this batch) and
   the architectural lens (cross-file targets). On **iteration 1**, run a dedicated
   architectural hunt over the top-N `architectural_targets` (cap N so the hunt fits
   comfortably in one subagent context — typically 5–10 targets; if the list is longer,
   pick the highest-risk ones and note the rest for later iterations). This bounded hunt is
   what surfaces large cross-file bugs without stalling on huge repos. Hunters never fix
   anything.
2. **CHALLENGE (Skeptic)** — Dispatch a *separate* adversary following
   `prompts/challenge.md`. It actively tries to disprove each candidate, calibrated to
   punish dismissing real bugs twice as hard as missing a false-positive catch. Verdicts:
   UPHELD, REJECTED, or DISPUTED.
3. **REFEREE** — If `adversarial.referee_enabled`, dispatch a neutral arbiter following
   `prompts/referee.md` to resolve DISPUTED items and spot-check high-severity UPHELD ones
   by reading the code independently. Its CONFIRMED list is the only thing eligible to fix.
   (This Hunter -> Skeptic -> Referee chain is the "adversarial checks".) For each confirmed
   bug with a transferable shape, the referee also synthesizes a **variant query** via
   `scripts/variants.sh add` so future runs hunt the whole repo for siblings (WU1); preflight
   replays these and feeds matched files into the frontier.
4. **FIX** (if `--fix`/`--approve`/`--autonomous`) — For each confirmed bug at/above the
   severity floor, follow `prompts/fix.md`: apply the minimal change, then
   `bash scripts/run_checks.sh verify "<RUN_DIR>"`. If OK / no new failures → commit
   (`git add -A && git commit -m "fix(bugsweep): <BUG-ID> <desc>"`). If `REGRESSION` →
   revert and quarantine. Never leave a red checkpoint. In `--approve`, ask before each
   commit.
5. **Record + checkpoint** — Append the iteration result to `ledger.jsonl` (the Referee
   writes `{"event":"iteration","confirmed":<n>,"new_bugs":<n_new>}`), mark the batch
   covered (`batch_covered`), then run:
   ```bash
   bash scripts/session.sh checkpoint "<RUN_DIR>"
   ```
   This refreshes `SESSION.md`. If it prints `RESET_RECOMMENDED`, finish to a clean state
   (every fix committed or reverted, nothing mid-edit), then **reset/compact context** and
   immediately **rehydrate**: read `SESSION.md`, `repo-context.md`, `antipatterns.md`, and
   `recon.json`, and tail `ledger.jsonl` before continuing. See
   `references/context-and-continuity.md`. Continuity is preserved because all progress is
   on disk; a reset only drops disposable working memory.

Stop conditions: all batches covered with no pending findings; `no_progress_streak`
iterations with zero new confirmed bugs; or any cap hit. Non-`--autonomous` modes run a
single pass over all batches and then stop.

### Step 5 — Finalize
**Write `<RUN_DIR>/report.md` BEFORE calling `finalize.sh`.** This must happen regardless
of why the loop stopped — cap hit, convergence, or early interrupt. A partial report is
always better than no report; use the Report structure template below and include
`— PARTIAL RUN (<stop_reason>)` in the Coverage line if not all batches were covered.

If the run stalled before reaching this step (e.g. during context-build or the
architectural hunt), `finalize.sh` will automatically emit a stub report from on-disk state
(`recon.json` counts + ledger events) so the user always gets a coverage summary.

```bash
bash scripts/finalize.sh "<RUN_DIR>"
```
Restores the user's stashed work onto their original branch, preserves all fix commits on
`bugsweep/<timestamp>`, emits the stub report if `report.md` is still missing, and points
to the report. It also persists this run's audit coverage + risk into `.bugsweep/state/`
so the next run resumes the whole-repo frontier instead of starting blind. It also
unconditionally reduces `ledger.jsonl` + `recon.json` into `<RUN_DIR>/run-summary.json`
(via `scripts/summarize.sh`) and appends the report's "Findings (machine-readable)" section
from that same reduction — so `run-summary.json` exists, and the report's JSON matches it,
even on a stalled/partial run. Present the summary and tell the user to review with
`git diff <original-branch>..bugsweep/<timestamp>`.

`finalize.sh` also writes `<RUN_DIR>/post-finalize-handoff.json`. Treat this as the
machine-readable contract for the parent agent. It includes:

- `run_dir`
- `original_branch`
- `preserved_branch`
- `report_path`
- `fix_commits`
- `focused_tests`
- `quality_gate_command`
- `smoke_test_commands`
- `push_policy`
- `cleanup_policy`
- `safe_to_delete_branch_after`
- `final_readback_commands`

**Land-or-discard handoff (REQUIRED — the run is not "done" until the human chooses).** A
fix branch left unlanded will be rediscovered next run, so finalize MUST end by presenting
the human merge gate. The core bugsweep run never lands, pushes, or deletes branches by
itself. State plainly which branch holds the fixes and that **nothing reaches the target
branch until the user approves the continuation**.

For autonomous mode, end with one clear compound next action:

> Reply `do it` to land the preserved branch, re-run proof on the target branch, push if
> safe, run configured smoke checks, verify remote read-back, and delete the now-merged
> bugsweep branch.

If the user replies `do it`, that one approval covers the full safe follow-through
sequence. Do not ask for another vague "do it" after landing. Read
`post-finalize-handoff.json`, then:

1. Check out the target branch (`original_branch` unless the user configured another
   target).
2. Merge the preserved branch with `--no-ff` or use the configured cleanup script.
3. Re-run the quality gate from `quality_gate_command` on the target branch.
4. Run every configured smoke command from `smoke_test_commands`; skip only when the list
   is empty.
5. Push only if the configured `push_policy` allows it and the checks passed; never
   force-push.
6. Run the `final_readback_commands` and report the concrete output.
7. Delete the `bugsweep/*` branch only after `safe_to_delete_branch_after` is satisfied:
   the branch is contained in the target branch. If it is checked out in a linked worktree,
   remove that worktree only when it is clean; dirty worktrees are preserved.

If any step reports `CLEANUP_RESULT=conflict`, `CLEANUP_RESULT=tests_failed`, a dirty
worktree, or a non-contained branch, stop and report `BRANCH_PRESERVED=<branch>`. Never
force-delete, reset user content, or remove dirty worktrees.

For manual review, the exact read-only command remains:

```bash
git diff <original-branch>..bugsweep/<timestamp>
```

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
Write `<RUN_DIR>/report.md` and present a condensed version. ALWAYS use this template:
```markdown
# bugsweep report — <timestamp>
**Branch:** bugsweep/<timestamp>   **Mode:** <mode>   **Iterations:** <n>
**Stack:** <detected>   **Baseline checks:** <summary>   **Final checks:** <summary>

## Summary
- Confirmed bugs: <n> (critical <n>, high <n>, medium <n>, low <n>); architectural: <n>
- Fixed & verified: <n>   Quarantined (needs human): <n>
- Coverage: <batches covered>/<total> batches [COMPLETE | PARTIAL — <stop reason>]; reviewed via Hunter→Skeptic→Referee

## Fixed
<one line per fix: BUG-ID · severity · lens · file:line · what was wrong · commit sha>

## Quarantined / needs human
<one line per item: BUG-ID · severity · file:line · why it wasn't auto-fixed>

## Confirmed but not fixed (detect-only or below severity floor)
- <BUG-ID> · <severity> · <category> · <file>:<line> · <one-line cause>

## How to review
git diff <original-branch>..bugsweep/<timestamp>
```

Do **not** author a "Findings (machine-readable)" section yourself. `scripts/finalize.sh`
(via `scripts/summarize.sh`) appends that section automatically, generated from the
deterministic `<RUN_DIR>/run-summary.json` reduction of `ledger.jsonl` + `recon.json` — the
same script-emitted source of truth a headless scheduler reads. This keeps prose and JSON
from ever diverging, which a model-authored block (format varied run-to-run) could not
guarantee. Just write the prose sections above and stop; the machine-readable JSON block is
appended for you, including on a stub/partial report.

## References
- `references/context-and-continuity.md` — how state persists and how to reset safely.
- `references/antipatterns/` — the curated stack-specific catalogs (start at `index.md`).
- `references/safety-rationale.md` — why the design is safe; read if trust is questioned.
- `references/no-tests.md` — behavior when the project has no automated checks.
- `references/tuning.md` — what each config value does and how to tune for big repos.
