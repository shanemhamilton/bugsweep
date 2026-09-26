#!/usr/bin/env bats

# The retired shell rerun/reset implementation is intentionally not part of
# structured proof. Provider isolation and frozen source identity are tested
# in the Python execution/proof suites; these checks prevent fallback to the
# old state.env-driven host behavior.

RUN_CHECKS_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/run_checks.sh"

setup() { RUN_DIR="$(mktemp -d)"; }
teardown() { rm -rf "$RUN_DIR"; }

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
