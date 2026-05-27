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

[Unreleased]: https://github.com/shanemhamilton/bugsweep/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/shanemhamilton/bugsweep/releases/tag/v0.1.0
