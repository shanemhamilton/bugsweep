#!/usr/bin/env bats
#
# Tier-A tests for the case-preparation tooling:
#   - sandbox.sh       : hardened, hash-verified clone of a repo at a pinned SHA
#   - validate_case.sh : fast jq-based required-field pre-check for a case JSON
#
# These never reach the public network: sandbox.sh is exercised against a LOCAL
# bare repo, and its --print-cmd mode lets us assert the hardening flags without
# inspecting a resulting clone's config.

load helpers

# validate_case.sh is a WU1 addition; define its path here rather than touching
# the WU0 helpers.bash.
SANDBOX_SH="${BENCH_LIB_DIR}/sandbox.sh"
VALIDATE_CASE_SH="${BENCH_LIB_DIR}/validate_case.sh"

setup() {
  BATS_TMP="$(mktemp -d)"
  export BATS_TMP
  export BENCH_MIRROR_DIR="${BATS_TMP}/mirrors"
}

teardown() {
  [[ -n "${BATS_TMP:-}" && -d "$BATS_TMP" ]] && rm -rf "$BATS_TMP"
}

# Create a local bare repo with >=2 commits in $BATS_TMP/src.git and export
# GOOD_SHA (HEAD's full 40-char SHA) and FIRST_SHA (the first commit).
_make_bare_repo() {
  local work="${BATS_TMP}/work"
  local bare="${BATS_TMP}/src.git"
  mkdir -p "$work"
  git init -q "$work"
  git -C "$work" config user.email bench@example.com
  git -C "$work" config user.name bench
  git -C "$work" config commit.gpgsign false
  echo "v1" >"$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -q -m "first"
  FIRST_SHA="$(git -C "$work" rev-parse HEAD)"
  echo "v2" >>"$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -q -m "second"
  GOOD_SHA="$(git -C "$work" rev-parse HEAD)"
  git clone -q --bare "$work" "$bare"
  BARE_REPO="$bare"
  export FIRST_SHA GOOD_SHA BARE_REPO
}

# ---------------------------------------------------------------------------
# sandbox.sh --print-cmd : analysis-phase clone hardening flags
# ---------------------------------------------------------------------------

@test "sandbox --print-cmd disables file-protocol transport on the clone" {
  # Enforced as destination repo config (config form: "protocol.file.allow never")
  # rather than a clone-time -c, because protocol.file.allow=never would block the
  # clone from our own trusted local mirror. See analysis_clone() for rationale.
  run "$SANDBOX_SH" --print-cmd /tmp/mirror /tmp/dest deadbeef
  [ "$status" -eq 0 ]
  assert_contains "$output" "protocol.file.allow never"
}

@test "sandbox --print-cmd disables git hooks" {
  run "$SANDBOX_SH" --print-cmd /tmp/mirror /tmp/dest deadbeef
  [ "$status" -eq 0 ]
  assert_contains "$output" "core.hooksPath=/dev/null"
}

@test "sandbox --print-cmd does not recurse submodules" {
  run "$SANDBOX_SH" --print-cmd /tmp/mirror /tmp/dest deadbeef
  [ "$status" -eq 0 ]
  assert_contains "$output" "--no-recurse-submodules"
}

@test "sandbox --print-cmd skips git-lfs smudge" {
  run "$SANDBOX_SH" --print-cmd /tmp/mirror /tmp/dest deadbeef
  [ "$status" -eq 0 ]
  assert_contains "$output" "GIT_LFS_SKIP_SMUDGE=1"
}

# ---------------------------------------------------------------------------
# sandbox.sh : end-to-end hardened clone from a local mirror
# ---------------------------------------------------------------------------

@test "sandbox leaves destdir on branch bench-base at the requested SHA" {
  _make_bare_repo
  local dest="${BATS_TMP}/clone-good"
  run "$SANDBOX_SH" "$BARE_REPO" "$GOOD_SHA" "$dest"
  [ "$status" -eq 0 ]
  run git -C "$dest" rev-parse --abbrev-ref HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "bench-base" ]
  run git -C "$dest" rev-parse HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "$GOOD_SHA" ]
}

@test "sandbox can check out an older pinned SHA (not just HEAD)" {
  _make_bare_repo
  local dest="${BATS_TMP}/clone-first"
  run "$SANDBOX_SH" "$BARE_REPO" "$FIRST_SHA" "$dest"
  [ "$status" -eq 0 ]
  run git -C "$dest" rev-parse HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "$FIRST_SHA" ]
}

@test "sandbox populates a hash-keyed local mirror it can reuse" {
  _make_bare_repo
  local dest="${BATS_TMP}/clone-mirror"
  run "$SANDBOX_SH" "$BARE_REPO" "$GOOD_SHA" "$dest"
  [ "$status" -eq 0 ]
  # A mirror was created under BENCH_MIRROR_DIR (the separate fetch phase).
  run find "$BENCH_MIRROR_DIR" -name HEAD -maxdepth 2
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "sandbox reuses an existing mirror on a second clone" {
  _make_bare_repo
  run "$SANDBOX_SH" "$BARE_REPO" "$GOOD_SHA" "${BATS_TMP}/clone-a"
  [ "$status" -eq 0 ]
  # Second clone of the same SHA must also succeed (mirror reuse path).
  run "$SANDBOX_SH" "$BARE_REPO" "$FIRST_SHA" "${BATS_TMP}/clone-b"
  [ "$status" -eq 0 ]
  run git -C "${BATS_TMP}/clone-b" rev-parse HEAD
  [ "$output" = "$FIRST_SHA" ]
}

# ---------------------------------------------------------------------------
# sandbox.sh : fail closed
# ---------------------------------------------------------------------------

@test "sandbox fails closed on a nonexistent SHA" {
  _make_bare_repo
  local dest="${BATS_TMP}/clone-bad"
  run "$SANDBOX_SH" "$BARE_REPO" "0000000000000000000000000000000000000000" "$dest"
  [ "$status" -ne 0 ]
}

@test "sandbox fails closed on a malformed (non-hex) SHA" {
  _make_bare_repo
  local dest="${BATS_TMP}/clone-malformed"
  run "$SANDBOX_SH" "$BARE_REPO" "not-a-sha" "$dest"
  [ "$status" -ne 0 ]
}

@test "sandbox usage error when args are missing" {
  run "$SANDBOX_SH"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# validate_case.sh : required-field pre-check
# ---------------------------------------------------------------------------

_fixtures_dir() {
  # BENCH_LIB_DIR is exported by helpers.bash as <bench>/lib; fixtures live at
  # <bench>/tests/fixtures.
  echo "$(dirname "${BENCH_LIB_DIR}")/tests/fixtures"
}

@test "validate_case accepts a complete case" {
  run "$VALIDATE_CASE_SH" "$(_fixtures_dir)/case_valid.json"
  [ "$status" -eq 0 ]
}

@test "validate_case rejects a case missing a top-level required field" {
  run "$VALIDATE_CASE_SH" "$(_fixtures_dir)/case_invalid.json"
  [ "$status" -ne 0 ]
  assert_contains "$output" "cross_file"
}

@test "validate_case rejects a case missing a nested source field" {
  local f="${BATS_TMP}/missing-repo.json"
  jq 'del(.source.repo)' "$(_fixtures_dir)/case_valid.json" >"$f"
  run "$VALIDATE_CASE_SH" "$f"
  [ "$status" -ne 0 ]
  assert_contains "$output" "repo"
}

@test "validate_case fails closed on invalid JSON" {
  local f="${BATS_TMP}/broken.json"
  printf '{ not valid json' >"$f"
  run "$VALIDATE_CASE_SH" "$f"
  [ "$status" -ne 0 ]
}

@test "validate_case fails closed on a missing file" {
  run "$VALIDATE_CASE_SH" "${BATS_TMP}/does-not-exist.json"
  [ "$status" -ne 0 ]
}

@test "validate_case usage error when no path given" {
  run "$VALIDATE_CASE_SH"
  [ "$status" -ne 0 ]
}
