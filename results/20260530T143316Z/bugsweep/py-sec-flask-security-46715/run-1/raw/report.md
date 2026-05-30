# bugsweep report — 20260530-153444
**Branch:** bugsweep/20260530-153444   **Mode:** detect-only (no fixes, no commits)   **Iterations:** 1
**Stack:** Python / Flask (Flask-Security auth library, ~14k LOC)   **Baseline checks:** typecheck=fail (pre-existing; the auto-detected `tsc` target is an unrelated stray TS project — not the Python code under audit; no Python test run was wired up)   **Final checks:** unchanged (detect-only — no code modified)

## Summary
- Confirmed bugs: 4 (critical 0, high 1, medium 0, low 3); architectural: 1
- Fixed & verified: 0 (detect-only)   Quarantined (needs human): 0
- Confirmed-uncertain / needs human: 8
- Coverage: 6/6 batches (whole `flask_security/` package), reviewed via Hunter -> Skeptic -> Referee

## Fixed
_None — detect-only run. No code changes, no commits._

## Quarantined / needs human
_None — detect-only run does not quarantine; see "Confirmed-uncertain" below._

## Confirmed but not fixed (detect-only)

- **BUG-1 · HIGH · architectural · `flask_security/core.py:1190-1217` (callers `forms.py:466,498,623`, `unified_signin.py:145`, `webauthn.py:334`, `oauth_glue.py:131`) · `UserMixin.is_locked()` public API contract is inverted vs. its implementation — apps that implement the documented account-lockout feature fail OPEN.**
  Commit `7ee1e834` (#1204) renamed `is_allowed_authn` → `is_locked` and rewrote the docstring to the opposite meaning ("Return True if the user account is locked") but did NOT invert the default return value or any call site. The body still `return True`, and every caller still proceeds with login when the method returns truthy: forms use `if not user.is_locked(...): return False` (deny only when it returns falsy); oauth uses `if ... and user.is_locked(...): <log in>`. Both polarities are mutually consistent and mean "True ⇒ allowed to authenticate" — i.e. the implementation still has the OLD `is_allowed_authn` semantics. But `is_locked` is a **documented public extension point** (`docs/features.rst:362`: "can be used to support account lockout", `versionadded:: 5.8.0`). An app developer who overrides it per the docstring returns `True` to lock an account → the guard treats `True` as "allowed" → **the locked account is authenticated** (fail-open security-control bypass), and conversely an unlocked user (returns `False`) is **denied all logins** (fail-closed availability break). The shipped default is unaffected (no override ⇒ always `True` ⇒ unchanged from before), so this is a latent contract bug, not an out-of-the-box exploit. Fix = pick one definition and make the name, docstring, default return value, all 6 call sites, and the test helper agree.

- **BUG-2 · LOW · local · `flask_security/mail_util.py:139-140` · `MailUtil.normalize()` mutates the shared app config dict, silently disabling `check_deliverability` for later `validate()` calls.**
  `validator_args = config_value("EMAIL_VALIDATOR_ARGS") or {}` returns the **live** `app.config["SECURITY_EMAIL_VALIDATOR_ARGS"]` object (`config_value` is `app.config.get(...)`, `utils.py:887`), and the next line does `validator_args["check_deliverability"] = False` in place. `validate()` (`mail_util.py:147-166`, used by registration) reads the same dict, so after any unauthenticated request triggers `normalize()` (e.g. `/login` identity lookup), an app-configured `check_deliverability=True` is permanently turned off process-wide. Only affects apps that set `SECURITY_EMAIL_VALIDATOR_ARGS` (default is `None` → a fresh `{}` each call, unaffected). Fix = copy first: `dict(config_value(...) or {})`.

- **BUG-3 · LOW · local · `flask_security/recovery_codes.py:95` · MFA recovery-code verification uses a non-constant-time comparison.**
  `check_recovery_code` returns `code in dcodes`, where `dcodes` is a list of decrypted plaintext recovery codes; `list.__contains__` uses `str.__eq__`, which short-circuits on the first differing byte. Every other secret comparison in the library is constant-time (hashing context / itsdangerous HMAC). This leaks per-character match timing on a second authentication factor. Practical exploitation is hard (network jitter ≫ per-char delta, and the attacker must already have passed primary auth at `mf_recovery`), hence LOW. Fix = compare via `hmac.compare_digest` against each stored code.

- **BUG-4 · LOW · local · `flask_security/recovery_codes.py:244-247` (+ `check_recovery_code`/`delete_recovery_code` 91-106) · recovery-code single-use is a check-then-act race (TOCTOU).**
  `MfRecoveryForm.validate` calls the read-only `check_recovery_code`; the view then schedules `delete_recovery_code` + `after_this_request(view_commit)`. Two concurrent requests with the same valid code can both pass validation before either commits the deletion, so one single-use code authenticates two sessions. (`delete_recovery_code` also does `codes.index(code)`, which raises `ValueError` if the code was concurrently removed.) Requires the attacker to already hold a valid code and primary credentials, so the escalation is marginal → LOW. Fix = make verify+consume atomic (delete-and-check in one datastore transaction).

## Confirmed-uncertain / needs human (not auto-fixable; judgment call)

- **WebAuthn challenge is not single-use — replayable within the token TTL · MEDIUM-uncertain · `webauthn.py` (signin/register/verify response paths; challenge minted at 423/591/611, validated at 527/688/848).** The challenge lives only in a stateless signed `wan_serializer` token returned to the client; verification is `check_and_get_token_status(..., within=WAN_*_WITHIN)` (signature + max-age) — the challenge is never stored or consumed server-side. Within the window, a captured assertion/registration POST could be replayed; the WebAuthn sign-count regression check is the only backstop and is a no-op for authenticators reporting a static counter of 0 (and absent for registration). This is a deliberate stateless-design tradeoff common in the wild, so flagged for human judgment rather than auto-confirmed. Hardening = bind the challenge to a server-side single-use marker (e.g. session nonce) and reject reuse.

- **TOTP / one-time codes are replayable within their validity window by default · `totp.py:63-92,198-212`.** `Totp.get_last_counter` returns `None` and `set_last_counter` is `pass`, so passlib's used-counter rejection never triggers — a valid emailed/SMS/authenticator code can be reused until expiry. This is **explicitly documented as not-implemented-by-default** (`totp.py:26-32`) with a subclass hook, so it is a documented limitation rather than a defect. Surfaced because the shipped default is replay-able and many deployments won't subclass.

- **`unified_signin.py:205` reuses the loop-shared `passcode` after `normalize()`.** In `_UnifiedPassCodeForm.validate2`, the `password` branch does `passcode = password_util.normalize(passcode)`; if the password check fails the loop continues and `verify_totp(token=passcode, ...)` runs against the normalized value, not the user input. Latent: for ASCII/numeric codes `normalize` (NFKD) is a no-op, so no observed misbehavior today — but it is a real variable-reuse bug that would bite if a code ever contained NFKD-unstable characters. Fix = use a separate local for the normalized password.

- **`utils.py:719-720` `validate_redirect_url` subdomain check is coarse (defense-in-depth gap, not independently exploitable).** With `REDIRECT_ALLOW_SUBDOMAINS`, the check is `url_next.netloc.endswith(f".{base_domain}")` on the raw `netloc` (includes userinfo/port and is not backslash-normalized), so e.g. `https://attacker.com\.lp.com` passes the validator. However, the actual redirect emitter `get_post_action_redirect` (#1223 fix, `utils.py:778-788`) re-parses and `quote()`s the **hostname** (`attacker.com%5C.lp.com`), neutralizing the browser backslash trick, and every final redirect (including the 2FA `next` carried as an *encoded* `url_for` query param → `get_post_login_redirect`) flows through that emitter. So this is NOT an exploitable open redirect in the current code — but the validator and the emitter disagree on what "host" means; aligning the validator to parse `url_next.hostname` would remove the latent footgun.

- **`utils.py:719-720` rejects legitimate subdomain redirects that include an explicit port.** Same `endswith` on `netloc` means `http://sub.lp.com:5000` fails the subdomain allowance (`"sub.lp.com:5000".endswith(".lp.com")` is False). Fail-closed functional/usability issue, not a security hole.

- **`twofactor.py:171` `is_tf_setup` returns a truthy secret string, not a strict bool.** `return user.tf_totp_secret and user.tf_primary_method`. Current callers (`if not is_tf_setup(...)`) coerce correctly, but the value is brittle if ever compared by identity or serialized, and an empty-string `tf_primary_method` would mis-report a user with a secret as "not setup". Low.

- **`recovery_codes.py:132-134` `_decrypt_codes` silently drops codes that fail decryption (`except InvalidToken: pass`).** On key rotation (dropping an old `MULTI_FACTOR_RECOVERY_CODES_KEYS` entry) or TTL expiry, previously-issued codes silently vanish from both verification and the "show codes" display with no signal to the user. Robustness/usability, not security. Low.

- **`oauth_provider.py:113` GitHub provider trusts `profile["email"]` which GitHub returns as `null` for private-email users.** `return "email", profile["email"]` then `find_user(email=None)`; best case the login fails with `IDENTITY_NOT_REGISTERED`, but a NULL-email row in some schemas could be matched unintentionally, and a missing key would raise. Low; robustness hardening.

## Rejected during adversarial review (recorded so they aren't re-raised)
- "`is_locked` has *opposite* polarity at `oauth_glue.py:131` vs the form call sites" — FALSE. Both forms (`if not is_locked(): deny`) and oauth (`if is_locked(): proceed`) consistently mean "True ⇒ proceed with login." The real defect is the inverted name/docstring vs. that shared implementation (BUG-1), not a call-site disagreement.
- "Open redirect via backslash/`endswith` is exploitable" — over-claim. Backstopped by `get_post_action_redirect` hostname-quoting (#1223); demoted to the defense-in-depth note above.
- Token-auth forgery / stale-token, `is_locked` causing a *default* regression, OAuth `state` CSRF, password/email/username normalization mismatch, decorator `any()/all()` logic, freshness checks, weak randomness — all traced and found correct.

## How to review
```
git diff bench-base..bugsweep/20260530-153444   # (empty — detect-only; no commits)
```
Findings above reference exact `file:line` in the working tree on branch `bench-base`.
Top priority for human review: **BUG-1** (`is_locked` inverted public contract).
