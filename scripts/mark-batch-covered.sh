#!/usr/bin/env bash
# Record one completed Hunter -> Skeptic -> Referee batch on both canonical
# progress surfaces and snapshot the exact audited Git blobs.

set -euo pipefail
export GIT_NO_LAZY_FETCH=1
export GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="${1:-}"
batch_id="${2:-}"
[ -n "$run_dir" ] && [ -d "$run_dir" ] && [ -n "$batch_id" ] \
  || die "usage: mark-batch-covered.sh <RUN_DIR> <BATCH_ID>"
case "$batch_id" in *[!A-Za-z0-9._-]*) die "mark-batch-covered: unsafe batch id" ;; esac
if ! have_python; then
  # Exact JSON + Git-object verification has no trustworthy shell-only parser.
  # Underreport and let the orchestrator finalize partial instead of forging
  # coverage or fatally stranding the run.
  echo "BATCH_COVERED=skipped_no_python"
  exit 0
fi
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || die "mark-batch-covered: not in a Git worktree"

lock_dir="${run_dir}/.batch-covered.lock"
if ! bugsweep_lock_acquire "$lock_dir" 15; then
  die "mark-batch-covered: checkpoint lock stayed busy"
fi
_mark_lock_held=1
_mark_cleanup() {
  if [ "${_mark_lock_held:-0}" = "1" ]; then
    bugsweep_lock_release "$lock_dir"
    _mark_lock_held=0
  fi
}
trap _mark_cleanup EXIT

python3 "${BUGSWEEP_SCRIPT_DIR}/_mark_batch_covered.py" "$run_dir" "$batch_id" "$repo_root"
_mark_cleanup
