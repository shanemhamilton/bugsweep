#!/usr/bin/env bash
#
# claude_p_baseline.sh — the BASELINE arm of the benchmark.
#
# Drives a bare `claude -p` with NO bugsweep skill. The prompt constrains the
# model to emit the SAME structured-line format the bugsweep detect-only report
# uses, so WU4's single parser reads both arms identically. claude's stdout IS
# the report and is captured straight into <out>/report.md.
#
# This file is SOURCED by runner.sh, which owns the RESULT=/exit-code contract,
# the size_ceiling SKIP gate, the `claude`/workdir presence checks, and the
# clean-tree assertion. Here we provide only the arm-specific pieces:
#   arm_print_cmd  <workdir> <out>   — print (do NOT run) the invocation argv
#   arm_run        <workdir> <out>   — invoke claude, capture stdout to report.md

set -euo pipefail

# Baseline prompt: no skill, output constrained to the structured detect-only
# line format (matches SKILL.md "Confirmed but not fixed" bullets) so a single
# parser handles both arms. Read-only; no edits requested.
readonly CLAUDE_P_BASELINE_PROMPT='Find runtime bugs in this repository. List each bug as a single line in exactly this format: "- <BUG-ID> · <severity> · <category> · <file>:<line> · <one-line cause>". Output only those lines. Do not modify any files.'

# Read-only: this arm has no skill and must never edit source.
readonly CLAUDE_P_BASELINE_ALLOWED_TOOLS='Bash,Read'

arm_print_cmd() {
  local workdir="$1" out="$2"
  cat <<EOF
cd ${workdir}
claude -p "${CLAUDE_P_BASELINE_PROMPT}" --allowedTools "${CLAUDE_P_BASELINE_ALLOWED_TOOLS}" --permission-mode default
# baseline arm: no skill loaded; stdout (structured lines) -> ${out}/report.md
EOF
}

# Invoke claude from the workdir and capture its stdout as the report. Returns:
#   0  ran and stdout was captured into <out>/report.md
#   1  the capture produced nothing on disk (treated as infra ERROR by runner)
arm_run() {
  local workdir="$1" out="$2"
  (
    cd "${workdir}" || exit 1
    claude -p "${CLAUDE_P_BASELINE_PROMPT}" \
      --allowedTools "${CLAUDE_P_BASELINE_ALLOWED_TOOLS}" \
      --permission-mode default
  ) >"${out}/report.md" 2>/dev/null || true

  [[ -s "${out}/report.md" ]] || return 1
}
