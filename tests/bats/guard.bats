#!/usr/bin/env bats
#
# Tests for scripts/guard.sh deadline handling (bugsweep-5ft). The guard is the
# deterministic checkpoint the SKILL consults at phase boundaries; once the
# persisted wall-clock deadline has passed, the run must route to finalize so
# nightshift still gets report.md + run-summary.json instead of silence.
#
# Also covers the bugsweep-5ft review's sanitization-branch gaps (MAJOR 5):
# preflight.sh's caps.max_runtime_minutes fallback (missing/0/negative/non-numeric/
# null config value -> default) and guard.sh's malformed BUGSWEEP_DEADLINE_EPOCH
# fallback (empty/garbage/negative state.env value -> recomputed default deadline).
# The model-facing per-batch checkpoint that BLOCKER 1 of that review added to
# prompts/context-build.md is covered separately by the grep-level prompt-contract
# tests in bench/tests/unit/test_context_build_prompt.py (same pattern as
# bench/tests/unit/test_skill_report_format.py) — this file only ever drove the
# STOP->finalize handoff manually (pre-existing mu3/e1r plumbing), it never
# exercised the model-facing prompt text itself.

GUARD_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/guard.sh"
FINALIZE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/finalize.sh"
PREFLIGHT_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/preflight.sh"
SKILL_MD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/SKILL.md"
SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  git -C "$dir" checkout -q -b dev
  git -C "$dir" commit --allow-empty -m "init" -q
}

_make_run_dir() {
  local repo="$1" run_dir="$2" orig_branch="$3" start_epoch="$4" deadline_epoch="$5"
  mkdir -p "$run_dir"

  local branch="bugsweep/deadline-test"
  git -C "$repo" checkout -q -b "$branch" 2>/dev/null || true

  cat > "${run_dir}/state.env" <<ENV
BUGSWEEP_TS=deadline-test
BUGSWEEP_RUN_DIR=${run_dir}
BUGSWEEP_BRANCH=${branch}
BUGSWEEP_ORIG_BRANCH=${orig_branch}
BUGSWEEP_STASH_REF=none
BUGSWEEP_START_EPOCH=${start_epoch}
BUGSWEEP_DEADLINE_EPOCH=${deadline_epoch}
BUGSWEEP_MAX_RUNTIME_MINUTES=120
BUGSWEEP_MODE=detect-only
BUGSWEEP_SCRIPT_DIR=${SCRIPT_DIR}
BUGSWEEP_WORKTREE=
ENV

  touch "${run_dir}/ledger.jsonl"
}

_make_recon_json() {
  local run_dir="$1"
  cat > "${run_dir}/recon.json" <<JSON
{
  "files_in_scope": 12,
  "batch_count": 4,
  "batches": [],
  "architectural_targets": [],
  "covered": [1]
}
JSON
}

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  ORIG_BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD)"
  RUN_DIR="${BATS_TMP}/run-dir"
  cd "$REPO"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

@test "preflight persists an absolute BUGSWEEP_DEADLINE_EPOCH in state.env" {
  run bash "$PREFLIGHT_SH"
  [ "$status" -eq 0 ]

  local run_dir deadline start max_minutes
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  [ -n "$run_dir" ]
  # shellcheck disable=SC1090
  . "${run_dir}/state.env"
  deadline="${BUGSWEEP_DEADLINE_EPOCH:-}"
  start="${BUGSWEEP_START_EPOCH:-}"
  max_minutes="${BUGSWEEP_MAX_RUNTIME_MINUTES:-}"

  case "$deadline" in ''|*[!0-9]*) echo "missing numeric deadline: $deadline" >&2; false ;; esac
  [ "$deadline" -gt "$start" ]
  [ "$deadline" -eq $(( start + max_minutes * 60 )) ]
}

@test "guard.sh: STOP after persisted deadline with remaining-time accounting" {
  local now
  now="$(date +%s)"
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH" "$((now - 300))" "$((now - 1))"

  run bash "$GUARD_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^STOP runtime_cap_reached'
  echo "$output" | grep -q 'remaining_sec=0'
  echo "$output" | grep -q 'deadline_epoch='
}

@test "guard.sh: CONTINUE before persisted deadline includes remaining seconds" {
  local now
  now="$(date +%s)"
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH" "$((now - 60))" "$((now + 120))"

  run bash "$GUARD_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^CONTINUE '
  echo "$output" | grep -q 'remaining_sec='
  echo "$output" | grep -q 'deadline_epoch='
}

@test "guard.sh STOP + finalize.sh: generic deadline stop emits stub report.md and run-summary.json (STOP->finalize handoff contract)" {
  # bugsweep-5ft review MAJOR 4: this test drives guard.sh + finalize.sh directly
  # (pre-existing mu3/e1r plumbing) — it proves the generic STOP->finalize artifact
  # contract, not that prompts/context-build.md's per-batch loop actually calls
  # guard.sh. That model-facing contract is asserted separately by the grep-level
  # prompt-contract tests in bench/tests/unit/test_context_build_prompt.py.
  local now guard_out
  now="$(date +%s)"
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH" "$((now - 300))" "$((now - 1))"
  _make_recon_json "$RUN_DIR"

  guard_out="$(bash "$GUARD_SH" "$RUN_DIR")"
  case "$guard_out" in
    STOP*) bash "$FINALIZE_SH" "$RUN_DIR" >/dev/null ;;
    *) echo "expected STOP, got: $guard_out" >&2; false ;;
  esac

  [ -f "${RUN_DIR}/report.md" ]
  [ -f "${RUN_DIR}/run-summary.json" ]
  grep -qi "INCOMPLETE" "${RUN_DIR}/report.md"
  python3 - "$RUN_DIR/run-summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["status"] == "partial", d["status"]
assert d["coverage"] == {"covered": 1, "total": 4}, d["coverage"]
PY
}

@test "SKILL.md documents deadline checkpoints and finalize-on-deadline contract" {
  grep -q 'BUGSWEEP_DEADLINE_EPOCH' "$SKILL_MD"
  grep -qi 'finalize on any' "$SKILL_MD"
  grep -q 'STOP\*' "$SKILL_MD"
}

@test "SKILL.md states the per-batch checkpoint is canonical (bugsweep-5ft review BLOCKER 2)" {
  # The two passages that used to disagree on WHEN context-build checks the
  # deadline (preflight intro vs. Step 2) must now both point at ONE canonical
  # rule: the per-batch checkpoint inside the modeling loop.
  grep -qi 'canonical checkpoint' "$SKILL_MD"
  grep -q 'Per-batch deadline checkpoint' "$SKILL_MD"
  # The old standalone "after context-build completes ... between large
  # batches" instruction (vague, no snippet, disconnected from the batch loop
  # it was supposed to guard) must be gone as its own sentence.
  ! grep -q 'After context-build completes, run' "$SKILL_MD"
}

@test "SKILL.md states the no-silence contract honestly (bugsweep-5ft review BLOCKER 3)" {
  # Must not claim a hard-kill-surviving trap; must state the guarantee is
  # voluntary phase-boundary checks, and must give the orchestrator/harness
  # wall-clock guidance (outer timeout above the inner caps.max_runtime_minutes).
  grep -qi 'VOLUNTARY' "$SKILL_MD"
  grep -qi 'SIGKILL' "$SKILL_MD"
  grep -qi 'Operational corollary' "$SKILL_MD"
  grep -q 'caps.max_runtime_minutes' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# MAJOR 5 (bugsweep-5ft review): preflight.sh's caps.max_runtime_minutes
# sanitization branches. Code (scripts/preflight.sh):
#   max_runtime_minutes="$(cfg_get '.caps.max_runtime_minutes' '120')"
#   case "$max_runtime_minutes" in ''|*[!0-9]*) max_runtime_minutes=120 ;; esac
#   [ "$max_runtime_minutes" -gt 0 ] || max_runtime_minutes=120
# Every bad-input case below must still resolve to the coded default: 120.
# ---------------------------------------------------------------------------

_assert_preflight_max_runtime_default() {
  local config_json="$1"
  mkdir -p "${REPO}/config"
  printf '%s' "$config_json" > "${REPO}/config/bugsweep.config.json"

  _PREFLIGHT_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" \
    run bash "$PREFLIGHT_SH"
  [ "$status" -eq 0 ]

  local run_dir
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  [ -n "$run_dir" ]
  # shellcheck disable=SC1090
  . "${run_dir}/state.env"
  [ "$BUGSWEEP_MAX_RUNTIME_MINUTES" -eq 120 ]
  [ "$BUGSWEEP_DEADLINE_EPOCH" -eq $(( BUGSWEEP_START_EPOCH + 120 * 60 )) ]
}

@test "preflight.sh: _PREFLIGHT_TEST_CONFIG_OVERRIDE actually redirects cfg_get (sanity check)" {
  # Proves the override hook is load-bearing: a VALID, non-default value must
  # come through untouched, so the "falls back to 120" tests below are known
  # to be exercising the override (and therefore the real sanitization code),
  # not silently reading the worktree's own config/bugsweep.config.json
  # (which also happens to be 120 and would make a broken override invisible).
  mkdir -p "${REPO}/config"
  printf '{"caps": {"max_runtime_minutes": 45}}' > "${REPO}/config/bugsweep.config.json"

  _PREFLIGHT_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" \
    run bash "$PREFLIGHT_SH"
  [ "$status" -eq 0 ]

  local run_dir
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  [ -n "$run_dir" ]
  # shellcheck disable=SC1090
  . "${run_dir}/state.env"
  [ "$BUGSWEEP_MAX_RUNTIME_MINUTES" -eq 45 ]
  [ "$BUGSWEEP_DEADLINE_EPOCH" -eq $(( BUGSWEEP_START_EPOCH + 45 * 60 )) ]
}

@test "preflight.sh: missing caps.max_runtime_minutes key falls back to the 120m default" {
  _assert_preflight_max_runtime_default '{"caps": {}}'
}

@test "preflight.sh: caps.max_runtime_minutes=0 falls back to the 120m default (the -gt 0 guard)" {
  _assert_preflight_max_runtime_default '{"caps": {"max_runtime_minutes": 0}}'
}

@test "preflight.sh: caps.max_runtime_minutes=-5 falls back to the 120m default (the non-digit case guard)" {
  _assert_preflight_max_runtime_default '{"caps": {"max_runtime_minutes": -5}}'
}

@test 'preflight.sh: caps.max_runtime_minutes="abc" falls back to the 120m default' {
  _assert_preflight_max_runtime_default '{"caps": {"max_runtime_minutes": "abc"}}'
}

@test "preflight.sh: caps.max_runtime_minutes=null falls back to the 120m default" {
  _assert_preflight_max_runtime_default '{"caps": {"max_runtime_minutes": null}}'
}

# ---------------------------------------------------------------------------
# MAJOR 5 (bugsweep-5ft review): guard.sh's malformed BUGSWEEP_DEADLINE_EPOCH
# sanitization branch. Code (scripts/guard.sh):
#   deadline_epoch="${BUGSWEEP_DEADLINE_EPOCH:-}"
#   case "$deadline_epoch" in
#     ''|*[!0-9]*) deadline_epoch=$(( BUGSWEEP_START_EPOCH + (max_minutes * 60) )) ;;
#   esac
# A malformed persisted deadline must not crash the guard; it must recompute
# from BUGSWEEP_START_EPOCH + the configured max-runtime default (120m in this
# repo's config/bugsweep.config.json — see the assertion below) and the run
# must still behave (CONTINUE/STOP correctly, not error out).
# ---------------------------------------------------------------------------

_assert_guard_recomputes_deadline() {
  local bad_deadline="$1"
  local now start
  now="$(date +%s)"
  start=$((now - 60))
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH" "$start" "$bad_deadline"

  run bash "$GUARD_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  # Still functions: a fresh 60s-old start plus a recomputed ~120m deadline
  # has not expired yet, so the run must CONTINUE, not error or false-STOP.
  echo "$output" | grep -q '^CONTINUE '
  echo "$output" | grep -q "deadline_epoch=$((start + 120 * 60))"
}

@test "guard.sh: empty BUGSWEEP_DEADLINE_EPOCH recomputes the default deadline and still behaves" {
  _assert_guard_recomputes_deadline ""
}

@test "guard.sh: garbage BUGSWEEP_DEADLINE_EPOCH recomputes the default deadline and still behaves" {
  _assert_guard_recomputes_deadline "not-a-number"
}

@test "guard.sh: negative BUGSWEEP_DEADLINE_EPOCH recomputes the default deadline and still behaves" {
  _assert_guard_recomputes_deadline "-500"
}
