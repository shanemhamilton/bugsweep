# React / React Native / Next.js (client) anti-patterns

## Hooks and state
- `useEffect` with a wrong/missing dependency array — stale closures reading old state, or
  effects that don't re-run when they should. Smell: effect uses a value not in deps.
- Setting state in a way that drops updates: `setCount(count + 1)` in async/batched paths
  instead of `setCount(c => c + 1)`.
- Effect that starts async work but doesn't cancel/ignore on unmount — setState after
  unmount, or a race where a slow earlier request overwrites a fast later one.
- Missing cleanup for subscriptions, timers, listeners (leaks, duplicate handlers).
- Derived state duplicated into `useState` and then going stale instead of computed on
  render.

## Rendering and keys
- List items keyed by array index while the list reorders/filters — wrong items update,
  state attaches to the wrong row.
- Object/array/function created inline as a prop causing unnecessary re-renders, or
  breaking `memo`/effect deps.

## Security (client)
- `dangerouslySetInnerHTML` with unsanitized content (XSS).
- Secrets/API keys embedded in client bundles or `NEXT_PUBLIC_*` env vars.
- Trusting client-side checks for authorization (must be enforced server-side).

## Data and async
- Fetch waterfalls vs. assuming data is present before it loads (reading `.map` on
  undefined during first render).
- No loading/error state, so an error renders as a blank or a crash.
- Next.js: leaking server-only data or secrets into client components; mixing server/client
  boundaries; caching a response that should be per-user.

## React Native specifics
- Assuming a permission is granted without checking the result.
- Platform-specific APIs called without an `isPlatform` guard.
