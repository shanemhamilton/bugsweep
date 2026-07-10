# Priority intelligence

Bugsweep still hunts every tracked file in its configured scope. Priority intelligence answers
a narrower question: **what should it investigate first on this run, and why now?** It never
decides that a bug exists and never changes the confirmation, fix, merge, or push gates. Its
ranking weights are fixed code, not a self-modifying policy.

## What it reads automatically

`scripts/priority-context.sh build <RUN_DIR>` runs after baseline checks and uses bounded,
local-only evidence:

- exact tracked-file changes since the last finalized Bugsweep run on the same original
  branch; the legacy global head is only a compatibility fallback, and the first run or an
  unavailable local commit uses a bounded recent-commit window;
- content fingerprints from batches that completed Hunter → Skeptic → Referee review, so a
  file changed since its last real hunt is distinguishable from architecture modeling;
- bounded Git churn and repeated fix/hotfix/revert pressure. Commit subjects may classify a
  repair locally but are omitted from the model-facing artifact;
- failing baseline check logs, but only when a repository-relative path can be validated
  against the tracked-file scope; otherwise the failure stays project-level evidence;
- prior confirmed/fixed/quarantined risk, variant matches, and invalidated conclusions;
- existing `LIVE` / `MAYBE` / `COLD` sink reachability;
- open repository-local Beads bugs only when they declare an explicit tracked `file_scope`.
  Concurrent worktree runs read this coordination snapshot from the common project root, where
  ignored/untracked Beads state actually lives;
- `priority.critical_globs` and a project-local signal inbox.

No `bd`, `gh`, tracker, telemetry, or incident CLI is invoked. Missing sources are recorded in
`source_status` and degrade independently; they never fail or shrink the run. Signal-health
counts make rejected, expired, inactive, unmapped, or over-broad inputs visible instead of
silently implying that all configured context was usable.

Change evidence is limited to paths in the **current** tracked-file set. A deleted path is no
longer targetable and therefore cannot receive a lane or score directly. Surviving tracked files
in the configured scope remain in the whole-repository plan, but deletion-aware dependency/caller
mapping is not yet an implemented signal; do not describe a removed file as covered by priority
intelligence.

## How ordering works

The artifact uses hard lanes first, then a visible bounded score:

- `must_focus` — a mapped baseline failure, active high/critical incident or release blocker,
  invalidated conclusion, known-bug variant, or recently changed `LIVE` sink;
- `high` — content changed since its completed hunt, explicit critical path, repeated repairs,
  high prior risk, a high-priority local bug, or a high-confidence/high-severity project signal;
- `elevated` — recent change/churn, stale audit, or partial/cold reachability evidence;
- `normal` — retained whole-repo work with no extra why-now evidence.

The score breakdown is intentionally inspectable and capped at 100:

- impact/value: 30
- active evidence: 25
- change likelihood: 15
- runtime reachability: 15
- recurrence/learning: 10
- audit staleness: 5

Category caps prevent ten similar signals from manufacturing certainty. Structured
`affected_users` and `occurrence_count` may add a bounded `user_impact` reason; prose never adds
points. All normalized reasons are scored before the display-only
`priority.max_reasons_per_file` limit is applied, so explanation size cannot change rank. A
reason may appear with `contribution: 0` when it corroborates evidence but its category is
already saturated. `priority_score` is investigation order only; severity and confirmation are
separate.

`scripts/priority-context.sh apply <RUN_DIR>` verifies the exact batch-ID and file multisets
before persisting any reorder. Existing critical frontier batches remain ahead of newly promoted
work. A candidate can clear `deferred` only when its **entire batch** fits both independent
added-work budgets:

- `priority.promotion_limit` — maximum newly promoted deferred batches (hard cap 20);
- `priority.max_promoted_files` — maximum total files inside those promoted batches (hard cap
  1,000).

Already non-deferred batches consume no promotion budget. Elevated recency/churn alone cannot
promote a batch. Unknown paths cannot enter the plan, and a large batch that exceeds the file
budget remains deferred even when it contains a high-ranked file.

On success, apply writes `<RUN_DIR>/priority-application.json`, validated by
`schemas/priority-application.schema.json`. This is the durable receipt for what actually
happened: candidate count, promoted batch IDs, added-file count, candidates already inside the
run budget, and candidates skipped as outside the plan or budget-limited. Reporting reads this
receipt rather than inferring applied work from the ranked candidates.

## Project-local signal inbox

External systems should normalize their read-only evidence into
`.bugsweep/priority-signals.jsonl`. This provider-neutral seam lets an existing GitHub,
Linear/Jira, Sentry/Crashlytics, observability, product-analytics, or support exporter add
context without putting credentials or network behavior inside Bugsweep.

One JSON object per line. Use stable structured facts rather than prose:

```json
{"id":"incident-2026-17","source":"sentry","kind":"runtime_incident","severity":"high","status":"active","confidence":90,"observed_at":"2026-07-09T14:00:00Z","expires_at":"2026-07-10T14:00:00Z","environment":"production","release":"42","affected_users":321,"occurrence_count":900,"files":["src/checkout.py"]}
{"id":"release-42","source":"ci","kind":"release_blocker","severity":"critical","status":"investigating","confidence":100,"observed_at":"2026-07-09T14:05:00Z","globs":["payments/**"]}
{"id":"product-1","source":"product-plan","kind":"project_priority","severity":"medium","status":"active","confidence":80,"observed_at":"2026-07-09T13:00:00Z","component":"family","flow":"onboarding"}
```

Supported fields:

- `id` and `source`: required stable identifiers using letters, digits, `_`, `.`, `:`, `/`, or
  `-`; never use a run-local `BUG-1` identifier;
- `kind`: `runtime_incident`, `incident`, `release_blocker`, `regression`, or
  `project_priority`; unknown kinds are rejected as malformed instead of gaining priority;
- `severity`: `critical`, `high`, `medium`, or `low`;
- `status`: `active`, `open`, `investigating`, `in_progress`, or `blocked` can rank.
  `closed`, `resolved`, `dismissed`, and `inactive` are counted as inactive; any unknown
  status is malformed;
- `confidence`: integer 0–100. High/critical incidents need confidence at least 70 to enter
  `must_focus`;
- `observed_at`: required epoch seconds or ISO-8601 timestamp. `expires_at` is optional; without
  it, `priority.max_signal_age_hours` supplies the freshness limit;
- `environment`, `release`, `component`, and `flow`: optional bounded identifiers for provenance
  and later mapping;
- `affected_users` and `occurrence_count`: optional non-negative aggregate impact facts. They
  are capped before contributing to the bounded `user_impact` factor;
- `files`: explicit repository-relative tracked paths;
- `globs`: optional tracked-path globs. A glob that matches more than
  `priority.max_glob_matches` is ignored instead of promoting a large part of the repository.

Keep raw logs, request bodies, customer conversations, email addresses, user IDs, and secrets
out of this file. Export aggregate facts and fingerprints only. Free-text titles and commit
subjects are deliberately omitted from the model-facing artifact. Bugsweep never evaluates
inbox text as a command.

### Signal health and unmapped context

`project_signals.signal_health` reports `accepted`, `inactive`, `expired`, `malformed`,
`unmapped`, and `overmatched` counts. Accepted signals with validated files can affect ordering.
An accepted fresh signal with no valid file or bounded glob is retained in
`unmapped_focus_signals` with its provenance, component, flow, release, and aggregate impact;
it does **not** rank a file or widen scope until a later validated mapping exists.

## How evidence compounds safely

After a batch completes the full adversarial hunt, `state.sh persist` records the audited
content fingerprint and retains bounded risk outcomes. Later runs can distinguish unchanged
fresh work from changed code, decay old risk, replay transferable variants, reopen conclusions
whose premises moved, and focus on areas where earlier evidence actually yielded bugs. Merely
building architecture context updates `recon.json.modeled`; it does not create audit coverage.

Each prioritized reason also produces an append-only observation in
`.bugsweep/state/priority-outcomes.jsonl`. The next artifact exposes bounded `signal_yield`
aggregates with this exact shape: `reason`, `observed`, `investigated`, `attributed`,
`confirmed`, `rejected`, `no_finding`, `unattributed`, and `confirmation_rate`. A finding only
credits a reason when the Hunter/Referee ledger event explicitly carries that closed code in
`priority_reason_codes`; a same-file finding without that link is counted as `unattributed`,
not evidence that every reason was effective. Attribution codes are retained independently of
the display-only reason cap. This lets people see which signals have historically led to real
bugs without confusing coincidence with yield.

Yield is observability, not automatic optimization. It does not change lanes, points,
confirmation thresholds, fix authority, or tool permissions. Any future weight change must be a
reviewed code/config change validated against held-out benchmark cases; Bugsweep never rewrites
its own ranking policy from production outcomes.

## Reporting and degraded operation

With Python 3 available, `scripts/summarize.sh` adds a deterministic `priority` object to
`<RUN_DIR>/run-summary.json`. `finalize.sh` renders that same object as
`## Priority focus (deterministic)`, including the application receipt, top-target outcomes,
signal health, unmapped context, and attributed historical yield. The model must not author or
edit that section.

Python 3 is required for exact Git-object audit checkpoints. Without it,
`mark-batch-covered.sh` returns `BATCH_COVERED=skipped_no_python` without mutating coverage;
the run finalizes with incomplete output at that checkpoint. The shell fallback still emits a
minimal schema-valid `run-summary.json` with `degraded: true` and underreports coverage as zero.
If finalize had to create a stub report, the summary status is `stalled` because no batch is
verifiably complete. It does not claim target outcomes or full priority reporting.
