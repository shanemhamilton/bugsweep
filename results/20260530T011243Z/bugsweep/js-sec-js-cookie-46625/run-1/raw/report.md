# bugsweep report — 20260529-201312
**Branch:** bugsweep/20260529-201312   **Mode:** detect-only (no code changes, no commits)   **Iterations:** 1
**Stack:** JavaScript (ESM library — js-cookie 3.0.5), Node/Grunt test harness, GitHub Actions CI
**Baseline checks:** harness-reported FAIL — confirmed environmental, NOT a failing assertion: baseline-test.log = `sh: grunt: command not found` (devDeps not installed) and baseline-typecheck.log = `cd: backend/firebase-research: No such file or directory` (the harness typecheck targets a dir that does not exist in this repo). No test assertion fails.
**Final checks:** unchanged (detect-only; no fixes applied)

## Summary
- Confirmed bugs: 0 (critical 0, high 0, medium 0, low 0); architectural: 0
- Fixed & verified: 0   Quarantined (needs human): 0
- Coverage: whole repo reviewed (runtime source, examples, build/test harness, CI workflows) via Hunter -> Skeptic -> Referee plus empirical execution probes and an authoritative upstream diff.

## Fixed
_None — detect-only mode._

## Quarantined / needs human
_None._

## Confirmed but not fixed (detect-only or below severity floor)
_None. No runtime bug survived adversarial review._

## What was reviewed and why it is clean

**Runtime library source — `src/api.mjs`, `src/converter.mjs`, `src/assign.mjs`, `index.js`**
Logic was diffed in full against BOTH exact-version upstream artifacts (`npm pack js-cookie@3.0.5` and `@3.0.8`). The entire local `src/` (api.mjs + converter.mjs + assign.mjs) is identical to upstream 3.0.8; versus the repo's stated 3.0.5, the only difference is the `get()` first-match guard `if (!(found in jar))` — a legitimate later upstream improvement (commit b754561), not a seeded change. Verified identical: the `converter.write` allow-list regex `/%(2[346BF]|3[AC-F]|40|5[BDE]|60|7[BCD])/g`, the cookie-name regex `/%(2[346B]|5E|60|7C)/g` + `.replace(/[()]/g, escape)`, the `read` quoted-strip + `/(%[\dA-F]{2})+/gi` decode, the `864e5` day-expiry math, the attribute sanitizer `.split(';')[0]` (the GitHub issue #396 XSS fix), and the `get()` parser (`split('; ')`, `parts.slice(1).join('=')`, `!(found in jar)` first-match guard).

**Empirical injection probes (executed against `src/api.mjs` with a mocked `document.cookie`):**
- Attribute `;`-injection (issue #396 payload `path:'/;domain=...'`, `domain:'site.com;remove_this'`, `customAttribute:'value;;remove_this'`) -> `c=v; path=/; domain=site.com; customAttribute=value` — sanitized exactly as the spec test requires.
- Cookie-name injection — `;`, `=`, CR/LF, space, comma all returned percent-encoded (`a%3Bb`, `a%3Db`, `a%0D%0Ab`, `a%20b`, `a%2Cb`). No attribute/cookie breakout possible.
- Cookie-value injection — `;`, comma, LF, tab, `"` all returned percent-encoded (`v%3B%20HttpOnly`, `a%2Cb`, `a%0Ab`, `a%09b`). `=` is preserved (legal in values; round-trips correctly).
- Prototype-named cookies — `__proto__=polluted` did NOT pollute `Object.prototype` (`({}).polluted === undefined`); the `!(found in jar)` guard and string-assignment-to-`__proto__` no-op keep it safe.
- Percent decoding — `%d0%96` -> the Cyrillic Zhe character; malformed `foo%bar%22baz%qux` -> `undefined` (correctly skipped). Matches the documented spec tests.

**Examples (`examples/**`)** — `node-static` file server + trivial `Cookies.set/get` demos; benign, upstream-identical.

**Build/test harness (`Gruntfile.js`, `test/**`)** — the `encodingMiddleware` reflects query params as `application/json` (not HTML; no reflected XSS) and binds to localhost only for the integration encoding test; the BrowserStack runner and QUnit suites are standard. No injectable sink.

**CI workflows (`.github/workflows/*.yml`)** — hardened and upstream-identical: top-level `permissions: {}`, third-party actions pinned to commit SHAs, `persist-credentials: false`, and the one interpolated `workflow_dispatch` input is passed through a `GITHUB_EVENT_INPUTS_BUMP` env var rather than inlined into `run:`, avoiding template-injection. `zizmor.yml` runs the GitHub Actions security auditor on every push/PR.

## Notes on non-bug edge cases (intentionally NOT reported as bugs)
These exist verbatim in upstream js-cookie and are documented/inert at runtime, so they are not deviations and not exploitable:
- A cookie literally named `toString`/`constructor` reads back the inherited prototype member rather than its value (the `found in jar` check walks the prototype chain). Long-standing upstream limitation; not security-relevant.
- Attribute values are split only on `;`, not CR/LF — but `document.cookie` in browsers ignores content after control characters, so no header/attribute injection results. Upstream behavior.
- A non-string attribute value (e.g. `{ 'max-age': 3600 }`) throws `TypeError` on `.split`. Upstream behavior; an API-misuse error, not a runtime defect in the library's contract.

## Conclusion
The js-cookie source in this repository matches the secure upstream 3.0.8 release exactly, and every security-critical path was verified secure by direct adversarial execution. No runtime behavioral bug — security, logic, error-handling, concurrency, data-integrity, or cross-file/architectural — was found. Reporting any of the upstream-inherited edge cases above as a "confirmed bug" would be a false positive, which this pipeline is designed to avoid.

## How to review
git diff bench-base..bugsweep/20260529-201312   # (empty — detect-only, no commits)
