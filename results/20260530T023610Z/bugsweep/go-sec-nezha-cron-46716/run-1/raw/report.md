# bugsweep report — 20260529-213648
**Branch:** bugsweep/20260529-213648   **Mode:** detect-only (no code changes, no commits)   **Iterations:** 1 (whole-repo, 3 batches)
**Stack:** Go 1.26 · gin · gorm · gRPC · robfig/cron/v3 · koanf   **Baseline checks:** RED — `go test ./...`, `tsc --noEmit`, `go build ./...` all failed (missing toolchain/deps in sandbox; see Caveats)   **Final checks:** n/a — detect-only makes no changes to verify

## Summary
- Confirmed bugs: 13 (critical 1, high 4, medium 5, low 3); architectural/cross-file: 4 (cron, service, alert-rule permission inversions + concurrent stream writes)
- Fixed & verified: 0 (detect-only)   Quarantined (needs human): 0
- Coverage: 3/3 batches (106 Go files in scope) reviewed via Hunter -> Skeptic -> Referee. Headline class = a repeated **deny-list permission inversion** across cron, service-monitor, and alert-rule creation.

## Fixed
_None — detect-only run; no code was modified and no commits were made._

## Quarantined / needs human
_None — detect-only run; nothing was auto-fixed, so nothing was quarantined._

## Confirmed but not fixed (detect-only)

### Authorization — the deny-list inversion family (same root cause, 3 endpoints)
The shared `class.CheckPermission(ctx, idList)` (`service/singleton/singleton.go:249`) only denies when an id is present in its in-memory map **and** the user lacks permission on it; ids absent from the set (or an empty set) pass vacuously. Three `commonHandler` (any authenticated, non-admin) endpoints feed it the **exclusion/ignore** set instead of the **effective target** set, so the check validates the wrong servers.

- **CRITICAL · authz bypass -> cross-tenant RCE · cmd/dashboard/controller/cron.go:53 (and :111)** · `createCron`/`updateCron` call `ServerShared.CheckPermission(c, cf.Servers)`. With `Cover == CronCoverAll` (=1, "ignore specified") the `Servers` list is a **deny-list**; `CronTrigger` (`service/singleton/crontask.go:160-166`) then runs `cr.Command` on every server in `ServerShared.Range` **not** in that list. A member sends `{TaskType:0, Cover:1, Servers:[], Command:"…"}` -> check over the empty set returns true -> the command is dispatched to **all** servers, including other users'/admin's agents. `manualTriggerCron` (cron.go:163) gives immediate execution because `cr.HasPermission` only checks cron ownership, not the targets. Arbitrary command execution across every monitored host by any authenticated low-privilege user. **Confidence: high.**

- **HIGH · authz bypass -> cross-tenant agent tasking / SSRF-via-agent · cmd/dashboard/controller/service.go:544** · `validateServers` checks only `ServerShared.CheckPermission(c, maps.Keys(ss.SkipServers))`. `ServiceCoverAll` (=0) makes `SkipServers` a deny-list; `DispatchTask` (`cmd/dashboard/rpc/rpc.go:100-110`) then sends the service task to every connected server not in `SkipServers`. A member POSTs `/service` with `cover:0`, empty `skip_servers`, and an attacker-chosen `Target`/`Type` -> the check passes vacuously -> **all** agents (including other tenants') probe the attacker's target and the member observes the results. Cross-tenant use of foreign agents as probe sources + disclosure of their reachability/latency. **Confidence: high.**

- **HIGH · authz bypass -> cross-tenant metric disclosure + trigger abuse · cmd/dashboard/controller/alertrule.go:172** · `validateRule` checks only `ServerShared.CheckPermission(c, maps.Keys(rule.Ignore))`. `RuleCoverAll` (=0) makes `rule.Ignore` a deny-list (`model/rule.go:51`: applies to every server **not** in `Ignore`). A member creates an alert rule with `cover:0` and empty `ignore` -> the rule monitors **all** servers, disclosing other users'/admin's metrics and firing the member's `FailTriggerTasks`/`RecoverTriggerTasks` on foreign server state. **Confidence: high.**

### Remote denial of service
- **HIGH · process-crash DoS · model/rule.go:69 (`gpu_max`) and :136 (`temperature_max`)** · `Rule.Snapshot` runs every ~3s for every rule×server in `service/singleton/alertsentinel.go:checkStatus` (line ~156), a loop with **no `recover()`**. `case "gpu_max": slices.Max(server.State.GPU)` panics on an empty slice (Go 1.21+), and `server.State.GPU` is empty for any host without a GPU (the common case). `temperature_max` panics the same way when all reported temperatures are 0. `rule.Type` is **never validated** in `validateRule`. Any authenticated user creates a `gpu_max` rule covering all servers; the first evaluation against a GPU-less host panics the alert-sentinel goroutine — an unrecovered panic in a goroutine terminates the whole dashboard process. **Confidence: high.**

### gRPC agent trust boundary
- **HIGH · tenant-isolation break · service/rpc/auth.go:59-74** · `Check` authenticates the *user* via `AgentSecretToUserId[clientSecret]` but, when the supplied `client_uuid` already maps to an existing server (`UUIDToID`, line 59), returns that server's `clientID` **without verifying `server.UserID == userId`**. A user holding any valid agent secret who presents another user's server UUID is connected *as* that server: it installs `server.TaskStream = stream` (`nezha.go:48`), reports `State`/`Host`/`GeoIP` for it, and receives the victim's dispatched tasks/commands. The only barrier is UUID secrecy; the ownership check is absent. **Confidence: high (defect unconditional; practical exploitation gated by 128-bit UUID discoverability).**

- **MEDIUM · data race / stream corruption · cmd/dashboard/rpc/rpc.go:97,107,121,154; service/singleton/crontask.go:145,168** · A single `server.TaskStream` (`pb.NezhaService_RequestTaskServer`) is written concurrently by independent goroutines — `DispatchKeepalive` (@every 20s), `DispatchTask`, `CronTrigger`, `ServeNAT`, and the terminal/fm HTTP handlers. gRPC forbids concurrent `SendMsg` on one stream; this races and can corrupt framing or crash. The write `server.TaskStream = stream` (`service/rpc/nezha.go:48`) is also unsynchronized against those reads. **Confidence: high (race exists); medium (observable corruption).**

- **MEDIUM · data race on shared server state · service/rpc/nezha.go:115-116,188-192 vs service/singleton/singleton.go:116-123** · `listMu` guards the server *map*, not the pointed-to `*model.Server`. `ReportSystemState`/`onReportSystemInfo` mutate `server.State`/`server.Host`/`PrevTransfer*` with no lock while `RecordTransferHourlyUsage` concurrently reads/writes the same fields from a cron goroutine. No per-server mutex exists. **Confidence: high (no guard); medium (corruption observability).**

- **MEDIUM · nil-deref panic on single worker · service/singleton/servicesentinel.go:708,728** · `reporterServer := m[r.Reporter]` is dereferenced for `.Name` with no nil check; `r.Reporter` is agent-supplied and `m` is a server snapshot. If the reporter was deleted (or isn't in the snapshot), the deref panics on the single `ss.worker()` goroutine, halting all service monitoring/alerting. **Confidence: medium (race-gated, large blast radius).**

### Data integrity
- **MEDIUM · wrong metric · model/rule.go:82** · `case "net_all_speed": src = float64(server.State.NetOutSpeed + server.State.NetOutSpeed)` double-counts outbound and ignores inbound. The parallel `transfer_all` case (line 88) correctly uses `NetOutTransfer + NetInTransfer`, confirming intent. `net_all_speed` alert rules fire on wrong data. **Confidence: high.**

### SSRF
- **MEDIUM · SSRF via DDNS webhook · pkg/ddns/webhook/webhook.go:64** · `utils.HttpClient.Do(req)` is issued against a request built from the user-controlled `WebhookURL` (`DDNSForm.WebhookURL` -> `cmd/dashboard/controller/ddns.go`), with **no IP allow-listing, no RFC1918/metadata CIDR block, and default redirect following** — unlike `model/notification.go`, which deliberately blocks those CIDRs and pins the dial to the resolved IP. An authenticated user can drive server-side requests to `127.0.0.1`, `169.254.169.254`, or internal hosts on DDNS update. The asymmetry with notification.go shows the protection is expected and missing here. **Confidence: medium.**

### Lower severity
- **LOW · nil-deref panic · service/rpc/nezha.go:47-48** · `server, _ := ServerShared.Get(clientID); server.TaskStream = stream` ignores `ok` and dereferences `server`, unlike the guarded handlers at nezha.go:110-113/176-179/267-270. If the server row is deleted in the narrow window after `Auth.Check`, this panics the RPC handler. **Confidence: medium path / low reachability.**

- **LOW · broken validation logic · service/rpc/nezha.go:220** · The `ff05ff05` magic-number guard is `(Data[0]!=0xff && Data[1]!=0x05 && Data[2]!=0xff && Data[3]==0x05)` — AND-chained `!=` checks plus a final `== 0x05`. It rejects almost nothing and never actually validates the magic; the intended guard is an OR of four `!=` comparisons. Real logic bug; impact limited because the downstream `GetStream(streamId)` lookup gates effect and the caller is authenticated. **Confidence: high (logic) / low (security impact).**

- **LOW · info disclosure · cmd/dashboard/controller/server.go:179-194** · In `forceUpdateServer`, for an unowned id whose `TaskStream == nil`, the handler appends to the `Offline` result **before** reaching the `HasPermission` check, letting a member probe online/offline status of servers they don't own. Information leak only; no write/action on foreign servers. **Confidence: high.**

## Examined and cleared (not bugs)
- `cmd/dashboard/controller/jwt.go` — `identityHandler` reloads the user from DB each request; role/ownership never trusted from the token; IP bound. No bypass.
- `model/notification.go` — SSRF is properly mitigated (scheme allow-list, blocked-CIDR check, dial pinned to resolved IP, redirects disabled). `VerifyTLS` default-off is an intentional user toggle.
- `server.go:63` (DDNSProfiles) and `server.go:331` (batchMoveServer), `nat.go` perm checks — validate the correct (allow) set; not inverted.
- `cmd/dashboard/rpc/rpc.go:84-110` service Cover/Ignore filtering and `service/rpc/nezha.go:284-289` IP-notification gating — constant values and parenthesization are correct; no inversion.
- `model` GORM `AfterFind` Unmarshal-return inconsistency, `pkg/utils/bytes.go` index bound, `pkg/{geoip,grpcx,websocketx,i18n,tsdb}` — no untrusted-input bug found.

## Caveats
- **Baseline checks were RED** (test/typecheck/build failed — missing Go toolchain modules / TS deps in the sandbox), so findings could not be measured against a green baseline. In detect-only this is acceptable: no fixes were applied and nothing required regression verification. A maintainer should reproduce findings in a working build before remediating.
- The three permission-inversion findings share one root cause: `CheckPermission` is given the exclusion set under the `*CoverAll` (deny-list) mode. A correct fix validates the **effective target** set (all servers minus the exclusion set) — or restricts these endpoints to admins — rather than patching each call site in isolation.

## How to review
git diff bench-base..bugsweep/20260529-213648   # (empty — detect-only made no changes)

Report artifact: .bugsweep/run-20260529-213648/report.md
