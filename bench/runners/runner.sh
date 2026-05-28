#!/usr/bin/env bash
#
# runner.sh — benchmark runner-adapter dispatch + terminal RESULT/exit contract.
#
# Drives one benchmark arm headless over a prepared sandbox clone and captures
# the raw report artifact into <out>/report.md. It does NOT parse the report or
# decide DETECTED/NOT_DETECTED — that is WU4's parse_report.py. This script only:
#   - dispatches by --runner to an arm script (claude_p | claude_p_baseline),
#   - enforces the per-case size_ceiling (SKIP if the workdir exceeds it),
#   - forces research.allow_web_research=false via a per-run workdir config
#     override and ASSERTS it (so the no-network container cannot silently
#     degrade), for the bugsweep arm,
#   - asserts the workdir git tree is clean after the run (detect-only made no
#     code changes), and
#   - emits EXACTLY ONE terminal status line and the matching exit code.
#
# Terminal contract (mirrors the scripts/ RESULT= convention):
#   ran, artifact captured            -> RESULT=RAN    exit 0
#   infra failure (no claude/workdir, capture/assert failed) -> RESULT=ERROR exit 1
#   skipped (size_ceiling exceeded, unsupported)             -> RESULT=SKIP  exit 10
#
# usage:
#   runner.sh --runner <claude_p|claude_p_baseline> \
#             --case <case.json> --workdir <sandbox> --out <dir>
#   runner.sh --print-cmd --runner <...> --case <...> --workdir <...> --out <...>
#     Print (do NOT run) the arm invocation argv for Tier-A assertions.

set -euo pipefail

RUNNERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNNERS_DIR

# --- terminal status emitters (each prints exactly one RESULT= line) ----------

emit_ran()   { echo "RESULT=RAN"; exit 0; }
emit_skip()  { echo "RESULT=SKIP${1:+ $1}"; exit 10; }
emit_error() { echo "runner.sh: $*" >&2; echo "RESULT=ERROR"; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage:
  runner.sh --runner <claude_p|claude_p_baseline> --case <case.json> --workdir <sandbox> --out <dir>
  runner.sh --print-cmd --runner <...> --case <...> --workdir <...> --out <...>
EOF
  exit 2
}

# --- size_ceiling gate --------------------------------------------------------

# Count tracked-ish files in the workdir, excluding the .git dir.
workdir_file_count() {
  local workdir="$1"
  find "${workdir}" -type f -not -path '*/.git/*' | wc -l | tr -d ' '
}

# Sum lines across those same files (best-effort; binary files count too, which
# only makes the ceiling more conservative).
workdir_loc_count() {
  local workdir="$1"
  find "${workdir}" -type f -not -path '*/.git/*' -print0 \
    | xargs -0 cat 2>/dev/null | wc -l | tr -d ' '
}

# Emit SKIP (exit 10) if the workdir exceeds either ceiling. Runs BEFORE claude
# is invoked so a skipped case never burns an API call.
enforce_size_ceiling() {
  local case_file="$1" workdir="$2"
  local max_files max_loc files loc

  max_files="$(jq -r '.size_ceiling.max_files' "${case_file}" 2>/dev/null)"
  max_loc="$(jq -r '.size_ceiling.max_loc' "${case_file}" 2>/dev/null)"
  case "${max_files}" in '' | null | *[!0-9]*) emit_error "case missing numeric size_ceiling.max_files" ;; esac
  case "${max_loc}" in '' | null | *[!0-9]*) emit_error "case missing numeric size_ceiling.max_loc" ;; esac

  files="$(workdir_file_count "${workdir}")"
  loc="$(workdir_loc_count "${workdir}")"

  if [[ "${files}" -gt "${max_files}" ]]; then
    emit_skip "workdir has ${files} files > size_ceiling.max_files=${max_files}"
  fi
  if [[ "${loc}" -gt "${max_loc}" ]]; then
    emit_skip "workdir has ${loc} loc > size_ceiling.max_loc=${max_loc}"
  fi
}

# --- per-run config override: force research.allow_web_research=false ---------

# Write/merge a per-run config into <workdir>/config/bugsweep.config.json that
# sets research.allow_web_research=false (the skill reads config relative to the
# repo it runs in), then ASSERT the on-disk value is false. Fails closed.
force_no_web_research() {
  local workdir="$1"
  local cfg_dir="${workdir}/config"
  local cfg="${cfg_dir}/bugsweep.config.json"

  mkdir -p "${cfg_dir}" || emit_error "could not create ${cfg_dir}"

  local merged
  if [[ -f "${cfg}" ]] && jq -e . "${cfg}" >/dev/null 2>&1; then
    # Preserve any existing config, override only the one field.
    merged="$(jq '.research.allow_web_research = false' "${cfg}")" \
      || emit_error "could not override allow_web_research in existing config"
  else
    merged='{"research":{"allow_web_research":false}}'
  fi
  printf '%s\n' "${merged}" >"${cfg}" || emit_error "could not write ${cfg}"

  # Assert the override actually took (catches a tampered/garbled write).
  jq -e '.research.allow_web_research == false' "${cfg}" >/dev/null 2>&1 \
    || emit_error "allow_web_research override assertion failed for ${cfg}"
}

# --- clean-tree assertion -----------------------------------------------------

# Capture HEAD before the run so we can confirm the original branch's commit did
# not move (detect-only must not commit fixes onto the user's branch).
workdir_head() {
  git -C "$1" rev-parse HEAD 2>/dev/null || true
}

# After the run, assert no tracked source was mutated and the original HEAD did
# not move. Two non-source paths are the runner's / skill's own scaffolding and
# are NOT detect-only output, so they are ignored: the per-run config override
# at config/bugsweep.config.json, and the skill's .bugsweep/ run-tree (RUN_DIRs,
# ledger, state — the skill's scratch space). Any OTHER dirty path is a real
# detect-only violation and fails closed.
#
# `git status --porcelain` lines are "XY <path>". Note git COLLAPSES a wholly
# untracked directory to its dir name (e.g. "?? config/" when the runner created
# config/ just to drop the override), so we accept either the collapsed-dir form
# or the exact override path; the same applies to the .bugsweep/ scratch tree.
assert_clean_tree() {
  local workdir="$1" head_before="$2"
  local dirty head_after

  dirty="$(git -C "${workdir}" status --porcelain 2>/dev/null \
    | grep -v -E '(^|[? ])config/(bugsweep\.config\.json)?$' \
    | grep -v -E '(^|[? ])\.bugsweep/?' || true)"
  if [[ -n "${dirty}" ]]; then
    emit_error "workdir tree is dirty after detect-only run:"$'\n'"${dirty}"
  fi

  head_after="$(workdir_head "${workdir}")"
  if [[ "${head_after}" != "${head_before}" ]]; then
    emit_error "workdir HEAD moved (${head_before} -> ${head_after}); detect-only must not commit"
  fi
}

# --- main ---------------------------------------------------------------------

main() {
  local print_cmd=0 runner="" case_file="" workdir="" out=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print-cmd) print_cmd=1; shift ;;
      --runner) runner="${2:-}"; shift 2 ;;
      --case) case_file="${2:-}"; shift 2 ;;
      --workdir) workdir="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      -h | --help) usage ;;
      *) usage ;;
    esac
  done

  [[ -n "${runner}" && -n "${case_file}" && -n "${workdir}" && -n "${out}" ]] || usage

  # Resolve the arm script (also validates --runner). Unknown -> ERROR.
  local arm_script
  case "${runner}" in
    claude_p) arm_script="${RUNNERS_DIR}/claude_p.sh" ;;
    claude_p_baseline) arm_script="${RUNNERS_DIR}/claude_p_baseline.sh" ;;
    *) emit_error "unknown --runner '${runner}' (use claude_p|claude_p_baseline)" ;;
  esac
  [[ -f "${arm_script}" ]] || emit_error "arm script not found: ${arm_script}"

  # shellcheck source=/dev/null
  source "${arm_script}"

  # --print-cmd: dry path. No claude, no workdir/jq requirements beyond paths.
  if [[ "${print_cmd}" -eq 1 ]]; then
    arm_print_cmd "${workdir}" "${out}"
    exit 0
  fi

  # Infra preconditions.
  command -v jq >/dev/null 2>&1 || emit_error "jq not found on PATH"
  [[ -f "${case_file}" ]] || emit_error "case file not found: ${case_file}"
  [[ -d "${workdir}" ]] || emit_error "workdir not found: ${workdir}"
  command -v claude >/dev/null 2>&1 || emit_error "claude CLI not found on PATH"
  mkdir -p "${out}" || emit_error "could not create out dir: ${out}"

  # Size-ceiling gate (may exit 10 / SKIP before any claude invocation).
  enforce_size_ceiling "${case_file}" "${workdir}"

  # The bugsweep arm forces+asserts allow_web_research=false; the baseline arm
  # runs no skill and reads no config, so the override does not apply there.
  if [[ "${runner}" == "claude_p" ]]; then
    force_no_web_research "${workdir}"
  fi

  local head_before
  head_before="$(workdir_head "${workdir}")"

  # Run the arm (captures report into <out>/report.md). A capture failure is an
  # infra ERROR, not a SKIP.
  arm_run "${workdir}" "${out}" || emit_error "arm '${runner}' produced no report artifact"
  [[ -f "${out}/report.md" ]] || emit_error "no report.md captured to ${out}"

  # Detect-only must not mutate source or move the branch HEAD.
  assert_clean_tree "${workdir}" "${head_before}"

  emit_ran
}

main "$@"
