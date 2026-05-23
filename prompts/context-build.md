# Phase: Build repo context (run once, early)

You are building a durable, distilled model of the whole repository so later hunting can
catch *large* bugs — the cross-file, architectural ones that per-file scanning is blind
to. You do NOT look for bugs yet and you NEVER modify code. The output is a compact
artifact, not a copy of the code, so it stays small enough to survive context resets.

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

Order batches critical-tier first (auth, payments, parsing, untrusted input, crypto,
queries, file paths), then high (concurrency, shared state, transforms), then normal.
Size each batch to fit comfortably in a subagent's context.

## Output to the main thread

A short summary: what the app is, the top 3–5 trust boundaries, the count of sensitive
sinks, the batch count, and the architectural targets queued. Then proceed to anti-pattern
research. Append a `context_built` event to the ledger.
