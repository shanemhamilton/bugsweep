#!/usr/bin/env bats
#
# Tier-A (container-free) tests for the analysis-image compatibility wrapper.
# It preserves the pinned host-adapter entrypoint contract without launching a
# container or provider client.

load helpers

# ---------------------------------------------------------------------------
# docker-entrypoint.sh : compatibility delegation
# ---------------------------------------------------------------------------

@test "entrypoint remains valid bash" {
  run bash -n "$ENTRYPOINT_SH"
  [ "$status" -eq 0 ]
}

@test "entrypoint enables strict shell error handling" {
  run grep -F 'set -euo pipefail' "$ENTRYPOINT_SH"
  [ "$status" -eq 0 ]
}

@test "entrypoint delegates to the pinned host adapter" {
  run grep -F 'exec /usr/local/bin/bench-host-adapter' "$ENTRYPOINT_SH"
  [ "$status" -eq 0 ]
}

@test "entrypoint forwards every argument unchanged" {
  run grep -F '"$@"' "$ENTRYPOINT_SH"
  [ "$status" -eq 0 ]
}

@test "entrypoint does not retain legacy clone staging" {
  run grep -F 'BENCH_ENTRY_' "$ENTRYPOINT_SH"
  [ "$status" -eq 1 ]
}

@test "entrypoint leaves arm selection to the host adapter" {
  run grep -F 'current_skill\|previous_release\|no_skill_baseline' "$ENTRYPOINT_SH"
  [ "$status" -eq 1 ]
}
