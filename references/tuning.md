# Tuning bugsweep

All knobs live in `config/bugsweep.config.json`.

## Caps (bound cost and runtime on unattended runs)

- `max_iterations` — how many hunt/verify/fix cycles the loop may run. Each iteration
  covers one batch of files. For a big repo you may want this higher; to cap an
  overnight spend, keep it modest.
- `max_runtime_minutes` — wall-clock ceiling. The guard stops the loop once exceeded.
- `max_fixes_per_run` — hard ceiling on total fixes, so a noisy codebase can't generate
  an unreviewably large branch in one run.
- `no_progress_streak_to_stop` — stop after this many consecutive iterations find zero
  new confirmed bugs. This is what makes the loop end on its own when the code is clean.

## Scope and noise

- `severity_floor` — `--severity` on the command line overrides this. Set to `medium` or
  `high` to fix only impactful bugs and leave low-severity items as report-only.
- `exclude_globs` — keep dependencies, build output, generated code, and vendored files
  out of scope. Anything matched here is never read or modified.
- `protected_branches` — branches bugsweep refuses to start from when they're dirty.

## Check commands

Leave `commands.*` empty to auto-detect (Node/npm, Python/pytest, Go, Rust). Set them
explicitly for anything else or to be precise — config always wins over detection.
Examples:
- iOS/Xcode: `"build": "xcodebuild -scheme MyApp -destination 'generic/platform=iOS' build"`
- Monorepo subset: `"test": "pnpm --filter @app/api test"`
- Python compile-only safety net: `"typecheck": "python -m compileall -q ."`

## Recommended profiles

- **First run / calibrating trust:** `/bugsweep --approve` with `severity_floor: "medium"`.
- **Overnight on a feature branch:** `/bugsweep --autonomous`, `max_runtime_minutes` and
  `max_iterations` sized to your budget, `no_progress_streak_to_stop: 2`.
- **Pre-release gate, no edits:** `/bugsweep` (detect-only) over the whole repo.

## Adversarial review (new)

- `adversarial.challenge_enabled` — run the Skeptic pass that tries to disprove each
  finding. Keep on; it is the main false-positive filter.
- `adversarial.referee_enabled` — run the neutral Referee to resolve disputed findings and
  spot-check high-severity ones. Turning it off is faster but lets more borderline findings
  through to the fix stage; keep on for autonomous runs.
- `adversarial.referee_spotchecks_upheld` — have the Referee independently re-verify the
  highest-severity findings the Skeptic already upheld, instead of trusting the chain.

## Anti-pattern research (new)

- `research.antipattern_priming` — load the curated stack catalogs to prime the hunt.
  Leave on; it materially improves what the hunters look for.
- `research.allow_web_research` — allow a few bounded web lookups for version-specific
  advisories on the detected frameworks. Off by default so runs are deterministic and
  offline; turn on only when a web/search tool is available and you want current CVE-class
  awareness.

## Large repos

When a repo has more files than can be covered within `max_runtime_minutes`, bugsweep sets
`large_repo_mode: true` in `recon.json` at the end of Step 2 and logs a
`large_repo_mode_activated` event. This is a signal, not a failure — the loop continues but
the report will be labelled `PARTIAL`.

To tune for large repos:

- **Increase `max_runtime_minutes`** to give the loop more wall-clock budget. A repo with
  ~150 batches needs roughly 25 hours at 10 min/batch — overnight `--autonomous` runs are
  the right mode.
- **Use `--autonomous` with `session.checkpoint_every_iterations: 3`** so context resets
  happen regularly. Every reset is free (all state is on disk); skipping them bloats context
  until the model degrades.
- **Raise `severity_floor` to `"medium"` or `"high"`** to spend adversarial review time only
  on impactful findings. Low-severity findings on large repos fill the report but aren't
  worth the runtime cost on a first pass.
- **Use `exclude_globs`** to drop generated code, vendored deps, and migration files that
  rarely contain runtime bugs. Reducing file count is the single biggest lever.
- **Run iteratively across sessions.** Cross-run state in `.bugsweep/state/` means each run
  picks up where the last left off — a large repo does not need to be fully covered in one
  run to accumulate value.

If a run stalls completely (no report written), `finalize.sh` will emit a stub from
`recon.json` coverage counts and the ledger. Check `ledger.jsonl` to see where it stopped.

## Session continuity (new)

- `session.checkpoint_every_iterations` — how often to refresh `SESSION.md` and recommend a
  context reset on long runs. Lower = more frequent resets (leaner context, slightly more
  overhead); 0 disables reset recommendations. A reset never loses progress because all
  state is on disk — see `references/context-and-continuity.md`.
