# bugsweep report — 20260530-000402
**Branch:** bugsweep/20260530-000402   **Mode:** detect-only   **Iterations:** 1
**Stack:** Go 1.26 · Gin · gRPC · GORM · JWT/OAuth2   **Baseline checks:** recorded failing (see note)   **Final checks:** n/a (no changes)

> Baseline note: `run_checks.sh` recorded `test`, `typecheck`, and `build` as failing. The
> `typecheck` step was a mis-detected non-Go command (`tsc` in a non-existent
> `backend/firebase-research`); `go build ./...` / `go test ./...` need module downloads not
> available in this sandbox. This is a detect-only run with no code changes, so baseline
> status is not a gating factor and no fix was measured against it.

## Summary
- Confirmed bugs: 5 (critical 0, high 1, medium 2, low 2); architectural: 1 (the cross-package SSRF chain, reported within BUG-1)
- Fixed & verified: 0   Quarantined (needs human): 1
- Coverage: HTTP controllers + router/authz core, gRPC/agent boundary, singleton/service layer, pkg/* (ddns, geoip, utils, websocketx, grpcx), model/* binding + notification/DDNS senders, plus a cross-file SSRF/authz sweep; reviewed via Hunter→Skeptic→Referee (adversarial). Generated `proto/*.pb.go` skimmed only.

## Fixed
_None — detect-only run; no code changes made._

## Quarantined / needs human
- BUG-3 · medium · `cmd/dashboard/controller/waf/waf.go:18-42` (`RealIp`) · WAF / brute-force IP-block bypass via a spoofable real-IP header — exploitable only when `Conf.WebRealIPHeader` is set to a header name AND the dashboard is reachable without a trusted proxy stripping that header. Real but deployment-config-conditional; a human must confirm the production topology before calling it active.

## Confirmed but not fixed (detect-only or below severity floor)
- BUG-1 · high · SSRF (response-leaking) · sink `model/notification.go:132-153` ← source `cmd/dashboard/controller/notification.go:59,71-72` · Any authenticated member makes the dashboard issue an arbitrary outbound HTTP request with no destination validation; non-2xx response bodies are reflected back to the caller. (POST/PATCH `/api/v1/notification` body `url` → `NotificationForm.URL` → `n.URL` → `NotificationServerBundle.Send` → `http.NewRequest(ns.reqURL(...))` → `client.Do`)
- BUG-2 · medium · SSRF (stored/deferred) · sink `pkg/ddns/webhook/webhook.go:92,64` ← source `cmd/dashboard/controller/ddns.go:70,141` · A member-created webhook-type DDNS profile stores an unvalidated `WebhookURL`; the dashboard later dials it (following redirects) on a server IP change. Same missing destination validation as BUG-1, different sink.
- BUG-4 · low · concurrency / data race · `service/singleton/server.go:92-106` (`UpdateDDNS`) · Reads shared `*model.Server` fields (`DDNSProfiles`, `OverrideDDNSDomains`, `GeoIP.IP`) and `Conf.DNSServers` and launches `go provider.UpdateDomain(...)` without a lock the concurrent agent path (`service/rpc/nezha.go:278` `ReportGeoIP`) also holds — `-race`-detectable; worst case torn reads of the slices feeding the outbound DDNS request.
- BUG-5 · low · latent nil-deref · `service/singleton/server.go:96` · `utils.IfOr(ip != nil, ip, &server.GeoIP.IP)` is a plain function, so `&server.GeoIP.IP` is dereferenced unconditionally even when `ip != nil`. Safe today only because `model.InitServer` (`model/server.go:45`) always pre-initializes `GeoIP`; any future path reaching `UpdateDDNS` with a non-`InitServer`-built `*Server` panics.

## Details

**BUG-1 — Notification webhook SSRF (high).** `createNotification` (`cmd/dashboard/controller/notification.go:46`) binds `NotificationForm`, copies `n.URL = nf.URL` with no validation (`:59`), and when `!nf.SkipCheck` calls `ns.Send("a test message")` (`:71-72`) BEFORE persisting — so the request fires on the create call itself. `Send` (`model/notification.go:113`) selects `utils.HttpClientSkipTlsVerify` whenever `VerifyTLS` is unset/false (`:116-119`) — TLS verification is OFF by default (`pkg/utils/http.go:14-19`) — builds the request from `ns.reqURL(message)`, which returns `n.URL` after only placeholder substitution (`model/notification.go:46-51`), and calls `client.Do(req)` (`:143`). On a non-2xx response it returns `fmt.Errorf("%d@%s %s", … string(body))` (`:151-153`), reflecting the internal response body to the caller — a response-leaking SSRF, not blind. The route is under the plain `auth` group (`controller.go:122`, `auth = api.Group("", authMw)` at `:81`, `authMw = authMiddleware.MiddlewareFunc()` at `:68`) — any logged-in member, not admin. `NotificationForm.URL` carries no validator at all (`model/notification_api.go:5`). Trigger: `POST /api/v1/notification` with `{"url":"http://169.254.169.254/latest/meta-data/iam/security-credentials/","request_method":1,"request_type":1,"skip_check":false}` → the dashboard fetches cloud-metadata creds / localhost services and returns the body in the error. Disconfirming checks that FAILED to clear it: handler does no validation; `reqURL`/`Send` use `n.URL` verbatim; repo-wide grep found loopback/private-IP checks (`IsLoopback`) only in `ws.go`, never on this outbound path. High (not critical) because it requires an authenticated member account.

**BUG-2 — DDNS webhook SSRF sibling (medium).** Same class, stored/deferred sink. `createDDNS`/`updateDDNS` (`cmd/dashboard/controller/ddns.go:47,105`, plain `auth` group at `controller.go:139-140`) validate only `MaxRetries` and IDN-normalize domains; `p.WebhookURL = df.WebhookURL` is stored unvalidated (`:70,:141`); `DDNSForm.WebhookURL` is `validate:"optional"` only (`model/ddns_api.go:12`). On a server IP change, `service/singleton/server.go:92` → `service/singleton/ddns.go:80` → `pkg/ddns/webhook/webhook.go:117-136` parses `WebhookURL` (host/scheme verbatim; only query-param values templated) and `:92`/`:64` dials it via `utils.HttpClient` (proxy-from-env, 10-min timeout, default redirect-following, no dialer restriction). Medium rather than high because firing is deferred to an IP-change event. Disconfirming check that cleared a STRONGER variant: an agent-supplied IP cannot inject the host — `pkg/ddns/ddns.go:73-77` runs `netip.ParseAddr` on the reported IP before `#ip#` substitution, so the residual SSRF is operator/member-config-tainted, not agent-tainted.

**BUG-3 (quarantined) — real-IP header spoofing (medium, config-dependent).** When `Conf.WebRealIPHeader` is a header name (not empty / not `ConfigUsePeerIP`), `RealIp` (`waf/waf.go:18-42`) trusts `c.Request.Header.Get(header)` verbatim. That value feeds WAF `CheckIP` (`waf.go:44-50`), the login/oauth brute-force blockers (`jwt.go:107-127`, `oauth2.go:139,145`), and JWT IP-pinning (`jwt.go:74-80,132`). An attacker reaching the dashboard directly (header not stripped by a fronting proxy) rotates `X-Forwarded-For` per attempt to evade per-IP blocking. With the default (`""`/`ConfigUsePeerIP`) the code uses `c.RemoteIP()`, which is not spoofable — hence quarantined pending the deployment topology.

**BUG-4 — UpdateDDNS data race (low).** `ServerClass.Update` releases `listMu` (`server.go:52`) before calling `UpdateDDNS`, which then reads pointed-to `*Server` fields under no lock while the agent gRPC path (`ReportGeoIP` → writes `server.GeoIP/State/Host`) can mutate the same struct concurrently. A lead, not a proven crash; verify with `go test -race`.

**BUG-5 — IfOr eager-eval latent nil-deref (low).** `IfOr` (`pkg/utils/utils.go`) evaluates both arguments, so `&server.GeoIP.IP` is always dereferenced. Currently masked by `InitServer` always running first; reported as a footgun, not an active defect.

**Cleared (verified NOT bugs):** agent `#ip#` SSRF injection (validated by `netip.ParseAddr`, `pkg/ddns/ddns.go:73-77`); gRPC cross-server spoofing (`service/rpc/auth.go:22-75` — secret→userID then UUID→server; missing UUID auto-creates a server owned by the authenticated user; no cross-tenant selection); all five gRPC handlers call `Auth.Check` first (no unauthenticated streaming method); `geoip.Lookup` (embedded DB, no egress); randomness (`crypto/rand`, no `math/rand` for secrets); OAuth2 state/CSRF (random state + cookie key, fixed-path callback redirect, no open redirect); `getUid` `MustGet` panic (only reachable under the hard-auth group); SQL (parameterized — `model/waf.go:134`, deletes use `id in (?)` bindings).

## How to review
git diff bench-base..bugsweep/20260530-000402
