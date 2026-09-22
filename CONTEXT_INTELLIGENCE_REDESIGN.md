# bugsweep — Context Intelligence Redesign
**Status:** Research complete. Phase 1 (coverage-first) implementation STARTED.
**Session date:** 2026-05-23

---

## ⚠️ DIVERGENCE FROM THIS DOC (2026-05-23): change-first → coverage-first

This document, as originally written, is **change-first**: its Tier-1 `index.json` leads
with `dirty_since_last_run` and `transitive_dependents_of_dirty`, and whole-repo coverage
is demoted to "then remaining files." That design risks degrading into a diff-only scanner
that under-audits unchanged-but-never-reviewed code — the opposite of bugsweep's core
value (finding latent bugs across an entire existing repo, then continuing to find new ones
as code changes).

We have pivoted to **coverage-first**. The durable state of record is an **audit ledger**,
not the diff. On every run the hunt queue spans the WHOLE repo; the front of the queue is
the union of five signals — `never-audited ∪ stale-audited ∪ content-changed ∪ high-risk ∪
all sink-bearing` — and the diff is just ONE of those signals, never a gate. The repo is
never "done": a file re-enters the frontier when it was never audited at the current
anti-pattern catalog version, or audited too many runs ago. This makes the first run on a
freshly-added existing repo correct by construction (everything is "never-audited").

### Implemented so far (Phase 1, coverage-first)
- `scripts/state.sh` — `persist` / `prime` / `catalog-version`. Cross-run state in
  `.bugsweep/state/` (`audit-log.jsonl`, `risk.jsonl`, `meta.json`). python3 engine with a
  graceful degrade that always widens to whole-repo scope, never narrows or fails a run.
- `references/antipatterns/VERSION` — catalog version stamped on every audit event; bump it
  when catalogs gain detection so old files re-enter the frontier.
- `scripts/preflight.sh` — runs `state.sh prime`, surfaces prior coverage, writes
  `<RUN_DIR>/prior-coverage.json`.
- `scripts/finalize.sh` — runs `state.sh persist` before restoring the user's branch.
- `prompts/context-build.md` — coverage-first contract: whole repo always in scope; prior
  coverage only reorders batches; frontier (`never-audited ∪ stale ∪ high-risk ∪ sinks`)
  leads; fresh-audited files go to a final re-confirmation tier.
- `config/bugsweep.config.json` — `context.{decay_factor,high_risk_top_n,recheck_audited_after_runs}`.
- Docs: `references/context-and-continuity.md` (intra-run vs cross-run + coverage-first
  contract), `SKILL.md` Steps 2 & 5.

### What changes in the schema below
- `index.json`'s change-centric Tier-1 is **superseded** by `prior-coverage.json`
  (coverage-centric) + `audit-log.jsonl`. `risk.jsonl` and the decayed risk formula are
  retained as designed.
- The 40% cold-start threshold is **dropped**: under coverage-first a large changeset does
  not invalidate the cache, it just reshuffles the queue.
- Manifest + sha256 + import-graph (the report's Phase 1a/Phase 2) are demoted to a future
  **performance** layer that sits on top of the now-correct coverage model — content-hash
  becomes the `content-changed` signal, the graph widens it to dependents. They are no
  longer prerequisites.

The original research below remains valid and is the basis for the retained pieces (risk
decay, ID stability, hybrid evaluation, PEEK constant-size context). Read it for rationale;
treat the coverage-first note above as the authority where they conflict.

---

---

## Problem Statement

bugsweep currently rebuilds its entire `repo-context.md` from scratch on every run by reading the whole codebase. This is:
- Expensive in context tokens on every invocation
- Wasteful — unchanged code is re-read identically each time
- Non-learning — previous runs' findings don't influence where the next run looks
- Slow to rehydrate after a mid-run context reset

The goal is a **persistent, self-learning context layer** that:
- Survives across runs (stored in `.bugsweep/` at repo root)
- Detects changed files via git diff and only re-analyzes those + their transitive dependents
- Accumulates historical risk signals (which files have historically had bugs)
- Keeps the persistent index small enough to load into a Claude Code context window at session start (~7–8KB for Tier 1)
- Works entirely on pure git + filesystem — no external databases, no network calls, no embeddings

---

## Research Summary

Researched 6 production systems (CodeQL, Semgrep, Cursor, Aider, Sourcegraph Cody, PEEK) and 4 academic sources (IncA, DRedL, incremental interprocedural analysis, time-weighted risk scoring). All six production tools independently converge on the same architecture.

### Key Findings Per Source

#### CodeQL (GitHub, 2025–2026)
- Ships incremental analysis across all languages; up to **80% faster PR scans**
- Architecture: serialized data-flow graphs + derived-fact caches from prior baseline; on change, semantic delta engine diffs at syntax-tree level; Partial Graph Unification merges new analysis of changed code with cached facts for unchanged code
- **Function Summaries:** unchanged functions are represented by their effect on data-flow (not re-analyzed internally); callers use the summary as a contract
- **Critical lesson — ID Stability:** original trap importer used sequential counter IDs; a one-line edit shifted IDs for every subsequent AST node → flood of spurious cache invalidations → total reuse collapse. Fix: stable IDs from AST node paths (`r_1_3` = root→child1→child3), prefixed with file path and hashed. Without this, any incremental system degrades to full rebuild on minor changes.
- **Hybrid evaluation beats fully-incremental:** non-recursive predicates run from scratch; only recursive/transitive ones are maintained incrementally. Full incrementalization = ~70GB RAM + ~1hr init. Hybrid = ~20GB + ~15min init with sub-minute PR updates.
- Source: arXiv 2308.09660 ("Incrementalizing Production CodeQL Analyses", Szabó)

#### Semgrep
- Git-baseline differential scanning: `SEMGREP_BASELINE_REF` or `SEMGREP_BASELINE_COMMIT`
- Runs full rules but only surfaces findings **not present at baseline**; skips unchanged files entirely
- Does **not** maintain a persistent cross-run knowledge model — no accumulated risk, no architecture model
- This is the floor bugsweep should surpass (scope improvement but no learning)
- Source: semgrep.dev/docs/kb/semgrep-ci/trigger-diff-scans-env-var

#### Cursor
- Merkle tree over content-hashed chunks; every 10 minutes checks for hash mismatches; only changed chunks re-embedded
- Change detection is **pure hashing** — the cloud vector DB is just storage; the detection layer needs no cloud
- Flat-file equivalent: `manifest.json` mapping `path → {sha256, mtime}` is sufficient for bugsweep (no Merkle tree needed at repo scales a single Claude session handles)
- Source: read.engineerscodex.com/p/how-cursor-indexes-codebases-fast

#### Aider (verified from source code: `aider/repomap.py`)
- **Zero embeddings, zero external databases**
- Pipeline:
  1. Parse every file with tree-sitter → extract symbol definitions and references ("tags")
  2. Cache tags per-file by mtime in `.aider.tags.cache.v*` — unchanged files never re-parsed
  3. Build symbol graph: edges connect files that *reference* a symbol to files that *define* it
  4. Run `networkx` PageRank with **personalization** toward files currently in context (dirty set in bugsweep's case)
  5. Render top-ranked symbols into a token-budgeted text blob
- Key insight: **personalized PageRank is the retrieval mechanism** — surfaces files connected to current concern without semantic embeddings
- Git integration: operates directly on git working tree; tracks dirty files via git status/diff; mtime cache invalidation per file

#### Sourcegraph Cody
- Three-layer retrieval: local file context → local repo context via symbol index (ctags-style, persistent) → remote context via code search + optional embeddings
- Durable layer is the **symbol index** — embeddings are a re-ranking add-on, not the foundation
- Validates embedding-free approach: symbol search is the reliable, fast, persistent baseline

#### PEEK Pattern (arXiv 2603.19935)
- Persistent, **constant-sized** context map caching orientation knowledge for LLM agents
- Fixed token budget regardless of repo size
- Contents: highest-value orientation facts only (architecture summary, top-risk files, trust boundaries)
- Reloaded at every session start / context reset — always current, always bounded
- Quantified result: tree-sitter knowledge graph achieves **83% of file-exploration quality at 10× fewer tokens** (Codebase-Memory paper, arXiv 2603.27277)

#### IncA / DRedL (OOPSLA 2018, Szabó et al.)
- Incremental Datalog evaluation for lattice-based program analyses
- **Support counts** as the invalidation primitive: each derived fact tracks how many independent derivations support it; a fact is removed only when count reaches zero (handles "multiple code paths independently justify same finding")
- Persistable data structures (file-friendly):
  1. Base-fact files (EDB) — AST as extensional predicates
  2. Relation-dependency edge file — which derived relations depend on which inputs
  3. Per-tuple support counts
  4. Per-group support multisets (for aggregated values like "worst severity across call sites")
- **Monotonicity insight:** when a deletion + insertion is an *increasing replacement* (new value ≥ old in the lattice), skip expensive delete-and-rederive; only monotonic propagation needed. For bugsweep: upgrading a finding from MEDIUM→HIGH severity doesn't require re-deriving from scratch.

#### Time-Weighted Risk Scoring (Microsoft Research, Opsera)
- Files in both churn hotspot set AND bug-commit set are highest-risk code
- Time-weighted bug density outperforms complexity metrics for defect prediction
- **No ML required** — computable entirely from git log
- Formula: `score = Σ [ weight(event) × decay^(age_in_runs) ]`
  - weights: fix_committed=3, quarantine=2, confirmed=1, false_positive=-1
  - decay: 0.85 (configurable)
- Secondary git-derivable signals: author count, commit frequency last 90 days, rollback rate

---

## The Unified Architecture (what all sources agree on)

```
┌──────────────────────────────────────────────────────────────────┐
│  TIER 1: index.json (~7–8KB)  ← only thing loaded into context   │
│  Constant-size. Risk-ranked. Warm/cold start decision.           │
│  dirty set + transitive dependents + top-N risk files.           │
├──────────────────────────────────────────────────────────────────┤
│  TIER 2: manifest, symbols, graph  ← script-only, never in ctx  │
│  manifest.json: path → {sha256, mtime}  (change detection)      │
│  symbols.json:  path → {defines, refs}  (symbol table)          │
│  graph.json:    path → [dependency paths]  (import graph)        │
├──────────────────────────────────────────────────────────────────┤
│  TIER 3: risk.jsonl  ← append-only learning log                  │
│  One line per finding event. Source of decayed risk scores.      │
│  Written by finalize.sh; read by index.sh at index-build time.   │
└──────────────────────────────────────────────────────────────────┘
```

**Change detection:** `git diff --name-only <last_head>..HEAD` → dirty set
**Impact expansion:** BFS over `graph.json` reverse edges from dirty set (depth 2–3)
**Context loading:** Only Tier 1 (`index.json`) enters the model's context window at session start
**Hunt scope (warm):** `dirty ∪ transitive_dependents ∪ top_risk_files ∪ architectural_targets`
**Learning write-back:** `finalize.sh` appends ledger events to `risk.jsonl` after every run

---

## Concrete Design

### Directory Structure

```
.bugsweep/                    ← repo root, gitignored, survives across runs
  index.json                  ← Tier 1 (~7–8KB), loaded into context at warm start
  manifest.json               ← path → {sha256, mtime}, script-only
  symbols.json                ← path → {defines, refs}, script-only
  graph.json                  ← path → [deps], script-only
  risk.jsonl                  ← append-only event log, script-only
  last_run.json               ← {head_sha, ended_at, run_id, schema}
```

### index.json Schema (Tier 1)

```json
{
  "schema": 1,
  "repo": "myapp",
  "head_sha": "a1b2c3d",
  "last_run": {
    "head_sha": "9f8e7d6",
    "ended_at": "2026-05-20T11:02:00Z",
    "runs": 7
  },
  "stats": {
    "files_tracked": 412,
    "sinks": 23,
    "trust_boundaries": 5
  },
  "dirty_since_last_run": [
    "src/auth/session.ts",
    "src/payments/charge.ts"
  ],
  "transitive_dependents_of_dirty": [
    "src/api/checkout.ts",
    "src/api/login.ts"
  ],
  "top_risk_files": [
    {
      "p": "src/payments/charge.ts",
      "score": 9.1,
      "fixes": 4,
      "sinks": ["money-math", "db-write"],
      "last_bug_run": 6
    },
    {
      "p": "src/auth/session.ts",
      "score": 7.8,
      "fixes": 3,
      "sinks": ["authz"],
      "last_bug_run": 7
    }
  ],
  "architectural_targets": [
    "verify authz on all paths into src/db/query.ts:execRaw",
    "trace untrusted body -> src/payments/charge.ts:applyDiscount"
  ],
  "warm_start": true,
  "dirty_truncated": false
}
```

**Byte budget rules:**
- Cap `top_risk_files` at 25 entries (use short keys: `p`, not `path`)
- Cap `dirty_since_last_run` + `transitive_dependents_of_dirty` at 30 entries total; set `dirty_truncated: true` if exceeded and fall back to manifest scan for the remainder
- Cap `architectural_targets` at 10 entries
- Target total ≤ 8KB before pretty-printing; minify if over

### risk.jsonl Schema (Tier 3)

One JSON object per line, append-only:

```jsonl
{"run":7,"file":"src/payments/charge.ts","event":"fix_committed","bug_id":"BS-042","severity":"critical","ts":"2026-05-20T11:01:00Z"}
{"run":7,"file":"src/auth/session.ts","event":"confirmed","bug_id":"BS-043","severity":"high","ts":"2026-05-20T11:01:30Z"}
{"run":6,"file":"src/db/query.ts","event":"quarantine","bug_id":"BS-031","severity":"high","ts":"2026-05-15T09:20:00Z"}
{"run":5,"file":"src/payments/charge.ts","event":"false_positive","bug_id":"BS-021","ts":"2026-05-10T14:00:00Z"}
```

### Risk Score Formula

Applied by `scripts/index.sh` at index-build time:

```python
# Configurable from bugsweep.config.json
DECAY = 0.85
WEIGHTS = {
    "fix_committed": 3,
    "quarantine": 2,
    "confirmed": 1,
    "false_positive": -1,
}

def score(file_events, current_run):
    return sum(
        WEIGHTS.get(e["event"], 0) * (DECAY ** (current_run - e["run"]))
        for e in file_events
    )
```

**Critical guard:** risk score is *ranking only*, never a gate. Any file containing a configured sink pattern (money-math, authz, sql, exec, crypto, deserialization) is always in hunt scope regardless of risk score. Risk reorders batches; it must never exclude a sink-bearing file.

### ID Stability for Architectural Targets

Architectural targets and sink locations **must be keyed by function name + call name, not line number.** Line numbers shift whenever code above is added or removed. Key format:

```
<relative/file/path>:<containing-function>:<sink-call-name>
```

Example: `src/db/query.ts:executeQuery:execRaw` — stable through most refactors, reformatting, and comment changes.

---

## Warm vs. Cold Start Logic

### Decision Tree (for `preflight.sh`)

```
if .bugsweep/index.json exists:
    if schema version matches:
        if last_run.head_sha resolves in git:
            changed_count = git diff --name-only <last_head>..HEAD | wc -l
            if changed_count / total_files < 0.40:
                WARM START
            else:
                COLD START  # large rebase/merge — trust increment is unsafe
        else:
            COLD START  # force-push, rebased history
    else:
        COLD START  # schema upgraded — format changed
else:
    COLD START  # first ever run
```

**40% threshold rationale:** When >40% of files changed, incremental scoping risks missing cross-cutting regressions. Full rebuild is safer and the performance cost is proportionate.

### Warm Start Flow

1. `preflight.sh` → detects warm start → reads `index.json` into context
2. Model receives Tier 1: dirty set, transitive dependents, top-risk files, architectural targets
3. Step 2 (context build) runs in **patch mode**: only re-reads dirty + dependent files; splices updated summaries into the cached architecture prose; does NOT read the whole repo
4. `recon.json` batch plan seeded: dirty ∪ dependents ∪ top_risk first (critical tier), then remaining files
5. Hunt proceeds with full scope awareness but minimal context cost

### Cold Start Flow

1. `preflight.sh` → detects cold start → proceeds exactly as today
2. `context-build.md` phase runs in full (unchanged behavior)
3. After full build: `scripts/index.sh build` writes `.bugsweep/` from scratch
4. `finalize.sh` → `scripts/index.sh update` → `risk.jsonl` append
5. Next run will be a warm start

---

## Migration Map (Existing Files → New Behavior)

| Existing file | Today | Post-redesign |
|---|---|---|
| `prompts/context-build.md` | Full rebuild every run | Add warm-start branch: patch mode for dirty+dependents only. Cold start path unchanged. |
| `references/context-and-continuity.md` | Describes per-run persistence | Extend: document `.bugsweep/` (cross-run) vs run-dir (intra-run). Explain warm/cold decision. |
| `scripts/preflight.sh` | Creates branch, stashes work | Add warm/cold start detection; load `index.json` on warm start. |
| `scripts/finalize.sh` | Restores user's branch | Add: `index.sh update` call; append ledger events to `risk.jsonl`. |
| `scripts/session.sh` | Writes SESSION.md | Add: warm/cold indicator + dirty-set size to SESSION.md for post-reset context. |
| `scripts/common.sh` | Shared utilities | Add: `require_bugsweep_cache`, `load_index` helpers. Reuse `cfg_get` pattern for new scripts. |
| `config/bugsweep.config.json` | Current config | Add: `context.decay_factor` (default 0.85), `context.cold_start_threshold` (default 0.40), `context.tier1_max_kb` (default 8). |
| *(new)* `scripts/index.sh` | — | New script: `build`, `diff`, `update`, `score` subcommands. The core of the new system. |
| *(new)* `.bugsweep/` | — | New repo-root persistent cache directory. Add to install.sh `.gitignore` injection. |

---

## Implementation Plan (Recommended Order)

### Phase 1 — Foundation (highest leverage, lowest risk)

**1a. `scripts/index.sh build` subcommand**
- Input: nothing (reads repo from CWD)
- Actions: write `manifest.json` (sha256 + mtime per file), write `last_run.json`, write empty `risk.jsonl`
- Output: creates `.bugsweep/` if not exists, writes `index.json` (cold-start format, `warm_start: false`)
- Implementation path: pure bash; use `git ls-files` for file list; `sha256sum` or `python3 -c "import hashlib..."` for hashing (match `common.sh` tiered approach)

**1b. `scripts/index.sh diff` subcommand**
- Input: `last_run.head_sha` from `index.json`
- Actions: `git diff --name-only <last_sha>..HEAD`, cross-reference against `manifest.json` for mtime changes, compute dirty set
- Output: writes updated `dirty_since_last_run` into `index.json`

**1c. `scripts/index.sh update` subcommand (called by finalize.sh)**
- Input: run ledger events (fix_committed, confirmed, quarantine, false_positive)
- Actions: append events to `risk.jsonl`, recompute risk scores, update `top_risk_files` in `index.json`, refresh `manifest.json` for changed files, update `last_run.json`
- Output: updated `index.json` ready for next warm start

**1d. Wire into `preflight.sh` and `finalize.sh`**
- `preflight.sh`: add warm/cold decision block, load `index.json` on warm start
- `finalize.sh`: call `index.sh update` before restoring user's branch

### Phase 2 — Graph Expansion

**2a. Import graph extraction**
- Language-specific: `git grep -E "^(import|require|from .* import)" --and -l` as fast first pass
- Output: `graph.json` (adjacency list: path → [dependency paths])
- On warm start: BFS from dirty set over reverse edges in `graph.json` → `transitive_dependents_of_dirty`
- Start with depth-2 BFS; depth-3 if repo is small enough

**2b. Wire graph expansion into hunt scoping**
- `context-build.md` warm-start branch: use `transitive_dependents_of_dirty` from `index.json` directly
- `recon.json` batch plan: place dirty ∪ dependents ∪ top_risk in critical-tier batches

### Phase 3 — Symbol Intelligence (optional upgrade)

**3a. Tree-sitter symbol extraction** (if bash grep is insufficient)
- Requires `tree-sitter` CLI or a small Python script with `tree-sitter` pip package
- Extracts function/class definitions and call sites per file → `symbols.json`
- Enables Aider-style PageRank for architectural-hunt ordering
- Validate that the dependency adds value before committing to it (measure false-negative rate of Phase 2's import grep)

**3b. Sink-location stable IDs**
- Update `architectural_targets` format in `index.json` to use `file:function:call` instead of `file:line`
- Update `context-build.md` warm-start branch to output stable IDs

---

## Guard Rails

1. **Schema version discipline.** `index.json` must have a `"schema": N` field. Any code reading it must check and force cold start on mismatch. Never silently consume a stale-format index.

2. **`.bugsweep/` must be gitignored.** The install script already injects `.gitignore` entries; add `.bugsweep/` to that list. The skill's own auto-commit logic (`git add -A` commits) must also exclude it — add it to the explicit exclude list in `fix.md`.

3. **Sink-bearing files are always in scope.** Risk score is advisory. Before finalizing the warm-start batch plan, assert that every file matching a sink pattern from `config/bugsweep.config.json` appears in scope regardless of score. Log a warning if risk score would have excluded it.

4. **Cold start on large changesets.** If `changed_count / total_files ≥ 0.40`, force cold start. Log `"cold_start_reason": "large_changeset"` in `index.json` for auditability.

5. **Graceful degradation.** If any part of the index is corrupt or missing, fall back to cold start (today's behavior). Never fail a run because the persistent cache is broken; log a warning and continue.

6. **Risk score cannot go negative below zero for any file.** Cap at 0 minimum. A file with only false-positive events should not get a negative score that could cause it to be deprioritized below uninspected files.

---

## Key Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Import graph misses dynamic requires | Always include sink-bearing files unconditionally; graph expansion is best-effort scope widening |
| Stale risk scores bias hunt away from refactored-but-actually-safe files | Decay factor (0.85) means old events fade; `false_positive` events actively reduce score |
| Schema mismatch on index.json format changes | Version field + forced cold start on mismatch |
| `.bugsweep/` accidentally committed | gitignore injection in install.sh + explicit exclude in auto-commit |
| Large rebase makes warm start miss cross-cutting changes | 40% threshold → cold start for big changesets |
| index.json grows beyond 8KB | Enforce cap via `index.sh build`; truncate with `dirty_truncated: true` flag |
| Sink location IDs go stale after refactor | Use function:call syntax (not line numbers); cold start on schema bump rebuilds all IDs |

---

## Files To Create / Modify

### New files to create:
- `bugsweep/scripts/index.sh` — core of the new system (build/diff/update/score)
- `bugsweep/references/persistent-context.md` — explains the two-tier cache design

### Files to modify:
- `bugsweep/scripts/preflight.sh` — add warm/cold detection + index load
- `bugsweep/scripts/finalize.sh` — add `index.sh update` call
- `bugsweep/scripts/session.sh` — add warm/cold indicator to SESSION.md
- `bugsweep/scripts/common.sh` — add `require_bugsweep_cache`, `load_index` helpers
- `bugsweep/prompts/context-build.md` — add warm-start patch-mode branch
- `bugsweep/references/context-and-continuity.md` — document cross-run vs intra-run persistence
- `bugsweep/config/bugsweep.config.json` — add `context.*` config keys
- `bugsweep/SKILL.md` — update Step 2 to describe warm/cold paths
- `bugsweep/install.sh` — inject `.bugsweep/` into `.gitignore`

---

## Research Sources (Full Bibliography)

1. GitHub Changelog. "Faster incremental analysis with CodeQL in pull requests." March 2026.
   https://github.blog/changelog/2026-03-24-faster-incremental-analysis-with-codeql-in-pull-requests/

2. GitHub Changelog. "Incremental security analysis with CodeQL is now available for all languages." September 2025.
   https://github.blog/changelog/2025-09-23-incremental-security-analysis-with-codeql-is-now-available-for-all-languages/

3. GitHub Next. "Incremental CodeQL."
   https://githubnext.com/projects/incremental-codeql/

4. Szabó, T. "Incrementalizing Production CodeQL Analyses." arXiv 2308.09660, 2023.
   https://arxiv.org/abs/2308.09660

5. Semgrep Docs. "How to trigger diff-aware scans."
   https://semgrep.dev/docs/kb/semgrep-ci/trigger-diff-scans-env-var

6. Engineer's Codex. "How Cursor Indexes Codebases Fast."
   https://read.engineerscodex.com/p/how-cursor-indexes-codebases-fast

7. Cursor Blog. "Securely indexing large codebases."
   https://cursor.com/blog/secure-codebase-indexing

8. Aider source code. `aider/repomap.py` — tree-sitter tags + networkx PageRank. Verified from current repository.

9. Sourcegraph Docs. "Embeddings."
   https://docs.sourcegraph.com/cody/core-concepts/embeddings

10. Sourcegraph Blog. "How Cody understands your codebase."
    https://sourcegraph.com/blog/how-cody-understands-your-codebase

11. Szabó, T., et al. "Incrementalizing Lattice-Based Program Analyses in Datalog." OOPSLA 2018.
    https://szabta89.github.io/publications/inca-oopsla.pdf

12. Conway, C., et al. "Incremental Algorithms for Inter-procedural Analysis of Safety Properties." CAV 2005.
    http://www.cs.columbia.edu/~sedwards/papers/conway2005incremental2.pdf

13. Demanded Summarization. "Interactive Abstract Interpretation with Demanded Summarization." TOPLAS 2024.
    https://plv.colorado.edu/bec/papers/demanded-summarization-toplas24.pdf

14. USPTO Patent 11157385. "Time-weighted risky code prediction."
    https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11157385

15. Opsera. "How to Measure Code Churn and Predict Future Risk."
    https://opsera.ai/blog/how-to-measure-code-churn/

16. arXiv 2603.19935. "Memori: A Persistent Memory Layer for Efficient, Context-Aware LLM Agents."

17. arXiv 2603.27277. "Codebase-Memory: Tree-Sitter-Based Knowledge Graphs for LLM Code Exploration via MCP."

18. IncA DSL. "IncA: a DSL for the definition of incremental program analyses." ASE 2016.
    https://dl.acm.org/doi/abs/10.1145/2970276.2970298

---

## Resuming This Work in a New Session

To continue in a future session, read this file first, then pick up at the Implementation Plan. Start with Phase 1a (`scripts/index.sh build`).

Context needed to implement:
- This document (design + rationale)
- `bugsweep/SKILL.md` (current skill behavior)
- `bugsweep/scripts/common.sh` (existing bash patterns to follow)
- `bugsweep/scripts/preflight.sh` (file to modify)
- `bugsweep/scripts/finalize.sh` (file to modify)
- `bugsweep/config/bugsweep.config.json` (config schema to extend)

The installed skill lives at `~/.claude/skills/bugsweep/`. Changes to the repo at `/Users/shanehamilton/Documents/bugsweep/bugsweep/` need to be copied or re-installed there to take effect (via `install.sh`).

---

# PART II — Expanded Context Design (zeroday-grade), spec for GH issue #2

**Status:** Phase 1 (coverage-first) committed. This part specs the expanded layer.
**Tracking:** GH issue #2 → BEADS epic `bugsweep-s5s` (WU0–WU3).
**Grounding:** Research on Google Big Sleep/Naptime, Project Zero variant analysis, DARPA
AIxCC cyber-reasoning systems (Atlantis/Buttercup), and CodeQL/Semgrep taint dataflow.

## Thesis

A pattern catalog is *descriptive* (it names bad shapes). Elite vuln research persists
**executable, verifiable, reachability-ranked artifacts** and runs a **falsification loop**:
a found bug becomes a reusable query; a "safe" judgment becomes a tracked dependency;
a candidate isn't reported until an oracle confirms it. Phase 1 gave us persistence and
whole-repo breadth; Part II adds *precision* and *learning*.

## Shared primitive — hybrid stable IDs (the keystone)

Every durable fact below is keyed by a **stable symbol ID** with a **content-hash version**:

- **Identity** = qualified name: `relative/path:container[:call]` (e.g.
  `src/payments/charge.ts:applyDiscount:execRaw`). Survives reformatting, comment edits,
  and line shifts — line numbers are anchors only, never keys.
- **Version** = hex content-hash of the symbol's *body*. Changes iff the code changes.

This single primitive is what makes invalidation work: identity *finds* a fact across
refactors; the hash tells you precisely *when* it went stale. (This is the CodeQL
ID-stability lesson — sequential IDs collapsed reuse on a one-line edit.) `tree-sitter` is
absent on target machines, so extraction degrades per language: python `ast` for `.py`;
brace/regex symbol slicing for js/ts/go; whole-file hash as the floor when a file can't be
parsed. Degrading to file-level identity is allowed; emitting an *unstable* key is not.

## WU0 — Stable-ID + symbol-hash index  *(enabler; in progress)*

`scripts/symbols.sh build <RUN_DIR>` → `.bugsweep/state/symbol-index.jsonl`:

```jsonl
{"symbol_id":"src/payments/charge.ts:applyDiscount","hash":"a91f3c","lang":"ts","start":40,"end":78,"kind":"function"}
{"symbol_id":"src/payments/charge.ts:applyDiscount:execRaw","hash":"a91f3c","lang":"ts","start":71,"end":71,"kind":"call"}
```

- **Invalidation:** rebuild a file's symbols when its file content-hash changes (reuses the
  Phase-1 manifest idea, file-level). A symbol whose qualified name vanishes but whose body
  hash reappears elsewhere emits a `{"event":"moved","from":...,"to":...}` so dependent
  facts re-link instead of dropping.
- **DoD:** IDs deterministic and stable across reformatting; hash changes only on body
  change; functional test across ≥2 languages (py + ts); never fails a run (degrade to
  file-level).

## WU1 — Variant queries from confirmed bugs *(the Project Zero multiplier)*

On a confirmed bug, synthesize a durable detector for its *shape* and replay it repo-wide
every run. `semgrep` is available → emit Semgrep YAML when the language is supported, else
a structured shape spec the hunter prompt consumes.

```
.bugsweep/state/variants/BSW-042.yml          # semgrep rule (sink + flow shape + guard-absence)
.bugsweep/state/variants.index.jsonl          # {"bug_id":"BSW-042","rule":"variants/BSW-042.yml","source_symbol":"...:execRaw","created_run":7,"last_matched_run":7}
```

- **Invalidation (inverted):** the rule is *durable* — code edits don't stale it; only its
  match-set is recomputed each run. New matches are treated as **catalog-bump-equivalent**:
  they re-queue the matched files via the Phase-1 frontier. Retire a rule only on explicit
  human mark; `last_matched_run` surfaces dead rules for review, never auto-deletes.
- **DoD:** confirm-→-synthesize-→-replay round trip finds a planted sibling; rule survives a
  reformat; degrade to LLM shape-search when `semgrep` absent or language unsupported.

## WU2 — Justification ledger / assumption invalidation

Persist every "safe because" conclusion keyed to the hashes of the symbols that justify it.

```jsonl
{"id":"C-117","claim":"req.body.amount cannot reach execRaw unsanitized","verdict":"safe","premises":[{"symbol_id":"src/payments/charge.ts:applyDiscount:execRaw","hash":"a91f3c"},{"symbol_id":"src/payments/sanitize.ts:coerceMoney","hash":"77bd02"}],"derived_at_catalog_v":7,"run":12}
```

- **Invalidation (two independent triggers):** re-hash each premise's symbol via WU0; if
  ANY differs → conclusion stale → re-queue its file. Also stale if catalog `VERSION`
  advanced past `derived_at_catalog_v`. Editing the *sanitizer three calls away* re-opens a
  conclusion even though source and sink are untouched — the regression class file-level
  staleness misses.
- **DoD:** test: record a `safe` conclusion, edit only the sanitizer symbol, re-prime →
  conclusion invalidated and its file re-queued.

## WU3 — Sanitizer-aware reachability + exposure ranking

A lightweight source→sink reachability layer over the call/import graph plus a persisted
sanitizer registry; rank the hunt queue by attacker-reachability, not pattern severity.

```jsonl
.bugsweep/state/taint-edges.jsonl   {"src":"src/api/checkout.ts:handler:req.body","dst":"src/payments/charge.ts:applyDiscount:amount","kind":"propagate"}
.bugsweep/state/taint-edges.jsonl   {"src":"src/payments/sanitize.ts:coerceMoney:out","dst":"...:amount","kind":"sanitize"}
.bugsweep/state/sanitizers.jsonl    {"symbol_id":"src/payments/sanitize.ts:coerceMoney","neutralizes":["sql","money"]}
```

- **Ranking keys (primary, ahead of severity):** (1) shortest path length from the nearest
  *untrusted* entry point; (2) asset class of the reached sink; (3) trust boundaries crossed.
  A reachable source→sink path with no intervening `sanitize` edge is a live candidate; an
  intervening sanitizer **demotes** it (never silently drops — a sink-bearing file stays in
  scope per the Phase-1 unconditional-sink rule).
- **Invalidation (per-symbol):** when a symbol's hash changes, drop edges incident to it and
  mark its file `needs_reflow`; only those edges re-derive next run. A config/wiring change
  that removes a sanitize edge (Tier-2 WU) re-opens dependent WU2 conclusions.
- **DoD:** ranking test — a medium-severity sink reachable from a public route outranks an
  unreachable "critical"; a candidate with an intervening sanitizer is demoted below an
  unsanitized one.

## Cross-cutting rules (carried from Phase 1, non-negotiable)

1. Pure git + filesystem + JSONL. No DB, no embeddings. CLIs (`semgrep`, python `ast`) are
   best-effort accelerants with documented degrade paths.
2. **Cache failure always WIDENS scope** (whole-repo frontier) — never narrows or fails a run.
3. **Constant-size Tier-1 context** (PEEK): these models live on disk and are *queried*; only
   the slice relevant to the current target enters the model's context.
4. Sink-bearing files are always in scope; WU3 ranking may reorder a sink earlier, never out.

## Lifecycle integration

- `preflight.sh` → already runs `state.sh prime`; add `symbols.sh build` (WU0) and surface
  WU2 invalidated-conclusion count + WU1 variant-rule count into `prior-coverage.json`.
- `prompts/context-build.md` → frontier additionally includes files with invalidated WU2
  conclusions and fresh WU1 variant matches; WU3 reachability becomes the in-tier sort key.
- `prompts/hunt.md` → load active variant rules (WU1) and the sanitizer registry (WU3).
- `prompts/referee.md` / `fix.md` → on CONFIRM, write a WU1 variant + (when a path is cleared)
  a WU2 `safe` conclusion; fix verification re-runs the variant rule.
- `finalize.sh` → `state.sh persist` also appends WU1/WU2 artifacts.

## Build order (BEADS deps)

WU0 (enabler) → then WU1, WU2, WU3 in parallel-eligible order (each blocked-by WU0).
Tier 2/3 (verifiable repro oracles, config/wiring facts, n-day/dependency reachability)
are deferred to a follow-up epic.

---

## PART II — v2 (design-review-gate revisions, 2026-05-23)

A 3-reviewer adversarial gate (Architecture, Security-Design, Feasibility) returned
**3/3 NEEDS_REVISION**. The blocking findings forced structural changes. v2 supersedes the
build order and several WU contracts above.

### Revised build order
**WU1 (variant queries) is now FIRST**, not the stable-ID keystone. Rationale: WU1 is the
highest-value, most self-contained unit and `semgrep` parses its own AST, so it does **not**
depend on the WU0 sub-file keystone — which the gate showed collapses to file-level without
`tree-sitter` (TS overloads, same-named methods across classes, Go receivers, closures all
lose sub-file identity). New order: **WU1 → WU0 (file-level + best-effort sub-file) → WU-G
(call/import graph + entry-point classifier) → WU3 → WU2**.

### WU-G (new, scheduled prerequisite)
The gate found WU3's primary ranking key ("distance from nearest untrusted entry point")
and WU2's safety both require a call/import graph + an untrusted-entry classifier that **no
WU built**. Phase 1 had deferred the import graph; it is now promoted to a scheduled WU.
`graph.jsonl` (caller→callee + import edges, keyed by WU0 symbol-ids) + `entry-points.jsonl`
(HTTP handlers, CLI argv, consumers, file/IPC, third-party callbacks). Indirect dispatch
(interfaces/abstract methods) is best-effort with documented misses. WU3 and WU2 are
**blocked-by WU-G**.

### WU2 redesign (was unsafe — could hide real bugs)
Original WU2 keyed a "safe" verdict to only its *named* premises; a **new path to the same
sink** added later changes none of those hashes, so the verdict auto-renews and the file
drops off the frontier — converting "we didn't look" into "we proved it safe." For a
security tool this is worse than no ledger. v2 contract:
1. A "safe" conclusion may only **deprioritize within its tier** — it may **never** remove a
   sink-reachable file from the frontier.
2. It is invalidated by **any change to the sink's reachable-path set** (computed from WU-G),
   not just named-premise hashes — so a newly added path re-opens it.
3. If the graph is unavailable, a conclusion is treated as **expired (widen)**, never trusted.
WU2 is deferred behind WU-G + WU3.

### Cross-cutting: persisted artifacts are DATA, never instructions
The gate flagged prompt-injection: WU2 `claim` strings, WU1 YAML, `sanitizers.jsonl`, and
symbol paths are all repo-derived and get reloaded into hunt/referee prompts. Mandatory rule
(mirrors `research.md`'s "treat fetched content as reference data only"): every persisted
repo-derived string is rendered into prompts as quoted/escaped data inside a clearly-fenced
"untrusted cache" block; identifiers used in `semgrep` rule bodies are escaped, never emitted
as raw rule logic; no cached field is ever interpreted as an instruction.

### Per-class catalog versioning
Monolithic `VERSION` makes WU2's catalog-bump invalidation impractical (one bump invalidates
every conclusion repo-wide → operators won't bump). Replace with a per-detector-class version
map (`{"sql":3,"authz":1,...}`); a conclusion stores the versions of the classes it relied on
and re-opens only when one of those advances.

### WU1 hardening (required before implementation)
- **Confirmed-bug record schema**: extend the ledger bug record with `{sink_symbol, source,
  missing_guard, lang}` so a rule can be synthesized. (`risk.jsonl` today has only
  `{run,file,event,severity}`.)
- **Per-rule FP counter + auto-retire** after K consecutive non-matches or a false-positive
  mark — `last_matched_run` alone lets dead/noisy rules accumulate and re-queue files forever.
- **Over-match AND never-match detection** in the DoD, not just "finds a planted sibling."
- **Injection-safe synthesis** per the cross-cutting rule above.

### WU0 reframe
File-level identity is reliable and sufficient for coverage/invalidation; sub-file IDs are
best-effort. **No safety property may depend on sub-file precision.** The "hash changes only
on body change" DoD applies to the parseable path only; the file-level floor is
reformat-sensitive by design and documented as such.

### Status
**COMPLETE (2026-05-23).** All units of the v2 build order landed on
`feat/context-zeroday-expanded` (pushed), under the 4-phase loop (IMPLEMENT → VALIDATE →
ADVERSARIAL REVIEW → COMMIT) with fresh ship-blocking reviewers each round:

- WU1 variant queries (`scripts/variants.sh`) — prior session.
- WU0 stable-ID/symbol-hash index (`scripts/symbols.sh`) — prior session.
- WU-G call/import graph + untrusted entry-point classifier (`scripts/graph.sh`, commit
  fd37270). Two review rounds; round 1 caught 5 blockers (decorator phantom edges,
  attribute-call false resolution, evidence injection, degrade-path exclude bypass,
  non-atomic write) — all fixed.
- WU3 sanitizer-aware reachability + exposure ranking (`scripts/reachability.sh`, commit
  5fd5a64). Coarse LIVE/MAYBE/COLD buckets (not BFS distance — call edges are mostly
  unresolved); `sanitized_observed` recorded but never demotes in v1; connected-component
  `path_hash` is the change-key WU2 uses. Review PASS.
- WU2 justification ledger (`scripts/conclusions.sh`, commit be1d45d). Re-opens a "safe"
  verdict on any premise/sink/sanitizer body-hash change, a new reachable path (path_hash),
  a sanitizer neutralizes-set change, or a catalog advance; fails closed. Two review rounds;
  round 1 caught a space-fragile fail-closed grep that re-queued nothing on evaluator crash
  (the exact stale-safe mode) — fixed to JSON parsing; a sink-body implicit-premise trigger
  was added after round 2.
- `refactor` (b561b45): hoisted the shared exclude-glob shell logic into `common.sh`.

Per-class catalog versioning is now LIVE (commit b72bb40): `references/antipatterns/versions.json`
is the per-detector-class source of truth; WU2 reopens only the conclusions whose relied-on class
advanced, while the coverage layer (`state.sh`) keys off the aggregate (sum) so any bump still
re-audits broadly. The legacy single-integer `VERSION` remains the fallback. catalog versioning
helpers were hoisted into `common.sh` (`catalog_class_version` / `catalog_aggregate_version`).
BEADS epic `bugsweep-s5s` closed (7/7). Branch not merged — awaiting human sign-off.
