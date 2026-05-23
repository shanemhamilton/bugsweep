# Contributing to bugsweep

Thanks for your interest. bugsweep is a Claude Code skill: Markdown instructions plus a
small deterministic shell layer. Contributions are welcome — please keep the design
principle below intact.

## The one invariant

**The AI finds and fixes; deterministic shell scripts own every irreversible action.**
Anything that touches git state, the user's working tree, or branches must live in
`scripts/` as plain, auditable shell — never be left to model judgment. A change that
moves an irreversible operation into a prompt, or that lets the tool push/merge/delete or
work on the user's original branch, will not be accepted. See
`references/safety-rationale.md`.

## Layout

- `SKILL.md` — the entry point and orchestration the model follows.
- `scripts/` — deterministic layer: `preflight` (branch/stash), `run_checks`
  (tests/build), `guard` (stop conditions), `session` (continuity), `finalize` (safe
  return), `common.sh` (shared helpers).
- `prompts/` — the separated phases: `context-build`, `research`, `hunt`, `challenge`
  (Skeptic), `referee`, `fix`.
- `references/` — rationale, no-tests playbook, tuning, continuity model, and
  `antipatterns/` (per-stack catalogs).
- `config/bugsweep.config.json` — user-tunable settings.

## Testing changes

The scripts are testable without an LLM. Create a throwaway git repo with a known bug and
a test that catches it, then exercise the flow:

```bash
# in a scratch repo with a planted bug + failing test
bash scripts/preflight.sh                 # cuts bugsweep/<ts>, stashes work
bash scripts/run_checks.sh baseline <RUN_DIR>
# apply a fix, then:
bash scripts/run_checks.sh verify <RUN_DIR>   # OK or REGRESSION
bash scripts/guard.sh <RUN_DIR>               # CONTINUE or STOP <reason>
bash scripts/session.sh checkpoint <RUN_DIR>  # refreshes SESSION.md
bash scripts/finalize.sh <RUN_DIR>            # returns you to your branch
```

Verify the safety properties: a regression is reverted, your original branch and
uncommitted work are untouched, and the run never pushes or deletes anything.

Scripts target bash 3.2 (stock macOS) — avoid bash 4+ features (associative arrays,
`mapfile`, `${var,,}`). Run `bash -n scripts/*.sh` before submitting.

## Adding an anti-pattern catalog

Add `references/antipatterns/<stack>.md` (one-liners: the *smell* and *why it bites*),
then add a routing row to `references/antipatterns/index.md`.

## Pull requests

Keep changes focused. Describe what you changed and how you tested the safety properties.
By contributing you agree your work is licensed under the repository's MIT License.
