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

# Appends one FINDING_EVENTS ledger line (see bench/scorer/run_summary.py) so
# summarize.sh's real reduction produces known counts/fixed/quarantined/
# confirmed_unfixed for the rollup-digest tests below.
_append_finding_event() {
  local run_dir="$1" event="$2" bug_id="$3" severity="$4"
  printf '{"event":"%s","file":"a.py","bug_id":"%s","severity":"%s","category":"security","line":1,"rationale":"r"}\n' \
    "$event" "$bug_id" "$severity" >> "${run_dir}/ledger.jsonl"
}

# A real (non-stub) report.md, so finalize.sh's status derivation resolves to
# "complete" (stop_reason null) rather than "stalled"/"partial".
_make_real_report() {
  local run_dir="$1"
  cat > "${run_dir}/report.md" <<'REPORT'
# bugsweep report
**Branch:** bugsweep/x   **Mode:** fix

## Summary
- Confirmed bugs: 2
REPORT
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

# ---------------------------------------------------------------------------
# Cross-repo/night operator rollup (bugsweep-6w8)
# ---------------------------------------------------------------------------

@test "finalize: rollup digest line is appended with correct fields when BUGSWEEP_ROLLUP_FILE is set" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 5 5
  _make_real_report "$RUN_DIR"
  _append_finding_event "$RUN_DIR" "fix_committed" "BUG-1" "critical"
  _append_finding_event "$RUN_DIR" "fix_committed" "BUG-2" "high"
  _append_finding_event "$RUN_DIR" "quarantine"    "BUG-3" "medium"
  _append_finding_event "$RUN_DIR" "confirmed"     "BUG-4" "low"

  local rollup="${BATS_TMP}/rollup.log"
  BUGSWEEP_ROLLUP_FILE="$rollup" run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  [ -f "$rollup" ]
  local repo_name
  repo_name="$(basename "$REPO")"
  local expected="20991231T000000Z ${repo_name} bugsweep/20991231T000000Z - confirmed 1/1/1/1 - fixed 2 quarantined 1 - coverage 5/5 - complete - ACTION: land (${RUN_DIR}/report.md)"
  local actual
  actual="$(cat "$rollup")"
  [ "$actual" = "$expected" ]
}

@test "finalize: rollup ACTION is 'review' when nothing was fixed but something was confirmed/quarantined" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 5 5
  _make_real_report "$RUN_DIR"
  _append_finding_event "$RUN_DIR" "quarantine" "BUG-1" "medium"

  local rollup="${BATS_TMP}/rollup.log"
  BUGSWEEP_ROLLUP_FILE="$rollup" run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  grep -q -- '- ACTION: review (' "$rollup"
}

@test "finalize: rollup ACTION is 'discard' and stop_reason falls back to status when nothing was found" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 5 5
  _make_real_report "$RUN_DIR"

  local rollup="${BATS_TMP}/rollup.log"
  BUGSWEEP_ROLLUP_FILE="$rollup" run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local repo_name
  repo_name="$(basename "$REPO")"
  local expected="20991231T000000Z ${repo_name} bugsweep/20991231T000000Z - confirmed 0/0/0/0 - fixed 0 quarantined 0 - coverage 5/5 - complete - ACTION: discard (${RUN_DIR}/report.md)"
  local actual
  actual="$(cat "$rollup")"
  [ "$actual" = "$expected" ]
}

@test "finalize: rollup digest line is NOT duplicated on re-finalize (idempotent per RUN_DIR)" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 5 5
  _make_real_report "$RUN_DIR"
  _append_finding_event "$RUN_DIR" "fix_committed" "BUG-1" "critical"

  local rollup="${BATS_TMP}/rollup.log"
  BUGSWEEP_ROLLUP_FILE="$rollup" run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  BUGSWEEP_ROLLUP_FILE="$rollup" run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local lines
  lines="$(wc -l < "$rollup" | tr -d ' ')"
  [ "$lines" -eq 1 ]
}

@test "finalize: BUGSWEEP_ROLLUP_FILE unset is a complete no-op (no file created, no error)" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 5 5
  _make_real_report "$RUN_DIR"

  local rollup="${BATS_TMP}/rollup-should-not-exist.log"
  unset BUGSWEEP_ROLLUP_FILE || true

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  [ ! -f "$rollup" ]
  [ ! -f "${RUN_DIR}/.rollup-appended" ]
}

@test "finalize: rollup digest works on the bare-machine (no jq, no python3) grep/awk fallback tier" {
  # Regression test: the Tier-3 grep fallback previously aborted finalize.sh
  # entirely (under this script's `set -euo pipefail`) whenever a field was
  # legitimately absent — e.g. stop_reason is JSON null (not a string) on
  # every "complete" run, so `grep -o '"stop_reason":..."[^"]*"'` finds no
  # match, exits non-zero, and pipefail propagated that failure through the
  # rest of the pipe even though `head`/`sed` themselves succeeded. Forces
  # BOTH jq and python3 out of PATH (have_python() is separately gated by
  # BUGSWEEP_NO_PYTHON) to exercise the real grep/awk-only code path end to
  # end, and asserts finalize.sh still exits 0 and appends a well-formed line.
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 5 5
  _make_real_report "$RUN_DIR"

  local fakebin="${BATS_TMP}/fakebin"
  mkdir -p "$fakebin"
  for tool in bash git grep sed awk cat mkdir date tr wc head cut basename dirname mktemp rm cp mv find true false printf test env sh; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "${fakebin}/${tool}"
  done

  local rollup="${BATS_TMP}/rollup.log"
  PATH="$fakebin" BUGSWEEP_NO_PYTHON=1 BUGSWEEP_ROLLUP_FILE="$rollup" run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  [ -f "$rollup" ]
  local repo_name
  repo_name="$(basename "$REPO")"
  # summarize.sh ALSO degrades under BUGSWEEP_NO_PYTHON=1 (it has no jq tier
  # of its own), so run-summary.json comes out as the minimal degraded shape
  # (counts/fixed/quarantined/confirmed_unfixed all zero/empty) — this test
  # asserts the grep/awk tier reads that real degraded shape correctly
  # (notably: an EMPTY array must count as 0, not 1 — the original bug
  # miscounted the JSON key name itself as an array element).
  local expected="20991231T000000Z ${repo_name} bugsweep/20991231T000000Z - confirmed 0/0/0/0 - fixed 0 quarantined 0 - coverage 5/5 - complete - ACTION: discard (${RUN_DIR}/report.md)"
  local actual
  actual="$(cat "$rollup")"
  [ "$actual" = "$expected" ]
}

@test "finalize: a failing rollup digest NEVER strands the user on the bugsweep branch (trust contract)" {
  # ROBUSTNESS BLOCKER regression (bugsweep-6w8 review): the rollup digest is a
  # cosmetic, default-OFF operator convenience. It must be structurally
  # incapable of aborting finalize.sh before the trust-critical teardown
  # (branch-restore + stash-pop) runs — otherwise a failure inside it strands
  # the user on the throwaway bugsweep branch with their stash unpopped.
  #
  # Reproduction of a real failure mode: an unreadable run-summary.json (a
  # permission change, or a TOCTOU vanish after the digest's own existence
  # check) combined with the no-jq/no-python3 grep tier, where the array-length
  # helper's `awk` errors (EACCES) with a NON-ZERO exit. Before the fix, that
  # non-zero propagated through a bare (non-`local`) command-substitution
  # assignment under `set -euo pipefail`, aborting the WHOLE script at a call
  # site placed BEFORE the branch-restore — leaving the user on the bugsweep
  # branch. After the fix (internal `|| var=0` guards + an isolated
  # `_write_rollup_digest || log` call moved to the very tail, after teardown),
  # finalize must ALWAYS return the user to their original branch and exit 0.
  if [ "$(id -u)" -eq 0 ]; then
    skip "runs as root: chmod 000 does not deny the owner, so the failure cannot be provoked"
  fi

  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 5 5
  _make_real_report "$RUN_DIR"

  # Pre-place an UNREADABLE run-summary.json. summarize.sh (also degraded under
  # BUGSWEEP_NO_PYTHON=1) cannot open-for-write a mode-000 file it owns, so it
  # fails and leaves this unreadable file in place — exactly the state the
  # digest then trips over when its grep-tier awk tries to read it.
  printf '{"counts":{"critical":0,"high":0,"medium":0,"low":0},"fixed":[],"quarantined":[],"confirmed_unfixed":[],"coverage":{"covered":5,"total":5},"status":"complete","stop_reason":null}\n' \
    > "${RUN_DIR}/run-summary.json"
  chmod 000 "${RUN_DIR}/run-summary.json"

  # Confirm the run really starts ON the bugsweep branch, so a pre-restore abort
  # would be observable as "still on bugsweep branch" afterward.
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = "bugsweep/20991231T000000Z" ]

  # Force the grep/awk tier: no jq, no python3.
  local fakebin="${BATS_TMP}/fakebin"
  mkdir -p "$fakebin"
  for tool in bash git grep sed awk cat mkdir date tr wc head cut basename dirname mktemp rm cp mv find true false printf test env sh; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "${fakebin}/${tool}"
  done

  local rollup="${BATS_TMP}/rollup.log"
  PATH="$fakebin" BUGSWEEP_NO_PYTHON=1 BUGSWEEP_ROLLUP_FILE="$rollup" run bash "$FINALIZE_SH" "$RUN_DIR"

  # Trust contract, in priority order:
  #   1. finalize exits 0 (the digest failure was swallowed, not propagated).
  #   2. the user is back on their ORIGINAL branch (teardown ran).
  #   3. the machine-readable FINALIZED marker was emitted (the script reached
  #      its normal end, it did not abort mid-way).
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = "$ORIG_BRANCH" ]
  echo "$output" | grep -q "FINALIZED"
}
