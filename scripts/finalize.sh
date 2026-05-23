#!/usr/bin/env bash
# bugsweep finalize: return the user to exactly where they started, with the fix
# commits quarantined on the bugsweep branch for review. Idempotent and safe.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="${1:-}"
[ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: finalize.sh <RUN_DIR>"
# Resolve to absolute so appends still work after we switch branches/cwd.
run_dir="$(cd "$run_dir" && pwd)"
# shellcheck disable=SC1090
. "${run_dir}/state.env"

require_git_repo

# Commit any stray uncommitted fix work on the bugsweep branch so switching is clean.
if ! git diff --quiet --ignore-submodules HEAD 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  git add -A >/dev/null 2>&1 || true
  git commit -m "fix(bugsweep): finalize uncommitted work" >/dev/null 2>&1 || true
fi

# Persist this run's audit coverage + risk into .bugsweep/state/ so the next run
# resumes the whole-repo frontier instead of starting blind. Best-effort: a failure
# here must never block finalize or strand the user off their branch.
if bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" persist "$run_dir" >/dev/null 2>&1; then
  log "Persisted audit coverage + risk to .bugsweep/state/ for future runs."
else
  log "WARNING: could not persist cross-run state (continuing; not fatal)."
fi

# Return the user to their original branch (the bugsweep branch is preserved).
if [ "$(current_branch)" != "$BUGSWEEP_ORIG_BRANCH" ]; then
  git checkout "$BUGSWEEP_ORIG_BRANCH" >/dev/null 2>&1 \
    || log "WARNING: could not switch back to ${BUGSWEEP_ORIG_BRANCH}; you are still on ${BUGSWEEP_BRANCH}."
fi

# Restore the user's stashed work, if any.
if [ "${BUGSWEEP_STASH_REF}" != "none" ]; then
  if git stash list | grep -q "bugsweep-autostash-${BUGSWEEP_TS}"; then
    if git stash pop >/dev/null 2>&1; then
      log "Restored your stashed work onto ${BUGSWEEP_ORIG_BRANCH}."
    else
      log "WARNING: could not auto-restore your stash. It is safe in: git stash list (bugsweep-autostash-${BUGSWEEP_TS})."
    fi
  fi
fi

printf '{"event":"finalize","branch":"%s","orig_branch":"%s"}\n' \
  "$BUGSWEEP_BRANCH" "$BUGSWEEP_ORIG_BRANCH" >> "${run_dir}/ledger.jsonl" 2>/dev/null || true

echo "FINALIZED"
echo "REVIEW_WITH=git diff ${BUGSWEEP_ORIG_BRANCH}..${BUGSWEEP_BRANCH}"
echo "REPORT=${run_dir}/report.md"
echo "BRANCH_PRESERVED=${BUGSWEEP_BRANCH}"
