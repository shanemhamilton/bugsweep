#!/usr/bin/env bats

CLEANUP_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/bugsweep-cleanup.sh"

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
