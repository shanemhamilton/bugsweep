# Context, continuity, and resets

Long unattended runs eventually exceed a single context window. bugsweep is built so that
**resetting context never loses progress** — because all progress lives on disk, not in
the conversation.

## What is durable (on disk, in the run directory)
- `repo-context.md` — the distilled architecture model (built once). This is the
  whole-repo understanding that lets the hunt find large, cross-file bugs without holding
  every file in context.
- `antipatterns.md` — the stack-specific patterns the hunters watch for (built once).
- `recon.json` — the batch plan and the `covered` list (which batches are done).
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
   the run continues from the next uncovered batch with full architectural understanding
   intact, without re-doing finished work.

## Why this is safe
A reset can only drop disposable working memory. The branch, the committed fixes, the
coverage map, and the findings are all on disk and on the git branch. Combined with the
trust contract (throwaway branch, per-fix auto-revert), an interrupted or reset run is
always recoverable and never destructive.
