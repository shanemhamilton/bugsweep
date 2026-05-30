# Leaderboard — bugsweep @ b3d46b5

## Per-case verdicts

| case | bugsweep | baseline | ground-truth |
| --- | --- | --- | --- |
| go-sec-nezha-cron-46716 | NOT_DETECTED | ERROR | SendTriggerTasks() in crontask.go fans out cron task triggers to servers without checking that the task or target server belongs to the triggering user. The callers in servicesentinel.go (notifyCheck) and alertsentinel.go (checkStatus) invoke triggers driven by reporter/alert state, so a low-privilege user could cause cron tasks owned by other users to execute against servers they do not own (missing authorization). |
| go-sec-nezha-ssrf | ERROR | ERROR | NotificationServerBundle.Send() in model/notification.go issues an outbound HTTP request to an attacker-controlled notification URL with no validation of the resolved target address. A RoleMember can configure a notification via POST /api/v1/notification pointing at internal/loopback/link-local addresses, and the response body is reflected back, yielding server-side request forgery (SSRF) against the dashboard host's internal network. |
| js-sec-js-cookie-46625 | ERROR | ERROR | The assign() helper in src/assign.mjs copies every enumerable key from source objects onto the target with a `for (var key in source)` loop that does not exclude `__proto__`. Because cookie attributes are assembled through this helper, an attacker who controls attribute input can set `__proto__`, polluting the target object's prototype and injecting/overwriting cookie attributes (prototype pollution leading to cookie-attribute injection). |
| py-data-wger-barcode | SKIPPED | SKIPPED | search_barcode() in filtersets.py filters the queryset by barcode and, when no local match exists, calls Ingredient.fetch_ingredient_from_off() to pull the ingredient from OpenFoodFacts. The newly fetched ingredient is discarded: the function returns the original (still-empty) queryset rather than a queryset containing the just-fetched row, so a successful remote fetch yields an empty barcode-search result. |
| py-logic-wger-language | SKIPPED | SKIPPED | search_languagecode() in filtersets.py maps each comma-separated language code through load_language(). load_language() defaults unknown codes to English, so an unrecognized language code silently resolves to English rather than being ignored as the docstring promises ('Unknown codes are ignored'). The filter then matches English ingredients for a bogus code instead of returning no language constraint. |
| py-sec-flask-security-46715 | ERROR | ERROR | The OAuth account-verification flow in oauth_glue.py trusts the identity attribute returned by the OAuth provider without confirming it belongs to the currently logged-in user. oauth_verify_response() set the freshness/verification timestamp for any user resolved from the OAuth response, so an attacker who can complete an OAuth flow with a different provider account could 'verify' the victim's session. The identity field was also not constrained to configured IDENTITY_ATTRIBUTES nor passed through the attribute mapper. |
| py-sec-sqlfluff-46374 | SKIPPED | SKIPPED | The SQLFluff parser has no bound on the number of parse nodes it will produce, so a maliciously crafted query can drive the parser into uncontrolled resource consumption (CPU/memory exhaustion). ParseContext (context.py) tracked no node count, parse() (parser.py) imposed no limit, and there was no max_parse_nodes configuration or validation. |
| ts-sec-fedify-42462 | SKIPPED | SKIPPED | Fedify's Linked Data Signature verification (verifyJsonLd in sig/ld.ts) does not normalize a signed JSON-LD payload against a trusted local context before interpreting it, and inbox routing (inbox.ts) acts on the raw received representation. A crafted payload using JSON-LD named-graph restructuring keywords (@graph, @included, @reverse) can present one document to the signature check and a different interpreted graph to the application, bypassing the Linked Data Signature (improper verification of cryptographic signature). |
| ts-sec-samlify-46490 | ERROR | ERROR | The SAML login-response builder injects attribute values into the XML template without escaping element text. escapeTag() in libsaml.ts XML-escapes attribute values (quoted positions) but returns element-text replacements verbatim, and IdentityProvider.createLoginResponse() in entity-idp.ts builds the AttributeStatement through replaceTagsByValue() relying on that replacer. An attacker who controls an attribute value can inject XML elements into a signed SAML assertion (XML injection / privilege escalation via crafted AttributeValue). |

## Detection rate (95% Wilson CI)

| arm | detected@>=1 | detected@majority | hit-rate | completed | Wilson CI | status |
| --- | --- | --- | --- | --- | --- | --- |
| bugsweep | 0 | 0 | 0.0% | 1 | [0.0%, 79.3%] | inconclusive |
| baseline | 0 | 0 | 0.0% | 0 | [0.0%, 0.0%] | inconclusive |

## Paired delta (bugsweep − baseline)

- paired cases (both arms completed): 0
- detected@>=1 delta: 0.0% pp
- bugsweep excluded — ERROR: 4, SKIPPED: 4
- baseline excluded — ERROR: 5, SKIPPED: 4

## Contamination split

Cases are split by `disclosure_date` vs the runner model cutoff.

### Post-cutoff
- bugsweep: detected@majority 0, hit-rate 0.0% (completed 1)
- baseline: detected@majority 0, hit-rate 0.0% (completed 0)
- status: inconclusive (post-cutoff inconclusive floor)

### Pre-cutoff
- bugsweep: detected@majority 0, hit-rate 0.0% (completed 0)
- baseline: detected@majority 0, hit-rate 0.0% (completed 0)

## Provenance

| field | value |
| --- | --- |
| runner_model_id | claude-opus-4-8 |
| runner_cutoff_date | 2026-01-31 |
| judge_model_id | gpt-5.3-codex |
| judge_prompt_hash | 4b2d88c37101b6c53fb14dec3ef7d7e2d2f496e661a73c8c1584c628de4f9ed0 |
| bugsweep_commit | b3d46b5 |
| case_verified_shas | go-sec-nezha-cron-46716=d06d539d34c143d842b91e2a64326e8c8f9bc405; go-sec-nezha-ssrf=85b0dd2992733037b019442caffc6c049ba937dd; js-sec-js-cookie-46625=f6f157f430d707d2ffd0c9c9138227a6cea564e5; py-data-wger-barcode=a6cddb94d494405fbfc4da158b6ae710cd83e207; py-logic-wger-language=a6cddb94d494405fbfc4da158b6ae710cd83e207; py-sec-flask-security-46715=18808e1e642c4466f8daa46a68d4e1f77a6d1713; py-sec-sqlfluff-46374=4649341a8d651ccc73b0d7e71e57e987d246f03c; ts-sec-fedify-42462=aab002d2fe091e6c38eb4f319e9a766392c40a21; ts-sec-samlify-46490=0235cab01f0a1602ffac89ce28f4e253aace2ff5 |
| container_image_digest | (unknown) |
| egress_proxy_image | (unknown) |
| line_window | 10 |
| k | 1 |
