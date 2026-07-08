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

  # The original prose must survive untouched as a prefix. finalize.sh (bugsweep-mu3)
  # appends a script-generated "Findings (machine-readable)" section derived from
  # run-summary.json even onto a pre-existing report.md, so the file is no longer
  # required to be byte-identical afterward — only its original content must be
  # preserved (never overwritten or replaced).
  local after
  after="$(cat "${RUN_DIR}/report.md")"
  case "$after" in
    "$before"*) : ;;
    *) echo "original report.md content was not preserved as a prefix" >&2; return 1 ;;
  esac
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

@test "finalize: writes post-finalize handoff JSON with required fields" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  printf 'fix\n' > "${REPO}/fix.txt"
  git -C "$REPO" add fix.txt
  git -C "$REPO" commit -m "fix(bugsweep): test handoff" -q

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local handoff="${RUN_DIR}/post-finalize-handoff.json"
  [ -f "$handoff" ]
  echo "$output" | grep -q "POST_FINALIZE_HANDOFF=${handoff}"

  python3 - "$handoff" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
required = {
    "run_dir",
    "original_branch",
    "preserved_branch",
    "report_path",
    "fix_commits",
    "focused_tests",
    "quality_gate_command",
    "smoke_test_commands",
    "push_policy",
    "cleanup_policy",
    "safe_to_delete_branch_after",
    "final_readback_commands",
}
missing = sorted(required - set(data))
assert not missing, missing
assert data["run_dir"]
assert data["original_branch"]
assert data["preserved_branch"].startswith("bugsweep/")
assert data["fix_commits"]
PY
}

@test "finalize: no-python heredoc fallback emits valid JSON with the default quality-gate command (bugsweep-yvq)" {
  # Regression test for bugsweep-yvq: the DEFAULT BUGSWEEP_QUALITY_GATE_COMMAND
  # embeds literal double quotes (`verify "<run_dir>"`). On the no-python
  # fallback path (bare machines without python3), those quotes used to be
  # interpolated raw into the heredoc, breaking post-finalize-handoff.json's
  # JSON. Force the no-python path deterministically via BUGSWEEP_NO_PYTHON
  # (the same hook state.sh/common.sh's have_python() already honors) rather
  # than mangling PATH, and validate with jq — NOT python3 — since the whole
  # point is that this file must parse on a machine with no python3 at all.
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  # BUGSWEEP_QUALITY_GATE_COMMAND is deliberately left UNSET so finalize.sh
  # falls back to its default, quote-embedding value.
  unset BUGSWEEP_QUALITY_GATE_COMMAND || true

  BUGSWEEP_NO_PYTHON=1 run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local handoff="${RUN_DIR}/post-finalize-handoff.json"
  [ -f "$handoff" ]

  # The default command's embedded quotes must actually be present (sanity
  # check that this test exercises the buggy value, not an empty string).
  grep -q 'run_checks.sh verify' "$handoff"

  run jq -e . "$handoff"
  [ "$status" -eq 0 ]

  # Every required field must be present and non-null.
  run jq -e '
    (.run_dir | type == "string" and length > 0)
    and (.original_branch | type == "string" and length > 0)
    and (.preserved_branch | type == "string" and startswith("bugsweep/"))
    and (.report_path | type == "string")
    and (.quality_gate_command | type == "string" and contains("run_checks.sh verify"))
    and (.push_policy | type == "string")
    and (.cleanup_policy | type == "string")
    and (.safe_to_delete_branch_after | type == "string")
    and (.final_readback_commands | type == "array")
  ' "$handoff"
  [ "$status" -eq 0 ]
}
