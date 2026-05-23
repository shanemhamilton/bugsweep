#!/usr/bin/env bash
# bugsweep checks runner. Two modes:
#   run_checks.sh baseline <RUN_DIR>   -> record the starting state
#   run_checks.sh verify   <RUN_DIR>   -> run again and compare to baseline
# Exit code: 0 if checks are GREEN or no worse than baseline; 1 if regressed.
# It auto-detects the project's checks unless overridden in the config.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

phase="${1:-}"; run_dir="${2:-}"
[ -n "$phase" ] && [ -n "$run_dir" ] || die "usage: run_checks.sh <baseline|verify> <RUN_DIR>"
[ -d "$run_dir" ] || die "run dir not found: $run_dir"

# --- Resolve check commands: config overrides win, else auto-detect -----------
cmd_test="$(cfg_get '.commands.test' '')"
cmd_build="$(cfg_get '.commands.build' '')"
cmd_typecheck="$(cfg_get '.commands.typecheck' '')"
cmd_lint="$(cfg_get '.commands.lint' '')"

detect() {
  # Only fills commands that weren't explicitly configured.
  if [ -f package.json ]; then
    [ -z "$cmd_test" ] && grep -q '"test"' package.json 2>/dev/null && cmd_test="npm test --silent"
    [ -z "$cmd_build" ] && grep -q '"build"' package.json 2>/dev/null && cmd_build="npm run build --silent"
    [ -z "$cmd_typecheck" ] && [ -f tsconfig.json ] && cmd_typecheck="npx --no-install tsc --noEmit"
  fi
  if [ -f pyproject.toml ] || [ -f setup.cfg ] || [ -f pytest.ini ] || ls tests/ >/dev/null 2>&1; then
    [ -z "$cmd_test" ] && command -v pytest >/dev/null 2>&1 && cmd_test="pytest -q"
  fi
  if [ -f go.mod ]; then
    [ -z "$cmd_test" ] && cmd_test="go test ./..."
    [ -z "$cmd_build" ] && cmd_build="go build ./..."
  fi
  if [ -f Cargo.toml ]; then
    [ -z "$cmd_test" ] && cmd_test="cargo test --quiet"
    [ -z "$cmd_build" ] && cmd_build="cargo build --quiet"
  fi
  if ls ./*.xcodeproj >/dev/null 2>&1 || ls ./*.xcworkspace >/dev/null 2>&1; then
    : # iOS/Xcode: leave to config override; xcodebuild invocations are project-specific.
  fi
}
detect

# --- Run each available check, capture pass/fail ------------------------------
results_file="${run_dir}/checks-${phase}.json"
overall=0
detail=""

run_one() {
  local name="$1" cmd="$2"
  [ -z "$cmd" ] && return 0
  log "running ${name}: ${cmd}"
  if ( eval "$cmd" ) >"${run_dir}/${phase}-${name}.log" 2>&1; then
    detail="${detail}{\"check\":\"${name}\",\"status\":\"pass\"},"
  else
    detail="${detail}{\"check\":\"${name}\",\"status\":\"fail\"},"
    overall=1
  fi
}

run_one "test" "$cmd_test"
run_one "typecheck" "$cmd_typecheck"
run_one "build" "$cmd_build"
run_one "lint" "$cmd_lint"

has_any_check="yes"
[ -z "${cmd_test}${cmd_build}${cmd_typecheck}${cmd_lint}" ] && has_any_check="no"

detail="[${detail%,}]"
printf '{"phase":"%s","overall":%d,"has_any_check":"%s","checks":%s}\n' \
  "$phase" "$overall" "$has_any_check" "$detail" > "$results_file"

if [ "$has_any_check" = "no" ]; then
  log "No automated checks detected. See references/no-tests.md — fixes will be more conservative."
  echo "NO_CHECKS"
  exit 0
fi

# --- Baseline just records; verify compares -----------------------------------
if [ "$phase" = "baseline" ]; then
  cp "$results_file" "${run_dir}/baseline.json"
  echo "BASELINE_OVERALL=${overall}"
  exit 0
fi

base_overall=0
if [ -f "${run_dir}/baseline.json" ]; then
  base_overall="$(grep -o '"overall":[0-9]*' "${run_dir}/baseline.json" | head -1 | grep -o '[0-9]*' || echo 0)"
fi

# Regression = checks fail now but passed (or didn't fail) at baseline.
if [ "$overall" -gt "$base_overall" ]; then
  echo "REGRESSION"
  exit 1
fi
echo "OK"
exit 0
