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
# format the parser reads. The parser anchors on the "## Confirmed but not fixed"
# SECTION HEADER (bench/scorer/parse_report.py) and ignores bullets emitted
# without it, so the prompt MUST request that header line before the bullets —
# otherwise this arm parses to zero findings and can never score a detection.
# Read-only; no edits requested.
readonly CLAUDE_P_BASELINE_PROMPT='Find runtime bugs in this repository. First output the exact line "## Confirmed but not fixed", then below it list each bug as a single line in exactly this format: "- <BUG-ID> · <severity> · <category> · <file>:<line> · <one-line cause>". Output only that header line followed by the bug lines. Do not modify any files.'

# Read-only: this arm has no skill and must never edit source.
readonly CLAUDE_P_BASELINE_ALLOWED_TOOLS='Bash,Read'

# Optional runner-model flag (see claude_p.sh): BENCH_RUNNER_MODEL pins the
# model; unset falls back to the CLI default. Both arms pin the SAME model so a
# Sonnet-vs-Opus comparison varies only the runner, not the arm.
arm_print_cmd() {
  local workdir="$1" out="$2"
  local model_note="${BENCH_RUNNER_MODEL:+--model ${BENCH_RUNNER_MODEL} }"
  cat <<EOF
cd ${workdir}
claude -p "${CLAUDE_P_BASELINE_PROMPT}" ${model_note}--allowedTools "${CLAUDE_P_BASELINE_ALLOWED_TOOLS}" --permission-mode default
# baseline arm: no skill loaded; stdout (structured lines) -> ${out}/report.md
EOF
}

# Invoke claude from the workdir and capture its stdout as the report. Returns:
#   0  ran and stdout was captured into <out>/report.md
#   1  the capture produced nothing on disk (treated as infra ERROR by runner)
arm_run() {
  local workdir="$1" out="$2"
  local -a model_flag=()
  [[ -n "${BENCH_RUNNER_MODEL:-}" ]] && model_flag=(--model "${BENCH_RUNNER_MODEL}")
  (
    cd "${workdir}" || exit 1
    claude -p "${CLAUDE_P_BASELINE_PROMPT}" \
      ${model_flag[@]+"${model_flag[@]}"} \
      --allowedTools "${CLAUDE_P_BASELINE_ALLOWED_TOOLS}" \
      --permission-mode default
  ) >"${out}/report.md" 2>/dev/null || true

  [[ -s "${out}/report.md" ]] || return 1
}
