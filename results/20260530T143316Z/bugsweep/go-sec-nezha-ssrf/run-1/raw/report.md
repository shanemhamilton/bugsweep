# bugsweep report — 20260530-145752
**Branch:** bugsweep/20260530-145752   **Mode:** detect-only (no fixes, no commits)   **Iterations:** 1
**Stack:** Go 1.26 · Gin · GORM (sqlite/mysql/pg) · gRPC · WebSocket · koanf · robfig/cron
**Baseline checks:** test/typecheck/build all FAIL at baseline — environment has no deps/toolchain wired (go modules + tsc not installed); not a code regression. No checks were re-run since detect-only made no changes.
**Final checks:** n/a (no code modified)

## Summary
- Confirmed bugs: 30 (critical 2, high 8, medium 12, low 8); architectural: 5
- Fixed & verified: 0 (detect-only)   Quarantined (needs human): 0
- Coverage: 8/8 batches (106 Go files, whole repo); reviewed via Hunter -> Skeptic -> Referee
- Not-confirmed / dropped by adversarial review: 6 (see "Needs human / not confirmed")

## Fixed
*(none — detect-only run; no code was changed and nothing was committed)*

## Quarantined / needs human
*(none — no auto-fix attempted)*

## Confirmed but not fixed (detect-only)

### CRITICAL
- **B2-1 · critical · architectural · cmd/dashboard/controller/alertrule.go:60-61,114-115 (also service.go:428-429,492-493)** — Cross-tenant command execution. `createAlertRule/updateAlertRule` (and service create/update), all on `commonHandler` (non-admin), copy `FailTriggerTasks`/`RecoverTriggerTasks` (cron task IDs) from the request with **no ownership check**. `validateRule` only checks `rule.Ignore` server perms + duration. On fire, `alertsentinel.go:170/180 → CronShared.SendTriggerTasks → crontask.go:113-127` resolves the task by ID from the **global** cron map with no UserID filter, and `CronTrigger` dispatches the cron's `Command` to agents. A low-priv user A references a trigger-type cron owned by B/admin and triggers B's arbitrary shell command on B's (or, with `CronCoverAll`, all) servers.
- **B6-1 · critical · service/singleton/servicesentinel.go:649-661 (vs Delete :375)** — Concurrent map read/write → fatal crash. The single `worker` reads/writes `ss.tlsCertCache` **after releasing** `serviceResponseDataStoreLock` at :625 (no lock held), while `ServiceSentinel.Delete` writes/deletes `tlsCertCache[id]` under lock. An agent TLS report processed while an admin deletes a service triggers Go's `fatal error: concurrent map read and map write`, taking down the whole dashboard.

### HIGH
- **B1-1 · high · cmd/dashboard/controller/oauth2.go:159-171** — OAuth2 binding takeover. The "already bound?" check uses `DB.Where(...).Limit(1).Find(&bind)`; GORM `Find` never returns `ErrRecordNotFound`, so the `== gorm.ErrRecordNotFound` create branch is **dead** and the code always runs `bind.UserID = user.ID; DB.Save(&bind)`. When a row for `(provider, openId)` already exists (owned by user A), `Find` loads it incl. its primary key, then UserID is reassigned to the current user B and `Save` rewrites it → B steals A's OAuth identity; subsequent OAuth login as that identity authenticates as B.
- **B3-1 (=B4-4) · high · cmd/dashboard/controller/terminal.go:73-106, fm.go:73-106, service/rpc/io_stream.go:13-20** — Terminal/FM stream attach has no ownership check. `createTerminal/createFM` gate on `server.HasPermission`, but `terminalStream/fmStream` only call `GetStream(streamId)`; `ioStreamContext` carries no owner/UserID. Any authenticated user who obtains a stream UUID (leaked via logs/referrer, or the ~10s connect window) attaches to another tenant's shell / file-manager session (RCE/file access). Severity high (not critical) because the UUID is random 128-bit and returned only to the creator.
- **B4-2 · high · service/rpc/io_stream.go:140-164** — Pooled-buffer use-after-return. `StartStream` runs two `io.CopyBuffer` goroutines, each borrowing a 1 MB buffer from a shared `sync.Pool` with `defer bufPool.Put`. It returns on `<-endCh` when the **first** direction finishes, while the other goroutine still reads/writes its buffer; that buffer (and the finished one) returns to the pool and can be `Get`-reused by another session mid-copy → cross-session data corruption/leakage between unrelated terminal/FM/NAT streams.
- **B4-5 · high · service/rpc/nezha.go:47-48** — Nil-pointer deref in `RequestTask`. `server, _ := singleton.ServerShared.Get(clientID)` ignores `ok`, then `server.TaskStream = stream`. Sibling handlers (`:110-113`, `:176-179`) guard `!ok`, but this one doesn't; if the server is deleted in the race window after auth, this panics the RPC goroutine.
- **B4-6 · high · architectural · service/rpc/nezha.go (RequestTask/ReportSystemState/onReportSystemInfo/ReportGeoIP)** — Unsynchronized shared-state mutation. Agent handlers write `server.TaskStream/State/Host/GeoIP/PrevTransfer*` on the shared `*model.Server` with **no per-server lock** (`model.Server` has none), while `DispatchTask`/`DispatchKeepalive` and HTTP read the same fields. Data race → torn/stale reads, corrupted transfer accounting, send on a swapped stream.
- **B6-2 · high · service/singleton/servicesentinel.go:610,635,642,646** — Nil deref after concurrent service delete. `cs, _ := ss.Get(mh.GetId())` ignores `ok`; if the service is deleted between the early check (:479) and here, `cs` is nil and `cs.Notify`/`cs.NotificationGroupID` panic the worker.
- **B6-3 · high · service/singleton/servicesentinel.go:543-563** — Nil map-value deref after concurrent delete. Between the early check and acquiring the lock at :543, `Delete` removes `serviceStatusToday[id]`/`serviceCurrentStatusData[id]` (pointer values); `:546`/`:555` then deref the nil pointers → panic.
- **B7-5 · high · model/rule.go:70,136** — `slices.Max` panic on empty slice crashes AlertSentinel. `gpu_max` does `slices.Max(server.State.GPU)` with no length guard (GPU is agent-reported, can be empty); `temperature_max` calls `slices.Max(temp)` where `temp` is empty when all reported temps are 0. `validateRule` does not constrain this. An agent reporting empty GPU/zero temps while such a rule exists panics the 3s alert ticker (DoS).

### MEDIUM
- **B2-2 · medium · architectural · alertrule.go:62,116 / cron.go:64,130 / service.go:421,485** — Cross-tenant `NotificationGroupID`. Bound from request with no ownership/existence check (unlike notification-group endpoints which validate member IDs). A user routes their alert/cron/service notifications through another tenant's group → abuses that tenant's webhooks/endpoints and injects attacker-controlled event text into their channels.
- **B5-1 · medium · model/notification.go:113-143 (+ controller/notification.go create/update)** — SSRF. Non-admin–creatable notifications fetch the user-controlled `URL` with **no host/scheme allowlist**; a test send fires on create/update (unless `SkipCheck`). Lets any low-priv user reach `169.254.169.254`/internal services from the dashboard.
- **B5-2 · medium · model/notification.go:116-120 (pkg/utils/http.go)** — TLS verification off by default. `if VerifyTLS != nil && *VerifyTLS { HttpClient } else { HttpClientSkipTlsVerify }`, and `HttpClientSkipTlsVerify` sets `InsecureSkipVerify: true`. Omitting/false `verify_tls` (the default) disables cert validation → MITM of notification delivery (which can carry API tokens in headers).
- **B5-3 · medium · pkg/ddns/webhook/webhook.go:49-136** — SSRF via DDNS webhook. Non-admin `createDDNS/updateDDNS` store a user `WebhookURL` that is later requested with no allowlist; fires on DDNS update cycle.
- **B5-6 · medium · pkg/utils/http.go** — Both shared clients set **no `CheckRedirect`** (follow up to 10 redirects) and only a coarse 10-minute timeout. Amplifies B5-1/B5-3: an allowed host can 302 to an internal/metadata address; enables long-lived outbound connections.
- **B6-4 · medium · service/singleton/servicesentinel.go:708-750** — Nil deref on reporter server. `reporterServer := m[r.Reporter]` then `.Name`/`.ID` with no presence check; if the reporting server was deleted (or unknown), the snapshot lookup is nil → panic during latency/status notification.
- **B6-5 · medium · architectural · service/singleton/crontask.go:113-127,145,168** — Concurrent `Send` on one gRPC stream. `SendTriggerTasks` spawns `go CronTrigger(...)` per task, each calling `s.TaskStream.Send`; gRPC server-stream `SendMsg` is **not** safe for concurrent use. Overlapping triggers/terminal commands to the same agent corrupt framing / panic.
- **B6-6 · medium · service/singleton/crontask.go:160-179 (singleton.go Range :238)** — Blocking network I/O under `listMu` RLock. `ServerShared.Range` holds the RLock for the whole loop while `TaskStream.Send` (blocking) runs inside it; one slow agent stalls all `Update`/`Delete` that need `listMu.Lock`.
- **B6-7 · medium · service/singleton/server.go:67** — Nil deref in `ServerClass.Delete`. `serverUUID := c.list[id].UUID` has no `ok` check; a double-delete / stale id (e.g. admin batch-delete racing `OnUserDelete`) dereferences a nil `*model.Server` → process crash.
- **B7-6 · medium · model/rule.go:82** — `net_all_speed` logic bug: `NetOutSpeed + NetOutSpeed` double-counts egress and ignores `NetInSpeed` (correct pattern at :88). Every such alert evaluates the wrong metric.
- **B7-7 · medium · model/rule.go:142** — `seconds := max(1800*((u.Max-src)/u.Max), 180)` with a transfer-cycle rule that sets only `Min` (`Max==0`, unvalidated) yields `±Inf`/`NaN`; `max(NaN,180)=NaN` defeats the `NextTransferAt` throttle → the expensive cycle SUM query re-runs every 3s tick per server.
- **B8-1 · medium · pkg/utils/gin_writer_wrapper.go:18-20** — `WriteHeader(code)` ignores `code` and always writes `customCode`. Wrapping `http.ServeContent`/`ServeFile` (controller.go:302,317), this overrides legitimate 304/206/416 to 200 with an empty/partial body → broken conditional/range requests for static frontend assets.

### LOW
- **B1-2 · low · cmd/dashboard/controller/controller.go:148 / waf.go** — `GET /waf` is `pCommonHandler` (auth only); `listBlockedAddress` returns full `net.IP` with no desensitization/filter, while `listOnlineUser` desensitizes for non-admins and `batch-delete/waf` is admin-only. Any member reads the full blocked-IP list.
- **B1-3 · low · cmd/dashboard/controller/user.go:85** — `updateProfile` sets `user.Username = pf.NewUsername` with no empty-check (createUser rejects empty); `Username` is a uniqueIndex → self-inflicted empty/colliding username / lockout.
- **B3-3 · low · cmd/dashboard/controller/nat.go:56-60,104-108** — Permission check nested in `if _, ok := ServerShared.Get(ServerID); ok { ... }`; when `ok==false` the `HasPermission` check is skipped (fail-open). Bounded today (ServerShared preloaded), but structurally presence-gated, not ownership-gated.
- **B4-1 · low · service/rpc/nezha.go:220** — IOStream magic-number guard `(d[0]!=0xff && d[1]!=0x05 && d[2]!=0xff && d[3]==0x05)` uses `&&`/`==` so the rejection predicate is effectively always false — the validation is a no-op. Low impact (a valid `GetStream` UUID is still required).
- **B5-7 · low · model/notification.go:152** — Non-2xx path does `io.ReadAll(resp.Body)` with no `LimitReader`, then embeds/logs the body; a malicious notification target returns a huge body → memory/log-flood DoS.
- **B6-8 · low · service/singleton/servicesentinel.go:364-384** — `Delete` never removes `serviceResponsePing[id]` (populated :489-492) → unbounded map growth (memory leak) on ping-service create/delete churn.
- **B6-9 · low · service/singleton/server.go:56** — `log.Printf("...server %d: %v", err, s.ID)` — args swapped (`err`→`%d`); garbled DDNS-failure log (observability only).
- **B8-2 · low · pkg/tsdb/tsdb.go:26** — `int(config.MaxMemoryMB*1024*1024)` truncates on 32-bit builds when `MaxMemoryMB ≥ 2048` → wrong/negative cache sizes. 64-bit unaffected.

## Needs human / not confirmed (dropped or uncertain in adversarial review)
- **B7-1 / B7-2 / B7-3 / B7-4 — NOT reachable via API.** Div-by-zero (Duration==0), div-by-zero/infinite-loop (CycleInterval==0), and nil-deref (CycleStart==nil) in `model/rule.go`/`alertrule.go` are all blocked by `validateRule` (alertrule.go:177-189: Duration≥3, CycleInterval≥1, CycleStart required & not future). Only reachable by a hand-edited DB row — flag for defense-in-depth, not a live bug.
- **B5-4 — not exploitable.** `formatWebhookString` strips `\r` but not `\n`, but Go's `net/http` rejects bare `\n` in header values at write time and percent-escapes it in query values; no injection survives.
- **B4-8 — unproven.** Possible IOStream keepalive goroutine leak when the user side never attaches; could not prove the half-open stream persists (agent disconnect / `CloseStream` normally reclaims it). Needs runtime confirmation.
- **B3-2 / B4-3 — low, unrefereed.** Data race on a shared `err` variable between the keepalive goroutine and the main path in terminal.go/fm.go (:80/:90/:97) and io_stream.go (:144-157). Real under `-race`, low impact (wrong logged error); not independently adjudicated.
- **B4-7 — low, unrefereed.** `nezha.go:78` `if len(server.ConfigCache) < 1` then channel send is a check-then-act race; a misbehaving agent can wedge its RequestTask goroutine or deliver a stale config blob.
- **B8-3 — marginal.** `pkg/i18n` passes translated strings as printf formats; translations are embedded/trusted, so impact is limited to garbled output if a `.mo` verb mismatches.

## Notable areas checked and cleared (no bug)
- IDOR on update/delete/get of server, server-group, service, cron, notification, notification-group, alert-rule: each gates via `HasPermission`/`CheckPermission` before mutating. Create/update set `UserID = getUid(c)` server-side (no mass-assignment of UserID). `getUid`/`MustGet` is only used on `authMw` routes (optionalAuth handlers use the safe `c.Get`).
- Path traversal in `checkLocalFileOrFs`: request path is `path.Join`/`Clean`-normalized and Gin pre-normalizes `URL.Path`; no `..` escape.
- gRPC auto server-create double-create is prevented by the `UUID unique` constraint.
- TSDB `writer.go` buffered write/flush is correctly mutex-guarded; daily-stats day bucketing is internally consistent (today handled separately).

## How to review
git diff bench-base..bugsweep/20260530-145752   # (empty — detect-only made no changes)
Report: .bugsweep/run-20260530-145752/report.md
