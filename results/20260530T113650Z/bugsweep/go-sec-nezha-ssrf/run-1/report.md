# bugsweep report — 20260530-113707
**Branch:** bugsweep/20260530-113707   **Mode:** detect-only (no fixes, no commits)   **Iterations:** 7 (one hunt pass per batch)
**Stack:** Go 1.26 · Gin · GORM (sqlite) · gRPC · gorilla/WebSocket · OAuth2/JWT
**Baseline checks:** test=fail, typecheck=fail, build=fail (pre-existing; not introduced by this run — no code was changed)
**Final checks:** unchanged (detect-only; working tree untouched)

## Summary
- Confirmed bugs: 26 (critical 1, high 6, medium 8, low 11); architectural: 11
- Fixed & verified: 0 (detect-only — no code changes, no commits)
- Needs human / lower-confidence: 7 (listed separately)
- Coverage: 7/7 batches; reviewed via Hunter -> Skeptic -> Referee. The Referee independently
  re-read the cited code for every CRITICAL/HIGH and most MEDIUM findings.

Root themes: (1) `class.CheckPermission` treats an **empty or unknown id list as authorized**,
which combines with cron "cover" semantics to give cross-tenant RCE; (2) several outbound and
agent-trust paths take untrusted URLs/IDs with no validation (SSRF, cross-user task triggers);
(3) `model.Server` runtime fields and several `service/singleton` maps are mutated outside their
locks, producing data races and **fatal concurrent-map-write crashes**; (4) client IP used for
WAF/auth brute-force protection is spoofable because trusted proxies are never configured.

## Fixed
(none — detect-only run)

## Confirmed but not fixed (detect-only)

### CRITICAL
- BUG-C1 · critical · architectural · `cmd/dashboard/controller/cron.go:53,65,179` +
  `service/singleton/crontask.go:160-172` + `service/singleton/singleton.go:249-261` ·
  **Cross-tenant remote command execution.** Any logged-in non-admin creates a cron with
  `cover = CronCoverAll` (=1, "ignore specific servers") and `servers = []`. `CheckPermission`
  returns `true` for an empty id list, so the create is authorized. `manualTriggerCron` only
  checks the caller owns the *cron row* (which they do), then `CronTrigger` iterates
  `ServerShared.Range` and, because the ignore-map is empty, sends `TaskTypeCommand` with the
  attacker's command to **every connected agent** — including servers owned by other users/admins.
  Trigger: `POST /api/v1/cron {cover:1,servers:[],command:"...",scheduler:"* * * * *"}` then
  `GET /api/v1/cron/{id}/manual`.

### HIGH
- BUG-C2 · high · architectural · `cmd/dashboard/controller/alertrule.go:60-61,114-115`,
  `cmd/dashboard/controller/service.go:427-429,492-493` + `service/singleton/crontask.go:113-127` ·
  **Cross-user task triggering (IDOR).** `FailTriggerTasks`/`RecoverTriggerTasks` cron IDs are
  copied from the request body with no ownership validation; `SendTriggerTasks` looks each up with
  no owner filter and executes it. A user references another user's trigger-task cron (or, via C1,
  an empty-server task) and fires it from their own alert rule / service monitor.
- BUG-C3 · high · architectural · `model/notification.go:132,152-153` (sink),
  `cmd/dashboard/controller/notification.go` (route `commonHandler`) · **SSRF via user-defined
  notification URL.** The URL is fetched server-side with no host allow-list and no block of
  loopback/private/link-local/cloud-metadata addresses; on a non-2xx response the upstream body is
  reflected back in the API error, enabling data exfiltration (e.g. `http://169.254.169.254/...`).
- BUG-C4 · high · architectural · `pkg/ddns/webhook/webhook.go:64,92,117-136` +
  `service/singleton/server.go:92-106` + `service/rpc/nezha.go:273-281` · **Blind SSRF via DDNS
  webhook URL,** additionally triggerable by agent-reported IP-change events. No SSRF guard exists
  anywhere in the outbound HTTP path.
- BUG-C5 · high · local/architectural · `service/rpc/nezha.go:115-116,158-160,188-192` (writes);
  reads in `model/rule.go:67-137`, `service/singleton/singleton.go:113-123`,
  `cmd/dashboard/rpc/rpc.go` · **Data race on shared `*model.Server` fields.** The gRPC report
  goroutine writes `State`/`Host`/`LastActive`/`PrevTransfer*Snapshot` on the shared pointer with
  no lock (`model.Server` has no mutex; `listMu` only guards the map). `PrevTransferInSnapshot` is
  written by both the gRPC path and the hourly-transfer cron → lost updates + torn reads → wrong
  alerts and corrupted transfer accounting. Flagged by `go test -race`.
- BUG-C6 · high · local · `service/singleton/servicesentinel.go:386-419,421-423` · **Fatal
  concurrent map read/write.** `LoadStats()` returns the live `monthlyStatus` map after all three
  deferred unlocks fire; `CopyStats()` then `copier.Copy`-iterates it with no lock held while
  `worker()` mutates the same map → unrecoverable `concurrent map read and map write` (process
  crash). Reachable by hitting the public `/api/v1/service` page under load.
- BUG-C7 · high · architectural · `cmd/dashboard/controller/waf/waf.go:25,30`,
  `cmd/dashboard/controller/controller.go:31` (no `SetTrustedProxies`), `model/waf.go` CheckIP/BlockIP,
  `service/rpc/nezha.go`/`cmd/dashboard/rpc/rpc.go:59-67`, `jwt.go:107,131` · **Spoofable client IP
  for WAF/auth brute-force protection.** Trusted proxies are never configured, so both the
  `WebRealIPHeader` path (`Header.Get` read verbatim) and the peer-IP path (`c.RemoteIP()` honors
  XFF under Gin's trust-all default) are attacker-controlled. Enables login/oauth brute-force block
  *evasion* and *poisoning* (block an arbitrary victim or the admin's own IP → DoS). The same
  spoofable value backs the JWT `ip` claim binding.

### MEDIUM
- BUG-C8 · medium · local · `service/singleton/servicesentinel.go:649-662` vs `:375` · `tlsCertCache`
  is read/written in `worker()` **after** `serviceResponseDataStoreLock.Unlock()` (line 625) while
  `Delete()` writes it under that lock → fatal concurrent map write (process crash).
- BUG-C9 · medium · architectural · `cron.go:64,130`, `alertrule.go:62,116`, `service.go:421,485` ·
  `NotificationGroupID` is set from the request body with no ownership check → a user routes alerts
  through, and mutates the mute-cache of, another user's notification group.
- BUG-C10 · medium · local · `service/singleton/online_user.go:53-59` +
  `cmd/dashboard/controller/user.go:200-208` · Pagination `limit`/`offset` are unbounded ints;
  `offset+limit` overflows negative, defeating the guard, then `users[offset:offset+limit]` panics
  (handled 500 via gin.Recovery, but a trivial per-request DoS).
- BUG-C11 · medium · local · `service/singleton/server.go:63-72` · `ServerClass.Delete` does
  `c.list[id].UUID` with no existence check **and** does not `defer` the `Unlock`; a missing or
  duplicated id panics on nil deref AND leaves `listMu` permanently locked → deadlocks all server
  operations. (Sibling `NATClass`/`CronClass` Delete guard with `ok`.)
- BUG-C12 · medium · architectural · `cmd/dashboard/main.go:50-62` + `model/user.go:17-20` ·
  First-boot seeds user `admin` with password `"admin"` and Role zero-value (`RoleAdmin`), with no
  forced change, randomization, or warning → admin/admin until a human intervenes (admin can open a
  terminal/file bridge to every agent = RCE). May be intended onboarding behavior — flagged for a human.
- BUG-C13 · medium · local · `model/rule.go` (GetTransferDurationStart/End cycle math) · Transfer-cycle
  alert rules loaded from the DB with `CycleInterval == 0` or nil `CycleStart` cause divide-by-zero /
  nil-deref panics in `CleanMonitorHistory`/`AlertSentinel` (those paths run on persisted rows; only
  the create/update API validates). Crashes a background goroutine.
- BUG-C14 · medium · local · `service/rpc/nezha.go:47-48` · `RequestTask` does
  `server, _ := ServerShared.Get(clientID)` then `server.TaskStream = stream`, ignoring `ok`; a
  concurrent server delete makes `server` nil → panic in the gRPC handler (no recovery interceptor
  is registered → process crash). Other report handlers guard `!ok || server == nil`; this one does not.
- BUG-C15 · medium · local · `service/singleton/servicesentinel.go:610-614,708-744` · `delayCheck`/
  `notifyCheck` dereference `m[r.Reporter]` from a cloned map with no existence check; a server
  deleted while an in-flight ping report is processed → nil deref crashes the sentinel worker,
  stopping all subsequent monitoring/alerting.

### LOW
- BUG-C16 · low · local · `model/rule.go:82` · `net_all_speed` computes `NetOutSpeed + NetOutSpeed`
  (doubles outbound, ignores inbound) → false-negative/false-positive alerts. (Cf. correct
  `transfer_all` at line 88.)
- BUG-C17 · low · local · `service/rpc/nezha.go:220` · IOStream magic-number guard
  `(d[0]!=0xff && d[1]!=0x05 && d[2]!=0xff && d[3]==0x05)` mixes `&&` with mismatched `!=`/`==`,
  so it effectively never rejects; intended check is `d[0]!=0xff || d[1]!=0x05 || d[2]!=0xff || d[3]!=0x05`.
  Defense-in-depth only (GetStream is the real gate).
- BUG-C18 · low/med · architectural · `cmd/dashboard/controller/terminal.go:73-78`, `fm.go`,
  `service/rpc/io_stream.go:13-20`, `nezha.go:210-242` · terminal/file-manager WS connect
  (`terminalStream`/`fmStream`) and the gRPC `IOStream` agent side never re-check ownership; the
  session context stores no owner. Mitigated by a single-use crypto-random UUID streamId with a
  ~10s window, so exploitation needs a streamId leak. Defense-in-depth gap with RCE blast radius.
- BUG-C19 · low · local · `cmd/dashboard/controller/server.go:179-194` · `forceUpdateServer` nests
  the `HasPermission` check inside `server.TaskStream != nil`, so offline/non-existent servers skip
  it → online/offline + existence oracle for servers you don't own.
- BUG-C20 · low · local · `service/singleton/server.go:56` · `log.Printf("...server %d: %v", err, s.ID)`
  — args swapped (err in `%d`, id in `%v`); garbles DDNS-failure logs.
- BUG-C21 · low/med · local · `model/notification.go:116-120` · Notification delivery uses
  `HttpClientSkipTlsVerify` (cert verification OFF) unless `VerifyTLS` is explicitly true; the
  insecure path is the default → MITM of notifications (which may carry secrets in headers/body).
- BUG-C22 · low · local · `pkg/utils/http.go:9-49` · Shared outbound clients set only a 10-minute
  overall timeout (no dial/TLS-handshake/response-header timeouts) and expose a default-insecure
  `HttpClientSkipTlsVerify`; a slow webhook ties up a goroutine/connection for up to 10 minutes.
- BUG-C23 · low · local · `cmd/dashboard/controller/server.go:325-369` · `batchMoveServer` (non-admin)
  lets a user reassign their own servers to any other user, and writes `s.UserID` inside a
  `ServerShared.Range` body that holds only an RLock (race).
- BUG-C24 · low · local · `pkg/ddns/webhook/webhook.go:146,162-175` · DDNS webhook JSON body is built
  by raw `strings.Replace` with no JSON escaping; unescaped secret/domain values can corrupt or
  inject into the outbound JSON (contrast notification.go which marshals each value).
- BUG-C25 · low · local · `service/rpc/nezha.go:224-232` · IOStream keepalive goroutine has no
  cancellation; it survives stream teardown until the next 30s `Send` fails → goroutine leak a hostile
  agent can amplify.
- BUG-C26 · low · local · `service/rpc/io_stream.go:140-164` · `StartStream`'s named return `err` is
  written by both copy goroutines with no synchronization, and `<-endCh` returns while the second
  goroutine still uses its pooled 1 MiB buffer (race / potential cross-session buffer reuse).

## Quarantined / needs human (lower confidence or judgment call)
- BUG-Q1 · medium · `service/singleton/singleton.go:253-260` + `batchDeleteCron/Notification/DDNS` ·
  `CheckPermission` passing unknown ids, combined with batch-delete `DB.Delete("id in (?)")` that has
  no `user_id` predicate, is a potential ownership-bypass for ids transiently absent from the
  in-memory list. Needs confirmation that every such row is always present in the singleton cache.
- BUG-Q2 · medium · `cmd/dashboard/controller/oauth2.go:159-171` · OAuth2 bind reassigns
  `bind.UserID` for an existing `(provider, open_id)` without checking current ownership/uniqueness;
  precondition is controlling the provider identity, so practical impact is account-binding
  confusion. Verify the `oauth2_binds` unique index covers `(provider, open_id)`.
- BUG-Q3 · low · `cmd/dashboard/controller/oauth2.go:218-237` · OAuth2 `state` is never deleted after
  use (replayable within the cache TTL); mostly mitigated by single-use provider `code`.
- BUG-Q4 · low/med · `cmd/dashboard/controller/oauth2.go:22-29` · `redirect_uri` derived from
  `Host`/`X-Forwarded-Proto`; impact depends on the provider's redirect_uri strictness.
- BUG-Q5 · low · `cmd/dashboard/controller/oauth2.go:175-184` + `service/singleton/user.go OnUserDelete` ·
  `Oauth2Bind` rows are not deleted when a user is deleted → orphaned bindings; login mint is largely
  mitigated by per-request DB re-validation in `identityHandler`.
- BUG-Q6 · low · `service/rpc/auth.go:39-48` · Agent shared-secret matched via a plain map lookup
  (not constant-time) with asymmetric work on hit vs miss → timing oracle; severity compounded by
  spoofable IP block accounting (C7).
- BUG-Q7 · low · `service/rpc/nezha.go:273-281` · Agent-controlled GeoIP drives DDNS record updates
  and IP-change notifications with no validation or rate limit → a compromised agent can hijack the
  user's DNS records / spam notifications.

## How to review
git diff bench-base..bugsweep/20260530-113707   # (no code changes in this detect-only run)
Artifacts: .bugsweep/run-20260530-113707/{repo-context.md,recon.json,antipatterns.md,ledger.jsonl,report.md}