#!/usr/bin/env bats
#
# Tier-A tests for cost.sh — accumulate per-arm token / wall-clock / dollar cost
# from the runner-written usage.json records. No network, no real claude: the
# test writes canned usage.json fixtures and asserts the aggregation.

load helpers

COST_SH="${BENCH_LIB_DIR}/cost.sh"

setup() {
  BATS_TMP="$(mktemp -d)"
  export BATS_TMP
  ARM_DIR="${BATS_TMP}/bugsweep"
  export ARM_DIR
}

teardown() {
  [[ -n "${BATS_TMP:-}" && -d "$BATS_TMP" ]] && rm -rf "$BATS_TMP"
}

# Write a usage.json with the three accounted fields under a per-case/run dir.
_write_usage() {
  local dir="$1" tokens="$2" wall="$3" cost="$4"
  mkdir -p "$dir"
  cat >"$dir/usage.json" <<EOF
{ "tokens": ${tokens}, "wall_clock_seconds": ${wall}, "cost_usd": ${cost} }
EOF
}

# ---------------------------------------------------------------------------
# sum-file: normalize a single record
# ---------------------------------------------------------------------------

@test "cost sum-file echoes the three accounted fields" {
  _write_usage "${ARM_DIR}/c1/run-1" 1200 42 0.018
  run "$COST_SH" sum-file "${ARM_DIR}/c1/run-1/usage.json"
  [ "$status" -eq 0 ]
  run jq -e '.tokens == 1200 and .wall_clock_seconds == 42 and .cost_usd == 0.018' \
    <<<"$output"
  [ "$status" -eq 0 ]
}

@test "cost sum-file defaults missing fields to zero" {
  mkdir -p "${ARM_DIR}/c1/run-1"
  printf '{ "tokens": 50 }\n' >"${ARM_DIR}/c1/run-1/usage.json"
  run "$COST_SH" sum-file "${ARM_DIR}/c1/run-1/usage.json"
  [ "$status" -eq 0 ]
  run jq -e '.tokens == 50 and .wall_clock_seconds == 0 and .cost_usd == 0' \
    <<<"$output"
  [ "$status" -eq 0 ]
}

@test "cost sum-file fails closed on malformed JSON" {
  mkdir -p "${ARM_DIR}/c1/run-1"
  printf 'not json\n' >"${ARM_DIR}/c1/run-1/usage.json"
  run "$COST_SH" sum-file "${ARM_DIR}/c1/run-1/usage.json"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# sum: aggregate every usage.json under an arm dir
# ---------------------------------------------------------------------------

@test "cost sum aggregates tokens, wall-clock, and dollars across runs" {
  _write_usage "${ARM_DIR}/c1/run-1" 1000 30 0.01
  _write_usage "${ARM_DIR}/c1/run-2" 2000 60 0.02
  _write_usage "${ARM_DIR}/c2/run-1" 500 15 0.005
  run "$COST_SH" sum "$ARM_DIR"
  [ "$status" -eq 0 ]
  assert_contains "$output" '"arm": "bugsweep"'
  # Capture the JSON once; each `run jq` would otherwise clobber $output.
  local totals="$output"
  run jq -e '.runs == 3 and .tokens == 3500 and .wall_clock_seconds == 105' \
    <<<"$totals"
  [ "$status" -eq 0 ]
  # cost_usd sums float cents; assert within tolerance, not exact equality.
  run jq -e '(.cost_usd - 0.035 | if . < 0 then -. else . end) < 0.0001' \
    <<<"$totals"
  [ "$status" -eq 0 ]
}

@test "cost sum on an arm dir with no usage records yields zeroed totals" {
  mkdir -p "$ARM_DIR"
  run "$COST_SH" sum "$ARM_DIR"
  [ "$status" -eq 0 ]
  run jq -e '.runs == 0 and .tokens == 0 and .cost_usd == 0' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "cost sum fails closed if any usage.json under the arm dir is malformed" {
  _write_usage "${ARM_DIR}/c1/run-1" 1000 30 0.01
  mkdir -p "${ARM_DIR}/c2/run-1"
  printf 'broken\n' >"${ARM_DIR}/c2/run-1/usage.json"
  run "$COST_SH" sum "$ARM_DIR"
  [ "$status" -eq 1 ]
}

@test "cost usage error with no args" {
  run "$COST_SH"
  [ "$status" -ne 0 ]
}
