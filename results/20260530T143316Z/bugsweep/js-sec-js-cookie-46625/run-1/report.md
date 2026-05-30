# bugsweep report — 20260530-152655
**Branch:** bugsweep/20260530-152655   **Mode:** detect-only (no fixes, no commits)   **Iterations:** 1
**Stack:** JavaScript (ESM browser library — js-cookie 3.0.5); Rollup build, Grunt+QUnit tests
**Baseline checks:** UNAVAILABLE in this sandbox — `npm`/`npx` not on PATH; the configured typecheck override targets a nonexistent dir (`backend/firebase-research`). Detection was performed statically.
**Final checks:** unchanged (no code modified)

## Summary
- Confirmed bugs: 0 (critical 0, high 0, medium 0, low 0); architectural: 0
- Fixed & verified: 0   Quarantined (needs human): 0
- Coverage: 4/4 source files covered (`src/api.mjs`, `src/converter.mjs`, `src/assign.mjs`, `index.js`); reviewed via Hunter -> independent Skeptic (both converged)
- Conclusion: the audited source is a faithful, unmodified copy of upstream js-cookie 3.0.5. No runtime behavioral bugs were confirmed.

## Fixed
(none — detect-only)

## Quarantined / needs human
(none)

## Confirmed but not fixed (detect-only or below severity floor)
(none — no confirmed bugs)

## Notes / what was checked (no findings)
The full attack surface of this library is the single sink `document.cookie`. Inputs (name, value,
attributes) flow from the caller through encoding before reaching that sink. Each path was examined:

- **Percent-encoding regexes (security-critical) — all match upstream 3.0.5 exactly, verified char-by-char:**
  - `src/converter.mjs:6` read  `/(%[\dA-F]{2})+/gi` ✓
  - `src/converter.mjs:10` write `/%(2[346BF]|3[AC-F]|40|5[BDE]|60|7[BCD])/g` ✓
  - `src/api.mjs:20` set-name  `/%(2[346B]|5E|60|7C)/g` ✓
  A single wrong hex digit here would be a subtle encoding/injection bug; none deviate.
- **Cookie-injection defense** (`src/api.mjs:42`): attribute values are truncated at the first `;`
  via `.split(';')[0]` per RFC 6265 §5.2 — blocks `;Secure`/`;Domain` injection through attribute values. Correct.
- **`expires` day math** (`src/api.mjs:13`): `* 864e5` = 86400000 ms = exactly one day. Correct.
- **`get` guards & return** (`src/api.mjs:50,73`): `arguments.length && !name` returns early only on an
  explicit falsy name; `Cookies.get()` with no args still returns the full jar; `name ? jar[name] : jar` correct.
- **`get` value reassembly** (`src/api.mjs:59-60`): `split('=')` + `slice(1).join('=')` correctly
  preserves values containing `=`. Correct.
- **`read` unquoting** (`src/converter.mjs:3-4`): `slice(1, -1)` only when value starts with `"`. Correct.
- **`assign`** (`src/assign.mjs`): shallow merge; `for..in` without `hasOwnProperty` mirrors upstream and is
  not exploitable given developer-supplied attribute objects. No regression.

### Known upstream behaviors (not bugs, noted for completeness)
- A non-string attribute value (e.g. a number passed for a custom attribute) would throw at
  `attributes[attributeName].split(';')` (`src/api.mjs:42`). This is documented upstream behavior
  (attribute values are expected to be strings), present identically in the published library — not a regression.

### Out of scope
- `examples/webpack/server.js` is example/demo code (serves `./dist` locally via `node-static`), not the
  shipped library. Dependency-version concerns (e.g. `node-static`) are out of bugsweep's scope.
- `index.js` re-exports the built bundle `./dist/js.cookie`, which is not present in the tree (build
  artifact). The audit covered the `src/` sources; verifying the built `dist/` bundle is a separate concern.

## How to review
git diff bench-base..bugsweep/20260530-152655   # (empty — detect-only made no changes)