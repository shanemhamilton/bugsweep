#!/usr/bin/env bash
# Shared bats helpers for the bench bash-glue test suite.
#
# Resolves repo paths relative to this file so tests run from any CWD, and
# provides small assertion helpers (bats-assert/bats-support are not assumed
# to be installed, so we keep these dependency-free).

# Absolute path to bench/lib regardless of the CWD bats was launched from.
# Resolve bench/ first (it always exists), then append lib/ so the helper can
# load even before lib/ is created (TDD red phase).
_BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH_LIB_DIR="${_BENCH_DIR}/lib"
export BENCH_LIB_DIR

ISOLATE_SH="${BENCH_LIB_DIR}/isolate.sh"
PROXY_SH="${BENCH_LIB_DIR}/proxy.sh"
export ISOLATE_SH PROXY_SH

# Analysis-image build glue lives under bench/docker/.
BENCH_DOCKER_DIR="${_BENCH_DIR}/docker"
ENTRYPOINT_SH="${BENCH_DOCKER_DIR}/docker-entrypoint.sh"
export BENCH_DOCKER_DIR ENTRYPOINT_SH

# assert_contains <haystack> <needle> — fail with context if needle absent.
assert_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'expected output to contain:\n  %s\nactual output:\n%s\n' "$needle" "$haystack" >&2
    return 1
  fi
}

# refute_contains <haystack> <needle> — fail if needle IS present.
refute_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'expected output to NOT contain:\n  %s\nactual output:\n%s\n' "$needle" "$haystack" >&2
    return 1
  fi
}
