# bugsweep report — 20260530-013717
**Branch:** bugsweep/20260530-013717   **Mode:** detect-only (no code changes, no commits)   **Iterations:** 1
**Stack:** JavaScript (ES-module browser library; Rollup build, Grunt + QUnit tests)   **Baseline checks:** could not execute — environmental (see note)   **Final checks:** not run (detect-only; no fixes applied)

## Summary
- Confirmed bugs: 2 (critical 0, high 0, medium 0, low 2); architectural: 0
- Fixed & verified: 0   Quarantined (needs human): 0
- Coverage: 13/13 files reviewed (3 core src + index + 2 build configs + examples + test harness); reviewed via Hunter -> Skeptic -> Referee
- No injected or high-severity bug found. The core library (`src/api.mjs`, `src/assign.mjs`, `src/converter.mjs`) is byte-for-byte consistent with canonical js-cookie 3.0.5; git history shows only legitimate upstream commits plus dependabot version bumps at HEAD. Both findings below are **pre-existing latent defects in upstream js-cookie**, low severity, and were confirmed empirically by re-running the exact logic in Node.

## Fixed
_(none — detect-only mode)_

## Quarantined / needs human
_(none)_

## Confirmed but not fixed (detect-only)
- **BUG-1 · low · logic/data-integrity (local lens) · src/api.mjs:64 · `get()` cannot read cookies whose name collides with an `Object.prototype` property.**
  The jar is a plain object (`var jar = {}`), and the guard `if (!(found in jar))` uses the `in` operator, which is true for inherited property names. For any cookie named `toString`, `constructor`, `hasOwnProperty`, `valueOf`, `isPrototypeOf`, `propertyIsEnumerable`, `toLocaleString`, etc., the value is **never stored**, so `Cookies.get('toString')` returns the inherited function instead of the cookie value, and `Cookies.get()` (whole jar) silently omits the cookie entirely.
  Empirical proof (Node re-impl of `get`, cookie string `toString=mysecret; constructor=abc; foo=bar; hasOwnProperty=hp`): `get('toString')` -> `function toString() { [native code] }`; `get('constructor')` -> `function`; `get('hasOwnProperty')` -> `function`; `Object.keys(get())` -> `['foo']` (the three prototype-named cookies are missing). `get('foo')` correctly returns `"bar"`.
  Impact: data loss / wrong value for such cookies; type-confusion risk if application code does `Cookies.get(someUserControlledName)` and uses the result in a string/truthy context (it may receive a Function rather than a string). Pre-existing upstream (introduced by upstream commit b754561, "Improve testing if cookie has been found before"); no test covers prototype-named cookies.

- **BUG-2 · low · error-handling/robustness (local lens) · src/api.mjs:42 · `set()` throws `TypeError` on a non-string truthy attribute value.**
  Line 42 calls `attributes[attributeName].split(';')[0]` unconditionally for any truthy, non-`true` attribute value. A numeric (or other non-string) attribute value — e.g. `Cookies.set('x', 'y', { maxAge: 3600 })` — has no `.split`, so the call throws `TypeError: attributes[a].split is not a function` and the cookie is never written.
  Empirical proof (Node re-impl of the attribute loop): `setAttrs({ path: '/', maxAge: 3600 })` -> `CRASH: TypeError - attributes[a].split is not a function`.
  Impact: an uncaught runtime crash on misuse (passing a number where a string is expected). Standard attributes (`path`, `domain`, `expires` after its Date->`toUTCString` conversion, `secure`/`sameSite`) are strings/booleans and are unaffected. Pre-existing upstream; low severity (caller-misuse triggered, developer-controlled input).

## Notes
- **Baseline checks (environmental, not a code defect):** `npm test` runs `grunt test`, which drives QUnit inside a real browser via Selenium/BrowserStack and cannot run in this headless sandbox; the auto-detected `typecheck` command pointed at `backend/firebase-research` (a path that does not exist in this repo) and is a misdetection, not a project script. Neither failure reflects a bug in the code under review. Because this is detect-only, no fixes were attempted and no regression gate was needed.
- **Out of scope as bugs (correctly ignored):** the webpack example's `node-static` static server (`examples/webpack/server.js`) is an unauthenticated demo file server, but it is example/demo code that ships in `examples/`, not part of the published package (`files: ["index.js", "dist/**/*"]`); not flagged as a library bug.
- **Whole-repo frontier persisted** to `.bugsweep/state/` for the next run; this run audited the entire codebase.

## How to review
git diff bench-base..bugsweep/20260530-013717
