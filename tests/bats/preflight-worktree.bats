#!/usr/bin/env bats
#
# Tests for scripts/preflight.sh --worktree — the concurrency-safe entry point that
# lets N subagents (one metaswarm orchestrator dispatching up to 5 in parallel) each
# get their own linked worktree + collision-free branch, cut from the SAME repo,
# without ever touching the user's working tree/branch or each other's worktrees.
#
# bugsweep-p74: see scripts/preflight.sh header for the full design rationale.

PREFLIGHT_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/preflight.sh"
FINALIZE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/finalize.sh"
STATE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/state.sh"
SKILL_MD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/SKILL.md"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  # Explicit non-protected branch name: bugsweep refuses to start from a dirty
  # protected branch (main/master/develop/...) in the DEFAULT (non-worktree)
  # mode, which is a deliberate, separate safety rule (see preflight.sh's
  # protected-branch guard) — not something these worktree/concurrency tests
  # are exercising. Using "dev" here mirrors bugsweep's own documented usage
  # (run from a feature/dev branch) and keeps this file's dirty-tree tests
  # independent of the local git config's init.defaultBranch.
  git -C "$dir" checkout -q -b dev
  printf 'base\n' > "${dir}/app.txt"
  git -C "$dir" add app.txt
  git -C "$dir" commit -m "init" -q
}

# Content hash of the user's tracked+untracked working-tree files (excluding
# .git and bugsweep's own .bugsweep/ bookkeeping dir), used to prove the user's
# ACTUAL working tree is byte-identical before/after a worktree-mode preflight.
# .bugsweep/ is deliberately excluded: it is bugsweep's own internal state
# (run dirs, cross-run state, leases, linked worktrees) — its existence/growth
# is the intended, documented side effect of running preflight at all (and it
# is already git-ignored via preflight's info/exclude entry, so `git status
# --porcelain` never sees it). What must NOT change is everything the user
# actually authored.
_tree_hash() {
  local dir="$1"
  ( cd "$dir" && \
    find . -path ./.git -prune -o -path ./.bugsweep -prune -o -type f -print0 2>/dev/null \
      | sort -z \
      | xargs -0 shasum 2>/dev/null \
      | shasum | awk '{print $1}' )
}

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  ORIG_BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD)"
  cd "$REPO"
}

teardown() {
  cd "$START_CWD"
  # Best-effort: prune any leftover linked worktrees before removing the repo dir.
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  rm -rf "$BATS_TMP"
}

# ---------------------------------------------------------------------------
# Single-invocation behavior
# ---------------------------------------------------------------------------

@test "preflight --worktree: emits WORKTREE, BRANCH, and PREFLIGHT_OK" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^WORKTREE='
  echo "$output" | grep -qE '^BRANCH=bugsweep/'
  echo "$output" | grep -q "PREFLIGHT_OK"
}

@test "preflight --worktree: does not touch the user's current branch" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = "$ORIG_BRANCH" ]
}

@test "preflight --worktree: does not stash and reports STASH=none" {
  printf 'dirty\n' >> "${REPO}/app.txt"

  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "STASH=none"
  # The user's dirty file must remain dirty (untouched), not stashed away.
  grep -q "dirty" "${REPO}/app.txt"
  git -C "$REPO" stash list | grep -qv . || true
  [ -z "$(git -C "$REPO" stash list)" ]
}

@test "preflight --worktree: the created worktree is checked out on the new branch and is a distinct directory" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]

  local wt branch
  wt="$(echo "$output" | sed -n 's/^WORKTREE=//p')"
  branch="$(echo "$output" | sed -n 's/^BRANCH=//p')"

  [ -d "$wt" ]
  [ "$wt" != "$REPO" ]
  [ "$(git -C "$wt" symbolic-ref --short HEAD)" = "$branch" ]
}

@test "preflight --worktree: worktree is anchored under the MAIN repo root, not a nested worktree path" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local wt
  wt="$(echo "$output" | sed -n 's/^WORKTREE=//p')"
  case "$wt" in
    "${REPO}"/.bugsweep/worktrees/*) : ;;
    *) echo "worktree not under main repo root: $wt"; false ;;
  esac
}

@test "preflight --worktree: refuses when a rebase is in progress" {
  mkdir -p "${REPO}/.git/rebase-merge"
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "rebase"
}

@test "preflight --worktree: refuses on detached HEAD" {
  git -C "$REPO" checkout -q --detach
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "detached"
}

@test "preflight --worktree: refuses when repo has no commits" {
  local empty="${BATS_TMP}/empty-repo"
  git init -q "$empty"
  git -C "$empty" config user.email "test@bugsweep"
  git -C "$empty" config user.name "bugsweep-test"
  cd "$empty"
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "no commits"
}

@test "default (non --worktree) preflight still stashes and checks out in the shared tree" {
  printf 'dirty\n' >> "${REPO}/app.txt"
  run bash "$PREFLIGHT_SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^BRANCH=bugsweep/'
  echo "$output" | grep -qv '^WORKTREE='
  # dirty work should have been stashed, not left in the tree
  ! grep -q "dirty" "${REPO}/app.txt"
  [ -n "$(git -C "$REPO" stash list)" ]
  # current branch changed to the new bugsweep branch (legacy in-place behavior)
  case "$(git -C "$REPO" symbolic-ref --short HEAD)" in bugsweep/*) : ;; *) false ;; esac
}

# ---------------------------------------------------------------------------
# Concurrency: 5 parallel --worktree invocations (acceptance criterion #1, #4)
# ---------------------------------------------------------------------------

@test "5 concurrent preflight --worktree runs yield 5 distinct worktrees/branches and leave the user's tree untouched" {
  local before_hash before_branch
  before_branch="$(git -C "$REPO" symbolic-ref --short HEAD)"
  before_hash="$(_tree_hash "$REPO")"
  local before_status
  before_status="$(git -C "$REPO" status --porcelain)"

  local outdir="${BATS_TMP}/outs"
  mkdir -p "$outdir"

  local pids=""
  for i in 1 2 3 4 5; do
    ( cd "$REPO" && bash "$PREFLIGHT_SH" --worktree > "${outdir}/out.${i}" 2>"${outdir}/err.${i}" ) &
    pids="$pids $!"
  done
  local rc=0
  for p in $pids; do
    wait "$p" || rc=1
  done
  [ "$rc" -eq 0 ]

  # Collect WORKTREE= and BRANCH= from each output; every one must be distinct.
  local worktrees="" branches=""
  for i in 1 2 3 4 5; do
    cat "${outdir}/out.${i}" >&2  # surfaced on failure via bats output capture
    grep -q "PREFLIGHT_OK" "${outdir}/out.${i}"
    local wt br
    wt="$(sed -n 's/^WORKTREE=//p' "${outdir}/out.${i}")"
    br="$(sed -n 's/^BRANCH=//p' "${outdir}/out.${i}")"
    [ -n "$wt" ]
    [ -n "$br" ]
    worktrees="${worktrees}${wt}"$'\n'
    branches="${branches}${br}"$'\n'
  done

  local uniq_wt uniq_br
  uniq_wt="$(printf '%s' "$worktrees" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  uniq_br="$(printf '%s' "$branches" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  [ "$uniq_wt" -eq 5 ]
  [ "$uniq_br" -eq 5 ]

  # The user's tree/branch must be exactly as it was.
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = "$before_branch" ]
  [ "$(_tree_hash "$REPO")" = "$before_hash" ]
  [ "$(git -C "$REPO" status --porcelain)" = "$before_status" ]
}

# ---------------------------------------------------------------------------
# Review BLOCKER B: lease must survive preflight's own exit
# ---------------------------------------------------------------------------

@test "worktree lease survives preflight's own exit (grace window prevents premature reclaim)" {
  # Plain subprocess, NO BUGSWEEP_LEASE_PID override: this is the REAL invocation
  # path. preflight exits immediately after printing PREFLIGHT_OK, so any
  # liveness scheme keyed to a pid that dies with preflight must NOT cause the
  # lease to be reclaimed while the run is still in-flight — a dead pid alone is
  # normal; reclaim additionally requires the lease file to age past the grace
  # window (BUGSWEEP_LEASE_GRACE_SECONDS, default 900s).
  bash "$PREFLIGHT_SH" --worktree > "${BATS_TMP}/pf.out" 2>/dev/null
  local run_dir
  run_dir="$(sed -n 's/^RUN_DIR=//p' "${BATS_TMP}/pf.out")"
  [ -n "$run_dir" ]

  run bash "$STATE_SH" lease-list
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$run_dir"
}

# ---------------------------------------------------------------------------
# Review BLOCKER C: exclude entry must anchor to the COMMON git dir
# ---------------------------------------------------------------------------

@test "default preflight run inside a linked worktree keeps .bugsweep/ excluded in the MAIN checkout" {
  local main_repo="${BATS_TMP}/main-repo"
  _make_git_repo "$main_repo"
  git -C "$main_repo" worktree add -q -b user-feature "${BATS_TMP}/user-wt"
  cd "${BATS_TMP}/user-wt"

  run bash "$PREFLIGHT_SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PREFLIGHT_OK"

  # The run dir lands under the MAIN repo root (BUGSWEEP_REPO_ROOT anchors to
  # the common git dir). Unless the exclude entry is written to the COMMON git
  # dir's info/exclude — the only exclude file git actually reads — .bugsweep/
  # shows up untracked in the main checkout, one `git add -A` away from being
  # committed into real history.
  run git -C "$main_repo" status --porcelain
  ! echo "$output" | grep -q "\.bugsweep"
  grep -qx '.bugsweep/' "${main_repo}/.git/info/exclude"
}

# ---------------------------------------------------------------------------
# Review MAJOR E: finalize must understand worktree mode
# ---------------------------------------------------------------------------

@test "finalize in worktree mode: no branch-return warning, handoff records worktree_path" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir wt
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  wt="$(echo "$output" | sed -n 's/^WORKTREE=//p')"
  [ -n "$run_dir" ]
  [ -n "$wt" ]

  printf 'fix\n' > "${wt}/fix.txt"
  cd "$wt"
  # No BUGSWEEP_REAP_MIN_AGE_SECONDS override here: finalize.sh writes a
  # durable .finalized sentinel before invoking the reaper, which is positive
  # DONE evidence, so this run's own worktree is reaped deterministically —
  # regardless of the grace-aligned age floor, the (released) lease, or a
  # fresh ledger. This is exactly the production teardown path (a real run's
  # ledger is fresh at finalize time too). If the reaper still relied on the
  # age floor, this test worktree (seconds old) would be wrongly preserved.
  run bash "$FINALIZE_SH" "$run_dir"
  [ "$status" -eq 0 ]

  # No misleading generic warning from git's (correct) refusal to check out a
  # branch that is held by the user's main checkout; instead an accurate,
  # worktree-aware line.
  ! echo "$output" | grep -q "could not switch back"
  echo "$output" | grep -qi "worktree run"

  # The user's checkout is untouched.
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = "$ORIG_BRANCH" ]
  [ ! -d "$wt" ]

  # The isolated worktree is gone, but the review branch remains available.
  git -C "$REPO" branch --list 'bugsweep/*' | grep -q .

  # Handoff carries the manual-cleanup breadcrumb.
  python3 - "${run_dir}/post-finalize-handoff.json" "$wt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("worktree_path") == sys.argv[2], repr(d.get("worktree_path"))
PY
}

# ---------------------------------------------------------------------------
# Review MINOR F: SKILL.md must document the worktree contract
# ---------------------------------------------------------------------------

@test "SKILL.md documents the --worktree preflight contract" {
  grep -q -- '--worktree' "$SKILL_MD"
  grep -q 'BUGSWEEP_LEASE_PID' "$SKILL_MD"
  grep -q '\.bugsweep/worktrees' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss review, BLOCKER A: preflight must acquire this run's
# lease BEFORE `git worktree add` creates the worktree, so a lease-less
# bugsweep worktree can never legitimately exist (closing the TOCTOU window
# a concurrent sibling's --reap-worktrees call could otherwise land in).
# ---------------------------------------------------------------------------

@test "preflight --worktree: the lease exists and the worktree directory does not, at the exact instant before 'git worktree add' runs (BLOCKER A ordering)" {
  # _PREFLIGHT_TEST_PRE_ADD_HOOK is a test-only hook (see preflight.sh) that
  # is eval'd inside preflight's own process, in the worktree-mode branch,
  # immediately after the lease is acquired and immediately before `git
  # worktree add` executes. It shares preflight's variable scope, so it can
  # assert on $worktree_path directly. A nonzero exit here surfaces as
  # preflight's own exit status.
  run env _PREFLIGHT_TEST_PRE_ADD_HOOK='
    lease_count=$(find .bugsweep/state/leases -type f -name "*.json" 2>/dev/null | wc -l | tr -d " ")
    [ "$lease_count" = "1" ] || exit 90
    [ ! -e "$worktree_path" ] || exit 91
  ' bash "$PREFLIGHT_SH" --worktree

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PREFLIGHT_OK"
}

@test "preflight --worktree: releases the pre-acquired lease and cleans up the run dir if 'git worktree add' fails (BLOCKER A ordering)" {
  # Force `git worktree add` to fail deterministically (no write permission
  # on its parent dir) without needing to race a concurrent process. This
  # exercises the NEW failure-path cleanup: a lease acquired before the add
  # attempt must not be left behind as an orphan when the add itself fails.
  mkdir -p "${REPO}/.bugsweep/worktrees"
  chmod 555 "${REPO}/.bugsweep/worktrees"

  run bash "$PREFLIGHT_SH" --worktree
  local rc="$status"

  chmod 755 "${REPO}/.bugsweep/worktrees"  # restore so teardown can clean up

  [ "$rc" -ne 0 ]
  echo "$output" | grep -qi "could not create worktree"
  [ -z "$(find "${REPO}/.bugsweep/state/leases" -type f -name '*.json' 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss review, COMPLETENESS: a session-end sweep entry point
# must exist and be documented (three wiring points: preflight, finalize,
# and session end).
# ---------------------------------------------------------------------------

@test "SKILL.md documents a session-end --reap-worktrees sweep for orchestrators" {
  grep -qi 'session.end' "$SKILL_MD"
  grep -q -- '--reap-worktrees' "$SKILL_MD"
}
