# Changelog

All notable changes to bugsweep are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

## [0.1.0] - 2026-05-24

First public release. bugsweep is a Claude Code and Codex skill that finds — and,
when you let it, fixes — real runtime bugs in a codebase, safely enough to run
unattended.

### Added

- **Adversarial review pipeline.** Hunter → Skeptic → Referee gauntlet.
- **Whole-repo context model.** Trust boundaries, sensitive sinks, call chains.
- **Stack-aware research priming.** Per-stack anti-pattern catalogs.
- **Coverage-first cross-run state.** Every file always in scope.
- **Autonomous auto-fix with safety rails.** Throwaway branch, one commit per bug, auto-revert.
- **Context continuity.** Progress persisted to disk.
- **Deterministic safety layer.** Ireversible ops in auditable shell scripts.
- **Universal installer.** Claude Code, Codex, or both.

[Unreleased]: https://github.com/shanemhamilton/bugsweep/compare/v0.1.0...HEAD

[0.1.0]: https://github.com/shanemhamilton/bugsweep/releases/tag/v0.1.0
