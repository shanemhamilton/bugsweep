# Bugsweep — evidence-based bug hunting and fixes

> **v0.7.0-rc.1 — development prerelease.** Live validation and final acceptance remain incomplete. Stable remains v0.6.0. See [validation limits](CHANGELOG.md#070-rc1---2026-09-06).

[![Release](https://img.shields.io/github/v/release/shanemhamilton/bugsweep?sort=semver&label=release)](https://github.com/shanemhamilton/bugsweep/releases)
[![License: MIT](https://img.shields.io/github/license/shanemhamilton/bugsweep)](LICENSE)

Bugsweep is a skill for Claude Code and Codex. It investigates runtime bugs across a
repository, challenges each finding, and can fix confirmed defects in an isolated
worktree. It records unresolved work in the project's tracker and verifies cleanup of
the exact temporary resources it owns.

**Current development:** executable proof, native review receipts, isolated execution,
semantic analyzer imports, and held-out evaluation are being strengthened. Pure checks
verify their local contracts. Actual host runs, isolation tests, budget enforcement,
and human calibration are separate release evidence; this source does not establish
a measured false-positive rate or superiority over another tool.

## What it does

- Builds a frozen-scope model of architecture, trust boundaries and cross-file flows.
- Uses local anti-pattern catalogs and optional bounded research to guide investigation.
- Captures Hunter, Skeptic and Referee evidence, including rejected candidates.
- Requires an expected assertion failure before each fix and the unchanged test passing
  after it, alongside a suite comparison by check and native test identity.
- Rechecks each fixed bug against the final combined source without overwriting its
  original proof. Records unavailable evidence instead of treating it as a pass.
- Preserves audit progress across context resets and separates audit coverage from
  operational closeout.

Priority, graph, variant and CodeQL/Semgrep hints reorder investigation. They never
confirm a finding or remove files from the requested scope. Model confidence remains
uncalibrated; repeated model reviews do not establish statistical independence.

## Install

To evaluate this prerelease, check out the exact tag, inspect its installer, and
choose a host. The installer needs the accompanying helper files and Python 3.12+
with `jsonschema==4.26.0` already installed.

```bash
release_dir="$(mktemp -d)"
git clone --branch v0.7.0-rc.1 --single-branch https://github.com/shanemhamilton/bugsweep.git "$release_dir"
# Inspect install.sh and scripts/installer_helper.py before continuing.
bash "$release_dir/install.sh" --version v0.7.0-rc.1 --claude
# or --codex / --all
```

This prerelease installer selects the highest numeric stable tag by default,
resolves its exact commit, and records installation provenance. The explicit
`--version v0.7.0-rc.1` above selects this candidate. `--edge` selects main, which
remains at the stable source while this candidate is reviewed. For the stable
version, follow the instructions attached to the [v0.6.0 release](https://github.com/shanemhamilton/bugsweep/releases/tag/v0.6.0).

`CLAUDE_SKILLS_DIR` controls the Claude skills root. `CODEX_DIR` controls the Codex root,
including its skills and registration file. Updates preserve local configuration, refuse
unrelated modified installed files, and use recoverable staged replacement. Failed
multi-host installs report prior successes and the failed destination.

`/bugsweep --update` runs the updater belonging to the active installation. It preserves
that installation's custom root; it does not silently switch to another host's default
copy. Update before starting a run, then invoke the skill again.

## Use

| Request | Outcome |
| --- | --- |
| `/bugsweep` | Detect and record a bounded audit; no source edits. |
| `/bugsweep src/api` | Keep the hunt within the selected path. |
| `/bugsweep --approve` | Ask before each regression-test/fix edit; all proof gates still apply. |
| `/bugsweep --fix` | Fix and locally land eligible work during one planned pass. |
| `/bugsweep --autonomous` | Repeat within the configured runtime, iteration and fix caps. |
| `/bugsweep --recall` | Also retain plausible unresolved findings for human review. |

Start with detection to see the findings and capability report. Fixes require a configured
external execution policy and native review capability. Without those, Bugsweep continues
source review and records confirmed work for a human; it does not execute project
commands directly on the host.

## Configure

Edit the installed [configuration](config/bugsweep.config.json) to set runtime/iteration
caps, scope exclusions and existing test/build commands. Python 3.12+ and
`jsonschema==4.26.0` are required for structured execution, proof and closeout.
The installer checks these prerequisites without installing dependencies.

Set `execution.policy_file` to an operator-owned absolute path outside the target. The
policy pins the Docker executable and image, non-root identity, resources, exact allowed
environment and denied network. The provider checks Docker's effective settings before
start and records actual readback. Tests write declared outputs to `/bugsweep-output`.
See [execution evidence](references/execution-evidence.md) for fields and repro examples.

`adversarial.hosts` pins approved native host/model IDs. Native reviews require a separately
configured approved proxy profile with explicit caps, pinned adapter and native clients.
Real API credentials remain in the proxy's external secret mount. No ambient host login
or executable download is used as a fallback.

Optional `analyzers.imports` names existing CodeQL/Semgrep commands and SARIF outputs.
Only configured commands run through the provider; the importer validates coordinator
receipts, source identity, paths and bounded traces. Missing and rejected imports remain
visible. No installed-tool discovery or automatic rule downloads occur.

## Completion and recovery

`finalize.sh` creates `report.md`, `run-summary.json` and a pending closeout handoff. Audit
coverage (`complete`, `partial`, `stalled`) is distinct from operational completion.

```bash
bash "$SKILL_ROOT/scripts/run-status.sh" "$RUN_DIR" --json
```

Exit `0` requires verified `COMPLETED_LANDED` or `COMPLETED_RECORDED`, no remaining blocker,
and exact branch/worktree absence. Exit `10` means pending or unknown; `2` means invalid
state. A crash remains pending and can be reconciled using the recorded identity.

Only verified fixes can locally land through the integration gate. Unresolved work is
tracker-recorded; unique unlanded work needs verified recovery escrow before deletion.
Bugsweep never pushes during an audit. Cleanup preserves dirty, live and ambiguous work;
normal closeout never invokes a repository-wide reaper. See the
[closeout contract](references/tracker-closeout.md).

The execution provider enforces deadlines on its child processes. Model reasoning still
uses phase checkpoints; a hard kill cannot guarantee immediate finalization. Reports
retain deferred coverage and partial work rather than calling an unfinished audit clean.

## Evaluation and contributing

The [benchmark](bench/README.md) compares Claude and Codex separately, using repeated,
interleaved current-skill, previous-release and no-skill runs with the same frozen caps.
Its current mode evaluates selected skill instructions in a read-only detection task;
separate native stage calls support frozen pipeline variants. It does not measure the
complete operational skill, and actual stage effects remain unverified.
It retains failed slots and unknown accounting, source-bound finding evidence, human
calibration, rejected-candidate audits and uncertainty. A test fixture is not live evidence.
Fresh corpus and gold-oracle execution must be validated before results count as held-out.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for pure local checks and separate Git-backed CI.
The [skill](SKILL.md) is the concise operating contract; [phase prompts](prompts/) contain
mode-specific details. [SERVICE-INVENTORY.md](SERVICE-INVENTORY.md) maps the shared
implementations so changes reuse the existing execution and proof boundaries.
