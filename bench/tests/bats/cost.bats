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
  local dir="$1" tokens="$2" wall="$3" cost="$4" source="${5:-actual}"
  mkdir -p "$dir"
  cat >"$dir/usage.json" <<EOF
{ "tokens": ${tokens}, "wall_clock_seconds": ${wall}, "cost_usd": ${cost}, "cost_source": "${source}" }
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

@test "cost sum-file preserves missing fields as incomplete rather than zero" {
  mkdir -p "${ARM_DIR}/c1/run-1"
  printf '{ "tokens": 50 }\n' >"${ARM_DIR}/c1/run-1/usage.json"
  run "$COST_SH" sum-file "${ARM_DIR}/c1/run-1/usage.json"
  [ "$status" -eq 0 ]
  run jq -e '.tokens == 50 and .wall_clock_seconds == null and .cost_usd == null and .accounting_state == "incomplete"' \
    <<<"$output"
  [ "$status" -eq 0 ]
}

@test "cost sum-file fails closed on malformed JSON" {
  mkdir -p "${ARM_DIR}/c1/run-1"
  printf 'not json\n' >"${ARM_DIR}/c1/run-1/usage.json"
  run "$COST_SH" sum-file "${ARM_DIR}/c1/run-1/usage.json"
  [ "$status" -eq 1 ]
}

@test "cost sum-file rejects negative, fractional, nonfinite, and forged complete usage" {
  mkdir -p "${ARM_DIR}/c1/run-1"
  for record in '{"tokens": -1, "wall_clock_seconds": 1, "cost_usd": 1, "cost_source":"actual"}' '{"tokens": 1.5, "wall_clock_seconds": 1, "cost_usd": 1, "cost_source":"actual"}' '{"tokens": 1, "wall_clock_seconds": 1, "cost_usd": "NaN", "cost_source":"actual"}' '{"tokens": 1, "wall_clock_seconds": null, "cost_usd": 1, "cost_source":"actual", "accounting_state":"complete"}'; do
    printf '%s\n' "$record" >"${ARM_DIR}/c1/run-1/usage.json"
    run "$COST_SH" sum-file "${ARM_DIR}/c1/run-1/usage.json"
    [ "$status" -ne 0 ]
  done
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

@test "cost sum on an arm dir with no usage records yields unknown totals" {
  mkdir -p "$ARM_DIR"
  run "$COST_SH" sum "$ARM_DIR"
  [ "$status" -eq 0 ]
  run jq -e '.runs == 0 and .tokens == null and .cost_usd == null and .accounting_state == "unknown"' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "cost sum labels rate-estimated dollars and never relabels them actual" {
  _write_usage "${ARM_DIR}/c1/run-1" 100 1 0.01 rate_estimated
  run "$COST_SH" sum "$ARM_DIR"
  [ "$status" -eq 0 ]
  run jq -e '.cost_usd == 0.01 and .cost_source == "rate_estimated" and .accounting_state == "complete"' <<<"$output"
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
