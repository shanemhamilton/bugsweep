#!/usr/bin/env bash
#
# cost.sh — accumulate per-arm token / wall-clock / dollar cost for a run.
#
# Input contract (defined HERE, consumed by run.sh): the runner writes a
# per-(case, run, arm) usage record to
#     results/<run-id>/<arm>/<case-id>/run-<n>/usage.json
# of the shape:
#     { "tokens": <int>, "wall_clock_seconds": <number>, "cost_usd": <number> }
# (the egress proxy's own proxy-usage.json — see proxy.sh — carries request/token
# counts; usage.json is the runner-side per-invocation accounting. Either source
# may emit a `tokens` field; cost.sh only requires the three fields above and
# tolerates extra keys.) A missing usage.json contributes zero (a SKIPped case
# burns no API call), so the totals never overcount.
#
# Modes:
#   cost.sh sum <arm-dir>
#       Sum every usage.json found anywhere under <arm-dir> and print one JSON
#       object: { "arm": "<basename>", "runs": N, "tokens": T,
#                 "wall_clock_seconds": W, "cost_usd": C }.
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

# Echo a single usage.json normalized to the three accounted fields. A file that
# is present but not valid JSON is a hard error (fail closed).
sum_file() {
  local file="$1"
  [[ -f "${file}" ]] || die "usage file not found: ${file}"
  jq -e . "${file}" >/dev/null 2>&1 || die "malformed usage JSON: ${file}"
  jq '{
    tokens: (.tokens // 0),
    wall_clock_seconds: (.wall_clock_seconds // 0),
    cost_usd: (.cost_usd // 0)
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

  # No records → emit a zeroed total directly. (Avoids `jq -s` with no file
  # arguments, which would block reading stdin.)
  if [[ "${#files[@]}" -eq 0 ]]; then
    jq -n --arg arm "${arm}" \
      '{ arm: $arm, runs: 0, tokens: 0, wall_clock_seconds: 0, cost_usd: 0 }'
    return 0
  fi

  # Validate each record first so a malformed one fails closed before summing.
  for file in "${files[@]}"; do
    jq -e . "${file}" >/dev/null 2>&1 || die "malformed usage JSON: ${file}"
  done

  # Slurp all records and fold them. The normalized `add // 0` guards keep the
  # totals numeric even if a record omits a field.
  jq -s --arg arm "${arm}" '
    {
      arm: $arm,
      runs: length,
      tokens: (map(.tokens // 0) | add // 0),
      wall_clock_seconds: (map(.wall_clock_seconds // 0) | add // 0),
      cost_usd: (map(.cost_usd // 0) | add // 0)
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
