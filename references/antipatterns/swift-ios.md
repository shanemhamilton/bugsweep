# Swift / SwiftUI / UIKit / iOS anti-patterns

## Optionals and crashes
- Force-unwrap `!` or `try!` on something that can be nil/throw at runtime — crash. Smell:
  `URL(string: userInput)!`, `dict[key]!`, force-cast `as!`.
- Implicitly unwrapped optionals (`var x: Foo!`) used before assignment.
- `fatalError`/`precondition` reachable from user input.

## Concurrency and memory
- Updating UI off the main thread (UIKit/SwiftUI must update on `@MainActor`/main queue) —
  flicker, corruption, crashes.
- Retain cycles: closures capturing `self` strongly (timers, networking callbacks,
  Combine sinks) without `[weak self]`.
- Data race on shared mutable state across queues/tasks without isolation; `async`/`await`
  check-then-act gaps; misuse of `@State`/`@StateObject` vs `@ObservedObject` causing lost
  or duplicated state.
- `Task {}` that captures self and isn't cancelled when the view disappears.

## Data and value handling
- Money/quantities in `Double` instead of `Decimal` — rounding errors.
- `Date` math assuming a fixed calendar/timezone; ignoring `Calendar`/`TimeZone`.
- Integer overflow with `&+`/unchecked arithmetic, or truncating conversions
  (`Int(largeDouble)`).
- Force-decoding JSON; `Codable` with non-optional fields that the server can omit → decode
  failure that's swallowed.

## Security / privacy (iOS)
- Secrets/API keys hardcoded in source or Info.plist.
- Sensitive data in `UserDefaults` (not encrypted) instead of Keychain.
- Logging PII or tokens; sensitive data in screenshots/pasteboard.
- Missing App Transport Security; trusting any TLS cert; ignoring certificate validation.
- Not checking the result of a permission/authorization request before using the resource.

## SwiftUI specifics
- View identity bugs from missing/unstable `.id`; `onAppear` doing work that re-runs
  unexpectedly; `@StateObject` recreated each render because it was declared as
  `@ObservedObject` on an owned object.
