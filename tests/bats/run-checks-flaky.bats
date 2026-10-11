#!/usr/bin/env bats
#
# run_checks.sh is now a proof gate. The previous shell-command/flaky-rerun
# implementation was retired when execution moved behind the coordinator and
# the required-untrusted provider. Keep explicit fail-closed coverage here:
# stale rerun knobs and untrusted plans must never execute a target command or
# manufacture an OK/FLAKY result.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
ROOT="$REPO_ROOT"
RUN_CHECKS_SH="${REPO_ROOT}/scripts/run_checks.sh"
PREPARE_PY="${REPO_ROOT}/scripts/_prepare_execution.py"
FAKE_PROVIDER="${REPO_ROOT}/tests/bats/fake_execution_provider.py"

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
    --target-root "$PROJECT" --run-id run-flaky \
    --deadline-epoch 9999999999 \
    --config-path "${BATS_TMP}/config.json" \
    --files-path "${BATS_TMP}/files.nul" > "${BATS_TMP}/preparation.json"
}

_write_untrusted_plan() {
  local marker="$1" digest
  digest="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "${PROJECT}/app.py")"
  cat > "${RUN_DIR}/check-plan.json" <<JSON
{"run_id":"run-flaky","target_root":"${PROJECT}","deadline_epoch":9999999999,"source_file_sha256":{"app.py":"${digest}"},"execution_policy":{"mode":"native"},"checks":[{"name":"test","command":["/bin/sh","-c","touch ${marker}"]}]}
JSON
}

_prepare_with_policy() {
  printf 'pass\n' > "${PROJECT}/app.py"
  printf '%s\n' '{"commands":{"test":{"command":["synthetic-suite"],"junit_path":"suite.xml"}}}' > "${BATS_TMP}/config.json"
  printf 'app.py\0' > "${BATS_TMP}/files.nul"
  printf '%s\n' '{"mode":"required-untrusted","backend":"docker"}' > "${BATS_TMP}/policy.json"
  python3 -B "$PREPARE_PY" init "$RUN_DIR" \
    --target-root "$PROJECT" --run-id run-flaky-structured \
    --deadline-epoch 9999999999 \
    --config-path "${BATS_TMP}/config.json" \
    --files-path "${BATS_TMP}/files.nul" \
    --policy-path "${BATS_TMP}/policy.json" > "${BATS_TMP}/preparation.json"
}

@test "an unavailable prepared run cannot produce a baseline" {
  _prepare_without_policy
  grep -q 'external_execution_policy_not_configured' "${BATS_TMP}/preparation.json"
  [ ! -e "${RUN_DIR}/check-plan.json" ]

  run bash "$RUN_CHECKS_SH" baseline "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "${RUN_DIR}/baseline.json" ]
}

@test "verify without a prepared plan fails closed even when flaky reruns are requested" {
  _prepare_without_policy
  run env BUGSWEEP_RERUN_INJECT_FAILURE=1 bash "$RUN_CHECKS_SH" verify "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "${RUN_DIR}/flaky.jsonl" ]
  [ ! -e "${PROJECT}/executed" ]
}

@test "a plan without the required-untrusted provider cannot execute its command" {
  printf 'pass\n' > "${PROJECT}/app.py"
  marker="${PROJECT}/executed"
  _write_untrusted_plan "$marker"

  run bash "$RUN_CHECKS_SH" baseline "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "$marker" ]
  [ ! -e "${RUN_DIR}/flaky.jsonl" ]
  grep -q '"proof_error": true' "${RUN_DIR}/baseline.json"
}

@test "structured baseline and verify pass through the synthetic provider" {
  _prepare_with_policy
  run env FAKE_CHECK_OUTCOME=pass python3 -B "$FAKE_PROVIDER" checks baseline "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "BASELINE_OVERALL=0" ]
  run env FAKE_CHECK_OUTCOME=pass python3 -B "$FAKE_PROVIDER" checks verify "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
  grep -q '"proof_error": false' "${RUN_DIR}/check-results-verify.json"
  grep -q '"provider": "synthetic-test-only"' "${RUN_DIR}/check-results-verify.json"
}

@test "structured verify reports a newly failing check as a regression" {
  _prepare_with_policy
  run env FAKE_CHECK_OUTCOME=pass python3 -B "$FAKE_PROVIDER" checks baseline "$RUN_DIR"
  [ "$status" -eq 0 ]
  run env FAKE_CHECK_OUTCOME=fail python3 -B "$FAKE_PROVIDER" checks verify "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "REGRESSION" ]
  grep -q 'synthetic::test_check' "${RUN_DIR}/check-results-verify.json"
  grep -q '"proof_error": false' "${RUN_DIR}/check-results-verify.json"
}

@test "structured verify rejects a source change against the frozen plan" {
  _prepare_with_policy
  run env FAKE_CHECK_OUTCOME=pass python3 -B "$FAKE_PROVIDER" checks baseline "$RUN_DIR"
  [ "$status" -eq 0 ]
  printf 'changed\n' > "${PROJECT}/app.py"
  run env FAKE_CHECK_OUTCOME=pass python3 -B "$FAKE_PROVIDER" checks verify "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  grep -q '"proof_error": true' "${RUN_DIR}/check-results-verify.json"
}

@test "malformed plan input stays a proof error rather than a flaky verdict" {
  printf 'not-json\n' > "${RUN_DIR}/check-plan.json"
  run bash "$RUN_CHECKS_SH" baseline "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "${RUN_DIR}/baseline.json" ]
  [ ! -e "${RUN_DIR}/flaky.jsonl" ]
}

@test "the retired rerun configuration cannot turn an unavailable run into OK" {
  _prepare_without_policy
  printf '{"verify":{"flaky_reruns":3}}\n' > "${BATS_TMP}/legacy-config.json"
  run env BUGSWEEP_CONFIG="${BATS_TMP}/legacy-config.json" bash "$RUN_CHECKS_SH" baseline "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [[ "$output" != *OK* ]]
  [[ "$output" != *FLAKY* ]]
}

@test "later passes do not excuse a newly observed regression" {
  grep -q 'does not excuse a regression after a later pass' "$ROOT/config/bugsweep.config.json"
  ! grep -q 'flaky_reruns' "$ROOT/scripts/_proof.py"
}
