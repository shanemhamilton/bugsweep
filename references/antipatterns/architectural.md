# Cross-file / architectural anti-patterns

Patterns that per-file scanning misses because the bug spans a module or package
boundary. Always loaded alongside `generic.md`; these patterns are framework-agnostic.
For each pattern: the "smell" to search for and the chain to trace.

---

## 1. SSRF via configurable URL without outbound validation

**Shape:** A user-controllable or attacker-controllable value (URL, hostname, IP) is
stored in config/DB and later used to make an outbound HTTP/TCP connection. The
validation that blocks private/loopback/internal addresses is absent or only applied
on some code paths.

**Trace:** `config write → storage → read → http.Client.Do(req)` — check every path
from the storage read to the dial for an IP allowlist/blocklist enforcement.

**Watch for:**
- Notification/webhook URL fields in config models
- Integration/connector URL fields
- HTTP clients constructed from user-supplied base URLs
- Absence of `net.LookupHost` or post-dial IP check
- Response bodies reflected back to the caller (amplifies impact to blind-SSRF→data exfil)

---

## 2. Auth bypass via secondary entry point

**Shape:** The primary endpoint into a sensitive operation is protected by
authentication/authorization middleware. A secondary, legacy, internal, or admin
endpoint that reaches the same operation is not.

**Trace:** enumerate *every* registered handler (route table, middleware groups,
manually registered handlers, internal/admin sub-routers) that calls the same
underlying service or sink. Verify the authz check is applied on ALL of them.

**Watch for:**
- `/api/v1/X` guarded; `/api/X`, `/internal/X`, `/admin/X`, `/v2/X` not
- Router middleware applied to a group but handlers registered outside the group
- Sub-applications / sub-routers that skip the parent middleware chain
- Cron or job-runner triggers that call the same service method without auth

---

## 3. Missing authz on a sibling HTTP verb or route variant

**Shape:** `POST /resource` enforces ownership checks; `PUT /resource/{id}`,
`PATCH /resource/{id}`, or `DELETE /resource/{id}` do not.

**Trace:** find every route that shares the same handler prefix or underlying service;
audit each HTTP method / path variant for the same authz checks as the primary.

**Watch for:**
- Bulk endpoints (`/resources/batch`) with weaker checks than singular endpoints
- PATCH/DELETE handlers added later than GET/POST and never given the same scrutiny
- GraphQL mutations without the same field-level authz as their query counterparts

---

## 4. Taint propagation across a package boundary without re-validation

**Shape:** Module A receives untrusted input (HTTP param, JSON field, file content)
and passes it to module B which calls a sensitive sink (SQL, exec, file path). Module
A validates, but a *different* caller of module B does not — or A's validation is
bypassed by a code path that calls B directly.

**Trace:** find every caller of the sink's module; verify each one performs equivalent
validation before calling. A validation in *some* callers is not a validation in *all*
callers.

**Watch for:**
- Functions/methods documented as "expects pre-validated input" called from multiple
  places
- Internal service methods called both from HTTP handlers (validated) and from admin
  scripts / background jobs (not validated)
- Serialization round-trips where a value is deserialized from untrusted bytes and
  passed directly to a business-logic method

---

## 5. Contract drift: "already validated" assumption not enforced

**Shape:** A called function assumes its input satisfies a constraint (non-null,
URL-safe, numeric, already-escaped). The calling code in module A fulfills this, but
a later caller in module B does not, silently breaking the assumption.

**Trace:** identify functions/methods whose docs or param names include "validated",
"sanitized", "trusted", "encoded", "normalized". Enumerate every call site. Find the
site where the constraint is not guaranteed.

**Watch for:**
- Internal helper functions that wrap a sink and document "call only with validated X"
- Functions accepting a `string` where the contract is actually "URL-encoded string"
- Go struct fields tagged `// must be sanitized before use`
- Python service methods that call `cursor.execute(raw_sql)` and document "pass
  parameterized SQL only" — with at least one caller that passes interpolated SQL

---

## 6. Privileged-service forwarding without re-checking caller privilege

**Shape:** Service A (trusted, privileged) forwards a request to service B using a
trusted internal channel. Service B grants privilege based on who it thinks is
calling. A value from the original untrusted external request — a user ID, a role
claim, an account type — is forwarded by A to B, and B acts on it without
re-verifying against the authority.

**Trace:** internal service-to-service calls → check what values from the external
request are forwarded → check what privilege B grants based on those values.

**Watch for:**
- `X-Forwarded-User`, `X-Internal-Role`, `X-Account-Type` headers set by one service
  and trusted by another without signature verification
- Microservice calls that propagate a JWT sub/claims without re-validation at the
  receiving service
- Internal gRPC/thrift calls passing a user-supplied account type field

---

## 7. Inconsistent middleware / guard application across a router tree

**Shape:** Middleware (rate limiting, authn, CSRF, logging) is applied to a router
group but not to all sub-routers or individually registered routes within the app.

**Trace:** build the full list of registered routes; for each, trace the middleware
chain it actually traverses. A route registered outside the guarded group silently
skips the guard.

**Watch for:**
- Express/Koa/Chi/Gin: routes added via `app.use()` or `router.Use()` before the guard
  but after the group definition
- Framework-specific mount order bugs (middleware registered after the route it should
  guard)
- API versioning where v2 routes are added to a new router without copying v1's
  middleware stack

---

## 8. Shared mutable state written from concurrent paths without synchronization

**Shape:** A module-level variable (map, slice, struct field, global cache) is written
from multiple goroutines/threads/event-loop callbacks without a mutex, lock, or
atomic. One path initializes lazily; another reads while initialization is in progress.

**Trace:** find module-level mutable declarations → enumerate every write site → check
for synchronization at every write and every read that follows a conditional write.

**Watch for:**
- Go: `map[T]U` at package level modified in goroutines without `sync.Mutex`/`sync.Map`
- Node.js: shared in-process cache written in async callbacks (though Node is
  single-threaded, shared state can still corrupt across async boundaries if reads and
  writes interleave with `await`)
- Python: `threading.Thread` with shared `dict`/`list` written without `threading.Lock`
- Lazy-initialization patterns: `if cache == nil { cache = build() }` without a once-guard

---

## 9. Deserialization with user-controlled type discriminator

**Shape:** A transport layer deserializes bytes using a type discriminator (class name,
type tag, `@class` field) that is controlled by the sender. The deserialized object is
passed to a business layer that trusts its type. No allowlist of acceptable types is
enforced at the deserialization boundary.

**Trace:** find deserialization call sites → check what determines the type used → find
where the resulting object is used in business logic → verify an allowlist exists
between deserialization and use.

**Watch for:**
- Java `ObjectInputStream`, Python `pickle.loads`, PHP `unserialize`
- JSON deserializers with polymorphic type handling (`@type`, `$type`, `__class__`)
- Protocol Buffers / Thrift `oneof` fields used as type discriminators without
  validation of which variant is acceptable from external callers

---

## 10. Missing cascading check across an internal forwarding chain

**Shape:** A request enters at an external boundary where some checks are applied.
The request (or a derived sub-request) is then forwarded to an internal handler that
performs an additional privileged operation. The internal handler does not re-apply
the checks (rate limit, quota, permission scope) because it assumes the external
boundary already did so.

**Trace:** find internal-dispatch / task-queue / job-enqueue call sites → trace what
checks were applied before the dispatch → verify that the receiving handler doesn't
need *additional* checks that aren't present.

**Watch for:**
- Worker queues that process jobs enqueued without a secondary permission re-check
- Internal RPC endpoints reachable via message bus (Kafka, SQS, Redis Pub/Sub) without
  authz because they're "internal" — but the message bus is writable by other services
- Batch pipelines where the per-item handler trusts that the batch-level caller
  already validated each item
