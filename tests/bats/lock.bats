#!/usr/bin/env bats
#
# Tests for common.sh's mkdir-based lock (bugsweep-p74 review fix, MAJOR D):
# stale-lock reclaim must have exactly ONE winner. The original reclaim
# (rm pidfile, rmdir, retry) let several waiters that all observed the same
# dead-pid lock interleave their deletions with the new winner's mkdir +
# pid-write, ending with many processes simultaneously "holding" the lock.
# The fix reclaims via atomic rename: exactly one mv succeeds; losers just
# re-race on mkdir.

COMMON_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/common.sh"

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  cd "$BATS_TMP"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

@test "bugsweep_lock_acquire: concurrent stale-lock reclaim admits exactly one holder at a time" {
  local lock="${BATS_TMP}/test.lock" mark="${BATS_TMP}/holder.mark" viol="${BATS_TMP}/violations"

  # Manufacture a dead-pid lock that all 10 workers will race to reclaim.
  mkdir "$lock"
  printf '999999' > "${lock}/pid"

  # Each worker: acquire -> enter critical section guarded by an ATOMIC mkdir
  # marker (a second concurrent holder's mkdir fails -> records a violation) ->
  # hold briefly -> leave -> release.
  local worker="${BATS_TMP}/worker.sh"
  cat > "$worker" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
common="$1"; lock="$2"; mark="$3"; viol="$4"
# shellcheck disable=SC1090
. "$common"
if bugsweep_lock_acquire "$lock" 100; then
  if ! mkdir "$mark" 2>/dev/null; then
    echo "overlap pid=$$" >> "$viol"
  else
    sleep 0.15
    rmdir "$mark" 2>/dev/null || true
  fi
  bugsweep_lock_release "$lock"
else
  echo "timeout pid=$$" >> "$viol"
fi
WORKER

  local pids="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( bash "$worker" "$COMMON_SH" "$lock" "$mark" "$viol" ) &
    pids="$pids $!"
  done
  local rc=0 p
  for p in $pids; do
    wait "$p" || rc=1
  done
  [ "$rc" -eq 0 ]

  # Zero overlapping holds and zero timeouts across all 10 workers.
  if [ -s "$viol" ]; then
    cat "$viol" >&2
    false
  fi

  # Lock fully released at the end.
  [ ! -d "$lock" ]
}
