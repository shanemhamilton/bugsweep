# bugsweep report — 20260530-155626
**Branch:** bugsweep/20260530-155626   **Mode:** detect-only (no code changes, no commits)   **Iterations:** 1
**Stack:** TypeScript / Node · xml-crypto · @xmldom/xmldom · node-rsa · @authenio/xml-encryption (samlify 2.12.0, SAML 2.0 SSO library)
**Baseline checks:** auto-detected commands target a non-existent path (`backend/firebase-research`) — test/typecheck/build all reported `fail` from misdetection, not real regressions. In detect-only mode no fixes are measured against baseline.
**Final checks:** unchanged (no code modified).

## Summary
- Confirmed bugs: 5 (critical 0, high 0, medium 4, low 1); architectural: 3
- Fixed & verified: 0 (detect-only)   Quarantined (needs human): 0
- Coverage: 3/3 batches; all 18 `src/` files reviewed via Hunter → Skeptic → Referee
- Crown-jewel path (`parseLoginResponse → verifySignature`) is **wrapping-hardened**
  (CVE-2025-47949 remediation via `getSignedReferences()` + `shortcut` re-rooting is present
  and correct). Audit-closed items F-2 (XXE), F-3 (SHA-1 downgrade) verified still closed.

## Fixed
_None — detect-only run._

## Quarantined / needs human
_None auto-fixed; see confirmed list below. Detect-only never edits code._

## Confirmed but not fixed (detect-only)

- **BUG-1 · MEDIUM · architectural · src/libsaml.ts:748** — `verifyMessageSignature` casts
  `metadata.getX509Certificate('signing') as string`. When peer metadata declares **multiple
  signing certificates** (key rollover — two `<KeyDescriptor use="signing">`), the extractor
  aggregates them into a **string[]** (`metadata.ts` `certificate` field via
  `zipObject(..., skipDuplicated=false)`). The array flows into
  `utility.getPublicKeyPemFromCertificate` → `Buffer.from(array, 'base64')`, where the
  `'base64'` encoding is ignored for array input and each string element coerces to `NaN→0`,
  yielding a garbage buffer that `new X509Certificate()` rejects. *Effect:* Redirect- and
  SimpleSign-binding signature verification **throws/fails for any IdP mid key-rollover**,
  while the POST path works (it explicitly flattens arrays at libsaml.ts:611-617). Fails
  closed (availability/correctness, not bypass), but breaks valid logins. *Trigger:* SP
  configured with IdP metadata containing ≥2 signing certs + inbound Redirect/SimpleSign.

- **BUG-2 · MEDIUM · architectural · src/flow.ts:101 (sink: src/utility.ts:150
  `inflateString`)** — In `redirectFlow`, the attacker-supplied `SAMLRequest`/`SAMLResponse`
  query param is `inflateRawSync`-decompressed **before** any signature check, with **no
  `maxOutputLength`**. A few-KB deflate "bomb" expands toward `buffer.kMaxLength` (~2 GiB)
  per request → memory exhaustion / pre-auth DoS. The POST and SimpleSign paths use
  `base64Decode` only and are unaffected. *Trigger:* any endpoint that calls
  `parseLoginResponse`/`parseLoginRequest`/`parseLogout*` over the Redirect binding.
  *Suggested direction (not applied):* pass a bounded `maxOutputLength` to `inflateRawSync`.

- **BUG-3 · MEDIUM · architectural · src/flow.ts:158-190** — `<AudienceRestriction>` is
  extracted (`extractor.loginResponseFields.audience`) but **never compared** to the SP's
  `entityID` in any flow branch. A login Response captured for one SP can be replayed against
  another SP sharing the same IdP (`saml-core §2.5.1.4`). *Already documented as audit
  finding **F-4 (Open)*** in `.skills/audits/2026-04-security-audit.md` — re-confirmed live;
  reported here for completeness, not as a new discovery.

- **BUG-4 · MEDIUM · local · src/libsaml.ts:395-400 / 472-490** — Element-**body** template
  placeholders are intentionally **not XML-escaped** (`escapeTag` escapes only attribute
  values; `attributeStatementBuilder` uses raw `String.replace`). When an IdP feeds
  untrusted user data into a body tag — notably `NameID: user.email` in every
  `base64LoginResponse` builder — a value like `a</saml:NameID>…<saml:Attribute>…` injects
  markup into the assertion that the IdP then **signs**, letting an authenticated principal
  forge additional signed attributes/identity that a relying SP will trust. Context-dependent
  (requires the IdP to populate NameID/attributes from untrusted input), hence not high.

## Needs human / confirmed-uncertain

- **BUG-5 · LOW · src/libsaml.ts:611-637** — `verifySignature` cert selection. If
  `opts.metadata.getX509Certificate('signing')` is absent it returns `null`; the subsequent
  `(metadataCert as string[]).map(...)` then throws an uninformative `TypeError` instead of a
  clean `NO_SELECTED_CERTIFICATE`. More importantly, the *intended* `metadataCert.length===0`
  branch (lines 619/628) would **trust an X509Certificate embedded in the inbound message**
  without anchoring it to metadata — an auth-bypass shape that is currently masked only
  because `null.map` throws first. Not reachable as a bypass today (getX509Certificate never
  returns `[]`), but the guard is fragile: if that function ever yields an empty array the
  branch becomes a signature-verification bypass. Recommend an explicit unconditional
  "embedded cert MUST match metadata" guard + clean error on missing metadata cert.

## How to review
git diff bench-base..bugsweep/20260530-155626   # (empty — detect-only, no changes)

Artifacts: `.bugsweep/run-20260530-155626/{repo-context.md,antipatterns.md,recon.json,ledger.jsonl}`