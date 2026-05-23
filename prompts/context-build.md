# Phase: Build repo context (run once, early)

You are building a durable, distilled model of the whole repository so later hunting can
catch *large* bugs — the cross-file, architectural ones that per-file scanning is blind
to. You do NOT look for bugs yet and you NEVER modify code. The output is a compact
artifact, not a copy of the code, so it stays small enough to survive context resets.

## Consult prior coverage first (coverage-first scope)

`preflight.sh` writes `prior-coverage.json` into the run directory from bugsweep's
cross-run state. Read it before planning batches. It tells you what earlier runs already
audited and what they found:

- `files_audited_current_catalog` — files audited at the **current** anti-pattern catalog
  version, recently enough to still trust. These are the *only* files you may de-prioritize.
- `files_audited_stale_catalog` — files audited under an older catalog version or too many
  runs ago. New rules (or drift) may have introduced findings; treat them as un-audited.
- `high_risk_files` — files with a history of confirmed bugs/fixes/quarantines (decayed
  score). Always front of the queue.
- `prior_runs: 0` (or a `degraded` flag) means no usable history — treat the **whole repo**
  as the frontier.

**The coverage-first contract — non-negotiable:**

1. **The whole repo is always in scope.** `recon.json` must enumerate every in-scope file
   (respecting `exclude_globs`), exactly as on a cold first run. Prior coverage REORDERS
   batches; it never DELETES files from the plan. bugsweep finds latent bugs in old,
   unchanged code — it is not a diff scanner.
2. **The frontier leads.** Compute `never_audited = (all in-scope files) −
   files_audited_current_catalog`. The critical/early tier is the union, deduped:
   `sink-bearing ∪ never_audited ∪ files_audited_stale_catalog ∪ high_risk_files`.
   Place already-audited-and-fresh files in the LAST tier (a cheap re-confirmation pass),
   never dropped.
3. **Sinks are unconditional.** Any file containing a sensitive sink (auth/authz, money
   math, SQL/query, shell/exec, deserialization, crypto, file-path, outbound request) is
   ALWAYS in the critical tier regardless of its coverage or risk score. Coverage may
   reorder a sink file earlier, never later or out.
4. **The repo is never "done."** As long as a `never_audited` or stale file remains, there
   is more frontier to hunt on the next run — even with an unchanged working tree.

If `prior-coverage.json` is missing or unreadable, fall back to whole-repo scope (every
file in the critical/normal tiers by sink/risk heuristics alone). Never fail or shrink the
plan because the coverage file is absent.

## Build the model

Read broadly but record concisely. Respect `exclude_globs`. Produce two files in the run
directory:

### `repo-context.md` — the architecture model

Capture, in tight prose/bullets (distilled, not exhaustive dumps):

- **What the app is and its entry points** — servers, CLIs, request handlers, jobs,
  message consumers, UI roots. Where untrusted input first enters.
- **Trust boundaries** — where data crosses from untrusted to trusted (network, user
  input, file uploads, third-party callbacks, IPC). These are where the worst bugs live.
- **Sensitive sinks** — auth/authz checks, payment/money math, DB queries, file-system
  paths, shell/exec, deserialization, crypto, outbound requests. List each with its
  file:location.
- **Call chains into those sinks** — for each sensitive sink, trace who calls it and
  whether every path enforces the right checks. A missing authz check three calls up
  from a DB write is a "large bug" — this map is how you find it.
- **Shared/mutable state** — module-level state, caches, singletons, globals touched by
  concurrent paths.
- **Module/import graph** — which modules depend on which; note tight couplings and
  cross-module contracts (a function's documented/assumed input shape vs. how callers use
  it). Contract drift across a boundary is a classic large bug.
- **Data flows worth tracing** — follow 2–4 of the highest-risk flows from source
  (untrusted input) to sink (sensitive operation) and note where validation/encoding
  happens or is missing.

### `recon.json` — the hunt plan

```
{
  "files_in_scope": <n>,
  "batch_count": <n>,
  "batches": [ { "id": 1, "tier": "critical", "files": ["..."] }, ... ],
  "architectural_targets": [ "<sink or call-chain to chase in the architectural hunt>", ... ],
  "covered": []
}
```

Order batches by the coverage-first contract above: critical tier = `sink-bearing ∪
never_audited ∪ stale ∪ high_risk` (auth, payments, parsing, untrusted input, crypto,
queries, file paths come first within it), then high (concurrency, shared state,
transforms), then normal — and put **already-audited-at-current-catalog, fresh** files in
the final tier as a cheap re-confirmation pass. Every in-scope file must appear in exactly
one batch; `covered` starts empty. Size each batch to fit comfortably in a subagent's
context.

## Output to the main thread

A short summary: what the app is, the top 3–5 trust boundaries, the count of sensitive
sinks, the batch count, the architectural targets queued, and the coverage posture (e.g.
"first run — whole repo is frontier" or "N files re-queued: M never-audited, K stale, J
high-risk; P fresh files in re-confirmation tier"). Then proceed to anti-pattern research.
Append a `context_built` event to the ledger.
