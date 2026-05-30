# bugsweep report — 20260530-113242
**Branch:** bugsweep/20260530-113242   **Mode:** detect-only (no fixes, no commits)   **Iterations:** 1
**Stack:** JavaScript (ES modules) — js-cookie browser library; QUnit/Grunt/Rollup tooling
**Baseline checks:** unavailable in this environment — `npm: command not found`; the typecheck override points at a non-existent `backend/firebase-research` dir. Recorded baseline `fail` is an environment artifact, not a real test signal.
**Final checks:** n/a (detect-only — no code changed)

## Summary
- Confirmed bugs: 1 (critical 0, high 1, medium 0, low 0); architectural: 0
- Fixed & verified: 0   Quarantined (needs human): 0
- Coverage: whole repo (src/api.mjs, src/assign.mjs, src/converter.mjs, index.js); reviewed via Hunter->Skeptic->Referee
- Detect-only run: no branch commits, no working-tree edits.

## Fixed
(none — detect-only mode)

## Quarantined / needs human
(none)

## Confirmed but not fixed (detect-only)
- BUG-001 · **high** · security/prototype-pollution · `src/assign.mjs:4-6` · The `__proto__`
  guard (`if (key === '__proto__') continue`) was removed from the shallow-merge helper.
  When a merge source has an **own enumerable** `__proto__` key — the normal shape produced
  by `JSON.parse` of untrusted input — `target[key] = source[key]` becomes
  `target['__proto__'] = source['__proto__']`, reassigning the merged object's prototype.
  `assign` backs `set`/`remove`/`withAttributes`/`withConverter`, and `set` then iterates
  attributes with `for (var attributeName in attributes)` (which enumerates *inherited*
  enumerable props) and writes them into `document.cookie` (a sink). An attacker who can
  influence the attributes/converter object can therefore manipulate the prototype chain and
  inject unintended cookie attributes. This guard exists in upstream `main` and was deleted
  on this branch — a deliberate security-hardening regression. Suggested fix: restore the
  guard inside the `for...in` loop.

## Notes on other diffs reviewed (not bugs)
- `src/api.mjs:68` `catch (_e)` -> `catch` (optional catch binding): identical runtime
  behavior. Not a bug.
- `src/api.mjs:78-79` `set: set, get: get` -> `set, get` (property shorthand): identical
  runtime behavior. Not a bug.
- `src/converter.mjs` and the rest of `src/api.mjs` match upstream js-cookie; no runtime
  defects found.

## How to review
git diff bench-base..bugsweep/20260530-113242     # (empty — detect-only made no changes)
git diff main..bench-base -- src/                 # shows the removed __proto__ guard (BUG-001)
