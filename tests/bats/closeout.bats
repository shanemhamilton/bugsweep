#!/usr/bin/env bats

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CLOSEOUT_SH="${ROOT}/scripts/closeout.sh"
INTEGRATE_SH="${ROOT}/scripts/integrate.sh"
LANDED_FIXTURE="${ROOT}/tests/bats/landed_fixture.py"

load integration-fixture

setup() {
  START_CWD="$(pwd)"
  TMP="$(cd "$(mktemp -d)" && pwd -P)"
  REPO="${TMP}/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email test@bugsweep
  git -C "$REPO" config user.name bugsweep-test
  printf 'base\n' > "${REPO}/app.txt"
  printf 'unchanged regression fixture\n' > "${REPO}/regression_fixture.txt"
  git -C "$REPO" add app.txt regression_fixture.txt
  git -C "$REPO" commit -q -m init
  printf '.bugsweep/\n' >> "${REPO}/.git/info/exclude"
  ORIG="$(git -C "$REPO" symbolic-ref --short HEAD)"
  RUN_ID="test-run"
  BRANCH="bugsweep/${RUN_ID}"
  WT="${REPO}/.bugsweep/worktrees/${RUN_ID}"
  # Keep the authority beside this temporary checkout so the fixture exercises
  # the ordinary sibling topology while closeout still binds the run to
  # REPO_ROOT through state.env below.
  RUN_DIR="${TMP}/integration-authority"
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
  REAL_PYTHON="$(command -v python3)"
  PROVIDER_STUB_DIR="${TMP}/provider-stub"
  _write_integration_provider_stub "$PROVIDER_STUB_DIR" "$REAL_PYTHON"
  export REAL_PYTHON PROVIDER_STUB_DIR
  export PATH="${PROVIDER_STUB_DIR}:${PATH}"
  _write_summary
  printf '{"state":"PENDING_CLOSEOUT"}\n' > "${REPO}/.bugsweep/state/closeout-blocked/${RUN_ID}.json"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$TMP"
}

_set_fixed_summary() {
  _write_summary '["BUG-1"]'
}

_write_summary() {
  local fixed="${1:-[]}" confirmed="${2:-[]}" quarantined="${3:-[]}"
  local follow_up="${4:-[]}" degraded="${5:-false}" findings="${6:-[]}"
  local status="complete" stop_reason="null"
  if [ "$degraded" = true ]; then
    status="partial"
    stop_reason='"degraded reduction"'
  fi
  printf '{"schema_version":1,"mode":"detect-only","status":"%s","stop_reason":%s,"degraded":%s,"coverage":{"covered":0,"total":0},"counts":{"critical":0,"high":0,"medium":0,"low":0,"architectural":0},"fixed":%s,"confirmed_unfixed":%s,"quarantined":%s,"findings":%s,"follow_up":%s}\n' \
    "$status" "$stop_reason" "$degraded" "$fixed" "$confirmed" "$quarantined" "$findings" "$follow_up" \
    > "${RUN_DIR}/run-summary.json"
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
  _write_summary '[]' '["BUG-1"]'

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
  _write_summary '[]' '["BUG-1"]'
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
  _write_summary '[]' '["BUG-1"]'
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
  _write_summary '[]' '[]' '[]' '[]' true

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

@test "closeout: verified landed evidence removes the exact branch and worktree" {
  _set_fixed_summary
  cd "$REPO"

  # Reviews are prepared and captured against the untouched source snapshot;
  # the fixture's run_command boundary is synthetic, while review validation is
  # the production native-event and execution-receipt validator.
  run "$REAL_PYTHON" "$LANDED_FIXTURE" prepare-reviews "$RUN_DIR" "$WT" "$RUN_ID" BUG-1
  [ "$status" -eq 0 ]

  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): verified landed fixture'
  fix_commit="$(git -C "$REPO" rev-parse "$BRANCH")"
  for _ in 1 2 3; do
    printf '{"event":"referee_vote","bug_id":"BUG-1","severity":"medium","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  done
  printf '{"event":"referee_verdict","bug_id":"BUG-1","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"fix_committed","bug_id":"BUG-1","severity":"medium","commit":"%s"}\n' "$fix_commit" >> "${RUN_DIR}/ledger.jsonl"

  _write_integration_authority "$RUN_DIR" "$RUN_ID"
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" "$ORIG" "$BRANCH"
  [ "$status" -eq 0 ]

  run "$REAL_PYTHON" "$LANDED_FIXTURE" finalize-evidence "$RUN_DIR" "$REPO" "$WT" "$RUN_ID" "$BRANCH" BUG-1
  [ "$status" -eq 0 ]

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OUTCOME=COMPLETED_LANDED'
  [ ! -d "$WT" ]
  [ -z "$(git -C "$REPO" branch --list "$BRANCH")" ]
  [ ! -f "${REPO}/.bugsweep/state/closeout-blocked/${RUN_ID}.json" ]
  grep -q '"outcome":"COMPLETED_LANDED"' "${RUN_DIR}/ledger.jsonl"
}

@test "closeout: malformed landed evidence reaches the trusted verifier from a subdirectory" {
  _set_fixed_summary
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): malformed evidence boundary'
  for _ in 1 2 3; do
    printf '{"event":"referee_vote","bug_id":"BUG-1","severity":"medium","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  done
  printf '{"event":"referee_verdict","bug_id":"BUG-1","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"fix_committed","bug_id":"BUG-1","severity":"medium"}\n' >> "${RUN_DIR}/ledger.jsonl"

  cd "$REPO"
  _write_integration_authority "$RUN_DIR"
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" "$ORIG" "$BRANCH"
  [ "$status" -eq 0 ]

  # source-digests.json is intentionally absent.  The test reaches the
  # verifier from a nested checkout directory, then must fail closed before
  # any branch or worktree cleanup.
  mkdir -p "${REPO}/subdir"
  cd "${REPO}/subdir"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'requires verified execution and review provenance'
  ! echo "$output" | grep -q "No module named 'scripts'"
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
}

@test "closeout: landed rejects a run with no fixed findings" {
  cd "$REPO"
  _write_integration_authority "$RUN_DIR"
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" "$ORIG" "$BRANCH"
  [ "$status" -eq 0 ]

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
  _write_summary '["BUG-1"]'
  git -C "$REPO" merge -q --no-ff "$BRANCH" -m 'manual merge fixed work'

  cd "$REPO"
  _write_integration_authority "$RUN_DIR"
  run bash "$CLOSEOUT_SH" "$RUN_DIR" recorded

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 're-gate and use landed'
  [ -d "$WT" ]
  [ -n "$(git -C "$REPO" branch --list "$BRANCH")" ]
}

@test "closeout: landed still requires tracker receipts for unresolved bugs" {
  _write_summary '["BUG-FIX"]' '["BUG-1"]'
  cd "$REPO"
  _write_integration_authority "$RUN_DIR"
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" "$ORIG" "$BRANCH"
  [ "$status" -eq 0 ]

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
  _write_integration_authority "$RUN_DIR"
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" "$ORIG" "$BRANCH"
  [ "$status" -eq 0 ]

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
  _write_integration_authority "$RUN_DIR"
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" "$ORIG" "$BRANCH"
  [ "$status" -eq 0 ]

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
  for _ in 1 2 3; do
    printf '{"event":"referee_vote","bug_id":"BUG-1","severity":"medium","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  done
  printf '{"event":"referee_verdict","bug_id":"BUG-1","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"repro_status","bug_id":"BUG-1","status":"unreproduced"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"approval","bug_id":"BUG-1","approved":true}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"fix_committed","bug_id":"BUG-1","severity":"medium"}\n' >> "${RUN_DIR}/ledger.jsonl"
  cd "$REPO"
  _write_integration_authority "$RUN_DIR"
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" "$ORIG" "$BRANCH"
  [ "$status" -eq 0 ]

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'approval receipt follows reproduction: BUG-1'
  [ -d "$WT" ]
}

@test "closeout: high-severity Referee votes appended after mutation cannot authorize landing" {
  printf 'fix\n' >> "${WT}/app.txt"
  git -C "$WT" add app.txt
  git -C "$WT" commit -q -m 'fix(bugsweep): late votes'
  printf '{"event":"referee_verdict","bug_id":"BUG-1","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"fix_committed","bug_id":"BUG-1","severity":"high"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"referee_vote","bug_id":"BUG-1","severity":"high","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"referee_vote","bug_id":"BUG-1","severity":"high","verdict":"CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"referee_vote","bug_id":"BUG-1","severity":"high","verdict":"NOT_CONFIRMED"}\n' >> "${RUN_DIR}/ledger.jsonl"
  _write_summary '["BUG-1"]' '[]' '[]' '[]' false '[{"bug_id":"BUG-1","fixed":true,"severity":"high","category":"security","file":"a.py","line":1,"rationale":"r","vote_split":{"confirmed":2,"total":3,"eligible":true}}]'
  cd "$REPO"
  _write_integration_authority "$RUN_DIR"
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" "$ORIG" "$BRANCH"
  [ "$status" -eq 0 ]

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
  _write_integration_authority "$RUN_DIR"
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash "$INTEGRATE_SH" --run-dir "$RUN_DIR" "$ORIG" "$BRANCH"
  [ "$status" -eq 0 ]

  run bash "$CLOSEOUT_SH" "$RUN_DIR" landed

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'lacks a valid severity required for authorization'
  [ -d "$WT" ]
}
