#!/usr/bin/env bats
#
# The former isolated rerun suite covered the retired shell-command executor.
# Current checks require a coordinator-authored plan and a verified Docker
# provider. These cases make the migration boundary executable: an absent,
# malformed, or untrusted plan must fail closed and must not touch the target.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
RUN_CHECKS_SH="${REPO_ROOT}/scripts/run_checks.sh"
PREPARE_PY="${REPO_ROOT}/scripts/_prepare_execution.py"

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(cd "$(mktemp -d)" && pwd -P)"
  PROJECT="${BATS_TMP}/project"
  RUN_DIR="${BATS_TMP}/authority"
  mkdir -p "$PROJECT" "$RUN_DIR"
  cd "$PROJECT"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

_prepare_without_policy() {
  printf 'pass\n' > "${PROJECT}/app.py"
  printf '{}\n' > "${BATS_TMP}/config.json"
  printf 'app.py\0' > "${BATS_TMP}/files.nul"
  python3 -B "$PREPARE_PY" init "$RUN_DIR" \
    --target-root "$PROJECT" --run-id run-isolated \
    --deadline-epoch 9999999999 \
    --config-path "${BATS_TMP}/config.json" \
    --files-path "${BATS_TMP}/files.nul" > "${BATS_TMP}/preparation.json"
}

_write_untrusted_plan() {
  local marker="$1" digest
  digest="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "${PROJECT}/app.py")"
  cat > "${RUN_DIR}/check-plan.json" <<JSON
{"run_id":"run-isolated","target_root":"${PROJECT}","deadline_epoch":9999999999,"source_file_sha256":{"app.py":"${digest}"},"execution_policy":{"mode":"native"},"checks":[{"name":"test","command":["/bin/sh","-c","touch ${marker}"]}]}
JSON
}

@test "verify without preparation is a proof error and leaves the target untouched" {
  _prepare_without_policy
  run bash "$RUN_CHECKS_SH" verify "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "${PROJECT}/executed" ]
  [ ! -e "${RUN_DIR}/check-results-verify.json" ]
}

@test "an unavailable preparation does not silently fall back to native execution" {
  _prepare_without_policy
  run bash "$RUN_CHECKS_SH" baseline "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "${RUN_DIR}/baseline.json" ]
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["verified"] is False' \
    "${RUN_DIR}/execution-availability.json"
}

@test "a native-looking plan cannot bypass the provider or pollute the target" {
  printf 'pass\n' > "${PROJECT}/app.py"
  marker="${PROJECT}/polluted"
  _write_untrusted_plan "$marker"
  run env BUGSWEEP_RERUN_INJECT_FAILURE=1 bash "$RUN_CHECKS_SH" baseline "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "$marker" ]
  grep -q '"proof_error": true' "${RUN_DIR}/baseline.json"
}

@test "a malformed check plan cannot trigger isolated reruns" {
  printf '{"checks":[{"name":"test","command":["touch","%s"]}]}\n' "${PROJECT}/polluted" > "${RUN_DIR}/check-plan.json"
  run bash "$RUN_CHECKS_SH" verify "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "${PROJECT}/polluted" ]
  [ ! -e "${RUN_DIR}/flaky.jsonl" ]
}

@test "legacy isolation environment variables do not create a verdict" {
  _prepare_without_policy
  run env BUGSWEEP_RERUN_INJECT_FAILURE=1 BUGSWEEP_WORKTREE="$PROJECT" bash "$RUN_CHECKS_SH" verify "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [[ "$output" != *OK* ]]
  [[ "$output" != *FLAKY* ]]
}

@test "a legacy worktree state file cannot activate a host-side rerun" {
  cat > "${RUN_DIR}/state.env" <<EOF
BUGSWEEP_WORKTREE=${RUN_DIR}
EOF
  run bash "$RUN_CHECKS_SH" verify "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
}

@test "the wrapper has no shell reset or cleanup implementation" {
  [ "$(wc -l < "$RUN_CHECKS_SH" | tr -d ' ')" -le 10 ]
  grep -q 'exec python3 -B .*_proof.py" checks' "$RUN_CHECKS_SH"
}
