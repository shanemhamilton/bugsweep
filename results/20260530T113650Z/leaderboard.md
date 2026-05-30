# Leaderboard — bugsweep @ ce037bf

## Per-case verdicts

| case | bugsweep | baseline | ground-truth |
| --- | --- | --- | --- |
| go-sec-nezha-ssrf | DETECTED | NOT_DETECTED | NotificationServerBundle.Send() in model/notification.go issues an outbound HTTP request to an attacker-controlled notification URL with no validation of the resolved target address. A RoleMember can configure a notification via POST /api/v1/notification pointing at internal/loopback/link-local addresses, and the response body is reflected back, yielding server-side request forgery (SSRF) against the dashboard host's internal network. |

## Detection rate (95% Wilson CI)

| arm | detected@>=1 | detected@majority | hit-rate | completed | Wilson CI | status |
| --- | --- | --- | --- | --- | --- | --- |
| bugsweep | 1 | 1 | 100.0% | 1 | [20.7%, 100.0%] | inconclusive |
| baseline | 0 | 0 | 0.0% | 1 | [0.0%, 79.3%] | inconclusive |

## Paired delta (bugsweep − baseline)

- paired cases (both arms completed): 1
- detected@>=1 delta: 100.0% pp
- bugsweep excluded — ERROR: 0, SKIPPED: 0
- baseline excluded — ERROR: 0, SKIPPED: 0

## Contamination split

Cases are split by `disclosure_date` vs the runner model cutoff.

### Post-cutoff
- bugsweep: detected@majority 1, hit-rate 100.0% (completed 1)
- baseline: detected@majority 0, hit-rate 0.0% (completed 1)
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
| bugsweep_commit | ce037bf |
| case_verified_shas | go-sec-nezha-ssrf=85b0dd2992733037b019442caffc6c049ba937dd |
| container_image_digest | sha256:f73210f6d5c446324abdc1bc3ec8b0947fd17fa71c49a8337910189cba586152 |
| egress_proxy_image | bugsweep-bench-proxy:latest@sha256:84057e26c47f048e7c2fc1c23635cdb00e1de9836c2de3ae95e9c4a7685f2bf4 |
| line_window | 10 |
| k | 1 |
