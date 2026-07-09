#!/usr/bin/env bats
#
# Tests for the repro gate (bugsweep-hty): scripts/repro.sh, plus its
# ADDITIVE integration with scripts/run_checks.sh's existing verify/revert
# decision (documented in prompts/fix.md).
#
# Design recap (see scripts/repro.sh's own header for the full contract):
#   - `repro.sh pre  <RUN_DIR> <BUG_ID> ["<CMD>"]` runs BEFORE a fix. Empty
#     CMD -> "none" (terminal). CMD passes -> "unreproduced" (terminal, the
#     repro never demonstrated the bug). CMD fails -> "red_confirmed"
#     (non-terminal — local state only, no ledger event yet).
#   - `repro.sh post <RUN_DIR> <BUG_ID>` runs AFTER a fix, ALONGSIDE (never
#     instead of) `run_checks.sh verify`. Anything other than a pre-
#     confirmed "red_confirmed" -> REPRO=none, exit 0 (no gate — EXACTLY
#     today's suite-only behavior). "red_confirmed" -> reruns the SAME
#     command: passes now -> "confirmed" (exit 0); still fails -> "failed"
#     (exit 1 — the caller must revert+quarantine exactly like a
#     run_checks.sh REGRESSION).
#   - Every terminal outcome appends exactly ONE
#     {"event":"repro_status","bug_id":...,"status":...} line to
#     <RUN_DIR>/ledger.jsonl.

REPRO_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/repro.sh"
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

# ---------------------------------------------------------------------------
# `pre` — basic classification
# ---------------------------------------------------------------------------

@test "pre: empty repro command -> REPRO=none, terminal ledger event, no pre.log" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-1" ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"
  grep -qF '{"event":"repro_status","bug_id":"BUG-1","status":"none"}' "${RUN_DIR}/ledger.jsonl"
  [ ! -f "${RUN_DIR}/repro-BUG-1-pre.log" ]
}

@test "pre: omitted repro command (no 4th arg at all) -> REPRO=none" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"
}

@test "pre: command that PASSES before the fix -> REPRO=unreproduced, terminal ledger event" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-2" "true"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=unreproduced"
  grep -qF '{"event":"repro_status","bug_id":"BUG-2","status":"unreproduced"}' "${RUN_DIR}/ledger.jsonl"
}

@test "pre: command that FAILS before the fix -> REPRO=red_confirmed, NO ledger event yet (non-terminal)" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-3" "false"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=red_confirmed"
  [ ! -f "${RUN_DIR}/ledger.jsonl" ]
  [ -f "${RUN_DIR}/repro-BUG-3-pre.log" ]
}

# ---------------------------------------------------------------------------
# `post` — fallback path (nothing pre-confirmed red)
# ---------------------------------------------------------------------------

@test "post: never ran pre -> REPRO=none, exit 0, no ledger event written by post" {
  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-4"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"
  [ ! -f "${RUN_DIR}/ledger.jsonl" ]
}

@test "post: pre recorded none -> post also reports REPRO=none and does not duplicate the ledger event" {
  bash "$REPRO_SH" pre "$RUN_DIR" "BUG-5" ""
  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-5"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"
  [ "$(grep -c '"bug_id":"BUG-5"' "${RUN_DIR}/ledger.jsonl")" -eq 1 ]
}

@test "post: pre recorded unreproduced -> post also reports REPRO=none, never gates, no duplicate event" {
  bash "$REPRO_SH" pre "$RUN_DIR" "BUG-6" "true"
  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-6"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"
  [ "$(grep -c '"bug_id":"BUG-6"' "${RUN_DIR}/ledger.jsonl")" -eq 1 ]
  grep -qF '"status":"unreproduced"' "${RUN_DIR}/ledger.jsonl"
}

# ---------------------------------------------------------------------------
# `post` — the real gate: red_confirmed -> confirmed / failed
# ---------------------------------------------------------------------------

@test "post: pre red_confirmed, command now PASSES -> REPRO=confirmed, exit 0, ledger event appended" {
  local marker="${BATS_TMP}/fixed.flag"
  bash "$REPRO_SH" pre "$RUN_DIR" "BUG-7" "[ -f '${marker}' ]"
  [ ! -f "${RUN_DIR}/ledger.jsonl" ]

  touch "$marker"
  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=confirmed"
  grep -qF '{"event":"repro_status","bug_id":"BUG-7","status":"confirmed"}' "${RUN_DIR}/ledger.jsonl"
  [ -f "${RUN_DIR}/repro-BUG-7-post.log" ]
}

@test "post: pre red_confirmed, command STILL FAILS -> REPRO=failed, exit 1, ledger event appended" {
  bash "$REPRO_SH" pre "$RUN_DIR" "BUG-8" "false"
  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-8"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qx "REPRO=failed"
  grep -qF '{"event":"repro_status","bug_id":"BUG-8","status":"failed"}' "${RUN_DIR}/ledger.jsonl"
}

@test "post: re-runs the EXACT SAME command pre used (round-trip through the state file)" {
  local counter="${BATS_TMP}/count.txt"
  : > "$counter"
  local stub="${BATS_TMP}/stub.sh"
  cat > "$stub" <<SH
#!/usr/bin/env bash
printf 'x\n' >> "${counter}"
exit 1
SH
  chmod +x "$stub"

  bash "$REPRO_SH" pre "$RUN_DIR" "BUG-9" "bash '${stub}'"
  [ "$(wc -l < "$counter" | tr -d ' ')" -eq 1 ]

  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-9"
  [ "$status" -eq 1 ]
  # The SAME stub ran a second time (post re-invoked the identical command).
  [ "$(wc -l < "$counter" | tr -d ' ')" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Ledger event shape: exact JSON, valid, single line per bug.
# ---------------------------------------------------------------------------

@test "ledger event shape is exact JSON with the documented keys" {
  bash "$REPRO_SH" pre "$RUN_DIR" "BUG-10" "false"
  bash "$REPRO_SH" post "$RUN_DIR" "BUG-10" || true

  run python3 -c '
import json, sys
lines = [l for l in open(sys.argv[1]) if l.strip()]
assert len(lines) == 1, lines
d = json.loads(lines[0])
assert list(d.keys()) == ["event", "bug_id", "status"], d
assert d["event"] == "repro_status"
assert d["bug_id"] == "BUG-10"
assert d["status"] == "failed"
print("SHAPE_OK")
' "${RUN_DIR}/ledger.jsonl"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "SHAPE_OK"
}

# ---------------------------------------------------------------------------
# Isolation across independent bug ids.
# ---------------------------------------------------------------------------

@test "independent bug ids never interfere with each other's state or ledger events" {
  bash "$REPRO_SH" pre "$RUN_DIR" "BUG-A" "false"
  bash "$REPRO_SH" pre "$RUN_DIR" "BUG-B" "true"
  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-A"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qx "REPRO=failed"
  run bash "$REPRO_SH" post "$RUN_DIR" "BUG-B"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"

  grep -qF '"bug_id":"BUG-A","status":"failed"' "${RUN_DIR}/ledger.jsonl"
  grep -qF '"bug_id":"BUG-B","status":"unreproduced"' "${RUN_DIR}/ledger.jsonl"
  [ "$(grep -c '"event":"repro_status"' "${RUN_DIR}/ledger.jsonl")" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Input validation / safety.
# ---------------------------------------------------------------------------

@test "usage error on missing arguments" {
  run bash "$REPRO_SH"
  [ "$status" -ne 0 ]
}

@test "usage error on an unknown subcommand" {
  run bash "$REPRO_SH" bogus "$RUN_DIR" "BUG-1"
  [ "$status" -ne 0 ]
}

@test "refuses a BUG_ID containing a path separator (traversal guard)" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "../etc/passwd" "false"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "invalid BUG_ID"
}

@test "refuses a BUG_ID containing '..'" {
  run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-..-1" "false"
  [ "$status" -ne 0 ]
}

@test "dies when RUN_DIR does not exist" {
  run bash "$REPRO_SH" pre "${BATS_TMP}/does-not-exist" "BUG-1" "false"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# No-python degraded path: identical observable behavior.
# ---------------------------------------------------------------------------

@test "degraded (BUGSWEEP_NO_PYTHON=1) path: red_confirmed -> confirmed round-trips correctly" {
  local marker="${BATS_TMP}/fixed2.flag"
  BUGSWEEP_NO_PYTHON=1 run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-11" "[ -f '${marker}' ]"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=red_confirmed"

  touch "$marker"
  BUGSWEEP_NO_PYTHON=1 run bash "$REPRO_SH" post "$RUN_DIR" "BUG-11"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=confirmed"
  grep -qF '{"event":"repro_status","bug_id":"BUG-11","status":"confirmed"}' "${RUN_DIR}/ledger.jsonl"
}

@test "degraded (BUGSWEEP_NO_PYTHON=1) path: red_confirmed -> failed round-trips correctly" {
  BUGSWEEP_NO_PYTHON=1 run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-12" "false"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=red_confirmed"

  BUGSWEEP_NO_PYTHON=1 run bash "$REPRO_SH" post "$RUN_DIR" "BUG-12"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qx "REPRO=failed"
}

@test "degraded (BUGSWEEP_NO_PYTHON=1) path: none / unreproduced still degrade cleanly" {
  BUGSWEEP_NO_PYTHON=1 run bash "$REPRO_SH" pre "$RUN_DIR" "BUG-13" ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"

  BUGSWEEP_NO_PYTHON=1 run bash "$REPRO_SH" post "$RUN_DIR" "BUG-13"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"
}

# ===========================================================================
# Integration with scripts/run_checks.sh (fix.md's documented flow)
# ===========================================================================
#
# Same config-staging idiom as tests/bats/run-checks-flaky.bats: run_checks.sh
# resolves its config relative to the SCRIPT's own root, so a per-test config
# override requires staging a scripts/ tree of per-file symlinks whose
# ../config is the temp config. repro.sh itself needs no config, but is
# staged alongside run_checks.sh so both resolve consistently in one test.

_write_config() {
  local test_cmd="$1"
  mkdir -p "${PROJECT}/config"
  cat > "${PROJECT}/config/bugsweep.config.json" <<JSON
{
  "commands": { "test": "${test_cmd}", "build": "", "typecheck": "", "lint": "" },
  "verify": { "flaky_reruns": 3 }
}
JSON
}

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
  STAGED_REPRO="${STAGE}/scripts/repro.sh"
}

# ---------------------------------------------------------------------------
# Acceptance criterion: seeded bug + generated repro FAILS pre-fix, PASSES
# post-fix, WHILE the general (unrelated) suite check stays green throughout
# -- proving the repro gate is an ADDITIONAL, independent signal, not a
# replacement for the existing suite-green check.
# ---------------------------------------------------------------------------

@test "integration: seeded bug's repro FAILS pre-fix and PASSES post-fix; suite stays green throughout" {
  # A buggy add() with an off-by-one, plus an UNRELATED "suite" check that is
  # blind to it (always "true") -- proving run_checks.sh alone would say OK
  # even though the real bug is still present.
  cat > "${PROJECT}/add.sh" <<'SH'
add() { echo $(( $1 + $2 + 1 )); }
SH
  local repro_test="${PROJECT}/repro_test.sh"
  cat > "$repro_test" <<SH
#!/usr/bin/env bash
. "${PROJECT}/add.sh"
result="\$(add 2 3)"
[ "\$result" -eq 5 ] || { echo "expected 5 got \$result"; exit 1; }
SH
  chmod +x "$repro_test"

  _write_config "true"
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$RUN_DIR"
  [ "$status" -eq 0 ]

  # Pre-fix: repro must be RED.
  run bash "$STAGED_REPRO" pre "$RUN_DIR" "BUG-SEED-1" "bash '${repro_test}'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=red_confirmed"

  # Apply the REAL fix.
  cat > "${PROJECT}/add.sh" <<'SH'
add() { echo $(( $1 + $2 )); }
SH

  # The general suite check is unaffected (still "true") -> stays green.
  run bash "$STAGED_RUN_CHECKS" verify "$RUN_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK$"

  # Post-fix: repro must now be GREEN.
  run bash "$STAGED_REPRO" post "$RUN_DIR" "BUG-SEED-1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=confirmed"

  grep -qF '{"event":"repro_status","bug_id":"BUG-SEED-1","status":"confirmed"}' "${RUN_DIR}/ledger.jsonl"
}

# ---------------------------------------------------------------------------
# Acceptance criterion: a fix that does NOT satisfy its repro is REVERTED and
# quarantined -- even though the (unrelated) suite alone reports OK. This
# mechanically drives the exact revert+quarantine sequence prompts/fix.md
# documents for a repro-failed outcome, proving the signal + the documented
# protocol together produce the correct end state.
# ---------------------------------------------------------------------------

@test "integration: fix whose repro stays RED is reverted and quarantined, even though the suite alone says OK" {
  cat > "${PROJECT}/add.sh" <<'SH'
add() { echo $(( $1 + $2 + 1 )); }
SH
  git init -q "$PROJECT"
  git -C "$PROJECT" config user.email "test@bugsweep"
  git -C "$PROJECT" config user.name "bugsweep-test"
  git -C "$PROJECT" add add.sh
  git -C "$PROJECT" commit -q -m "seed buggy add()"

  local repro_test="${PROJECT}/repro_test.sh"
  cat > "$repro_test" <<SH
#!/usr/bin/env bash
. "${PROJECT}/add.sh"
result="\$(add 2 3)"
[ "\$result" -eq 5 ] || { echo "expected 5 got \$result"; exit 1; }
SH
  chmod +x "$repro_test"

  _write_config "true"
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$RUN_DIR"
  [ "$status" -eq 0 ]

  run bash "$STAGED_REPRO" pre "$RUN_DIR" "BUG-SEED-2" "bash '${repro_test}'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=red_confirmed"

  # Apply an INCOMPLETE "fix": a cosmetic edit that does not touch the actual
  # bug. The unrelated suite check ("true") cannot detect this.
  printf '# reviewed, looks fine\n' >> "${PROJECT}/add.sh"

  run bash "$STAGED_RUN_CHECKS" verify "$RUN_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK$"

  run bash "$STAGED_REPRO" post "$RUN_DIR" "BUG-SEED-2"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qx "REPRO=failed"

  # prompts/fix.md's documented revert-on-REGRESSION sequence, applied here
  # because step 3b's REPRO=failed is treated exactly like a REGRESSION:
  # uncommitted changes -> `git checkout -- .`, then quarantine the bug.
  git -C "$PROJECT" checkout -q -- add.sh
  echo '{"event":"quarantine","bug_id":"BUG-SEED-2","file":"add.sh","rationale":"repro stayed red after fix"}' \
    >> "${RUN_DIR}/ledger.jsonl"

  # The fix was reverted: the original bug is back, verbatim, and add.sh
  # matches the committed (buggy) HEAD content exactly -- no leftover diff
  # from the incomplete fix. (Other untracked scaffolding, e.g. this test's
  # own config/ and repro_test.sh, is irrelevant scaffolding, not part of
  # the fix under revert, so it is deliberately NOT asserted clean here.)
  grep -qF '+ 1' "${PROJECT}/add.sh"
  ! grep -q "reviewed, looks fine" "${PROJECT}/add.sh"
  git -C "$PROJECT" diff --quiet -- add.sh

  # The bug is recorded as quarantined, never as committed/fixed.
  grep -qF '"event":"quarantine","bug_id":"BUG-SEED-2"' "${RUN_DIR}/ledger.jsonl"
  ! grep -q '"event":"fix_committed".*"BUG-SEED-2"' "${RUN_DIR}/ledger.jsonl"
}

# ---------------------------------------------------------------------------
# Acceptance criterion: repro:none (and unreproduced) degrade EXACTLY to
# today's suite-only gating -- an incomplete fix that keeps the suite green
# is never newly reverted just because no repro exists for it.
# ---------------------------------------------------------------------------

@test "integration: repro:none never triggers a new revert -- an incomplete fix with a green suite still lands" {
  cat > "${PROJECT}/add.sh" <<'SH'
add() { echo $(( $1 + $2 + 1 )); }
SH

  _write_config "true"
  _stage_scripts_with_config
  run bash "$STAGED_RUN_CHECKS" baseline "$RUN_DIR"
  [ "$status" -eq 0 ]

  # No repro command available for this bug (e.g. no test framework detected
  # / not a reproducible shape) -> "none".
  run bash "$STAGED_REPRO" pre "$RUN_DIR" "BUG-SEED-3" ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"

  # An incomplete "fix" that the (unrelated) suite cannot catch.
  printf '# cosmetic only\n' >> "${PROJECT}/add.sh"

  run bash "$STAGED_RUN_CHECKS" verify "$RUN_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK$"

  # post must be a pure no-op fallback: no new gate, exit 0.
  run bash "$STAGED_REPRO" post "$RUN_DIR" "BUG-SEED-3"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPRO=none"

  # Per today's (unchanged) decision, the fix would land: run_checks.sh
  # verify alone is OK, and repro.sh contributes no additional gate.
  grep -qF '"event":"repro_status","bug_id":"BUG-SEED-3","status":"none"' "${RUN_DIR}/ledger.jsonl"
}
