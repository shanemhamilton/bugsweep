#!/usr/bin/env bats
#
# Tests for common.sh's mkdir-based lock (bugsweep-p74 review fix, MAJOR D):
# stale-lock reclaim must have exactly ONE winner. The shipped fix reclaims via
# an O_EXCL "takeover" marker (bash noclobber): a lock dir left behind by a
# dead process holds a pidfile; when that pid is observed dead, waiters race
# an exclusive `noclobber` write to a "takeover" marker file. Exactly one
# waiter wins that write; it then re-verifies — under the marker's exclusion —
# that the pidfile still names the SAME dead holder before adopting the lock
# IN PLACE (writing its own pid over the old one). The lock directory itself
# is never removed or renamed during reclaim, so the path can never be
# re-bound to a fresh generation mid-reclaim; a rename/mv-based scheme was
# tried and rejected for exactly that reason (rename(2) binds to the PATH, not
# the observed generation, so a fresh LIVE holder that re-acquired between a
# waiter's liveness check and its mv could be stolen from).
#
# bugsweep-re9: adoption's pid-write (common.sh ~line 220) was check-then-act
# without a verify-AFTER-write — a schedule replay proved a double-adopt is
# still reachable: the orphaned-marker cleanup (clearing a dead claimant's
# marker) is itself check-then-act, so a preempted claimant's `rm -f "$marker"`
# can delete a DIFFERENT, freshly-alive claimant's marker between that new
# claimant's noclobber-write and its own pid-write, letting a third waiter's
# noclobber-write also succeed and adopt concurrently. The fix adds a
# re-read-after-write: immediately after writing "$$" into "${lockdir}/pid",
# the claimant re-reads the file; if it does not see its own pid back, another
# claimant clobbered it after write and this claimant backs off and re-loops
# instead of believing it holds the lock.

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

# ---------------------------------------------------------------------------
# bugsweep-re9: verify-after-write in the adoption path — repeated storm runs.
# ---------------------------------------------------------------------------
#
# This reproduces the orphaned-marker preemption race as far as practical in a
# black-box bats test: a dead-pid lock PLUS a dead-claimant orphaned marker,
# then 10 concurrent acquirers all racing the same reclaim path. Every
# acquirer that believes it holds the lock records its (start,end) window in a
# shared file; the test asserts, across 5 repeated runs, that no two windows
# ever overlap — i.e. zero double-adoption, even though every run starts from
# an already-orphaned marker that primes exactly the preemption window the
# residual describes.

@test "bugsweep_lock_acquire: dead-pid lock + orphaned dead-claimant marker + 10-way storm never double-adopts (x5)" {
  local worker="${BATS_TMP}/storm-worker.sh"
  cat > "$worker" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
common="$1"; lock="$2"; windows="$3"; viol="$4"
# shellcheck disable=SC1090
. "$common"
if bugsweep_lock_acquire "$lock" 100; then
  start="$(date +%s%N 2>/dev/null || date +%s)"
  # Hold long enough to make an overlap observable if one occurs.
  sleep 0.05
  end="$(date +%s%N 2>/dev/null || date +%s)"
  printf '%s %s %s\n' "$$" "$start" "$end" >> "$windows"
  bugsweep_lock_release "$lock"
else
  echo "timeout pid=$$" >> "$viol"
fi
WORKER

  local run
  for run in 1 2 3 4 5; do
    local lock="${BATS_TMP}/storm-${run}.lock" windows="${BATS_TMP}/windows-${run}" viol="${BATS_TMP}/viol-${run}"
    : > "$windows"
    : > "$viol"

    # Dead-pid lock, plus an ORPHANED marker left by a claimant that itself
    # died mid-takeover (also a dead pid) — exactly the state the residual's
    # replay starts from.
    mkdir "$lock"
    printf '999999' > "${lock}/pid"
    printf '999998' > "${lock}/takeover"

    local pids="" i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      ( bash "$worker" "$COMMON_SH" "$lock" "$windows" "$viol" ) &
      pids="$pids $!"
    done
    local rc=0 p
    for p in $pids; do
      wait "$p" || rc=1
    done
    [ "$rc" -eq 0 ]

    if [ -s "$viol" ]; then
      cat "$viol" >&2
      false
    fi

    # Every worker must have recorded a window (nobody silently failed to acquire).
    local nwin
    nwin="$(wc -l < "$windows" | tr -d ' ')"
    [ "$nwin" -eq 10 ]

    # No two windows may overlap: sort by start and assert each start >= previous end.
    run python3 - "$windows" <<'PY'
import sys
rows = []
with open(sys.argv[1]) as f:
    for line in f:
        pid, start, end = line.split()
        rows.append((int(start), int(end), pid))
rows.sort()
for i in range(1, len(rows)):
    prev_end = rows[i-1][1]
    cur_start = rows[i][0]
    if cur_start < prev_end:
        print("OVERLAP: %s ends %d, %s starts %d" % (rows[i-1][2], prev_end, rows[i][2], cur_start))
        sys.exit(1)
print("OK")
PY
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]

    [ ! -d "$lock" ]
  done
}

# ---------------------------------------------------------------------------
# bugsweep-re9: comment-accuracy assertions (grep, not prose review) — these
# fail if the header above regresses to describing the rejected mv-rename
# design, and if common.sh's usage comment regresses to teaching the
# hazardous "trap release + explicit release" double-release pattern.
# ---------------------------------------------------------------------------

@test "lock.bats header describes the shipped O_EXCL takeover-marker adoption protocol, not the rejected mv-rename design" {
  # The header must describe the actual mechanism...
  grep -q 'takeover' "$BATS_TEST_FILENAME"
  grep -q 'noclobber' "$BATS_TEST_FILENAME"
  grep -qi 'adopt' "$BATS_TEST_FILENAME"
  # ...and must NOT claim the rejected mv-rename design's tagline as the
  # mechanism. Built from parts so this assertion itself doesn't false-trigger
  # by containing the literal banned phrase.
  local rejected_phrase
  rejected_phrase="exactly one m""v succeeds"
  ! grep -qF "$rejected_phrase" "$BATS_TEST_FILENAME"
}

@test "common.sh lock-usage comment teaches a safe release pattern, not the hazardous trap+explicit double-release" {
  # The old comment showed:
  #   if bugsweep_lock_acquire ...; then
  #     trap 'bugsweep_lock_release "$lockdir"' EXIT
  #     ...
  #     bugsweep_lock_release "$lockdir"
  #   fi
  # bugsweep_lock_release force-clears whatever CURRENTLY holds the path, so a
  # trap that fires AFTER the explicit release (e.g. on a later, unrelated
  # exit path) can destroy a subsequent holder's lock. The usage comment must
  # no longer show both a trap-release and an explicit release for the same
  # acquire with no guard between them.
  local usage_block
  usage_block="$(sed -n '/mkdir-based mutual exclusion/,/^bugsweep_lock_acquire()/p' "$COMMON_SH")"
  [ -n "$usage_block" ]
  echo "$usage_block" | grep -q '^# Usage:'

  # Must not show the trap firing unconditionally alongside an explicit release.
  if echo "$usage_block" | grep -q "trap 'bugsweep_lock_release"; then
    # If a trap is still shown, it must be guarded (e.g. a sentinel variable)
    # so it no-ops after the explicit release — not fired unconditionally.
    echo "$usage_block" | grep -qE '(released|done|guard)' \
      || { echo "usage comment shows an unguarded trap + explicit release:" >&2; echo "$usage_block" >&2; false; }
  fi
}
