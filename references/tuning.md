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

## Execution and native review

- Automatic fixes require an external `required-untrusted` Docker execution policy. It
  must use a digest-pinned image and denied network for checks, repro, and analyzers. If it
  is absent or cannot produce a verified receipt, the run may detect and record findings but
  must not fix them automatically.
- `adversarial.hosts` defaults to `{}`. Set only explicit operator-approved `claude` and/or
  `codex` model IDs. Preflight records that map and the installed review-prompt hash; each
  fresh native review must match both. An empty map means native review is unavailable for
  automatic fixes.
- Multiple fresh verdicts determine eligibility; they are not statistically independent and
  their confidence is uncalibrated. Static analyzers and research can seed investigation but
  never confirm a candidate, narrow the required proof, or authorize a fix.

## Anti-pattern research (new)

- `research.antipattern_priming` — load the curated stack catalogs to prime the hunt.
  Leave on; it materially improves what the hunters look for.
- `research.allow_web_research` — allow a few bounded web lookups for version-specific
  advisories on the detected frameworks. Off by default so runs are deterministic and
  offline; turn on only when a web/search tool is available and you want current CVE-class
  awareness.

## Large repos

The planner writes every selected file into `recon-plan.json` before source modeling.
It bounds each batch with two portable, configurable limits:

- `context.max_batch_files` — maximum files per ordinary batch (default 25).
- `context.max_batch_bytes` — maximum source bytes per ordinary batch (default 131,072).

A file larger than the byte limit stays visible as an oversized singleton; a missing
size is an explicit unknown singleton. These limits bound planning units, not model
tokens or the dependency reads needed to trace a bug. They are starting values, not
benchmarked optimal settings.

Above `context.large_repo_file_threshold` (default 800), only
`context.large_repo_first_pass_batches` (default 40) are initially admitted. Ranking
chooses which batches fit; never-audited status does not expand the budget. Explicit
priority promotions have their own bounded allowance below. Guard checkpoints still
enforce the runtime and iteration caps.

Each admitted slice completes context → hunt → review → checkpoint before the next
slice is modeled. Deferred work remains in the plan and makes coverage partial. Later
runs use exact audit membership to rank the remaining frontier. Raising time or batch
limits trades cost for more investigation, without guaranteeing more verified bugs.

If a run stalls, `finalize.sh` can emit a stub from `recon.json` and the ledger. A hard
kill still requires recovery; it is not a completed audit.

## Priority intelligence

- `priority.recent_commit_count` — bounded first-run/fallback Git window. Exact changes since
  the last finalized run take precedence when that commit is available.
- `priority.max_targets` — maximum ranked files written to `priority-context.json` (hard cap
  200).
- `priority.max_reasons_per_file` — maximum independent reason records retained per file
  (hard cap 8). This is display-only; lowering it does not change the score or rank.
- `priority.promotion_limit` — maximum deferred **batches** that `must_focus`/`high` candidates
  may promote into this run (hard cap 20). Already non-deferred work consumes no budget.
- `priority.max_promoted_files` — maximum total files contained by newly promoted batches
  (hard cap 1,000). A candidate cannot partially promote a batch; an oversized batch remains
  deferred.
- `priority.max_glob_matches` — an explicit critical/signal glob matching more files than
  this is treated as over-broad and does not promote them (hard cap 100).
- `priority.max_signal_age_hours` — freshness limit for a project signal that omits
  `expires_at` (default 168 hours; hard cap one year). Expired signals are counted but do not
  rank work.
- `priority.critical_globs` — explicit business-critical tracked paths. Prefer the
  project-local signal inbox when one Bugsweep installation scans several different repos.
- `priority.signal_files` — bounded repository-local JSONL inputs. The default is
  `.bugsweep/priority-signals.jsonl`; no remote service is contacted.

Priority outcomes are append-only observations in
`.bugsweep/state/priority-outcomes.jsonl`. Their `signal_yield` aggregates never tune these
values automatically; changing ranking weights remains a reviewed and benchmarked code/config
decision.

See `references/priority-intelligence.md` for the inbox schema, score categories, and trust
boundaries.

## Session continuity (new)

- `session.checkpoint_every_iterations` — how often to refresh `SESSION.md` and recommend a
  context reset on long runs. Lower = more frequent resets (leaner context, slightly more
  overhead); 0 disables reset recommendations. A reset never loses progress because all
  state is on disk — see `references/context-and-continuity.md`.
