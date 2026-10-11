# Context, continuity, and resets

Long unattended runs eventually exceed a single context window. bugsweep is built so that
**resetting context never loses progress** — because all progress lives on disk, not in
the conversation.

## What is durable (on disk, in the run directory)
- `repo-context.md` — the distilled architecture model (updated per slice). This is the
  frozen-scope understanding that lets the hunt find large, cross-file bugs without holding
  every file in context.
- `indexes/` — source-bound symbols, graph, entry points, and sink reachability for
  this run's audited checkout. Manifests bind source, configuration, and extractor
  identity. Missing or stale bindings cannot support a cached conclusion.
- `antipatterns.md` — the stack-specific patterns the hunters watch for (built once).
- `recon.json` — the batch plan, frozen `admission`, and `covered` list (which batches are done).
- `ledger.jsonl` — every event: iterations, confirmed counts, fixes committed,
  quarantines, checkpoints. The full audit trail.
- `SESSION.md` — the continuity anchor, refreshed at each checkpoint by `session.sh`. It
  states where the run is and exactly which files to re-read to resume.

## What is disposable (working memory / context window)
The reasoning in the current conversation: the code currently being read, the in-flight
candidate list for the batch in progress. Losing this costs at most the re-scan of one
batch, never a confirmed finding or a committed fix.

## The reset cycle
1. `session.sh checkpoint <RUN_DIR>` runs on a cadence (`session.checkpoint_every_iterations`).
   It refreshes `SESSION.md` and prints `RESET_RECOMMENDED` when a reset is due.
2. On `RESET_RECOMMENDED` (or whenever the working context feels large), finish the
   current batch to a clean state — every fix either committed or reverted, never
   mid-edit — then reset/compact the context.
3. After the reset, the FIRST actions are to read `SESSION.md`, then `repo-context.md`,
   `antipatterns.md`, and `recon.json`, then tail `ledger.jsonl`. Continuity is restored:
   the run continues from the next admitted uncovered batch. Re-read source citations before reusing notes;
   resume an incomplete slice through hunt and review before modeling another.

## Why this is safe
A reset can only drop disposable working memory. During the run, committed fixes remain on
the exact run branch while coverage and findings remain under `RUN_DIR`. At closeout, landed
fixes move to the recorded local target; unlanded fixes are represented by a verified
recovery bundle plus tracker receipt before the ephemeral branch is removed. Cross-run
learning never depends on retaining the branch.

## Two layers of persistence: intra-run vs cross-run

There are two distinct durable stores, and they answer different questions:

- **Intra-run and closeout evidence** — `.bugsweep/run-<ts>/` (everything above:
  `repo-context.md`,
  `recon.json`, `ledger.jsonl`, `SESSION.md`). Scoped to ONE run. Answers *"where am I in
  this run, how do I resume after a reset, and how can an escrowed fix be recovered?"*
- **Cross-run** — `.bugsweep/state/` (`audit-log.jsonl`, its compact `audit-index.json`,
  exact `audit-membership.json`, `risk.jsonl`, and `meta.json`).
  Survives *across* runs. Answers *"what has ever been audited, at which catalog version,
  and where have bugs historically clustered?"* This is what makes bugsweep accumulate
  understanding instead of starting blind every time.

Both are kept out of git by the same `info/exclude` entry preflight installs (`.bugsweep/`).

When invoking index or conclusion helpers directly, supply `BUGSWEEP_TARGET_ROOT`
and `BUGSWEEP_RUN_DIR` for the audited checkout and run. Preflight supplies these
automatically. Helpers without a run directory retain the legacy shared output
paths, but those outputs cannot support cached safety conclusions or validated
symbol lookups. Missing Python or an unmatched manifest also makes those lookups
unknown and reopens conclusions; source-based detection can continue.

## The coverage-first contract (why bugsweep keeps finding latent bugs)

Bugsweep is **not** a diff scanner. With no path argument its scope is the whole repo;
with an explicit path, coverage is limited to that selected scope while outside dependencies
may be read as context. Cross-run state only *reprioritizes* the queue; it never silently
shrinks the user's selected scope.

- `preflight.sh` runs `state.sh prime`, producing `prior-coverage.json` in the run dir:
  the files audited at the current catalog version (recently), the stale ones, and the
  historically risky ones.
- `context-build.md` ranks fresh audit history and current-source signals within the
  frozen plan, then applies bounded admission. A cold frontier or a sensitive sink
  does not clear all deferred flags. **Every** in-scope file stays in the plan; only
  admitted batches are modeled, hunted, reviewed, and checkpointed this run.
- Display lists in `prior-coverage.json` are capped. The priority helper verifies its
  binding to exact membership and source fingerprints before making frontier decisions;
  absence from a display sample does not mean never audited.
- `finalize.sh` runs `state.sh persist`: the files in this run's covered batches are
  appended to `audit-log.jsonl` (stamped with the catalog version + a run ordinal), and
  per-file bug/fix/quarantine events are appended to `risk.jsonl`.

A file re-enters the frontier when (a) it was never audited, (b) the anti-pattern catalog
version was bumped since it was last audited, or (c) it was audited more than
`context.recheck_audited_after_runs` runs ago. So the repo is **never permanently "done"**
— old, unchanged code keeps getting fresh passes. If `.bugsweep/state/` is missing or
unreadable, bugsweep degrades to treating the entire frozen selected scope as the frontier;
the cache can only ever *speed up* prioritization, never narrow or fail a run.
