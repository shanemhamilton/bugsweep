#!/usr/bin/env bash
#
# claude_p.sh — the BUGSWEEP arm of the benchmark.
#
# Drives the real bugsweep skill headless via `claude -p` in DETECT-ONLY mode
# over the whole sandbox repo, makes NO code changes, and captures the skill's
# RUN_DIR/report.md into <out>/report.md so WU4's single parser can read it.
#
# This file is SOURCED by runner.sh, which owns the RESULT=/exit-code contract,
# the size_ceiling SKIP gate, the `claude`/workdir presence checks, the
# allow_web_research=false override + assertion, and the clean-tree assertion.
# Here we provide only the arm-specific pieces:
#   arm_print_cmd  <workdir> <out>   — print (do NOT run) the invocation argv
#   arm_run        <workdir> <out>   — invoke claude, capture report.md
#
# Detect-only rationale (SKILL.md "Modes"): a bare `/bugsweep` is detect-only —
# full pipeline, writes a report, no code changes. In `-p` mode slash skills are
# unavailable, so the task is described in natural language (per
# references/autonomous-maintenance.md) and the skill auto-triggers; the prompt
# explicitly forbids fixes/commits. Tool grants follow that reference: Bash,Read
# only — NO Edit/Write — so the model physically cannot mutate source.

set -euo pipefail

# Natural-language detect-only task. Must NOT request fix/autonomous behavior and
# must forbid any code change so the captured report reflects detection only.
readonly CLAUDE_P_PROMPT='Run bugsweep in detect-only mode over this whole repository: find runtime bugs across all files, write the bugsweep report to its RUN_DIR/report.md using the standard report template, and make NO code changes and NO git commits. Detect only: do not enter any fix or autonomous mode.'

# Tool grants. Write/Edit ARE included: the skill writes its report.md (under
# .bugsweep/) and some models (e.g. opus-4-8) use the Write tool to do so — with
# only Bash,Read a headless `-p` run blocks on an unanswerable permission prompt
# and never produces a report (ERROR). Excluding Write was never a real safety
# boundary anyway (Bash can mutate files too); the detect-only guarantee is
# enforced by the clean-tree assertion (no tracked-source change, HEAD unmoved)
# plus the NL prompt's explicit "make NO code changes".
readonly CLAUDE_P_ALLOWED_TOOLS='Bash,Read,Write,Edit'

# Print the invocation WITHOUT running it. runner.sh prepends the
# allow_web_research=false override note so --print-cmd shows the full intent.
# Optional runner-model flag. BENCH_RUNNER_MODEL pins the model claude runs
# (e.g. claude-opus-4-8); unset falls back to the CLI default. run.sh sets it
# from BENCH_RUNNER_MODEL_ID so the pinned model and the recorded provenance
# model_id are the SAME value.
arm_print_cmd() {
  local workdir="$1" out="$2"
  local model_note="${BENCH_RUNNER_MODEL:+--model ${BENCH_RUNNER_MODEL} }"
  cat <<EOF
cd ${workdir}
claude -p "${CLAUDE_P_PROMPT}" ${model_note}--allowedTools "${CLAUDE_P_ALLOWED_TOOLS}" --permission-mode default
# detect-only: no fix flag, no autonomous flag; config override forces research.allow_web_research=false
# capture: newest <workdir>/.bugsweep/runs/*/report.md -> ${out}/report.md
EOF
}

# Invoke claude from the workdir, then capture the skill's report. Returns:
#   0  ran and a report was captured into <out>/report.md
#   1  ran but no report.md could be located (treated as infra ERROR by runner)
arm_run() {
  local workdir="$1" out="$2"
  local -a model_flag=()
  [[ -n "${BENCH_RUNNER_MODEL:-}" ]] && model_flag=(--model "${BENCH_RUNNER_MODEL}")

  # Run the skill from inside the sandbox so preflight.sh writes its RUN_DIR
  # (<workdir>/.bugsweep/run-<ts>/, per scripts/preflight.sh) and its report.md
  # under <workdir>/.bugsweep/. claude's own stdout (which can include the
  # skill's RESULT=PROCEED-style strings) is swallowed so it cannot leak into
  # the runner's single terminal RESULT= line.
  (
    cd "${workdir}" || exit 1
    claude -p "${CLAUDE_P_PROMPT}" \
      ${model_flag[@]+"${model_flag[@]}"} \
      --allowedTools "${CLAUDE_P_ALLOWED_TOOLS}" \
      --permission-mode default
  ) >/dev/null 2>&1 || true

  # Locate the newest RUN_DIR report the skill produced.
  local report
  report="$(_arm_newest_report "${workdir}")"
  if [[ -z "${report}" || ! -f "${report}" ]]; then
    return 1
  fi

  cp "${report}" "${out}/report.md"
}

# Echo the path of the newest report.md under <workdir>/.bugsweep/, or empty.
# preflight.sh names each RUN_DIR `<workdir>/.bugsweep/run-<ts>/`, so we search
# the whole .bugsweep/ tree for report.md and take the most recently modified —
# robust to the exact RUN_DIR naming and to multiple runs in one workdir.
_arm_newest_report() {
  local workdir="$1"
  local bugsweep_dir="${workdir}/.bugsweep"
  [[ -d "${bugsweep_dir}" ]] || return 0
  find "${bugsweep_dir}" -type f -name report.md -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null \
    | head -1
}
