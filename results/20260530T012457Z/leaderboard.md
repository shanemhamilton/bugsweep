# Leaderboard — bugsweep @ a997a43

## Per-case verdicts

| case | bugsweep | baseline | ground-truth |
| --- | --- | --- | --- |
| go-sec-nezha-cron-46716 | NOT_DETECTED | (unknown) | SendTriggerTasks() in crontask.go fans out cron task triggers to servers without checking that the task or target server belongs to the triggering user. The callers in servicesentinel.go (notifyCheck) and alertsentinel.go (checkStatus) invoke triggers driven by reporter/alert state, so a low-privilege user could cause cron tasks owned by other users to execute against servers they do not own (missing authorization). |

## Detection rate (95% Wilson CI)

| arm | detected@>=1 | detected@majority | hit-rate | completed | Wilson CI | status |
| --- | --- | --- | --- | --- | --- | --- |
| bugsweep | 0 | 0 | 0.0% | 1 | [0.0%, 79.3%] | inconclusive |
| baseline | 0 | 0 | 0.0% | 0 | [0.0%, 0.0%] | inconclusive |

## Paired delta (bugsweep − baseline)

- paired cases (both arms completed): 0
- detected@>=1 delta: 0.0% pp
- bugsweep excluded — ERROR: 0, SKIPPED: 0
- baseline excluded — ERROR: 0, SKIPPED: 0

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
| judge_model_id | gpt-4o-judge |
| judge_prompt_hash | 4b2d88c37101b6c53fb14dec3ef7d7e2d2f496e661a73c8c1584c628de4f9ed0 |
| bugsweep_commit | a997a43 |
| case_verified_shas | go-sec-nezha-cron-46716=d06d539d34c143d842b91e2a64326e8c8f9bc405 |
| container_image_digest | (unknown) |
| egress_proxy_image | (unknown) |
| line_window | 10 |
| k | 1 |
