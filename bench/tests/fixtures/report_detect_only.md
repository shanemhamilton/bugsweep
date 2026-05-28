# bugsweep report — 2026-05-28T09:30:00Z
**Branch:** bugsweep/2026-05-28T09:30:00Z   **Mode:** detect-only   **Iterations:** 1
**Stack:** python/flask   **Baseline checks:** pytest 42 passed   **Final checks:** pytest 42 passed

## Summary
- Confirmed bugs: 2 (critical 1, high 1, medium 0, low 0); architectural: 0
- Fixed & verified: 0   Quarantined (needs human): 0
- Coverage: 3/3; reviewed via Hunter->Skeptic->Referee

## Fixed
<one line per fix: BUG-ID · severity · lens · file:line · what was wrong · commit sha>

## Quarantined / needs human
<one line per item: BUG-ID · severity · file:line · why it wasn't auto-fixed>

## Confirmed but not fixed (detect-only or below severity floor)
- BUG-001 · critical · sql-injection · app/db/users.py:88 · user-controlled `email` interpolated into raw SQL
- BUG-002 · high · path-traversal · app/files/download.py:34 · request `name` joined to base dir without normalization

## How to review
git diff main..bugsweep/2026-05-28T09:30:00Z
