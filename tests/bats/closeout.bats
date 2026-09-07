#!/usr/bin/env bats
# shellcheck disable=SC2164,SC2129

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CLOSEOUT_SH="${ROOT}/scripts/closeout.sh"

setup() {
  START_CWD="$(pwd)"
  TMP="$(mktemp -d)"
  REPO="${TMP}/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email test@bugsweep
  git -C "$REPO" config user.name bugsweep-test
  printf 'base\n' > "${REPO}/app.txt"
  git -C "$REPO" add app.txt
  git -C "$REPO" commit -q -m init
  printf '.bugsweep/\n' >> "${REPO}/.git/info/exclude"
  ORIG="$(git -C "$REPO" symbolic-ref --short HEAD)"
  RUN_ID="test-run"
  BRANCH="bugsweep/${RUN_ID}"
  WT="${REPO}/.bugsweep/worktrees/${RUN_ID}"
  RUN_DIR="${REPO}/.bugsweep/run-${RUN_ID}"
  mkdir -p "$(dirname "$WT")" "$RUN_DIR" "${REPO}/.bugsweep/state/closeout-blocked"
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" HEAD
  cat > "${RUN_DIR}/state.env" <<ENV
BUGSWEEP_TS='${RUN_ID}'
BUGSWEEP_RUN_ID='${RUN_ID}'
BUGSWEEP_RUN_DIR='${RUN_DIR}'
BUGSWEEP_REPO_ROOT='${REPO}'
BUGSWEEP_BRANCH='${BRANCH}'
BUGSWEEP_ORIG_BRANCH='${ORIG}'
BUGSWEEP_ORIG_HEAD='$(git -C "$REPO" rev-parse HEAD)'
BUGSWEEP_STASH_REF='none'
BUGSWEEP_WORKTREE='${WT}'
ENV
  : > "${RUN_DIR}/ledger.jsonl"
  _write_summary '[]' '[]' '[]'
  printf '{"state":"PENDING_CLOSEOUT"}\n' > "${REPO}/.bugsweep/state/closeout-blocked/${RUN_ID}.json"
}

teardown() {
  cd "$START_CWD" || return
  rm -rf "$TMP"
}

_write_summary() {
  local fixed="$1" quarantined="$2" confirmed_unfixed="$3" degraded="${4:-false}"
  printf '{"schema_version":1,"mode":"detect","status":"complete","stop_reason":null,"coverage":{"covered":0,"total":0},"counts":{"critical":0,"high":0,"medium":0,"low":0,"architectural":0},"fixed":%s,"quarantined":%s,"confirmed_unfixed":%s,"findings":[],"degraded":%s,"follow_up":[]}\n' \
    "$fixed" "$quarantined" "$confirmed_unfixed" "$degraded" > "${RUN_DIR}/run-summary.json"
}

_set_fixed_summary() {
  _write_summary '["BUG-1"]' '[]' '[]'
}

_seed_synthetic_integration_receipt() {
  # Test fixture only: bind real fixture refs so downstream rejection guards
  # run before the separate full provider-proof validation.
  git -C "$REPO" merge -q --no-ff "$BRANCH" -m 'fixture merge'
  local source target
  source="$(git -C "$REPO" rev-parse "$BRANCH")"
  target="$(git -C "$REPO" rev-parse "$ORIG")"
  printf '{"target_branch":"%s","quality_gate_command":"provider:frozen-check-plan","result":"complete","branches":[{"branch":"%s","status":"merged","quality_gate_passed":true,"source_tip":"%s","target_tip":"%s"}]}' \
    "$ORIG" "$BRANCH" "$source" "$target" > "${RUN_DIR}/integrate-results.json"
}

@test "closeout: clean recorded run removes only its exact branch and worktree" {
  cd "$REPO"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" recorded

  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OUTCOME=COMPLETED_RECORDED'
  [ ! -d "$WT" ]
  [ -z "$(git -C "$REPO" branch --list "$BRANCH")" ]
  [ ! -f "${REPO}/.bugsweep/state/closeout-blocked/${RUN_ID}.json" ]

  run bash "$CLOSEOUT_SH" "$RUN_DIR" recorded
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OUTCOME=COMPLETED_RECORDED'
}

@test "closeout: unlanded action without tracker receipt stays blocked and recoverable" {
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): test'
  _write_summary '[]' '[]' '["BUG-1"]'

  cd "$REPO"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" recorded

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'verified tracker readback missing keys'
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
  grep -q 'INCOMPLETE_TRACKER' "${REPO}/.bugsweep/state/closeout-blocked/${RUN_ID}.json"
}

@test "closeout: tracker, bundle, and matching review authorize exact recorded discard" {
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): test'
  _write_summary '[]' '[]' '["BUG-1"]'
  git -C "$REPO" bundle create "${RUN_DIR}/recovery.bundle" "refs/heads/${BRANCH}"
  tip="$(git -C "$REPO" rev-parse "$BRANCH")"
  sha="$(shasum -a 256 "${RUN_DIR}/recovery.bundle" | awk '{print $1}')"
  printf '{"provider":"beads","item_id":"BUG-1","finding_key":"BUG-1","readback_verified":true,"recovery_bundle":"%s","recovery_sha256":"%s"}\n' \
    "${RUN_DIR}/recovery.bundle" "$sha" > "${RUN_DIR}/tracker-receipts.jsonl"
  printf '{"approved":true,"branch":"%s","tip":"%s","bundle_sha256":"%s"}\n' \
    "$BRANCH" "$tip" "$sha" > "${RUN_DIR}/deletion-review.json"

  cd "$REPO"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" recorded

  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OUTCOME=COMPLETED_RECORDED'
  [ ! -d "$WT" ]
  [ -z "$(git -C "$REPO" branch --list "$BRANCH")" ]
  git -C "$REPO" bundle verify "${RUN_DIR}/recovery.bundle"
}

@test "closeout: valid bundle for the wrong ref cannot authorize branch deletion" {
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): test'
  _write_summary '[]' '[]' '["BUG-1"]'
  git -C "$REPO" bundle create "${RUN_DIR}/recovery.bundle" "refs/heads/${ORIG}"
  tip="$(git -C "$REPO" rev-parse "$BRANCH")"
  sha="$(shasum -a 256 "${RUN_DIR}/recovery.bundle" | awk '{print $1}')"
  printf '{"provider":"beads","item_id":"BUG-1","finding_key":"BUG-1","readback_verified":true,"recovery_bundle":"%s","recovery_sha256":"%s"}\n' \
    "${RUN_DIR}/recovery.bundle" "$sha" > "${RUN_DIR}/tracker-receipts.jsonl"
  printf '{"approved":true,"branch":"%s","tip":"%s","bundle_sha256":"%s"}\n' \
    "$BRANCH" "$tip" "$sha" > "${RUN_DIR}/deletion-review.json"

  cd "$REPO"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" recorded

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'recovery bundle does not contain the exact branch tip'
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
}

@test "closeout: degraded summary cannot silently erase tracker obligations" {
  _write_summary '[]' '[]' '[]' true

  cd "$REPO"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" recorded

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'degraded run summary cannot prove tracker completeness'
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
}

@test "closeout: state cannot remove a worktree registered to another branch" {
  OTHER="${REPO}/.bugsweep/worktrees/other"
  git -C "$REPO" worktree add -q -b bugsweep/other "$OTHER" HEAD
  sed -i.bak "s|BUGSWEEP_WORKTREE='${WT}'|BUGSWEEP_WORKTREE='${OTHER}'|" "${RUN_DIR}/state.env"

  cd "$REPO"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" recorded

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'not registered to the exact run branch'
  [ -d "$OTHER" ]
  [ -n "$(git -C "$REPO" branch --list 'bugsweep/other')" ]
}

@test "closeout: landed requires the integration quality-gate receipt" {
  _set_fixed_summary
  cd "$REPO"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'successful integration quality-gate receipt'
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
}

@test "closeout: landed rejects a run with no fixed findings" {
  cd "$REPO"
  _seed_synthetic_integration_receipt

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'requires at least one fixed finding'
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
}

@test "closeout: recorded cannot misclassify already-contained fixed work" {
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): contained fix'
  _set_fixed_summary
  git -C "$REPO" merge -q --no-ff "$BRANCH" -m 'manual merge fixed work'

  cd "$REPO"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" recorded

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 're-gate and use landed'
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
}

@test "closeout: landed still requires tracker receipts for unresolved bugs" {
  _write_summary '["BUG-FIX"]' '[]' '["BUG-1"]'
  cd "$REPO"
  _seed_synthetic_integration_receipt

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'verified tracker readback missing keys: BUG-1'
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
}

@test "closeout: stale integration receipt cannot authorize a newer branch tip" {
  _set_fixed_summary
  printf 'first fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): first tip'
  cd "$REPO"
  _seed_synthetic_integration_receipt

  printf 'second fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): newer tip'
  git -C "$REPO" merge -q --no-ff "$BRANCH" -m 'manual merge newer tip'

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'does not match the exact current branch tip'
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
}

@test "closeout: Referee verdict appended after a fix cannot authorize landing" {
  _set_fixed_summary
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): ordered evidence'
  printf '{"event":"fix_committed","bug_id":"BUG-1","severity":"medium"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"referee_verdict","bug_id":"BUG-1","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  cd "$REPO"
  _seed_synthetic_integration_receipt

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'lacks a preceding Referee verdict: BUG-1'
  [ -d "$WT" ]
}

@test "closeout: approved-mode approval must precede reproduction and fix" {
  _set_fixed_summary
  printf "BUGSWEEP_MODE='approve'\n" >> "${RUN_DIR}/state.env"
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): approval order'
  printf '{"event":"referee_verdict","bug_id":"BUG-1","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"repro_status","bug_id":"BUG-1","status":"unreproduced"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"approval","bug_id":"BUG-1","approved":true}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"fix_committed","bug_id":"BUG-1","severity":"medium"}\n' >> "${RUN_DIR}/ledger.jsonl"
  cd "$REPO"
  _seed_synthetic_integration_receipt

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'approval receipt follows reproduction: BUG-1'
  [ -d "$WT" ]
}

@test "closeout: high-severity Referee votes appended after mutation cannot authorize landing" {
  _set_fixed_summary
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): late votes'
  printf '{"event":"referee_verdict","bug_id":"BUG-1","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"fix_committed","bug_id":"BUG-1","severity":"high"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"referee_vote","bug_id":"BUG-1","severity":"high","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"referee_vote","bug_id":"BUG-1","severity":"high","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"referee_vote","bug_id":"BUG-1","severity":"high","verdict":"NOT_CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  cd "$REPO"
  _seed_synthetic_integration_receipt

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'lacks 3 Referee votes before its verdict: BUG-1'
  [ -d "$WT" ]
}

@test "closeout: missing severity cannot bypass high-severity authorization" {
  _set_fixed_summary
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): missing severity'
  printf '{"event":"referee_verdict","bug_id":"BUG-1","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"fix_committed","bug_id":"BUG-1"}\n' >> "${RUN_DIR}/ledger.jsonl"
  cd "$REPO"
  _seed_synthetic_integration_receipt

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'lacks a valid severity required for authorization'
  [ -d "$WT" ]
}
