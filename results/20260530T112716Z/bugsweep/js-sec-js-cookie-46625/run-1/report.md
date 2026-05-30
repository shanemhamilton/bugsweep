# bugsweep report — 20260530-112724
**Branch:** bugsweep/20260530-112724   **Mode:** detect-only (no fixes, no commits)   **Iterations:** 1
**Stack:** JavaScript (browser library + Node), ESM source, Rollup build, QUnit tests   **Baseline checks:** test=fail, typecheck=fail — both environmental/config, not code (see Notes)   **Final checks:** unchanged (no code modified)

## Summary
- Confirmed bugs: 0 (critical 0, high 0, medium 0, low 0); architectural: 0
- Fixed & verified: 0   Quarantined (needs human): 0
- Coverage: 1/1 batches covered; reviewed via whole-repo architectural lens + per-file hunt (Hunter->Skeptic->Referee)
- Verdict: clean. The library/runtime code is a faithful copy of upstream js-cookie v3; no runtime behavioral bug was found.

## Scope reviewed
Whole repository (first run — entire codebase was the unaudited frontier). Runtime/product code read in full:
- `src/api.mjs` — set/get/remove/withAttributes/withConverter, attribute stringification, name/value encoding
- `src/converter.mjs` — default read/write percent-encoding
- `src/assign.mjs` — shallow object merge
- `index.js` — CJS entry re-exporting the built dist
- `examples/webpack/server.js`, `examples/webpack/src/index.js`, `examples/es-module/src/main.js` — demo code
- `Gruntfile.js` (incl. `encodingMiddleware`), `rollup.config.mjs` — build/test harness
- `test/*.js` (tests.js, encoding.js, utils.js, node.js, sub/tests.js, fix-qunit-reference.js, browserstack/runner.js)

## Trust-boundary / sink review (architectural lens)
- **Cookie write path** (`set`): attribute values are truncated at the first `;` via `attributes[attributeName].split(';')[0]`, correctly preventing attribute injection from untrusted input (behavior asserted by `test/tests.js` "sanitization of attributes to prevent XSS"). Name encoding via `encodeURIComponent(...).replace(...)` matches RFC 6265 allow-list handling. No injection gap found.
- **Cookie read path** (`get`): malformed percent-encoding is contained by the per-cookie `try/catch` around `decodeURIComponent`, so one bad cookie cannot throw while reading others (asserted by the issue-196/PR-62 tests). No DoS/throw gap found.
- **`encodingMiddleware`** (Gruntfile, test-only server): reflects `name`/`value` query params into a JSON body with `content-type: application/json`; not user-facing production code and not an HTML sink. No XSS/SSRF/path-traversal in first-party code.
- **`examples/webpack/server.js`**: serves `./dist` via `node-static`; any path-traversal exposure would originate in the third-party dependency, not this repo's code (dependency CVEs are out of bugsweep's runtime-bug scope).

## Fixed
(none — detect-only)

## Quarantined / needs human
(none)

## Confirmed but not fixed (detect-only or below severity floor)
(none — no confirmed runtime bugs)

## Notes (infrastructure / config — out of bugsweep's runtime-bug scope, surfaced for the human)
These caused the "failed" baseline but are NOT defects in the product code, so they are reported, not fixed:
- **Baseline `test` failed:** `npm: command not found` — `npm` is not on PATH in this environment. No code involvement.
- **Baseline `typecheck` failed:** the check override runs `cd backend/firebase-research && npx tsc`, but `backend/firebase-research` does not exist in this repo (the untracked `config/` directory is empty). This is a misconfigured check override pointing at a nonexistent path, not a code bug.
- Neither item affects the correctness of the JavaScript library and neither is in scope for "runtime bug" detection.

## How to review
git diff bench-base..bugsweep/20260530-112724
# (expected: no code changes — detect-only run)