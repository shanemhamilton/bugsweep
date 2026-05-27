# Repeatable, unattended maintenance runs

This is a recipe for running bugsweep on a schedule so it slowly deepens its coverage of
your codebase over time, while every session still ends in a clean git state — no pile of
leftover `bugsweep/<timestamp>` branches.

## What you do and don't need to build

- **You do NOT need to add anything to make bugsweep "learn" or "go deeper."** That is
  built in. bugsweep keeps cross-run state in `.bugsweep/state/` (audit log, per-file risk
  scores, variant queries) and reprioritizes toward never-audited, stale, and high-risk
  files on each run. Just running it again digs deeper. See
  `references/context-and-continuity.md`.
- **You DO need a merge gate if you want clean endings.** bugsweep deliberately never
  merges and never deletes branches — the human is the only merge gate. For unattended,
  repeatable runs, automate that gate with the optional companion script
  `scripts/bugsweep-cleanup.sh`. It runs *after* `finalize.sh`, on your own branch, using
  only plain git. It is intentionally outside the skill's trust contract: the skill's
  safety guarantees are unchanged.

## Setup (once per project)

1. Copy the companion scripts into your project so the prompt's relative paths resolve:
   ```bash
   cp ~/.claude/skills/bugsweep/scripts/bugsweep-prepare.sh scripts/bugsweep-prepare.sh
   cp ~/.claude/skills/bugsweep/scripts/bugsweep-cleanup.sh scripts/bugsweep-cleanup.sh
   chmod +x scripts/bugsweep-prepare.sh scripts/bugsweep-cleanup.sh
   ```
   (Codex users: substitute `~/.codex/skills/bugsweep/...`.)
2. Make sure the project has a **non-protected** integration/dev branch to receive fixes.
   The script refuses to auto-merge into `main`/`master`/`develop`/`prod`/`release` unless
   you set `BUGSWEEP_ALLOW_PROTECTED=1`. A dedicated `bugsweep-staging` branch you review
   periodically is the safest target.
3. Always run scheduled sweeps from a **clean checkout** (no uncommitted work). The cleanup
   script aborts on a dirty tree on purpose.

## The prompt (placeholders for your project agent to fill)

> Run an autonomous bugsweep maintenance pass on THIS repository, then finish with a clean
> git state. Follow these steps in order; do not skip verification.
>
> Background to respect: bugsweep cuts a throwaway `bugsweep/<timestamp>` branch, fixes
> only adversarially-confirmed bugs there, re-runs my tests after each fix, and auto-reverts
> regressions. It does NOT merge or delete branches — I automate that gate in step 4. Do not
> raise, bypass, or work around any bugsweep cap or safety script.
>
> 1. Get the tree clean by running `bash <PREPARE_PATH>`, then act on its result:
>    - `RESULT=PROCEED` (exit 0): the tree is clean (or stale work was committed) — continue to step 2.
>    - `RESULT=SKIP` (exit 10): another session appears to be actively working in the tree.
>      Do NOT run bugsweep this cycle. Stop cleanly and note the pass was deferred — this is
>      expected, not an error.
>    - any other non-zero exit: STOP and report the error.
> 2. Invoke bugsweep in autonomous mode with a high severity floor. In interactive Claude
>    Code that is `/bugsweep --autonomous --severity high`; in headless `-p` mode, request
>    it in natural language (slash skills aren't available there) — e.g. "run an unattended
>    autonomous bug-hunt-and-fix audit, high severity only." Let bugsweep's coverage-first
>    state set the file order; in hunting, prioritize high-risk backend/runtime paths first,
>    then iOS, then frontend.
> 3. When `finalize.sh` completes, capture `BRANCH_PRESERVED=...` and the `REPORT=...` path.
> 4. Act as the merge gate:
>    `BUGSWEEP_TARGET=<DEV_BRANCH> BUGSWEEP_POLICY=merge BUGSWEEP_TEST_CMD="<TEST_CMD>" bash <CLEANUP_PATH> <BRANCH_PRESERVED>`
>    If it reports a merge conflict or failing tests, leave that branch untouched and flag
>    it — do not force anything.
> 5. VERIFY and report the end state explicitly: I am on `<DEV_BRANCH>`, `git status` is
>    clean, and `git branch --list 'bugsweep/*'` shows no leftover branches except any you
>    flagged for review.
> 6. Produce the findings report ordered by severity (critical → low). For each finding:
>    ABSOLUTE file path + exact line number(s), what was wrong, the fix commit SHA (or why
>    quarantined), and the test/build evidence (baseline vs final from bugsweep's report.md).
> 7. Append a dated progress note to issue tracker item `<ISSUE_ID>`: pass timestamp, counts
>    by severity, fixed vs quarantined, coverage (batches covered / total), and the cleanup
>    outcome (merged / conflict / kept).

Placeholders: `<DEV_BRANCH>`, `<TEST_CMD>`, `<PREPARE_PATH>` (default
`scripts/bugsweep-prepare.sh`), `<CLEANUP_PATH>` (default `scripts/bugsweep-cleanup.sh`),
`<ISSUE_ID>`. One `/bugsweep` call only sweeps the repo you're in — run the prompt once per
repository.

## Dirty-tree handling (`bugsweep-prepare.sh`)

A scheduled run should start from a clean checkout, but if uncommitted work is present the
default `auto` policy resolves it without losing work and without leaving anything that
accumulates. It judges whether the work is ACTIVE or STALE:

- **ACTIVE** — a git operation is in progress (`index.lock` present), or the newest dirty
  file was touched less recently than the threshold ago. Another session looks busy, so the
  run **defers**: nothing is committed, stashed, or created; it prints `RESULT=SKIP` and
  exits `10`. The next scheduled cycle re-checks. (This is the "let another session finish"
  case.)
- **STALE** — the newest dirty file is at least the threshold old. The work is committed
  as-is onto the current branch to **close the tree**, then the sweep proceeds. That commit
  is ordinary history — recoverable, squashable — so nothing parks or piles up. (This is the
  "no activity for 2+ hours, so close it" case.)

It commits existing changes; it does not write new code to "finish" the work, and it never
discards anything. On a protected branch it refuses to auto-commit and errors (exit `1`) so
you fix the misconfiguration — run the loop on a non-protected dev branch.

| Variable                 | Default | Purpose                                                           |
| ------------------------ | ------- | ---------------------------------------------------------------- |
| `BUGSWEEP_DIRTY_POLICY`  | `auto`   | `auto` (defer-or-close) \| `commit` (always close) \| `stash` (legacy; can accumulate) \| `fail`. |
| `BUFSWEEP_IDLE_SECONDS`  | `7200`  | Activity threshold. < this = ACTIVE/defer; ≥ this = STALE/close. (7200 = 2h.) |
| `BUGSWEEP_AUTOCLOSE_MSG` | _(set)_ | Commit message prefix for closed stale work.                   |

Activity is inferred from file modification times — a heuristic. A process that
continuously rewrites a tracked file would always read as ACTIVE; keep build artifacts
git-ignored so they don't register as dirty. A crashed git process can leave a stale
`index.lock`; if cycles keep deferring, check for and remove it.

## Cleanup script settings

| Variable                   | Default          | Purpose                                            |
| --------------------------- | ---------------- | ---------------------------------------------------- |
| `BUFSWEEP_TARGET`          | current branch   | Branch to merge verified fixes into.               |
| `BUGSWEEP_POLICY`          | `merge`          | `merge` \| `discard` (throw the run away) \| `keep` (leave for review). |
| `BUGSWEEP_TEST_CMD`        | _(none)_         | Optional command re-run on the branch before merge; failure blocks the merge. |
| `BUFSWEEP_RETENTION_DAYS`  | `7`              | Force-prune abandoned older sweep branches past this age. |
| `BUGSWEEP_ALLOW_PROTECTED` | `0`              | Set `1` to permit merging into a protected branch. |

The script merges with `--no-ff` (preserving the one-commit-per-bug history), deletes the
branch only after a successful merge, aborts cleanly on conflict, and leaves a branch in
place if its re-test fails.

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

Auto-merging removes you from reviewing each diff, even though bugsweep only commits fixes
that keep tests green. If that's too much autonomy: point `BUGSWEEP_TARGET` at a long-lived
`bugsweep-staging` branch and review that on your own cadence, or set `BUGSWEEP_POLICY=keep`
for the first several scheduled runs to build trust before switching to `merge`.
