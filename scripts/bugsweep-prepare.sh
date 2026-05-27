#!/usr/bin/env bash
# bugsweep-prepare.sh — get the working tree to a clean state BEFORE a scheduled bugsweep
# run, WITHOUT losing work and WITHOUT leaving anything that accumulates. Runs first.
#
# Default policy `auto` decides based on whether the uncommitted work looks ACTIVE or STALE:
#   - ACTIVE  (a git op is in progress, or the newest dirty file was touched < threshold):
#             another session appears to be working — DEFER. Do nothing, signal SKIP, and
#             let that session finish. The next scheduled cycle re-checks.
#   - STALE   (newest dirty file is >= threshold old): close the tree by committing the
#             changes as-is onto the current branch, then PROCEED. The commit is normal
#             history (recoverable, squashable), so nothing parks or piles up.
#
# It commits existing changes; it does NOT author new code to "finish" the work, and it
# NEVER discards anything.
#
# Output contract (read by the loop):
#   prints "RESULT=PROCEED"  + exit 0   -> run bugsweep
#   prints "RESULT=SKIP ..." + exit 10  -> expected defer; do NOT run bugsweep this cycle
#   die()                    + exit 1   -> real error; stop and report
#
# Settings:
#   BUGSWEEP_DIRTY_POLICY   auto (default) | stash | commit | fail
#   BUGSWEEP_IDLE_SECONDS   activity threshold in seconds (default 7200 = 2h)
#   BUGSWEEP_AUTOCLOSE_MSG  commit message prefix for closed stale work
#   (protected branches are never auto-committed onto; run the loop on a dev branch)

set -euo pipefail

POLICY="${BUGSWEEP_DIRTY_POLICY:-auto}"
IDLE_SECONDS="${BUGSWEEP_IDLE_SECONDS:-7200}"
PROTECTED="main master develop production prod release"
ts="$(date +%Y%m%d-%H%M%S)"
log(){ echo "prepare: $*"; }
die(){ echo "prepare: ERROR: $*" >&2; exit 1; }
skip(){ echo "prepare: $*"; echo "RESULT=SKIP $*"; exit 10; }
proceed(){ echo "RESULT=PROCEED"; exit 0; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"

# Portable file-mtime in epoch seconds (GNU coreutils vs BSD/macOS).
file_mtime(){
  if stat --version >/dev/null 2>&1; then stat -c %Y "$1"; else stat -f %m "$1"; fi
}

tree_dirty(){
  ! git diff --quiet || ! git diff --cached --quiet \
    || [ -n "$(git ls-files --others --exclude-standard)" ]
}

if ! tree_dirty; then
  log "working tree already clean — nothing to do"
  proceed
fi

# Newest mtime across changed/staged/untracked files (0 if none can be read, e.g. deletions).
newest_dirty_mtime(){
  local newest=0 f m
  while IFS= read -r f; do
    [ -n "$f" ] && [ -e "$f" ] || continue
    m=$(file_mtime "$f" 2>/dev/null) || continue
    case "$m" in ''|*[!0-9]*) continue;; esac
    [ "$m" -gt "$newest" ] && newest="$m"
  done < <( { git diff --name-only; git diff --cached --name-only; \
              git ls-files --others --exclude-standard; } | sort -u )
  echo "$newest"
}

close_tree(){
  local cur; cur="$(git rev-parse --abbrev-ref HEAD)"
  for p in $PROTECTED; do
    if [ "$cur" = "$p" ]; then
      die "stale work on protected branch '$cur'; run the loop on a non-protected dev branch so I can commit it safely"
    fi
  done
  local msg="${BUGSWEEP_AUTOCLOSE_MSG:-chore(bugsweep-autoclose): commit idle WIP}"
  log "committing stale work onto '$cur' to close the tree"
  git add -A
  git commit -qm "${msg} (${ts})" >/dev/null
  log "tree clean on '$cur'; idle work committed (squash/amend later if you want)"
  proceed
}

case "$POLICY" in
  auto)
    gitdir="$(git rev-parse --git-dir)"
    if [ -e "${gitdir}/index.lock" ]; then
      lock_age=$(( $(date +%s) - $(file_mtime "${gitdir}/index.lock" 2>/dev/null || echo 0) ))
      skip "a git operation is in progress (index.lock present, age ${lock_age}s) — deferring"
    fi
    newest="$(newest_dirty_mtime)"
    now="$(date +%s)"
    if [ "$newest" -gt 0 ]; then
      idle=$(( now - newest ))
      if [ "$idle" -lt "$IDLE_SECONDS" ]; then
        skip "work in progress (last touched $((idle/60))m ago, < $((IDLE_SECONDS/60))m) — deferring to the active session"
      fi
      log "no activity for $((idle/60))m (>= $((IDLE_SECONDS/60))m) — treating as stale"
    else
      log "could not read file times (e.g. deletions only) — treating as stale"
    fi
    close_tree
    ;;
  commit)
    close_tree
    ;;
  stash)
    label="bugsweep-parked-${ts}"
    log "parking work in stash '${label}' (recover with: git stash list / git stash pop)"
    git stash push -u -m "$label" >/dev/null
    proceed
    ;;
  fail)
    die "working tree not clean and BUGSWEEP_DIRTY_POLICY=fail; aborting for manual cleanup"
    ;;
  *)
    die "unknown BUGSWEEP_DIRTY_POLICY '$POLICY' (use auto|commit|stash|fail)"
    ;;
esac
