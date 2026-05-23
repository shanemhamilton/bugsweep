# TypeScript anti-patterns

TypeScript's type system is unsound by design in places, and types vanish at runtime.
These patterns are about bugs the compiler *won't* catch. For runtime/async JS issues
(missing `await`, `==` coercion, `JSON.parse`, Express handlers), also load
`javascript-node.md`.

## Escape hatches that hide real bugs
- `as` assertions (`x as Foo`, `as unknown as Foo`) — these *assert*, they don't *check*.
  A wrong assertion at a boundary silently propagates a bad shape. Smell: casting the
  result of `JSON.parse`, an API response, or `any` straight to a domain type.
- `any` (explicit or inferred) — disables checking transitively. One `any` at a boundary
  poisons everything downstream. `noImplicitAny` off is a repo-wide smell.
- Non-null assertion `!` (`user!.id`) on a value that genuinely can be null/undefined at
  runtime → `cannot read property of undefined`.
- `@ts-ignore` / `@ts-expect-error` suppressing a diagnostic that points at a real bug.
- Double assertion `as unknown as T` to force an incompatible cast — almost always hiding
  a defect.

## Unsound or surprising typing
- Trusting types on data that crossed an untyped boundary (network, `localStorage`, env
  vars, `JSON.parse`, `process.env`, message payloads) without runtime validation (zod /
  io-ts / manual guards). The type is a *claim*, not a check.
- Array index access typed as `T` but actually `T | undefined` (unless
  `noUncheckedIndexedAccess` is on) — `arr[i]` and `map[key]` can be undefined at runtime.
- Optional property vs `undefined` value confusion; `exactOptionalPropertyTypes` off lets
  `{ x: undefined }` satisfy `{ x?: T }`.
- Function parameter bivariance and unsound method types allowing a wrong callback shape.
- `object`/`{}`/`Function` types that accept far more than intended.

## Enums, unions, narrowing
- Numeric `enum` reverse-mapping and accepting arbitrary numbers; prefer string enums or
  union literals.
- Non-exhaustive `switch` over a union with no `default: assertNever(x)` — adding a union
  member silently skips handling.
- Type guards that lie (`x is Foo` predicate whose body doesn't actually prove it).
- Narrowing lost across an `await` or a closure (re-widened to the original type).

## Async typing traps
- `async` function whose return isn't awaited — type is `Promise<T>`, treated as `T`.
- Typing a value as `T` when the API can return `T | null`; mismatched
  `Promise<void>` vs fire-and-forget.
- `void` return type swallowing a returned promise in callbacks (floating promises).

## Config and build smells
- Loose `tsconfig`: `strict: false`, `strictNullChecks: false`,
  `noUncheckedIndexedAccess: false` — most of the above only get caught with strict on.
- `skipLibCheck` masking a real type conflict from a dependency at a boundary you use.
- Declaration merging / module augmentation that silently changes a third-party type.
