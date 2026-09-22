#!/usr/bin/env bash
#
# cost.sh — accumulate per-arm token / wall-clock / dollar cost for a run.
#
# Input contract (defined HERE, consumed by run.sh): the runner writes a
# per-(case, run, arm) usage record to
#     results/<run-id>/<arm>/<case-id>/run-<n>/usage.json
# of the shape:
#     { "tokens": <int|null>, "wall_clock_seconds": <number|null>,
#       "cost_usd": <number|null>, "cost_source": "actual"|"rate_estimated"|"unknown" }
# Missing accounting remains null/unknown. It is never converted to zero: zero
# is a measured value, while missing usage cannot support cost-normalized claims.
#
# Modes:
#   cost.sh sum <arm-dir>
#       Sum every usage.json found anywhere under <arm-dir> and print one JSON
#       object with nullable totals plus `cost_source` and `accounting_state`.
#   cost.sh sum-file <usage.json>
#       Echo the three accounted fields of a single usage.json as a JSON object
#       (used by run.sh to validate a freshly-written record).
#
# Fails closed (exit 1) if jq is absent or a usage.json is present but malformed
# JSON (a malformed accounting record must not be silently dropped to zero).

set -euo pipefail

die() {
  echo "cost.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  cost.sh sum      <arm-dir>
  cost.sh sum-file <usage.json>
EOF
  exit 2
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq not found on PATH; cannot account cost"
}

# Echo one usage record, preserving unknowns as null. A file that is present but
# not valid JSON is a hard error (fail closed).
sum_file() {
  local file="$1"
  [[ -f "${file}" ]] || die "usage file not found: ${file}"
  jq -e . "${file}" >/dev/null 2>&1 || die "malformed usage JSON: ${file}"
  jq -e '
    def token_or_null: if . == null or (type == "number" and isfinite and . >= 0 and floor == .) then . else error("expected nonnegative integral tokens or null") end;
    def finite_nonnegative_or_null: if . == null or (type == "number" and isfinite and . >= 0) then . else error("expected finite nonnegative number or null") end;
    (.tokens // .total_tokens // null | token_or_null) as $tokens |
    (.wall_clock_seconds // null | finite_nonnegative_or_null) as $wall |
    (.cost_usd // null | finite_nonnegative_or_null) as $cost |
    (.cost_source // "unknown") as $source |
    if ($source | IN("actual", "rate_estimated", "unknown")) | not then error("invalid cost_source") else . end |
    (if $tokens == null or $wall == null or $cost == null or $source == "unknown" then "incomplete" else "complete" end) as $state |
    if (.accounting_state? != null and .accounting_state != $state) then error("inconsistent accounting_state") else . end |
    {
      tokens: $tokens, wall_clock_seconds: $wall, cost_usd: $cost,
      cost_source: (if $cost == null then "unknown" else $source end),
      accounting_state: $state
    }' "${file}"
}

# Sum every usage.json under <arm-dir> into a single per-arm total object. An
# arm dir with no usage.json yields a zeroed object with runs=0.
sum_arm() {
  local arm_dir="$1"
  [[ -d "${arm_dir}" ]] || die "arm dir not found: ${arm_dir}"
  local arm
  arm="$(basename "${arm_dir}")"

  # Collect every record path into an array (NUL-safe) so the empty case is a
  # zero-length array rather than an unrun xargs invocation.
  local files=()
  local file
  while IFS= read -r -d '' file; do
    files+=("${file}")
  done < <(find "${arm_dir}" -type f -name usage.json -print0 2>/dev/null)

  # No records is unknown, not a zero-cost run. (Avoids `jq -s` with no file
  # arguments, which would block reading stdin.)
  if [[ "${#files[@]}" -eq 0 ]]; then
    jq -n --arg arm "${arm}" \
      '{ arm: $arm, runs: 0, tokens: null, wall_clock_seconds: null, cost_usd: null, cost_source: "unknown", accounting_state: "unknown" }'
    return 0
  fi

  # Validate each record first so a malformed one fails closed before summing.
  for file in "${files[@]}"; do
    jq -e . "${file}" >/dev/null 2>&1 || die "malformed usage JSON: ${file}"
  done

  # Normalize each record first. Any incomplete field taints only that total;
  # the output keeps it null rather than manufacturing a zero.
  jq -s --arg arm "${arm}" '
    def normalized:
      (.tokens // .total_tokens // null) as $tokens |
      (.wall_clock_seconds // null) as $wall |
      (.cost_usd // null) as $cost |
      (.cost_source // "unknown") as $source |
      if (($tokens == null or (($tokens|type) == "number" and ($tokens|isfinite) and $tokens >= 0 and ($tokens|floor) == $tokens)) and ($wall == null or (($wall|type) == "number" and ($wall|isfinite) and $wall >= 0)) and ($cost == null or (($cost|type) == "number" and ($cost|isfinite) and $cost >= 0)) and ($source | IN("actual", "rate_estimated", "unknown"))) then
        (if $tokens == null or $wall == null or $cost == null or $source == "unknown" then "incomplete" else "complete" end) as $state |
        if (.accounting_state? != null and .accounting_state != $state) then error("inconsistent accounting_state") else {tokens:$tokens, wall_clock_seconds:$wall, cost_usd:$cost, cost_source:(if $cost == null then "unknown" else $source end), accounting_state:$state} end
      else error("invalid usage accounting fields") end;
    map(normalized) |
    {
      arm: $arm,
      runs: length,
      tokens: (if any(.[]; .tokens == null) then null else map(.tokens) | add end),
      wall_clock_seconds: (if any(.[]; .wall_clock_seconds == null) then null else map(.wall_clock_seconds) | add end),
      cost_usd: (if any(.[]; .cost_usd == null or .cost_source == "unknown") then null else map(.cost_usd) | add end),
      cost_source: (if any(.[]; .cost_source == "unknown") then "unknown" elif any(.[]; .cost_source == "rate_estimated") then "rate_estimated" else "actual" end),
      accounting_state: (if any(.[]; .accounting_state != "complete") then "incomplete" else "complete" end)
    }' "${files[@]}"
}

main() {
  [[ $# -ge 1 ]] || usage
  require_jq
  case "$1" in
    sum)
      shift
      [[ $# -eq 1 ]] || usage
      sum_arm "$1"
      ;;
    sum-file)
      shift
      [[ $# -eq 1 ]] || usage
      sum_file "$1"
      ;;
    -h | --help)
      usage
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
