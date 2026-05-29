#!/usr/bin/env bats
#
# Tier-A (container-free) tests for the analysis-image entrypoint glue.
# These exercise docker-entrypoint.sh's setup logic directly on the host with
# its paths redirected to tmp dirs (BENCH_ENTRY_* overrides) — they never build
# or launch a container.

load helpers

setup() {
  BATS_TMP="$(mktemp -d)"
  export BATS_TMP
}

teardown() {
  [[ -n "${BATS_TMP:-}" && -d "$BATS_TMP" ]] && rm -rf "$BATS_TMP"
}

# ---------------------------------------------------------------------------
# docker-entrypoint.sh : per-run setup then exec
# ---------------------------------------------------------------------------

@test "entrypoint stages the skill into HOME/.claude/skills" {
  mkdir -p "$BATS_TMP/skill" "$BATS_TMP/work"
  echo marker >"$BATS_TMP/skill/SKILL.md"
  run env \
    BENCH_ENTRY_HOME="$BATS_TMP/home" \
    BENCH_ENTRY_SKILL_SRC="$BATS_TMP/skill" \
    BENCH_ENTRY_WORK="$BATS_TMP/work" \
    BENCH_ENTRY_REPO="$BATS_TMP/repo" \
    bash "$ENTRYPOINT_SH" true
  [ "$status" -eq 0 ]
  [ -f "$BATS_TMP/home/.claude/skills/bugsweep/SKILL.md" ]
}

@test "entrypoint makes a WRITABLE copy of the read-only clone" {
  mkdir -p "$BATS_TMP/skill" "$BATS_TMP/work"
  echo workfile >"$BATS_TMP/work/file.txt"
  run env \
    BENCH_ENTRY_HOME="$BATS_TMP/home" \
    BENCH_ENTRY_SKILL_SRC="$BATS_TMP/skill" \
    BENCH_ENTRY_WORK="$BATS_TMP/work" \
    BENCH_ENTRY_REPO="$BATS_TMP/repo" \
    bash "$ENTRYPOINT_SH" sh -c 'echo mutated >> file.txt; cat file.txt'
  [ "$status" -eq 0 ]
  assert_contains "$output" "workfile"
  assert_contains "$output" "mutated"
  # The host clone must remain pristine (the copy absorbed the write).
  run cat "$BATS_TMP/work/file.txt"
  assert_contains "$output" "workfile"
  refute_contains "$output" "mutated"
}

@test "entrypoint execs the command from inside the writable repo copy" {
  mkdir -p "$BATS_TMP/skill" "$BATS_TMP/work"
  run env \
    BENCH_ENTRY_HOME="$BATS_TMP/home" \
    BENCH_ENTRY_SKILL_SRC="$BATS_TMP/skill" \
    BENCH_ENTRY_WORK="$BATS_TMP/work" \
    BENCH_ENTRY_REPO="$BATS_TMP/repo" \
    bash "$ENTRYPOINT_SH" pwd
  [ "$status" -eq 0 ]
  assert_contains "$output" "$BATS_TMP/repo"
}

@test "entrypoint exports HOME to the writable tmpfs location" {
  mkdir -p "$BATS_TMP/skill" "$BATS_TMP/work"
  run env \
    BENCH_ENTRY_HOME="$BATS_TMP/home" \
    BENCH_ENTRY_SKILL_SRC="$BATS_TMP/skill" \
    BENCH_ENTRY_WORK="$BATS_TMP/work" \
    BENCH_ENTRY_REPO="$BATS_TMP/repo" \
    bash "$ENTRYPOINT_SH" sh -c 'echo HOME=$HOME'
  [ "$status" -eq 0 ]
  assert_contains "$output" "HOME=$BATS_TMP/home"
}

@test "entrypoint propagates the command's exit status" {
  mkdir -p "$BATS_TMP/skill" "$BATS_TMP/work"
  run env \
    BENCH_ENTRY_HOME="$BATS_TMP/home" \
    BENCH_ENTRY_SKILL_SRC="$BATS_TMP/skill" \
    BENCH_ENTRY_WORK="$BATS_TMP/work" \
    BENCH_ENTRY_REPO="$BATS_TMP/repo" \
    bash "$ENTRYPOINT_SH" sh -c 'exit 10'
  [ "$status" -eq 10 ]
}

@test "entrypoint tolerates a missing skill source (no skill to stage)" {
  mkdir -p "$BATS_TMP/work"
  run env \
    BENCH_ENTRY_HOME="$BATS_TMP/home" \
    BENCH_ENTRY_SKILL_SRC="$BATS_TMP/does-not-exist" \
    BENCH_ENTRY_WORK="$BATS_TMP/work" \
    BENCH_ENTRY_REPO="$BATS_TMP/repo" \
    bash "$ENTRYPOINT_SH" true
  [ "$status" -eq 0 ]
}
