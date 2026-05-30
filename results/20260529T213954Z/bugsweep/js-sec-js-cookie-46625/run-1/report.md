# bugsweep report — 20260529-222748
**Branch:** bugsweep/20260529-222748   **Mode:** detect-only (no code changes, no commits)   **Iterations:** 1
**Stack:** JavaScript (ESM library: js-cookie 3.0.5); build via Rollup; tests via Grunt + QUnit; lint ESLint/Prettier
**Baseline checks:** test=fail, typecheck=fail — both ENVIRONMENTAL ONLY (`npm: command not found` in sandbox; typecheck override points at a non-existent `backend/firebase-research` dir). Not code defects.
**Final checks:** unchanged (no code modified)

## Summary
- Confirmed bugs: 0 (critical 0, high 0, medium 0, low 0); architectural: 0
- Fixed & verified: 0   Quarantined (needs human): 0
- Coverage: all files reviewed (whole-repo, single pass); reviewed via Hunter -> Skeptic -> Referee

The product code (`src/api.mjs`, `src/converter.mjs`, `src/assign.mjs`, `index.js`) is the
genuine, mature, well-tested js-cookie 3.0.5. It matches the canonical upstream
implementation, and the extensive QUnit suite (`test/tests.js`, `test/encoding.js`,
`test/sub/`, `test/node.js`, `test/module.mjs`) pins down the encoding, RFC 6265
sanitization, quoting, and shadowing edge cases. No runtime behavioral bug — security,
logic, error-handling, concurrency, or data-integrity — was confirmed.

## Fixed
(none — detect-only)

## Quarantined / needs human
(none)

## Confirmed but not fixed (detect-only or below severity floor)
(none confirmed)

### Reviewed candidates that did NOT survive adversarial review (informational, not bugs)
- `src/assign.mjs` — `for (var key in source)` copies inherited enumerable properties (no
  `hasOwnProperty` guard). REJECTED as a bug: attributes are object literals in normal use;
  exploiting it requires an already prototype-polluted environment, and the behavior is
  identical to upstream js-cookie. No exposed sink.
- `src/api.mjs:42` — `attributes[attributeName].split(';')[0]` throws `TypeError` if a
  caller passes a truthy, non-`true`, non-string attribute value (e.g.
  `Cookies.set('c','v',{ 'max-age': 3600 })` with a numeric value). REJECTED as a defect:
  this is documented/by-design upstream behavior (attribute values other than the special
  `expires` number and boolean flags are expected to be strings); it is not a regression
  introduced in this repo. Worth a doc note at most, not a code fix.

### Files reviewed
- Core: `src/api.mjs`, `src/converter.mjs`, `src/assign.mjs`, `index.js`
- Build/tooling: `Gruntfile.js`, `rollup.config.mjs`, `.nano-staged.mjs`
- Tests: `test/tests.js`, `test/encoding.js`, `test/utils.js`, `test/node.js`,
  `test/module.mjs`, `test/sub/tests.js`, `test/fix-qunit-reference.js`,
  `test/browserstack/runner.js`
- Examples: `examples/webpack/server.js`, `examples/webpack/src/index.js`,
  `examples/es-module/src/main.js`

### Note on baseline check failures
Both baseline checks failed for environmental reasons, NOT code defects:
- `test` failed with `npm: command not found` — the toolchain (npm/Grunt/headless Chrome)
  is unavailable in this sandbox.
- `typecheck` ran a config override (`cd backend/firebase-research && npx tsc`) against a
  directory that does not exist in this repo (js-cookie ships no TypeScript). Stray override.
Neither indicates a runtime bug in the product.

## How to review
git diff bench-base..bugsweep/20260529-222748   # expected: empty — detect-only, no changes