# Go anti-patterns

## Errors and nil
- Ignored errors (`val, _ := f()`) where the error matters — proceeding with a zero value.
- Returning a non-nil error but also a partially-populated value the caller uses.
- Nil pointer/map/interface dereference; writing to a nil map (panic). Smell: `var m
  map[k]v` then `m[x] = y` without `make`.
- Typed-nil-in-interface: a nil pointer wrapped in an interface is `!= nil`.

## Concurrency
- Data race on shared state without a mutex/channel (run with `-race`). Smell: goroutine
  closing over a loop variable; map written from multiple goroutines.
- Loop variable captured by goroutine/closure (pre-1.22 semantics) — all see the last
  value.
- Goroutine leak: started with no cancellation/`context` and blocks forever; missing
  `ctx` propagation; ignoring `ctx.Done()`.
- `WaitGroup` Add/Done mismatch; deadlock on unbuffered channel.

## Resources and data
- `defer` for cleanup placed after the error return, so it never runs; or `defer` in a
  loop accumulating open handles.
- `defer rows.Close()`/`resp.Body.Close()` missing → leak.
- Integer overflow / truncating conversions; `int` vs `int64` on 32-bit.
- Time without zone; comparing times with `==` instead of `.Equal`.

## Security
- SQL string concatenation instead of placeholders.
- `exec.Command` with a shell and interpolated input.
- Path from user input without `filepath.Clean` + containment check.
- `http.Get` to user-controlled URL (SSRF); skipping TLS verification.
- Secrets in source or logs.

## HTTP/server
- Not checking `r.Context()` cancellation on long handlers.
- Writing to `http.ResponseWriter` after `WriteHeader` / after returning.
- Trusting client headers/body for authz or identity.
