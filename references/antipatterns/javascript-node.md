# Node.js / JavaScript / TypeScript anti-patterns

## Async and control flow
- Missing `await` on a promise — the value is a pending Promise, not the result;
  conditions on it are always truthy and errors become unhandled rejections.
- `forEach` with an async callback — it does not await; iterations run uncoordinated and
  errors are lost. Use `for...of` with await or `Promise.all`.
- Unhandled promise rejection paths (no `.catch`, no try/await) crash or silently drop.
- `Promise.all` where one rejection should not abort the rest (use `allSettled`), or the
  reverse — swallowing failures that should abort.

## Type and value traps
- `==` vs `===` coercion; `0`, `""`, `NaN`, `null`, `undefined` falsy surprises.
- `JSON.parse` without try/catch on untrusted input.
- `parseInt` without radix; `Number()` on user input producing `NaN` used downstream.
- Optional chaining masking a real "should never be null" bug, or its absence causing
  `cannot read property of undefined`.

## Security
- SQL built by string concatenation/template literals instead of parameterized queries.
- `child_process.exec`/`execSync` with interpolated input (command injection); prefer
  `execFile` with an args array.
- Path built from user input passed to `fs` without normalization/containment (traversal).
- `req.query`/`req.body`/`req.params` trusted for authz, price, role, or IDs.
- Open redirects from user-supplied URLs; SSRF from user-supplied hostnames in server-side
  fetch.
- Secrets in `process.env` logged or returned in error responses.

## Express/HTTP specifics
- Async route handler that throws — in Express 4 the error isn't caught unless wrapped;
  the request hangs.
- Missing input validation middleware on a mutating route.
- Returning the whole DB object (leaking fields like passwordHash, internal flags).
- Wrong status codes that change caller behavior (200 on failure).

## TypeScript
- `as any` / `as Foo` casts that hide a real shape mismatch at a boundary.
- Non-null assertion `!` on something that can be null at runtime.
- Trusting types on data that crossed an untyped boundary (network, JSON) without runtime
  validation.
