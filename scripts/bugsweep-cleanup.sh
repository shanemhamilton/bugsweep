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
#   bash bugsweep-cleanup.sh --reap-worktrees
#
# Settings (override via environment variables):
#   BUGSWEEP_TARGET           branch to merge fixes into (default: current branch)
#   BUGSWEEP_POLICY           merge | discard | keep   (default: merge)
#   BUGSWEEP_TEST_CMD         optional re-verify before merge, e.g. "npm test"
#   BUGSWEEP_RETENTION_DAYS   retained for compatibility; unmerged branches are preserved
#   BUGSWEEP_ALLOW_PROTECTED  set to 1 to allow merging into main/master/etc.
#
# --reap-worktrees is the non-merge safety reaper used by preflight/finalize:
# it removes only bugsweep-managed linked worktrees under .bugsweep/worktrees,
# skips live leased siblings, commits dirty worktree content to its own branch
# before removal, prunes only contained branch refs, and never touches remotes.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

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
WORKTREE_PRESERVED_LINES=""
WORKTREE_OUT_OF_SCOPE_LINES=""
REAP_WORKTREES="no"

if [ "${1:-}" = "--reap-worktrees" ]; then
  REAP_WORKTREES="yes"
  shift
  SWEEP_ARG="${1:-}"
fi

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

record_worktree_preserved(){
  if [ -n "$WORKTREE_PRESERVED_LINES" ]; then
    WORKTREE_PRESERVED_LINES="${WORKTREE_PRESERVED_LINES}
$1"
  else
    WORKTREE_PRESERVED_LINES="$1"
  fi
}

# MAJOR D (bugsweep-8d0 dataloss review): a bugsweep worktree that is out of
# this reaper's remove scope (off the canonical path, or an unregistered
# directory) must never be silently invisible in the output — record it so
# the count/accounting invariant holds even for things we deliberately don't
# touch.
record_worktree_out_of_scope(){
  if [ -n "$WORKTREE_OUT_OF_SCOPE_LINES" ]; then
    WORKTREE_OUT_OF_SCOPE_LINES="${WORKTREE_OUT_OF_SCOPE_LINES}
$1"
  else
    WORKTREE_OUT_OF_SCOPE_LINES="$1"
  fi
}

count_list() {
  local values="$1"
  [ -n "$values" ] || { echo 0; return 0; }
  printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' '
}

canonical_path() {
  local path="$1"
  if [ -d "$path" ]; then
    ( cd "$path" && pwd -P )
  else
    printf '%s\n' "$path"
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

# BLOCKER B (bugsweep-8d0 dataloss review): --reap-worktrees must NEVER
# resolve its containment target from the caller's ambient cwd HEAD — see
# resolve_pinned_target_branch() below. Skip the cwd-derived default (and the
# detached-HEAD guard that only makes sense for it) entirely in reap mode; the
# reaper does not need the invoking shell's checkout to be on any particular
# branch at all.
if [ -n "${BUGSWEEP_TARGET:-}" ]; then
  TARGET_BRANCH="$BUGSWEEP_TARGET"
elif [ "$REAP_WORKTREES" != "yes" ]; then
  TARGET_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
fi

if [ "$REAP_WORKTREES" != "yes" ] && { [ "$TARGET_BRANCH" = "HEAD" ] || [ -z "$TARGET_BRANCH" ]; }; then
  fail_preserved "refusing cleanup from a detached HEAD"
fi

branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1"
}

branch_contained_in_target() {
  git merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

# BLOCKER B fix: resolve a containment target that is completely independent
# of the CALLER's cwd/checkout. Unlike merge-mode's deliberate "default to
# whatever branch I'm on" (a human explicitly runs this script from their
# intended target), --reap-worktrees runs unattended from preflight/finalize,
# invoked from whatever branch or linked worktree the calling shell happens
# to be sitting in. Resolving TARGET_BRANCH from `git rev-parse --abbrev-ref
# HEAD` in that context can prove containment against the wrong branch
# entirely (e.g. a sibling worktree's own feature branch that happens to
# descend from an unreviewed bugsweep branch) and delete a fix that was never
# merged into the real integration target.
#
# An explicit BUGSWEEP_TARGET is still honored — a caller who names the
# target means it. Absent that, pin to the repo's default branch: the first
# configured protected branch that actually exists (main/master/... — see
# $PROTECTED), independent of cwd.
#
# bugsweep-8d0 dataloss re-review MAJOR 2: the last resort is EMPTY — NEVER
# the caller's cwd HEAD. An earlier revision fell back to `git rev-parse
# --abbrev-ref HEAD`, which reintroduced the exact bug BLOCKER B set out to
# kill: in a repo whose default branch is not in $PROTECTED (e.g. `trunk`)
# with a worktree that has no recorded run mapping, the pin became the
# ambient checkout, and an unreviewed branch merged only into THAT incidental
# cwd branch got deleted though the real integration target never received
# it. "No cwd-independent target resolvable" now means "cannot prove
# containment safely" — the caller (reap_one_worktree) must PRESERVE the
# branch rather than delete it against ambient ancestry. Empty output is that
# signal.
resolve_pinned_target_branch() {
  if [ -n "${BUGSWEEP_TARGET:-}" ]; then
    printf '%s' "$BUGSWEEP_TARGET"
    return 0
  fi
  local p
  for p in $PROTECTED; do
    if branch_exists "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf ''
}

# Per-worktree containment target (BLOCKER B, alternate precision path): when
# a run_dir mapping is known for a worktree, its OWN recorded
# BUGSWEEP_ORIG_BRANCH is the most precise proof of "the real integration
# target this fix was meant for" — more precise than the single repo-wide
# pinned default, since different runs may have started from different
# branches. Falls back (empty output, caller substitutes the pinned default)
# when no mapping or no recorded value exists.
orig_branch_for_run_dir() {
  local run_dir="$1" value
  [ -n "$run_dir" ] && [ -f "${run_dir}/state.env" ] || return 1
  value="$(sed -n 's/^BUGSWEEP_ORIG_BRANCH=//p' "${run_dir}/state.env" | head -1)"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# Snapshot of every currently-recorded lease's run_dir, taken BEFORE this
# call's stale-lease reclaim pass (MEDIUM F: needed to scope LEASES_RELEASED
# to worktrees this call actually processed, rather than every lease
# reclaimed repo-wide).
lease_run_dirs_snapshot() {
  local leases="${BUGSWEEP_REPO_ROOT}/.bugsweep/state/leases" f run_dir
  [ -d "$leases" ] || return 0
  for f in "$leases"/*.json; do
    [ -e "$f" ] || continue
    run_dir="$(sed -n 's/.*"run_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)"
    [ -n "$run_dir" ] && printf '%s\n' "$run_dir"
  done
}

# Portable mtime (epoch seconds) of a path, or empty if it can't be read —
# same idiom as state.sh's _file_mtime, duplicated here in cleanup.sh (not
# state.sh) because it answers a different question: the AGE of a worktree
# directory on disk, not a lease file's liveness.
_bsw_path_mtime() {
  local path="$1" m
  [ -e "$path" ] || { printf ''; return 0; }
  if stat --version >/dev/null 2>&1; then
    m="$(stat -c %Y "$path" 2>/dev/null || true)"
  else
    m="$(stat -f %m "$path" 2>/dev/null || true)"
  fi
  case "$m" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$m" ;; esac
}

# The lease-reclaim grace window (state.sh's BUGSWEEP_LEASE_GRACE_SECONDS,
# default 900s). The reaper aligns its OWN eligibility windows to this single
# source of truth: it must never consider a run reapable before the lease
# subsystem itself would consider that run's lease reclaimable, or it races a
# still-heartbeating live run. Sanitised to a positive integer; falls back to
# 900 on any garbage.
_bsw_grace_seconds() {
  local g="${BUGSWEEP_LEASE_GRACE_SECONDS:-900}"
  case "$g" in ''|*[!0-9]*) g=900 ;; esac
  [ "$g" -gt 0 ] 2>/dev/null || g=900
  printf '%s' "$g"
}

# Minimum-age floor helper. Returns 0 (true — "younger than min_age, must be
# preserved") when the worktree's age is unknown (ambiguous -> preserve, same
# rule as everywhere else) or younger than min_age; returns 1 only when the
# directory is provably at least min_age old.
#
# bugsweep-8d0 dataloss re-review MAJOR 1a: the DEFAULT floor is now the lease
# grace window (>= BUGSWEEP_LEASE_GRACE_SECONDS), NOT the old 120s. A live run
# in one long (>grace) read-only hunt iteration writes nothing to its worktree
# root and its lease goes stale; a sub-grace floor made that live worktree
# reapable. Deriving the floor from the grace window means a run is never
# eligible before the lease system itself would treat its lease as reclaimable.
worktree_younger_than_floor() {
  local path="$1" min_age="$2" mtime now age
  mtime="$(_bsw_path_mtime "$path")"
  [ -n "$mtime" ] || return 0
  now="$(date +%s)"
  age=$(( now - mtime ))
  [ "$age" -lt "$min_age" ]
}

# bugsweep-8d0 dataloss re-review MAJOR 1b: the run's ledger.jsonl is the
# authoritative liveness signal DURING a hunt — guard.sh appends
# batch_covered / iteration events to it as the run makes progress (and
# preflight seeds it). If it was written within the grace window, the run is
# active and its worktree MUST be preserved, even if its lease lapsed (the
# heartbeat and the ledger can both fall silent inside one long iteration, but
# treating a within-grace ledger as "alive" is the conservative, data-safe
# read). Returns 0 (true, "active") only when ledger.jsonl exists AND its
# mtime is within the window; an absent ledger is NOT active (returns 1), so a
# genuinely dead run with no ledger is still reapable.
ledger_active_within() {
  local run_dir="$1" window="$2" ledger mtime now
  [ -n "$run_dir" ] || return 1
  ledger="${run_dir}/ledger.jsonl"
  [ -f "$ledger" ] || return 1
  mtime="$(_bsw_path_mtime "$ledger")"
  [ -n "$mtime" ] || return 1
  now="$(date +%s)"
  [ $(( now - mtime )) -lt "$window" ]
}

run_dir_for_worktree() {
  local worktree="$1" state_file run_dir value
  worktree="$(canonical_path "$worktree")"
  for state_file in "${BUGSWEEP_REPO_ROOT}/.bugsweep"/run-*/state.env; do
    [ -f "$state_file" ] || continue
    value="$(sed -n 's/^BUGSWEEP_WORKTREE=//p' "$state_file" | head -1)"
    [ -n "$value" ] && value="$(canonical_path "$value")"
    if [ "$value" = "$worktree" ]; then
      run_dir="$(dirname "$state_file")"
      printf '%s\n' "$run_dir"
      return 0
    fi
  done
  return 1
}

run_dir_is_live() {
  local run_dir="$1" live_file="$2"
  [ -n "$run_dir" ] || return 1
  grep -qxF "$run_dir" "$live_file" 2>/dev/null
}

# bugsweep-cv0: run_dir_for_worktree() stops at the FIRST run-*/state.env
# that names a given worktree. Every real run mints a unique run_dir, so in
# production exactly one state.env ever maps a worktree. But if an operator
# manually copies a .bugsweep/run-* directory, TWO state.env files can name
# the SAME worktree — and trusting only the first match's liveness (or,
# further down, its ".finalized" sentinel) would silently ignore a second,
# genuinely live-leased run_dir mapping that same worktree. This scans EVERY
# state.env naming the worktree and reports whether ANY of them is live, so
# the DONE/.finalized reap path can never bypass a live lease just because it
# wasn't the lexically-first match.
any_run_dir_for_worktree_is_live() {
  local worktree="$1" live_file="$2" state_file value candidate
  worktree="$(canonical_path "$worktree")"
  for state_file in "${BUGSWEEP_REPO_ROOT}/.bugsweep"/run-*/state.env; do
    [ -f "$state_file" ] || continue
    value="$(sed -n 's/^BUGSWEEP_WORKTREE=//p' "$state_file" | head -1)"
    [ -n "$value" ] && value="$(canonical_path "$value")"
    if [ "$value" = "$worktree" ]; then
      candidate="$(dirname "$state_file")"
      run_dir_is_live "$candidate" "$live_file" && return 0
    fi
  done
  return 1
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
  local path="$1" untracked ignored
  git -C "$path" diff --quiet || return 1
  git -C "$path" diff --cached --quiet || return 1
  untracked="$(git -C "$path" ls-files --others --exclude-standard)"
  [ -z "$untracked" ] || return 1
  # MAJOR E fix (bugsweep-8d0 dataloss review): `ls-files --others
  # --exclude-standard` (above) respects .gitignore, so gitignored-but-present
  # content (build output, node_modules, debug logs) was previously invisible
  # to this clean-check — and to the `git add -A` commit-before-remove path
  # below, which ALSO respects .gitignore — so it got silently deleted by
  # `git worktree remove` with no commit, no warning, no trace. Treat it as
  # dirty too.
  ignored="$(git -C "$path" ls-files --others --ignored --exclude-standard)"
  [ -z "$ignored" ]
}

ensure_worktree_clean_or_committed() {
  local path="$1" branch="$2" ignored
  if worktree_is_clean "$path"; then
    return 0
  fi

  log "$branch has dirty worktree content; committing it before removal"
  if git -C "$path" add -A >/dev/null 2>&1 \
    && git -C "$path" commit -m "chore(bugsweep): preserve dirty worktree before cleanup" >/dev/null 2>&1; then
    # MAJOR E fix: `git add -A` respects .gitignore just like the dirty-check
    # does, so a successful commit here NEVER captures gitignored content —
    # it may have committed OTHER (tracked/non-ignored) changes just fine
    # while ignored content remains uncommitted. Re-check and refuse to let
    # the caller proceed to `git worktree remove` if any remains, instead of
    # silently discarding it.
    ignored="$(git -C "$path" ls-files --others --ignored --exclude-standard 2>/dev/null || true)"
    if [ -n "$ignored" ]; then
      log "$branch worktree still has gitignored content that cannot be committed — preserving instead of removing: $(printf '%s' "$ignored" | tr '\n' ' ')"
      return 1
    fi
    return 0
  fi

  ignored="$(git -C "$path" ls-files --others --ignored --exclude-standard 2>/dev/null || true)"
  if [ -n "$ignored" ]; then
    log "$branch has gitignored content that git cannot commit — preserving worktree so nothing is silently discarded: $(printf '%s' "$ignored" | tr '\n' ' ')"
  else
    log "could not commit dirty content in $path — preserving worktree"
  fi
  return 1
}

# BLOCKER C fix (bugsweep-8d0 dataloss review): the worktree directory may
# have been removed out-of-band while git still has it registered (`git
# worktree list` still reports it — this is exactly what git calls
# "prunable"). This MUST be resolved (branch containment decided) BEFORE `git
# worktree prune` (called once, after the whole reap_worktrees loop) erases
# the registration — otherwise a possibly-unreviewed branch becomes a
# permanent orphan no future reaper pass ever revisits, because nothing links
# it to a worktree anymore. `--force` is safe here specifically because the
# directory is already gone: there is no uncommitted content left to lose by
# forcing the registration away.
reap_missing_worktree() {
  local path="$1" branch="$2" target="$3"
  log "worktree directory is missing for $branch ($path) — resolving branch containment before the registration is pruned"

  # MAJOR 2: with no cwd-independent target, never prove containment against an
  # ambient HEAD — clear the dead registration but PRESERVE the branch ref.
  if [ -z "$target" ] && branch_exists "$branch"; then
    log "no cwd-independent containment target for missing-directory branch $branch — preserving branch ref, clearing only the stale registration"
    git worktree remove --force "$path" >/dev/null 2>&1 \
      || log "could not clear stale worktree registration for $path — it may be cleared by a later 'git worktree prune'"
    record_preserved "$branch"
    return 0
  fi

  if branch_exists "$branch" && branch_contained_in_target "$branch" "$target"; then
    if git worktree remove --force "$path" >/dev/null 2>&1; then
      log "cleared stale worktree registration for missing directory $path"
    else
      log "could not clear stale worktree registration for $path (will retry via 'git worktree prune')"
    fi
    if git branch -d "$branch" >/dev/null 2>&1; then
      log "deleted contained branch $branch (worktree directory was already gone)"
      record_deleted "$branch"
    else
      log "could not delete contained branch $branch after clearing missing worktree — preserving ref"
      record_preserved "$branch"
    fi
  elif branch_exists "$branch"; then
    log "worktree directory for unmerged branch $branch is missing — preserving the branch ref (not contained in $target)"
    if git worktree remove --force "$path" >/dev/null 2>&1; then
      log "cleared stale worktree registration for missing directory $path (branch ref preserved)"
    else
      log "could not clear stale worktree registration for $path — it may be cleared by a later 'git worktree prune'"
    fi
    record_preserved "$branch"
  else
    log "worktree directory for $branch is missing and the branch no longer exists — nothing to preserve"
    git worktree remove --force "$path" >/dev/null 2>&1 || true
  fi
  # Never record this path as "preserved" — it does not exist. Reporting
  # WORKTREE_PRESERVED for a nonexistent path is exactly the false-truthful
  # output this fix closes.
}

# Reap-eligibility rule (bugsweep-8d0 dataloss re-review MAJOR 1). A mapped,
# existing, canonical-path bugsweep worktree is reaped ONLY on POSITIVE
# evidence its run is no longer active; on ANY ambiguity it is PRESERVED and
# reported. Positive evidence is either:
#   (i)  the owning run recorded a durable ".finalized" sentinel in its
#        run_dir (finalize.sh writes it — the run definitively ended), OR
#   (ii) ALL of: a lease record for this run DID exist but is no longer live
#        (stale, reclaimed past the grace window) AND the worktree is at least
#        the age floor old (default = grace window) AND ledger.jsonl has been
#        quiescent for at least the grace window (no hunt activity).
# Everything else — no run mapping, no lease record ever, still within the age
# floor, or a ledger touched within the grace window — is ambiguous and
# PRESERVED. This closes the reproduced live-sibling reap: a live run whose
# lease lapsed during one long read-only iteration keeps a fresh-enough ledger
# (or, failing that, is under the grace-aligned age floor) and is preserved.
reap_one_worktree() {
  local path="$1" branch="$2" live_file="$3" snapshot_file="$4"
  local run_dir="" canonical_root canonical_worktree worktree_target
  local grace min_age finalized="no"

  canonical_root="$(canonical_path "$BUGSWEEP_WORKTREES_DIR")"
  canonical_worktree="$(canonical_path "$path")"
  case "$canonical_worktree" in
    "${canonical_root}"/*) : ;;
    *)
      # MAJOR D fix: an off-canonical-path bugsweep worktree must never be
      # silently invisible — report it explicitly so the accounting/count
      # invariant holds, even though removing it is out of this reaper's scope.
      log "bugsweep branch $branch has a worktree off the canonical path ($path) — out of reap scope, reporting only"
      record_worktree_out_of_scope "$path"
      return 0
      ;;
  esac

  path="$canonical_worktree"
  run_dir="$(run_dir_for_worktree "$path" || true)"

  # BLOCKER B fix: prefer the per-worktree recorded original branch (the real
  # integration target THIS run's fix was meant for) when known; fall back to
  # the pinned, cwd-independent default otherwise. Never the caller's cwd HEAD.
  # (MAJOR 2: TARGET_BRANCH may itself be EMPTY when nothing cwd-independent
  # resolved — handled at the branch-deletion step below.)
  worktree_target="$(orig_branch_for_run_dir "$run_dir" 2>/dev/null || true)"
  [ -n "$worktree_target" ] || worktree_target="$TARGET_BRANCH"

  if [ ! -d "$path" ]; then
    reap_missing_worktree "$path" "$branch" "$worktree_target"
    return 0
  fi

  # bugsweep-cv0: check liveness across EVERY state.env naming this worktree
  # (not just the single first-matched run_dir bound above) so a live lease
  # recorded under a lexically-later run_dir is never invisible to the
  # DONE/.finalized reap path below.
  if any_run_dir_for_worktree_is_live "$path" "$live_file"; then
    log "preserving live leased worktree $path ($branch)"
    record_worktree_preserved "$path"
    return 0
  fi

  # Positive DONE evidence: the owning run finalized (durable sentinel written
  # by finalize.sh). This is the deterministic teardown path — reap regardless
  # of lease/ledger/age, since the run is provably over.
  if [ -n "$run_dir" ] && [ -f "${run_dir}/.finalized" ]; then
    finalized="yes"
  fi

  grace="$(_bsw_grace_seconds)"
  min_age="${BUGSWEEP_REAP_MIN_AGE_SECONDS:-$grace}"
  case "$min_age" in ''|*[!0-9]*) min_age="$grace" ;; esac

  if [ "$finalized" != "yes" ]; then
    # --- Ambiguity / liveness belts: PRESERVE unless positive dead evidence. ---

    # (MAJOR 1c) No run_dir mapping at all -> we cannot check lease OR ledger
    # -> ambiguous -> preserve. In production every bugsweep worktree has a
    # run mapping from birth (preflight writes state.env before `git worktree
    # add`); a mapping-less worktree is unknown provenance, never reaped.
    if [ -z "$run_dir" ]; then
      log "no run mapping for $path ($branch) — ambiguous (cannot prove the run is dead); preserving, not reaping"
      record_worktree_preserved "$path"
      return 0
    fi

    # (MAJOR 1c) No lease record EVER existed for this run (not in the
    # pre-reclaim snapshot) -> ambiguous -> preserve. Positive dead evidence
    # requires a lease to have existed and gone stale; "never had a lease" is
    # not that.
    #
    # bugsweep-gqw item 1 (secondary "positive-dead-evidence" reap path) was
    # DESIGNED here and then REMOVED after an adversarial production-default
    # repro: no lease + quiescent ledger + worktree mtime past grace + branch
    # contained are ALL satisfiable by a genuinely LIVE run (worktree root
    # mtime freezes at `git worktree add`; a single slow tool call exceeds the
    # ledger quiescence window; an out-of-band sibling `state.sh lease-list`
    # reclaim removes the lease and lease_touch cannot resurrect it; a branch
    # is its own ancestor before its first fix commit). There is no
    # mtime/quiescence proxy that separates "dead" from "alive but slow" — only
    # a genuine per-process liveness check would, which is out of scope. So a
    # no-lease-in-snapshot worktree stays PRESERVED: a lingering dead worktree
    # is an accepted disk-hygiene cost, never worth risking a live run's data.
    if ! grep -qxF "$run_dir" "$snapshot_file" 2>/dev/null; then
      log "no lease record was ever found for $path ($branch) — ambiguous; preserving (reap requires a stale-past-grace lease)"
      record_worktree_preserved "$path"
      return 0
    fi

    # (MAJOR 1a) Age floor, default = the lease grace window. Never reap a
    # worktree the lease system itself would still be inside the grace window
    # for.
    if worktree_younger_than_floor "$path" "$min_age"; then
      log "preserving worktree younger than the reap age floor (${min_age}s): $path ($branch)"
      record_worktree_preserved "$path"
      return 0
    fi

    # (MAJOR 1b) Ledger activity within the grace window == the run is alive
    # (a long read-only iteration whose lease lapsed still has a recent ledger,
    # or is caught by the age floor above). Preserve.
    if ledger_active_within "$run_dir" "$grace"; then
      log "preserving $path ($branch): ledger.jsonl was written within the grace window (${grace}s) — the run appears alive despite a lapsed lease"
      record_worktree_preserved "$path"
      return 0
    fi

    log "reaping $path ($branch): lease existed but is stale past the grace window AND ledger.jsonl has been quiescent for >=${grace}s (positive dead evidence)"
  else
    log "reaping $path ($branch): its owning run recorded a .finalized sentinel (positive done evidence)"
  fi

  if ! ensure_worktree_clean_or_committed "$path" "$branch"; then
    record_worktree_preserved "$path"
    record_preserved "$branch"
    return 0
  fi

  if git worktree remove "$path" >/dev/null 2>&1; then
    log "removed bugsweep worktree $path"
    record_worktree_removed "$path"
  else
    log "git worktree remove failed for $path — preserving"
    record_worktree_preserved "$path"
    record_preserved "$branch"
    return 0
  fi

  # MAJOR 2: never prove containment against an ambient cwd HEAD. If no
  # cwd-independent target resolved (empty), we cannot safely decide
  # containment -> PRESERVE the branch ref (the worktree content is already
  # safely committed on that branch by ensure_worktree_clean_or_committed).
  if [ -z "$worktree_target" ]; then
    log "no cwd-independent containment target resolved for $branch — cannot prove containment; preserving branch ref (never deleted against ambient cwd ancestry)"
    record_preserved "$branch"
    return 0
  fi

  if branch_exists "$branch" && branch_contained_in_target "$branch" "$worktree_target"; then
    if git branch -d "$branch" >/dev/null 2>&1; then
      log "deleted contained branch $branch"
      record_deleted "$branch"
    else
      log "could not delete contained branch $branch — preserving ref"
      record_preserved "$branch"
    fi
  elif branch_exists "$branch"; then
    log "preserving unmerged branch ref $branch after worktree removal"
    record_preserved "$branch"
  fi
}

# bugsweep-gqw item 2: reap_worktrees() is invoked by its caller as
# `reap_worktrees || reap_status=$?` so the reap lock is ALWAYS structurally
# released (MINOR 4) even when this function fails. That `||` context
# disables `set -e` for this function's ENTIRE body as a side effect of bash
# semantics — a failed mktemp (unwritable or nonexistent TMPDIR) would
# otherwise be silently swallowed: the affected variable stays empty, every
# downstream read/write against it quietly no-ops or errors without
# aborting, and the function still reaches the bottom and prints a dishonest
# "REAP_RESULT=ok" with all-zero counts. Each mktemp below is explicitly
# verified; on failure this reports the honest "REAP_RESULT=error" (with
# every documented counter still zeroed — the existing result-line contract,
# MINOR 3) and returns non-zero so the caller propagates a real error exit.
_bsw_reap_infra_error() {
  local reason="$1"
  log "reap-worktrees: internal failure — ${reason}; aborting this pass, no worktree was touched"
  echo "REAP_RESULT=error"
  [ -n "$TARGET_BRANCH" ] && echo "TARGET_BRANCH=${TARGET_BRANCH}"
  echo "WORKTREES_REMOVED=0"
  echo "WORKTREES_PRESERVED=0"
  echo "WORKTREES_OUT_OF_SCOPE=0"
  echo "BRANCHES_PRUNED=0"
  echo "LEASES_RELEASED=0"
  echo "LEASES_RELEASED_REAPED=0"
}

reap_worktrees() {
  local live_file leases_released leases_released_reaped line current_path current_branch
  local seen_paths_file pre_leases_file processed_run_dirs_file reaped_run_dirs_file
  local this_run_dir d canon canon_current

  live_file="$(mktemp "${TMPDIR:-/tmp}/bugsweep-live-leases.XXXXXX" 2>/dev/null || true)"
  if [ -z "$live_file" ] || [ ! -f "$live_file" ]; then
    _bsw_reap_infra_error "could not allocate a temp file (mktemp failed) for the live-lease snapshot"
    return 1
  fi
  : > "$live_file"

  seen_paths_file="$(mktemp "${TMPDIR:-/tmp}/bugsweep-seen-worktrees.XXXXXX" 2>/dev/null || true)"
  if [ -z "$seen_paths_file" ] || [ ! -f "$seen_paths_file" ]; then
    _bsw_reap_infra_error "could not allocate a temp file (mktemp failed) for seen-worktree tracking"
    rm -f "$live_file" 2>/dev/null || true
    return 1
  fi
  : > "$seen_paths_file"

  pre_leases_file="$(mktemp "${TMPDIR:-/tmp}/bugsweep-pre-leases.XXXXXX" 2>/dev/null || true)"
  if [ -z "$pre_leases_file" ] || [ ! -f "$pre_leases_file" ]; then
    _bsw_reap_infra_error "could not allocate a temp file (mktemp failed) for the pre-reclaim lease snapshot"
    rm -f "$live_file" "$seen_paths_file" 2>/dev/null || true
    return 1
  fi
  lease_run_dirs_snapshot > "$pre_leases_file" 2>/dev/null || true

  processed_run_dirs_file="$(mktemp "${TMPDIR:-/tmp}/bugsweep-processed-rundirs.XXXXXX" 2>/dev/null || true)"
  if [ -z "$processed_run_dirs_file" ] || [ ! -f "$processed_run_dirs_file" ]; then
    _bsw_reap_infra_error "could not allocate a temp file (mktemp failed) for processed-run-dir tracking"
    rm -f "$live_file" "$seen_paths_file" "$pre_leases_file" 2>/dev/null || true
    return 1
  fi
  : > "$processed_run_dirs_file"

  # bugsweep-gqw item 3: separately tracks run_dirs whose worktree this call
  # ACTUALLY reaped (removed), so LEASES_RELEASED_REAPED below can never be
  # conflated with LEASES_RELEASED (which counts every stale lease this
  # call's own state.sh lease-list reclaimed among worktrees it merely
  # PROCESSED — including ones that ended up PRESERVED, e.g. a lapsed lease
  # whose worktree the fresh-ledger belt, MAJOR 1b, kept alive).
  reaped_run_dirs_file="$(mktemp "${TMPDIR:-/tmp}/bugsweep-reaped-rundirs.XXXXXX" 2>/dev/null || true)"
  if [ -z "$reaped_run_dirs_file" ] || [ ! -f "$reaped_run_dirs_file" ]; then
    _bsw_reap_infra_error "could not allocate a temp file (mktemp failed) for reaped-run-dir tracking"
    rm -f "$live_file" "$seen_paths_file" "$pre_leases_file" "$processed_run_dirs_file" 2>/dev/null || true
    return 1
  fi
  : > "$reaped_run_dirs_file"

  bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" lease-list 2>/dev/null \
    | sed -n 's/^LEASE=//p' > "$live_file" || true

  current_path=""
  current_branch=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        current_path="${line#worktree }"; current_branch=""
        canonical_path "$current_path" >> "$seen_paths_file"
        ;;
      branch\ refs/heads/bugsweep/*)
        current_branch="${line#branch refs/heads/}"
        this_run_dir="$(run_dir_for_worktree "$current_path" || true)"
        [ -n "$this_run_dir" ] && printf '%s\n' "$this_run_dir" >> "$processed_run_dirs_file"
        reap_one_worktree "$current_path" "$current_branch" "$live_file" "$pre_leases_file"
        # bugsweep-gqw item 3: only correlate this run_dir to the "actually
        # reaped" bookkeeping when the worktree was REMOVED this pass (i.e.
        # its canonical path landed in WORKTREE_REMOVED_LINES) — never merely
        # because reap_one_worktree processed it.
        if [ -n "$this_run_dir" ]; then
          canon_current="$(canonical_path "$current_path")"
          if printf '%s\n' "$WORKTREE_REMOVED_LINES" | grep -qxF "$canon_current" 2>/dev/null; then
            printf '%s\n' "$this_run_dir" >> "$reaped_run_dirs_file"
          fi
        fi
        ;;
    esac
  done < <(git worktree list --porcelain)

  # MAJOR D fix (part 2): reconcile the canonical worktrees directory against
  # what `git worktree list` actually reported. A directory left behind by a
  # crashed/partial `git worktree add` (or created out-of-band) would
  # otherwise never be visited by the loop above at all — not even reported —
  # because it was never git-registered as a worktree. Report it explicitly
  # rather than staying silent; never touch it (git doesn't know it exists).
  if [ -d "$BUGSWEEP_WORKTREES_DIR" ]; then
    for d in "${BUGSWEEP_WORKTREES_DIR}"/*; do
      [ -d "$d" ] || continue
      canon="$(canonical_path "$d")"
      if ! grep -qxF "$canon" "$seen_paths_file" 2>/dev/null; then
        log "found a directory under BUGSWEEP_WORKTREES_DIR that 'git worktree list' does not know about: $d — reporting, not touching"
        record_worktree_out_of_scope "$d"
      fi
    done
  fi

  # MEDIUM F fix: count ONLY leases whose run_dir maps to a worktree THIS call
  # actually processed above — not a repo-wide before/after lease-file-count
  # delta, which conflated stale-lease reclaims of unrelated in-place-mode
  # runs (preflight acquires a lease for both worktree AND in-place runs, and
  # lease-list's reclaim pass is repo-wide) with worktrees this call reports on.
  leases_released=0
  if [ -s "$processed_run_dirs_file" ]; then
    while IFS= read -r this_run_dir; do
      [ -n "$this_run_dir" ] || continue
      if grep -qxF "$this_run_dir" "$pre_leases_file" 2>/dev/null \
        && ! grep -qxF "$this_run_dir" "$live_file" 2>/dev/null; then
        leases_released=$(( leases_released + 1 ))
      fi
    done < "$processed_run_dirs_file"
  fi

  # bugsweep-gqw item 3: the accurate subset of the count above whose
  # worktree was ACTUALLY reaped this pass (see reaped_run_dirs_file).
  leases_released_reaped=0
  if [ -s "$reaped_run_dirs_file" ]; then
    while IFS= read -r this_run_dir; do
      [ -n "$this_run_dir" ] || continue
      if grep -qxF "$this_run_dir" "$pre_leases_file" 2>/dev/null \
        && ! grep -qxF "$this_run_dir" "$live_file" 2>/dev/null; then
        leases_released_reaped=$(( leases_released_reaped + 1 ))
      fi
    done < "$reaped_run_dirs_file"
  fi

  git worktree prune >/dev/null 2>&1 || true
  rm -f "$live_file" "$seen_paths_file" "$pre_leases_file" "$processed_run_dirs_file" "$reaped_run_dirs_file" 2>/dev/null || true

  echo "REAP_RESULT=ok"
  # BLOCKER B observability: surface the resolved pinned target so callers
  # (and tests) can verify containment was proven against the real
  # integration target, never incidental cwd ancestry.
  [ -n "$TARGET_BRANCH" ] && echo "TARGET_BRANCH=${TARGET_BRANCH}"
  echo "WORKTREES_REMOVED=$(count_list "$WORKTREE_REMOVED_LINES")"
  echo "WORKTREES_PRESERVED=$(count_list "$WORKTREE_PRESERVED_LINES")"
  echo "WORKTREES_OUT_OF_SCOPE=$(count_list "$WORKTREE_OUT_OF_SCOPE_LINES")"
  echo "BRANCHES_PRUNED=$(count_list "$BRANCH_DELETED_LINES")"
  echo "LEASES_RELEASED=${leases_released}"
  # bugsweep-gqw item 3: LEASES_RELEASED (above) counts every stale lease
  # this call's own state.sh lease-list reclaimed among PROCESSED worktrees,
  # regardless of outcome — it does NOT imply "worktrees reaped" (a lapsed
  # lease can be reclaimed for a worktree the ledger-activity belt still
  # preserved as alive, MAJOR 1b). LEASES_RELEASED_REAPED is the accurate
  # subset restricted to worktrees this call actually removed.
  echo "LEASES_RELEASED_REAPED=${leases_released_reaped}"
  emit_list "WORKTREE_REMOVED" "$WORKTREE_REMOVED_LINES"
  emit_list "WORKTREE_PRESERVED" "$WORKTREE_PRESERVED_LINES"
  emit_list "WORKTREE_OUT_OF_SCOPE" "$WORKTREE_OUT_OF_SCOPE_LINES"
  emit_list "BRANCH_PRUNED" "$BRANCH_DELETED_LINES"
  emit_list "BRANCH_PRESERVED" "$BRANCH_PRESERVED_LINES"
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

if [ "$REAP_WORKTREES" = "yes" ]; then
  TARGET_BRANCH="$(resolve_pinned_target_branch)"

  # MINOR G fix (bugsweep-8d0 dataloss review): serialize concurrent
  # --reap-worktrees calls behind a short mkdir lock (the same idiom already
  # used for meta.json/the shared-index build elsewhere in this repo) so two
  # reapers racing on the same worktree/branch never both act on it — the
  # loser used to `git worktree remove`/`git branch -d` fail (the winner
  # already did it) and then log a stale "preserved" line for a branch that
  # was, in fact, already correctly deleted. If the lock is busy, skip this
  # pass entirely rather than proceeding unlocked: a skipped pass is harmless
  # (the next preflight/finalize call reaps it), which is a better trade than
  # ever emitting untrustworthy output.
  reap_lock="${BUGSWEEP_REPO_ROOT:+${BUGSWEEP_REPO_ROOT}/.bugsweep/.reap-worktrees.lock}"
  # bugsweep_lock_acquire does a plain `mkdir "$lockdir"` (no -p) — its parent
  # .bugsweep/ dir is not guaranteed to exist yet (e.g. the very first
  # --reap-worktrees call on a repo with no prior bugsweep activity), so
  # ensure it exists first or the lock would always fail to acquire and every
  # call would silently degrade to skipped_locked forever.
  if [ -n "$reap_lock" ]; then
    mkdir -p "${BUGSWEEP_REPO_ROOT}/.bugsweep" 2>/dev/null || true
  fi
  if [ -n "$reap_lock" ] && bugsweep_lock_acquire "$reap_lock" "${BUGSWEEP_REAP_LOCK_TIMEOUT:-25}"; then
    # MINOR 4 (dataloss re-review): make lock release STRUCTURAL. reap_worktrees
    # is under `set -euo pipefail`; a non-zero return would otherwise exit
    # before bugsweep_lock_release runs, leaking the lock (it self-heals via
    # dead-pid reclaim, but structurally it must always release). Capture the
    # status with `|| status=$?` so `set -e` cannot short-circuit the release,
    # then always release and propagate the real status.
    reap_status=0
    reap_worktrees || reap_status=$?
    bugsweep_lock_release "$reap_lock"
    exit "$reap_status"
  fi
  log "reap-worktrees: lock busy or repo root unresolved — skipping this pass (non-fatal; a later preflight/finalize call will retry)."
  # MINOR 3 (dataloss re-review): AC4 requires every KEY=VALUE counter line to
  # be emitted on EVERY path, including zeros — a headless caller parsing the
  # output must never see a counter simply vanish. Emit all six as 0 here
  # (bugsweep-gqw item 3 added LEASES_RELEASED_REAPED to this contract).
  echo "REAP_RESULT=skipped_locked"
  [ -n "$TARGET_BRANCH" ] && echo "TARGET_BRANCH=${TARGET_BRANCH}"
  echo "WORKTREES_REMOVED=0"
  echo "WORKTREES_PRESERVED=0"
  echo "WORKTREES_OUT_OF_SCOPE=0"
  echo "BRANCHES_PRUNED=0"
  echo "LEASES_RELEASED=0"
  echo "LEASES_RELEASED_REAPED=0"
  exit 0
fi

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
