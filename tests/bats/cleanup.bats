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

# bugsweep-8d0 dataloss re-review MAJOR 1b: the reaper preserves any run whose
# ledger.jsonl was written within the lease grace window (a live-hunt liveness
# signal). Tests that intend a run to be REAPED must age its ledger past that
# window so the ledger-activity guard doesn't (correctly) preserve it.
_age_ledger() {
  local run_dir="$1"
  touch -t 202001010000 "${run_dir}/ledger.jsonl" 2>/dev/null || true
}

# bugsweep-8d0 dataloss re-review MAJOR 1: finalize.sh drops a durable
# ".finalized" sentinel so the reaper can deterministically reap a
# definitively-finished run. Tests that model a finished run use this.
_mark_finalized() {
  local run_dir="$1"
  : > "${run_dir}/.finalized"
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

  # bugsweep-8d0 dataloss re-review MAJOR 1: the reaper now reaps ONLY on
  # positive evidence a run is over. Model these as FINISHED runs: each gets a
  # run mapping + a durable .finalized sentinel (what finalize.sh writes), so
  # the reaper reaps them deterministically. Without it they would be
  # correctly preserved as ambiguous (no positive dead/done evidence).
  local rd1 rd2
  rd1="$(_make_run_dir_for_worktree "reap-one" "bugsweep/reap-one" "$wt1")"
  rd2="$(_make_run_dir_for_worktree "reap-two" "bugsweep/reap-two" "$wt2")"
  _mark_finalized "$rd1"
  _mark_finalized "$rd2"

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
  # Model a genuinely DEAD/crashed run: a stale-past-grace lease (old) AND a
  # quiescent ledger (aged past grace) — the positive dead evidence the reaper
  # now requires. MIN_AGE=0 waives only the worktree-dir age floor (the dir is
  # seconds old by wall-clock); the stale-lease + quiescent-ledger evidence is
  # what authorizes the reap.
  _make_lease "run-reap-dirty" "$run_dir" 999999 old
  _age_ledger "$run_dir"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
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
  # Dead run: stale-past-grace lease + quiescent ledger (see the dirty-worktree
  # test above for why both are needed under the re-review MAJOR 1 rule).
  _make_lease "run-reap-preflight" "$run_dir" 999999 old
  _age_ledger "$run_dir"

  run env BUGSWEEP_REAP_MIN_AGE_SECONDS=0 bash "$PREFLIGHT_SH" --worktree

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PREFLIGHT_OK"
  [ ! -d "$orphan" ]
  ! _branch_exists "bugsweep/reap-preflight"
  ! git -C "$REPO" worktree list --porcelain | grep -q "$orphan"
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss review: BLOCKER A — lease-before-add TOCTOU + wrong
# ambiguous default (no lease found used to mean "remove if clean"; now it
# must mean "preserve" unless the worktree is provably old).
# ---------------------------------------------------------------------------

@test "reap-worktrees: worktree with no lease record and age below the grace floor is preserved, live-lease sibling also untouched (BLOCKER A)" {
  # A worktree with NO run_dir/lease ever created for it — indistinguishable
  # from a worktree caught mid-creation by a concurrent preflight (the exact
  # TOCTOU this fix closes). It must be preserved purely because it is new
  # (default grace floor 120s), independent of lease state.
  _make_bugsweep_branch "bugsweep/no-lease-young" "young orphan, no lease ever recorded"
  local wt_no_lease="${REPO}/.bugsweep/worktrees/no-lease-young"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt_no_lease" "bugsweep/no-lease-young"

  # A sibling worktree with a genuinely LIVE lease (this test process's own
  # pid), which must also survive regardless of the age floor.
  _make_bugsweep_branch "bugsweep/reap-live-sibling" "live sibling"
  local wt_live="${REPO}/.bugsweep/worktrees/reap-live-sibling"
  git -C "$REPO" worktree add -q "$wt_live" "bugsweep/reap-live-sibling"
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "reap-live-sibling" "bugsweep/reap-live-sibling" "$wt_live")"
  _make_lease "run-reap-live-sibling" "$run_dir" "$$"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=0"
  echo "$output" | grep -q "WORKTREES_PRESERVED=2"
  [ -d "$wt_no_lease" ]
  [ -d "$wt_live" ]
  _branch_exists "bugsweep/no-lease-young"
  _branch_exists "bugsweep/reap-live-sibling"
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss review: BLOCKER B — TARGET_BRANCH resolved from
# caller cwd HEAD deletes unreviewed branches merged only into an incidental
# sibling branch, never into the real integration target.
# ---------------------------------------------------------------------------

@test "reap-worktrees: pinned target ignores caller cwd branch ancestry (BLOCKER B)" {
  _make_bugsweep_branch "bugsweep/unreviewed" "unreviewed fix, never merged to main"
  local wt="${REPO}/.bugsweep/worktrees/unreviewed"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/unreviewed"
  # Reap-eligible finished run (records BUGSWEEP_ORIG_BRANCH=main as the real
  # integration target), so the reaper reaches the branch-containment step —
  # the step BLOCKER B protects.
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "unreviewed" "bugsweep/unreviewed" "$wt")"
  _mark_finalized "$run_dir"

  # A separate branch that legitimately descends from (contains) the
  # unreviewed branch's tip — simulating some unrelated branch that happens
  # to be checked out in the CALLER's cwd when the reaper runs.
  git -C "$REPO" checkout -b "someone-elses-branch" "bugsweep/unreviewed" -q
  git -C "$REPO" checkout main -q

  local other_wt="${BATS_TMP}/other-checkout"
  git -C "$REPO" worktree add -q "$other_wt" "someone-elses-branch"

  # Pre-fix, TARGET_BRANCH would resolve to "someone-elses-branch" (the
  # invoking cwd's HEAD), against which bugsweep/unreviewed IS contained —
  # and the reaper would delete an unreviewed fix main never received. The
  # worktree itself is still removed (it is clean/finalized, so its content is
  # safe — the fix lives on the branch ref); what BLOCKER B protects is the
  # BRANCH REF surviving because it is correctly judged "not contained in
  # main", never in the incidental sibling branch.
  run env BUGSWEEP_ALLOW_PROTECTED=1 \
    bash -c "cd '$other_wt' && bash '$CLEANUP_SH' --reap-worktrees"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TARGET_BRANCH=main"
  echo "$output" | grep -q "BRANCH_PRESERVED=bugsweep/unreviewed"
  ! echo "$output" | grep -q "BRANCH_PRUNED=bugsweep/unreviewed"
  _branch_exists "bugsweep/unreviewed"
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss review: BLOCKER C — worktree directory vanished
# out-of-band while git still registers it; must resolve containment before
# `git worktree prune` erases the linkage, never leaving a permanent orphan.
# ---------------------------------------------------------------------------

@test "reap-worktrees: directory-vanished worktree with a CONTAINED branch is resolved, not orphaned (BLOCKER C)" {
  _make_bugsweep_branch "bugsweep/vanished-contained" "fix, later merged"
  _merge_branch_to_main "bugsweep/vanished-contained"
  local wt="${REPO}/.bugsweep/worktrees/vanished-contained"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/vanished-contained"
  # Simulate out-of-band directory removal: git still has it registered.
  rm -rf "$wt"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  # A nonexistent path must never be reported as "preserved" (that is the
  # exact false-truthful line this fix removes).
  ! echo "$output" | grep -q "WORKTREE_PRESERVED=${wt}"
  echo "$output" | grep -q "BRANCH_PRUNED=bugsweep/vanished-contained"
  ! _branch_exists "bugsweep/vanished-contained"
  ! git -C "$REPO" worktree list --porcelain | grep -q "$wt"
}

@test "reap-worktrees: directory-vanished worktree with an UNMERGED branch preserves the branch ref, never orphaning it silently (BLOCKER C)" {
  _make_bugsweep_branch "bugsweep/vanished-unmerged" "fix, never merged"
  local wt="${REPO}/.bugsweep/worktrees/vanished-unmerged"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/vanished-unmerged"
  rm -rf "$wt"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "WORKTREE_PRESERVED=${wt}"
  echo "$output" | grep -q "BRANCH_PRESERVED=bugsweep/vanished-unmerged"
  _branch_exists "bugsweep/vanished-unmerged"
  # The stale registration must be cleared (never a permanent orphan that no
  # future reaper pass revisits) — `git worktree prune`/`--force` cleared it.
  ! git -C "$REPO" worktree list --porcelain | grep -q "$wt"

  # The branch itself is a normal, ordinary branch ref now (no worktree links
  # to it at all) — proving it is NOT a permanent orphan: it remains fully
  # visible to and operable by the rest of the cleanup tooling, e.g. once it
  # is later merged, ordinary (non-worktree) cleanup can still find and
  # delete it like any other contained bugsweep branch.
  _merge_branch_to_main "bugsweep/vanished-unmerged"
  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" "bugsweep/vanished-unmerged"
  [ "$status" -eq 0 ]
  ! _branch_exists "bugsweep/vanished-unmerged"
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss review: MAJOR D — off-canonical-path bugsweep
# worktrees were invisible (no record at all) instead of being reported.
# ---------------------------------------------------------------------------

@test "reap-worktrees: off-canonical-path bugsweep worktree is reported, not silently skipped (MAJOR D)" {
  _make_bugsweep_branch "bugsweep/off-canonical" "fix in a non-canonical worktree location"
  local wt="${BATS_TMP}/off-canonical-worktree"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/off-canonical"
  # `git worktree list --porcelain` always reports paths in resolved
  # (realpath) form; normalize here too so the string comparison below
  # matches what the script actually reports (same idiom the pre-existing
  # "clean linked worktree" test above already uses).
  wt="$(cd "$wt" && pwd -P)"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_OUT_OF_SCOPE=1"
  echo "$output" | grep -q "WORKTREE_OUT_OF_SCOPE=${wt}"
  # Never touched: still exists, branch untouched, not double-counted as
  # either removed or (canonical-scope) preserved.
  [ -d "$wt" ]
  _branch_exists "bugsweep/off-canonical"
  ! echo "$output" | grep -q "WORKTREES_REMOVED=1"
}

@test "reap-worktrees: un-registered directory under BUGSWEEP_WORKTREES_DIR is reported via directory-scan reconciliation (MAJOR D)" {
  # A directory that 'git worktree list' does not know about at all (e.g. a
  # crashed/partial 'git worktree add', or an out-of-band copy) — the
  # porcelain-based enumeration loop alone would never even visit this, let
  # alone report it.
  mkdir -p "${REPO}/.bugsweep/worktrees/ghost-dir"
  printf 'not a real worktree\n' > "${REPO}/.bugsweep/worktrees/ghost-dir/marker.txt"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_OUT_OF_SCOPE=1"
  echo "$output" | grep -q "WORKTREE_OUT_OF_SCOPE=${REPO}/.bugsweep/worktrees/ghost-dir"
  [ -d "${REPO}/.bugsweep/worktrees/ghost-dir" ]
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss review: MAJOR E — gitignored-but-present untracked
# content was invisible to the dirty-check AND `git add -A`, so it was
# silently deleted by `git worktree remove` with no commit, no warning.
# ---------------------------------------------------------------------------

@test "reap-worktrees: gitignored untracked content is never silently discarded (MAJOR E)" {
  _make_bugsweep_branch "bugsweep/reap-ignored" "fix with ignored content"
  _merge_branch_to_main "bugsweep/reap-ignored"
  local wt="${REPO}/.bugsweep/worktrees/reap-ignored"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/reap-ignored"
  wt="$(cd "$wt" && pwd -P)"
  # Reap-eligible finished run, so the reaper reaches the content-safety guard
  # (ensure_worktree_clean_or_committed) where MAJOR E lives — it is that guard
  # that must detect the gitignored content and preserve rather than remove.
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "reap-ignored" "bugsweep/reap-ignored" "$wt")"
  _mark_finalized "$run_dir"
  printf 'build/\n' > "${wt}/.gitignore"
  git -C "$wt" add .gitignore >/dev/null
  git -C "$wt" commit -q -m "add gitignore"
  mkdir -p "${wt}/build"
  printf 'generated output that must not vanish silently\n' > "${wt}/build/out.txt"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  # Must never be silently discarded: the worktree (and its gitignored file)
  # must still be on disk, preserved and reported — not removed out from
  # under the content.
  [ -d "$wt" ]
  [ -f "${wt}/build/out.txt" ]
  grep -q "generated output that must not vanish silently" "${wt}/build/out.txt"
  echo "$output" | grep -q "WORKTREE_PRESERVED=${wt}"
  _branch_exists "bugsweep/reap-ignored"
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss review: MEDIUM F — LEASES_RELEASED was a repo-wide
# before/after JSON-file-count delta that conflated unrelated in-place-mode
# runs' reclaimed leases with worktrees this call actually reaped.
# ---------------------------------------------------------------------------

@test "reap-worktrees: LEASES_RELEASED counts only this call's worktrees, not unrelated in-place-run leases (MEDIUM F)" {
  _make_bugsweep_branch "bugsweep/reap-scoped-lease" "fix scoped lease"
  local wt="${REPO}/.bugsweep/worktrees/reap-scoped-lease"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/reap-scoped-lease"
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "reap-scoped-lease" "bugsweep/reap-scoped-lease" "$wt")"
  _make_lease "run-reap-scoped-lease" "$run_dir" 999999 old
  _age_ledger "$run_dir"

  # An UNRELATED in-place-mode run's stale lease — preflight acquires a lease
  # for in-place runs too, and its run_dir has no BUGSWEEP_WORKTREE mapping
  # to any worktree at all. This must NEVER be folded into this call's
  # LEASES_RELEASED count.
  local unrelated_run_dir="${REPO}/.bugsweep/run-unrelated-inplace"
  mkdir -p "$unrelated_run_dir"
  _make_lease "run-unrelated-inplace" "$unrelated_run_dir" 999998 old

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "LEASES_RELEASED=1"
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss review: MINOR G — concurrent reapers could report a
# stale "preserved" line for a branch/worktree a sibling reaper had already
# resolved.
# ---------------------------------------------------------------------------

@test "reap-worktrees: concurrent reap attempts serialize via lock instead of racing (MINOR G)" {
  _make_bugsweep_branch "bugsweep/reap-lockcheck" "fix lock check"
  _merge_branch_to_main "bugsweep/reap-lockcheck"
  local wt="${REPO}/.bugsweep/worktrees/reap-lockcheck"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/reap-lockcheck"

  # Simulate a concurrent reaper already holding the lock (a live pid: this
  # bats test process itself).
  local lockdir="${REPO}/.bugsweep/.reap-worktrees.lock"
  mkdir -p "$lockdir"
  printf '%s' "$$" > "${lockdir}/pid"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_LOCK_TIMEOUT=1 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "REAP_RESULT=skipped_locked"
  # Nothing was touched while the lock was held by "another" reaper.
  [ -d "$wt" ]
  _branch_exists "bugsweep/reap-lockcheck"

  rm -f "${lockdir}/pid"
  rmdir "$lockdir" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss re-review MINOR 3: the skipped_locked path must still
# emit every KEY=VALUE counter line (as 0), not just REAP_RESULT — a headless
# caller parsing the output must never see a counter vanish.
# ---------------------------------------------------------------------------

@test "reap-worktrees: skipped_locked path emits all five counter lines as zero (MINOR 3)" {
  local lockdir="${REPO}/.bugsweep/.reap-worktrees.lock"
  mkdir -p "$lockdir"
  printf '%s' "$$" > "${lockdir}/pid"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_LOCK_TIMEOUT=1 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "REAP_RESULT=skipped_locked"
  echo "$output" | grep -q "^WORKTREES_REMOVED=0$"
  echo "$output" | grep -q "^WORKTREES_PRESERVED=0$"
  echo "$output" | grep -q "^WORKTREES_OUT_OF_SCOPE=0$"
  echo "$output" | grep -q "^BRANCHES_PRUNED=0$"
  echo "$output" | grep -q "^LEASES_RELEASED=0$"

  rm -f "${lockdir}/pid"
  rmdir "$lockdir" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss re-review MINOR 4: the reap lock must be released
# structurally — after a normal reap completes, the lock directory must not
# linger (a leak that would otherwise only self-heal via dead-pid reclaim).
# ---------------------------------------------------------------------------

@test "reap-worktrees: releases its lock structurally (no leaked lock dir after a normal reap) (MINOR 4)" {
  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "REAP_RESULT=ok"
  [ ! -d "${REPO}/.bugsweep/.reap-worktrees.lock" ]
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss re-review MAJOR 1b: a live sibling whose lease lapsed
# past the grace window but whose ledger.jsonl is FRESH must be PRESERVED.
# ---------------------------------------------------------------------------

@test "reap-worktrees: live sibling with a lapsed lease but a FRESH ledger is preserved (MAJOR 1b)" {
  _make_bugsweep_branch "bugsweep/live-lapsed" "long read-only hunt, lease lapsed"
  local wt="${REPO}/.bugsweep/worktrees/live-lapsed"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/live-lapsed"
  wt="$(cd "$wt" && pwd -P)"
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "live-lapsed" "bugsweep/live-lapsed" "$wt")"
  # Lease lapsed past grace (dead recorded pid + aged file -> reclaimed by
  # lease-list), BUT the run is genuinely alive: its ledger.jsonl was written
  # just now (guard.sh appends hunt events). MIN_AGE=0 waives the worktree-dir
  # age floor, so ONLY the ledger-activity guard stands between a live run and
  # a data-losing reap — exactly the reproduced defect.
  _make_lease "run-live-lapsed" "$run_dir" 999999 old
  printf '{"event":"batch_covered","batch":7}\n' >> "${run_dir}/ledger.jsonl"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=0"
  echo "$output" | grep -q "WORKTREE_PRESERVED=${wt}"
  [ -d "$wt" ]
  _branch_exists "bugsweep/live-lapsed"
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss re-review MAJOR 1c: a worktree with a run mapping but
# NO lease record ever, past the age floor, must be PRESERVED (ambiguous ->
# preserve; reap requires a stale-past-grace lease as positive dead evidence).
# ---------------------------------------------------------------------------

@test "reap-worktrees: mapped worktree with NO lease record ever, past the floor, is preserved (MAJOR 1c)" {
  _make_bugsweep_branch "bugsweep/no-lease-mapped" "run mapping but no lease ever"
  _merge_branch_to_main "bugsweep/no-lease-mapped"
  local wt="${REPO}/.bugsweep/worktrees/no-lease-mapped"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/no-lease-mapped"
  wt="$(cd "$wt" && pwd -P)"
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "no-lease-mapped" "bugsweep/no-lease-mapped" "$wt")"
  _age_ledger "$run_dir"
  # NO _make_lease call: this run never had a lease record. Even merged and
  # past the (MIN_AGE=0) floor with a quiescent ledger, absence of any lease
  # record is ambiguous -> preserve, never reap.

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=0"
  echo "$output" | grep -q "WORKTREE_PRESERVED=${wt}"
  [ -d "$wt" ]
  _branch_exists "bugsweep/no-lease-mapped"
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss re-review MAJOR 2: resolve_pinned_target_branch's last
# resort must NOT fall back to caller cwd HEAD. In a repo whose default branch
# is not protected (e.g. trunk), an orphan worktree with no recorded target
# must have its branch PRESERVED, never deleted against ambient cwd ancestry.
# ---------------------------------------------------------------------------

@test "reap-worktrees: trunk-default repo, no resolvable target, unreviewed branch survives ambient cwd ancestry (MAJOR 2)" {
  # A repo whose default branch (trunk) is NOT in PROTECTED, with no main/master.
  local trepo="${BATS_TMP}/trunk-repo"
  git init -q "$trepo"
  git -C "$trepo" config user.email "test@bugsweep"
  git -C "$trepo" config user.name "bugsweep-test"
  git -C "$trepo" checkout -q -b trunk
  printf 'base\n' > "${trepo}/app.txt"
  git -C "$trepo" add app.txt
  git -C "$trepo" commit -q -m init

  # An unreviewed bugsweep fix, never merged into trunk.
  git -C "$trepo" checkout -q -b bugsweep/unreviewed-trunk trunk
  printf 'fix\n' > "${trepo}/app.txt"
  git -C "$trepo" add app.txt
  git -C "$trepo" commit -q -m "unreviewed fix"
  git -C "$trepo" checkout -q trunk

  # A canonical-path worktree for it, but NO run mapping (crashed run; .bugsweep
  # state reclaimed).
  mkdir -p "${trepo}/.bugsweep/worktrees"
  local wt="${trepo}/.bugsweep/worktrees/unreviewed-trunk"
  git -C "$trepo" worktree add -q "$wt" bugsweep/unreviewed-trunk

  # A sibling branch descending from the unreviewed fix, checked out in the
  # cwd the reaper is invoked from — the ambient HEAD the pre-fix last resort
  # would have (wrongly) pinned to.
  git -C "$trepo" checkout -q -b descends-from-unreviewed bugsweep/unreviewed-trunk
  git -C "$trepo" checkout -q trunk
  local other_wt="${BATS_TMP}/trunk-other"
  git -C "$trepo" worktree add -q "$other_wt" descends-from-unreviewed

  # No BUGSWEEP_TARGET, no protected branch exists -> resolve_pinned yields
  # empty. The unreviewed branch must SURVIVE.
  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash -c "cd '$other_wt' && bash '$CLEANUP_SH' --reap-worktrees"

  [ "$status" -eq 0 ]
  # Empty target -> no TARGET_BRANCH line, and NEVER the ambient cwd branch.
  ! echo "$output" | grep -q "TARGET_BRANCH=descends-from-unreviewed"
  ! echo "$output" | grep -q "BRANCH_PRUNED=bugsweep/unreviewed-trunk"
  git -C "$trepo" show-ref --verify --quiet refs/heads/bugsweep/unreviewed-trunk

  git -C "$trepo" worktree prune >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# bugsweep-8d0 dataloss re-review MAJOR 1 (done evidence): a run that recorded
# a .finalized sentinel is reaped deterministically (this is how finalize.sh
# reaps its own worktree despite a fresh ledger / released lease).
# ---------------------------------------------------------------------------

@test "reap-worktrees: a .finalized run is reaped even with a fresh ledger and no live lease (MAJOR 1 done-evidence)" {
  _make_bugsweep_branch "bugsweep/finalized-run" "finished fix, merged"
  _merge_branch_to_main "bugsweep/finalized-run"
  local wt="${REPO}/.bugsweep/worktrees/finalized-run"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/finalized-run"
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "finalized-run" "bugsweep/finalized-run" "$wt")"
  # Fresh ledger (would preserve under the liveness belts) + NO lease record,
  # but a .finalized sentinel => positive DONE evidence => reap deterministically.
  printf '{"event":"finalize"}\n' >> "${run_dir}/ledger.jsonl"
  _mark_finalized "$run_dir"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=1"
  echo "$output" | grep -q "BRANCH_PRUNED=bugsweep/finalized-run"
  [ ! -d "$wt" ]
  ! _branch_exists "bugsweep/finalized-run"
}

# ---------------------------------------------------------------------------
# bugsweep-cv0: run_dir_for_worktree returns only the FIRST matching
# run-*/state.env for a worktree and the DONE/.finalized reap path trusts
# that single match's sentinel without checking whether any OTHER state.env
# naming the same worktree is currently live. If an operator manually copies
# a .bugsweep/run-* directory (the only realistic way two state.env files
# name the same worktree — every real preflight run mints a unique run_dir),
# a lexically-first stale/copied ".finalized" must never let the reaper
# bypass a genuinely live lease recorded under a different (lexically later)
# run_dir for that same worktree.
# ---------------------------------------------------------------------------

@test "reap-worktrees: a second state.env mapping the same worktree with a LIVE lease is not bypassed by a first-matched stale .finalized sentinel (bugsweep-cv0)" {
  _make_bugsweep_branch "bugsweep/dup-mapping" "fix with duplicate state.env mapping"
  local wt="${REPO}/.bugsweep/worktrees/dup-mapping"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/dup-mapping"
  wt="$(cd "$wt" && pwd -P)"

  # Lexically-FIRST state.env for this worktree ("run-a-decoy" sorts before
  # "run-b-live" in the run-*/state.env glob): carries a stale/copied
  # .finalized sentinel and has NO live lease of its own — this is what a
  # manually-copied .bugsweep/run-* directory looks like.
  local rd_a
  rd_a="$(_make_run_dir_for_worktree "a-decoy" "bugsweep/dup-mapping" "$wt")"
  _mark_finalized "$rd_a"

  # Lexically-SECOND state.env naming the SAME worktree, with a genuinely
  # LIVE lease (this test process's own pid). The reaper must never bypass
  # this live mapping just because it wasn't the first (lexical) match.
  local rd_b
  rd_b="$(_make_run_dir_for_worktree "b-live" "bugsweep/dup-mapping" "$wt")"
  _make_lease "run-dup-mapping-live" "$rd_b" "$$"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=0"
  echo "$output" | grep -q "WORKTREE_PRESERVED=${wt}"
  [ -d "$wt" ]
  _branch_exists "bugsweep/dup-mapping"
}

@test "reap-worktrees: single state.env, .finalized, no live lease is still reaped (happy path unaffected by bugsweep-cv0 guard)" {
  _make_bugsweep_branch "bugsweep/single-mapping-done" "genuinely finished single-mapping run"
  _merge_branch_to_main "bugsweep/single-mapping-done"
  local wt="${REPO}/.bugsweep/worktrees/single-mapping-done"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/single-mapping-done"
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "single-mapping-done" "bugsweep/single-mapping-done" "$wt")"
  _mark_finalized "$run_dir"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=1"
  echo "$output" | grep -q "BRANCH_PRUNED=bugsweep/single-mapping-done"
  [ ! -d "$wt" ]
  ! _branch_exists "bugsweep/single-mapping-done"
}

# ---------------------------------------------------------------------------
# bugsweep-gqw item 1 (secondary "positive-dead-evidence" reap path) was
# designed and then REMOVED after an adversarial production-default repro:
# no-lease + quiescent-ledger + worktree-mtime-past-grace + branch-contained
# are ALL satisfiable by a genuinely LIVE run, so any such reap could delete
# the working directory a live subagent is executing in. The pre-gqw
# "no lease record ever -> preserve" belt (preserve-biased, correct) is
# restored; a lingering dead worktree is an accepted disk-hygiene cost. The
# existing MAJOR-1c preserve tests above ("worktree with no lease record and
# age below the grace floor is preserved", "mapped worktree with NO lease
# record ever, past the floor, is preserved") already lock that
# preserve-biased behavior in, so no item-1 tests remain.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# bugsweep-gqw item 2: the `reap_worktrees || reap_status=$?` idiom (needed so
# the reap lock is ALWAYS structurally released, MINOR 4) disables `set -e`
# for the entire reap_worktrees() body. A failed mktemp (e.g. an unwritable or
# nonexistent TMPDIR) must never be silently swallowed into a dishonest
# "REAP_RESULT=ok" with all-zero counts.
# ---------------------------------------------------------------------------

@test "reap-worktrees: mktemp/infrastructure failure is reported honestly as REAP_RESULT=error, never a silent ok (item 2)" {
  local bogus_tmpdir="${BATS_TMP}/does-not-exist/nested/nope"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main TMPDIR="$bogus_tmpdir" \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "REAP_RESULT=error"
  ! echo "$output" | grep -q "REAP_RESULT=ok"
}

# ---------------------------------------------------------------------------
# bugsweep-gqw item 3: LEASES_RELEASED counts every stale lease this call's
# own state.sh lease-list reclaimed among worktrees it processed — including
# ones that were PRESERVED (e.g. a lapsed lease whose worktree was kept alive
# by the ledger-activity belt, MAJOR 1b). That is not "worktrees reaped".
# LEASES_RELEASED_REAPED is the accurate subset restricted to worktrees this
# call actually removed.
# ---------------------------------------------------------------------------

@test "reap-worktrees: LEASES_RELEASED_REAPED excludes a preserved worktree whose stale lease this call itself reclaimed (item 3)" {
  _make_bugsweep_branch "bugsweep/lease-reclaimed-preserved" "long hunt, lease lapsed but ledger fresh"
  local wt="${REPO}/.bugsweep/worktrees/lease-reclaimed-preserved"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/lease-reclaimed-preserved"
  wt="$(cd "$wt" && pwd -P)"
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "lease-reclaimed-preserved" "bugsweep/lease-reclaimed-preserved" "$wt")"
  # Lease lapsed past grace (dead pid + aged lease file) -> reclaimed by THIS
  # call's own state.sh lease-list. Ledger left FRESH so the MAJOR 1b
  # fresh-ledger belt preserves the worktree despite the reclaim.
  _make_lease "run-lease-reclaimed-preserved" "$run_dir" 999999 old
  printf '{"event":"batch_covered","batch":1}\n' >> "${run_dir}/ledger.jsonl"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=0"
  echo "$output" | grep -q "WORKTREE_PRESERVED=${wt}"
  echo "$output" | grep -q "LEASES_RELEASED=1"
  echo "$output" | grep -q "LEASES_RELEASED_REAPED=0"
  [ -d "$wt" ]
  _branch_exists "bugsweep/lease-reclaimed-preserved"
}

@test "reap-worktrees: LEASES_RELEASED_REAPED equals LEASES_RELEASED for a worktree that was actually reaped (item 3 sanity)" {
  _make_bugsweep_branch "bugsweep/lease-reclaimed-reaped" "genuinely dead run, actually reaped"
  local wt="${REPO}/.bugsweep/worktrees/lease-reclaimed-reaped"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$wt" "bugsweep/lease-reclaimed-reaped"
  local run_dir
  run_dir="$(_make_run_dir_for_worktree "lease-reclaimed-reaped" "bugsweep/lease-reclaimed-reaped" "$wt")"
  _make_lease "run-lease-reclaimed-reaped" "$run_dir" 999999 old
  _age_ledger "$run_dir"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WORKTREES_REMOVED=1"
  echo "$output" | grep -q "LEASES_RELEASED=1"
  echo "$output" | grep -q "LEASES_RELEASED_REAPED=1"
  [ ! -d "$wt" ]
}

@test "reap-worktrees: skipped_locked path emits LEASES_RELEASED_REAPED=0 alongside the other zeroed counters (item 3 contract)" {
  local lockdir="${REPO}/.bugsweep/.reap-worktrees.lock"
  mkdir -p "$lockdir"
  printf '%s' "$$" > "${lockdir}/pid"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_REAP_LOCK_TIMEOUT=1 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "REAP_RESULT=skipped_locked"
  echo "$output" | grep -q "^LEASES_RELEASED_REAPED=0$"

  rm -f "${lockdir}/pid"
  rmdir "$lockdir" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# bugsweep-l2r (Part B): belt-and-suspenders sweep for PRE-EXISTING orphaned
# bugsweep-integrate-results.* temp dirs. Part A (scripts/integrate.sh) now
# stops the leak at the source via its own exit trap, but this reaper still
# needs to clean up dirs that predate that fix (or survived a SIGKILL the
# trap could never catch). Scoped to BUGSWEEP_WORKTREES_DIR — the documented
# "p74 topology" location where concurrent sibling integrate.sh invocations
# (each cwd'd into its own worktree) create these dirs as CWD-adjacent
# siblings of the worktrees themselves. Reap requires the conjunction of (1)
# a completed integrate-results.json, (2) no in-progress marker, and (3) age
# past a GENEROUS floor — a strict multiple of the plain lease-grace window,
# never exactly grace. Any ambiguity -> preserve.
# ---------------------------------------------------------------------------

_make_orphan_results_dir() {
  local name="$1" have_json="${2:-yes}" in_progress="${3:-no}"
  local dir="${REPO}/.bugsweep/worktrees/bugsweep-integrate-results.${name}"
  mkdir -p "$dir"
  if [ "$have_json" = "yes" ]; then
    printf '{"result":"complete"}\n' > "${dir}/integrate-results.json"
  fi
  if [ "$in_progress" = "yes" ]; then
    : > "${dir}/.in-progress"
  fi
  printf '%s\n' "$dir"
}

@test "reap-worktrees: sweeps an OLD orphaned bugsweep-integrate-results.* dir with a completed json and no in-progress marker" {
  local orphan
  orphan="$(_make_orphan_results_dir "OLD1")"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_INTEGRATE_RESULTS_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  [ ! -d "$orphan" ]
  # Auditable per-removal log line.
  echo "$output" | grep -qi "swept.*${orphan}\|${orphan}.*swept"
}

@test "reap-worktrees: preserves a RECENT bugsweep-integrate-results.* dir (below the default generous sweep floor)" {
  local orphan
  orphan="$(_make_orphan_results_dir "FRESH1")"

  # No age-floor override: the dir was just created, so it is far younger
  # than the default floor (a strict multiple of the lease-grace window).
  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  [ -d "$orphan" ]
  [ -f "${orphan}/integrate-results.json" ]
}

@test "reap-worktrees: preserves a bugsweep-integrate-results.* dir with an in-progress marker present, even when old" {
  local orphan
  orphan="$(_make_orphan_results_dir "INPROG1" "yes" "yes")"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_INTEGRATE_RESULTS_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  [ -d "$orphan" ]
  [ -f "${orphan}/.in-progress" ]
}

@test "reap-worktrees: preserves a bugsweep-integrate-results.* dir with NO completed integrate-results.json, even when old" {
  local orphan
  orphan="$(_make_orphan_results_dir "NOJSON1" "no")"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_INTEGRATE_RESULTS_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  [ -d "$orphan" ]
  [ ! -f "${orphan}/integrate-results.json" ]
}

@test "reap-worktrees: never touches a sibling directory that does not match the exact bugsweep-integrate-results.* prefix" {
  mkdir -p "${REPO}/.bugsweep/worktrees"
  local decoy1="${REPO}/.bugsweep/worktrees/bugsweep-integrate-result.DECOY"    # missing trailing 's'
  local decoy2="${REPO}/.bugsweep/worktrees/notbugsweep-integrate-results.DECOY"
  mkdir -p "$decoy1" "$decoy2"
  printf '{"result":"complete"}\n' > "${decoy1}/integrate-results.json"
  printf '{"result":"complete"}\n' > "${decoy2}/integrate-results.json"
  touch -t 202001010000 "$decoy1" "$decoy2"

  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_INTEGRATE_RESULTS_MIN_AGE_SECONDS=0 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  [ -d "$decoy1" ]
  [ -d "$decoy2" ]
}

@test "reap-worktrees: sweep floor is a strict multiple of the grace window, not exactly grace (an orphan past grace but under the floor is preserved)" {
  local old_orphan young_orphan

  old_orphan="$(_make_orphan_results_dir "PASTGRACE")"
  sleep 3
  young_orphan="$(_make_orphan_results_dir "WITHINGRACE")"
  sleep 2

  # grace=1s: if the floor were exactly grace(1s), BOTH dirs (now 5s and 2s
  # old respectively) would be swept. The default floor is a strict multiple
  # of grace (> 1s) — only the dir past that higher bar may be swept.
  run env BUGSWEEP_ALLOW_PROTECTED=1 BUGSWEEP_TARGET=main BUGSWEEP_LEASE_GRACE_SECONDS=1 \
    bash "$CLEANUP_SH" --reap-worktrees

  [ "$status" -eq 0 ]
  [ ! -d "$old_orphan" ]
  [ -d "$young_orphan" ]
}
