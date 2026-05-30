# Leaderboard — bugsweep @ af564b0

## Per-case verdicts

| case | bugsweep | baseline | ground-truth |
| --- | --- | --- | --- |
| js-sec-js-cookie-46625 | ERROR | (unknown) | The assign() helper in src/assign.mjs copies every enumerable key from source objects onto the target with a `for (var key in source)` loop that does not exclude `__proto__`. Because cookie attributes are assembled through this helper, an attacker who controls attribute input can set `__proto__`, polluting the target object's prototype and injecting/overwriting cookie attributes (prototype pollution leading to cookie-attribute injection). |

## Detection rate (95% Wilson CI)

| arm | detected@>=1 | detected@majority | hit-rate | completed | Wilson CI | status |
| --- | --- | --- | --- | --- | --- | --- |
| bugsweep | 0 | 0 | 0.0% | 0 | [0.0%, 0.0%] | inconclusive |
| baseline | 0 | 0 | 0.0% | 0 | [0.0%, 0.0%] | inconclusive |

## Paired delta (bugsweep − baseline)

- paired cases (both arms completed): 0
- detected@>=1 delta: 0.0% pp
- bugsweep excluded — ERROR: 1, SKIPPED: 0
- baseline excluded — ERROR: 0, SKIPPED: 0

## Contamination split

Cases are split by `disclosure_date` vs the runner model cutoff.

### Post-cutoff
- bugsweep: detected@majority 0, hit-rate 0.0% (completed 0)
- baseline: detected@majority 0, hit-rate 0.0% (completed 0)
- status: inconclusive (post-cutoff inconclusive floor)

### Pre-cutoff
- bugsweep: detected@majority 0, hit-rate 0.0% (completed 0)
- baseline: detected@majority 0, hit-rate 0.0% (completed 0)

## Provenance

| field | value |
| --- | --- |
| runner_model_id | claude-opus-4-7 |
| runner_cutoff_date | 2026-01-31 |
| judge_model_id | gpt-4o-judge |
| judge_prompt_hash | 77cb73cb616f71568745e835aff6a2823cf57c2b4ac8a04f04067cbc1204f125 |
| bugsweep_commit | af564b0 |
| case_verified_shas | js-sec-js-cookie-46625=f6f157f430d707d2ffd0c9c9138227a6cea564e5 |
| container_image_digest | sha256:f73210f6d5c446324abdc1bc3ec8b0947fd17fa71c49a8337910189cba586152 |
| egress_proxy_image | bugsweep-bench-proxy:latest@sha256:84057e26c47f048e7c2fc1c23635cdb00e1de9836c2de3ae95e9c4a7685f2bf4 |
| line_window | 10 |
| k | 1 |
