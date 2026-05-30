# bugsweep report — 20260529-233025
**Branch:** bugsweep/20260529-233025   **Mode:** detect-only (no code changes, no commits)   **Iterations:** 1
**Stack:** Go 1.26 · gin · gorm · gRPC (nezhahq/nezha server-monitoring dashboard)   **Baseline checks:** test FAIL · typecheck FAIL · build FAIL (pre-existing in this clone; not introduced by this run)   **Final checks:** unchanged (detect-only — nothing was modified)

## Summary
- Confirmed bugs: 12 (critical 1, high 1, medium 5, low 5); architectural/cross-file: 3 (BUG-01, BUG-02, BUG-07)
- Fixed & verified: 0 (detect-only)   Quarantined (needs human): 0
- Coverage: high-risk sinks audited via targeted manual review (cron subsystem, gRPC task path, auth/router wiring) + 3 hunter subagents (auth/JWT/OAuth2/user/WAF; notification/DDNS/NAT/streams) + an adversarial skeptic pass on the headline finding (UPHELD). Not every one of 106 Go files was read line-by-line; the security-relevant controllers, singletons, RPC handlers, and `pkg/` sinks were.

---

## Confirmed but not fixed (detect-only)

### BUG-01 · CRITICAL · authz / RCE · cross-file
**Cross-tenant remote command execution via cron `Cover` semantics.**
`cmd/dashboard/controller/cron.go:53` & `:111` (gate) -> `service/singleton/crontask.go:160-166` (execution)

The only server-ownership gate on cron create/update is
`singleton.ServerShared.CheckPermission(c, slices.Values(cf.Servers))`, which (see
`service/singleton/singleton.go:249`) checks `HasPermission` **only for the server IDs present in
`cf.Servers`** and returns `true` for an empty list. At execution time, `CronTrigger`
(`crontask.go:160`) iterates the **global** `ServerShared.Range` (all servers, all owners) with
**no filter on the cron's owner / `UserID`** — it filters solely by `Cover` + `crIgnoreMap`.

The `Cover` values (`model/cron.go:11`) are: `CronCoverIgnoreAll=0` ("run only on the listed
servers"), `CronCoverAll=1` ("run on ALL servers **except** the listed ones"),
`CronCoverAlertTrigger=2`. For `Cover==CronCoverAll`, the execution set is the **complement** of
`cf.Servers` — so the ownership check validates the *excluded* set, not the *executed* set.

**Exploit:** A non-admin (`RoleMember`) user `POST`s `/cron` (route uses `commonHandler`, not
`adminHandler` — `controller.go:132`) with `task_type=0`, `servers=[]` (or only their own server
IDs), `cover=1`, and an arbitrary `command`. `CheckPermission([])` passes. The task is scheduled via
`AddFunc` (fires automatically, with no auth context) and is also manually triggerable
(`manualTriggerCron` passes `cr.HasPermission` because `cr.UserID = getUid(c)` made them the owner).
At trigger time the command is sent — `s.TaskStream.Send(&pb.Task{Data: cr.Command, Type: TaskTypeCommand})`
(`crontask.go:167`) — to **every online agent in the fleet, including servers owned by other users and
the admin**, which execute it. Skeptic verdict: **UPHELD** (all five links confirmed in code; no
mitigating control found). Precondition: multi-user deployment with >=1 non-admin user and >=1
target server online with a live `TaskStream`.

### BUG-02 · HIGH · SSRF · cross-file
**DDNS webhook provider sends fully user-controlled requests with no SSRF guard — the unhardened twin of the recent notification hardening.**
`pkg/ddns/webhook/webhook.go:64` (`utils.HttpClient.Do(req)`), request built at `:75-104` from
`WebhookURL/WebhookMethod/WebhookRequestBody/WebhookHeaders` (set in `cmd/dashboard/controller/ddns.go:70-74,141-145`).

The notification path was just hardened (HEAD commit) with `resolveNotificationTarget` +
IP-pinned `DialContext` (`model/notification.go:194-230`), but the structurally identical DDNS
webhook uses the plain shared `utils.HttpClient` with **no IP/CIDR allow-list, no scheme check, no
redirect suppression**, and `Proxy: http.ProxyFromEnvironment`. A member creates a `webhook` DDNS
profile with `WebhookURL=http://169.254.169.254/latest/meta-data/...` (or `http://127.0.0.1:<port>/`)
bound to a server they own; when the agent reports an IP change
(`service/rpc/nezha.go:278` -> `ServerClass.UpdateDDNS` -> `provider.SetRecords` -> `HttpClient.Do`),
the dashboard host issues the attacker-controlled internal request. Cloud-metadata / internal-service
SSRF. (Not test-fired on create, so no immediate self-detection.)

### BUG-03 · MEDIUM · logic / authz · OAuth2 identity reassignment (dead-code branch)
`cmd/dashboard/controller/oauth2.go:159-174`

`singleton.DB.Where("provider = ? AND open_id = ?", ...).Limit(1).Find(&bind)` is used, then the
code branches on `result.Error == gorm.ErrRecordNotFound`. GORM's `.Find()` does **not** set
`ErrRecordNotFound` on zero rows (only `First/Take/Last` do), so the `Create` branch is **unreachable**
and `Save` always runs. When a user completes a *bind* flow for a `(provider, open_id)` already bound
to a **different** user, the existing row is loaded, `bind.UserID` is overwritten with the current
user, and saved — silently transferring the binding instead of rejecting it. The DB unique index is
`user_id+provider+open_id`, which does not prevent the same `open_id` moving to a new user.
Account-binding takeover, bounded by the provider's own auth + the `nz-o2s` state cookie (so not blind-CSRF).

### BUG-04 · MEDIUM · concurrency · lock-order inversion (deadlock)
`service/singleton/notification.go` — `UpdateGroup:102-108` locks `groupMu` **then** `listMu`;
`DeleteGroup:163-167` locks `listMu` **then** `groupMu`. Classic AB-BA inversion: a concurrent
`updateNotificationGroup`/`createNotificationGroup` and `batchDeleteNotificationGroup` (both
reachable by authenticated users) can deadlock permanently. Because these mutexes guard state read on
every `SendNotification`, a hit wedges notification delivery process-wide until restart.

### BUG-05 · MEDIUM · authz / IDOR · terminal & file-manager stream attach
`cmd/dashboard/controller/terminal.go:73-78` (`terminalStream`) and `cmd/dashboard/controller/fm.go:73-78`
(`fmStream`). `ioStreamContext` (`service/rpc/io_stream.go:13`) stores **no owner/user identity**.
`createTerminal`/`createFM` correctly enforce `server.HasPermission(c)`, but the attach endpoints only
verify the stream UUID **exists** (`GetStream(streamId)`) — they never check the attaching user owns it
or has permission on the underlying server. Any authenticated user (incl. a `RoleMember` with no rights
on the target server) who obtains the stream UUID can attach to another user's live SSH terminal / file
session and read-write it. Bounded by UUID unpredictability (`hashicorp/go-uuid`) -> requires UUID leak,
not enumeration.

### BUG-06 · MEDIUM · nil-deref / panic · `server.GeoIP` in UpdateDDNS
`service/singleton/server.go:96`:
`...GetDDNSProvidersFromProfiles(server.DDNSProfiles, utils.IfOr(ip != nil, ip, &server.GeoIP.IP))`.
`utils.IfOr` (`pkg/utils/utils.go:96`) is an ordinary function, so **both** arguments are evaluated
eagerly — `&server.GeoIP.IP` is dereferenced even when `ip != nil`. `GeoIP` can be nil (confirmed by
the explicit nil-check at `cmd/dashboard/controller/ws.go:172`). A server with a nil `GeoIP` that has
DDNS profiles panics here, crashing the goroutine handling that path.

### BUG-07 · MEDIUM · nil-deref / DoS · cross-file · unchecked server in gRPC `RequestTask`
`service/rpc/nezha.go:47-48`: `server, _ := singleton.ServerShared.Get(clientID); server.TaskStream = stream`
discards the `ok` and dereferences `server`. The sibling handler `ReportSystemState`
(`nezha.go:110-113`) guards exactly this with `if !ok || server == nil { return ... }`; `RequestTask`
does not. The gRPC server installs only unary interceptors (`getRealIp`, `waf`) and **no recovery
interceptor** (`cmd/dashboard/rpc/rpc.go:25`); `RequestTask` is a *streaming* RPC with no interceptors
at all. grpc-go does not recover handler panics by default, so an unrecovered nil-deref panic crashes
the **process**. Reachable via TOCTOU: a server deleted between `Auth.Check` returning `clientID` and
the `Get(clientID)` call returns a nil `server`.

### BUG-08 · LOW · validation gap · `updateProfile`
`cmd/dashboard/controller/user.go:85-87` sets `Username`/`Password` without the empty-username and
>=6-char-password checks that `createUser` enforces (`user.go:130-135`). Self-inflicted (user can set an
empty username or a 1-char password). Role/AgentSecret are correctly preserved, so no privilege change.

### BUG-09 · LOW · open-redirect / auth-code interception · `getRedirectURL`
`cmd/dashboard/controller/oauth2.go:22-29` builds the OAuth2 `redirect_uri` from client-supplied
`Host` + `Referer`/`X-Forwarded-Proto`. With a permissive provider redirect allow-list or a
Host-header-tolerant proxy, this is the classic auth-code-interception vector. Bounded by the provider's
`redirect_uri` allow-list and whether the deployment trusts `Host`.

### BUG-10 · LOW · data race · terminal/fm ping goroutine
`cmd/dashboard/controller/terminal.go:87-95` and `fm.go:87-95`: the keep-alive goroutine writes the
function-scoped `err` that the main body also reads/writes with no synchronization — an unsynchronized
shared-variable access (trips `-race`).

### BUG-11 · LOW · CPU busy-loop · `serverStream`
`cmd/dashboard/controller/ws.go:139-142`: on a `getServerStat` error the `continue` skips the bottom
`time.Sleep(time.Second*2)`, so a sustained error spins the loop with no backoff, pinning a CPU per
stuck connection.

### BUG-12 · LOW · authz gap · `createNAT`/`updateNAT` skip check for uncached ServerID
`cmd/dashboard/controller/nat.go:56-60,104-108`: `if server, ok := ServerShared.Get(nf.ServerID); ok { check }`
— when `ServerID` is not in the cache the permission check is skipped and the NAT row is created/updated
with that `ServerID`. Existing-but-unowned servers are still correctly denied, so impact is limited to
attaching a profile to a non-existent / not-yet-cached server ID.

---

## Fixed
None — detect-only run. No code was changed and no commits were made.

## Quarantined / needs human
None — detect-only run. All 12 items above are reported for human triage; nothing was auto-fixed.

## Notable areas reviewed and assessed CLEAN
- Notification SSRF hardening (HEAD commit) is **effective**: `resolveNotificationTarget` validates the
  resolved IP (blocklist + `IsGlobalUnicast`) and **pins** it into `DialContext` (no DNS-rebinding/TOCTOU),
  `CheckRedirect` disables redirects, IPv4-mapped IPv6 is `Unmap()`-normalized, error path no longer
  reflects the upstream body. (`model/notification.go`)
- JWT: `JWTSecretKey` is a 1024-char crypto-random secret persisted on first boot; HS256; 1h expiry;
  deleted users lose access via per-request `DB.First(&user)`. (`jwt.go`, `model/config.go`)
- Admin gating: all sensitive routes (`/user`, `/batch-delete/user`, `/batch-delete/waf`,
  `/online-user/batch-block`, `PATCH /setting`, `/maintenance`) correctly use `adminHandler`.
- `OnUserDelete` (recent fix) correctly recomputes per-`uid` and deletes only the current user.
- WAF block/unblock window math (`model/waf.go`) — no inversion.
- Cron HTTP surface beyond BUG-01: routes are all under the authenticated group; `listCron` is
  ownership-filtered via `listHandler`/`filter`; create/update also check `ServerShared.CheckPermission`
  and `cr.HasPermission` symmetrically with peer controllers.

## How to review
This was a detect-only run; the throwaway branch `bugsweep/20260529-233025` contains **no commits**.
Inspect the findings directly in the working tree, e.g.:
```
git diff <original-branch>..bugsweep/20260529-233025   # (empty — no changes were made)
```
Start with BUG-01 (`cmd/dashboard/controller/cron.go` + `service/singleton/crontask.go`) and BUG-02
(`pkg/ddns/webhook/webhook.go`).
