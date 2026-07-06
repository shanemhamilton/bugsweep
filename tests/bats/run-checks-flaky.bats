#!/usr/bin/env bats
#
# Tests for flaky-aware verify in scripts/run_checks.sh (bugsweep-ml7).
#
# run_checks.sh verify's ACTUAL (pre-existing) semantics, as read from the
# script: it runs each configured check ONCE, records {"check":<name>,"status":
# "pass"|"fail"} per check into checks-<phase>.json, sums fails into an
# "overall" count, and compares "overall" against the recorded baseline's
# "overall". If verify's overall > baseline's overall it prints REGRESSION and
# exits 1; otherwise it prints OK (or NO_CHECKS if no commands were detected)
# and exits 0. There is no per-test granularity anywhere in the pre-existing
# script — a "check" (test/typecheck/build/lint) is the smallest unit it can
# observe or rerun.
#
# This suite verifies the flaky-aware rerun layer added on top of that: when
# verify's "test" check newly fails vs baseline, it is rerun `.verify.flaky_reruns`
# (default 3) times. Classification is by MAJORITY of those reruns, not
# pass-once: only a STRICT majority of rerun passes (passes > failures across
# the reruns) reclassifies the check as flaky; a tie or a majority of rerun
# failures stays a REGRESSION and reverts. This raises the bar against the
# "state-pollution false-pass" attack where a broken fix's first run fails but
# leaves a marker/cache that makes subsequent (shared-environment) reruns pass.
# A flaky classification excludes the check from the pass/fail regression
# decision, is recorded to <RUN_DIR>/flaky.jsonl and appended to ledger.jsonl
# as {"event":"flaky_test","test":<id>,"file":<file-or-null>,"reruns":N,
# "failures":M}, and is loudly surfaced via a FLAKY=<n> KEY=VALUE line plus
# per-test lines — so any fix that lands with a flaky test is reviewable, never
# silent. On a clean (all-green) verify, NO FLAKY= line is emitted at all, so
# the happy-path stdout stays byte-identical to the pre-feature script.

RUN_CHECKS_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/run_checks.sh"

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  PROJECT="${BATS_TMP}/project"
  RUN_DIR="${BATS_TMP}/rundir"
  mkdir -p "$PROJECT" "$RUN_DIR"
  cd "$PROJECT"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

# A minimal bugsweep.config.json override so run_checks.sh doesn't need a
# real package.json/pytest project to resolve its "test" command — we point
# cmd_test straight at a stub script. `flaky_reruns` defaults to the value
# under test unless a test overrides it via BUGSWEEP_CONFIG env below.
_write_config() {
  local test_cmd="$1" flaky_reruns="${2:-3}" lint_cmd="${3:-}"
  mkdir -p "${PROJECT}/config"
  cat > "${PROJECT}/config/bugsweep.config.json" <<JSON
{
  "commands": { "test": "${test_cmd}", "build": "", "typecheck": "", "lint": "${lint_cmd}" },
  "verify": { "flaky_reruns": ${flaky_reruns} }
}
JSON
}

# run_checks.sh resolves its config relative to the script's own root
# (BUGSWEEP_ROOT/config/bugsweep.config.json), not the CWD project. cfg_get
# reads $BUGSWEEP_CONFIG which is derived from the script's location, so we
# stage a script tree whose ../config is our per-test config.
#
# IMPORTANT (test isolation): ${STAGE}/scripts is a REAL directory whose
# entries are individual symlinks to the real script FILES — NOT a symlink to
# the real scripts/ directory. A dir-level symlink would make any write into
# ${STAGE}/scripts/ (e.g. staging a base-revision copy) land in the real repo
# and pollute the working tree. Per-file symlinks let a test drop extra files
# into ${STAGE}/scripts/ safely, since only the symlinks (not their targets)
# live under BATS_TMP.
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
  cp -R "${PROJECT}/config" "${STAGE}/config"
  STAGED_RUN_CHECKS="${STAGE}/scripts/run_checks.sh"
}

_run_baseline() {
  bash "$STAGED_RUN_CHECKS" baseline "$RUN_DIR"
}

_run_verify() {
  bash "$STAGED_RUN_CHECKS" verify "$RUN_DIR"
}

# Write a stub "test" command that returns a deterministic pass/fail SEQUENCE
# keyed on how many times it has been invoked so far. $1 is the file path for
# the stub, $2 is a space-separated sequence of 0 (pass) / 1 (fail) exit codes;
# once the sequence is exhausted the LAST value repeats. A per-stub counter
# file tracks invocations across the initial run + all reruns. This lets a
# test express e.g. "fail, then pass every rerun" (1 0) or "fail the first run
# then fail the majority of reruns" (1 1 1 0) precisely.
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

# ---------------------------------------------------------------------------
# Criterion 1: deterministic regression still reverts (RESULT contract
# unchanged) — a test that fails EVERY time (including every rerun).
# ---------------------------------------------------------------------------

@test "verify: newly-failing deterministic test reverts (REGRESSION) after N reruns all fail" {
  # Baseline: green.
  _write_config "true" 3
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "BASELINE_OVERALL=0"

  # Verify: swap in an always-failing test command (deterministic regression).
  _write_config "bash '${PROJECT}/always_fail.sh'" 3
  cat > "${PROJECT}/always_fail.sh" <<'SH'
#!/usr/bin/env bash
echo "FAILED tests/test_foo.py::test_always_broken"
exit 1
SH
  chmod +x "${PROJECT}/always_fail.sh"
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
  # Reran up to flaky_reruns times and every one failed -> not flaky.
  [ ! -f "${RUN_DIR}/flaky.jsonl" ]
  ! grep -q '"event":"flaky_test"' "${RUN_DIR}/ledger.jsonl" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Criterion 2: a flaky test (fails then passes on rerun, via a counter-file
# trick) does NOT trigger REGRESSION, and lands in flaky.jsonl + ledger.jsonl
# with the exact event shape the run-summary reducer expects.
# ---------------------------------------------------------------------------

@test "verify: test flaky by MAJORITY of reruns does not regress and is recorded with exact event shape" {
  _write_config "true" 3
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  # Sequence: initial run fails, then passes on every rerun -> all 3 reruns
  # pass (3 pass > 0 fail = strict majority) -> flaky.
  _write_seq_stub "${PROJECT}/flaky_test.sh" "1 0" "FAILED tests/test_flaky.py::test_intermittent"
  _write_config "bash '${PROJECT}/flaky_test.sh'" 3
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK$"
  echo "$output" | grep -q "^FLAKY=1$"

  [ -f "${RUN_DIR}/flaky.jsonl" ]
  grep -q '"event":"flaky_test"' "${RUN_DIR}/flaky.jsonl"
  # All N=3 reruns were performed (majority model runs the full set, no early
  # break). Total observed failures = 1 (just the initial run; every rerun
  # passed).
  grep -q '"reruns":3' "${RUN_DIR}/flaky.jsonl"
  grep -q '"failures":1' "${RUN_DIR}/flaky.jsonl"

  # Same line appended to the run ledger.
  grep -q '"event":"flaky_test"' "${RUN_DIR}/ledger.jsonl"

  # Exact per-test line diff between flaky.jsonl and its ledger copy: identical.
  diff <(grep '"event":"flaky_test"' "${RUN_DIR}/flaky.jsonl") \
       <(grep '"event":"flaky_test"' "${RUN_DIR}/ledger.jsonl")

  # Emitted event shape is byte-exactly the reducer contract (bugsweep-xdw):
  # keys in order event,test,file,reruns,failures; string values quoted;
  # numeric values bare. This is the integration contract xdw's run_summary.py
  # reducer will consume once it lands (it does NOT consume flaky_test on THIS
  # branch — we only EMIT the shape here).
  run cat "${RUN_DIR}/flaky.jsonl"
  [ "$output" = '{"event":"flaky_test","test":"tests/test_flaky.py::test_intermittent","file":"tests/test_flaky.py","reruns":3,"failures":1}' ]

  # Structural guarantee: valid JSON, exact key ORDER, string vs int TYPES.
  run python3 -c 'import json,sys
d=json.loads(open(sys.argv[1]).read().strip())
assert list(d.keys())==["event","test","file","reruns","failures"], d
assert d["event"]=="flaky_test"
assert isinstance(d["test"],str) and isinstance(d["file"],(str,type(None)))
assert isinstance(d["reruns"],int) and isinstance(d["failures"],int)
print("SHAPE_OK")' "${RUN_DIR}/flaky.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SHAPE_OK"
}

@test "verify: BLOCKER-3 file field is emitted as bare null (unquoted) when unknown" {
  _write_config "true" 3
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  # A failing-test line WITHOUT a "path::name" shape -> no derivable file, so
  # "file" must be JSON null (the reducer contract permits null), not "" and
  # not the string "null".
  _write_seq_stub "${PROJECT}/nofile_test.sh" "1 0" "--- FAIL: TestNoFile"
  _write_config "bash '${PROJECT}/nofile_test.sh'" 3
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify
  [ "$status" -eq 0 ]
  # file is bare null, test is the extracted go id.
  grep -Fq '"file":null' "${RUN_DIR}/flaky.jsonl"
  run python3 -c 'import json,sys
d=json.loads(open(sys.argv[1]).read().strip())
assert d["file"] is None, d
assert d["test"]=="TestNoFile", d
print("NULL_OK")' "${RUN_DIR}/flaky.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "NULL_OK"
}

@test "verify: BLOCKER-1 state-pollution false-pass (majority of reruns FAIL) still REGRESSES" {
  _write_config "true" 4
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  # Attack shape: initial run fails, ONE rerun then passes (as if a marker was
  # left behind), but the majority of reruns still fail. Sequence "1 0 1 1 1"
  # with N=4 reruns -> rerun outcomes are [pass, fail, fail, fail] = 1 pass,
  # 3 fails. Pass-once would (wrongly) call this flaky and LAND a broken fix;
  # majority-of-reruns correctly keeps it a REGRESSION.
  _write_seq_stub "${PROJECT}/pollute_test.sh" "1 0 1 1 1" "FAILED tests/test_pollute.py::test_state_pollution"
  _write_config "bash '${PROJECT}/pollute_test.sh'" 4
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
  # Must NOT have been classified flaky.
  [ ! -f "${RUN_DIR}/flaky.jsonl" ]
  ! grep -q '"event":"flaky_test"' "${RUN_DIR}/ledger.jsonl" 2>/dev/null
}

@test "verify: BLOCKER-1 a rerun-tie (equal pass/fail) is NOT flaky and REGRESSES" {
  _write_config "true" 4
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  # N=4 reruns, sequence "1 0 1 0 1" -> rerun outcomes [pass, fail, pass, fail]
  # = 2 pass, 2 fail. A tie is not a STRICT majority pass -> conservative
  # (safety-first) -> REGRESSION, not flaky.
  _write_seq_stub "${PROJECT}/tie_test.sh" "1 0 1 0 1" "FAILED tests/test_tie.py::test_tie"
  _write_config "bash '${PROJECT}/tie_test.sh'" 4
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
  [ ! -f "${RUN_DIR}/flaky.jsonl" ]
}

@test "verify: flaky test reclassification does not mask a SIMULTANEOUS real lint regression" {
  # Both "test" and "lint" pass at baseline.
  _write_config "true" 3 "true"
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "BASELINE_OVERALL=0"

  # At verify time: "test" is flaky by majority (fails once, then passes every
  # rerun), AND "lint" has a genuine deterministic regression (always fails).
  # The flaky reclassification of "test" must NOT swallow the real lint
  # regression.
  _write_seq_stub "${PROJECT}/flaky_test.sh" "1 0" "FAILED tests/test_flaky.py::test_intermittent_mixed"
  cat > "${PROJECT}/always_fail_lint.sh" <<'SH'
#!/usr/bin/env bash
echo "lint: always broken"
exit 1
SH
  chmod +x "${PROJECT}/always_fail_lint.sh"
  _write_config "bash '${PROJECT}/flaky_test.sh'" 3 "bash '${PROJECT}/always_fail_lint.sh'"
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify

  # The lint regression is real and deterministic -> must still REGRESS,
  # even though "test" independently turned out to be flaky.
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
  # And "test" must still have been correctly identified as flaky and logged,
  # proving the rerun path ran and reclassified it rather than short-circuiting.
  [ -f "${RUN_DIR}/flaky.jsonl" ]
  grep -q '"event":"flaky_test"' "${RUN_DIR}/flaky.jsonl"
}

@test "verify: flaky test surfaces stable FLAKY=<n> and a per-test FLAKY_TEST= line" {
  _write_config "true" 3
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  # Majority-pass flaky (1 fail then pass every rerun).
  _write_seq_stub "${PROJECT}/flaky_test.sh" "1 0" "FAILED tests/test_flaky.py::test_intermittent_two"
  _write_config "bash '${PROJECT}/flaky_test.sh'" 3
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^FLAKY=1$"
  # The per-test line carries the full id verbatim.
  echo "$output" | grep -q "^FLAKY_TEST=tests/test_flaky.py::test_intermittent_two$"
}

@test "verify: MAJOR-4 FLAKY_TEST= line preserves a parametrized id containing commas/brackets" {
  _write_config "true" 3
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  # A pytest parametrized id: "path::test_name[a,b,c]" — the OLD [^,"]* regex
  # truncated this at the first comma. The FLAKY_TEST= line must carry the
  # WHOLE id, and it must match the id written to the durable JSONL exactly.
  local pid='tests/test_p.py::test_param[a,b,c]'
  _write_seq_stub "${PROJECT}/param_test.sh" "1 0" "FAILED ${pid}"
  _write_config "bash '${PROJECT}/param_test.sh'" 3
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^FLAKY=1$"
  echo "$output" | grep -Fq "FLAKY_TEST=${pid}"
  # And the JSONL "test" field carries the same full id.
  grep -Fq "\"test\":\"${pid}\"" "${RUN_DIR}/flaky.jsonl"
}

@test "verify: MAJOR-5 clean all-green verify emits NO FLAKY= line (byte-identical to pre-feature stdout)" {
  # Baseline green, verify green — the pre-feature script printed exactly "OK"
  # on STDOUT for this path (progress logs go to stderr via log()). The feature
  # must not add a FLAKY= line here. Capture stdout ONLY (stderr discarded) and
  # assert it is byte-exactly "OK\n".
  _write_config "true" 3
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  local out
  out="$(bash "$STAGED_RUN_CHECKS" verify "$RUN_DIR" 2>/dev/null)"
  [ "$out" = "OK" ]
  ! printf '%s\n' "$out" | grep -q "FLAKY"

  # Byte-for-byte against the real PRE-FEATURE script's stdout on the identical
  # inputs — the strongest form of "matches main exactly". Resolve the last
  # revision of scripts/run_checks.sh that predates this feature by finding the
  # newest ancestor commit whose copy does NOT contain the FLAKY= marker (so
  # this stays correct across REVISE retries that add more commits on top). Fall
  # back to main, then to the documented branch-point e1f783f.
  local repo base_rev base_script="${BATS_TMP}/run_checks_base.sh"
  repo="$(cd "$(dirname "$RUN_CHECKS_SH")/.." && pwd)"
  base_rev=""
  local rev
  for rev in $(git -C "$repo" log --format='%H' -- scripts/run_checks.sh 2>/dev/null); do
    if ! git -C "$repo" show "${rev}:scripts/run_checks.sh" 2>/dev/null | grep -q 'FLAKY='; then
      base_rev="$rev"; break
    fi
  done
  [ -n "$base_rev" ] || base_rev="main"
  git -C "$repo" show "${base_rev}:scripts/run_checks.sh" > "$base_script" 2>/dev/null \
    || git -C "$repo" show "e1f783f:scripts/run_checks.sh" > "$base_script" 2>/dev/null \
    || skip "no pre-feature base revision available to diff stdout against"
  # Assert we really got a pre-feature script (defence against a bad match).
  ! grep -q 'FLAKY=' "$base_script"
  # Stage the base script next to the shared common.sh/config so it resolves.
  # (${STAGE}/scripts is a real dir of per-file symlinks — writing here is
  # isolated to BATS_TMP and does NOT touch the real repo.)
  cp "$base_script" "${STAGE}/scripts/run_checks_base.sh"
  local base_run="${BATS_TMP}/rundir_base"
  mkdir -p "$base_run"
  bash "${STAGE}/scripts/run_checks_base.sh" baseline "$base_run" >/dev/null 2>&1
  local base_out
  base_out="$(bash "${STAGE}/scripts/run_checks_base.sh" verify "$base_run" 2>/dev/null)"
  [ "$out" = "$base_out" ]
}

# ---------------------------------------------------------------------------
# Criterion 4: rerun-infrastructure failure -> fall back to OLD behavior
# (treat as deterministic -> revert). We simulate infra failure by making the
# rerun mechanism itself error: an unreadable/corrupt run_dir path for the
# rerun bookkeeping file forces the fallback branch.
# ---------------------------------------------------------------------------

@test "verify: rerun-infrastructure failure falls back to old behavior (REGRESSION)" {
  _write_config "true" 3
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  cat > "${PROJECT}/always_fail.sh" <<'SH'
#!/usr/bin/env bash
echo "FAILED tests/test_foo.py::test_broken"
exit 1
SH
  chmod +x "${PROJECT}/always_fail.sh"
  _write_config "bash '${PROJECT}/always_fail.sh'" 3
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  # Sabotage the rerun infrastructure itself via the same kind of explicit
  # test-only escape hatch common.sh already uses for BUGSWEEP_NO_PYTHON=1:
  # BUGSWEEP_RERUN_INJECT_FAILURE=1 forces the rerun dispatch to error out
  # (simulating e.g. an exec failure launching the rerun), independent of
  # whether the newly-failing check is itself flaky. The fail-safe must fall
  # back to the OLD behavior (treat as deterministic -> revert), never a
  # false green from a broken rerun path.
  run env BUGSWEEP_RERUN_INJECT_FAILURE=1 bash "$STAGED_RUN_CHECKS" verify "$RUN_DIR"

  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
}

@test "verify: flaky_reruns=0 disables the rerun path entirely (immediate REGRESSION)" {
  _write_config "true" 3
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  # Would-be-flaky test (fails once, then would pass) — but reruns are
  # disabled via config, so it must never get the chance to prove flaky.
  _write_seq_stub "${PROJECT}/flaky_test.sh" "1 0" "FAILED tests/test_flaky.py::test_would_be_flaky"
  _write_config "bash '${PROJECT}/flaky_test.sh'" 0
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^REGRESSION$"
  [ ! -f "${RUN_DIR}/flaky.jsonl" ]
}

# ---------------------------------------------------------------------------
# Criterion 3: baseline-flaky limitation is documented, not silently claimed.
# ---------------------------------------------------------------------------

@test "run_checks.sh header documents the baseline-flaky detection limitation" {
  grep -qi "baseline" "$RUN_CHECKS_SH"
  grep -qi "flaky" "$RUN_CHECKS_SH"
  # The header must explicitly say baseline has no per-test identity, so a
  # test flaky already at baseline time cannot be distinguished from a new
  # regression by this mechanism.
  grep -qi "cannot distinguish\|no per-test\|does not track individual test" "$RUN_CHECKS_SH"
}

@test "MAJOR-2 run_checks.sh header states the safety claim ACCURATELY (no overclaim)" {
  # (i) reruns share the working tree / environment.
  grep -qi "shared \(working tree\|environment\)\|share the initial run" "$RUN_CHECKS_SH"
  # (ii) monotonic state-pollution can be misclassified as flaky.
  grep -qi "state.pollution\|state pollution" "$RUN_CHECKS_SH"
  # (iii) a fix that lands with a flaky classification is surfaced for review.
  grep -qi "surfaced" "$RUN_CHECKS_SH"
  grep -qi "review" "$RUN_CHECKS_SH"
  # (iv) full per-rerun isolation is a documented future enhancement.
  grep -qi "future enhancement\|isolation.*deferred\|deferred.*isolation" "$RUN_CHECKS_SH"
  # And it must NOT claim to distinguish deterministic-vs-flaky as a guarantee.
  ! grep -qi "guarantee.* distinguish.* deterministic" "$RUN_CHECKS_SH"
}

@test "MAJOR-2 SKILL.md rule 5 states the safety claim ACCURATELY (no overclaim)" {
  local skill; skill="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/SKILL.md"
  grep -qi "shared \(working tree\|environment\)\|share the initial run" "$skill"
  grep -qi "state.pollution\|state pollution" "$skill"
  # The flaky-lands-with-a-fix case is surfaced and must be reviewed.
  grep -qi "surfaced" "$skill"
  grep -qi "must be reviewed\|reviews it\|be reviewed" "$skill"
  grep -qi "future enhancement\|isolation.*deferred\|deferred.*isolation" "$skill"
}

# ---------------------------------------------------------------------------
# Config default: flaky_reruns defaults to 3 when unset.
# ---------------------------------------------------------------------------

@test "verify: flaky_reruns defaults to 3 when absent from config" {
  mkdir -p "${PROJECT}/config"
  cat > "${PROJECT}/config/bugsweep.config.json" <<'JSON'
{ "commands": { "test": "true", "build": "", "typecheck": "", "lint": "" } }
JSON
  _stage_scripts_with_config
  run _run_baseline
  [ "$status" -eq 0 ]

  # Sequence "1 1 0": initial run fails, rerun 1 fails, reruns 2 and 3 pass.
  # Over the 3 default reruns the outcomes are [fail, pass, pass] = 2 pass >
  # 1 fail = strict majority -> flaky. A default clamped to fewer than 3
  # reruns would NOT reach a passing majority here, so this proves default=3.
  _write_seq_stub "${PROJECT}/flaky_test.sh" "1 1 0" "FAILED tests/test_default.py::test_default_reruns"
  cat > "${PROJECT}/config/bugsweep.config.json" <<JSON
{ "commands": { "test": "bash '${PROJECT}/flaky_test.sh'", "build": "", "typecheck": "", "lint": "" } }
JSON
  cp "${PROJECT}/config/bugsweep.config.json" "${STAGE}/config/bugsweep.config.json"

  run _run_verify
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^FLAKY=1$"
  # All 3 default reruns performed; failures = initial(1) + rerun-1(1) = 2.
  grep -q '"reruns":3' "${RUN_DIR}/flaky.jsonl"
  grep -q '"failures":2' "${RUN_DIR}/flaky.jsonl"
}
