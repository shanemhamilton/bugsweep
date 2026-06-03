#!/usr/bin/env bash
# bugsweep-cleanup.sh — OPTIONAL post-run merge gate (not part of the core hunt loop).
#
# The bugsweep skill still stops at the human merge gate. This companion runs only after
# finalize, when the user or scheduler has approved the continuation. It can merge the
# preserved bugsweep branch, re-run a configured check, and delete branches that are proven
# contained in the target branch. It never force-pushes, never force-removes worktrees, and
# never deletes dirty worktrees.
#
# Usage:
#   bash bugsweep-cleanup.sh [specific-bugsweep-branch]
#
# Settings (override via environment variables):
#   BUGSWEEP_TARGET           branch to merge fixes into (default: current branch)
#   BUGSWEEP_POLICY           merge | discard | keep   (default: merge)
#   BUGSWEEP_TEST_CMD         optional re-verify before merge, e.g. "npm test"
#   BUGSWEEP_RETENTION_DAYS   retained for compatibility; unmerged branches are preserved
#   BUGSWEEP_ALLOW_PROTECTED  set to 1 to allow merging into main/master/etc.

set -euo pipefail

POLICY="${BUGSWEEP_POLICY:-merge}"
TEST_CMD="${BUGSWEEP_TEST_CMD:-}"
RETENTION_DAYS="${BUGSWEEP_RETENTION_DAYS:-7}"
PROTECTED="main master develop production prod release"
SWEEP_ARG="${1:-}"
TARGET_BRANCH=""
RESULT=""
EXIT_STATUS=0
BRANCH_DELETED_LINES=""
BRANCH_PRESERVED_LINES=""
WORKTREE_REMOVED_LINES=""

log(){ echo "cleanup: $*"; }

record_deleted(){
  if [ -n "$BRANCH_DELETED_LINES" ]; then
    BRANCH_DELETED_LINES="${BRANCH_DELETED_LINES}
$1"
  else
    BRANCH_DELETED_LINES="$1"
  fi
}

record_preserved(){
  if [ -n "$BRANCH_PRESERVED_LINES" ]; then
    BRANCH_PRESERVED_LINES="${BRANCH_PRESERVED_LINES}
$1"
  else
    BRANCH_PRESERVED_LINES="$1"
  fi
}

record_worktree_removed(){
  if [ -n "$WORKTREE_REMOVED_LINES" ]; then
    WORKTREE_REMOVED_LINES="${WORKTREE_REMOVED_LINES}
$1"
  else
    WORKTREE_REMOVED_LINES="$1"
  fi
}

emit_list() {
  local prefix="$1" values="$2" value
  [ -n "$values" ] || return 0
  while IFS= read -r value; do
    [ -n "$value" ] && echo "${prefix}=${value}"
  done <<EOF
$values
EOF
}

finish() {
  local status="${1:-$EXIT_STATUS}"
  [ -n "$RESULT" ] || RESULT="kept_for_review"
  echo "CLEANUP_RESULT=${RESULT}"
  emit_list "BRANCH_DELETED" "$BRANCH_DELETED_LINES"
  emit_list "BRANCH_PRESERVED" "$BRANCH_PRESERVED_LINES"
  emit_list "WORKTREE_REMOVED" "$WORKTREE_REMOVED_LINES"
  [ -n "$TARGET_BRANCH" ] && echo "TARGET_BRANCH=${TARGET_BRANCH}"
  exit "$status"
}

fail_preserved() {
  local message="$1" branch="${2:-}"
  log "$message"
  [ -n "$branch" ] && record_preserved "$branch"
  RESULT="kept_for_review"
  finish 1
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  log "ERROR: not inside a git repo"
  RESULT="kept_for_review"
  finish 1
}

if [ -n "${BUGSWEEP_TARGET:-}" ]; then
  TARGET_BRANCH="$BUGSWEEP_TARGET"
else
  TARGET_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
fi

if [ "$TARGET_BRANCH" = "HEAD" ] || [ -z "$TARGET_BRANCH" ]; then
  fail_preserved "refusing cleanup from a detached HEAD"
fi

branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1"
}

branch_contained_in_target() {
  git merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

worktree_for_branch() {
  local branch="$1" line path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ *)
        if [ "${line#branch }" = "refs/heads/${branch}" ]; then
          printf '%s\n' "$path"
          return 0
        fi
        ;;
    esac
  done < <(git worktree list --porcelain)
  return 1
}

worktree_is_clean() {
  local path="$1" untracked
  git -C "$path" diff --quiet || return 1
  git -C "$path" diff --cached --quiet || return 1
  untracked="$(git -C "$path" ls-files --others --exclude-standard)"
  [ -z "$untracked" ]
}

delete_contained_branch() {
  local branch="$1" target="$2" linked=""

  if ! branch_exists "$branch"; then
    log "$branch no longer exists"
    return 0
  fi

  if ! branch_contained_in_target "$branch" "$target"; then
    log "$branch is not contained in $target — preserving"
    record_preserved "$branch"
    return 2
  fi

  if git branch -d "$branch" >/dev/null 2>&1; then
    log "deleted contained branch $branch"
    record_deleted "$branch"
    return 0
  fi

  linked="$(worktree_for_branch "$branch" || true)"
  if [ -z "$linked" ]; then
    log "could not delete $branch even though it is contained — preserving"
    record_preserved "$branch"
    return 1
  fi

  log "$branch is checked out in linked worktree: $linked"
  if ! worktree_is_clean "$linked"; then
    log "linked worktree is dirty — preserving $branch and $linked"
    record_preserved "$branch"
    return 1
  fi

  if git worktree remove "$linked" >/dev/null 2>&1; then
    log "removed clean linked worktree $linked"
    record_worktree_removed "$linked"
  else
    log "git worktree remove failed for $linked — preserving $branch"
    record_preserved "$branch"
    return 1
  fi

  if git branch -d "$branch" >/dev/null 2>&1; then
    log "deleted contained branch $branch"
    record_deleted "$branch"
    return 0
  fi

  log "could not delete $branch after removing clean worktree — preserving"
  record_preserved "$branch"
  return 1
}

discard_branch() {
  local branch="$1" linked=""

  if ! branch_exists "$branch"; then
    log "$branch no longer exists"
    return 0
  fi

  linked="$(worktree_for_branch "$branch" || true)"
  if [ -n "$linked" ]; then
    log "$branch is checked out in linked worktree: $linked"
    if ! worktree_is_clean "$linked"; then
      log "linked worktree is dirty — preserving $branch and $linked"
      record_preserved "$branch"
      return 1
    fi
    if git worktree remove "$linked" >/dev/null 2>&1; then
      log "removed clean linked worktree $linked"
      record_worktree_removed "$linked"
    else
      log "git worktree remove failed for $linked — preserving $branch"
      record_preserved "$branch"
      return 1
    fi
  fi

  if git branch -D "$branch" >/dev/null 2>&1; then
    log "discarded $branch by explicit policy"
    record_deleted "$branch"
    return 0
  fi

  log "could not discard $branch — preserving"
  record_preserved "$branch"
  return 1
}

# Never operate on a dirty tree — don't risk entangling uncommitted work.
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  fail_preserved "working tree is not clean; aborting so I don't touch uncommitted work"
fi

# Guard protected target branches unless explicitly allowed.
for p in $PROTECTED; do
  if [ "$TARGET_BRANCH" = "$p" ] && [ "${BUGSWEEP_ALLOW_PROTECTED:-0}" != "1" ]; then
    fail_preserved "refusing to auto-merge into protected branch '$TARGET_BRANCH' (set BUGSWEEP_ALLOW_PROTECTED=1 to override)"
  fi
done

if ! git checkout -q "$TARGET_BRANCH"; then
  fail_preserved "could not check out target branch '$TARGET_BRANCH'"
fi

# Collect bugsweep branches, newest commit first.
# Use a read loop so macOS Bash 3.2 can run this script.
SWEEPS=()
while IFS= read -r sweep_branch; do
  [ -n "$sweep_branch" ] && SWEEPS+=("$sweep_branch")
done < <(git for-each-ref --sort=-committerdate \
  --format='%(refname:short)' 'refs/heads/bugsweep/*' 2>/dev/null || true)

if [ "${#SWEEPS[@]}" -eq 0 ]; then
  log "no bugsweep/* branches found; nothing to do"
  RESULT="kept_for_review"
  finish 0
fi

LATEST="${SWEEP_ARG:-${SWEEPS[0]}}"
if ! branch_exists "$LATEST"; then
  fail_preserved "bugsweep branch not found: $LATEST" "$LATEST"
fi

log "target branch : $TARGET_BRANCH"
log "policy        : $POLICY"
log "latest sweep  : $LATEST"

merge_branch() {
  local branch="$1" ahead

  if branch_contained_in_target "$branch" "$TARGET_BRANCH"; then
    log "$branch is already contained in $TARGET_BRANCH"
    if delete_contained_branch "$branch" "$TARGET_BRANCH"; then
      RESULT="merged_deleted"
      return 0
    fi
    RESULT="merged_branch_preserved"
    return 0
  fi

  ahead=$(git rev-list --count "$TARGET_BRANCH..$branch" 2>/dev/null || echo 0)

  if [ -n "$TEST_CMD" ]; then
    log "re-verifying $branch with: $TEST_CMD"
    if ! git checkout -q "$branch"; then
      git checkout -q "$TARGET_BRANCH" >/dev/null 2>&1 || true
      log "could not check out $branch for re-verification — preserving"
      record_preserved "$branch"
      RESULT="tests_failed"
      return 1
    fi
    if ! bash -lc "$TEST_CMD"; then
      git checkout -q "$TARGET_BRANCH" >/dev/null 2>&1 || true
      log "TESTS FAILED on $branch — NOT merging; branch kept for manual review"
      record_preserved "$branch"
      RESULT="tests_failed"
      return 1
    fi
    git checkout -q "$TARGET_BRANCH"
  fi

  log "merging $branch (${ahead} fix commit(s)) into $TARGET_BRANCH"
  if git merge --no-ff -m "merge(bugsweep): $branch" "$branch"; then
    if delete_contained_branch "$branch" "$TARGET_BRANCH"; then
      RESULT="merged_deleted"
      return 0
    fi
    RESULT="merged_branch_preserved"
    return 0
  fi

  git merge --abort >/dev/null 2>&1 || true
  log "MERGE CONFLICT on $branch — left unmerged for manual review; not deleted"
  record_preserved "$branch"
  RESULT="conflict"
  return 1
}

prune_old() {
  local branch="$1"
  if branch_contained_in_target "$branch" "$TARGET_BRANCH"; then
    log "leftover $branch is contained in $TARGET_BRANCH"
    delete_contained_branch "$branch" "$TARGET_BRANCH" || true
  else
    log "keeping unmerged leftover $branch (retention=${RETENTION_DAYS}d; unmerged branches require explicit discard)"
    record_preserved "$branch"
  fi
}

# Handle the current run's branch per policy.
case "$POLICY" in
  merge)
    if ! merge_branch "$LATEST"; then
      finish 1
    fi
    ;;
  discard)
    log "policy=discard — deleting $LATEST only because discard was explicit"
    if discard_branch "$LATEST"; then
      RESULT="discarded"
    else
      RESULT="kept_for_review"
      finish 1
    fi
    ;;
  keep)
    log "policy=keep — leaving $LATEST for review"
    record_preserved "$LATEST"
    RESULT="kept_for_review"
    ;;
  *)
    fail_preserved "unknown POLICY '$POLICY' (use merge|discard|keep)" "$LATEST"
    ;;
esac

# Prune older leftover sweep branches from previous runs only when already contained.
for branch in "${SWEEPS[@]}"; do
  [ "$branch" = "$LATEST" ] && continue
  prune_old "$branch"
done

git checkout -q "$TARGET_BRANCH" >/dev/null 2>&1 || true
log "done. remaining bugsweep branches:"
git for-each-ref --format='  %(refname:short)' 'refs/heads/bugsweep/*' 2>/dev/null || true

finish 0
