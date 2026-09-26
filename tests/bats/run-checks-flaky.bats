#!/usr/bin/env bats

# v0.7 records immutable provider results once. Native-result comparison and
# missing/skipped regression behavior are covered by
# bench/tests/unit/test_check_results.py; this suite covers the shell boundary.

RUN_CHECKS_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/run_checks.sh"
ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() { RUN_DIR="$(mktemp -d)"; }
teardown() { rm -rf "$RUN_DIR"; }

@test "checks fail closed without the frozen coordinator check plan" {
  run bash "$RUN_CHECKS_SH" baseline "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
}

@test "checks do not execute a legacy config command when no plan exists" {
  marker="${RUN_DIR}/host-command-ran"
  mkdir -p "${RUN_DIR}/config"
  printf '{"commands":{"test":"touch %s"}}\n' "$marker" > "${RUN_DIR}/config/bugsweep.config.json"
  run bash "$RUN_CHECKS_SH" verify "$RUN_DIR"
  [ "$status" -eq 1 ]
  [ "$output" = "PROOF_ERROR" ]
  [ ! -e "$marker" ]
}

@test "later passes do not excuse a newly observed regression" {
  grep -q 'does not excuse a regression after a later pass' "$ROOT/config/bugsweep.config.json"
  ! grep -q 'flaky_reruns' "$ROOT/scripts/_proof.py"
}
