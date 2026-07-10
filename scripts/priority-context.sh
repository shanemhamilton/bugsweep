#!/usr/bin/env bash
# Deterministic, local-only priority evidence for Bugsweep.
#
#   priority-context.sh build <RUN_DIR>
#     Run after baseline checks. Writes <RUN_DIR>/priority-context.json from
#     bounded local Git history/diffs, audit fingerprints, baseline failures,
#     reachability, variants/reopened conclusions, local Beads bugs, and an
#     optional project-local .bugsweep/priority-signals.jsonl inbox.
#
#   priority-context.sh apply <RUN_DIR>
#     Run after context-build has seeded/re-tiered recon.json. Reorders existing
#     batches and performs bounded hard-focus promotions without adding,
#     deleting, or duplicating any batch/file.
#
# This script never calls a tracker CLI or a Git remote operation. Every source
# is advisory, untrusted data: it can change investigation order, never confirm
# a finding or relax Bugsweep's fix/merge gates.

set -euo pipefail
# Partial/promisor clones may otherwise lazily fetch objects for seemingly
# local `log`/`diff`/`cat-file` reads. Local-only means missing objects degrade.
export GIT_NO_LAZY_FETCH=1
export GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [ -n "${_PRIORITY_TEST_CONFIG_OVERRIDE:-}" ]; then
  # shellcheck disable=SC2034
  BUGSWEEP_CONFIG="$_PRIORITY_TEST_CONFIG_OVERRIDE"
fi

command_name="${1:-}"
run_dir="${2:-}"
[ -n "$command_name" ] && [ -n "$run_dir" ] && [ -d "$run_dir" ] \
  || die "usage: priority-context.sh <build|apply> <RUN_DIR>"
run_dir="$(cd "$run_dir" && pwd)"
out="${run_dir}/priority-context.json"

_write_degraded() {
  local reason="${1:-unavailable}" degraded_tmp
  degraded_tmp="$(mktemp "${run_dir}/.priority-context.degraded.XXXXXX")" \
    || die "priority-context: cannot create degraded artifact temp file"
  printf '%s\n' \
    '{' \
    '  "degraded": true,' \
    '  "generated_from": {"head": null, "previous_run_head": null, "prior_runs": 0},' \
    '  "project_signals": {"baseline_stability": "unknown", "external_signal_count": 0, "failing_checks": [], "mapped_local_issue_count": 0, "no_checks": false, "overmatched_globs": [], "signal_health": {"accepted": 0, "expired": 0, "inactive": 0, "malformed": 0, "overmatched": 0, "unmapped": 0}, "signal_yield": [], "unmapped_focus_signals": []},' \
    '  "promotion_budget": {"max_batches": 0, "max_files": 0},' \
    '  "promotion_candidates": [],' \
    '  "recent_repairs": [],' \
    '  "schema_version": 1,' \
    '  "scope_contract": "priority_only_whole_repo_remains_in_scope",' \
    "  \"source_status\": {\"collector\": \"$(_bsw_json_escape "$reason")\"}," \
    '  "targets": [],' \
    '  "truncated": {"reasons_omitted": 0, "targets_omitted": 0}' \
    '}' > "$degraded_tmp"
  mv -f -- "$degraded_tmp" "$out"
}

case "$command_name" in
  build)
    if ! have_python; then
      _write_degraded "python_unavailable"
      echo "PRIORITY_CONTEXT=${out}"
      exit 0
    fi
    command -v git >/dev/null 2>&1 || {
      _write_degraded "git_unavailable"
      echo "PRIORITY_CONTEXT=${out}"
      exit 0
    }
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    common_root="${BUGSWEEP_REPO_ROOT:-$repo_root}"
    if [ -z "$repo_root" ] || [ -z "$common_root" ]; then
      _write_degraded "not_a_git_repo"
      echo "PRIORITY_CONTEXT=${out}"
      exit 0
    fi

    history_path="$(mktemp "${run_dir}/.priority-git-history.XXXXXX")" || {
      _write_degraded "history_temp_failed"
      echo "PRIORITY_CONTEXT=${out}"
      exit 0
    }
    _priority_history_cleanup() { rm -f -- "$history_path"; }
    trap _priority_history_cleanup EXIT
    if [ -f "${BUGSWEEP_SCRIPT_DIR}/git-history-risk.sh" ]; then
      bash "${BUGSWEEP_SCRIPT_DIR}/git-history-risk.sh" "$repo_root" > "$history_path" 2>/dev/null || true
    fi
    current_head="$(_bsw_state_env_get "${run_dir}/state.env" BUGSWEEP_ORIG_HEAD)"
    current_branch="$(_bsw_state_env_get "${run_dir}/state.env" BUGSWEEP_ORIG_BRANCH)"
    reference_epoch="$(_bsw_state_env_get "${run_dir}/state.env" BUGSWEEP_START_EPOCH)"

    if ! python3 "${BUGSWEEP_SCRIPT_DIR}/_priority_context.py" build \
      --repo "$repo_root" \
      --common-root "$common_root" \
      --run-dir "$run_dir" \
      --config "$BUGSWEEP_CONFIG" \
      --history "$history_path" \
      --output "$out" \
      --current-head "$current_head" \
      --branch "$current_branch" \
      --reference-epoch "$reference_epoch"; then
      log "priority-context: one or more local collectors failed; using a degraded empty artifact."
      _write_degraded "collector_failed"
    fi

    counts="$(python3 - "$out" <<'PY' 2>/dev/null || printf '0 0'
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d.get("targets", [])), len(d.get("promotion_candidates", [])))
PY
)"
    targets_count="${counts%% *}"
    promotions_count="${counts#* }"
    case "$targets_count" in ''|*[!0-9]*) targets_count=0 ;; esac
    case "$promotions_count" in ''|*[!0-9]*) promotions_count=0 ;; esac
    printf '{"event":"priority_context_built","targets":%s,"promotion_candidates":%s}\n' \
      "$targets_count" "$promotions_count" >> "${run_dir}/ledger.jsonl" 2>/dev/null || true
    echo "PRIORITY_CONTEXT=${out}"
    ;;
  apply)
    if ! have_python; then
      log "priority-context: python3 unavailable; leaving recon.json unchanged (whole-repo fallback)."
      echo "PRIORITY_APPLIED=skipped_degraded"
      exit 0
    fi
    if python3 "${BUGSWEEP_SCRIPT_DIR}/_priority_context.py" apply --run-dir "$run_dir"; then
      echo "PRIORITY_APPLIED=${run_dir}/recon.json"
    else
      log "priority-context: apply failed; leaving the existing recon plan as the source of truth."
      echo "PRIORITY_APPLIED=skipped_error"
    fi
    ;;
  *)
    die "usage: priority-context.sh <build|apply> <RUN_DIR>"
    ;;
esac
