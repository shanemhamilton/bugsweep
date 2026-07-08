# Changelog

All notable changes to bugsweep are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-07-08

The overnight-orchestrator milestone: bugsweep grows from a single-run bug hunter into a
fleet a headless scheduler can drive unattended and tear down cleanly. The trust contract is
unchanged — the core run still never touches remotes, and you are still the only merge gate.

### Added

- **Deterministic, schema-valid `run-summary.json` (bugsweep-mu3).** `finalize.sh` always
  writes `<RUN_DIR>/run-summary.json` (reduced by `scripts/summarize.sh` against
  `schemas/run-summary.schema.json`) so a scheduler can branch on JSON — status, coverage,
  severity counts, and fixed/quarantined/confirmed-unfixed findings — instead of parsing
  model prose. If the full reduction can't run, a minimal schema-valid summary with
  `"degraded": true` is emitted instead; the summary always exists after finalize.
- **Run-summary enrichment + cross-run aggregation (bugsweep-xdw).** Adds
  `root_cause_clusters`, a `follow_up` "where to look next" frontier, and
  `scripts/aggregate-summaries.sh` to fold findings across runs (all backward-compatible
  optional fields).
- **Worktree isolation for concurrent runs (bugsweep-p74).** `preflight.sh --worktree`
  checks the run out into an isolated linked git worktree so multiple sibling subagents can
  hunt one repo at once without colliding — and without ever touching the user's checkout.
- **Incremental, checkpointed context-build with a deterministic batch plan (bugsweep-e1r).**
- **Optional static-analyzer seeding (bugsweep-042), off by default.** `scripts/analyzers.sh`
  runs installed off-the-shelf analyzers (semgrep, gosec, bandit, …) pre-hunt as one more
  corroboration signal for the Referee — never a replacement for adversarial review.
- **Serialized, re-verifying multi-branch merge (bugsweep-5e8).** `scripts/integrate.sh`
  lands an ordered list of already-verified fix branches into a target one at a time,
  re-running the quality gate after each merge and stopping cleanly on the first failure.
- **A deadline that always finalizes (bugsweep-5ft).** The runtime cap is a hard checkpoint
  the loop honors every iteration; hitting it routes straight to `finalize.sh` so a run that
  runs out of time still restores the branch and writes its report, summary, and handoff.
- **GitHub Pages marketing page (`docs/index.html`) + README "Overnight orchestrator"
  section** documenting the above.

### Changed

- **Flaky-aware revert (bugsweep-ml7).** Trust-contract rule 5's regression check now reruns
  a newly-failing test `.verify.flaky_reruns` times (default 3); only a strict majority of
  passing reruns reclassifies it FLAKY and skips the revert. The reruns share the run's
  tree/environment (not full isolation), so any fix that lands flaky is surfaced loudly in
  `flaky.jsonl`, the ledger, and the summary — never silently.
- **Concurrency hardening (bugsweep-re9).** Lease heartbeat plus single-winner stale-lock
  adoption so concurrent runs never double-claim or serialize on a dead lock.

### Fixed

- **Crash-safe teardown (bugsweep-8d0).** The optional worktree/branch reaper reclaims only
  on positive evidence a run is dead or done (a `.finalized` sentinel or an expired lease);
  anything dirty, unmerged, or ambiguous is preserved and reported, never guessed away.
  Closes seven data-loss paths found in adversarial re-review (lease-before-add, pinned
  target resolution, vanished-dir, gitignored-content, and live-sibling reap).

## [0.3.1] - 2026-06-03

### Added

- Post-finalize continuation contract for autonomous runs: Step 5 now ends with one
  compound `do it` action covering land, target-branch proof, safe push, configured smoke
  checks, remote read-back, and cleanup.
- `finalize.sh` now writes `<RUN_DIR>/post-finalize-handoff.json` with branch, report,
  fix-commit, quality-gate, smoke-test, push-policy, cleanup-policy, deletion-proof, and
  read-back state for parent agents.
- Bats integration tests for cleanup branch deletion, linked worktree handling, conflicts,
  protected targets, Bash 3.2 syntax, and portability guardrails.

### Changed

- `scripts/bugsweep-cleanup.sh` now deletes `bugsweep/*` branches only after containment
  proof, removes clean linked worktrees when they block deletion, preserves dirty linked
  worktrees, and emits stable `CLEANUP_RESULT=...` / `BRANCH_*` / `WORKTREE_REMOVED=...`
  result lines.
- `--autonomous` now stops at the same explicit post-finalize continuation gate instead of
  treating invocation as implicit merge/push/delete authorization.

## [0.3.0] - 2026-05-31

### Added

- **`--autonomous` mode auto-lands fixes end-to-end.** When invoked with `--autonomous`,
  the run now completes fully: fix commits are merged into the original branch with
  `--no-ff`, pushed to remote, and the bugsweep branch is deleted. Previously, `--autonomous`
  stopped at a throwaway branch and required a manual merge step. The invocation itself is
  the merge+push authorization; non-autonomous modes (`--fix`, `--approve`, detect-only)
  still use the human handoff as before. If the push fails (no remote or insufficient
  access), the local merge is preserved and a `git push` is all that remains. If the merge
  fails (rare; concurrent work landed conflicting changes), the branch is preserved and
  the normal handoff is presented.
- **`BUGSWEEP_MODE` written to `state.env` at preflight.** `preflight.sh` now accepts
  `--mode <mode>` and persists it so mode survives context resets — `finalize.sh` reads
  it directly from `state.env` and does not rely on the model remembering the invocation
  flag after a long unattended run.

## [0.2.0] - 2026-05-30

### Added

- **`scripts/bugsweep-prepare.sh` — activity-aware dirty-tree handling for unattended
  loops.** Runs before the sweep. If the tree is dirty it judges whether the work is active
  or stale: an in-progress git op or a recently-touched file makes it **defer** (exit 10,
  run skipped) so another session can finish; work idle past a threshold (default 2h) is
  **committed as-is to close the tree** so the sweep proceeds. Never parks, never
  accumulates, never discards; refuses to auto-commit onto a protected branch. Configurable
  via `BUGSWEEP_DIRTY_POLICY` / `BUGSWEEP_IDLE_SECONDS`.
- **`scripts/bugsweep-cleanup.sh` — optional post-run merge gate.** Automates the human
  merge gate for repeatable/scheduled runs: merges the verified fix branch into a branch you
  choose (optional re-test first), deletes it, and prunes old abandoned `bugsweep/*`
  branches so unattended runs don't leave a pile behind. Uses only plain git, runs after
  `finalize.sh`, and stays outside the trust contract — the skill itself still never merges
  or deletes. Refuses to act on a dirty tree or a protected branch unless explicitly forced.
- **`references/autonomous-maintenance.md`** — a recipe for repeatable, unattended runs: the
  copy-paste prompt with placeholders, cleanup settings, and headless scheduling notes
  (including that slash skills aren't available in `claude -p` mode, so the task is
  described instead).
- **Bench harness (`bench/`).** Full 4-track evaluation framework: 9-CVE detection corpus,
  bugsweep + baseline runner adapters, cross-model LLM judge (format-robust, location-aware),
  precision track scorer, leaderboard renderer, and container isolation via Docker + egress
  proxy. 197 tests covering scorer, runner, corpus, and renderer.
- **`--update` flag + passive staleness check in `install.sh`.** `install.sh --update`
  re-runs the installer to pull the latest version. Passive staleness warnings on every
  invocation when a newer tag is available.

### Fixed

- Skeptic over-conservatism calibrated — weak-grounds rejection brought into correct range.
- Stale-branch accumulation loop: `SKILL.md` now includes Step 0 stale-branch check and
  Step 5 land-or-discard handoff.
- Bash 3.2 compatibility for `bugsweep-cleanup.sh` (macOS default shell).

## [0.1.0] - 2026-05-24

First public release. bugsweep is a Claude Code and Codex skill that finds — and,
when you let it, fixes — real runtime bugs in a codebase, safely enough to run
unattended.

### Added

- **Adversarial review pipeline.** Every candidate finding runs a Hunter → Skeptic →
  Referee gauntlet so the model never rubber-stamps its own findings, keeping the
  false-positive rate low.
- **Whole-repo context model.** Builds a distilled architecture model — trust
  boundaries, sensitive sinks, and the call chains into them — to catch cross-file
  and architectural bugs, not just local ones.
- **Stack-aware research priming.** Detects languages and frameworks and primes the
  hunt with curated, per-stack anti-pattern catalogs (with optional, off-by-default
  web research for version-specific advisories).
- **Coverage-first cross-run state.** Not a diff scanner — every file is always in
  scope. Cross-run state in `.bugsweep/state/` tracks which files were audited at the
  current catalog version and prioritizes the rest.
- **Autonomous auto-fix with safety rails.** Fixes land on a throwaway
  `bugsweep/<timestamp>` branch, one commit per bug, with tests re-run after each fix
  and automatic revert on any regression. bugsweep never touches your branch, never
  pushes, never merges, never deletes files.
- **Context continuity.** All progress is persisted to disk so long unattended runs
  survive working-memory resets without losing findings, fixes, or coverage.
- **Deterministic safety layer.** The irreversible git operations (branch, stash,
  revert) live in short, auditable shell scripts in `scripts/`, not in the AI's
  judgment.
- **Universal installer.** One command installs for Claude Code, Codex, or both, with
  in-place updates.
- **Version-pinned installs.** `install.sh --version vX.Y.Z` checks out a tagged
  release instead of tracking `main`.

[Unreleased]: https://github.com/shanemhamilton/bugsweep/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/shanemhamilton/bugsweep/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/shanemhamilton/bugsweep/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/shanemhamilton/bugsweep/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/shanemhamilton/bugsweep/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/shanemhamilton/bugsweep/releases/tag/v0.1.0
