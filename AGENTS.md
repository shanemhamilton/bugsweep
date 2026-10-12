# Developing Bugsweep

These instructions apply to contributors using Codex, Claude Code, Google Antigravity
(AGY), or another capable coding agent. `CLAUDE.md` and `GEMINI.md` point here; edit
this canonical file, not its symlinks. These are development instructions, not the
operating contract for an installed Bugsweep skill. For that, read `SKILL.md`.

## Portable workflow

No orchestration plugin is required. Use the host's available file, search, shell,
planning, and review tools. Do not assume another host's tool names, slash commands,
model IDs, or session APIs exist. If a capability is unavailable, say so and use a
supported equivalent without weakening execution, proof, or approval boundaries.

### Start a task

Read the request, relevant source, `CONTRIBUTING.md`, and applicable instructions.
Check the working tree and preserve unrelated edits. Define observable completion
criteria and select focused verification before editing. For substantial work, keep
a short plan in the host's plan tool or conversation; no planning plugin is required.
Ask only for information or authorization the task actually needs.

Use direct implementation for bounded changes. Delegate independent work when it
saves time or provides needed review, with explicit file ownership and self-contained
instructions. Workers must not revert one another's changes. Use native subagents
when available; a missing subagent API does not prevent sequential investigation.

### Prime or resume

Read the task's existing issue, PR, commit, and recorded evidence. Verify the current
source revision and unfinished work before proceeding. Use an existing tracker when
available; neither Beads nor a particular memory or task plugin is required. Preserve
continuation details in the existing task record or commit body, not new handoff files.

### Brainstorm and review a design

When the problem is ambiguous, establish the trigger, expected behavior, constraints,
and a concrete example. Compare existing solutions before adding a helper or dependency.
For consequential changes, review the actual proposal for correctness, compatibility,
security, recovery, and testability. Use independent review where risk warrants it;
do not require a fixed panel size or manufacture defects to satisfy a quota.

### Implement and verify

For runtime changes, write a regression that exposes the failure before the fix.
Update the producer, consumer, schema, and documentation together when a contract
changes. Keep test and proof requirements intact. Do not claim verification from
reasoning, fixtures alone, or a worker's summary; inspect the evidence.

Read `.coverage-thresholds.json`; the CI gate requires at least 80% aggregate line
and branch coverage for scorer and installer helper separately. Bash behavior is
covered by Bats. Follow `CONTRIBUTING.md` for the pinned tools and quality commands.
Use the execution location authorized for the session; local instructions can require
remote CI. GitHub Actions covers Linux and macOS with Python 3.12 and 3.13.

Bash helpers target Bash 3.2. Reuse the shared execution, serialization, review, and
proof services documented in `SERVICE-INVENTORY.md`. Never add a host-shell fallback
for audited project commands or relax evidence gates to support a new agent host.

### Self-reflection

Before closing meaningful work, compare the result with the request. Record only new,
verified lessons that will prevent a repeat failure, in an existing relevant document,
test, issue, or commit body. A short commit note is sufficient; do not create a knowledge
base, invoke a plugin, or invent a lesson just to satisfy a ceremony. State what was
verified and what remains unverified.

### Shepherd a pull request

Inspect the exact PR head, review comments, and CI results. Fix confirmed failures and
rerun affected checks without weakening them. Follow the user's commit, push, merge,
and release authorization; creating a PR does not authorize merging or publishing.
Never force-push a shared branch, bypass failing checks, amend others' commits, or skip
hooks. A PR description should explain behavior, validation, and remaining limitations.

## Optional Metaswarm integration

Metaswarm is an optional contributor tool. Use it only when installed and explicitly
selected by the user for the task. Its namespaced commands can help with planning,
review, and reflection, but the portable workflow above is the complete fallback.
Missing Metaswarm never blocks development, testing, review, or skill execution.
The `.claude/commands/` shortcuts follow this same rule; Codex and AGY can follow the
sections above directly. `.metaswarm/` contains optional integration configuration,
not runtime requirements. Installed skill payloads omit these contributor surfaces.

## Evidence and scope

Keep fixes narrow, preserve user files, and cite source locations for code claims.
Model confidence, candidate counts, and scanned files do not establish improved bug
detection. CI verifies local contracts; live host compatibility, runtime oracles,
containment, and calibrated evaluation need their own evidence. Do not conflate a
merged change, a published release, and a deployed webpage.
