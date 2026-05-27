#!/usr/bin/env bash
# bugsweep-cleanup.sh - OPTIONAL post-run merge gate (not part of the trust contract).
#
# The bugsweep skill never merges and never deletes branches by design. The human is
# the merge gate. This companion script automates that gate for repeatable or
# scheduled runs, so bugsweep/<timestamp> branches do not accumulate.
#
# It runs AFTER finalize.sh has returned you to your original branch, uses only
# plain git, and stays outside the skill's safety scripts on purpose.
#
# It will:
#   - merge the verified fix branch into a target branch (optional re-test first)
#   - delete that branch once merged
#   - prune old, abandoned bugsweep/* branches from previous runs
#   - refuse to touch a dirty tree or a protected branch unless forced
#
# Usage:
#   bash bugsweep-cleanup.sh [specific-bugsweep-branch]
#
# Settings (override via environment variables):
#   BUGSWEEP_TARGET           branch to merge fixes into (default: current branch)
#   BUGSWEEP_POLICY           merge | discard | keep (default: merge)
#   BUGSWEEP_TEST_CMD         optional re-verify before merge, e.g. "npm test"
#   BUGSWEEP_RETENTION_DAYS   force-prune abandoned branches older than N days (default: 7)
#   BUGSWEEP_ALLOW_PROTECTED  set to 1 to allow merging into main/master/etc.

set -euo pipefail

TARGET_BRANCH="${BUGSWEEP_TARGET:-$(git rev-parse --abbrev-ref HEAD)}"
POLICY="${BUGSWEEP_POLICY:-merge}"
TEST_CMD="${BUGSWEEP_TEST_CMD:-}"
RETENTION_DAYS="${BUGSWEEP_RETENTION_DAYS:-7}"
PROTECTED="main master develop production prod release"
SWEEP_ARG="${1:-}"

log() { echo "cleanup: $*"; }
die() { echo "cleanup: ERROR: $*" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"

# Never operate on a dirty tree because that risks entangling uncommitted work.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree is not clean; aborting so I don't touch uncommitted work"
fi

# Guard protected target branches unless explicitly allowed.
for protected_branch in $PROTECTED; do
  if [ "$TARGET_BRANCH" = "$protected_branch" ] && [ "${BUGSWEEP_ALLOW_PROTECTED:-0}" != "1" ]; then
    die "refusing to auto-merge into protected branch '$TARGET_BRANCH' (set BUGSWEEP_ALLOW_PROTECTED=1 to override)"
  fi
done

# Collect bugsweep branches, newest commit first. Use a read loop for macOS Bash 3.2.
SWEEPS=()
while IFS= read -r sweep_branch; do
  [ -n "$sweep_branch" ] && SWEEPS+=("$sweep_branch")
done < <(git for-each-ref --sort=-committerdate \
  --format='%(refname:short)' 'refs/heads/bugsweep/*' 2>/dev/null || true)

if [ "${#SWEEPS[@]}" -eq 0 ]; then
  log "no bugsweep/* branches found; nothing to do"
  exit 0
fi

# Decide which branch is "the run we just did".
LATEST="${SWEEP_ARG:-${SWEEPS[0]}}"
log "target branch : $TARGET_BRANCH"
log "policy        : $POLICY"
log "latest sweep  : $LATEST"

git checkout -q "$TARGET_BRANCH"

merge_branch() {
  local branch="$1"
  local ahead

  ahead=$(git rev-list --count "$TARGET_BRANCH..$branch" 2>/dev/null || echo 0)

  if [ "$ahead" -eq 0 ]; then
    log "$branch has no new fixes vs $TARGET_BRANCH - deleting"
    git branch -D "$branch" >/dev/null
    return
  fi

  if [ -n "$TEST_CMD" ]; then
    log "re-verifying $branch with: $TEST_CMD"
    git checkout -q "$branch"
    if ! bash -lc "$TEST_CMD"; then
      git checkout -q "$TARGET_BRANCH"
      log "TESTS FAILED with $branch - NOT merging; branch KEPT for manual review"
      return
    fi
    git checkout -q "$TARGET_BRANCH"
  fi

  log "merging $branch ($ahead fix commit(s)) into $TARGET_BRANCH"
  if git merge --no-ff -m "merge(bugsweep): $branch" "$branch"; then
    git branch -d "$branch" >/dev/null
    log "merged and deleted $branch"
  else
    git merge --abort 2>/dev/null || true
    log "MERGE CONFLICT on $branch - left unmerged for manual review; not deleted"
  fi
}

prune_old() {
  local branch="$1"
  local ahead
  local age_days

  ahead=$(git rev-list --count "$TARGET_BRANCH..$branch" 2>/dev/null || echo 0)
  if [ "$ahead" -eq 0 ]; then
    log "leftover $branch is fully merged - deleting"
    git branch -d "$branch" >/dev/null 2>&1 || git branch -D "$branch" >/dev/null
    return
  fi

  age_days=$(( ( $(date +%s) - $(git log -1 --format=%ct "$branch") ) / 86400 ))
  if [ "$age_days" -ge "$RETENTION_DAYS" ]; then
    log "pruning abandoned $branch (age ${age_days}d, ${ahead} unmerged commit(s))"
    git branch -D "$branch" >/dev/null
  else
    log "keeping $branch (age ${age_days}d < ${RETENTION_DAYS}d retention)"
  fi
}

# Handle the current run's branch per policy.
case "$POLICY" in
  merge)
    merge_branch "$LATEST"
    ;;
  discard)
    log "policy=discard - deleting $LATEST"
    git branch -D "$LATEST" >/dev/null
    ;;
  keep)
    log "policy=keep - leaving $LATEST for review"
    ;;
  *)
    die "unknown POLICY '$POLICY' (use merge|discard|keep)"
    ;;
esac

# Prune older leftover sweep branches from previous runs.
for branch in "${SWEEPS[@]}"; do
  [ "$branch" = "$LATEST" ] && continue
  prune_old "$branch"
done

git checkout -q "$TARGET_BRANCH"
