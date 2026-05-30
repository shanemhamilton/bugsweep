#!/usr/bin/env bats
#
# Tests for scripts/finalize.sh — specifically the stub-report backstop that
# emits a coverage summary when report.md was never written (silent-failure guard
# for large-repo runs that stall before the model completes the report template).

FINALIZE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/finalize.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  git -C "$dir" commit --allow-empty -m "init" -q
}

_make_run_dir() {
  # Minimal run directory with required state.env + ledger.jsonl.
  local repo="$1" run_dir="$2" orig_branch="$3"
  mkdir -p "$run_dir"

  local ts="20991231T000000Z"
  local branch="bugsweep/${ts}"
  git -C "$repo" checkout -b "$branch" -q 2>/dev/null || true

  cat > "${run_dir}/state.env" <<ENV
BUGSWEEP_TS="${ts}"
BUGSWEEP_BRANCH="${branch}"
BUGSWEEP_ORIG_BRANCH="${orig_branch}"
BUGSWEEP_STASH_REF="none"
BUGSWEEP_START_EPOCH="$(date +%s)"
BUGSWEEP_SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"
ENV

  touch "${run_dir}/ledger.jsonl"
}

_make_recon_json() {
  local run_dir="$1" covered="$2" total="$3"
  # Build covered array from count
  local covered_arr="[]"
  if [ "$covered" -gt 0 ]; then
    local items=""
    for i in $(seq 1 "$covered"); do
      items="${items}${items:+,}$i"
    done
    covered_arr="[${items}]"
  fi

  cat > "${run_dir}/recon.json" <<JSON
{
  "files_in_scope": 42,
  "batch_count": ${total},
  "batches": [],
  "architectural_targets": [],
  "covered": ${covered_arr}
}
JSON
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  ORIG_BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD)"
  RUN_DIR="${BATS_TMP}/run-dir"
}

teardown() {
  rm -rf "$BATS_TMP"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "finalize: emits stub report.md when report.md is missing" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  # Stub must exist.
  [ -f "${RUN_DIR}/report.md" ]

  # Must contain the INCOMPLETE warning.
  grep -qi "INCOMPLETE" "${RUN_DIR}/report.md"
}

@test "finalize: stub report includes coverage fraction from recon.json" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 3 10

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  [ -f "${RUN_DIR}/report.md" ]
  grep -q "3/10" "${RUN_DIR}/report.md"
}

@test "finalize: does NOT overwrite an existing report.md" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"

  echo "# existing report" > "${RUN_DIR}/report.md"
  local before
  before="$(cat "${RUN_DIR}/report.md")"

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local after
  after="$(cat "${RUN_DIR}/report.md")"
  [ "$before" = "$after" ]
}

@test "finalize: stub report includes branch names" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  [ -f "${RUN_DIR}/report.md" ]
  grep -q "20991231T000000Z" "${RUN_DIR}/report.md"
}

@test "finalize: still finalizes cleanly (FINALIZED line) even without report.md" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  echo "$output" | grep -q "FINALIZED"
}
