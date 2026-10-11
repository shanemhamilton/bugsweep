#!/usr/bin/env bats
#
# Tier-A tests for the pinned image entrypoint contract.  The entrypoint is a
# deliberately small compatibility wrapper: Docker supplies the trusted
# adapter at /usr/local/bin/bench-host-adapter, so setup and checkout copying
# belong to the executor rather than this script.

load helpers

@test "docker entrypoint is valid bash and enables strict mode" {
  run bash -n "$ENTRYPOINT_SH"
  [ "$status" -eq 0 ]

  run grep -F 'set -euo pipefail' "$ENTRYPOINT_SH"
  [ "$status" -eq 0 ]
}

@test "docker entrypoint execs the pinned host adapter with all arguments" {
  run grep -F 'exec /usr/local/bin/bench-host-adapter "$@"' "$ENTRYPOINT_SH"
  [ "$status" -eq 0 ]

  # The retired wrapper used host-controlled setup overrides.  Keeping those
  # out of the image entrypoint prevents a mounted checkout or skill from
  # becoming an implicit execution input.
  run grep -E 'BENCH_ENTRY_(HOME|SKILL_SRC|WORK|REPO)' "$ENTRYPOINT_SH"
  [ "$status" -ne 0 ]
}

@test "docker entrypoint leaves arm selection to the host adapter" {
  run grep -E 'current_skill|previous_release|no_skill_baseline' "$ENTRYPOINT_SH"
  [ "$status" -ne 0 ]
}
