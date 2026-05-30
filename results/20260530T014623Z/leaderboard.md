# Leaderboard — bugsweep @ a997a43

## Per-case verdicts

| case | bugsweep | baseline | ground-truth |
| --- | --- | --- | --- |
| py-data-wger-barcode | ERROR | (unknown) | search_barcode() in filtersets.py filters the queryset by barcode and, when no local match exists, calls Ingredient.fetch_ingredient_from_off() to pull the ingredient from OpenFoodFacts. The newly fetched ingredient is discarded: the function returns the original (still-empty) queryset rather than a queryset containing the just-fetched row, so a successful remote fetch yields an empty barcode-search result. |

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
| runner_model_id | claude-opus-4-8 |
| runner_cutoff_date | 2026-01-31 |
| judge_model_id | gpt-4o-judge |
| judge_prompt_hash | 4b2d88c37101b6c53fb14dec3ef7d7e2d2f496e661a73c8c1584c628de4f9ed0 |
| bugsweep_commit | a997a43 |
| case_verified_shas | py-data-wger-barcode=a6cddb94d494405fbfc4da158b6ae710cd83e207 |
| container_image_digest | (unknown) |
| egress_proxy_image | (unknown) |
| line_window | 10 |
| k | 1 |
