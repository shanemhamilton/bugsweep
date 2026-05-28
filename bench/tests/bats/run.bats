#!/usr/bin/env bats
#
# Tier-A faked end-to-end test for run.sh — the orchestrator that ties the
# committed pieces (validate_case → sandbox → runner → scrub → scorer →
# leaderboard) into a single run, WITHOUT a live container or a real model API.
#
# How the fake end-to-end is constructed (all on the host, no network):
#   - a stub `claude` on PATH emits a canned structured-line detect-only report
#     whose file:line matches the case ground truth (so the gate passes),
#   - the case target is a tmp LOCAL BARE git repo (sandbox.sh clones from it),
#   - BENCH_NO_CONTAINER=1 runs the arm directly (TEST-ONLY container bypass),
#   - BENCH_NO_JUDGE=1 treats every gate-pass as a judge match (TEST-ONLY judge
#     bypass; the live judge needs a model API, out of Tier-A scope),
#   - k=1.
# The test asserts run.sh produces results/<ts>/leaderboard.md carrying the
# 3-col per-case table, the provenance block, and — per the design, the
# most-attacked outputs — the contamination (post/pre-cutoff) split and the
# majority aggregation label.

load helpers

# Derive bench/ from the helper-exported BENCH_LIB_DIR (bench/lib) — the same
# pattern runner.bats uses, robust to how bats sources the test file.
RUN_SH="$(dirname "${BENCH_LIB_DIR}")/run.sh"

# A structured detect-only line whose file matches the case ground truth and
# whose line falls inside the ground-truth hunk so the file-overlap gate passes.
STRUCTURED_LINE='- BUG-001 · critical · sql-injection · app/db/users.py:88 · user-controlled `email` interpolated into raw SQL'

setup() {
  BATS_TMP="$(mktemp -d)"
  export BATS_TMP

  # Keep sandbox.sh's mirror cache out of the user's $HOME.
  export BENCH_MIRROR_DIR="${BATS_TMP}/mirrors"

  # The case target: a real repo containing the "vulnerable" file, committed so
  # there is a stable pre-fix SHA, then mirrored into a BARE repo sandbox.sh
  # clones from. (sandbox.sh clones from a local mirror; we point its repo at a
  # local path so no network is touched.)
  SRC="${BATS_TMP}/src"
  _make_source_repo "$SRC"
  PRE_FIX_SHA="$(git -C "$SRC" rev-parse HEAD)"
  export SRC PRE_FIX_SHA

  CASES_DIR="${BATS_TMP}/cases"
  mkdir -p "$CASES_DIR"
  _write_case "${CASES_DIR}/case-post.json" "$SRC" "$PRE_FIX_SHA" "2099-01-01"
  export CASES_DIR

  RESULTS_ROOT="${BATS_TMP}/results"
  export RESULTS_ROOT

  # The canned report fixture the stub claude drops into the workdir.
  REPORT_FIXTURE="${BATS_TMP}/report-fixture.md"
  _write_report_fixture "$REPORT_FIXTURE"
  export REPORT_FIXTURE
}

teardown() {
  [[ -n "${BATS_TMP:-}" && -d "$BATS_TMP" ]] && rm -rf "$BATS_TMP"
}

# --- fixtures --------------------------------------------------------------

_make_source_repo() {
  local dir="$1"
  mkdir -p "$dir/app/db"
  git init -q "$dir"
  git -C "$dir" config user.email bench@example.com
  git -C "$dir" config user.name bench
  git -C "$dir" config commit.gpgsign false
  # ~90 lines so line 88 exists; the bug sits around there.
  local i
  : >"$dir/app/db/users.py"
  for i in $(seq 1 90); do
    printf 'line_%s = %s\n' "$i" "$i" >>"$dir/app/db/users.py"
  done
  printf 'README\n' >"$dir/README.md"
  git -C "$dir" add app/db/users.py README.md
  git -C "$dir" commit -q -m "seed vulnerable repo"
}

# A full, schema-required case JSON (validate_case.sh checks every field). The
# ground-truth file + hunk make the canned report's app/db/users.py:88 pass the
# file-overlap gate.
_write_case() {
  local file="$1" repo="$2" sha="$3" disclosure="$4"
  cat >"$file" <<EOF
{
  "id": "py-sec-demo-001",
  "language": "python",
  "category": "security",
  "source": {
    "repo": "${repo}",
    "pre_fix_commit": "${sha}",
    "fix_commit": "${sha}",
    "advisory_url": "https://example.test/advisory",
    "disclosure_date": "${disclosure}"
  },
  "ground_truth": {
    "hunks": [ { "file": "app/db/users.py", "start": 80, "end": 95 } ],
    "files": ["app/db/users.py"],
    "description": "raw SQL interpolation of user email in users.py",
    "fix_summary": "use a parameterized query"
  },
  "size_ceiling": { "max_files": 100000, "max_loc": 10000000 },
  "cross_file": false
}
EOF
}

_write_report_fixture() {
  local file="$1"
  cat >"$file" <<EOF
# bugsweep report — 2026-05-28T09:30:00Z
**Branch:** bugsweep/2026-05-28T09:30:00Z   **Mode:** detect-only   **Iterations:** 1

## Confirmed but not fixed (detect-only or below severity floor)
${STRUCTURED_LINE}
EOF
}

# Stub claude for the bugsweep arm: writes the report under the CWD's
# .bugsweep/run-<ts>/report.md (matching the real skill's RUN_DIR layout, which
# runner.sh's clean-tree assertion whitelists) and makes no other change.
_install_fake_claude() {
  local bindir="${BATS_TMP}/fakebin"
  mkdir -p "$bindir"
  cat >"$bindir/claude" <<'STUB'
#!/usr/bin/env bash
run_dir=".bugsweep/run-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run_dir"
cp "$FAKE_CLAUDE_REPORT_FIXTURE" "$run_dir/report.md"
echo "RESULT=PROCEED"  # skill-ish noise that must NOT leak as a terminal line
exit 0
STUB
  chmod +x "$bindir/claude"
  echo "$bindir"
}

# Run run.sh with the fake claude on PATH and both test-only bypasses set.
_run_orchestrator() {
  local bindir; bindir="$(_install_fake_claude)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" \
  PATH="${bindir}:$PATH" \
  BENCH_NO_CONTAINER=1 \
  BENCH_NO_JUDGE=1 \
  BENCH_RESULTS_DIR="$RESULTS_ROOT" \
    run "$RUN_SH" --cases "$CASES_DIR" -k 1 --results-root "$RESULTS_ROOT"
}

# Echo the single leaderboard.md path produced under the results root.
_leaderboard_path() {
  find "$RESULTS_ROOT" -type f -name leaderboard.md 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# usage / arg handling
# ---------------------------------------------------------------------------

@test "run.sh usage error when no args given" {
  run "$RUN_SH"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# faked end-to-end → leaderboard.md
# ---------------------------------------------------------------------------

@test "run.sh faked end-to-end produces a results/<ts>/leaderboard.md" {
  _run_orchestrator
  [ "$status" -eq 0 ]
  local lb; lb="$(_leaderboard_path)"
  [ -n "$lb" ]
  [ -f "$lb" ]
}

@test "leaderboard.md carries the 3-column per-case table" {
  _run_orchestrator
  [ "$status" -eq 0 ]
  local lb; lb="$(_leaderboard_path)"
  run cat "$lb"
  assert_contains "$output" "| case | bugsweep | baseline | ground-truth |"
  # The case id appears in a table row.
  assert_contains "$output" "py-sec-demo-001"
}

@test "leaderboard.md carries the provenance block with enumerated fields" {
  _run_orchestrator
  [ "$status" -eq 0 ]
  local lb; lb="$(_leaderboard_path)"
  run cat "$lb"
  assert_contains "$output" "## Provenance"
  assert_contains "$output" "runner_model_id"
  assert_contains "$output" "runner_cutoff_date"
  assert_contains "$output" "judge_model_id"
  assert_contains "$output" "judge_prompt_hash"
  assert_contains "$output" "bugsweep_commit"
  assert_contains "$output" "case_verified_shas"
  assert_contains "$output" "container_image_digest"
  assert_contains "$output" "egress_proxy_image"
  assert_contains "$output" "line_window"
}

@test "leaderboard.md headline is labeled 'bugsweep @ <commit>', not v0.1.0" {
  _run_orchestrator
  [ "$status" -eq 0 ]
  local lb; lb="$(_leaderboard_path)"
  run cat "$lb"
  assert_contains "$output" "bugsweep @ "
  refute_contains "$output" "v0.1.0"
}

@test "leaderboard.md shows the contamination split and majority aggregation" {
  _run_orchestrator
  [ "$status" -eq 0 ]
  local lb; lb="$(_leaderboard_path)"
  run cat "$lb"
  # The two most-attacked outputs per the design: the post/pre-cutoff split and
  # the majority aggregation.
  assert_contains "$output" "Contamination split"
  assert_contains "$output" "Post-cutoff"
  assert_contains "$output" "Pre-cutoff"
  assert_contains "$output" "majority"
}

@test "leaderboard.md credits a DETECTED bugsweep verdict for the matching case" {
  _run_orchestrator
  [ "$status" -eq 0 ]
  local lb; lb="$(_leaderboard_path)"
  run cat "$lb"
  # The stub report's app/db/users.py:88 overlaps the ground-truth file, so with
  # the judge bypass the bugsweep arm detects this case. Assert on the
  # pipe-delimited bugsweep cell `| DETECTED |` — NOT a bare "DETECTED", which
  # `| NOT_DETECTED |` would also contain as a substring.
  local row; row="$(grep 'py-sec-demo-001' "$lb" | grep '|')"
  assert_contains "$row" "| DETECTED |"
}
