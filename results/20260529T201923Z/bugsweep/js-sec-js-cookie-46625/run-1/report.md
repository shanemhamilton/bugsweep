# bugsweep report — 20260529-201932
**Branch:** bugsweep/20260529-201932   **Mode:** detect-only   **Iterations:** 1
**Stack:** browser-targeting JavaScript (ESM under `src/`), Node 20 test harness (Grunt
+ rollup + Qunit + Selenium/BrowserStack)
**Baseline checks:** unable to run in this sandbox — `npm` not on PATH and the run_checks
script searched a `backend/firebase-research` directory that doesn't exist in this repo
(harness false-positive, NOT a code defect). The project's checks are `grunt test` (Qunit
in headless Chromium via puppeteer) + Node-side Qunit; both require `npm install` first.
**Final checks:** N/A (detect-only, no code changed).

## Summary
- Confirmed bugs: **6** (critical 0, high 0, medium 2, low 4); architectural: **2**
- Fixed & verified: 0 (detect-only)
- Quarantined (needs human): 2 informational items (not confirmed bugs)
- Coverage: 4/4 batches covered; reviewed via Hunter → Skeptic → Referee

## Fixed
*(none — detect-only run)*

## Quarantined / needs human
- INFO-1 · n/a · `test/utils.js:47-58` · iframe `load` listeners accumulate per `using(assert).setCookie(...)` call. Latent: QUnit recreates the iframe between tests AND every current test calls `setCookie` only once, so the bug does not manifest today. Would surface if anyone writes a test with two consecutive `setCookie` calls against the same iframe. Test-only.
- INFO-2 · n/a · `src/api.mjs:50` · `Cookies.get('')` returns undefined. By design — tests verify the same behavior for `null`/`undefined`.

## Confirmed but not fixed (detect-only)

### BUG-1 · medium · local + architectural · `src/converter.mjs:3-5`
**Default read converter strips trailing char on unpaired-quote cookies.**
The check `if (value[0] === '"') value = value.slice(1, -1)` assumes the value is RFC 6265
`DQUOTE *cookie-octet DQUOTE` (paired). When stored value starts with `"` but does NOT
end with `"`, `slice(1, -1)` removes the leading `"` AND the last (unrelated) character.
- **Trigger.** Any other code on the page writes `document.cookie = 'c="abc'`. Then
  `Cookies.get('c')` returns `'ab'` instead of `'"abc'`.
- **Why this matters.** js-cookie's own writer encodes `"` as `%22`, so cookies set by the
  library never trip this. The corruption happens on cookies set by OTHER code — server
  `Set-Cookie` headers, other JS libraries, direct `document.cookie =` writes by
  third-party scripts. Silent data corruption is hard to diagnose.
- **Recommended fix shape.** Strip only when BOTH quotes are present:
  `if (value[0] === '"' && value[value.length - 1] === '"') value = value.slice(1, -1)`.

### BUG-4 · medium · architectural · `src/assign.mjs:4` + `src/api.mjs:24`
**`for…in` without `hasOwnProperty` propagates Object.prototype pollution.**
Both the `assign` merge function and the attribute-emit loop in `api.mjs` enumerate
inherited enumerable properties.
- **Trigger.** Any prior page code executes `Object.prototype.domain = 'attacker.example'`.
  Subsequent `Cookies.set('c', 'v')` produces the header
  `c=v; path=/; domain=attacker.example`. The browser rejects the cookie outright
  (cross-domain mismatch) → silent set failure. For other polluted keys (e.g. `secure`,
  `samesite`, `expires`), the cookie is set with unintended attributes.
- **Why this matters.** Prototype pollution is a well-known gadget that flows through any
  unguarded `for…in`. A cookie library is a high-value target for that flow, and the
  defense is one line: replace `for (var k in src)` with
  `for (var k in src) if (Object.prototype.hasOwnProperty.call(src, k))`, or switch to
  `Object.keys(src).forEach(...)`.

### BUG-2 · low · local + architectural · `src/api.mjs:12-17`
**NaN `expires` writes the literal string `"Invalid Date"` into the cookie header.**
`typeof NaN === 'number'` is true → `new Date(Date.now() + NaN * 864e5)` is Invalid Date
(truthy object) → `.toUTCString()` returns `'Invalid Date'`. The cookie header becomes
`c=v; path=/; expires=Invalid Date`.
- **Trigger.** `Cookies.set('c', 'v', { expires: Number(maybeUndefined) })` where the
  value is missing, or any arithmetic with one undefined operand.
- **Why this matters.** Browsers treat malformed `expires` as session-cookie default →
  the developer believes the cookie was persistent, but it disappears on browser close.
  Silent persistent→session downgrade.
- **Recommended fix shape.** `if (typeof attributes.expires === 'number' && !isNaN(attributes.expires))` (or check `attributes.expires instanceof Date` and validate `getTime()` in the second branch).

### BUG-3 · low · local · `src/api.mjs:15-17`
**String `expires` throws TypeError.**
`'2030-01-01'.toUTCString` is `undefined`. The call at line 16 throws synchronously and
propagates out of `set`. The README documents `expires` as `Number | Date`, but no
runtime check guards it.
- **Trigger.** `Cookies.set('c', 'v', { expires: '2030-01-01T00:00:00Z' })`.
- **Why this matters.** UX/contract gap. Loud (not silent) failure, but the call should
  either accept a Date-coercible string or reject with a clearer error.

### BUG-5 · low · local · `src/api.mjs:25-27`
**Falsy attribute values silently dropped — `maxAge: 0` and similar numeric-zero attributes disappear.**
`if (!attributes[attributeName]) continue` skips `0`, `""`, `false`, `null`, `undefined`,
`NaN`. For booleans like `secure: false`, that's intentional (omit the flag). For
NUMERIC attributes, `0` is a legitimate value: RFC 6265 explicitly assigns meaning to
`Max-Age=0` ("expire immediately").
- **Trigger.** `Cookies.set('c', 'v', { maxAge: 0 })`. Expected `c=v; path=/; maxAge=0`;
  actual `c=v; path=/` (silently dropped).
- **Why this matters.** Most callers use `Cookies.remove()` for delete-now, so impact is
  limited — but it's a real contract issue for any caller that wants a numeric-zero
  attribute. Intent appears to be "skip undefined", which would be `== null`.

### BUG-8 · low · architectural · `src/api.mjs:24` + `:29`
**Attribute KEY is not validated; semicolons/`=` in keys smuggle directives into the cookie header.**
The attribute-emit loop appends `attributeName` verbatim at line 29 with no defense; the
matching `.split(';')[0]` defense at line 42 only chops the VALUE side. The asymmetry is
the smoking gun — the writer KNOWS to defend the value, but overlooks the key.
- **Trigger.** `Cookies.set('c', 'v', { 'foo; path=/admin': 'bar' })` →
  `c=v; path=/; foo; path=/admin=bar`. Browser last-wins on `Path` → cookie rebound to
  `/admin=bar` instead of `/`.
- **Why this matters.** Realistic only when a developer forwards attacker-controlled
  attribute KEYS into `Cookies.set` (feature-flag systems, dynamic attribute objects
  merged from configs/user input). Newlines/CR are blocked at the `document.cookie =`
  layer by browsers; `;` and `=` are not.
- **Recommended fix shape.** Mirror the value defense on the key:
  `attributeName.split(';')[0]`, or reject keys containing `;`/`=`.

---

## How to review
This was a detect-only run — nothing was committed. To inspect the artifacts:
```
ls /scratch/repo/.bugsweep/run-20260529-201932/
cat /scratch/repo/.bugsweep/run-20260529-201932/repo-context.md
cat /scratch/repo/.bugsweep/run-20260529-201932/antipatterns.md
cat /scratch/repo/.bugsweep/run-20260529-201932/hunt-findings.md
cat /scratch/repo/.bugsweep/run-20260529-201932/challenge.md
cat /scratch/repo/.bugsweep/run-20260529-201932/referee.md
```
The throwaway branch `bugsweep/20260529-201932` contains no commits. If you want to act on
the findings yourself, the recommended order is BUG-1 and BUG-4 first (medium severity,
small fixes), then the four low-severity ones together.