#!/usr/bin/env bash
#
# validate_case.sh — fast, jq-based required-field pre-check for a corpus case.
#
# This is a CHEAP gate run by run.sh before the (slower) full JSON Schema
# validation: it confirms the case JSON parses and that every required top-level
# and nested field exists. It is intentionally a structural presence check, not
# a full schema validation — the authoritative contract is bench/corpus/schema.json
# (enforced in the Python test suite). Exits non-zero with a clear message on the
# first missing field so a malformed case fails fast and closed.
#
# usage: validate_case.sh <case.json>

set -euo pipefail

die() {
  echo "validate_case.sh: $*" >&2
  exit 1
}

usage() {
  echo "usage: validate_case.sh <case.json>" >&2
  exit 2
}

# Dotted jq paths that MUST be present (and non-null) in a valid case.
readonly REQUIRED_PATHS=(
  ".id"
  ".language"
  ".category"
  ".source"
  ".source.repo"
  ".source.pre_fix_commit"
  ".source.fix_commit"
  ".source.advisory_url"
  ".source.disclosure_date"
  ".ground_truth"
  ".ground_truth.hunks"
  ".ground_truth.files"
  ".ground_truth.description"
  ".ground_truth.fix_summary"
  ".size_ceiling"
  ".size_ceiling.max_files"
  ".size_ceiling.max_loc"
  ".cross_file"
)

main() {
  [[ $# -eq 1 ]] || usage
  local case_file="$1"

  command -v jq >/dev/null 2>&1 || die "jq not found on PATH; cannot validate case"
  [[ -f "${case_file}" ]] || die "case file not found: ${case_file}"

  # Parse check: fail closed on malformed JSON.
  if ! jq -e . "${case_file}" >/dev/null 2>&1; then
    die "invalid JSON in ${case_file}"
  fi

  local path
  for path in "${REQUIRED_PATHS[@]}"; do
    # `getpath` would require splitting; instead use jq with the literal path.
    # A missing key yields null; jq -e returns non-zero for null/false.
    if ! jq -e "${path} != null" "${case_file}" >/dev/null 2>&1; then
      die "missing required field '${path}' in ${case_file}"
    fi
  done
}

main "$@"
