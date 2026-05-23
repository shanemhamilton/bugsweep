# bugsweep

A Claude Code skill that finds and fixes bugs in your codebase — safely enough to run
unattended, even fully autonomously overnight. It hunts for real runtime bugs (security
holes, logic errors, race conditions, bad error handling, data-integrity issues), and
when you let it, fixes them on a throwaway branch with automatic revert if a fix breaks
anything.

It does four things that make it effective on real, large codebases:
- **Whole-repo context.** Before hunting, it builds a distilled model of your
  architecture — trust boundaries, sensitive sinks, and the call chains into them — so it
  catches *large* cross-file bugs (like a missing authorization check on one path into a
  database write), not just local ones.
- **Stack-aware research.** It detects your languages/frameworks and primes itself with a
  curated library of the bugs common to that kind of code (with optional, off-by-default
  web research for version-specific advisories).
- **Adversarial review.** Every finding runs a gauntlet — a Hunter finds it, a Skeptic
  tries to disprove it, and a neutral Referee makes the final call — so false positives
  rarely reach the fix stage.
- **Context continuity.** All progress is written to disk, so on a long run it can reset
  its working memory and keep going without losing findings, fixes, or coverage.

## The one thing to understand

**The worst case for any run is a branch you delete.** bugsweep never works on your real
branch, never pushes anywhere, never merges, and never deletes files. It cuts a fresh
`bugsweep/<timestamp>` branch, makes its fixes there as one commit each, and re-runs your
tests after every fix — automatically undoing any fix that breaks something. You review
the branch and decide what to keep. You are always the merge gate.

The dangerous, irreversible operations (branching, stashing your work, reverting) are
done by short shell scripts in `scripts/` that you can read in a few minutes — not by the
AI's judgment. That's what makes it trustworthy for long unattended runs.

## Install

Drop the folder into your Claude Code skills directory:

```
git clone <your-copy> ~/.claude/skills/bugsweep
# or just copy this folder to ~/.claude/skills/bugsweep
```

Claude Code auto-discovers skills in `~/.claude/skills/`. Make the scripts executable:

```
chmod +x ~/.claude/skills/bugsweep/scripts/*.sh
```

## Use

Open Claude Code in your project and type one of:

| Command | What it does |
| --- | --- |
| `/bugsweep` | Find bugs and write a report. **Makes no changes.** Start here. |
| `/bugsweep --approve` | Find + fix, but asks you before each fix. Use this to build trust. |
| `/bugsweep --autonomous` | Find + fix in a loop until clean or a limit is hit. The overnight mode. |
| `/bugsweep src/api` | Limit the sweep to a folder or file. |
| `/bugsweep --severity high` | Only fix high/critical bugs; report the rest. |

Recommended path: run `/bugsweep` once to see what it finds, then `/bugsweep --approve`
to watch how it fixes, then `/bugsweep --autonomous` once you trust it.

## After a run

It tells you the branch name and how to review:

```
git diff <your-branch>..bugsweep/<timestamp>
```

Keep what you like (cherry-pick or merge), and delete the branch if you don't:
`git branch -D bugsweep/<timestamp>`. Your original branch and uncommitted work are
exactly as you left them.

## Configure

Edit `config/bugsweep.config.json` to set limits (how long it runs, how many fixes),
exclude folders, or specify your test/build commands if auto-detect misses them. See
`references/tuning.md`.

## What's inside

- `SKILL.md` — the instructions Claude follows.
- `scripts/` — the deterministic safety + state layer: `preflight` (branch/stash setup),
  `run_checks` (tests/build), `guard` (stop conditions), `session` (continuity anchor),
  `finalize` (safe return).
- `prompts/` — the phases, kept separate so the AI never rubber-stamps its own findings:
  `context-build` (whole-repo model), `research` (anti-pattern priming), `hunt` (local +
  architectural lenses), `challenge` (Skeptic), `referee` (final arbiter), `fix`.
- `references/` — safety rationale, the no-tests playbook, tuning notes, the
  context/continuity model, and `antipatterns/` (the curated per-stack catalogs).
- `config/bugsweep.config.json` — your settings (caps, excludes, commands, and the
  adversarial / research / session toggles).

No third-party dependencies, no network calls (unless you opt into web research), no
telemetry. Read `scripts/` and `references/safety-rationale.md` before trusting it — that's
the whole point of owning it.
