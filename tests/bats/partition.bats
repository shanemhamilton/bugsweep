#!/usr/bin/env bats
#
# Tests for scripts/partition.sh (bugsweep-wbg): partitioning the risk-ranked
# frontier across N concurrent bugsweep subagents so they cover DISJOINT
# batches instead of all racing to the same highest-risk files first.
#
#  - `shard`: deterministic pre-partition — batch i (0-based position in the
#    frontier) -> shard (i mod N). Disjoint across shards; union == frontier;
#    same inputs always produce the same output.
#  - `claim`: atomic self-claim of the next unclaimed batch id, via `mkdir` of
#    a per-batch claim directory (the same atomic primitive as common.sh's
#    bugsweep_lock_acquire). A 5-way concurrent claim storm must never
#    double-claim a batch, must claim every batch exactly once, and must
#    leave no batch unclaimable.

PARTITION_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/partition.sh"

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  git -C "$dir" commit --allow-empty -m "init" -q
}

# Writes a recon.json fixture with $1 batches (ids 1..$1), one file per batch,
# into run dir $2. Mirrors the schema documented in prompts/context-build.md.
_make_recon_fixture() {
  local n="$1" run_dir="$2" i
  mkdir -p "$run_dir"
  {
    printf '{\n  "files_in_scope": %s,\n  "batch_count": %s,\n  "batches": [\n' "$n" "$n"
    # BSD `seq 1 0` counts DOWN (prints "1\n0"), unlike GNU seq which prints
    # nothing for an empty range — guard n=0 explicitly so this fixture
    # builder behaves the same on macOS and Linux.
    if [ "$n" -gt 0 ]; then
      for i in $(seq 1 "$n"); do
        printf '    {"id": %s, "dir": "pkg%s", "tier": "normal", "deferred": false, "files": ["pkg%s/file.go"]}' "$i" "$i" "$i"
        [ "$i" -lt "$n" ] && printf ',\n' || printf '\n'
      done
    fi
    printf '  ],\n  "covered": []\n}\n'
  } > "${run_dir}/recon.json"
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
# frontier
# ---------------------------------------------------------------------------

@test "partition.sh frontier: lists batch ids in recon.json order" {
  local rd="${BATS_TMP}/run-frontier"
  _make_recon_fixture 4 "$rd"

  run bash "$PARTITION_SH" frontier "$rd"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\n2\n3\n4')" ]
}

@test "partition.sh frontier: falls back to generating a plan when no recon.json/recon-plan.json exists" {
  local rd="${BATS_TMP}/run-nofrontier"
  mkdir -p "$rd"
  printf 'x' > "${REPO}/a.txt"
  printf 'y' > "${REPO}/b.txt"
  git -C "$REPO" add a.txt b.txt
  git -C "$REPO" commit -q -m "seed files"

  run bash "$PARTITION_SH" frontier "$rd"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -f "${rd}/recon-plan.json" ]
}

@test "partition.sh frontier: reads recon-plan.json directly when recon.json has not been seeded yet" {
  local rd="${BATS_TMP}/run-planonly"
  mkdir -p "$rd"
  cat > "${rd}/recon-plan.json" <<'JSON'
{"schema_version":1,"files_in_scope":2,"batch_count":2,"batches":[{"id":1,"dir":"a","tier":"normal","deferred":false,"files":["a/x.go"]},{"id":2,"dir":"b","tier":"normal","deferred":false,"files":["b/y.go"]}],"covered":[]}
JSON

  run bash "$PARTITION_SH" frontier "$rd"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\n2')" ]
}

@test "partition.sh frontier: recon.json takes precedence over recon-plan.json when both exist" {
  local rd="${BATS_TMP}/run-both"
  _make_recon_fixture 2 "$rd"
  cat > "${rd}/recon-plan.json" <<'JSON'
{"schema_version":1,"files_in_scope":9,"batch_count":9,"batches":[{"id":97,"dir":"z","tier":"normal","deferred":false,"files":["z/z.go"]}],"covered":[]}
JSON

  run bash "$PARTITION_SH" frontier "$rd"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\n2')" ]
}

@test "partition.sh frontier: exits non-zero on a missing/invalid RUN_DIR" {
  run bash "$PARTITION_SH" frontier "${BATS_TMP}/does-not-exist"
  [ "$status" -ne 0 ]
  run bash "$PARTITION_SH" frontier
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# shard: deterministic disjoint pre-partition, union == frontier
# ---------------------------------------------------------------------------

@test "partition.sh shard: N shards are pairwise disjoint and their union is exactly the frontier" {
  local rd="${BATS_TMP}/run-shard"
  _make_recon_fixture 17 "$rd"
  local n=5 i

  : > "${BATS_TMP}/all-shards.txt"
  for i in 0 1 2 3 4; do
    run bash "$PARTITION_SH" shard "$rd" "$n" "$i"
    [ "$status" -eq 0 ]
    echo "$output" > "${BATS_TMP}/shard-${i}.txt"
    sed '/^$/d' "${BATS_TMP}/shard-${i}.txt" >> "${BATS_TMP}/all-shards.txt"
  done

  # Union: exactly ids 1..17, each appearing once across ALL shards combined.
  local union_sorted expected
  union_sorted="$(sort -n "${BATS_TMP}/all-shards.txt" | tr '\n' ' ')"
  expected="$(seq 1 17 | tr '\n' ' ')"
  [ "$union_sorted" = "$expected" ]

  # Pairwise disjoint: no id appears in two different shard files.
  local dupes
  dupes="$(sort -n "${BATS_TMP}/all-shards.txt" | uniq -d)"
  [ -z "$dupes" ]
}

@test "partition.sh shard: is deterministic given the same N + frontier" {
  local rd="${BATS_TMP}/run-determinism"
  _make_recon_fixture 13 "$rd"

  run bash "$PARTITION_SH" shard "$rd" 4 2
  [ "$status" -eq 0 ]
  local first="$output"

  run bash "$PARTITION_SH" shard "$rd" 4 2
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]

  # A second, independently-built fixture with IDENTICAL batch ids/order must
  # produce the SAME shard assignment (determinism is a function of the
  # frontier's content, not incidental filesystem/process state).
  local rd2="${BATS_TMP}/run-determinism-2"
  _make_recon_fixture 13 "$rd2"
  run bash "$PARTITION_SH" shard "$rd2" 4 2
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
}

@test "partition.sh shard: rejects an out-of-range shard index" {
  local rd="${BATS_TMP}/run-badindex"
  _make_recon_fixture 3 "$rd"
  run bash "$PARTITION_SH" shard "$rd" 3 3
  [ "$status" -ne 0 ]
}

@test "partition.sh shard: rejects a non-numeric N, a non-numeric INDEX, N=0, and missing args" {
  local rd="${BATS_TMP}/run-badargs"
  _make_recon_fixture 3 "$rd"
  run bash "$PARTITION_SH" shard "$rd" nope 0
  [ "$status" -ne 0 ]
  run bash "$PARTITION_SH" shard "$rd" 3 nope
  [ "$status" -ne 0 ]
  run bash "$PARTITION_SH" shard "$rd" 0 0
  [ "$status" -ne 0 ]
  run bash "$PARTITION_SH" shard "$rd" 3
  [ "$status" -ne 0 ]
}

@test "partition.sh shard: an empty frontier yields an empty shard for every index" {
  local rd="${BATS_TMP}/run-empty"
  _make_recon_fixture 0 "$rd"
  run bash "$PARTITION_SH" shard "$rd" 3 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# claim: atomic self-claim
# ---------------------------------------------------------------------------

@test "partition.sh claim: claims batches one at a time in frontier order until exhausted" {
  local rd="${BATS_TMP}/run-claim-seq"
  _make_recon_fixture 3 "$rd"

  run bash "$PARTITION_SH" claim run-seq "$rd" workerA
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIMED_BATCH=1" ]

  run bash "$PARTITION_SH" claim run-seq "$rd" workerA
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIMED_BATCH=2" ]

  run bash "$PARTITION_SH" claim run-seq "$rd" workerA
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIMED_BATCH=3" ]

  run bash "$PARTITION_SH" claim run-seq "$rd" workerA
  [ "$status" -eq 0 ]
  [ "$output" = "NO_BATCHES_LEFT=1" ]
}

@test "partition.sh claim: different RUN_IDs do not collide (same batch claimable under each)" {
  local rd="${BATS_TMP}/run-claim-isolated"
  _make_recon_fixture 1 "$rd"

  run bash "$PARTITION_SH" claim run-a "$rd" workerA
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIMED_BATCH=1" ]

  run bash "$PARTITION_SH" claim run-b "$rd" workerA
  [ "$status" -eq 0 ]
  [ "$output" = "CLAIMED_BATCH=1" ]
}

@test "partition.sh claims: lists claimed batch ids for a RUN_ID" {
  local rd="${BATS_TMP}/run-claim-list"
  _make_recon_fixture 2 "$rd"
  bash "$PARTITION_SH" claim run-list "$rd" workerA >/dev/null
  bash "$PARTITION_SH" claim run-list "$rd" workerA >/dev/null

  run bash "$PARTITION_SH" claims run-list
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'CLAIM=1'
  echo "$output" | grep -qx 'CLAIM=2'
}

@test "partition.sh claims: exits 0 with empty output for a RUN_ID that has claimed nothing yet" {
  run bash "$PARTITION_SH" claims run-never-claimed
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "partition.sh claim: rejects missing RUN_ID or RUN_DIR" {
  run bash "$PARTITION_SH" claim
  [ "$status" -ne 0 ]
  run bash "$PARTITION_SH" claim run-x
  [ "$status" -ne 0 ]
  run bash "$PARTITION_SH" claim run-x "${BATS_TMP}/does-not-exist"
  [ "$status" -ne 0 ]
}

@test "partition.sh claim: outside a git repo, degrades to NO_BATCHES_LEFT instead of failing" {
  local nogit="${BATS_TMP}/no-git-here"
  local rd="${nogit}/run-x"
  mkdir -p "$rd"
  _make_recon_fixture 3 "$rd"

  cd "$nogit"
  run bash "$PARTITION_SH" claim run-nogit "$rd" workerA
  cd "$REPO"
  [ "$status" -eq 0 ]
  # `run` merges stderr into $output, and the degraded path logs a warning
  # there — match on the stdout contract (the last line) rather than the
  # whole combined stream.
  [ "$(echo "$output" | tail -1)" = "NO_BATCHES_LEFT=1" ]
}

@test "partition.sh: unknown subcommand exits non-zero" {
  run bash "$PARTITION_SH" bogus-command
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# claim: 5-way atomic concurrency — the core race-safety guarantee
# ---------------------------------------------------------------------------

@test "partition.sh claim: 5 concurrent claimers never double-claim a batch, and claim every batch exactly once" {
  local rd="${BATS_TMP}/run-claim-storm"
  local m=20
  _make_recon_fixture "$m" "$rd"
  local run_id="storm-run"

  local worker="${BATS_TMP}/claim-worker.sh"
  cat > "$worker" <<WORKER
#!/usr/bin/env bash
set -euo pipefail
partition="\$1"; run_id="\$2"; rd="\$3"; owner="\$4"; out="\$5"
: > "\$out"
while true; do
  line="\$(bash "\$partition" claim "\$run_id" "\$rd" "\$owner")"
  case "\$line" in
    CLAIMED_BATCH=*) echo "\${line#CLAIMED_BATCH=}" >> "\$out" ;;
    NO_BATCHES_LEFT=*) break ;;
    *) echo "UNEXPECTED_OUTPUT:\$line" >> "\$out"; break ;;
  esac
done
WORKER

  local pids="" i
  for i in 1 2 3 4 5; do
    ( bash "$worker" "$PARTITION_SH" "$run_id" "$rd" "worker-${i}" "${BATS_TMP}/claimed-${i}.txt" ) &
    pids="$pids $!"
  done
  local rc=0 p
  for p in $pids; do
    wait "$p" || rc=1
  done
  [ "$rc" -eq 0 ]

  # No worker saw unexpected output.
  for i in 1 2 3 4 5; do
    ! grep -q 'UNEXPECTED_OUTPUT' "${BATS_TMP}/claimed-${i}.txt"
  done

  cat "${BATS_TMP}/claimed-1.txt" "${BATS_TMP}/claimed-2.txt" "${BATS_TMP}/claimed-3.txt" \
      "${BATS_TMP}/claimed-4.txt" "${BATS_TMP}/claimed-5.txt" > "${BATS_TMP}/all-claimed.txt"

  # Total claims across all workers == M (none lost, none unclaimable).
  local total
  total="$(wc -l < "${BATS_TMP}/all-claimed.txt" | tr -d ' ')"
  [ "$total" -eq "$m" ]

  # Every id 1..M appears, and appears EXACTLY once (no double-claim across workers).
  local sorted expected
  sorted="$(sort -n "${BATS_TMP}/all-claimed.txt" | tr '\n' ' ')"
  expected="$(seq 1 "$m" | tr '\n' ' ')"
  [ "$sorted" = "$expected" ]

  local dupes
  dupes="$(sort -n "${BATS_TMP}/all-claimed.txt" | uniq -d)"
  [ -z "$dupes" ]

  # The on-disk registry agrees: exactly M lines, one per batch, all unique.
  local registry="${REPO}/.bugsweep/state/claims-${run_id}.jsonl"
  [ -f "$registry" ]
  local registry_lines
  registry_lines="$(wc -l < "$registry" | tr -d ' ')"
  [ "$registry_lines" -eq "$m" ]
  local registry_batches
  registry_batches="$(grep -o '"batch":[0-9]*' "$registry" | grep -o '[0-9]*' | sort -n | uniq -d)"
  [ -z "$registry_batches" ]

  # And the claim directories themselves (the atomic ground truth) agree too.
  local claim_dir_count
  claim_dir_count="$(find "${REPO}/.bugsweep/state/claims-${run_id}.d" -maxdepth 1 -type d -name 'batch-*.claim' | wc -l | tr -d ' ')"
  [ "$claim_dir_count" -eq "$m" ]
}

@test "partition.sh claim: 25 concurrent claimers over a 6-batch frontier — no double-claim, exactly 6 winners total" {
  # Harder contention ratio: more claimers than batches, so most calls race for
  # the SAME dwindling set of ids. Asserts the same invariants under heavier load.
  local rd="${BATS_TMP}/run-claim-storm2"
  local m=6
  _make_recon_fixture "$m" "$rd"
  local run_id="storm-run-2"

  local worker="${BATS_TMP}/claim-worker2.sh"
  cat > "$worker" <<WORKER
#!/usr/bin/env bash
set -euo pipefail
partition="\$1"; run_id="\$2"; rd="\$3"; owner="\$4"; out="\$5"
line="\$(bash "\$partition" claim "\$run_id" "\$rd" "\$owner")"
echo "\$line" >> "\$out"
WORKER

  : > "${BATS_TMP}/storm2-out.txt"
  local pids="" i
  for i in $(seq 1 25); do
    ( bash "$worker" "$PARTITION_SH" "$run_id" "$rd" "worker-${i}" "${BATS_TMP}/storm2-out.txt" ) &
    pids="$pids $!"
  done
  local rc=0 p
  for p in $pids; do
    wait "$p" || rc=1
  done
  [ "$rc" -eq 0 ]

  local claimed_lines
  claimed_lines="$(grep -c '^CLAIMED_BATCH=' "${BATS_TMP}/storm2-out.txt" || true)"
  [ "$claimed_lines" -eq "$m" ]

  local ids sorted expected
  ids="$(grep '^CLAIMED_BATCH=' "${BATS_TMP}/storm2-out.txt" | sed 's/CLAIMED_BATCH=//')"
  sorted="$(echo "$ids" | sort -n | tr '\n' ' ')"
  expected="$(seq 1 "$m" | tr '\n' ' ')"
  [ "$sorted" = "$expected" ]

  local no_left_lines
  no_left_lines="$(grep -c '^NO_BATCHES_LEFT=1$' "${BATS_TMP}/storm2-out.txt" || true)"
  [ "$no_left_lines" -eq $((25 - m)) ]
}
