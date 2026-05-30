# bugsweep report — 2026-05-29 17:47:42 UTC
**Branch:** bugsweep/20260529-174742   **Mode:** detect-only (no fixes, no commits)   **Iterations:** 1
**Stack:** Vanilla ES modules (browser), Rollup ESM+UMD, CommonJS shim, Grunt+QUnit+Selenium tooling, Node ≥20
**Baseline checks:** test fail, typecheck fail (typecheck is in an unrelated `backend/firebase-research` dir not present in repo; npm test fails because `dist/` isn't built — neither blocks detection)
**Final checks:** unchanged (detect-only, no edits)

## Summary
- Confirmed bugs: 7 (critical 0, high 0, medium 3, low 4); architectural: 2
- Fixed & verified: 0   Quarantined (needs human): 0
- Coverage: 4/4 batches reviewed via Hunter -> Skeptic -> Referee on `src/api.mjs`, `src/converter.mjs`, `src/assign.mjs`, plus the build/test surface. Architectural lens walked T1–T8 in `recon.json`.

## Fixed
(none — detect-only mode)

## Quarantined / needs human
(none — every finding below is concrete; none was DISPUTED or NOT-CONFIRMED. They are listed under "Confirmed but not fixed" because this run is detect-only.)

## Confirmed but not fixed (detect-only)

### BUG-1 · medium · architectural (T2) · `src/assign.mjs:4`
**Prototype-chain walk in `assign` lets polluted `Object.prototype` keys flow into cookie attributes.**
- The whole helper is `for (var key in source) target[key] = source[key]` — `for..in` enumerates inherited enumerable string keys, not just own properties. There is no `Object.hasOwn(source, key)` guard and no `Object.keys(source)` filter.
- Concrete trigger: any other script on the page does `Object.prototype.domain = 'evil.com'` (a known proto-pollution payload). The next `Cookies.set('c', 'v')` runs `assign({}, defaultAttributes, attributes)` which copies the inherited `domain` into `attributes`, then the serialize loop emits `; domain=evil.com`. The resulting `document.cookie = 'c=v; path=/; domain=evil.com'` is honored by the browser.
- Manifests in the full set chain: `Cookies.set` -> `set()` (api.mjs:5) -> `assign({}, defaultAttributes, attributes)` (api.mjs:10) -> for-in serializer (api.mjs:24-43) -> `document.cookie =` (api.mjs:45-46). The for-in at api.mjs:24 also walks inherited keys on its own — same vulnerability shows up twice on the path.
- Evidence: `src/assign.mjs:1-9`; the loop body never checks `Object.prototype.hasOwnProperty.call(source, key)`.
- Why it matters: js-cookie is loaded in pages alongside arbitrary third-party scripts; a prototype-pollution gadget elsewhere on the page silently poisons every subsequent cookie write (domain, path, secure, etc.). Standard defensive posture for a library at this trust boundary is to enumerate own keys only.

### BUG-2 · medium · architectural (T1) · `src/api.mjs:24-43`
**Attribute *name* is interpolated into the cookie header without sanitization, defeating the `;` filter that is applied to values.**
- The serializer applies `.split(';')[0]` to each attribute *value* (api.mjs:42) — that is the entire defense against attribute-injection. But the attribute *key* is concatenated raw at api.mjs:29: `stringifiedAttributes += '; ' + attributeName`.
- Concrete trigger: `Cookies.set('c', 'v', {'a; Secure': '1'})` produces `c=v; path=/; a; Secure=1`. The browser parses this as setting the `Secure` flag despite the caller never asking for it. Likewise `Cookies.set('c', 'v', {'a; HttpOnly': '1'})` — though `HttpOnly` set via `document.cookie` is stripped by browsers, `Secure`, `Max-Age`, `Domain`, and `Path` are not, so the injection is real for those.
- Manifests when callers ever build attribute objects from untrusted input — e.g., a settings UI that lets users add arbitrary attribute key/value pairs, or `assign({}, defaults, JSON.parse(req.body))`. The library is the last line of defense before `document.cookie =` and the docs explicitly market `.split(';')[0]` (tests.js:434-446) as that line. The defense is one-sided: values are stripped, keys are not.
- Evidence: `src/api.mjs:29` (raw `attributeName` concatenation), contrasted with `src/api.mjs:42` (the `.split(';')[0]` applied only to the value). Verified by walking each control-flow path through the for-in.
- Defensive fix would mirror what is done for values (strip after first `;`) or whitelist a token-only key shape; bugsweep does not fix in detect-only mode.

### BUG-3 · medium · local · `src/api.mjs:49-74`
**Cookie names that collide with `Object.prototype` keys are unreadable and `get` returns the inherited prototype value instead.**
- `get` initializes `var jar = {}` (a plain object whose chain includes `Object.prototype`) and uses `if (!(found in jar)) jar[found] = converter.read(value, found)`. The `in` operator is `[[HasProperty]]` — it returns `true` for any inherited property, including `toString`, `hasOwnProperty`, `valueOf`, `__proto__`, `constructor`, `isPrototypeOf`, etc.
- Concrete trigger: another script (or a server `Set-Cookie`) sets `toString=hello`. Then:
  - `Cookies.get('toString')` — the loop computes `found = 'toString'`. `'toString' in jar` is `true` (it is on `Object.prototype`), so the assignment `jar.toString = ...` never happens. The `if (name === found) break` does fire, then `return name ? jar[name] : jar` evaluates `jar['toString']`, which is the native `Object.prototype.toString` *function*. Caller receives a function rather than the string `'hello'` (or `undefined`).
  - `Cookies.get()` (no name) — same: `jar.toString` is the inherited function, the real cookie is silently dropped from the snapshot. The cookie is invisible to the consumer.
- Manifests on the legacy-document.cookie surface: literal cookie names like `toString`, `__proto__`, `hasOwnProperty` are rare in practice but legal under RFC 6265 cookie-name grammar, and the bug returns wildly wrong types (function, prototype object) instead of strings.
- Evidence: `src/api.mjs:57` (`var jar = {}`), `src/api.mjs:64` (`if (!(found in jar))`), `src/api.mjs:73` (`return name ? jar[name] : jar`).
- Standard fix shape would be `Object.create(null)` for `jar` or `Object.prototype.hasOwnProperty.call(jar, found)`; bugsweep does not fix in detect-only mode.

### BUG-4 · low · local · `src/api.mjs:24-42`
**Numeric attribute values throw `TypeError: x.split is not a function`.**
- The serializer assumes every non-`true` attribute value is a string (api.mjs:42: `attributes[attributeName].split(';')[0]`). The `expires` attribute is type-coerced (Number -> Date -> `toUTCString()`) but no other attribute is.
- Concrete trigger: `Cookies.set('c', 'v', { 'max-age': 60 })` throws `TypeError: (60).split is not a function`. Same for any caller that passes a numeric `samesite-version`, custom attribute, etc.
- The library documents `expires`, `path`, `domain`, `secure`, `sameSite` as the supported attributes (README; tests.js:382-392 covers `unofficial` as a string). Numeric Max-Age is a natural mistake.
- Evidence: `src/api.mjs:42`.
- A safe defensive change would be `String(attributes[attributeName]).split(';')[0]`. Detect-only; no edit.

### BUG-5 · low · local · `src/api.mjs:15-17`
**String `expires` values throw `TypeError: x.toUTCString is not a function`.**
- The number-to-Date coercion at api.mjs:12-14 handles `typeof === 'number'` only. The subsequent `if (attributes.expires) attributes.expires = attributes.expires.toUTCString()` assumes the value is a `Date`.
- Concrete trigger: `Cookies.set('c', 'v', { expires: '2024-01-01' })` throws `TypeError: "2024-01-01".toUTCString is not a function`. The README types `expires` as `Number | Date` so the input is unsupported, but the failure is a runtime crash rather than a coerced or ignored value.
- Evidence: `src/api.mjs:15-17`.
- Defensive shape: coerce string with `new Date(attributes.expires)` if not already a Date; if invalid, drop the attribute. Detect-only; no edit.

### BUG-6 · low · local · `src/converter.mjs:2-7`
**`read` strips only the leading quote when a cookie value starts with `"` but is not balanced, silently corrupting the value.**
- The implementation is `if (value[0] === '"') { value = value.slice(1, -1) }` — there is no symmetric `value[value.length - 1] === '"'` check.
- Concrete trigger: another script writes `document.cookie = 'c="hello'` (unbalanced — set by buggy server, edited via dev tools, or `Set-Cookie: c="hello`). Then `Cookies.get('c')` returns `'hell'` — the leading `"` AND the trailing `o` are dropped, corrupting the value.
- Evidence: `src/converter.mjs:3-5`. RFC 6265 §5.2.3 only specifies that *both* DQUOTEs be stripped when the cookie-value is DQUOTE-enclosed; the implementation strips unconditionally on a leading quote.
- Defensive shape: only `slice(1, -1)` when both ends are `"`. Detect-only; no edit.

### BUG-7 · low · architectural (T5) · `src/api.mjs:25-27`
**`if (!attributes[attributeName]) continue` silently drops `Max-Age: 0` and any other legitimate falsy attribute value.**
- The truthiness gate at api.mjs:25 treats `0`, `''`, `false`, `null`, `undefined` as "skip this attribute." For most attributes this is the right thing (omitting `secure: false` is the documented behavior; omitting `path: ''` is the *documented* way to mean "current page", and the test at tests.js:358-360 enshrines `path: undefined` as a no-op).
- But `Max-Age: 0` is meaningful: per RFC 6265 §5.2.2, `Max-Age=0` instructs the user agent to delete the cookie immediately. A caller writing `Cookies.set('c', '', { 'max-age': 0 })` to delete a cookie via Max-Age gets a `path=/` cookie with empty value and NO Max-Age — the cookie is created/refreshed instead of being deleted. Similarly `expires: 0` (treated as a number, coerced to "now") works fine, but raw `0` on any custom numeric attribute is lost.
- Evidence: `src/api.mjs:25-27`. The check would need to be class-specific (e.g., distinguish booleans-as-flags from values that may legitimately be `0`/`''`). Lower severity because `Cookies.remove(name)` is the supported delete path; high enough to record because Max-Age users will hit it silently.

## How to review
```
git diff bench-base..bugsweep/20260529-174742   # no diff — detect-only
```
All artifacts: `/scratch/repo/.bugsweep/run-20260529-174742/` (`repo-context.md`, `recon.json`, `antipatterns.md`, `ledger.jsonl`, this report).
