#!/usr/bin/env bats

# v0.7 delegates executable proof to the coordinator/provider. Receipt
# validation, red-to-green semantics, and source identity live in
# bench/tests/unit/test_fix_proof.py; these are the shell entrypoint guards.

REPRO_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/repro.sh"
ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() { RUN_DIR="$(mktemp -d)"; }
teardown() { rm -rf "$RUN_DIR"; }

@test "repro rejects a legacy raw command instead of executing it on the host" {
  marker="${RUN_DIR}/host-command-ran"
  run bash "$REPRO_SH" pre "$RUN_DIR" BUG-1 "touch '${marker}'"
  [ "$status" -eq 1 ]
  [ "$output" = "REPRO=proof_error" ]
  [ ! -e "$marker" ]
}

@test "repro requires a coordinator-created request for every phase" {
  run bash "$REPRO_SH" post "$RUN_DIR" BUG-1
  [ "$status" -eq 1 ]
  [ "$output" = "REPRO=proof_error" ]
}

@test "repro documentation requires a frozen request and verified provider" {
  grep -q 'never pass a raw command' "$ROOT/prompts/repro.md"
  grep -q 'required-untrusted provider' "$ROOT/prompts/repro.md"
  grep -q 'Do not use host evaluation, a shell fallback' "$ROOT/prompts/repro.md"
}
