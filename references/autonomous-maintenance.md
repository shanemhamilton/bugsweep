# Repeatable, unattended maintenance runs

This is a recipe for running bugsweep on a schedule so it slowly deepens its coverage of
your codebase over time, while every session still ends in a clean git state — no pile of
leftover `bugsweep/<timestamp>` branches.

**This doc covers a single sequential `/bugsweep --autonomous` run only.** If you want one
orchestrator session to fan out up to 5 worktree-isolated bugsweep subagents in parallel
(partitioning the hunt frontier, integrating verified branches with re-verification after
each merge, and never hunting itself), see
[`references/orchestrator.md`](orchestrator.md) instead.

## What you do and don't need to build

- **You do NOT need to add anything to make bugsweep "learn" or "go deeper."** That is
  built in. bugsweep keeps cross-run state in `.bugsweep/state/` (audit log, per-file risk
  scores, variant queries) and reprioritizes toward never-audited, stale, and high-risk
  files on each run. Just running it again digs deeper. See
  `references/context-and-continuity.md`.
- **You DO need a documented project tracker and a local quality gate.** Bugsweep now
  treats `finalize.sh` as an artifact checkpoint, then lands verified local work or records
  remaining action and prunes its exact branch/worktree. Scheduled runs must provide the
  same tracker access and closeout proof as interactive runs. See
  [`tracker-closeout.md`](tracker-closeout.md).

## Setup (once per project)

1. Point the scheduler at the installed skill directory so the scripts keep their shared
   `common.sh` dependency:
   ```bash
   SKILL_ROOT="$HOME/.claude/skills/bugsweep"  # or ~/.codex/skills/bugsweep
   ```
2. Configure the external `required-untrusted` Docker policy and explicit
   `adversarial.hosts` operator model IDs. The default empty hosts map means an unattended
   run can detect and record but cannot automatically fix.
3. Make sure the project has a **non-protected** integration/dev branch to receive fixes.
   The script refuses to auto-merge into `main`/`master`/`develop`/`prod`/`release` unless
   you set `BUGSWEEP_ALLOW_PROTECTED=1`. A dedicated `bugsweep-staging` branch you review
   periodically is the safest target.
4. Run every sweep with `preflight.sh --worktree`. The user's checkout may be dirty because
   isolated mode never stashes, commits, switches, or cleans it.

## The prompt (placeholders for your project agent to fill)

> Run an autonomous bugsweep maintenance pass on THIS repository, then finish with a clean
> git state. Follow these steps in order; do not skip verification.
>
> Background to respect: Bugsweep uses one isolated, ephemeral run branch, fixes only
> source-backed, fresh-native-review-eligible bugs with immutable assertion red/green proof
> and a provider-verified suite receipt. Before preflight, resolve this
> project's documented tracker. After `finalize.sh`, locally land verified work or upsert
> remaining action, then remove only this run's exact branch/worktree and read back the
> result. Do not push, raise caps, or bypass a safety script.
>
> 1. Invoke bugsweep in autonomous mode with a high severity floor. In interactive Claude
>    Code that is `/bugsweep --autonomous --severity high`; in headless `-p` mode, request
>    it in natural language (slash skills aren't available there) — e.g. "run an unattended
>    autonomous bug-hunt-and-fix audit, high severity only." Let bugsweep's coverage-first
>    state set the file order; in hunting, prioritize high-risk backend/runtime paths first,
>    then iOS, then frontend.
> 2. Treat `finalize.sh` as an artifact checkpoint. Read `run-summary.json` and follow
>    `references/tracker-closeout.md`: upsert actionable unresolved work with stable keys and
>    read back the tracker receipts.
> 3. Integrate verified fixes into `<DEV_BRANCH>` with
>    `bash "$SKILL_ROOT/scripts/integrate.sh"`, then run
>    `bash "$SKILL_ROOT/scripts/closeout.sh" <RUN_DIR> landed`.
>    If integration cannot pass its post-merge gate, escrow a verified recovery bundle,
>    update the tracker item, obtain the independent deletion check, then discard only the
>    exact run branch with `bash "$SKILL_ROOT/scripts/closeout.sh" <RUN_DIR> recorded`.
> 4. After every multi-fix integration, preserve each original proof and reverify each
>    original regression test against the final combined tree:
>    `python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" reverify <RUN_DIR> <BUG_ID> <SHA>`
>    followed by `bash "$SKILL_ROOT/scripts/repro.sh" reverify <RUN_DIR> <BUG_ID> <REQUEST_PATH>`.
> 5. Run configured smoke commands only after local integration. Do not push as part of the
>    Bugsweep run.
> 6. If execution, native review, or tracker evidence is unavailable, do not fix or claim a
>    completed run: record the blocked finding and preserve the required recovery state.
> 7. VERIFY the exact run branch and worktree are absent and the user's checkout is unchanged.
>    Report `COMPLETED_LANDED`, `COMPLETED_RECORDED`, `INCOMPLETE_TRACKER`, or
>    `INCOMPLETE_CLEANUP`; only the first two are success.
> 8. Produce the findings report ordered by severity (critical → low). For each finding:
>    ABSOLUTE file path + exact line number(s), what was wrong, the fix commit SHA (or why
>    quarantined), and the test/build evidence (baseline vs final from bugsweep's report.md).
> 9. Include tracker IDs, pass timestamp, severity counts, fixed vs quarantined, coverage,
>    and closeout outcome in the final report.

Placeholders: `<DEV_BRANCH>`, `<TEST_CMD>`.
One `/bugsweep` call only sweeps the repo you're in — run the prompt once per
repository.

## Dirty-tree handling

Do not run `bugsweep-prepare.sh` in the scheduled workflow. It is a legacy in-place helper
that can commit stale user work. Worktree isolation makes that mutation unnecessary: leave
the user's checkout exactly as it is and audit committed `HEAD` in the owned worktree.

## Cleanup script settings

| Variable                   | Default          | Purpose                                            |
| -------------------------- | ---------------- | -------------------------------------------------- |
| `BUGSWEEP_TARGET`          | current branch   | Branch to merge verified fixes into.               |
| `BUGSWEEP_POLICY`          | `merge`          | `merge` \| `keep` (leave for review). Uncontained discard is closeout-only. |
| `BUGSWEEP_TEST_CMD`        | _(none)_         | Optional command re-run on the branch before merge; failure blocks the merge. |
| `BUGSWEEP_ALLOW_PROTECTED` | `0`              | Set `1` to permit merging into a protected branch. |

The script merges with `--no-ff` (preserving the one-commit-per-bug history), deletes the
branch only after containment proof (`git merge-base --is-ancestor <branch> <target>`),
aborts cleanly on conflict, and leaves a branch in place if its re-test fails.

If a fully merged bugsweep branch is checked out in another linked worktree, cleanup
locates that worktree with `git worktree list --porcelain`. It removes the worktree with
plain `git worktree remove <path>` only when the worktree is clean: no unstaged changes, no
staged changes, and no untracked files. Dirty linked worktrees are preserved, and cleanup
prints `BRANCH_PRESERVED=<branch>`.

Stable result lines are printed at the end so a parent agent can make deterministic
decisions:

```text
CLEANUP_RESULT=merged_deleted
CLEANUP_RESULT=merged_branch_preserved
CLEANUP_RESULT=kept_for_review
CLEANUP_RESULT=conflict
CLEANUP_RESULT=tests_failed
BRANCH_DELETED=<branch>
BRANCH_PRESERVED=<branch>
WORKTREE_REMOVED=<path>
TARGET_BRANCH=<branch>
```

## Scheduling

In headless mode, drive it with Claude Code's print flag and grant the tools the run needs:

```bash
claude -p "$(cat maintenance-prompt.txt)" \
  --allowedTools "Bash,Read,Edit" \
  --permission-mode acceptEdits
```

Wrap that in `cron`/`launchd` (one invocation per repo, each run from a clean checkout).
To stop two cycles overlapping on the same repo, serialize them with a lock, e.g.
`flock -n /tmp/bugsweep-<repo>.lock claude -p ...` — `flock` exits without running if the
previous cycle is still going. Remember: in `-p` mode you describe the task; the bugsweep skill auto-triggers from the
description rather than from a typed `/bugsweep`. Tune cost/runtime via the caps in
`config/bugsweep.config.json` rather than instructing the AI to override them.

## Lowering risk

Auto-integration removes a per-diff human pause even though Bugsweep gates every landed fix.
If that is too much autonomy, use `--approve` or detect-only mode. Do not use
`BUGSWEEP_POLICY=keep` as a review queue; unresolved work belongs in the project tracker,
with a recovery bundle when code cannot land.
