#!/usr/bin/env bash
# bugsweep checks runner. Two modes:
#   run_checks.sh baseline <RUN_DIR>   -> record the starting state
#   run_checks.sh verify   <RUN_DIR>   -> run again and compare to baseline
# Exit code: 0 if checks are GREEN or no worse than baseline; 1 if regressed.
# It auto-detects the project's checks unless overridden in the config.
#
# --- Flaky-aware verify (bugsweep-ml7) ----------------------------------------
# This script has NO per-test granularity: each configured check (test/
# typecheck/build/lint) is one opaque shell command, and baseline/verify only
# ever compare pass/fail PER CHECK, never per individual test. That is a hard
# pre-existing limitation, not something this feature works around:
#   - "Newly failing" is detected at the check level (a check that passed, or
#     wasn't run, at baseline but fails at verify).
#   - When the "test" check newly fails, it is rerun (re-invoking the SAME
#     check command) up to `.verify.flaky_reruns` (default 3) times. If the
#     project's test runner output lets us identify individual failing test
#     names (best-effort regex over common pytest/jest/vitest/go/cargo/bats
#     failure-line formats), those names are recorded for reporting; if not,
#     the whole "test" check is treated as the rerun unit and reported under
#     a synthetic id. Either way the thing that is actually re-EXECUTED is
#     always the check's command — there is no mechanism here to target one
#     test inside a suite without running the rest.
#   - Classification is by MAJORITY of the reruns, NOT pass-once. All N reruns
#     are run and their pass/fail outcomes counted. A STRICT majority of rerun
#     passes (rerun_passes > rerun_fails) reclassifies the check as flaky:
#     excluded from the regression decision, recorded to <RUN_DIR>/flaky.jsonl
#     and appended to <RUN_DIR>/ledger.jsonl as
#     {"event":"flaky_test","test":<id>,"file":<file-or-null>,"reruns":<n>,
#     "failures":<m>}, and surfaced via a stable `FLAKY=<n>` line plus one
#     `FLAKY_TEST=<id>` line. A tie or a majority of rerun FAILURES stays a
#     REGRESSION and reverts (the existing exit-1 contract is UNCHANGED).
#   - Fail-safe: if the rerun MECHANISM itself errors (as opposed to the
#     reran command simply failing) this falls back to the OLD behavior —
#     treat the check as a deterministic failure and revert. A broken rerun
#     path must never become a loophole that lets a red checkpoint through.
#
# WHAT THIS ACTUALLY DISTINGUISHES — DO NOT OVERCLAIM (safety, MAJOR 2):
# This mechanism does NOT prove a failure is "deterministic" vs "flaky" in the
# general sense. Precisely, it distinguishes only "failed the MAJORITY of
# reruns in a SHARED working tree / environment" from "passed the majority".
# Because the reruns SHARE the initial run's working tree and environment (no
# per-rerun isolation), a MONOTONIC state-pollution failure — a broken fix
# whose first run fails but leaves a marker/cache/lock that makes later runs
# pass — CAN be misclassified as flaky. The majority-of-N vote raises the bar
# against this (a single pollution-driven pass no longer wins), but does not
# eliminate it: a fix that pollutes state on its FIRST run and then passes a
# majority of reruns would still be mislabeled flaky. Therefore any fix that
# lands with a flaky classification is LOUDLY surfaced (flaky.jsonl + ledger +
# run-summary + the `FLAKY=<n>`/`FLAKY_TEST=` stdout lines) so a human /
# orchestrator reviews it — a flaky-classified landed fix is never silent.
# Full per-rerun isolation (fresh worktree/env per rerun) is a documented
# FUTURE ENHANCEMENT (a follow-up bead), deliberately deferred here; this
# comment states the delivered guarantee accurately rather than claiming more
# safety than the shared-environment rerun provides.
#
# KNOWN LIMITATION (baseline-flaky, criterion 3): baseline.json records only
# an aggregate pass/fail PER CHECK, with no per-test identity at all. So a
# test that was ALREADY intermittently failing at baseline time — i.e. it
# happened to pass when baseline captured the "test" check as green — cannot
# be distinguished from a genuinely new regression by this mechanism: if it
# fails at verify time and then passes a majority of reruns, it is (correctly,
# by this design) classified as flaky, even though from the project's
# perspective it was flaky all along rather than newly introduced. There is no per-test
# baseline identity to check it against. Fixing this would require baseline
# to also capture and persist individual test outcomes (framework-specific
# parsing baseline does not do today), which is out of scope here; this
# comment exists so that limitation is documented rather than silently
# assumed away.

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

# --- Flaky-rerun helpers (bugsweep-ml7) ---------------------------------------
# Best-effort, language-agnostic extraction of a failing test's identity from
# a check's captured log, purely for the flaky.jsonl/ledger "test" field and
# the human-facing FLAKY_TEST= line. Never used to decide what to re-execute
# (that is always the whole "test" check's command — see header comment).
# Recognizes the common failure-line shapes emitted by pytest, jest/vitest,
# go test, cargo test, and bats; falls back to a generic marker so the field
# is always populated with SOMETHING rather than emitting invalid JSON.
extract_failing_test_id() {
  local log="$1" line=""
  [ -f "$log" ] || { printf '%s' "test-check"; return 0; }
  # pytest: "FAILED path/to/test_x.py::test_name" (optionally "- reason").
  line="$(grep -m1 -oE '^FAILED[[:space:]]+[^[:space:]]+' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "${line#FAILED }"; return 0; fi
  # jest/vitest: "✕ test name" or "FAIL  path" — prefer the ✕ assertion line.
  line="$(grep -m1 -oE '(✕|✗)[[:space:]]+.+' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "$(printf '%s' "$line" | sed -E 's/^(✕|✗)[[:space:]]+//')"; return 0; fi
  # go test: "--- FAIL: TestName (0.00s)"
  line="$(grep -m1 -oE -- '--- FAIL: [^[:space:]]+' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "${line#--- FAIL: }"; return 0; fi
  # cargo test: "test module::test_name ... FAILED"
  line="$(grep -m1 -oE 'test [^[:space:]]+ \.\.\. FAILED' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "$(printf '%s' "$line" | sed -E 's/^test ([^[:space:]]+).*/\1/')"; return 0; fi
  # bats: "not ok N description"
  line="$(grep -m1 -oE 'not ok [0-9]+ .+' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "${line#not ok }"; return 0; fi
  printf '%s' "test-check"
}

# Best-effort file path for the failing test, if the id embeds one
# (pytest's "path::name" shape); null-worthy otherwise per the bead spec
# ("file may be null").
extract_failing_test_file() {
  local id file
  id="$(extract_failing_test_id "$1")"
  case "$id" in
    *"::"*) file="${id%%::*}"; printf '%s' "$file" ;;
    *) printf '' ;;
  esac
}

# Emit a JSON string literal for a possibly-empty value, or the bare word
# null when empty — used for flaky.jsonl's "file" field which may be null.
json_str_or_null() {
  local v="$1"
  if [ -z "$v" ]; then
    printf 'null'
  else
    # Minimal escaping sufficient for the values we ever pass here (test ids
    # and file paths): backslash and double-quote.
    printf '"%s"' "$(printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

# --- Run each available check, capture pass/fail ------------------------------
results_file="${run_dir}/checks-${phase}.json"
overall=0
detail=""
# Set by run_one() for the "test" check only, so the verify-phase flaky-rerun
# logic below can tell whether THIS check just failed without re-parsing
# results_file. Deliberately check-scoped (not a generic per-check map) since
# flaky rerun only ever applies to "test" (see header comment).
test_check_failed=0
# Whether any check OTHER than "test" failed. Needed because "overall" is a
# single shared 0/1 flag across all checks (pre-existing shape, unchanged) —
# if lint/build/typecheck ALSO regressed at the same time the "test" check
# turns out to be flaky, reclassifying test as flaky must NOT also erase a
# genuine lint/build/typecheck regression. Tracking this separately lets the
# flaky path recompute "overall" instead of blindly zeroing it.
other_check_failed=0

run_one() {
  local name="$1" cmd="$2"
  [ -z "$cmd" ] && return 0
  log "running ${name}: ${cmd}"
  if ( eval "$cmd" ) >"${run_dir}/${phase}-${name}.log" 2>&1; then
    detail="${detail}{\"check\":\"${name}\",\"status\":\"pass\"},"
  else
    detail="${detail}{\"check\":\"${name}\",\"status\":\"fail\"},"
    overall=1
    if [ "$name" = "test" ]; then test_check_failed=1; else other_check_failed=1; fi
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

# Did the "test" check pass at baseline? (0/1 flag, aggregate-only per the
# documented limitation above — there is no per-test baseline identity.)
base_test_failed=0
if [ -f "${run_dir}/baseline.json" ]; then
  base_test_failed="$(grep -o '{"check":"test","status":"[a-z]*"}' "${run_dir}/baseline.json" \
    | grep -c '"status":"fail"' || true)"
  case "$base_test_failed" in ''|*[!0-9]*) base_test_failed=0 ;; esac
  [ "$base_test_failed" -gt 1 ] 2>/dev/null && base_test_failed=1
fi

# --- Flaky-aware rerun: only the "test" check, only when it NEWLY fails -------
# (test_check_failed=1 now, but it did not fail at baseline). See the header
# comment for the full design and the documented baseline-flaky limitation.
flaky_count=0
flaky_test_ids=""
if [ "$test_check_failed" -eq 1 ] && [ "$base_test_failed" -eq 0 ] && [ -n "$cmd_test" ]; then
  flaky_reruns="$(cfg_get '.verify.flaky_reruns' '3')"
  # clamp-to-default-3 (NOT clamp-to-disabled/0) is INTENTIONAL: a garbled or
  # non-numeric config value must not silently turn OFF flakiness protection,
  # so it falls back to the safe default rather than 0. Do not "fix" toward 0.
  case "$flaky_reruns" in ''|*[!0-9]*) flaky_reruns=3 ;; esac

  if [ "$flaky_reruns" -gt 0 ]; then
    # Best-effort test-id extraction from the failing log, for reporting only
    # (the thing actually re-executed is always the whole "test" check — see
    # header comment on why per-test targeting isn't possible here).
    fail_log="${run_dir}/verify-test.log"
    test_id="$(extract_failing_test_id "$fail_log")"
    test_file="$(extract_failing_test_file "$fail_log")"

    # Majority-of-reruns model (BLOCKER 1): run ALL N reruns (no early break)
    # and count how many pass vs fail. Classify flaky ONLY on a STRICT
    # majority of rerun passes (rerun_passes > rerun_fails). A tie or a
    # majority of rerun failures stays a REGRESSION. This raises the bar
    # against the state-pollution false-pass attack, where a broken fix's
    # first run fails but leaves a marker/cache that makes a MINORITY of the
    # (shared-environment) reruns pass. rerun_infra_ok gates the fail-safe:
    # if the rerun mechanism itself errors, we fall back to the pre-flaky
    # deterministic path and never classify flaky.
    reruns=0
    rerun_passes=0
    rerun_fails=0
    rerun_infra_ok=1

    i=1
    while [ "$i" -le "$flaky_reruns" ]; do
      rerun_log="${run_dir}/verify-test-rerun-${i}.log"
      # BUGSWEEP_RERUN_INJECT_FAILURE is a test-only fault-injection hook (same
      # pattern as common.sh's BUGSWEEP_NO_PYTHON) that simulates the rerun
      # MECHANISM itself erroring — distinct from the reran command simply
      # failing. A real-world equivalent would be: can't write $rerun_log,
      # can't fork the subshell, etc. Fail CLOSED: infra failure -> stop
      # rerunning and fall back to the old (pre-flaky) deterministic path.
      if [ -n "${BUGSWEEP_RERUN_INJECT_FAILURE:-}" ]; then
        rerun_infra_ok=0
        break
      fi
      reruns=$((reruns + 1))
      if ( eval "$cmd_test" ) >"$rerun_log" 2>&1; then
        rerun_passes=$((rerun_passes + 1))
      else
        rerun_fails=$((rerun_fails + 1))
      fi
      i=$((i + 1))
    done

    if [ "$rerun_infra_ok" -eq 1 ] && [ "$rerun_passes" -gt "$rerun_fails" ]; then
      # STRICT majority of reruns passed -> FLAKY. Exclude ONLY this check's
      # contribution to "overall" — if lint/build/typecheck ALSO regressed
      # independently, that must still trigger REGRESSION.
      overall="$other_check_failed"
      flaky_count=1
      # Total observed failures = the initial run (1) + rerun failures.
      total_failures=$((1 + rerun_fails))
      # test_id (raw) is the SINGLE source of truth for the id: json_str_or_null
      # escapes it for the durable JSONL, and the SAME raw value is carried to
      # the human-facing FLAKY_TEST= line below (MAJOR 4: never re-derive the id
      # with a second fragile regex, so parametrized ids with commas survive).
      flaky_line="$(printf '{"event":"flaky_test","test":%s,"file":%s,"reruns":%d,"failures":%d}' \
        "$(json_str_or_null "$test_id")" "$(json_str_or_null "$test_file")" \
        "$reruns" "$total_failures")"
      printf '%s\n' "$flaky_line" >> "${run_dir}/flaky.jsonl"
      printf '%s\n' "$flaky_line" >> "${run_dir}/ledger.jsonl"
      # Carry the (raw, unescaped) id forward for the human-facing line.
      flaky_test_ids="${test_id}"$'\n'
    fi
    # rerun_infra_ok=0, or reruns did NOT pass by a strict majority -> fall
    # through unchanged: this check's earlier "overall=1" contribution stands,
    # so the pre-existing deterministic REGRESSION path fires exactly as it
    # did before this feature existed (fail-safe / acceptance criterion 1, 4,
    # and the state-pollution / tie defenses).
  fi
fi

# Regression = checks fail now but passed (or didn't fail) at baseline.
if [ "$overall" -gt "$base_overall" ]; then
  echo "REGRESSION"
  exit 1
fi
# Surface any flaky reclassification LOUDLY (BLOCKER 1c) — but ONLY when one
# actually happened, so a clean all-green verify's stdout stays byte-identical
# to the pre-feature script (MAJOR 5). The FLAKY_TEST= id comes straight from
# the same id already written to the durable JSONL — no second fragile regex
# (MAJOR 4), so parametrized ids with commas/brackets pass through verbatim.
if [ "$flaky_count" -gt 0 ]; then
  printf 'FLAKY=%d\n' "$flaky_count"
  if [ -n "$flaky_test_ids" ]; then
    printf '%s' "$flaky_test_ids" | while IFS= read -r fl_test; do
      [ -n "$fl_test" ] && printf 'FLAKY_TEST=%s\n' "$fl_test"
    done
  fi
fi
echo "OK"
exit 0
