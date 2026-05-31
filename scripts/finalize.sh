#!/usr/bin/env bash
# bugsweep finalize: return the user to exactly where they started, with the fix
# commits quarantined on the bugsweep branch for review. Idempotent and safe.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="${1:-}"
[ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: finalize.sh <RUN_DIR> [--autonomous]"
# Accept optional --autonomous flag (overrides state.env BUGSWEEP_MODE)
_auto_flag=""
for _arg in "$@"; do
  [ "$_arg" = "--autonomous" ] && _auto_flag="yes"
done
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

# Emit a stub report when report.md was never written (silent-failure backstop).
# A large-repo run may stall during context-build or the architectural hunt before
# the model ever reaches the report template. This backstop ensures the user always
# gets a coverage summary from on-disk state, regardless of where execution stopped.
_emit_stub_report() {
  local report="${run_dir}/report.md"
  [ -f "$report" ] && return 0          # real report exists — do not overwrite

  local covered=0 total=0
  if [ -f "${run_dir}/recon.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      covered="$(jq -r '.covered | length'         "${run_dir}/recon.json" 2>/dev/null || printf '0')"
      total="$(  jq -r '.batch_count // (.batches | length)' "${run_dir}/recon.json" 2>/dev/null || printf '0')"
    elif command -v python3 >/dev/null 2>&1; then
      covered="$(python3 -c \
        'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("covered",[])))' \
        "${run_dir}/recon.json" 2>/dev/null || printf '0')"
      total="$(python3 -c \
        'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("batch_count",len(d.get("batches",[]))))' \
        "${run_dir}/recon.json" 2>/dev/null || printf '0')"
    fi
  fi
  # Sanitise: accept only digits so arithmetic below never sees garbage.
  case "$covered" in ''|*[!0-9]*) covered=0 ;; esac
  case "$total"   in ''|*[!0-9]*) total=0   ;; esac

  local fixes
  fixes="$(count_event "${run_dir}/ledger.jsonl" "fix_committed")"

  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"

  cat > "$report" <<STUB
# bugsweep report — ${ts}
**Branch:** ${BUGSWEEP_BRANCH}   **Mode:** detect-only (partial)
**WARNING: INCOMPLETE RUN** — the model did not produce a full report. The run likely
stalled during context-build or the architectural hunt before reaching the report step.

## Summary
- Coverage: ${covered}/${total} batches — PARTIAL RUN (stalled before report)
- Fixes committed: ${fixes}
- See ledger.jsonl for the full event log

## How to review
git diff ${BUGSWEEP_ORIG_BRANCH}..${BUGSWEEP_BRANCH}
git -C . log --oneline ${BUGSWEEP_ORIG_BRANCH}..${BUGSWEEP_BRANCH}
STUB

  log "WARNING: report.md was missing — emitted a stub from on-disk state. Check ledger.jsonl."
}
_emit_stub_report

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

# --- Autonomous mode: auto-merge, push, and clean up --------------------------
# Triggered by --autonomous flag OR BUGSWEEP_MODE=autonomous in state.env.
# The invocation of --autonomous is the explicit authorization for end-to-end delivery.
_effective_mode="${_auto_flag:-}"
[ -z "$_effective_mode" ] && [ "${BUGSWEEP_MODE:-}" = "autonomous" ] && _effective_mode="yes"

if [ "$_effective_mode" = "yes" ]; then
  _fix_count="$(git rev-list --count "${BUGSWEEP_ORIG_BRANCH}..${BUGSWEEP_BRANCH}" 2>/dev/null || echo 0)"
  case "$_fix_count" in ''|*[!0-9]*) _fix_count=0 ;; esac

  _merged=no
  if [ "$_fix_count" -gt 0 ]; then
    log "Autonomous: merging ${_fix_count} fix commit(s) into ${BUGSWEEP_ORIG_BRANCH}..."
    if git merge --no-ff "$BUGSWEEP_BRANCH" \
        -m "fix(bugsweep): land ${_fix_count} verified fix(es) from ${BUGSWEEP_BRANCH}" \
        >/dev/null 2>&1; then
      _merged=yes
      log "Merged into ${BUGSWEEP_ORIG_BRANCH}."
      printf '{"event":"auto_merged","fix_count":%s}\n' "$_fix_count" \
        >> "${run_dir}/ledger.jsonl" 2>/dev/null || true
      echo "MERGED=true"
      if git push >/dev/null 2>&1; then
        log "Pushed ${BUGSWEEP_ORIG_BRANCH} to remote."
        printf '{"event":"auto_pushed"}\n' >> "${run_dir}/ledger.jsonl" 2>/dev/null || true
        echo "PUSHED=true"
      else
        log "WARNING: push failed (no remote or insufficient access). Fixes are merged locally. Run: git push"
        echo "PUSHED=false"
      fi
    else
      log "WARNING: auto-merge failed (possible conflicts). Fixes preserved on ${BUGSWEEP_BRANCH} — merge manually."
      echo "MERGE_FAILED=true"
      echo "BRANCH_PRESERVED=${BUGSWEEP_BRANCH}"
    fi
  else
    log "No fix commits to merge (detect-only run)."
    _merged=yes
    echo "MERGED=skipped"
  fi

  if [ "$_merged" = "yes" ]; then
    if git branch -d "$BUGSWEEP_BRANCH" >/dev/null 2>&1; then
      log "Deleted ${BUGSWEEP_BRANCH}."
      echo "BRANCH_DELETED=${BUGSWEEP_BRANCH}"
    else
      log "NOTE: could not auto-delete ${BUGSWEEP_BRANCH}. Run: git branch -d ${BUGSWEEP_BRANCH}"
      echo "BRANCH_PRESERVED=${BUGSWEEP_BRANCH}"
    fi
  fi
else
  echo "BRANCH_PRESERVED=${BUGSWEEP_BRANCH}"
fi
