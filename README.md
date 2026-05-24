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
        FIN["finalize.sh\nrestore original branch\npop stash\npersist audit coverage"]
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
    FIN --> R(["User reviews\ngit diff main..bugsweep/&lt;timestamp&gt;"])
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

    HUNT --> FIN["finalize.sh\n→ state.sh persist\nupdate audit-log + risk"]
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
