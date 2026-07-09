#!/usr/bin/env bats
#
# bugsweep-06y: state.env is SOURCED (not merely read) by five call sites
# (guard.sh, finalize.sh, session.sh, run_checks.sh, state.sh). Pre-fix,
# preflight.sh's _bsw_persist_run_state_and_lease() wrote it via an UNQUOTED
# heredoc that interpolated BUGSWEEP_ORIG_BRANCH raw — and orig_branch is the
# user's current git branch NAME, which may legally contain $(...), backticks,
# `;`, and quotes. A branch named e.g. `x$(touch /tmp/PWNED)` got that command
# EXECUTED the moment any of the five sites sourced state.env: command
# injection via the source boundary.
#
# These tests drive the REAL, shipped preflight.sh end-to-end (never re-derive
# its logic): check out a malicious branch name, run preflight, then `source`
# the produced state.env exactly like the five real call sites do, and assert
# (a) no injected command executed, and (b) the value round-trips byte-for-byte.
# A companion test proves the preflight ledger.jsonl line stays valid JSON for
# a branch name containing a double quote.

PREFLIGHT_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/preflight.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  # Non-protected default branch name (preflight refuses to START from a
  # dirty protected branch — unrelated to what this file tests, see the
  # other bats files' identical setup rationale).
  git -C "$dir" checkout -q -b dev
  printf 'base\n' > "${dir}/app.txt"
  git -C "$dir" add app.txt
  git -C "$dir" commit -m "init" -q
}

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  cd "$REPO"
  MARKER="${BATS_TMP}/PWNED"
  rm -f "$MARKER"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

# Runs preflight on the given (possibly malicious) branch name, sources the
# produced state.env in a SEPARATE subshell (so a successful injection cannot
# corrupt the bats process itself), and echoes:
#   RUN_DIR=<dir>
#   ORIG_BRANCH_VALUE=<what BUGSWEEP_ORIG_BRANCH round-tripped to>
#   MARKER_EXISTS=<yes|no>
_run_preflight_and_source_state_env() {
  local payload="$1"
  git -C "$REPO" checkout -q -b "$payload"

  run bash "$PREFLIGHT_SH"
  [ "$status" -eq 0 ]
  local run_dir
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  [ -n "$run_dir" ]
  [ -f "${run_dir}/state.env" ]

  echo "RUN_DIR=${run_dir}"

  # Source exactly like the five real call sites do (guard.sh:12,
  # finalize.sh:13, session.sh:14, run_checks.sh:105, state.sh:106): a plain
  # `. state.env` in a fresh, disposable subshell.
  ( set +u
    # shellcheck disable=SC1090
    . "${run_dir}/state.env"
    echo "ORIG_BRANCH_VALUE=${BUGSWEEP_ORIG_BRANCH}"
  )
}

# ---------------------------------------------------------------------------
# RED/GREEN: command injection via $(...)
# ---------------------------------------------------------------------------

@test "state.env: sourcing a branch named x\$(touch MARKER) does NOT execute the payload, and the value round-trips" {
  local payload="x\$(>${MARKER})"
  run _run_preflight_and_source_state_env "$payload"
  [ "$status" -eq 0 ]

  [ ! -f "$MARKER" ]  # no execution happened while sourcing state.env

  echo "$output" | grep -qF "ORIG_BRANCH_VALUE=${payload}"
}

# ---------------------------------------------------------------------------
# RED/GREEN: command injection via backticks
# ---------------------------------------------------------------------------

@test "state.env: sourcing a branch named x\`touch MARKER\` does NOT execute the payload, and the value round-trips" {
  local payload="x\`>${MARKER}\`"
  run _run_preflight_and_source_state_env "$payload"
  [ "$status" -eq 0 ]

  [ ! -f "$MARKER" ]

  echo "$output" | grep -qF "ORIG_BRANCH_VALUE=${payload}"
}

# ---------------------------------------------------------------------------
# RED/GREEN: command injection via a bare semicolon-separated command
# ---------------------------------------------------------------------------

@test "state.env: sourcing a branch named x;touch MARKER does NOT execute the payload, and the value round-trips" {
  local payload="x;>${MARKER}"
  run _run_preflight_and_source_state_env "$payload"
  [ "$status" -eq 0 ]

  [ ! -f "$MARKER" ]

  echo "$output" | grep -qF "ORIG_BRANCH_VALUE=${payload}"
}

# ---------------------------------------------------------------------------
# RED/GREEN: a single quote in the value must not break out of the emitted
# quoting (the classic "escape every embedded single quote" edge case).
# ---------------------------------------------------------------------------

@test "state.env: a branch name containing a single quote round-trips exactly, with no execution" {
  local payload="x'y\$(>${MARKER})"
  run _run_preflight_and_source_state_env "$payload"
  [ "$status" -eq 0 ]

  [ ! -f "$MARKER" ]

  echo "$output" | grep -qF "ORIG_BRANCH_VALUE=${payload}"
}

# ---------------------------------------------------------------------------
# RED/GREEN: a double quote in the value must round-trip too (single-quote
# wrapping treats " as an ordinary character, unlike double-quote wrapping).
# ---------------------------------------------------------------------------

@test "state.env: a branch name containing a double quote round-trips exactly" {
  local payload='x"y'
  run _run_preflight_and_source_state_env "$payload"
  [ "$status" -eq 0 ]

  echo "$output" | grep -qF "ORIG_BRANCH_VALUE=${payload}"
}

# ---------------------------------------------------------------------------
# RED/GREEN: the ledger.jsonl "preflight" event line must stay valid JSON for
# a branch name containing a double quote (pre-fix, raw printf %s interpolation
# breaks the JSON string structure).
# ---------------------------------------------------------------------------

@test "ledger.jsonl: the preflight event line is valid JSON for a branch name containing a double quote" {
  local payload='x"y'
  git -C "$REPO" checkout -q -b "$payload"

  run bash "$PREFLIGHT_SH"
  [ "$status" -eq 0 ]
  local run_dir
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  [ -n "$run_dir" ]
  [ -f "${run_dir}/ledger.jsonl" ]

  local line
  line="$(sed -n '1p' "${run_dir}/ledger.jsonl")"
  [ -n "$line" ]

  run jq -e . <<< "$line"
  [ "$status" -eq 0 ]

  # And the orig_branch field, once JSON-decoded, is the exact literal payload.
  run jq -r '.orig_branch' <<< "$line"
  [ "$status" -eq 0 ]
  [ "$output" = "$payload" ]
}

# ---------------------------------------------------------------------------
# Unit-level proof for the helper itself (bash 3.2 round-trip), independent of
# preflight.sh, so the escaping mechanism is verified in isolation too.
# ---------------------------------------------------------------------------

@test "_bsw_env_kv: escapes a value containing a single quote AND a command substitution, and round-trips exactly under bash 3.2" {
  COMMON_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/common.sh"
  # shellcheck disable=SC1090
  source "$COMMON_SH"

  local value="x'y\$(>${MARKER})"
  local emitted
  emitted="$(_bsw_env_kv TESTKEY "$value")"

  # The escaped form must be source-safe: sourcing it must not execute the
  # embedded $(...) and must round-trip the exact original value.
  local tmp_env="${BATS_TMP}/unit-state.env"
  printf '%s\n' "$emitted" > "$tmp_env"

  ( set +u
    # shellcheck disable=SC1090
    . "$tmp_env"
    [ ! -f "$MARKER" ]
    [ "$TESTKEY" = "$value" ]
  )
}

@test "_bsw_json_escape: escapes double quotes and backslashes so the result is a valid JSON string body" {
  COMMON_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/common.sh"
  # shellcheck disable=SC1090
  source "$COMMON_SH"

  local value='x"y\z'
  local escaped
  escaped="$(_bsw_json_escape "$value")"

  run jq -r . <<< "\"${escaped}\""
  [ "$status" -eq 0 ]
  [ "$output" = "$value" ]
}
