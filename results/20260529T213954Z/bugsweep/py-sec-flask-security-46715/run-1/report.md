# bugsweep report — 20260529-231901
**Branch:** bugsweep/20260529-231901   **Mode:** detect-only (no code changes, no commits)   **Iterations:** 1
**Stack:** Python 3 / Flask extension; WTForms, itsdangerous, passlib/bcrypt, pyotp, webauthn, Flask-Login; multi-backend datastore (SQLAlchemy / MongoEngine / Peewee / PonyORM)
**Baseline checks:** misconfigured (config `typecheck` points at a nonexistent JS path `backend/firebase-research`; no Python checks ran). Not relevant to detect-only — no changes were made.
**Final checks:** n/a — detect-only run, working tree untouched.

## Summary
- Confirmed bugs: 17 (critical 0, high 2, medium 5, low 10); architectural: 6 (CAND-1,2,3,4,5,7 span cross-file call chains)
- Fixed & verified: 0 (detect-only)   Quarantined (needs human): 0 (nothing auto-fixed)
- Confirmed but not fixed (detect-only): 17   Confirmed-uncertain / needs human: 3
- Coverage: 10/10 batches; all 38 in-scope package files reviewed via Hunter -> Skeptic -> Referee (0 rejected by Skeptic; Referee independently re-verified both HIGH items and resolved all 3 disputed items)

## Fixed
(none — detect-only run; no code was modified and no commits were made)

## Quarantined / needs human
(none — nothing was auto-fixed, so nothing was quarantined)

## Confirmed but not fixed (detect-only)
### HIGH
- CAND-1 · high · architectural · flask_security/webauthn.py:332-335 · WebAuthn signin lets a DEACTIVATED user authenticate: the `if not self.user.is_active:` branch appends DISABLED_ACCOUNT but is missing `return False`; control falls through (the next `return False` is gated on `is_locked()`, whose default returns True so `not True`==False), `validate()` returns True, and the view calls `login_user` -> `_login_user(force=True)` which skips Flask-Login's is_active recheck. Trigger: deactivated user with a registered passkey POSTs to /wan-signin/<token>. Compare correct pattern in forms.py LoginForm (has `return False`).
- CAND-3 · high · architectural · flask_security/utils.py:699-789 · Open redirect via 3+ leading slashes. `urlsplit('/////github.com')` yields empty netloc AND empty scheme, so `validate_redirect_url` treats it as relative and returns True; the secondary `quote()` in `get_post_action_redirect` keeps `/` (default safe set), so `Location: ///github.com` is emitted and browsers normalize it to the external host. The function docstring explicitly lists `next=/////github.com` as a must-defend case; tests cover only `//github.com`. Fix 18808e1e hardened only the netloc/subdomain path.

### MEDIUM
- CAND-2 · medium · architectural · flask_security/core.py:1190-1217 (+ callers forms.py:466/498/623, unified_signin.py:145, webauthn.py:334, oauth_glue.py:131) · `is_locked()` contract inverted vs its name/docstring. Commit 7ee1e834 renamed `is_allowed_authn`->`is_locked` and rewrote the docstring to "Return True if locked", but kept default `return True` and all callers' `if not user.is_locked(): return False`. The shipped default is a safe allow-all no-op; an app that overrides per the documented semantics inverts lockout (locked accounts authenticate; normal accounts blocked) across login / us_signin / forgot_password / WebAuthn / OAuth. High-blast-radius footgun.
- CAND-4 · medium · architectural · flask_security/totp.py:86-89,198-212 · TOTP/2FA replay protection is a no-op in the default config: `Totp.get_last_counter` returns None and `set_last_counter` is `pass`, and default `totp_cls` is this class (not subclassed), so passlib's reused-counter defense never engages. A captured TOTP/US authenticator code is replayable within the step+window.
- CAND-5 · medium · architectural · flask_security/oauth_provider.py:110-126 + oauth_glue.py:104-149 · OAuth login links to an existing local account by provider-asserted email with no verified-email requirement and no pre-established link. GitHub public email is attacker-settable (Google `email_verified` not checked) -> `find_user(email=...)` -> `login_user(...)` = takeover of an unlinked account.
- CAND-6 · medium · local · flask_security/views.py:367-388 + passwordless.py:49 · Passwordless magic-link replay: `token_login` consumes the login token and logs in but never rotates `fs_uniquifier` (token embeds only the uniquifier), so the same /login/<token> re-authenticates for the whole LOGIN_WITHIN window. `reset_password` rotates the uniquifier; this path does not.
- CAND-7 · medium · local · flask_security/recovery_codes.py:97-135 + datastore.py:577-591 · Recovery-code single-use bypass via index desync: `delete_recovery_code` computes `idx = codes.index(code)` on the decrypted+filtered list, then `mf_delete_recovery_code` pops `idx` on the stored encrypted list. With MULTI_FACTOR_RECOVERY_CODES_KEYS + TTL, `_decrypt_codes` silently drops expired/undecryptable entries (`except InvalidToken: pass`), desyncing indices -> the wrong (still-valid) code is popped and the redeemed code remains reusable.

### LOW
- CAND-8 · low · local · flask_security/decorators.py:502-540,565-606 · `roles_accepted`/`roles_required`/`permissions_*` fail OPEN when given an empty arg list (`Permission().can()`==True) -> any authenticated user allowed. Triggers only if an app invokes the decorator with no required role/permission (e.g. a misconfigured/empty config list).
- CAND-9 · low · local · flask_security/cli.py:136-137 · `attr, attrarg = attrarg.split(":")` (no maxsplit) raises ValueError on any attribute value containing `:` (e.g. a phone number), aborting `users create`. Should be `split(":", 1)`. Local admin CLI robustness, not a security boundary.
- CAND-10 · low · local · flask_security/recovery_codes.py:95,105 · Recovery codes compared with `code in dcodes` / `.index` (short-circuiting `==`) rather than `hmac.compare_digest`. Timing side-channel; high code entropy limits practicality.
- CAND-11 · low · local · flask_security/utils.py:781 · `get_post_action_redirect` interpolates literal `"None"` into reconstructed userinfo when a URL has a username but no password. Correctness bug; contained because validate runs first.
- CAND-12 · low · local · flask_security/utils.py:988 · Deprecated `get_token_status`: `expired = expired and (user is not None)` makes an expired token for a deleted user report `(expired=False, invalid=False, user=None)` — misleading status tuple; current callers separately check `user`.
- CAND-13 · low · local · flask_security/utils.py:1394 · `password_length_validator` bounds by code points (<=128) while bcrypt truncates at 72 bytes; multibyte passwords sharing a 72-byte prefix collide. Accepted bcrypt limitation (noted in code).
- CAND-14 · low · local · flask_security/views.py:269 · `logout` has no decorator and is GET-reachable via default LOGOUT_METHODS -> CSRF-unprotected forced logout (e.g. `<img src=.../logout>`). Low impact (logout only).
- CAND-16 · low · local · flask_security/views.py:810-811 · `two_factor_setup` writes the unverified submitted SMS phone number into the user record and commits before the new method is validated (code's own TODO at line 809).
- CAND-18 · low · local · flask_security/forms.py (ChangePasswordForm) · "same as current password" check compares the normalized current password against the not-yet-normalized new password -> bypassable via a unicode-normalization-equivalent new password.
- CAND-19 · low · local · flask_security/models/fsqla_v3.py:105, models/sqla.py:200 · WebAuthn `extensions = Column(String(255))` stores client-supplied JSON; >255 chars is silently truncated on non-strict backends (e.g. MySQL), persisting corrupt JSON. Data-integrity.

## Confirmed-uncertain / needs human (NOT confirmed for fixing)
- CAND-15 · low · flask_security/views.py:198-200 · Login generic-response PII munge gated on `request.method=="POST"` rather than "validation failed". Referee: the success path returns at line 198 before the munge, so any POST reaching it already failed validation — fragile coupling, no demonstrated runtime misbehavior.
- CAND-17 · low · flask_security/datastore.py (find_user) · Empty-kwargs `find_user` builds a match-all query on Mongo/Peewee/Pony (returns an arbitrary first user); SQLAlchemy `popitem()` raises. Real unsafe primitive but no shipped call site passes empty kwargs — reachable only via app misuse. Hardening suggestion.
- CAND-20 · low · flask_security/babel.py:105-108 · `FsDomain.format_list` fallback returns only inside `if not has_babel_ext():`, else implicit None. Requires flask_babel import failure WHILE the babel ext is registered (contradictory), so effectively unreachable.

## Notable areas verified as NOT vulnerable
- Open-redirect netloc/backslash/`%5C`/userinfo@/subdomain-allowlist bypasses are correctly blocked by commit 18808e1e (only the 3+-slash relative case CAND-3 slips through).
- `datastore.find_user` `kwargs.popitem()` attribute is never attacker-controlled (callers pass fixed attribute names; only the value is bound as an ORM parameter) — no column/operator injection.
- Signed-token chains (confirm / reset / change-email) correctly reject expired and reused tokens and bind to an immutable attribute hash; reset tokens are single-use via uniquifier rotation.
- mail_util has no manual header concatenation (no CRLF injection); phone_util catches only NumberParseException by design.

## How to review
git diff bench-base..bugsweep/20260529-231901
# (detect-only: this diff contains NO source changes — only the .bugsweep/ run artifacts)