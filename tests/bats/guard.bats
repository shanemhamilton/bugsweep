#!/usr/bin/env bats
#
# Tests for scripts/guard.sh deadline handling (bugsweep-5ft). The guard is the
# deterministic checkpoint the SKILL consults at phase boundaries; once the
# persisted wall-clock deadline has passed, the run must route to finalize so
# nightshift still gets report.md + run-summary.json instead of silence.

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

@test "context-build deadline checkpoint can finalize to stub report and run-summary" {
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
  grep -qi 'always.*finalize' "$SKILL_MD"
  grep -qi 'context-build.*guard.sh' "$SKILL_MD"
}
