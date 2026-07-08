#!/usr/bin/env bats
#
# Tests for isolated flaky-reruns in scripts/run_checks.sh (bugsweep-7hw).
#
# Follow-up to bugsweep-ml7: ml7's flaky reruns share the working tree/
# environment with the initial run, so a test that fails on a clean first run
# then leaves a marker/cache making all reruns pass (monotonic state-
# pollution) is misclassified FLAKY -- a bad fix could then land. This suite
# proves the fix: when verify runs inside a `preflight.sh --worktree`-created,
# bugsweep-controlled, disposable linked worktree (the ISOLATION-ACTIVATION
# SIGNAL is state.env's BUGSWEEP_WORKTREE, written by preflight.sh -- see
# preflight.sh:198 and :225), each flaky rerun gets a clean slate: tracked
# files the TEST mutated are restored to a pre-run snapshot, and untracked
# files the TEST created are removed -- so a monotonic pollution marker can no
# longer manufacture a false majority-pass, and the check correctly stays a
# REGRESSION. Outside an unambiguous worktree signal, behavior is byte-
# identical to the pre-bugsweep-7hw script (documented shared-environment
# residual persists honestly rather than risking an unsafe reset).

PREFLIGHT_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/preflight.sh"
RUN_CHECKS_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/run_checks.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  git -C "$dir" checkout -q -b dev
  printf 'base\n' > "${dir}/app.txt"
  git -C "$dir" add app.txt
  git -C "$dir" commit -m "init" -q
}

# Content hash of a tree's tracked+untracked files (excluding .git and
# .bugsweep/), same idiom as tests/bats/preflight-worktree.bats's _tree_hash.
_tree_hash() {
  local dir="$1"
  ( cd "$dir" && \
    find . -path ./.git -prune -o -path ./.bugsweep -prune -o -type f -print0 2>/dev/null \
      | sort -z \
      | xargs -0 shasum 2>/dev/null \
      | shasum | awk '{print $1}' )
}

_file_hash() {
  shasum "$1" 2>/dev/null | awk '{print $1}'
}

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  CFGSRC="${BATS_TMP}/cfgsrc"
  mkdir -p "$CFGSRC"
  _make_git_repo "$REPO"
  cd "$REPO"
}

teardown() {
  cd "$START_CWD"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  rm -rf "$BATS_TMP"
}

# A minimal bugsweep.config.json override, same shape as run-checks-flaky.bats.
_write_config() {
  local test_cmd="$1" flaky_reruns="${2:-3}" lint_cmd="${3:-}"
  cat > "${CFGSRC}/bugsweep.config.json" <<JSON
{
  "commands": { "test": "${test_cmd}", "build": "", "typecheck": "", "lint": "${lint_cmd}" },
  "verify": { "flaky_reruns": ${flaky_reruns} }
}
JSON
}

# Stage a scripts/ tree of per-file symlinks to the REAL scripts (so writes
# under STAGE never touch the real repo) whose config resolves to $CFGSRC,
# exactly mirroring run-checks-flaky.bats's own staging idiom.
_stage_scripts_with_config() {
  local real_scripts real_root f
  real_scripts="$(cd "$(dirname "$RUN_CHECKS_SH")" && pwd)"
  real_root="$(cd "${real_scripts}/.." && pwd)"
  STAGE="${BATS_TMP}/stage"
  mkdir -p "${STAGE}/scripts"
  for f in "$real_scripts"/*; do
    ln -s "$f" "${STAGE}/scripts/$(basename "$f")"
  done
  ln -s "$real_root/references" "${STAGE}/references" 2>/dev/null || true
  cp -R "$CFGSRC" "${STAGE}/config"
  STAGED_RUN_CHECKS="${STAGE}/scripts/run_checks.sh"
}

_sync_config() {
  cp "${CFGSRC}/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"
}

# Deterministic pass/fail-by-invocation-count stub (same idiom as
# run-checks-flaky.bats's _write_seq_stub): $1 stub path, $2 space-separated
# 0(pass)/1(fail) sequence (last value repeats once exhausted), $3 failing
# test id line. The counter file lives BESIDE the stub script -- callers that
# want "not worktree-state-dependent" flakiness should put the stub (and thus
# its counter) OUTSIDE the isolated worktree.
_write_seq_stub() {
  local path="$1" seq="$2" idline="${3:-FAILED tests/test_seq.py::test_seq}"
  local counter="${path}.counter"
  : > "$counter"
  cat > "$path" <<SH
#!/usr/bin/env bash
seq=(${seq})
n=\$(wc -l < "${counter}" | tr -d ' ')
printf 'x\n' >> "${counter}"
idx=\$n
last=\$(( \${#seq[@]} - 1 ))
[ "\$idx" -gt "\$last" ] && idx=\$last
code=\${seq[\$idx]}
if [ "\$code" -ne 0 ]; then
  echo "${idline}"
  exit 1
fi
echo "1 passed"
exit 0
SH
  chmod +x "$path"
}

# A monotonic state-pollution fixture: FAILS while its worktree-local marker
# is absent (and creates it), PASSES once the marker exists. This is the
# ml7/7hw attack shape -- a broken fix whose first run fails but leaves
# disposable state that makes every later run pass.
_write_pollution_stub() {
  local path="$1" marker="${2:-.pollution-marker}" idline="${3:-FAILED tests/test_pollute.py::test_state_pollution}"
  cat > "$path" <<SH
#!/usr/bin/env bash
marker="${marker}"
if [ -f "\$marker" ]; then
  echo "1 passed"
  exit 0
fi
touch "\$marker"
echo "${idline}"
exit 1
SH
  chmod +x "$path"
}

_write_state_env() {
  local run_dir="$1" worktree_val="$2"
  mkdir -p "$run_dir"
  cat > "${run_dir}/state.env" <<EOF
BUGSWEEP_TS=00000000-000000
BUGSWEEP_RUN_DIR=${run_dir}
BUGSWEEP_BRANCH=bugsweep/test
BUGSWEEP_ORIG_BRANCH=dev
BUGSWEEP_ORIG_HEAD=0000000000000000000000000000000000000000
BUGSWEEP_STASH_REF=none
BUGSWEEP_START_EPOCH=0
BUGSWEEP_DEADLINE_EPOCH=0
BUGSWEEP_MAX_RUNTIME_MINUTES=120
BUGSWEEP_MODE=detect
BUGSWEEP_WORKTREE=${worktree_val}
EOF
}

# ---------------------------------------------------------------------------
# 1. State-pollution fixture, isolation ACTIVE (real preflight.sh --worktree)
#    -> must classify REGRESSION, never FLAKY.
# ---------------------------------------------------------------------------

@test "verify (isolated worktree): monotonic state-pollution failure stays REGRESSION, not FLAKY" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"
  [ -n "$run_dir" ]
  [ -n "$worktree" ]

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "BASELINE_OVERALL=0"

  _write_pollution_stub "${BATS_TMP}/pollute.sh"
  _write_config "bash '${BATS_TMP}/pollute.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
  [ ! -f "${run_dir}/flaky.jsonl" ]
  ! grep -q '"event":"flaky_test"' "${run_dir}/ledger.jsonl" 2>/dev/null

  # Every rerun must show as a genuine failure in its own log -- proving the
  # marker was actually reset before each one, not coincidentally absent.
  for n in 1 2 3; do
    grep -q "FAILED" "${run_dir}/verify-test-rerun-${n}.log"
  done
}

# ---------------------------------------------------------------------------
# 2. Safety: a pre-existing untracked file and a tracked file's committed
#    content must survive reruns byte-for-byte.
# ---------------------------------------------------------------------------

@test "verify (isolated worktree): pre-existing untracked file and tracked file survive reruns byte-for-byte" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"

  # A file that existed in the worktree BEFORE this verify run started.
  printf 'pre-existing scratch content\n' > "${worktree}/scratch.txt"
  local pre_hash tracked_hash
  pre_hash="$(_file_hash "${worktree}/scratch.txt")"
  tracked_hash="$(_file_hash "${worktree}/app.txt")"

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  # Fixture: every invocation pollutes the TRACKED file app.txt AND creates an
  # untracked marker; fails until the marker exists.
  cat > "${BATS_TMP}/pollute2.sh" <<SH
#!/usr/bin/env bash
echo "polluted" >> "${worktree}/app.txt"
marker=".pollution-marker-2"
if [ -f "\$marker" ]; then
  echo "1 passed"
  exit 0
fi
touch "\$marker"
echo "FAILED tests/test_pollute2.py::test_state_pollution_2"
exit 1
SH
  chmod +x "${BATS_TMP}/pollute2.sh"
  _write_config "bash '${BATS_TMP}/pollute2.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"

  # The pre-existing untracked file is byte-for-byte unchanged.
  [ "$(_file_hash "${worktree}/scratch.txt")" = "$pre_hash" ]
  # The tracked file's pre-run (committed) content is restored -- even the
  # LAST rerun's pollution must have been cleaned up.
  [ "$(_file_hash "${worktree}/app.txt")" = "$tracked_hash" ]
  # The NEW untracked marker created during this run is gone (final cleanup),
  # while the pre-existing scratch file remains.
  [ ! -f "${worktree}/.pollution-marker-2" ]
  [ -f "${worktree}/scratch.txt" ]
}

@test "verify (isolated worktree): the user's main tree is untouched by isolation resets" {
  printf 'user work\n' > "${REPO}/user-file.txt"
  local before_hash
  before_hash="$(_tree_hash "$REPO")"
  local before_status
  before_status="$(git -C "$REPO" status --porcelain)"

  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  _write_pollution_stub "${BATS_TMP}/pollute.sh"
  _write_config "bash '${BATS_TMP}/pollute.sh'" 3
  _sync_config
  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 1 ]

  [ "$(_tree_hash "$REPO")" = "$before_hash" ]
  [ "$(git -C "$REPO" status --porcelain)" = "$before_status" ]
}

# ---------------------------------------------------------------------------
# 3. Fallback: NOT isolated -> unchanged shared-environment (pre-7hw) behavior.
# ---------------------------------------------------------------------------

@test "verify (no state.env at all): monotonic state-pollution is STILL misclassified FLAKY (old behavior unchanged)" {
  local project="${BATS_TMP}/plain-project"
  local run_dir="${BATS_TMP}/plain-rundir"
  mkdir -p "$project" "$run_dir"
  cd "$project"

  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  _write_pollution_stub "${project}/pollute.sh"
  _write_config "bash '${project}/pollute.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  # OLD (documented, pre-7hw) behavior: the marker persists across shared-
  # environment reruns, so every rerun passes -> misclassified FLAKY, OK.
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK$"
  echo "$output" | grep -q "^FLAKY=1$"
  [ -f "${run_dir}/flaky.jsonl" ]
}

@test "verify (state.env present, BUGSWEEP_WORKTREE empty / default preflight mode): fallback unchanged" {
  local project="${BATS_TMP}/plain-project2"
  local run_dir="${BATS_TMP}/plain-rundir2"
  mkdir -p "$project"
  _write_state_env "$run_dir" ""
  cd "$project"

  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  _write_pollution_stub "${project}/pollute.sh"
  _write_config "bash '${project}/pollute.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^FLAKY=1$"
}

@test "verify (BUGSWEEP_WORKTREE points at a non-worktree directory): ambiguous signal -> fail closed, fallback unchanged" {
  local project="${BATS_TMP}/plain-project3"
  local run_dir="${BATS_TMP}/plain-rundir3"
  local bogus="${BATS_TMP}/not-a-worktree"
  mkdir -p "$project" "$bogus"
  _write_state_env "$run_dir" "$bogus"
  cd "$project"

  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  _write_pollution_stub "${project}/pollute.sh"
  _write_config "bash '${project}/pollute.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^FLAKY=1$"
}

@test "verify (BUGSWEEP_WORKTREE points at the main repo root itself): tampered/ambiguous -> fail closed" {
  local run_dir="${BATS_TMP}/plain-rundir4"
  _write_state_env "$run_dir" "$REPO"
  cd "$REPO"

  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  _write_pollution_stub "${BATS_TMP}/pollute.sh"
  _write_config "bash '${BATS_TMP}/pollute.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^FLAKY=1$"
  # And, since isolation never engaged, nothing was reset in $REPO itself.
  [ -f "${REPO}/.pollution-marker" ]
}

# ---------------------------------------------------------------------------
# 4. Genuine flakiness (nondeterministic, NOT worktree-state-dependent) must
#    still classify FLAKY under isolation.
# ---------------------------------------------------------------------------

@test "verify (isolated worktree): genuinely nondeterministic test (not state-dependent) still classifies FLAKY" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  # The counter file lives OUTSIDE the worktree (under BATS_TMP), so resetting
  # the worktree's tracked/untracked state can never affect it -- this models
  # genuine flakiness, distinct from the in-worktree state-pollution shape
  # tested above.
  _write_seq_stub "${BATS_TMP}/genflaky.sh" "1 0" "FAILED tests/test_flaky.py::test_genuinely_flaky"
  _write_config "bash '${BATS_TMP}/genflaky.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK$"
  echo "$output" | grep -q "^FLAKY=1$"
  [ -f "${run_dir}/flaky.jsonl" ]
}

@test "verify (isolated worktree): deterministic failure (every rerun fails, no state dependency) still REGRESSES" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  cat > "${BATS_TMP}/always_fail.sh" <<'SH'
#!/usr/bin/env bash
echo "FAILED tests/test_foo.py::test_always_broken"
exit 1
SH
  chmod +x "${BATS_TMP}/always_fail.sh"
  _write_config "bash '${BATS_TMP}/always_fail.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
  [ ! -f "${run_dir}/flaky.jsonl" ]
}

# ---------------------------------------------------------------------------
# 5. The rerun-infra fail-safe (bugsweep-ml7's BUGSWEEP_RERUN_INJECT_FAILURE
#    hook) must still fall back to the deterministic path when isolated.
# ---------------------------------------------------------------------------

@test "verify (isolated worktree): rerun-infrastructure failure still falls back to REGRESSION" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  cat > "${BATS_TMP}/always_fail.sh" <<'SH'
#!/usr/bin/env bash
echo "FAILED tests/test_foo.py::test_broken"
exit 1
SH
  chmod +x "${BATS_TMP}/always_fail.sh"
  _write_config "bash '${BATS_TMP}/always_fail.sh'" 3
  _sync_config

  run env BUGSWEEP_RERUN_INJECT_FAILURE=1 bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
}

# ---------------------------------------------------------------------------
# 6. BLOCKER (adversarial review): C-quoted filenames must NOT defeat the
#    untracked reset. `git ls-files --others` C-QUOTES any name containing a
#    newline / backslash / double-quote (it prints the literal `"a\nb"`, not
#    the raw bytes). If the reset compares/removes the quoted literal, the
#    REAL polluting file survives every rerun -> reruns pass -> misclassified
#    FLAKY -> a bad fix LANDS, reopening the exact hole this bead closes. The
#    fix must be NUL-safe end to end (git ls-files -z + NUL-delimited compare
#    + removal of the real byte-accurate name).
# ---------------------------------------------------------------------------

@test "verify (isolated worktree): state-pollution marker whose NAME contains an embedded newline is reset -> REGRESSION (NUL-safety BLOCKER)" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"
  [ -n "$run_dir" ]
  [ -n "$worktree" ]

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  # Marker name has embedded newlines (the C-quoting trigger). The stub does
  # the ANSI-C quoting at RUNTIME (quoted heredoc keeps $'...' literal in the
  # file) so the real on-disk name really contains raw newline bytes.
  cat > "${BATS_TMP}/pollute_nl.sh" <<'SH'
#!/usr/bin/env bash
marker=$'state\npollution\nmarker.tmp'
if [ -f "$marker" ]; then
  echo "1 passed"
  exit 0
fi
: > "$marker"
echo "FAILED tests/test_pollute_nl.py::test_newline_marker"
exit 1
SH
  chmod +x "${BATS_TMP}/pollute_nl.sh"
  _write_config "bash '${BATS_TMP}/pollute_nl.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
  [ ! -f "${run_dir}/flaky.jsonl" ]
  ! grep -q '"event":"flaky_test"' "${run_dir}/ledger.jsonl" 2>/dev/null

  # The real newline-named marker must have been removed by the final reset,
  # proving the NUL-accurate name was matched -- not a C-quoted literal.
  [ -z "$(git -C "$worktree" ls-files --others --exclude-standard)" ]
}

@test "verify (isolated worktree): ordinary special names (space, leading dash, unicode) still reset -> REGRESSION" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  # Three markers with awkward-but-not-C-quoted names: a space, a leading
  # dash (which `rm` must not treat as an option -- our `rm -rf -- "$target"`
  # and "${wt}/" prefix guard against that), and a unicode name. The test
  # passes only once ALL three exist; the reset must remove all three between
  # reruns so every rerun fails.
  cat > "${BATS_TMP}/pollute_special.sh" <<'SH'
#!/usr/bin/env bash
m1="marker with space.tmp"
m2="-leading-dash.tmp"
m3="märker-ünïcode.tmp"
if [ -f "$m1" ] && [ -f "$m2" ] && [ -f "$m3" ]; then
  echo "1 passed"
  exit 0
fi
: > "$m1"; : > "$m2"; : > "$m3"
echo "FAILED tests/test_special.py::test_special_names"
exit 1
SH
  chmod +x "${BATS_TMP}/pollute_special.sh"
  _write_config "bash '${BATS_TMP}/pollute_special.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
  [ ! -f "${run_dir}/flaky.jsonl" ]
  [ -z "$(git -C "$worktree" ls-files --others --exclude-standard)" ]
}

@test "verify (isolated worktree): a PRE-EXISTING file whose name contains a newline is preserved across reruns" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"

  # A newline-named file that predates the verify pass must never be a removal
  # candidate (it is in the pre-run snapshot). This guards against the NUL-safe
  # removal over-reaching onto user-authored oddly-named files.
  local pre
  pre=$'pre\nexisting\nkeep.txt'
  ( cd "$worktree" && printf 'keep me\n' > "$pre" )
  local pre_hash
  pre_hash="$( cd "$worktree" && shasum "$pre" 2>/dev/null | awk '{print $1}' )"
  [ -n "$pre_hash" ]

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  # A DIFFERENT newline-named pollution marker (created during the run) must
  # be reset, while the pre-existing newline-named file survives.
  cat > "${BATS_TMP}/pollute_nl2.sh" <<'SH'
#!/usr/bin/env bash
marker=$'new\npollution\nmarker.tmp'
if [ -f "$marker" ]; then
  echo "1 passed"
  exit 0
fi
: > "$marker"
echo "FAILED tests/test_pollute_nl2.py::test_newline_marker_2"
exit 1
SH
  chmod +x "${BATS_TMP}/pollute_nl2.sh"
  _write_config "bash '${BATS_TMP}/pollute_nl2.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"

  # Pre-existing newline-named file untouched, byte-for-byte.
  [ "$( cd "$worktree" && shasum "$pre" 2>/dev/null | awk '{print $1}' )" = "$pre_hash" ]
}

# ---------------------------------------------------------------------------
# 7. MINOR (adversarial review): snapshot-capture failure must fail SAFE
#    (disable isolation, fall back to shared-env behavior) -- NEVER an
#    uncaught `set -euo pipefail` crash. We block the pre-run untracked
#    snapshot path by pre-creating it as a DIRECTORY (so the redirect into it
#    as a file fails), while keeping the run_dir itself writable.
# ---------------------------------------------------------------------------

@test "verify (isolated worktree): snapshot-capture failure falls back cleanly (no set -e crash)" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir worktree
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  worktree="$(echo "$output" | sed -n 's/^WORKTREE=//p')"

  cd "$worktree"
  _write_config "true" 3
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$run_dir"
  [ "$status" -eq 0 ]

  # Sabotage the untracked-snapshot capture: the path run_checks writes the
  # pre-run untracked snapshot to is now a directory, so the write fails.
  mkdir -p "${run_dir}/isolate-pre-untracked.txt"

  _write_pollution_stub "${BATS_TMP}/pollute.sh"
  _write_config "bash '${BATS_TMP}/pollute.sh'" 3
  _sync_config

  run bash "$STAGED_RUN_CHECKS" verify "$run_dir"
  # Must NOT crash: a verdict line is printed and the exit code is a clean
  # 0/1, not a raw bash abort. With isolation disabled by the fail-safe, the
  # pollution reverts to the documented shared-env misclassification (FLAKY /
  # OK) -- the point of THIS test is "no uncaught crash + clean fallback".
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK$"
  echo "$output" | grep -qi "falling back to shared-environment"
}
