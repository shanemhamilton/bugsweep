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
2. **Never touch remotes.** No push/pull/fetch, no PR, no merge. The human is the only
   merge gate.
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

For unattended/overnight/"run all night"/fully autonomous behavior, use `--autonomous`.
Recommend a first-time `--approve` run to calibrate trust before `--autonomous`.

## Execution

### Step 0 — Preflight (deterministic safety setup)
ALWAYS run first, before reading any source file:
```bash
bash scripts/preflight.sh
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
   whole-repo architectural hunt over all `architectural_targets` first — this is where the
   large bugs surface. Hunters never fix anything.
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
```bash
bash scripts/finalize.sh "<RUN_DIR>"
```
Restores the user's stashed work onto their original branch, preserves all fix commits on
`bugsweep/<timestamp>`, and points to the report. It also persists this run's audit
coverage + risk into `.bugsweep/state/` so the next run resumes the whole-repo frontier
instead of starting blind. Present the summary and tell the user to review with
`git diff <original-branch>..bugsweep/<timestamp>`.

**Land-or-discard handoff (REQUIRED — the run is not "done" until the human chooses).** A
fix branch left unlanded will be rediscovered next run, so finalize MUST end by presenting
the human merge gate. The skill never lands or deletes branches itself; give the user the
exact commands and let them choose:

- **Land** (the fixes are good, merge them yourself — the only path that stops recurrence):
  ```bash
  git checkout <original-branch>
  git merge --no-ff bugsweep/<timestamp>     # or: git cherry-pick <sha>...  for a subset
  # then push per your normal flow — bugsweep never pushes
  ```
- **Discard** (not worth keeping):
  ```bash
  git branch -D bugsweep/<timestamp>
  ```
- **Defer** (decide later): leave it, but know the next run's stale-branch check will flag it.

State plainly which branch holds the fixes and that **nothing reaches `main` until they
land it** — bugsweep stops at the gate by design. Do not soften this into "the fixes are
ready"; they are stranded on a throwaway branch until the human acts.

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
- Coverage: <batches covered>/<total>; reviewed via Hunter->Skeptic->Referee

## Fixed
<one line per fix: BUG-ID · severity · lens · file:line · what was wrong · commit sha>

## Quarantined / needs human
<one line per item: BUG-ID · severity · file:line · why it wasn't auto-fixed>

## Confirmed but not fixed (detect-only or below severity floor)
- <BUG-ID> · <severity> · <category> · <file>:<line> · <one-line cause>

## How to review
git diff <original-branch>..bugsweep/<timestamp>
```

## References
- `references/context-and-continuity.md` — how state persists and how to reset safely.
- `references/antipatterns/` — the curated stack-specific catalogs (start at `index.md`).
- `references/safety-rationale.md` — why the design is safe; read if trust is questioned.
- `references/no-tests.md` — behavior when the project has no automated checks.
- `references/tuning.md` — what each config value does and how to tune for big repos.
