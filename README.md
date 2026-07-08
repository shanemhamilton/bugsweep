# bugsweep — AI bug hunting & auto-fix for your codebase

[![Release](https://img.shields.io/github/v/release/shanemhamilton/bugsweep?sort=semver&label=release&color=2563eb)](https://github.com/shanemhamilton/bugsweep/releases)
[![License: MIT](https://img.shields.io/github/license/shanemhamilton/bugsweep?color=2563eb)](LICENSE)
[![Works with Claude Code](https://img.shields.io/badge/Claude%20Code-skill-d97757)](https://claude.ai/code)
[![Works with Codex](https://img.shields.io/badge/Codex-skill-412991)](https://github.com/openai/codex)
[![Dependencies: none](https://img.shields.io/badge/dependencies-none-2563eb)](#configure)

> **An autonomous, adversarial AI code-review and bug-fixing skill for [Claude Code](https://claude.ai/code) and [Codex](https://github.com/openai/codex).** It finds real security vulnerabilities, logic errors, race conditions, and data-integrity bugs across your whole repository — then, when you let it, fixes them on a throwaway git branch you fully control. Safe enough to run unattended overnight.

A Claude Code and Codex skill that finds and fixes bugs in your codebase — safely enough
to run unattended, even fully autonomously overnight. It hunts for real runtime bugs
(security holes, logic errors, race conditions, bad error handling, data-integrity
issues), and when you let it, fixes them on a throwaway branch with automatic revert if a
fix breaks anything.

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

**The worst case for any core run is a branch you delete.** bugsweep never works on your
real branch during the hunt/fix loop, never pushes anywhere, never merges, and never
deletes files. It cuts a fresh `bugsweep/<timestamp>` branch, makes its fixes there as one
commit each, and re-runs your tests after every fix — automatically undoing any fix that
breaks something. You review the branch and decide what to keep. You are always the merge
gate.

The dangerous, irreversible operations (branching, stashing your work, reverting) are
done by short shell scripts in `scripts/` that you can read in a few minutes — not by the
AI's judgment. That's what makes it trustworthy for long unattended runs.

## How it works

### Full run pipeline

```mermaid
flowchart TD
    A(["/bugsweep invoked"]) --> B

    subgraph scripts ["⚙️ Shell scripts — deterministic, auditable"]
        B["preflight.sh\ncut bugsweep/&lt;timestamp&gt; branch\nstash uncommitted work\nwrite RUN_DIR + ledger"]
        C["run_checks.sh baseline\nrecord test / build / lint state"]
        L["run_checks.sh verify\ndiff against baseline"]
        Q["guard.sh\ncheck iteration / time / fix caps"]
        FIN["finalize.sh\nrestore original branch\npop stash\npersist audit coverage\nwrite handoff JSON"]
    end

    subgraph ai ["🤖 AI phases — reasoning only, no git ops"]
        D["context-build\nbuild whole-repo model\narchitecture · trust boundaries\nsensitive sinks · call chains"]
        E["research\nprime with stack-specific\nanti-pattern catalogs"]
        F["hunt\nbatch through files\nHunter generates candidates"]
        G["challenge\nSkeptic tries to disprove\neach candidate"]
        H["referee\nneutral final verdict"]
        K["fix.md\nsurgical minimal patch\none commit per confirmed bug"]
    end

    B --> C --> D --> E --> F --> G --> H
    H --> |detect-only| RPT["📄 write report\nno code changes"]
    H --> |fix / approve / autonomous| K
    K --> L
    L --> |pass| N["commit fix\nappend to ledger"]
    L --> |fail| O["auto-revert\nquarantine bug"]
    N --> Q
    O --> Q
    RPT --> FIN
    Q --> |CONTINUE| F
    Q --> |STOP| FIN
    FIN --> HANDOFF["post-finalize handoff\nbranch preserved\none compound next action"]
    HANDOFF --> DECIDE{"User replies do it?"}
    DECIDE --> |"No"| R(["Review manually\ngit diff main..bugsweep/&lt;timestamp&gt;"])
    DECIDE --> |"Yes"| LAND["land preserved branch\nre-run proof on target\npush if safe\nsmoke + remote read-back\ncleanup merged branch"]
```

### Adversarial review — why bugsweep has a low false-positive rate

Every candidate finding runs a three-role gauntlet before it can be fixed or reported. The model never evaluates its own findings.

```mermaid
flowchart LR
    H["🔍 **Hunter**\n`hunt.md`\nfinds candidate bug\nwith supporting evidence"]
    S["🛡️ **Skeptic**\n`challenge.md`\ntries to disprove:\nalternate explanations\ncode paths that prevent the bug\ntest coverage that catches it"]
    R["⚖️ **Referee**\n`referee.md`\nneutral final verdict\nbased on both sides"]

    H --> S --> R

    R --> |"Confirmed\n(high confidence)"| FIX["Promoted to fix queue"]
    R --> |"Dismissed or uncertain"| DISC["Dropped — not fixed\nnot reported"]
```

### Coverage-first state — how bugsweep finds bugs in old, unchanged code

bugsweep is not a diff scanner. Every file in the repo is always in scope. Cross-run state lets it track which files have been reviewed at the current catalog version and prioritize the ones that haven't.

```mermaid
flowchart TD
    subgraph state ["📁 .bugsweep/state/  (persists across runs)"]
        AL["audit-log.jsonl\nper-file: last-audited run, catalog version"]
        RJ["risk.jsonl\nrisk scores per file"]
        MJ["meta.json\ncurrent catalog version"]
    end

    P["preflight.sh\n→ state.sh prime"] -->|reads state| PC["prior-coverage.json\nbatch priority plan"]

    PC --> T1["**Tier 1 — Critical**\nnever-audited\nstale (catalog bumped)\ncontent-changed\nhigh-risk\nsink-bearing"]
    PC --> T2["**Tier 2 — Re-confirm**\nrecently audited, fresh"]

    T1 --> HUNT["hunt loop"]
    T2 --> HUNT

    HUNT --> FIN["finalize.sh\n→ state.sh persist\nupdate audit-log + risk\nwrite handoff JSON"]
    FIN -->|next run| P
```

## Install

**One command — works for Claude Code, Codex, or both:**

```bash
curl -fsSL https://raw.githubusercontent.com/shanemhamilton/bugsweep/main/install.sh | bash
```

The script auto-detects which AI tools you have installed (`~/.claude` → Claude Code,
`~/.codex` → Codex) and sets up each one. Re-running it updates in place.

**Force a specific tool:**

```bash
# Claude Code only
curl -fsSL https://raw.githubusercontent.com/shanemhamilton/bugsweep/main/install.sh | bash -s -- --claude

# Codex only
curl -fsSL https://raw.githubusercontent.com/shanemhamilton/bugsweep/main/install.sh | bash -s -- --codex

# Both
curl -fsSL https://raw.githubusercontent.com/shanemhamilton/bugsweep/main/install.sh | bash -s -- --all
```

**Pin to a specific release** (instead of tracking the latest `main`):

```bash
curl -fsSL https://raw.githubusercontent.com/shanemhamilton/bugsweep/main/install.sh | bash -s -- --version v0.1.0
```

Re-running the installer with `--version` checks out that release tag; re-running without
it returns you to the latest `main`. See [releases](https://github.com/shanemhamilton/bugsweep/releases)
and the [CHANGELOG](CHANGELOG.md).

**Manual install (if you prefer to inspect first):**

```bash
git clone https://github.com/shanemhamilton/bugsweep.git
bash bugsweep/install.sh          # then delete the clone — it installs to ~/.claude or ~/.codex
```

**What the installer does:**
- *Claude Code* — clones to `~/.claude/skills/bugsweep/`. Claude Code auto-discovers skills
  there; no config needed.
- *Codex* — clones to `~/.codex/skills/bugsweep/` and appends a stub to
  `~/.codex/instructions.md` so Codex knows where the scripts live.

## Use

Open Claude Code (or start Codex) in your project and type one of:

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

It also writes `<RUN_DIR>/post-finalize-handoff.json`, a machine-readable handoff with the
preserved branch, report path, fix commits, quality gate, smoke checks, push policy,
cleanup policy, deletion proof, and final read-back commands.

For `/bugsweep --autonomous`, the recommended next step is intentionally one compound
approval:

> Reply `do it` to land the preserved branch, re-run proof on the target branch, push if
> safe, run configured smoke checks, verify remote read-back, and delete the now-merged
> bugsweep branch.

That does not weaken the trust contract. The core run still stops at finalize and leaves
the fixes stranded on `bugsweep/<timestamp>` until you approve the continuation. The
approved follow-through uses the handoff JSON and the optional cleanup script so a parent
agent does not need to ask again after the merge.

Branch deletion is allowed only after proof that the branch is contained in the target
branch (`git merge-base --is-ancestor <branch> <target>`). If the branch is checked out in
a linked worktree, cleanup removes that worktree only when it is clean: no unstaged
changes, no staged changes, and no untracked files. Dirty worktrees and unmerged branches
are preserved.

Manual review still works the same way: keep what you like with a cherry-pick or merge, or
discard explicitly if you decide the branch is not worth keeping. Your original branch and
uncommitted work are exactly as you left them.

## Overnight orchestrator

Running bugsweep on a schedule makes it dig deeper over time on its own — coverage-first
cross-run state means each run prioritizes the files it hasn't audited yet. On top of that,
a set of shipped capabilities turn a single run into something a headless scheduler or a
fleet of concurrent runs can drive without a human watching:

- **A machine contract, not prose.** `finalize.sh` always writes
  `<RUN_DIR>/run-summary.json`, reduced from the run's ledger by `scripts/summarize.sh`
  against [`schemas/run-summary.schema.json`](schemas/run-summary.schema.json): `status`
  (`complete` / `partial` / `stalled`), severity `counts`, `fixed` / `quarantined` /
  `confirmed_unfixed`, and per-finding detail — so a scheduler can branch on JSON instead of
  parsing model output. If the full reduction can't run (no `python3`, or it fails for any
  reason), a minimal schema-valid summary with `"degraded": true` is emitted instead.
  Either way, `run-summary.json` exists after every finalize.
- **Worktree isolation for concurrency.** `preflight.sh --worktree` checks the run out into
  an isolated linked git worktree instead of the user's tree, so a fleet of sibling
  subagents can hunt the same repo at the same time without colliding on one branch, index,
  or stash — and without ever touching the user's checkout (no stash is taken, so there's
  nothing to restore).
- **A deadline that always finalizes.** The runtime cap is a hard checkpoint the loop
  checks every iteration (`guard.sh`); hitting it routes straight to `finalize.sh`, so a run
  that runs out of time still restores the original branch and writes its report, summary,
  and handoff instead of dying mid-fix.
- **Crash-safe teardown.** The optional reaper (`bugsweep-cleanup.sh --reap-worktrees`,
  also called by preflight/finalize themselves) reclaims a worktree or branch only on
  positive evidence its run is dead or done — a `.finalized` sentinel, or an expired lease.
  Anything ambiguous, dirty, or unmerged is preserved and reported, never guessed away.
- **Landing more than one fix branch safely.** `scripts/integrate.sh` merges an ordered
  list of already-verified branches into a target one at a time, re-running the quality
  gate after *each* merge — a fix that was green in isolation can go red once a sibling's
  fix lands. The first conflict or failure stops cleanly, leaves the target at its last
  good state, and preserves every remaining branch for the orchestrator to reorder or defer.
- **Flaky-aware revert, honestly caveated.** Trust-contract rule 5's regression check
  reruns a newly-failing test up to `.verify.flaky_reruns` (default `3`) times; only a
  strict majority of passing reruns reclassifies it FLAKY and skips the revert. The reruns
  share the run's tree and environment rather than running in full isolation, so this tells
  you "failed vs. passed the majority," not a provably deterministic-vs-flaky distinction —
  and any fix that lands with a flaky classification is written to `flaky.jsonl` and
  surfaced loudly in the ledger and summary, never silently.
- **Optional analyzer corroboration — off by default.** Set `analyzers.enabled: true` in
  `config/bugsweep.config.json` and `scripts/analyzers.sh` runs whatever off-the-shelf
  static analyzers you have installed (semgrep, gosec, bandit, ...) before the hunt,
  feeding their hits in as one more corroboration signal for the Referee — never a
  replacement for adversarial review.

The only thing that still accumulates across runs is one `bugsweep/<timestamp>` branch (or
worktree) per run, because none of the above lets bugsweep merge or delete on its own — you
are still the merge gate. The optional companion script `scripts/bugsweep-cleanup.sh`
automates that gate *after* finalize and after approval: it merges a verified fix branch
into a branch you choose, deletes only branches proven contained in that target, and
preserves dirty worktrees or unmerged branches — using only plain git, outside the core
hunt/fix loop. See
[`references/autonomous-maintenance.md`](references/autonomous-maintenance.md) for the
copy-paste prompt, settings, and scheduling notes.

## Configure

Edit `config/bugsweep.config.json` to set limits (how long it runs, how many fixes),
exclude folders, or specify your test/build commands if auto-detect misses them. See
`references/tuning.md`.

## FAQ

**How is bugsweep different from Snyk, CodeQL, SonarQube, or Dependabot?**
Those are mostly pattern/diff scanners and dependency auditors. bugsweep is an *agentic*
reviewer: it builds a whole-repo architecture model and reasons about behavior, so it
catches cross-file logic bugs (like a missing authorization check on one path into a
database write) that pattern matchers miss. It complements those tools rather than
replacing them — and it can fix what it finds, not just flag it.

**What languages and frameworks does it support?**
Any language Claude Code or Codex can read. It ships curated anti-pattern catalogs for
common stacks (JavaScript/TypeScript, Python, Go, Swift/iOS, Kotlin, and React) and detects
your stack automatically to prime the hunt.

**Is it safe to run on a production codebase?**
Yes — that's the design center. bugsweep never works on your branch, never pushes, never
merges, and never deletes files. It cuts a throwaway `bugsweep/<timestamp>` branch, and
the irreversible git operations are short shell scripts you can audit in minutes. The
worst case for any run is a branch you delete.

**Does bugsweep send my code anywhere?**
No third-party services, no telemetry, and no network calls — unless you explicitly opt
into bounded web research for version-specific advisories (off by default). Your code
goes only to the AI tool you already use.

**Can it run unattended or in CI?**
Yes. `/bugsweep --autonomous` runs a find-and-fix loop until the codebase is clean or a
configured limit (time, iterations, or fix count) is hit, re-running your tests after
every fix. State persists to disk so long runs survive context resets. Landing, pushing,
smoke checks, remote read-back, and branch cleanup happen through the explicit
post-finalize continuation so the merge gate stays visible.

**Does it work with OpenAI Codex too, or just Claude Code?**
Both. The installer sets up whichever you have (`--claude`, `--codex`, or `--all`).

## What's inside

- `SKILL.md` — the instructions Claude follows.
- `scripts/` — the deterministic safety + state layer: `preflight` (branch/stash setup),
  `run_checks` (tests/build), `guard` (stop conditions), `session` (continuity anchor),
  `finalize` (safe return plus `post-finalize-handoff.json`). Plus two *optional*,
  user-owned companions for scheduled runs (outside the core hunt/fix loop):
  `bugsweep-prepare.sh` (if the tree is dirty, it defers to an active session or commits
  genuinely idle work to close the tree — never parks, never discards) and
  `bugsweep-cleanup.sh` (the post-run merge gate; the only script that merges or deletes,
  and only when you choose to run it).
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
