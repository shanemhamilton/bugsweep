# bugsweep report — 20260529-202534
**Branch:** bugsweep/20260529-202534   **Mode:** detect-only (no code changes, no commits)   **Iterations:** 1
**Stack:** Go (Gin HTTP API + gRPC agent server, gorm, robfig/cron, appleboy/gin-jwt)   **Baseline checks:** test/typecheck/build all reported FAIL in this sandbox (no network/deps; not used since detect-only makes no edits)   **Final checks:** unchanged (no edits)

## Summary
- Confirmed bugs: 22 (critical 1, high 5, medium 7, low 9); architectural: 8
- Fixed & verified: 0 (detect-only)   Quarantined (needs human): 0
- Coverage: 6/6 batches; reviewed via Hunter -> Skeptic -> Referee (referee re-read code; downgraded the parallel "service" authz finding after confirming a dispatch-time ownership re-gate, and marked one nil-deref claim DISPUTED)
- 1 disputed claim retained for human review (CopyStats nil-deref); 1 design-intent question (cross-tenant notification-group/trigger-task linkage)

## Fixed
(none — detect-only)

## Quarantined / needs human
(none — detect-only makes no changes; all confirmed bugs are listed below for human action)

## Confirmed but not fixed (detect-only)

### CRITICAL
- **BUG-01 · critical · architectural · cmd/dashboard/controller/cron.go:53,111 + service/singleton/crontask.go:160-179 + service/singleton/singleton.go:249**
  Cron authorization bypass → arbitrary command execution on every agent.
  `createCron`/`updateCron`/`manualTriggerCron` are registered with `commonHandler` (controller.go:132-134), so any authenticated **RoleMember** can call them. They authorize servers via `singleton.ServerShared.CheckPermission(c, slices.Values(cf.Servers))`. But `CheckPermission` (singleton.go:249) returns `true` for an empty list and silently skips ids not in its map, and `CronTrigger` (crontask.go:161-164) treats `Servers` as an **ignore list** when `Cover == CronCoverAll (1)` — the command runs on the *complement* of `Servers`. So a member submits `Cover=1, Servers=[]` (or only their own server in the ignore list), passes the permission check, and the scheduled/manually-triggered command is delivered to **all** servers, including admin- and other-user-owned agents. Unlike service-probe dispatch (rpc.go:96,106 gated by `canSendTaskToServer`, rpc.go:189: `task.UserID==server.UserID || isAdmin`), `CronTrigger` calls `s.TaskStream.Send(&pb.Task{Data: cr.Command, Type: TaskTypeCommand})` **directly with no ownership re-gate** — so the escalation is unmitigated. Net effect: low-privileged member → RCE on the entire fleet.

### HIGH
- **BUG-02 · high · architectural · service/singleton/servicesentinel.go:386-392 (vs 324-330, 364-370)**
  Lock-order inversion deadlock. The file documents the required order at line 64: `serviceResponseDataStoreLock > monthlyStatusLock > servicesLock`. `Update`/`Delete` follow it; `LoadStats` acquires `servicesLock.RLock` FIRST, then `serviceResponseDataStoreLock.RLock` — inverted (AB–BA). `LoadStats` is reachable from the **public** `optionalAuth GET /service` (controller `showService` → `CopyStats` → `LoadStats`, service.go:32) and the daily refresh cron (servicesentinel.go:135); `Update`/`Delete` from `commonHandler` service create/update/delete. A public GET racing any service write permanently deadlocks the service-monitoring subsystem and the service page.
- **BUG-03 · high · local · model/rule.go:82**
  `net_all_speed` alert evaluates `NetOutSpeed + NetOutSpeed` instead of `NetInSpeed + NetOutSpeed` (the adjacent `transfer_all` at :88 proves intended semantics). Aggregate-bandwidth alerts silently ignore inbound traffic — a host saturating its inbound link never trips the threshold; outbound trips at half the configured value. Silent monitoring failure.
- **BUG-04 · high · local · model/rule.go:70,136**
  `slices.Max` panics on an empty slice. `gpu_max` (`slices.Max(server.State.GPU)`, :70) gets an empty `GPU` slice for every no-GPU host (the common case); `temperature_max` (:136) gets an empty `temp` when all reported temperatures are 0 (filtered at :132). `GPU`/`Temperatures` come from agent gRPC reports (model/host.go PB2State). An admin-created `gpu_max`/`temperature_max` rule applied to such a host panics the alert-sentinel goroutine, halting all alert processing.
- **BUG-05 · high · architectural · service/singleton/notification.go:101-109 (vs 163-167)**
  Lock-order inversion deadlock. `UpdateGroup` takes `groupMu.Lock` then `listMu.Lock`; `DeleteGroup` takes `listMu.Lock` then `groupMu.Lock` — inverted. Concurrent notification-group update + delete (admin HTTP endpoints) deadlocks, freezing all notification dispatch (`SendNotification` reads `listMu`).

- **BUG-20 · high · architectural · service/rpc/nezha.go:57-76**
  `RequestTask` trusts an agent-supplied cron ID. After authenticating the agent to `clientID` (:43), the `TaskTypeCommand` branch does `cr, _ := singleton.CronShared.Get(result.GetId())` (:59) where `result.GetId()` comes straight off the wire (`stream.Recv()`, :51). It never verifies the cron targets the reporting server or shares its owner. For any existing cron ID, it sends a notification to `cr.NotificationGroupID` containing the attacker-controlled `result.GetData()` (:65-70) and writes `LastExecutedAt`/`LastResult` to that cron's DB row (:72-75). Any single authenticated agent can therefore spoof ta[REDACTED] results for any cron in the system (cross-tenant notification injection) and corrupt other users' cron integrity fields.

### MEDIUM
- **BUG-06 · medium · local · service/singleton/servicesentinel.go:418,423**
  Concurrent map read/write. `LoadStats` returns the **live** `ss.monthlyStatus` map and its deferred unlocks fire on return; `CopyStats` then iterates it (via `copier.Copy(&stats, ss.LoadStats())`, :423) with no lock held. Concurrent writers (`Update`/`Delete`, `refreshMonthlyServiceStatus`) mutate `monthlyStatus` → Go fatal "concurrent map iteration and map write" crashing the process. Reachable from the public `GET /service`.
- **BUG-07 · medium · architectural · cmd/dashboard/controller/oauth2.go:159-174**
  OAuth2 bind reassigns an already-bound identity. The bind lookup is scoped only by `provider + open_id` (not the current user), then unconditionally sets `bind.UserID = user.ID` and `Save`s, with no "already bound to a different account" conflict check. The `if result.Error == gorm.ErrRecordNotFound { Create }` branch is dead because `Find` never returns `ErrRecordNotFound`. Impact: OAuth binding theft / login denial for the victim; account takeover where the IdP reuses the identifier returned by `UserIDPath`.
- **BUG-08 · medium · local · pkg/ddns/webhook/webhook.go:64**
  HTTP response body leak. `utils.HttpClient.Do(req)` discards the `*http.Response` with `_`, so `resp.Body` is never closed. With the shared keep-alive transport (pkg/utils/http.go:44), each DDNS webhook update (looped over domains × `MaxRetries`) leaks a connection/FD and prevents connection reuse; grows unbounded on a long-running dashboard.
- **BUG-09 · medium · local · model/ddns.go:51-53**
  `DDNSProfile.AfterFind` returns `json.Unmarshal([]byte(d.DomainsRaw), &d.Domains)` with no empty-string guard and no `gorm:"default:'[]'"` tag on `DomainsRaw` (unlike `Server.DDNSProfilesRaw` at server.go:24 and `Service.AfterFind` which pre-inits). An empty `domains_raw` (legacy/manual rows) makes `json.Unmarshal` fail with "unexpected end of JSON input", so the profile row is unloadable and the error propagates to any controller querying DDNS profiles.
- **BUG-10 · medium · architectural · cmd/dashboard/rpc/rpc.go:24-29**
  gRPC server registers only `ChainUnaryInterceptor(getRealIp, waf)` — no stream interceptor — so streaming RPCs (`RequestTask`, `IOStream`) bypass the WAF IP-blocklist entirely. No `grpc.Creds(...)` is set; agent traffic on the primary listener is cleartext H2C unless TLS is terminated by an external proxy.

- **BUG-21 · medium · local · service/rpc/nezha.go:47-48**
  `server, _ := singleton.ServerShared.Get(clientID)` discards `ok`, then immediately writes `server.TaskStream = stream` — unlike the sibling methods `ReportSystemState` (:110-113) and `onReportSystemInfo` (:176-179) which guard `if !ok || server == nil`. (a) If `clientID` is absent at that instant (race against a server delete/reload) `server` is nil and the assignment panics, killing the gRPC handler goroutine. (b) The write to the shared `TaskStream` pointer holds no lock while `CronTrigger` (crontask.go:144,167) and `createTerminal` (terminal.go:34,52) read/use it concurrently — an unconditional data race on every agent reconnect.
- **BUG-22 · medium · local · service/rpc/io_stream.go:106-125**
  `StartStream`'s timeout is non-functional → goroutine + `ioStreams` leak. `timeoutTimer` (:106) is created but `timeoutTimer.C` is never selected; the only timeout case is a fresh `time.After(timeout)` reconstructed each loop iteration (:121). The connect channels are *closed* via `sync.Once` (:79-81,:93-95), so in the half-open state (exactly one side connects) that closed-channel case is ready every iteration, the inner guard fails, `time.Sleep(500ms)` runs, and the loop repeats with a new `time.After` that never accumulates to `timeout`. The 10s timeout callers rely on (terminal.go, fm.go, rpc.go:176) never fires, so an agent that receives a terminal/fm/NAT task but never calls back `IOStream` makes `StartStream` spin forever, leaking a goroutine and a stream-map entry per session (DoS / resource exhaustion).

### LOW
- **BUG-11 · low · architectural · cmd/dashboard/controller/service.go:543-549**
  `validateServers` checks permission only on `maps.Keys(ss.SkipServers)` (the *excluded* set). With `Cover=ServiceCoverAll(0)` and empty `SkipServers`, a member's service nominally covers all servers (same inverted-set mistake as BUG-01). **Mitigated** at dispatch by `canSendTaskToServer` (rpc.go:189), which re-gates each probe by `task.UserID==server.UserID || isAdmin`, so a member cannot actually enlist non-owned agents. Residual: defense-in-depth gap and inconsistency with the unmitigated cron path.
- **BUG-12 · low · local · cmd/dashboard/controller/user.go:136-142**
  `createUser` validates only `if uf.Role > model.RoleMember`. Since `RoleAdmin = 0` is the zero value, a request omitting `role` silently creates an **admin**. Endpoint is `adminHandler`-gated, so this is an operational footgun, not a cross-privilege escalation.
- **BUG-13 · low · architectural · cmd/dashboard/controller/terminal.go + fm.go (stream handlers) + service/rpc/io_stream.go:72-84**
  Terminal/FM WebSocket consume-side authorization relies solely on stream-UUID existence (`GetStream`), with no re-check that the connecting user created the stream; the stream context stores no owner. Creation is correctly `HasPermission`-gated and the UUID is 122-bit random (no IDOR), so this is residual bearer-capability risk if a stream UUID leaks (proxy/access logs, Referer, history).
- **BUG-14 · low · local · cmd/dashboard/controller/server.go:179-195**
  `forceUpdateServer` performs `server.HasPermission(c)` only inside the `server != nil && server.TaskStream != nil` (online) branch. A member passing IDs of offline/nonexistent servers they don't own skips the permission check and the IDs are bucketed into `Offline` — cross-tenant existence/online-state enumeration (no state change on foreign servers).
- **BUG-15 · low · local · service/rpc/nezha.go:220**
  IOStream magic-number validation is logically broken: `(id.Data[0]!=0xff && id.Data[1]!=0x05 && id.Data[2]!=0xff && id.Data[3]==0x05)`. The correct check is `||` with `id.Data[3]!=0x05`; as written it rejects almost no malformed prefix. Low impact: the agent is already authenticated (`Auth.Check`, :211) and `streamId` must still match an existing pending stream.
- **BUG-16 · low · local · service/rpc/io_stream.go:78,92,143-164**
  Data races in IO-stream plumbing: `stream.userIo`/`stream.agentIo` are written in `UserConnected`/`AgentConnected` without holding `ioStreamMutex` and read in `StartStream`; the shared `err` variable is written by both `io.CopyBuffer` goroutines (:145,:156) and read at :164 without synchronization.
- **BUG-17 · low · local · pkg/tsdb/query.go:198,214**
  Daily-bucket index uses `(days-1) - int(today.Sub(ts).Hours())/24`, bucketing by rolling 24-hour windows from `today`'s wall-clock instant rather than calendar days. Points near a day boundary are misattributed, skewing per-day uptime and average-delay statistics by up to a full day depending on the time `today` is passed.
- **BUG-18 · low · local · cmd/dashboard/rpc/rpc.go:39-76**
  When `AgentRealIPHeader` is configured, `getRealIp` trusts the agent-supplied header value as the real IP (used by the `waf`/`CheckIP` decision) with no cross-check against the connecting IP, letting an agent spoof its IP to evade the block list. Operator-config dependent.
- **BUG-19 · low · local · model/notification.go:313-315**
  Memory/Swap/Disk percentage formatting divides by agent-reported totals with no zero-guard (unlike the `percentage()` helper at rule.go:41). Swapless hosts (`SwapTotal==0`) or pre-first-report hosts render `+Inf`/`NaN %` in notification messages.

## Disputed / design-intent (human judgement)
- **DISPUTED · service/singleton/servicesentinel.go:427** `CopyStats` dereferences `service.service.EnableShowInService`, but `serviceResponseItem.service` is an **unexported** field that `copier` (v0.4.0) cannot populate when copying `map[uint64]*serviceResponseItem`. This would nil-deref panic *if* copier leaves `service` nil, or silently return empty stats *if* copier leaves `stats` nil. Could not be empirically confirmed (no buildable sandbox), and this is a public, hot endpoint in a working project — so the runtime behavior is uncertain. Flagged for human verification; the confirmed concurrency defect in the same function is BUG-06.
- **DESIGN-INTENT · cron.go:64, service.go:421, alertrule.go:62 (NotificationGroupID); service.go:428-429, alertrule.go:60-61 (FailTriggerTasks/RecoverTriggerTasks)** Create/update handlers copy `NotificationGroupID` and trigger-task ID lists straight from the request with no ownership validation, permitting a member to bind another user's notification group / trigger tasks. This is consistent across all such handlers, so it may be an intentional shared-resource model; flagged for a maintainer decision rather than asserted as a bug.

## How to review
git diff bench-base..bugsweep/20260529-202534   # (empty — detect-only made no changes)