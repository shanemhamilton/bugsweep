#!/usr/bin/env bats

CLEANUP_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/bugsweep-cleanup.sh"
PREFLIGHT_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/preflight.sh"

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name "bugsweep-test"
  git -C "$dir" checkout -b main -q
  printf 'base\n' > "${dir}/app.txt"
  git -C "$dir" add app.txt
  git -C "$dir" commit -m "init" -q
}

_make_bugsweep_branch() {
  local branch="$1" content="$2"
  git -C "$REPO" checkout -b "$branch" main -q
  printf '%s\n' "$content" > "${REPO}/app.txt"
  git -C "$REPO" add app.txt
  git -C "$REPO" commit -m "fix: ${branch}" -q
  git -C "$REPO" checkout main -q
}

_merge_branch_to_main() {
  local branch="$1"
  git -C "$REPO" checkout main -q
  git -C "$REPO" merge --no-ff -m "merge ${branch}" "$branch" -q
}

_branch_exists() {
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$1"
}

_make_run_dir_for_worktree() {
  local name="$1" branch="$2" worktree="$3"
  local run_dir="${REPO}/.bugsweep/run-${name}"
  mkdir -p "$run_dir"
  cat > "${run_dir}/state.env" <<ENV
BUGSWEEP_TS=${name}
BUGSWEEP_RUN_DIR=${run_dir}
BUGSWEEP_BRANCH=${branch}
BUGSWEEP_ORIG_BRANCH=main
BUGSWEEP_STASH_REF=none
BUGSWEEP_START_EPOCH=1
BUGSWEEP_MODE=detect-only
BUGSWEEP_WORKTREE=${worktree}
BUGSWEEP_SCRIPT_DIR=$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts
ENV
  touch "${run_dir}/ledger.jsonl"
  printf '%s\n' "$run_dir"
}

_make_lease() {
  local id="$1" run_dir="$2" pid="$3" timestamp="${4:-now}"
  local leases="${REPO}/.bugsweep/state/leases"
  local started
  mkdir -p "$leases"
  started="$(date +%s)"
  cat > "${leases}/${id}.json" <<JSON
{"pid":${pid},"run_dir":"${run_dir}","started":${started}}
JSON
  if [ "$timestamp" = "old" ]; then
    touch -t 202001010000 "${leases}/${id}.json"
  fi
}

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  cd "$REPO"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

@test "cleanup: merged bugsweep branch deletes normally" {
  _make_bugsweep_branch "bugsweep/merged-normal" "fix normal"
  _merge_branch_to_main "bugsweep/merged-normal"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" "bugsweep/merged-normal"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLEANUP_RESULT=merged_deleted"
  echo "$output" | grep -q "BRANCH_DELETED=bugsweep/merged-normal"
  ! _branch_exists "bugsweep/merged-normal"
}

@test "cleanup: merged branch in clean linked worktree removes worktree then deletes branch" {
  _make_bugsweep_branch "bugsweep/clean-worktree" "fix clean worktree"
  _merge_branch_to_main "bugsweep/clean-worktree"
  WORKTREE="${BATS_TMP}/linked-clean"
  git -C "$REPO" worktree add -q "$WORKTREE" "bugsweep/clean-worktree"
  WORKTREE="$(cd "$WORKTREE" && pwd -P)"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" "bugsweep/clean-worktree"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLEANUP_RESULT=merged_deleted"
  echo "$output" | grep -q "WORKTREE_REMOVED=${WORKTREE}"
  echo "$output" | grep -q "BRANCH_DELETED=bugsweep/clean-worktree"
  ! _branch_exists "bugsweep/clean-worktree"
  [ ! -d "$WORKTREE" ]
}

@test "cleanup: merged branch in dirty linked worktree is preserved" {
  _make_bugsweep_branch "bugsweep/dirty-worktree" "fix dirty worktree"
  _merge_branch_to_main "bugsweep/dirty-worktree"
  WORKTREE="${BATS_TMP}/linked-dirty"
  git -C "$REPO" worktree add -q "$WORKTREE" "bugsweep/dirty-worktree"
  printf 'untracked\n' > "${WORKTREE}/scratch.txt"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" "bugsweep/dirty-worktree"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLEANUP_RESULT=merged_branch_preserved"
  echo "$output" | grep -q "BRANCH_PRESERVED=bugsweep/dirty-worktree"
  _branch_exists "bugsweep/dirty-worktree"
  [ -d "$WORKTREE" ]
}

@test "cleanup: unmerged branch is preserved unless discard policy is explicit" {
  _make_bugsweep_branch "bugsweep/unmerged" "unmerged fix"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_POLICY=keep \
    bash "$CLEANUP_SH" "bugsweep/unmerged"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLEANUP_RESULT=kept_for_review"
  echo "$output" | grep -q "BRANCH_PRESERVED=bugsweep/unmerged"
  _branch_exists "bugsweep/unmerged"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_POLICY=discard \
    bash "$CLEANUP_SH" "bugsweep/unmerged"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLEANUP_RESULT=discarded"
  echo "$output" | grep -q "BRANCH_DELETED=bugsweep/unmerged"
  ! _branch_exists "bugsweep/unmerged"
}

@test "cleanup: unmerged leftover branch is preserved during contained branch cleanup" {
  _make_bugsweep_branch "bugsweep/merged-latest" "merged latest"
  _merge_branch_to_main "bugsweep/merged-latest"
  _make_bugsweep_branch "bugsweep/unmerged-leftover" "unmerged leftover"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" "bugsweep/merged-latest"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLEANUP_RESULT=merged_deleted"
  echo "$output" | grep -q "BRANCH_DELETED=bugsweep/merged-latest"
  echo "$output" | grep -q "BRANCH_PRESERVED=bugsweep/unmerged-leftover"
  ! _branch_exists "bugsweep/merged-latest"
  _branch_exists "bugsweep/unmerged-leftover"
}

@test "cleanup: merge conflict preserves branch" {
  _make_bugsweep_branch "bugsweep/conflict" "branch side"
  git -C "$REPO" checkout main -q
  printf 'target side\n' > "${REPO}/app.txt"
  git -C "$REPO" add app.txt
  git -C "$REPO" commit -m "target change" -q

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" "bugsweep/conflict"

  [ "$status" -eq 1 ]
  echo "$output" | grep -q "CLEANUP_RESULT=conflict"
  echo "$output" | grep -q "BRANCH_PRESERVED=bugsweep/conflict"
  _branch_exists "bugsweep/conflict"
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}

@test "cleanup: protected target branch refuses unless explicitly allowed" {
  _make_bugsweep_branch "bugsweep/protected" "protected fix"

  run env BUGSWEEP_TARGET=main bash "$CLEANUP_SH" "bugsweep/protected"

  [ "$status" -eq 1 ]
  echo "$output" | grep -q "CLEANUP_RESULT=kept_for_review"
  echo "$output" | grep -q "TARGET_BRANCH=main"
  _branch_exists "bugsweep/protected"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" "bugsweep/protected"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CLEANUP_RESULT=merged_deleted"
  ! _branch_exists "bugsweep/protected"
}

@test "cleanup: script parses with Bash 3.2-compatible syntax" {
  run bash -n "$CLEANUP_SH"
  [ "$status" -eq 0 ]
}

@test "cleanup: script does not use mapfile" {
  run grep -q "mapfile" "$CLEANUP_SH"
  [ "$status" -ne 0 ]
}

@test "reap-worktrees: removes N contained bugsweep worktrees, prunes branches, and is idempotent" {
  _make_bugsweep_branch "bugsweep/reap-one" "fix reap one"
  _merge_branch_to_main "bugsweep/reap-one"
  _make_bugsweep_branch "bugsweep/reap-two" "fix reap two"
  _merge_branch_to_main "bugsweep/reap-two"

  local wt1="${REPO}/.bugsweep/worktrees/reap-one"
  local wt2="${REPO}/.bugsweep/worktrees/reap-two"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt1" "bugsweep/reap-one"
  git -C "$REPO" worktree add -q "$wt2" "bugsweep/reap-two"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "REAP_RESULT=ok"
  echo "$output" | grep -q "WORKTREES_REMOVED=2"
  echo "$output" | grep -q "BRANCHES_PRUNED=2"
  echo "$output" | grep -q "LEASES_RELEASED=0"
  [ ! -d "$wt1" ]
  [ ! -d "$wt2" ]
  ! _branch_exists "bugsweep/reap-one"
  ! _branch_exists "bugsweep/reap-two"
  ! git -C "$REPO" worktree list --porcelain | grep -q "${REPO}/.bugsweep/worktrees/"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=0"
  echo "$output" | grep -q "BRANCHES_PRUNED=0"
}

@test "reap-worktrees: stale dirty worktree is committed to its branch, worktree removed, branch preserved" {
  _make_bugsweep_branch "bugsweep/reap-dirty" "fix dirty before reap"
  local wt="${REPO}/.bugsweep/worktrees/reap-dirty"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/reap-dirty"
  printf 'important uncommitted data\n' > "${wt}/scratch.txt"

  local run_dir
  run_dir="$(_make_run_dir_for_worktree "reap-dirty" "bugsweep/reap-dirty" "$wt")"
  _make_lease "run-reap-dirty" "$run_dir" 999999 old

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=1"
  echo "$output" | grep -q "WORKTREES_PRESERVED=0"
  echo "$output" | grep -q "BRANCHES_PRUNED=0"
  echo "$output" | grep -q "LEASES_RELEASED=1"
  [ ! -d "$wt" ]
  _branch_exists "bugsweep/reap-dirty"
  git -C "$REPO" show "bugsweep/reap-dirty:scratch.txt" | grep -q "important uncommitted data"
}

@test "reap-worktrees: live leased sibling is preserved" {
  _make_bugsweep_branch "bugsweep/reap-live" "fix live"
  local wt="${REPO}/.bugsweep/worktrees/reap-live"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/reap-live"

  local run_dir
  run_dir="$(_make_run_dir_for_worktree "reap-live" "bugsweep/reap-live" "$wt")"
  _make_lease "run-reap-live" "$run_dir" "$$"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=0"
  echo "$output" | grep -q "WORKTREES_PRESERVED=1"
  echo "$output" | grep -q "BRANCHES_PRUNED=0"
  [ -d "$wt" ]
  _branch_exists "bugsweep/reap-live"
}

@test "preflight --worktree reaps stale orphan before creating the next worktree" {
  _make_bugsweep_branch "bugsweep/reap-preflight" "fix preflight"
  _merge_branch_to_main "bugsweep/reap-preflight"
  local orphan="${REPO}/.bugsweep/worktrees/reap-preflight"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$orphan" "bugsweep/reap-preflight"
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "reap-preflight" "bugsweep/reap-preflight" "$orphan")"
  _make_lease "run-reap-preflight" "$run_dir" 999999 old

  run bash "$PREFLIGHT_SH" --worktree

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PREFLIGHT_OK"
  [ ! -d "$orphan" ]
  ! _branch_exists "bugsweep/reap-preflight"
  ! git -C "$REPO" worktree list --porcelain | grep -q "$orphan"
}
