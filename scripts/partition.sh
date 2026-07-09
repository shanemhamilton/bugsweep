#!/usr/bin/env bash
# bugsweep partition (bugsweep-wbg): partition the risk-ranked hunt frontier
# across N concurrent subagents so they cover DISJOINT batches instead of all
# racing to the same highest-risk files first.
#
# PROBLEM this fixes: if an orchestrator hands 5 subagents the SAME
# prior-coverage.json + recon.json, all 5 independently hunt the highest-risk
# batch first -- 5x redundant work on the same files, not 5x coverage. This
# script does not re-rank anything (recon-plan.sh / context-build.md already
# produce the risk-ordered batch list) -- it only partitions/claims over that
# EXISTING deterministic order.
#
#   partition.sh frontier <RUN_DIR>                  list batch ids, one per line, in frontier order
#   partition.sh shard    <RUN_DIR> <N> <INDEX>       deterministic pre-partition: batch ids for shard INDEX (0-based) of N
#   partition.sh claim    <RUN_ID> <RUN_DIR> [OWNER]  atomically self-claim the next unclaimed batch id
#   partition.sh claims   <RUN_ID>                    list already-claimed batch ids for RUN_ID
#
# Two coordination modes (either or both):
#   (a) Orchestrator-driven: call `shard <RUN_DIR> <N> <I>` once per subagent up
#       front and hand subagent I its batch id list. Pure function of the
#       frontier's content -- no shared state, no locking, byte-identical
#       across repeated calls (see the determinism test in tests/bats/partition.bats).
#   (b) Self-claim: each subagent repeatedly calls `claim <RUN_ID> <RUN_DIR>`
#       and hunts whatever batch id it gets back, until NO_BATCHES_LEFT=1.
#       RUN_ID is a caller-chosen string shared by all sibling subagents of ONE
#       orchestrator invocation (e.g. the orchestrator's own session/dispatch
#       id) -- it is NOT any individual subagent's own run_dir/bs_id, since the
#       whole point is that siblings coordinate through one shared registry.
#
# Frontier = the batches array of <RUN_DIR>/recon.json (the live, run-scoped
# hunt plan context-build.md seeds from recon-plan.json and updates as it
# re-tiers), falling back to <RUN_DIR>/recon-plan.json (Step 0's raw plan,
# before context-build.md has copied it into recon.json), generating the
# latter on the fly via recon-plan.sh + `git ls-files` only if NEITHER exists
# yet. recon-plan.sh's docstring names byte-identical output as its
# determinism contract, so independently-run sibling subagents (each doing
# their own context-build.md Step 0 against the same file list/config) end up
# with the SAME batch ids in the SAME order -- which is what makes a bare
# integer id a valid cross-subagent coordination key at all.
#
# Registry: .bugsweep/state/claims-<RUN_ID>.jsonl        (audit trail; one JSON line per successful claim)
# Claim dirs: .bugsweep/state/claims-<RUN_ID>.d/batch-<id>.claim/   (the atomic primitive itself)
#
# ATOMICITY (the part that gets scrutinized): a claim is `mkdir
# "${claims_dir}/batch-${id}.claim"`. `mkdir` is atomic on every POSIX
# filesystem -- exactly the same primitive common.sh's bugsweep_lock_acquire
# uses for its critical sections (bugsweep-p74) -- and is used here DIRECTLY
# rather than through that mutex wrapper, because a claim is never released:
# there is no critical section to hold-then-unlock, no stale-holder-reclaim
# story, just a permanent one-way "has batch <id> been claimed in run <RUN_ID>
# yet". Exactly one concurrent `mkdir` for the SAME path can ever return
# success; every other caller gets EEXIST (mkdir's normal errno for "already
# exists") and moves on to try the next unclaimed id. Critically, this is NOT
# a check-then-act race: there is no `test -e "$dir" || mkdir "$dir"` window
# for a second claimant to land in between the check and the act -- the
# kernel's mkdir(2) call performs the existence check and the creation as one
# indivisible operation. The JSONL registry append that follows a WON claim is
# not part of the race at all (only the single already-uniquely-winning
# claimant for that id ever reaches it), so no lock is needed there either --
# it's just an audit trail, not the source of truth (the claim directories
# are).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

STATE_DIR="$BUGSWEEP_STATE_DIR"

# Sanitize a caller-supplied run id into a safe filename fragment. Mirrors
# state.sh's _lease_id() so registry/claim-dir names are always filesystem-safe
# even if a caller passes something with slashes or spaces.
_run_key() {
  printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_'
}

# --- frontier resolution ----------------------------------------------------

# Resolves which file holds the batch list for <RUN_DIR>, generating
# recon-plan.json on the fly (via the existing recon-plan.sh, not reinventing
# its ranking) only when neither recon.json nor recon-plan.json exists yet.
_frontier_source() {
  local run_dir="$1"
  if [ -f "${run_dir}/recon.json" ]; then
    printf '%s' "${run_dir}/recon.json"
  elif [ -f "${run_dir}/recon-plan.json" ]; then
    printf '%s' "${run_dir}/recon-plan.json"
  else
    ( cd "$BUGSWEEP_REPO_ROOT" 2>/dev/null \
        && git ls-files 2>/dev/null | bash "${BUGSWEEP_SCRIPT_DIR}/recon-plan.sh" "$run_dir" >/dev/null 2>&1 ) || true
    printf '%s' "${run_dir}/recon-plan.json"
  fi
}

# Prints one integer batch id per line, in the SAME order the batches array
# stores them (already risk-ranked upstream -- this function does not sort or
# re-rank anything). A plain line-oriented grep is sufficient without a JSON
# parser: "id" is a key ONLY on batch objects in this schema (see
# prompts/context-build.md's recon.json shape), so there is nothing else in
# the file it could mismatch.
frontier() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: partition.sh frontier <RUN_DIR>"
  run_dir="$(cd "$run_dir" && pwd)"
  local src; src="$(_frontier_source "$run_dir")"
  [ -f "$src" ] || return 0
  grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' "$src" 2>/dev/null | grep -o '[0-9]*$'
}

# --- shard: deterministic pre-partition -------------------------------------

# Batch at 0-based position <i> in the frontier goes to shard (i mod N).
# Round-robin by POSITION (not by id value, which need not be contiguous) so
# every shard gets a spread of high- and low-priority batches instead of one
# shard getting only the risk-ranked head and another only the tail -- that
# spread is the whole point: it's what turns "5 subagents" into "5x coverage"
# instead of "5x the same top files". Pure function of (frontier, N, index):
# no shared state, no locking, byte-identical on repeated calls.
shard() {
  local run_dir="${1:-}" n="${2:-}" index="${3:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && [ -n "$n" ] && [ -n "$index" ] \
    || die "usage: partition.sh shard <RUN_DIR> <N> <INDEX>"
  case "$n" in ''|*[!0-9]*) die "partition.sh shard: N must be a non-negative integer, got '${n}'" ;; esac
  case "$index" in ''|*[!0-9]*) die "partition.sh shard: INDEX must be a non-negative integer, got '${index}'" ;; esac
  [ "$n" -gt 0 ] || die "partition.sh shard: N must be > 0"
  [ "$index" -lt "$n" ] || die "partition.sh shard: INDEX (${index}) must be < N (${n})"

  local id pos=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ $(( pos % n )) -eq "$index" ]; then
      printf '%s\n' "$id"
    fi
    pos=$(( pos + 1 ))
  done < <(frontier "$run_dir")
}

# --- claim: atomic self-claim ------------------------------------------------

claim() {
  local run_id="${1:-}" run_dir="${2:-}" owner="${3:-${BUGSWEEP_CLAIM_OWNER:-$$}}"
  [ -n "$run_id" ] && [ -n "$run_dir" ] && [ -d "$run_dir" ] \
    || die "usage: partition.sh claim <RUN_ID> <RUN_DIR> [OWNER]"
  run_dir="$(cd "$run_dir" && pwd)"
  bugsweep_state_dir_ready || {
    log "partition: no project-scoped state dir (${BUGSWEEP_STATE_DIR:-not in a git repo}); cannot coordinate a claim."
    echo "NO_BATCHES_LEFT=1"
    return 0
  }

  local key; key="$(_run_key "$run_id")"
  local claims_dir="${STATE_DIR}/claims-${key}.d"
  local registry="${STATE_DIR}/claims-${key}.jsonl"
  mkdir -p "$claims_dir" 2>/dev/null || true

  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # THE atomic primitive: see the file header for why this mkdir alone is
    # sufficient (no check-then-act window; exactly one winner per path).
    if mkdir "${claims_dir}/batch-${id}.claim" 2>/dev/null; then
      local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '{"run":"%s","batch":%s,"owner":"%s","pid":%s,"ts":"%s"}\n' \
        "$key" "$id" "$owner" "$$" "$ts" >> "$registry"
      echo "CLAIMED_BATCH=${id}"
      return 0
    fi
  done < <(frontier "$run_dir")

  echo "NO_BATCHES_LEFT=1"
}

# Lists batch ids already claimed for RUN_ID, reading the claim directories
# themselves (the atomic ground truth) rather than the JSONL audit trail.
claims() {
  local run_id="${1:-}"
  [ -n "$run_id" ] || die "usage: partition.sh claims <RUN_ID>"
  local key; key="$(_run_key "$run_id")"
  local claims_dir="${STATE_DIR}/claims-${key}.d"
  [ -d "$claims_dir" ] || return 0

  local f base id
  for f in "$claims_dir"/batch-*.claim; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    id="${base#batch-}"
    id="${id%.claim}"
    echo "CLAIM=${id}"
  done
  return 0
}

# ---------------------------------------------------------------------------
cmd="${1:-}"
case "$cmd" in
  frontier) frontier "${2:-}" ;;
  shard)    shard "${2:-}" "${3:-}" "${4:-}" ;;
  claim)    claim "${2:-}" "${3:-}" "${4:-}" ;;
  claims)   claims "${2:-}" ;;
  *)        die "usage: partition.sh <frontier|shard|claim|claims> [args]" ;;
esac
