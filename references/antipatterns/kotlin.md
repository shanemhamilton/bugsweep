# Kotlin anti-patterns

Kotlin's null-safety and coroutines prevent whole bug classes — but Java interop,
concurrency, and a few language conveniences re-open them. For Android UI specifics also
consider lifecycle/leak patterns below.

## Null safety and Java interop
- Platform types from Java (`String!`) — the compiler can't enforce nullability, so a
  Java method returning null assigned to a non-null Kotlin type throws NPE at use. Smell:
  Kotlin calling Java/Android SDK and treating results as non-null.
- `!!` (not-null assertion) on something that can actually be null → NPE. Each `!!` is a
  claim to verify.
- `lateinit var` read before initialization (`UninitializedPropertyAccessException`);
  using `lateinit` for something nullable instead of a nullable type.
- Ignoring nullability of map lookups (`map[key]` is `V?`) and treating as non-null.

## Coroutines and concurrency
- Launching in `GlobalScope` (or a scope that outlives the screen) → leaks and work that
  outlives its owner. Use a lifecycle-bound scope.
- Swallowed cancellation: `catch (e: Exception)` inside a coroutine catches
  `CancellationException` and breaks structured concurrency. Catch specific types or
  rethrow `CancellationException`.
- Blocking calls on a coroutine dispatcher meant to be non-blocking (block the thread);
  not switching to `Dispatchers.IO` for IO.
- `runBlocking` on the main thread (Android) — frozen UI / ANR.
- Shared mutable state accessed from multiple coroutines without a mutex/confined
  dispatcher (data race); check-then-act across a suspension point.
- Fire-and-forget `launch` whose exception is lost (no handler), vs `async` whose
  exception only surfaces on `await`.

## Language conveniences that bite
- Scope-function confusion: `also`/`apply` return the receiver, `let`/`run` return the
  lambda result — returning the wrong thing. `apply` used where the result was needed.
- `lazy` property that is not thread-safe (`LazyThreadSafetyMode.NONE`) read from multiple
  threads.
- `data class` `equals`/`hashCode` based only on constructor properties — body properties
  ignored, surprising set/map behavior; `copy()` bypassing validation done in `init`.
- `companion object` mutable state acting as a global singleton mutated per-call.
- Overflowing `Int` arithmetic; truncation on `toInt()`; `Double` for money instead of
  `BigDecimal`.
- `when` without `else` on a non-sealed type, or a non-exhaustive `when` used as a
  statement so a missing branch is silently skipped.
- Default arguments + named-argument mismatches changing which overload runs.
- Elvis hiding a real error: `?: return`/`?: 0` that masks a condition the caller should
  handle.

## Android specifics
- Holding a `Context`/`Activity`/`View` in a longer-lived object (static, ViewModel,
  singleton) → memory leak.
- Accessing `ViewBinding`/views after the fragment view is destroyed.
- Updating UI off the main thread.
- Not checking a runtime permission result before using the protected API.
- Secrets hardcoded in source/`BuildConfig`; sensitive data in `SharedPreferences`
  unencrypted instead of `EncryptedSharedPreferences`/Keystore.
