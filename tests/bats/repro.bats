#!/usr/bin/env bats
#
# The executable repro contract is coordinator-driven. A request is a JSON
# artifact produced by _prepare_execution.py and is executed only by the
# trusted provider. The former `repro.sh ... "<shell command>"` interface was
# retired; these tests keep that boundary explicit so a stale caller cannot
# regain arbitrary shell execution.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
REPRO_SH="${REPO_ROOT}/scripts/repro.sh"
PREPARE_PY="${REPO_ROOT}/scripts/_prepare_execution.py"
RUN_CHECKS_SH="${REPO_ROOT}/scripts/run_checks.sh"
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
  printf 'answer = 0\n' > "${PROJECT}/app.py"
  printf '{}\n' > "${BATS_TMP}/config.json"
  printf 'app.py\0' > "${BATS_TMP}/files.nul"
  python3 -B "$PREPARE_PY" init "$RUN_DIR" \
    --target-root "$PROJECT" --run-id run-repro \
    --deadline-epoch 9999999999 \
    --config-path "${BATS_TMP}/config.json" \
    --files-path "${BATS_TMP}/files.nul" > "${BATS_TMP}/preparation.json"
}

_prepare_with_policy() {
  printf 'answer = 0\n' > "${PROJECT}/app.py"
  printf 'def test_answer():\n    assert answer == 1\n' > "${PROJECT}/test_bug.py"
  printf '%s\n' '{"commands":{"test":{"command":["synthetic-suite"],"junit_path":"suite.xml"}}}' > "${BATS_TMP}/config.json"
  printf 'app.py\0test_bug.py\0' > "${BATS_TMP}/files.nul"
  printf '%s\n' '{"mode":"required-untrusted","backend":"docker"}' > "${BATS_TMP}/policy.json"
  python3 -B "$PREPARE_PY" init "$RUN_DIR" \
    --target-root "$PROJECT" --run-id run-structured \
    --deadline-epoch 9999999999 \
    --config-path "${BATS_TMP}/config.json" \
    --files-path "${BATS_TMP}/files.nul" \
    --policy-path "${BATS_TMP}/policy.json" > "${BATS_TMP}/preparation.json"
  local app_sha
  app_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "${PROJECT}/app.py")"
  cat > "${BATS_TMP}/repro-spec.json" <<JSON
{"command":["synthetic-repro"],"test":{"path":"test_bug.py","native_id":"test_bug::test_answer","expected_failure_type":"assertion","expected_failure_message":"assert 0 == 1"},"intended_source_files":["app.py"],"junit_path":"repro.xml","review_source_file_sha256":{"app.py":"${app_sha}"}}
JSON
}

_prepare_repro_request() {
  python3 -B "$PREPARE_PY" repro-pre "$RUN_DIR" "$1" "${BATS_TMP}/repro-spec.json" > "${BATS_TMP}/pre-request-result.json"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "${BATS_TMP}/pre-request-result.json"
}

_prepare_post_request() {
  python3 -B "$PREPARE_PY" repro-post "$RUN_DIR" "$1" > "${BATS_TMP}/post-request-result.json"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "${BATS_TMP}/post-request-result.json"
}

_assert_proof_error() {
  [ "$status" -eq 1 ]
  [ "$output" = "REPRO=proof_error" ]
}

@test "retired none classification is proof_error without a ledger event" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-1" ""
  _assert_proof_error
  grep -q '"missing_request"' "${RUN_DIR}/proofs/BUG-1.json"
  [ ! -e "${RUN_DIR}/ledger.jsonl" ]
}

@test "legacy omitted pre command is rejected" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-2"
  _assert_proof_error
  grep -q '"legacy_raw_command"' "${RUN_DIR}/proofs/BUG-2.json"
}

@test "retired green and red classifications are proof_error without execution" {
  marker="${BATS_TMP}/executed"
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-3" "touch '${marker}'"
  _assert_proof_error
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-4" "false"
  _assert_proof_error
  [ ! -e "$marker" ]
  grep -q '"missing_request"' "${RUN_DIR}/proofs/BUG-3.json"
  grep -q '"missing_request"' "${RUN_DIR}/proofs/BUG-4.json"
}

@test "post without a coordinator request fails closed" {
  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-5"
  _assert_proof_error
  grep -q '"missing_request"' "${RUN_DIR}/proofs/BUG-5.json"
  [ ! -e "${RUN_DIR}/ledger.jsonl" ]
}

@test "post cannot turn a legacy pre call into a shell execution" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-6" "false"
  _assert_proof_error
  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-6"
  _assert_proof_error
  # Final proof files are immutable: post reports the error but does not
  # replace the original legacy-call diagnostic.
  grep -q '"missing_request"' "${RUN_DIR}/proofs/BUG-6.json"
}

@test "prepared runs without an external required-untrusted policy stay unavailable" {
  _prepare_without_policy
  grep -q 'external_execution_policy_not_configured' "${BATS_TMP}/preparation.json"
  [ ! -e "${RUN_DIR}/check-plan.json" ]

  run bash "$RUN_CHECKS_SH" baseline "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "${RUN_DIR}/baseline.json" ]
}

@test "structured prepared repro runs red-to-green through the synthetic provider" {
  _prepare_with_policy
  run python3 -B "$FAKE_PROVIDER" checks baseline "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "BASELINE_OVERALL=0" ]

  request="$(_prepare_repro_request BUG-STRUCTURED-1)"
  run env FAKE_REPRO_OUTCOME=failure python3 -B "$FAKE_PROVIDER" repro pre "$RUN_DIR" "BUG-STRUCTURED-1" "$request"
  [ "$status" -eq 0 ]
  [ "$output" = "REPRO=red_confirmed" ]

  printf 'answer = 1\n' > "${PROJECT}/app.py"
  python3 -B "$PREPARE_PY" checks "$RUN_DIR" > "${BATS_TMP}/refreshed.json"
  run env FAKE_CHECK_OUTCOME=pass python3 -B "$FAKE_PROVIDER" checks verify "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]

  post_request="$(_prepare_post_request BUG-STRUCTURED-1)"
  run env FAKE_REPRO_OUTCOME=pass python3 -B "$FAKE_PROVIDER" repro post "$RUN_DIR" "BUG-STRUCTURED-1" "$post_request"
  [ "$status" -eq 0 ]
  [ "$output" = "REPRO=confirmed" ]
  grep -q '"status": "verified"' "${RUN_DIR}/proofs/BUG-STRUCTURED-1.json"
}

@test "structured repro rejects a non-assertion before failure" {
  _prepare_with_policy
  request="$(_prepare_repro_request BUG-STRUCTURED-2)"
  run env FAKE_REPRO_OUTCOME=failure FAKE_REPRO_FAILURE_KIND=import python3 -B "$FAKE_PROVIDER" repro pre "$RUN_DIR" "BUG-STRUCTURED-2" "$request"
  [ "$status" -eq 1 ]
  [ "$output" = "REPRO=proof_error" ]
  grep -q '"before_not_expected_assertion"' "${RUN_DIR}/proofs/BUG-STRUCTURED-2.json"
}

@test "structured repro still-red post is proof_error and immutable retries do not replace proof" {
  _prepare_with_policy
  run python3 -B "$FAKE_PROVIDER" checks baseline "$RUN_DIR"
  [ "$status" -eq 0 ]
  request="$(_prepare_repro_request BUG-STRUCTURED-3)"
  run env FAKE_REPRO_OUTCOME=failure python3 -B "$FAKE_PROVIDER" repro pre "$RUN_DIR" "BUG-STRUCTURED-3" "$request"
  [ "$status" -eq 0 ]

  printf 'answer = 1\n' > "${PROJECT}/app.py"
  python3 -B "$PREPARE_PY" checks "$RUN_DIR" > "${BATS_TMP}/refreshed.json"
  run env FAKE_CHECK_OUTCOME=pass python3 -B "$FAKE_PROVIDER" checks verify "$RUN_DIR"
  [ "$status" -eq 0 ]
  post_request="$(_prepare_post_request BUG-STRUCTURED-3)"

  run env FAKE_REPRO_OUTCOME=still-red python3 -B "$FAKE_PROVIDER" repro post "$RUN_DIR" "BUG-STRUCTURED-3" "$post_request"
  [ "$status" -eq 1 ]
  [ "$output" = "REPRO=proof_error" ]
  proof_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "${RUN_DIR}/proofs/BUG-STRUCTURED-3.json")"
  run env FAKE_REPRO_OUTCOME=pass python3 -B "$FAKE_PROVIDER" repro post "$RUN_DIR" "BUG-STRUCTURED-3" "$post_request"
  [ "$status" -eq 1 ]
  [ "$output" = "REPRO=proof_error" ]
  [ "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "${RUN_DIR}/proofs/BUG-STRUCTURED-3.json")" = "$proof_sha" ]
}

@test "BUGSWEEP_NO_PYTHON cannot re-enable the retired degraded shell path" {
  BUGSWEEP_NO_PYTHON=1 run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-7" "true"
  _assert_proof_error
  grep -q '"missing_request"' "${RUN_DIR}/proofs/BUG-7.json"
}

@test "invalid bug identifiers are rejected before request processing" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "../etc/passwd" "false"
  [ "$status" -eq 1 ]
  [ "$output" = "REPRO=proof_error" ]
  grep -q '"invalid_bug_id"' "${RUN_DIR}/proofs/.._etc_passwd.json"
}

@test "missing run directories fail closed" {
  missing="${BATS_TMP}/missing"
  run bash "$REPRO_SH" pre "$missing" "BUG-8" "false"
  _assert_proof_error
  [ -f "${missing}/proofs/BUG-8.json" ]
}

@test "unknown subcommands and missing arguments remain usage errors" {
  run bash "$REPRO_SH"
  [ "$status" -ne 0 ]
  run bash "$REPRO_SH" unknown "$RUN_DIR" "BUG-9"
  [ "$status" -ne 0 ]
}
