#!/usr/bin/env bats
#
# Tests for scripts/state.sh concurrency safety (bugsweep-p74):
#  - 5 concurrent `state.sh persist` runs must NOT corrupt meta.json's run count
#    (ordinal computed inside the lock's critical section, not read-before-lock).
#  - 5 concurrent persists must not lose audit-log / risk-log lines.
#  - Per-run leases: N coexist at once (not a mutex), a stale lease (dead pid /
#    old timestamp) is reclaimed, and lease-release removes a live lease.

STATE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/state.sh"

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  git -C "$dir" commit --allow-empty -m "init" -q
}

# A minimal run dir with one covered batch containing one file, so `persist`
# has something concrete to harvest into audit-log/risk each time.
_make_run_dir() {
  local run_dir="$1" ts="$2" file="$3"
  mkdir -p "$run_dir"
  cat > "${run_dir}/state.env" <<ENV
BUGSWEEP_TS=${ts}
BUGSWEEP_RUN_DIR=${run_dir}
BUGSWEEP_BRANCH=bugsweep/${ts}
ENV
  cat > "${run_dir}/recon.json" <<JSON
{"batches":[{"id":1,"files":["${file}"]}],"covered":[1]}
JSON
  cat > "${run_dir}/ledger.jsonl" <<LEDGER
{"event":"preflight","ts":"${ts}"}
{"event":"batch_covered","batch":1}
{"event":"fix_committed","file":"${file}","severity":"high"}
LEDGER
}

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  cd "$REPO"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

# ---------------------------------------------------------------------------
# meta.json run-count correctness under concurrency
# ---------------------------------------------------------------------------

@test "state.sh persist: 5 concurrent runs produce meta.json runs == prior + 5" {
  # Seed one prior run so we're asserting increments, not just starting from 0.
  local seed_dir="${BATS_TMP}/run-seed"
  _make_run_dir "$seed_dir" "seed" "seed.txt"
  run bash "$STATE_SH" persist "$seed_dir"
  [ "$status" -eq 0 ]

  local prior_runs
  prior_runs="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("runs",0))' \
    "${REPO}/.bugsweep/state/meta.json")"

  local pids=""
  for i in 1 2 3 4 5; do
    local rd="${BATS_TMP}/run-${i}"
    _make_run_dir "$rd" "ts${i}" "file${i}.txt"
    ( bash "$STATE_SH" persist "$rd" >"${BATS_TMP}/persist-out-${i}.log" 2>&1 ) &
    pids="$pids $!"
  done
  local rc=0
  for p in $pids; do
    wait "$p" || rc=1
  done
  [ "$rc" -eq 0 ]

  local final_runs
  final_runs="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("runs",0))' \
    "${REPO}/.bugsweep/state/meta.json")"

  [ "$final_runs" -eq $((prior_runs + 5)) ]
}

@test "state.sh persist: 5 concurrent runs lose no audit-log or risk-log lines" {
  local pids=""
  for i in 1 2 3 4 5; do
    local rd="${BATS_TMP}/run-${i}"
    _make_run_dir "$rd" "ts${i}" "file${i}.txt"
    ( bash "$STATE_SH" persist "$rd" >"${BATS_TMP}/persist-out-${i}.log" 2>&1 ) &
    pids="$pids $!"
  done
  local rc=0
  for p in $pids; do
    wait "$p" || rc=1
  done
  [ "$rc" -eq 0 ]

  local audit_log="${REPO}/.bugsweep/state/audit-log.jsonl"
  local risk_log="${REPO}/.bugsweep/state/risk.jsonl"
  [ -f "$audit_log" ]
  [ -f "$risk_log" ]

  # Each of the 5 runs covered exactly one distinct file (file1..file5) — all must
  # be present in the audit log, and every audit-log line must be valid JSON (no
  # interleaved/torn writes from concurrent appenders).
  for i in 1 2 3 4 5; do
    grep -q "\"file${i}.txt\"" "$audit_log"
    grep -q "\"file${i}.txt\"" "$risk_log"
  done

  # No line is truncated/corrupted: every non-empty line parses as JSON.
  python3 - "$audit_log" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        json.loads(line)  # raises if a line got torn/interleaved
PY
  python3 - "$risk_log" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        json.loads(line)
PY

  # Exactly 5 risk lines (one fix_committed per run) — none dropped, none duplicated.
  local risk_lines
  risk_lines="$(wc -l < "$risk_log" | tr -d ' ')"
  [ "$risk_lines" -eq 5 ]
}

# ---------------------------------------------------------------------------
# Leases: coexist, stale reclaim, release
# ---------------------------------------------------------------------------

@test "state.sh lease-acquire: N leases coexist simultaneously (not a mutex)" {
  local rd1="${BATS_TMP}/run-a" rd2="${BATS_TMP}/run-b" rd3="${BATS_TMP}/run-c"
  mkdir -p "$rd1" "$rd2" "$rd3"

  # BUGSWEEP_LEASE_PID pins the lease's liveness pid to THIS bats test process
  # (which stays alive for the whole test), simulating the long-lived shell/
  # subagent session that owns a run end-to-end. A bare `bash state.sh ...`
  # invocation exits the instant the command returns, so without this override
  # every lease would look dead moments after being written — this override is
  # exactly the mechanism a real orchestrator uses to record its own pid.
  run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd1"
  [ "$status" -eq 0 ]
  run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd2"
  [ "$status" -eq 0 ]
  run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd3"
  [ "$status" -eq 0 ]

  run bash "$STATE_SH" lease-list
  [ "$status" -eq 0 ]
  local n
  n="$(echo "$output" | grep -c '^LEASE=' || true)"
  [ "$n" -eq 3 ]
}

@test "state.sh lease-acquire: a stale lease (dead pid + past grace window) is reclaimed" {
  local rd="${BATS_TMP}/run-stale"
  mkdir -p "$rd"

  # Manufacture a stale lease: a pid that cannot be alive AND a lease file whose
  # mtime is far older than the reclaim grace window. Both are required — a dead
  # pid alone is normal (the recording shell legitimately exits before the run
  # ends), so only dead-pid + old-file may be reclaimed.
  local leases_dir="${REPO}/.bugsweep/state/leases"
  mkdir -p "$leases_dir"
  local dead_pid=999999
  cat > "${leases_dir}/stale-run.json" <<JSON
{"pid": ${dead_pid}, "run_dir": "${rd}", "started": 1}
JSON
  touch -t 202001010000 "${leases_dir}/stale-run.json"

  run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd"
  [ "$status" -eq 0 ]

  # The stale lease file must be gone (reclaimed), replaced by this run's own lease.
  [ ! -f "${leases_dir}/stale-run.json" ]
  run bash "$STATE_SH" lease-list
  echo "$output" | grep -q "$rd"
}

@test "state.sh lease-list: dead-pid lease within the grace window is NOT reclaimed" {
  # BLOCKER B (bugsweep-p74 review): in the real invocation path the pid recorded
  # in the lease dies the moment preflight exits, while the run itself is still
  # in-flight. A dead pid with a FRESH lease file must therefore survive
  # lease-list's reclaim pass — only dead-pid + old-mtime is reclaimable.
  local rd="${BATS_TMP}/run-fresh-dead"
  mkdir -p "$rd"
  local leases_dir="${REPO}/.bugsweep/state/leases"
  mkdir -p "$leases_dir"
  cat > "${leases_dir}/fresh-dead.json" <<JSON
{"pid": 999999, "run_dir": "${rd}", "started": $(date +%s)}
JSON

  run bash "$STATE_SH" lease-list
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$rd"
  [ -f "${leases_dir}/fresh-dead.json" ]
}

@test "state.sh lease-release: releases a live lease so it no longer appears in lease-list" {
  local rd="${BATS_TMP}/run-release"
  mkdir -p "$rd"

  run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd"
  [ "$status" -eq 0 ]
  run bash "$STATE_SH" lease-list
  echo "$output" | grep -q "$rd"

  run bash "$STATE_SH" lease-release "$rd"
  [ "$status" -eq 0 ]

  run bash "$STATE_SH" lease-list
  ! echo "$output" | grep -q "$rd"
}

@test "finalize.sh releases the lease it acquired during preflight" {
  FINALIZE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/finalize.sh"
  local rd="${BATS_TMP}/run-finalize"
  local ts="20991231T111111Z"
  local branch="bugsweep/${ts}"
  git -C "$REPO" checkout -b "$branch" -q
  mkdir -p "$rd"
  cat > "${rd}/state.env" <<ENV
BUGSWEEP_TS="${ts}"
BUGSWEEP_BRANCH="${branch}"
BUGSWEEP_ORIG_BRANCH="master"
BUGSWEEP_STASH_REF="none"
BUGSWEEP_START_EPOCH="$(date +%s)"
BUGSWEEP_SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"
ENV
  touch "${rd}/ledger.jsonl"

  run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd"
  [ "$status" -eq 0 ]
  run bash "$STATE_SH" lease-list
  echo "$output" | grep -q "$rd"

  run bash "$FINALIZE_SH" "$rd"
  [ "$status" -eq 0 ]

  run bash "$STATE_SH" lease-list
  ! echo "$output" | grep -q "$rd"
}

# ---------------------------------------------------------------------------
# Lease heartbeat (bugsweep-re9): no heartbeat refreshes lease mtime mid-run,
# so any run longer than BUGSWEEP_LEASE_GRACE_SECONDS (default 900s) loses its
# lease on a sibling's reclaim pass even while genuinely still in-flight. A
# `lease-touch` subcommand lets long-lived callers (guard.sh's per-iteration
# loop, state.sh persist) refresh the lease file's mtime without recreating a
# lease that was never acquired (it must be a no-op, never a create, for a
# run_dir with no lease file).
# ---------------------------------------------------------------------------

@test "state.sh lease-touch: refreshes mtime of an existing lease, surviving past the grace window" {
  local rd="${BATS_TMP}/run-heartbeat"
  mkdir -p "$rd"
  run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd"
  [ "$status" -eq 0 ]

  local leases_dir="${REPO}/.bugsweep/state/leases"
  local id lease_file
  id="$(basename "$rd" | tr -c 'A-Za-z0-9._-' '_')"
  lease_file="${leases_dir}/${id}.json"
  [ -f "$lease_file" ]

  # Simulate the lease aging PAST the grace window (default 900s) without a heartbeat.
  touch -t 202001010000 "$lease_file"
  local aged_mtime
  aged_mtime="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$lease_file")"

  # Heartbeat: touch the lease. mtime must move forward to "now".
  run bash "$STATE_SH" lease-touch "$rd"
  [ "$status" -eq 0 ]
  local touched_mtime
  touched_mtime="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$lease_file")"
  [ "$touched_mtime" -gt "$aged_mtime" ]

  # Even with a DEAD recorded pid, a lease touched within the grace window must
  # NOT be reclaimed by a lease-list pass — this is the whole point of the
  # heartbeat: liveness now flows from "was this touched recently", not solely
  # from "is the recorded pid still running" (which is false in every
  # Bash-tool-per-call agent flow).
  python3 -c '
import json
d = json.load(open("'"$lease_file"'"))
d["pid"] = 999999
json.dump(d, open("'"$lease_file"'", "w"))
'
  touch "$lease_file"

  run bash "$STATE_SH" lease-list
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$rd"
  [ -f "$lease_file" ]
}

@test "state.sh lease-touch: dead pid + no touch past the grace window is still reclaimed (regression guard)" {
  # This is the pre-existing behavior (already covered above by the
  # dead-pid+old-mtime reclaim test) — re-asserted here so a heartbeat
  # implementation cannot accidentally make ALL dead-pid leases immortal.
  local rd="${BATS_TMP}/run-heartbeat-none"
  mkdir -p "$rd"
  local leases_dir="${REPO}/.bugsweep/state/leases"
  mkdir -p "$leases_dir"
  cat > "${leases_dir}/no-heartbeat.json" <<JSON
{"pid": 999999, "run_dir": "${rd}", "started": 1}
JSON
  touch -t 202001010000 "${leases_dir}/no-heartbeat.json"

  run bash "$STATE_SH" lease-list
  [ "$status" -eq 0 ]
  [ ! -f "${leases_dir}/no-heartbeat.json" ]
}

@test "state.sh lease-touch: is a no-op for a run_dir with no existing lease (never creates one)" {
  local rd="${BATS_TMP}/run-never-leased"
  mkdir -p "$rd"
  local leases_dir="${REPO}/.bugsweep/state/leases"

  run bash "$STATE_SH" lease-touch "$rd"
  [ "$status" -eq 0 ]

  local id lease_file
  id="$(basename "$rd" | tr -c 'A-Za-z0-9._-' '_')"
  lease_file="${leases_dir}/${id}.json"
  [ ! -f "$lease_file" ]
}

@test "guard.sh: touches the lease mtime on each invocation without changing STOP/CONTINUE output" {
  GUARD_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/guard.sh"
  local rd="${BATS_TMP}/run-guard-heartbeat"
  mkdir -p "$rd"
  cat > "${rd}/state.env" <<ENV
BUGSWEEP_START_EPOCH=$(date +%s)
ENV
  : > "${rd}/ledger.jsonl"

  run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd"
  [ "$status" -eq 0 ]

  local leases_dir="${REPO}/.bugsweep/state/leases"
  local id lease_file
  id="$(basename "$rd" | tr -c 'A-Za-z0-9._-' '_')"
  lease_file="${leases_dir}/${id}.json"
  [ -f "$lease_file" ]
  touch -t 202001010000 "$lease_file"
  local before_mtime
  before_mtime="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$lease_file")"

  run bash "$GUARD_SH" "$rd"
  [ "$status" -eq 0 ]
  [[ "$output" == CONTINUE* ]]

  local after_mtime
  after_mtime="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$lease_file")"
  [ "$after_mtime" -gt "$before_mtime" ]
}

# ---------------------------------------------------------------------------
# Lease heartbeat hardening (bugsweep-re9 retry 1 — adversarial review).
# ---------------------------------------------------------------------------

@test "state.sh lease-touch: racing touch against a concurrent lease-release never leaves a zombie lease" {
  # BLOCKER 1: `touch` CREATES the file if absent. If lease-release (lock-guarded)
  # deletes the lease between lease-touch's existence check and its `touch`, an
  # unguarded touch recreates a 0-byte zombie lease (no pid/run_dir/started, fresh
  # mtime) that then survives the whole grace window.
  #
  # BUGSWEEP_LEASE_TOUCH_RACE_SLEEP forces the check→act window open
  # deterministically (the same way the reviewer reproduced it — "a sleep in the
  # window"). We fire lease-touch WITH that sleep, then run lease-release while
  # touch is parked mid-window, then let touch proceed. Under the unguarded
  # implementation the touch lands AFTER release deleted the file and recreates
  # a zombie. A correctly locked lease-touch (or a re-check under lock) cannot,
  # because release holds the leases lock across its delete.
  local trial rc_any=0
  for trial in $(seq 1 8); do
    local rd="${BATS_TMP}/run-race-${trial}"
    mkdir -p "$rd"
    run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd"
    [ "$status" -eq 0 ]

    local id lease_file
    id="$(basename "$rd" | tr -c 'A-Za-z0-9._-' '_')"
    lease_file="${REPO}/.bugsweep/state/leases/${id}.json"
    [ -f "$lease_file" ]

    # touch parks inside the check→act window for ~0.4s...
    env BUGSWEEP_LEASE_PID="$$" BUGSWEEP_LEASE_TOUCH_RACE_SLEEP=0.4 \
      bash "$STATE_SH" lease-touch "$rd" >/dev/null 2>&1 &
    local tpid=$!
    # ...give it time to pass its existence check and park...
    sleep 0.15
    # ...then release deletes the lease while touch is still parked...
    bash "$STATE_SH" lease-release "$rd" >/dev/null 2>&1
    # ...and now touch wakes and completes.
    wait "$tpid" || rc_any=1

    # After release, NO lease file for this run may remain — a zombie recreated
    # by an unguarded touch-after-delete is the exact bug under test.
    if [ -f "$lease_file" ]; then
      echo "ZOMBIE lease survived trial ${trial}: $(cat "$lease_file" 2>/dev/null || echo '<unreadable>')" >&2
      false
    fi
  done
  [ "$rc_any" -eq 0 ]

  # lease-list must still exit 0 even with whatever files remain.
  run bash "$STATE_SH" lease-list
  [ "$status" -eq 0 ]
}

@test "state.sh lease-list: exits 0 even when a 0-byte/empty lease file is present" {
  # MAJOR 2 (defensive): lease_list's exit status must not be the last loop
  # iteration's `[ -n "$run_dir" ] && echo` — an empty lease file (no run_dir)
  # would otherwise make the whole command exit 1.
  local leases_dir="${REPO}/.bugsweep/state/leases"
  mkdir -p "$leases_dir"
  # A fresh, empty file with a live-looking mtime: not reclaimed by the stale
  # pass, has no run_dir, and is the LAST (only) file iterated.
  : > "${leases_dir}/empty.json"

  run bash "$STATE_SH" lease-list
  [ "$status" -eq 0 ]
}

@test "state.sh persist: does NOT touch the lease (persist runs once at finalize, not per-iteration)" {
  # MAJOR 2: persist() is invoked exactly once per run (finalize.sh:26), five
  # lines before lease-release. A lease-touch there refreshes a lease that is
  # about to be deleted and gives ZERO mid-run protection — guard.sh is the sole
  # per-iteration heartbeat. persist() must not call lease-touch at all.
  #
  # Assert structurally (persist's code path never invokes lease_touch) rather
  # than behaviorally: seed a lease with an OLD mtime, run persist, and require
  # the mtime to be UNCHANGED afterward.
  local rd="${BATS_TMP}/run-persist-no-touch"
  _make_run_dir "$rd" "pnt" "pnt.txt"

  run env BUGSWEEP_LEASE_PID="$$" bash "$STATE_SH" lease-acquire "$rd"
  [ "$status" -eq 0 ]
  local id lease_file
  id="$(basename "$rd" | tr -c 'A-Za-z0-9._-' '_')"
  lease_file="${REPO}/.bugsweep/state/leases/${id}.json"
  [ -f "$lease_file" ]
  touch -t 202001010000 "$lease_file"
  local before_mtime
  before_mtime="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$lease_file")"

  run bash "$STATE_SH" persist "$rd"
  [ "$status" -eq 0 ]

  local after_mtime
  after_mtime="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$lease_file")"
  [ "$after_mtime" -eq "$before_mtime" ]
}

@test "state.sh source: persist() body contains no lease_touch call" {
  # Belt-and-suspenders for MAJOR 2: grep the persist() function body directly so
  # the intent can't silently regress even if the mtime assertion above were
  # ever weakened. Extract persist()'s body and assert no lease_touch within it.
  local persist_body
  persist_body="$(sed -n '/^persist() {/,/^}/p' "$STATE_SH")"
  [ -n "$persist_body" ]
  ! echo "$persist_body" | grep -q 'lease_touch'
}

# ---------------------------------------------------------------------------
# No-python fallback path (review BLOCKER A, bugsweep-p74)
# ---------------------------------------------------------------------------

@test "state.sh persist (no-python fallback): concurrent persists never clobber the meta.json run count" {
  # BUGSWEEP_NO_PYTHON forces the degraded shell path in the scripts under test
  # (the test itself still uses python3 freely to verify). The FIRST process is
  # given a big ledger so it deterministically finishes LAST — under the old bug
  # (_persist_fallback rewrote meta.json OUTSIDE the lock, after the ordinal had
  # already been reserved+persisted inside it) that last unlocked write would
  # clobber the counter back to this process's own early ordinal.
  local big="${BATS_TMP}/run-big"
  mkdir -p "$big"
  printf 'BUGSWEEP_TS=big\n' > "${big}/state.env"
  : > "${big}/ledger.jsonl"
  local i
  # 1500 matching lines make the big run's fallback take seconds (measured
  # ~2.5ms/line) while each small persist takes ~30ms — so the big run reliably
  # reserves FIRST (ordinal 1) and finishes LAST, which is exactly the
  # interleaving that exposed the unlocked meta.json rewrite.
  for i in $(seq 1 1500); do
    printf '{"event":"fix_committed","file":"big-%s.txt","severity":"low"}\n' "$i" >> "${big}/ledger.jsonl"
  done

  ( env BUGSWEEP_NO_PYTHON=1 bash "$STATE_SH" persist "$big" >"${BATS_TMP}/nopy-big.log" 2>&1 ) &
  local pids="$!"
  sleep 0.3  # let the big run reserve its ordinal first; it stays busy for seconds after
  for i in 1 2 3 4; do
    local rd="${BATS_TMP}/run-nopy-${i}"
    _make_run_dir "$rd" "nopy${i}" "nopy-file${i}.txt"
    ( env BUGSWEEP_NO_PYTHON=1 bash "$STATE_SH" persist "$rd" >"${BATS_TMP}/nopy-${i}.log" 2>&1 ) &
    pids="$pids $!"
  done
  local rc=0 p
  for p in $pids; do
    wait "$p" || rc=1
  done
  [ "$rc" -eq 0 ]

  local runs
  runs="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("runs",0))' \
    "${REPO}/.bugsweep/state/meta.json")"
  [ "$runs" -eq 5 ]

  # Zero lost risk lines: 1500 from the big run + 1 each from the other four.
  local risk_lines
  risk_lines="$(wc -l < "${REPO}/.bugsweep/state/risk.jsonl" | tr -d ' ')"
  [ "$risk_lines" -eq 1504 ]
}

@test "state.sh persist: python-harvest failure fallback does not rewrite meta.json" {
  # Deterministic single-process variant of BLOCKER A. Seed meta.json with an
  # extra canary key: the locked (python) ordinal reserve preserves unknown
  # keys, so if the canary survives persist, meta.json was NOT rewritten by the
  # unlocked shell fallback. The harvest is made to throw mid-flight by turning
  # the audit-log path into a directory (os.open fails EISDIR), which is one of
  # the real production triggers for the fallback path.
  local state_dir="${REPO}/.bugsweep/state"
  mkdir -p "$state_dir"
  printf '{"schema":1,"runs":7,"canary":"keepme"}\n' > "${state_dir}/meta.json"
  mkdir -p "${state_dir}/audit-log.jsonl"

  local rd="${BATS_TMP}/run-pyfail"
  _make_run_dir "$rd" "pyfail" "pyfail.txt"
  run bash "$STATE_SH" persist "$rd"
  [ "$status" -eq 0 ]

  python3 - "${state_dir}/meta.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("runs") == 8, d
assert d.get("canary") == "keepme", d
PY
}

# ---------------------------------------------------------------------------
# Loud degraded path (review MINOR G, bugsweep-p74)
# ---------------------------------------------------------------------------

@test "state.sh persist: appends state_lock_timeout ledger event when the meta lock stays busy" {
  local rd="${BATS_TMP}/run-locked"
  _make_run_dir "$rd" "locked" "locked.txt"
  local state_dir="${REPO}/.bugsweep/state"
  mkdir -p "${state_dir}/meta.lock"
  printf '%s' "$$" > "${state_dir}/meta.lock/pid"   # live holder: cannot be reclaimed

  run env BUGSWEEP_META_LOCK_TIMEOUT=2 bash "$STATE_SH" persist "$rd"
  [ "$status" -eq 0 ]

  # The degraded unlocked-ordinal path must be visible in the run's own ledger,
  # not just a stderr line nobody persists.
  grep -q '"event":"state_lock_timeout"' "${rd}/ledger.jsonl"

  rm -rf "${state_dir}/meta.lock"
}
