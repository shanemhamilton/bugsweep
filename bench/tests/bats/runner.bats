#!/usr/bin/env bats
#
# Tier-A tests for the benchmark runner adapters:
#   - runner.sh              : dispatch by --runner, RESULT=/exit-code contract,
#                              size_ceiling SKIP enforcement
#   - claude_p.sh            : bugsweep arm (detect-only, allow_web_research=false)
#   - claude_p_baseline.sh   : baseline arm (no skill, structured-line prompt)
#
# These never reach the public network or a real `claude` CLI. A FAKE `claude`
# stub is placed on PATH (a tmp dir prepended to PATH) that emits a canned
# report containing the structured detect-only line. The scripts' LOGIC — the
# RESULT contract, the size-ceiling gate, the detect-only/no-`--fix` invocation,
# and the allow_web_research=false override+assert — is what is exercised.

load helpers

# Runner adapters are WU3 additions; define their paths here rather than
# touching the WU0 helpers.bash (which only exports lib paths).
_BENCH_RUNNERS_DIR="$(dirname "${BENCH_LIB_DIR}")/runners"
RUNNER_SH="${_BENCH_RUNNERS_DIR}/runner.sh"
CLAUDE_P_SH="${_BENCH_RUNNERS_DIR}/claude_p.sh"
CLAUDE_P_BASELINE_SH="${_BENCH_RUNNERS_DIR}/claude_p_baseline.sh"

# The structured detect-only report line every arm's captured report must use.
STRUCTURED_LINE='- BUG-001 · critical · sql-injection · app/db/users.py:88 · user-controlled `email` interpolated into raw SQL'

setup() {
  BATS_TMP="$(mktemp -d)"
  export BATS_TMP

  # A clean git workdir under size ceilings by default.
  WORKDIR="${BATS_TMP}/workdir"
  export WORKDIR
  _make_workdir "$WORKDIR"

  OUT="${BATS_TMP}/out"
  mkdir -p "$OUT"
  export OUT

  # A normal case JSON with generous size ceilings.
  CASE_JSON="${BATS_TMP}/case.json"
  _write_case "$CASE_JSON" 400 60000
  export CASE_JSON

  # A canned bugsweep report fixture the fake `claude` drops into the workdir.
  REPORT_FIXTURE="${BATS_TMP}/report-fixture.md"
  _write_report_fixture "$REPORT_FIXTURE"
  export REPORT_FIXTURE
}

teardown() {
  [[ -n "${BATS_TMP:-}" && -d "$BATS_TMP" ]] && rm -rf "$BATS_TMP"
}

# --- fixtures --------------------------------------------------------------

# Create a git working directory with 2 committed files so the tree is clean
# and HEAD is stable (the clean-tree assertion compares against this).
_make_workdir() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email bench@example.com
  git -C "$dir" config user.name bench
  git -C "$dir" config commit.gpgsign false
  printf 'one\ntwo\n' >"$dir/a.py"
  printf 'three\nfour\n' >"$dir/b.py"
  git -C "$dir" add a.py b.py
  git -C "$dir" commit -q -m "seed"
}

# Minimal case JSON carrying only the size_ceiling the runner reads.
_write_case() {
  local file="$1" max_files="$2" max_loc="$3"
  cat >"$file" <<EOF
{
  "id": "test-case-001",
  "size_ceiling": { "max_files": ${max_files}, "max_loc": ${max_loc} }
}
EOF
}

# A canned detect-only report in the SKILL.md template, including the
# structured "Confirmed but not fixed" line WU4's parser will read.
_write_report_fixture() {
  local file="$1"
  cat >"$file" <<EOF
# bugsweep report — 2026-05-28T09:30:00Z
**Branch:** bugsweep/2026-05-28T09:30:00Z   **Mode:** detect-only   **Iterations:** 1

## Confirmed but not fixed (detect-only or below severity floor)
${STRUCTURED_LINE}
EOF
}

# Install a fake `claude` executable on PATH for the bugsweep arm: it writes the
# report fixture to <workdir>/.bugsweep/run-<ts>/report.md (the RUN_DIR layout the
# real skill uses via preflight.sh) and makes no code changes. Returns the bin dir.
_install_fake_claude_bugsweep() {
  local bindir="${BATS_TMP}/fakebin"
  mkdir -p "$bindir"
  cat >"$bindir/claude" <<'STUB'
#!/usr/bin/env bash
# Fake bugsweep-arm `claude -p`: simulate the skill writing its RUN_DIR report
# under the CWD's .bugsweep/run-<ts>/ (matching scripts/preflight.sh). Emits some
# skill-like stdout (including a bugsweep RESULT= string) to prove the runner
# does NOT leak it as a terminal line.
run_dir=".bugsweep/run-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run_dir"
cp "$FAKE_CLAUDE_REPORT_FIXTURE" "$run_dir/report.md"
echo "RESULT=PROCEED"   # bugsweep-prepare-style noise that must NOT leak through
echo "fake claude: wrote $run_dir/report.md"
exit 0
STUB
  chmod +x "$bindir/claude"
  echo "$bindir"
}

# Install a fake `claude` for the baseline arm: it prints the structured report
# to STDOUT (no skill, no files), which the runner redirects to <out>/report.md.
_install_fake_claude_baseline() {
  local bindir="${BATS_TMP}/fakebin"
  mkdir -p "$bindir"
  cat >"$bindir/claude" <<'STUB'
#!/usr/bin/env bash
cat "$FAKE_CLAUDE_REPORT_FIXTURE"
exit 0
STUB
  chmod +x "$bindir/claude"
  echo "$bindir"
}

# Count RESULT= lines in a captured $output.
_count_result_lines() {
  grep -c '^RESULT=' <<<"$1"
}

# ---------------------------------------------------------------------------
# usage / dispatch
# ---------------------------------------------------------------------------

@test "runner usage error when no args given" {
  run "$RUNNER_SH"
  [ "$status" -ne 0 ]
}

@test "runner errors on an unknown --runner value" {
  run "$RUNNER_SH" --runner bogus --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 1 ]
  assert_contains "$output" "RESULT=ERROR"
}

# ---------------------------------------------------------------------------
# bugsweep arm (claude_p) — RAN path
# ---------------------------------------------------------------------------

@test "bugsweep arm: RESULT=RAN exit 0 with report captured to <out>/report.md" {
  local bindir; bindir="$(_install_fake_claude_bugsweep)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "RESULT=RAN"
  [ -f "${OUT}/report.md" ]
  run cat "${OUT}/report.md"
  assert_contains "$output" "$STRUCTURED_LINE"
}

@test "bugsweep arm: emits exactly ONE RESULT= line (no skill-output leakage)" {
  local bindir; bindir="$(_install_fake_claude_bugsweep)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  [ "$(_count_result_lines "$output")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# baseline arm (claude_p_baseline) — RAN path
# ---------------------------------------------------------------------------

@test "baseline arm: RESULT=RAN exit 0 with stdout captured to <out>/report.md" {
  local bindir; bindir="$(_install_fake_claude_baseline)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p_baseline --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "RESULT=RAN"
  [ -f "${OUT}/report.md" ]
  run cat "${OUT}/report.md"
  assert_contains "$output" "$STRUCTURED_LINE"
}

@test "baseline arm: emits exactly ONE RESULT= line" {
  local bindir; bindir="$(_install_fake_claude_baseline)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p_baseline --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  [ "$(_count_result_lines "$output")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# ERROR path — missing `claude`
# ---------------------------------------------------------------------------

@test "runner: RESULT=ERROR exit 1 when claude is absent from PATH" {
  # Build a sanitized bin dir holding symlinks to every tool the runner needs
  # EXCEPT claude, then run with PATH pointed only at it so `command -v claude`
  # fails while bash/jq/git/find/etc. still resolve.
  local cleanbin="${BATS_TMP}/cleanbin"
  mkdir -p "$cleanbin"
  local t
  for t in bash sh env jq git find xargs cat wc tr grep head sort ls mkdir dirname cp date; do
    local p; p="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$p" ] && ln -sf "$p" "$cleanbin/$t"
  done
  PATH="$cleanbin" run "$RUNNER_SH" --runner claude_p --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 1 ]
  assert_contains "$output" "RESULT=ERROR"
  [ "$(_count_result_lines "$output")" -eq 1 ]
}

@test "runner: RESULT=ERROR exit 1 when the workdir is missing" {
  local bindir; bindir="$(_install_fake_claude_bugsweep)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p --case "$CASE_JSON" --workdir "${BATS_TMP}/nope" --out "$OUT"
  [ "$status" -eq 1 ]
  assert_contains "$output" "RESULT=ERROR"
}

# ---------------------------------------------------------------------------
# SKIP path — size_ceiling exceeded
# ---------------------------------------------------------------------------

@test "runner: RESULT=SKIP exit 10 when workdir exceeds max_files" {
  # max_files=1, workdir has 2 tracked files -> exceeds.
  local tightcase="${BATS_TMP}/tight-files.json"
  _write_case "$tightcase" 1 60000
  local bindir; bindir="$(_install_fake_claude_bugsweep)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p --case "$tightcase" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 10 ]
  assert_contains "$output" "RESULT=SKIP"
  [ "$(_count_result_lines "$output")" -eq 1 ]
  # SKIP must short-circuit BEFORE invoking claude: no report captured.
  [ ! -f "${OUT}/report.md" ]
}

@test "runner: RESULT=SKIP exit 10 when workdir exceeds max_loc" {
  # max_loc=1, workdir has 4 lines across 2 files -> exceeds.
  local tightcase="${BATS_TMP}/tight-loc.json"
  _write_case "$tightcase" 400 1
  local bindir; bindir="$(_install_fake_claude_bugsweep)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p --case "$tightcase" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 10 ]
  assert_contains "$output" "RESULT=SKIP"
}

@test "runner: a workdir within ceilings does NOT skip" {
  # max_files=2, max_loc=4 exactly matches the seed workdir -> within bounds.
  local exactcase="${BATS_TMP}/exact.json"
  _write_case "$exactcase" 2 4
  local bindir; bindir="$(_install_fake_claude_bugsweep)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p --case "$exactcase" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "RESULT=RAN"
}

# ---------------------------------------------------------------------------
# --print-cmd dry path — invocation shape
# ---------------------------------------------------------------------------

@test "bugsweep arm --print-cmd shows a detect-only invocation with no --fix" {
  run "$RUNNER_SH" --print-cmd --runner claude_p --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "claude -p"
  assert_contains "$output" "detect-only"
  refute_contains "$output" "--fix"
}

@test "bugsweep arm --print-cmd shows the allow_web_research=false override" {
  run "$RUNNER_SH" --print-cmd --runner claude_p --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "allow_web_research"
  assert_contains "$output" "false"
}

@test "baseline arm --print-cmd shows the structured-line prompt and no bugsweep skill" {
  run "$RUNNER_SH" --print-cmd --runner claude_p_baseline --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "claude -p"
  assert_contains "$output" "<BUG-ID>"
  refute_contains "$output" "bugsweep"
}

@test "runner --print-cmd does not invoke claude (no report written)" {
  run "$RUNNER_SH" --print-cmd --runner claude_p --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  [ ! -f "${OUT}/report.md" ]
}

# ---------------------------------------------------------------------------
# allow_web_research=false override is materialized in the workdir config
# ---------------------------------------------------------------------------

@test "bugsweep arm writes a workdir config override forcing allow_web_research=false" {
  local bindir; bindir="$(_install_fake_claude_bugsweep)"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 0 ]
  # The per-run override lands at <workdir>/config/bugsweep.config.json.
  [ -f "${WORKDIR}/config/bugsweep.config.json" ]
  run jq -e '.research.allow_web_research == false' "${WORKDIR}/config/bugsweep.config.json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# clean-tree assertion — detect-only must not mutate tracked content
# ---------------------------------------------------------------------------

@test "bugsweep arm: RESULT=ERROR if the workdir tree is dirty after the run" {
  # A fake claude that simulates a (forbidden) source edit in detect-only mode.
  local bindir="${BATS_TMP}/dirtybin"
  mkdir -p "$bindir"
  cat >"$bindir/claude" <<'STUB'
#!/usr/bin/env bash
run_dir=".bugsweep/run-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run_dir"
cp "$FAKE_CLAUDE_REPORT_FIXTURE" "$run_dir/report.md"
echo "mutation" >>a.py   # forbidden: edits tracked source
exit 0
STUB
  chmod +x "$bindir/claude"
  FAKE_CLAUDE_REPORT_FIXTURE="$REPORT_FIXTURE" PATH="${bindir}:$PATH" \
    run "$RUNNER_SH" --runner claude_p --case "$CASE_JSON" --workdir "$WORKDIR" --out "$OUT"
  [ "$status" -eq 1 ]
  assert_contains "$output" "RESULT=ERROR"
}
