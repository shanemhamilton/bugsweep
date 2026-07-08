#!/usr/bin/env bats
# Tests for scripts/integrate.sh — ordered, re-verifying multi-branch integration
# (bugsweep-5e8). The nightshift orchestrator produces up to 5 sibling bugsweep/*
# branches; this script merges an ORDERED list of them into a target branch,
# re-running the quality gate after EACH merge, stopping cleanly (and rolling
# back) the instant a merge goes red or conflicts.

INTEGRATE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/integrate.sh"

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

# Creates a bugsweep branch off main that touches its OWN file, so siblings
# never textually conflict with each other unless the test explicitly wants
# a conflict (see the conflict test, which edits the same file/line as main).
_make_bugsweep_branch() {
  local branch="$1" file="$2" content="$3"
  git -C "$REPO" checkout -b "$branch" main -q
  printf '%s\n' "$content" > "${REPO}/${file}"
  git -C "$REPO" add "$file"
  git -C "$REPO" commit -m "fix: ${branch}" -q
  git -C "$REPO" checkout main -q
}

_branch_exists() {
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$1"
}

_current_sha() {
  git -C "$REPO" rev-parse "$1"
}

# A stub quality-gate script that records how many times it was invoked (one
# line per call to $CALL_LOG) and can be configured to fail starting on a given
# call number via $FAIL_FROM_CALL (0/unset = never fail).
_write_stub_gate() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${CALL_LOG:?}"
n=0
[ -f "$CALL_LOG" ] && n=$(wc -l < "$CALL_LOG" | tr -d ' ')
n=$((n + 1))
printf '%s\n' "$n" >> "$CALL_LOG"
if [ -n "${FAIL_FROM_CALL:-}" ] && [ "$n" -ge "$FAIL_FROM_CALL" ]; then
  echo "stub gate: FAIL (call $n)" >&2
  exit 1
fi
echo "stub gate: PASS (call $n)"
exit 0
STUB
  chmod +x "$path"
}

# An INTERACTION-DRIVEN stub gate (TEST HONESTY 8): it inspects the actual repo
# state at the moment it runs and fails ONLY when BOTH marker files introduced
# by two different branches are simultaneously present in the working tree —
# i.e. a genuine semantic regression that appears only once the second branch
# has landed on top of the first. Call-count is irrelevant; content is what
# matters, so this proves the rollback targets the right (second) merge.
_write_marker_gate() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${CALL_LOG:?}"
: "${MARKER_A:?}"
: "${MARKER_B:?}"
n=0
[ -f "$CALL_LOG" ] && n=$(wc -l < "$CALL_LOG" | tr -d ' ')
n=$((n + 1))
printf '%s\n' "$n" >> "$CALL_LOG"
if [ -f "$MARKER_A" ] && [ -f "$MARKER_B" ]; then
  echo "marker gate: FAIL — both $MARKER_A and $MARKER_B present (semantic regression)" >&2
  exit 1
fi
echo "marker gate: PASS (call $n)"
exit 0
STUB
  chmod +x "$path"
}

# A stub gate that PASSES but DIRTIES the working tree as a side effect — the way
# a real test runner leaks .coverage / __pycache__/*.pyc artifacts (BLOCKER 2).
# Writes an untracked file into the repo it runs in.
_write_tree_dirtying_gate() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${CALL_LOG:?}"
n=0
[ -f "$CALL_LOG" ] && n=$(wc -l < "$CALL_LOG" | tr -d ' ')
n=$((n + 1))
printf '%s\n' "$n" >> "$CALL_LOG"
# Simulate a leaked build artifact (untracked file) in the CURRENT repo.
printf 'leaked coverage artifact\n' > ".gate-leaked-artifact"
echo "tree-dirtying gate: PASS but left an artifact (call $n)"
exit 0
STUB
  chmod +x "$path"
}

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  GATE="${BATS_TMP}/stub-gate.sh"
  MARKER_GATE="${BATS_TMP}/marker-gate.sh"
  DIRTY_GATE="${BATS_TMP}/dirty-gate.sh"
  CALL_LOG="${BATS_TMP}/gate-calls.log"
  _write_stub_gate "$GATE"
  _write_marker_gate "$MARKER_GATE"
  _write_tree_dirtying_gate "$DIRTY_GATE"
  cd "$REPO"
}

# Emit only the executable (non-comment, non-blank) lines of the script, so a
# grep guard tests actual code rather than prose in the header/comments.
_code_lines() {
  grep -vE '^[[:space:]]*#' "$INTEGRATE_SH" | grep -vE '^[[:space:]]*$'
}

# Sum every per-branch bucket the output contract reports and assert it equals
# the number of input branches (BLOCKER 3 invariant: buckets partition inputs).
_assert_counts_partition_inputs() {
  local out="$1" expected="$2" merged already preserved sum
  merged="$(printf '%s\n' "$out" | sed -n 's/^MERGED_COUNT=//p')"
  already="$(printf '%s\n' "$out" | sed -n 's/^ALREADY_CONTAINED_COUNT=//p')"
  preserved="$(printf '%s\n' "$out" | sed -n 's/^PRESERVED_COUNT=//p')"
  : "${merged:=0}" "${already:=0}" "${preserved:=0}"
  sum=$((merged + already + preserved))
  [ "$sum" -eq "$expected" ]
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

# --- Acceptance criterion 1: sequential merge with gate re-run between each ---

@test "integrate: merges 3 siblings in order, re-running the quality gate after each" {
  _make_bugsweep_branch "bugsweep/one" "one.txt" "fix one"
  _make_bugsweep_branch "bugsweep/two" "two.txt" "fix two"
  _make_bugsweep_branch "bugsweep/three" "three.txt" "fix three"

  pre_target_sha="$(_current_sha main)"

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/one bugsweep/two bugsweep/three

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/one:merged"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/two:merged"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/three:merged"
  echo "$output" | grep -q "INTEGRATE_RESULT=complete"
  echo "$output" | grep -q "MERGED_COUNT=3"
  echo "$output" | grep -q "ALREADY_CONTAINED_COUNT=0"
  echo "$output" | grep -q "PRESERVED_COUNT=0"
  _assert_counts_partition_inputs "$output" 3

  # Gate re-ran once per branch (3 merges -> 3 gate invocations).
  [ "$(wc -l < "$CALL_LOG" | tr -d ' ')" -eq 3 ]

  [ -f "${REPO}/one.txt" ]
  [ -f "${REPO}/two.txt" ]
  [ -f "${REPO}/three.txt" ]
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "main" ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]

  # The target ref only ever moved FORWARD: its pre-run sha must be an ancestor
  # of where it ended (fast-forward-only advance onto gate-passed commits).
  git -C "$REPO" merge-base --is-ancestor "$pre_target_sha" main
  # All three fixes are contained.
  git -C "$REPO" merge-base --is-ancestor bugsweep/one main
  git -C "$REPO" merge-base --is-ancestor bugsweep/two main
  git -C "$REPO" merge-base --is-ancestor bugsweep/three main
}

# --- Acceptance criterion 2: gate regresses AFTER a prior good merge ---------
# INTERACTION-DRIVEN (TEST HONESTY 8): the marker gate fails only when BOTH
# good.txt and regressor.txt are simultaneously present in the tree — a genuine
# semantic regression that appears only once the second branch lands on the
# first. Nothing here depends on the gate's call count, so it would catch the
# WRONG branch being rolled back (if integrate rolled back bugsweep/good instead
# of bugsweep/regressor, one marker would be absent and the gate would pass).

@test "integrate: gate failure after a prior good merge abandons the bad merge (never git reset --hard on the target), preserves remaining branches, stops cleanly" {
  _make_bugsweep_branch "bugsweep/good" "good.txt" "fix good"
  _make_bugsweep_branch "bugsweep/regressor" "regressor.txt" "fix regressor"
  _make_bugsweep_branch "bugsweep/never-attempted" "never.txt" "fix never"

  pre_target_sha="$(_current_sha main)"
  good_only_sha=""  # captured below via the target's post-first-merge tip

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $MARKER_GATE" CALL_LOG="$CALL_LOG" \
    MARKER_A="${REPO}/good.txt" MARKER_B="${REPO}/regressor.txt" \
    bash "$INTEGRATE_SH" main bugsweep/good bugsweep/regressor bugsweep/never-attempted

  [ "$status" -eq 1 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/good:merged"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/regressor:gate_failed"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/never-attempted:skipped_after_stop"
  echo "$output" | grep -q "INTEGRATE_RESULT=stopped"
  echo "$output" | grep -q "STOPPED_AT=bugsweep/regressor"
  echo "$output" | grep -q "MERGED_COUNT=1"
  echo "$output" | grep -q "ALREADY_CONTAINED_COUNT=0"
  echo "$output" | grep -q "PRESERVED_COUNT=2"
  _assert_counts_partition_inputs "$output" 3

  # bugsweep/good's merge commit remains contained; bugsweep/regressor's merge
  # was abandoned so the target does NOT contain it.
  git -C "$REPO" merge-base --is-ancestor "bugsweep/good" main
  ! git -C "$REPO" merge-base --is-ancestor "bugsweep/regressor" main

  # The target advanced ONLY forward: its pre-run sha is still an ancestor of
  # where it ended (fast-forward-only onto the gate-passed good merge). This is
  # the observable signature of "never moved to a bad state and reset back".
  git -C "$REPO" merge-base --is-ancestor "$pre_target_sha" main
  [ "$(_current_sha main)" != "$pre_target_sha" ]

  [ ! -f "${REPO}/regressor.txt" ]
  [ -f "${REPO}/good.txt" ]

  [ -z "$(git -C "$REPO" status --porcelain)" ]
  [ ! -f "${REPO}/.git/MERGE_HEAD" ]
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "main" ]

  # Source branches themselves are NEVER touched/rewritten.
  _branch_exists "bugsweep/good"
  _branch_exists "bugsweep/regressor"
  _branch_exists "bugsweep/never-attempted"
}

@test "integrate: the redesign never invokes git reset --hard in executable code" {
  ! _code_lines | grep -E -- 'reset[[:space:]]+--hard'
}

# --- Acceptance criterion 3: textual conflict -------------------------------

@test "integrate: textual conflict aborts merge, preserves branch, does not attempt later branches" {
  _make_bugsweep_branch "bugsweep/conflict" "app.txt" "conflicting change"
  _make_bugsweep_branch "bugsweep/after-conflict" "after.txt" "fix after"

  # Make main diverge on the SAME file/line so the merge textually conflicts.
  git -C "$REPO" checkout main -q
  printf 'target side change\n' > "${REPO}/app.txt"
  git -C "$REPO" add app.txt
  git -C "$REPO" commit -m "target change" -q
  pre_target_sha="$(_current_sha main)"

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/conflict bugsweep/after-conflict

  [ "$status" -eq 1 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/conflict:conflict"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/after-conflict:skipped_after_stop"
  echo "$output" | grep -q "INTEGRATE_RESULT=stopped"
  echo "$output" | grep -q "STOPPED_AT=bugsweep/conflict"
  echo "$output" | grep -q "MERGED_COUNT=0"
  echo "$output" | grep -q "PRESERVED_COUNT=2"

  [ "$(_current_sha main)" = "$pre_target_sha" ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
  [ ! -f "${REPO}/.git/MERGE_HEAD" ]
  _branch_exists "bugsweep/conflict"
  _branch_exists "bugsweep/after-conflict"

  # The quality gate must never even run for a textual conflict — there is
  # nothing to verify since the merge itself never landed.
  [ ! -f "$CALL_LOG" ]
}

# --- Acceptance criterion 4: idempotency ------------------------------------

@test "integrate: re-running after a partial integration reports already_contained, no duplicate merges" {
  _make_bugsweep_branch "bugsweep/alpha" "alpha.txt" "fix alpha"
  _make_bugsweep_branch "bugsweep/beta" "beta.txt" "fix beta"

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/alpha bugsweep/beta
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/alpha:merged"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/beta:merged"

  merge_commit_count_before="$(git -C "$REPO" log --oneline --merges main | wc -l | tr -d ' ')"

  # Re-run the exact same invocation — both branches are already contained.
  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/alpha bugsweep/beta

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/alpha:already_contained"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/beta:already_contained"
  echo "$output" | grep -q "INTEGRATE_RESULT=complete"
  echo "$output" | grep -q "MERGED_COUNT=0"
  echo "$output" | grep -q "ALREADY_CONTAINED_COUNT=2"
  echo "$output" | grep -q "PRESERVED_COUNT=0"
  # BLOCKER 3 invariant: 2 already-contained branches must be counted (2+0+0=2).
  _assert_counts_partition_inputs "$output" 2

  merge_commit_count_after="$(git -C "$REPO" log --oneline --merges main | wc -l | tr -d ' ')"
  [ "$merge_commit_count_before" -eq "$merge_commit_count_after" ]
}

@test "integrate: idempotent re-run after a stop resumes from the failure point without re-attempting merged branches" {
  _make_bugsweep_branch "bugsweep/first" "first.txt" "fix first"
  # Cut bugsweep/second from main BEFORE main diverges, so main's later change
  # to the same file/line produces a genuine, reproducible textual conflict.
  _make_bugsweep_branch "bugsweep/second" "second.txt" "branch side"

  git -C "$REPO" checkout main -q
  printf 'target side\n' > "${REPO}/second.txt"
  git -C "$REPO" add second.txt
  git -C "$REPO" commit -m "main diverges on second.txt" -q

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/first bugsweep/second
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/first:merged"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/second:conflict"

  first_calls="$(wc -l < "$CALL_LOG" | tr -d ' ')"

  # Re-run: bugsweep/first should be reported already_contained (no re-merge,
  # no re-invocation of the gate for it); bugsweep/second still conflicts.
  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/first bugsweep/second

  [ "$status" -eq 1 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/first:already_contained"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/second:conflict"

  second_calls="$(wc -l < "$CALL_LOG" | tr -d ' ')"
  # already_contained branches must not re-invoke the gate.
  [ "$second_calls" -eq "$first_calls" ]
}

# --- Acceptance criterion 5: never force; explicit target required ---------
# MINOR 6: this is a broad regression guard against every destructive/force
# idiom the trust contract forbids — not a proof of safety, but wide enough
# that reintroducing any of them trips the test.

@test "integrate: executable code contains none of the forbidden destructive/force idioms" {
  local code
  code="$(_code_lines)"
  ! printf '%s\n' "$code" | grep -E -- '--force\b'
  ! printf '%s\n' "$code" | grep -E -- '--force-with-lease'
  ! printf '%s\n' "$code" | grep -E -- '\bgit[^|;]*push'
  ! printf '%s\n' "$code" | grep -E -- 'branch[[:space:]]+-D\b'
  ! printf '%s\n' "$code" | grep -E -- 'checkout[[:space:]]+-f\b'
  ! printf '%s\n' "$code" | grep -E -- 'checkout[[:space:]].*--force'
  ! printf '%s\n' "$code" | grep -E -- 'clean[[:space:]]+-[a-z]*f'
  ! printf '%s\n' "$code" | grep -E -- 'reset[[:space:]]+--hard'
  ! printf '%s\n' "$code" | grep -E -- 'update-ref[[:space:]]+-d'
}

@test "integrate: refuses to run without an explicit target branch argument" {
  _make_bugsweep_branch "bugsweep/needs-target" "x.txt" "fix"

  run bash "$INTEGRATE_SH"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "usage\|target"
}

@test "integrate: refuses to run when no branches are given" {
  run bash "$INTEGRATE_SH" main
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "usage\|branch"
}

@test "integrate: refuses to run when working tree is dirty" {
  _make_bugsweep_branch "bugsweep/x" "x.txt" "fix x"
  printf 'dirty\n' > "${REPO}/dirty.txt"

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/x
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "dirty\|clean"
  _branch_exists "bugsweep/x"
}

@test "integrate: refuses to run when a merge is already in progress" {
  _make_bugsweep_branch "bugsweep/mid-merge" "mid.txt" "fix mid"
  _make_bugsweep_branch "bugsweep/other" "other.txt" "fix other"

  # Force main into a conflicted, in-progress merge state.
  git -C "$REPO" checkout main -q
  printf 'main side\n' > "${REPO}/mid.txt"
  git -C "$REPO" add mid.txt
  git -C "$REPO" commit -m "main side of conflict" -q
  git -C "$REPO" merge bugsweep/mid-merge -q 2>/dev/null || true
  [ -f "${REPO}/.git/MERGE_HEAD" ]

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/other
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "merge\|progress"

  git -C "$REPO" merge --abort
}

@test "integrate: defaults to bash scripts/run_checks.sh verify <RUN_DIR> convention when RUN_DIR given and no override" {
  _make_bugsweep_branch "bugsweep/rd" "rd.txt" "fix rd"
  RUN_DIR="${BATS_TMP}/run"
  mkdir -p "$RUN_DIR"

  # The default quality-gate command is relative ("scripts/run_checks.sh"), the
  # same convention finalize.sh documents in post-finalize-handoff.json: it is
  # meant to run from the TARGET repo's root, where bugsweep's own scripts/ is
  # installed. Simulate that by copying the real run_checks.sh + common.sh into
  # this throwaway repo (committed, so the working tree stays clean going in —
  # integrate.sh refuses to run on a dirty tree).
  mkdir -p "${REPO}/scripts"
  cp "$(dirname "$INTEGRATE_SH")/run_checks.sh" "${REPO}/scripts/run_checks.sh"
  cp "$(dirname "$INTEGRATE_SH")/common.sh" "${REPO}/scripts/common.sh"
  git -C "$REPO" add scripts
  git -C "$REPO" commit -q -m "vendor run_checks.sh + common.sh for the test"

  # No BUGSWEEP_QUALITY_GATE_COMMAND override: integrate.sh should fall back to
  # the documented convention. run_checks.sh with no test/build/lint detected
  # in this throwaway repo reports NO_CHECKS and exits 0, so the merge proceeds.
  run bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" main bugsweep/rd

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/rd:merged"
  [ -f "${RUN_DIR}/integrate-results.json" ]
}

# --- Output contract: integrate-results.json --------------------------------

@test "integrate: writes machine-readable integrate-results.json into RUN_DIR" {
  _make_bugsweep_branch "bugsweep/json" "json.txt" "fix json"
  RUN_DIR="${BATS_TMP}/run2"
  mkdir -p "$RUN_DIR"

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" main bugsweep/json

  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/integrate-results.json" ]
  grep -q '"result": *"complete"' "${RUN_DIR}/integrate-results.json"
  grep -q '"bugsweep/json"' "${RUN_DIR}/integrate-results.json"
  grep -q '"merged"' "${RUN_DIR}/integrate-results.json"
}

@test "integrate: writes integrate-results.json CWD-adjacent (not inside the repo) when no RUN_DIR is provided" {
  _make_bugsweep_branch "bugsweep/nord" "nord.txt" "fix nord"

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/nord

  [ "$status" -eq 0 ]
  results_line="$(printf '%s\n' "$output" | grep '^RESULTS_JSON=')"
  results_path="${results_line#RESULTS_JSON=}"
  [ -f "$results_path" ]
  grep -q '"result": *"complete"' "$results_path"

  # Must NOT be written inside the target repo's working tree — that would
  # leave an untracked file behind and make the "tree is clean" guarantee false.
  [ ! -f "${REPO}/integrate-results.json" ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}

# --- BLOCKER 2: a tree-dirtying gate must be caught, not carried forward -----

@test "integrate: a quality gate that dirties the working tree yields gate_dirtied_tree, stops, and does not carry into the next branch" {
  _make_bugsweep_branch "bugsweep/dirtier" "dirtier.txt" "fix dirtier"
  _make_bugsweep_branch "bugsweep/after-dirty" "after-dirty.txt" "fix after"

  pre_target_sha="$(_current_sha main)"

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $DIRTY_GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/dirtier bugsweep/after-dirty

  [ "$status" -eq 1 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/dirtier:gate_dirtied_tree"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/after-dirty:skipped_after_stop"
  echo "$output" | grep -q "INTEGRATE_RESULT=stopped"
  echo "$output" | grep -q "STOPPED_AT=bugsweep/dirtier"
  echo "$output" | grep -q "MERGED_COUNT=0"
  echo "$output" | grep -q "PRESERVED_COUNT=2"
  _assert_counts_partition_inputs "$output" 2

  # The dirtied branch is NOT landed; the target never advanced.
  ! git -C "$REPO" merge-base --is-ancestor "bugsweep/dirtier" main
  [ "$(_current_sha main)" = "$pre_target_sha" ]

  # The gate ran exactly once — it must NOT have proceeded to branch 2 (which
  # is what "never silently carried into branch N+1" means).
  [ "$(wc -l < "$CALL_LOG" | tr -d ' ')" -eq 1 ]

  _branch_exists "bugsweep/dirtier"
  _branch_exists "bugsweep/after-dirty"
}

@test "integrate: header documents that quality-gate commands must be tree-neutral" {
  grep -qi "tree-neutral\|must not.*writ\|write only outside\|leave.*artifact" "$INTEGRATE_SH"
}

# --- BLOCKER 3: bucket partition holds for every terminal outcome ------------

@test "integrate: counts partition inputs on a conflict-stop" {
  _make_bugsweep_branch "bugsweep/cf" "app.txt" "conflict change"
  _make_bugsweep_branch "bugsweep/cf-after" "cf-after.txt" "after"
  git -C "$REPO" checkout main -q
  printf 'target side\n' > "${REPO}/app.txt"
  git -C "$REPO" add app.txt
  git -C "$REPO" commit -m "target diverges" -q

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/cf bugsweep/cf-after
  [ "$status" -eq 1 ]
  _assert_counts_partition_inputs "$output" 2
}

@test "integrate: counts partition inputs on a mixed already-contained + merged run" {
  _make_bugsweep_branch "bugsweep/pre" "pre.txt" "fix pre"
  # Land bugsweep/pre first.
  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/pre
  [ "$status" -eq 0 ]
  # Now add a fresh branch and re-run with both: pre is already_contained, new merges.
  _make_bugsweep_branch "bugsweep/fresh" "fresh.txt" "fix fresh"
  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/pre bugsweep/fresh
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/pre:already_contained"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/fresh:merged"
  echo "$output" | grep -q "MERGED_COUNT=1"
  echo "$output" | grep -q "ALREADY_CONTAINED_COUNT=1"
  echo "$output" | grep -q "PRESERVED_COUNT=0"
  _assert_counts_partition_inputs "$output" 2
}

# --- MAJOR 4: no-python JSON fallback must be quote/backslash safe -----------

@test "integrate: no-python fallback JSON is valid for a branch name containing a double-quote" {
  # git rejects spaces, tabs, and backslash in ref names, but PERMITS a literal
  # double-quote (verified via git check-ref-format) — the case that breaks a
  # naive hand-rolled JSON writer. Build such a branch.
  weird='bugsweep/we"ird'
  git -C "$REPO" check-ref-format "refs/heads/$weird"   # sanity: git allows it
  git -C "$REPO" checkout -b "$weird" main -q
  printf 'weird fix\n' > "${REPO}/weird.txt"
  git -C "$REPO" add weird.txt
  git -C "$REPO" commit -m "fix weird" -q
  git -C "$REPO" checkout main -q

  RUN_DIR="${BATS_TMP}/run-weird"
  mkdir -p "$RUN_DIR"

  # Force the degraded (no-python3) path via BUGSWEEP_FORCE_NO_PYTHON.
  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    BUGSWEEP_FORCE_NO_PYTHON=1 \
    bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" main "$weird"

  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/integrate-results.json" ]

  # The emitted JSON must PARSE and round-trip the branch name exactly. The
  # script produced it via its no-python fallback; validate with python3 here.
  if command -v python3 >/dev/null 2>&1; then
    run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["branches"][0]["branch"]==sys.argv[2], d; print("VALID")' \
      "${RUN_DIR}/integrate-results.json" "$weird"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "VALID"
  fi
}

# --- MINOR 5: --run-dir that does not exist -----------------------------------

@test "integrate: creates a non-existent --run-dir rather than silently substituting a temp path" {
  _make_bugsweep_branch "bugsweep/mk" "mk.txt" "fix mk"
  RUN_DIR="${BATS_TMP}/does-not-exist-yet/nested"

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" main bugsweep/mk

  [ "$status" -eq 0 ]
  # The results file lands in the caller-specified RUN_DIR, not a random temp dir.
  [ -f "${RUN_DIR}/integrate-results.json" ]
  echo "$output" | grep -q "RESULTS_JSON=${RUN_DIR}/integrate-results.json"
}

# --- MAJOR 1 (retry 2): the temp results dir must NOT destroy a concurrent peer
# The p74 sibling-concurrency topology runs multiple integrate.sh invocations in
# sibling worktrees under the same parent. A no-run-dir run must NEVER delete
# another live run's bugsweep-integrate-results.* dir (which may hold an unread
# integrate-results.json). The prior "reaper" did exactly that; it is removed.

@test "integrate: a concurrent peer's live results dir survives a second no-run-dir run" {
  _make_bugsweep_branch "bugsweep/peerA" "a.txt" "fix a"

  parent="$(dirname "$REPO")"
  # Simulate a concurrently-LIVE peer run's results dir with an unread JSON.
  peer_dir="${parent}/bugsweep-integrate-results.PEERLIVE"
  mkdir -p "$peer_dir"
  printf '{"live":"peer results not yet read"}\n' > "${peer_dir}/integrate-results.json"

  run env BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/peerA
  [ "$status" -eq 0 ]

  # The peer's live results dir and its unread JSON MUST still be intact.
  [ -d "$peer_dir" ]
  [ -f "${peer_dir}/integrate-results.json" ]
  grep -q 'peer results not yet read' "${peer_dir}/integrate-results.json"

  # This run wrote its own results file (distinct from the peer's).
  results_line="$(printf '%s\n' "$output" | grep '^RESULTS_JSON=')"
  results_path="${results_line#RESULTS_JSON=}"
  [ -f "$results_path" ]
  [ "$results_path" != "${peer_dir}/integrate-results.json" ]
}

@test "integrate: source does not reap/glob-delete bugsweep-integrate-results dirs" {
  # Regression guard against reintroducing the data-loss reaper in any form:
  # no rm targeting those dirs, and no glob-loop over sibling results dirs.
  local code
  code="$(_code_lines)"
  ! printf '%s\n' "$code" | grep -E 'rm[[:space:]].*bugsweep-integrate-results'
  ! printf '%s\n' "$code" | grep -E 'for[[:space:]].*bugsweep-integrate-results\.\*'
  ! printf '%s\n' "$code" | grep -E 'rm[[:space:]]+-rf?.*"?\$\{?(stale|peer|results_json_tmpdir)'
}

# --- MAJOR 2 (retry 2): a failed update-ref CAS must NOT report merged ---------
# When the 3-arg compare-and-swap update-ref fails (a concurrent target advance
# moved the ref out from under us), integrate_one must NOT fall through to
# 'merged'. It must emit a distinct code, preserve the branch, stop, and the run
# must exit non-zero — never a false success.

@test "integrate: a failed update-ref CAS is reported update_failed (not merged), stops, exits non-zero" {
  _make_bugsweep_branch "bugsweep/cas" "cas.txt" "fix cas"
  _make_bugsweep_branch "bugsweep/cas-after" "cas-after.txt" "fix after"

  pre_target_sha="$(_current_sha main)"

  # Shim `git` so that `git update-ref` always fails, but every other git
  # subcommand passes through to the real binary. Placed first on PATH.
  SHIM_DIR="${BATS_TMP}/gitshim"
  mkdir -p "$SHIM_DIR"
  real_git="$(command -v git)"
  cat > "${SHIM_DIR}/git" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "update-ref" ]; then
  echo "shim: simulated CAS failure on update-ref" >&2
  exit 1
fi
exec "$real_git" "\$@"
SHIM
  chmod +x "${SHIM_DIR}/git"

  run env PATH="${SHIM_DIR}:${PATH}" BUGSWEEP_QUALITY_GATE_COMMAND="bash $GATE" CALL_LOG="$CALL_LOG" \
    bash "$INTEGRATE_SH" main bugsweep/cas bugsweep/cas-after

  # The run must fail loudly, not lie about success.
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/cas:update_failed"
  ! echo "$output" | grep -q "BRANCH_RESULT=bugsweep/cas:merged"
  echo "$output" | grep -q "BRANCH_RESULT=bugsweep/cas-after:skipped_after_stop"
  echo "$output" | grep -q "INTEGRATE_RESULT=stopped"
  echo "$output" | grep -q "STOPPED_AT=bugsweep/cas"
  echo "$output" | grep -q "MERGED_COUNT=0"
  _assert_counts_partition_inputs "$output" 2

  # The target ref did NOT advance (the CAS failed) and HEAD is back on the target.
  [ "$(_current_sha main)" = "$pre_target_sha" ]
  ! git -C "$REPO" merge-base --is-ancestor "bugsweep/cas" main
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "main" ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}

# --- Bash 3.2 / shellcheck hygiene ------------------------------------------

@test "integrate: script parses with Bash 3.2-compatible syntax" {
  run bash -n "$INTEGRATE_SH"
  [ "$status" -eq 0 ]
}

@test "integrate: script does not use mapfile or associative arrays" {
  ! grep -q "mapfile" "$INTEGRATE_SH"
  ! grep -q "declare -A" "$INTEGRATE_SH"
}
