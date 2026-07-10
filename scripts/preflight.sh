#!/usr/bin/env bash
# bugsweep preflight: the fail-closed safety gate. Run before anything else.
#
# Two modes:
#
#   default (no flag)  — the original single-run-per-tree contract:
#     - we are on a fresh bugsweep/<timestamp> branch cut from the user's HEAD,
#       checked out IN PLACE in the current working tree
#     - the user's uncommitted work is stashed and recorded for later restore
#     - a run directory + ledger exist under .bugsweep/
#     Byte-for-byte identical behavior to before bugsweep-p74 — existing
#     callers/tests are unaffected.
#
#   --worktree (bugsweep-p74) — concurrency-safe mode for N sibling subagents
#   (e.g. a metaswarm orchestrator dispatching up to 5 in parallel) that must
#   each get an ISOLATED working dir + index + HEAD without colliding on the
#   ONE shared tree/branch/stash-stack, and without ever touching the user's
#   checkout:
#     - a NEW linked git worktree is created under
#       <main-repo-root>/.bugsweep/worktrees/<id>, checked out on a
#       collision-free branch bugsweep/<ts>-<pid>-<rand> cut from the user's
#       current HEAD
#     - the user's current working tree/branch/index are NEVER read, stashed,
#       or switched — the worktree is cut straight from HEAD, so the run only
#       ever sees committed history at the moment preflight ran. Uncommitted
#       changes in the user's tree are simply not visible inside the worktree
#       (git worktrees always start clean relative to the checked-out commit);
#       nothing is lost or moved, it just isn't part of this run's view.
#       STASH=none is reported for this reason — there is no stash to restore.
#     - id is timestamp + pid + a short random suffix, so same-second parallel
#       starts (the norm when 5 subagents launch together) never collide, even
#       under pid reuse across quick sequential runs
#     - all safety refusals (rebase/merge in progress, detached HEAD, no
#       commits, protected+dirty branch) still apply identically before any
#       worktree is created
#
# On ANY problem it exits non-zero and changes nothing it can't undo.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# TEST-ONLY config redirection. common.sh unconditionally sets BUGSWEEP_CONFIG
# to "${BUGSWEEP_ROOT}/config/bugsweep.config.json" (a plain assignment, not
# `:=`), so the test harness cannot point this script at a temp config via the
# public BUGSWEEP_CONFIG. This underscore-prefixed, _TEST_-marked hook lets
# tests/bats/guard.bats exercise the caps.max_runtime_minutes sanitization
# branches (bugsweep-5ft review MAJOR 5) WITHOUT introducing any production-path
# config-redirection env var (no unprefixed override exists — the production
# path always trusts common.sh's single BUGSWEEP_CONFIG, exactly like every
# other cfg_get-using script in the repo; see scripts/analyzers.sh for the same
# pattern). A stray CI export of this internal name is the caller's own doing,
# not a supported knob.
if [ -n "${_PREFLIGHT_TEST_CONFIG_OVERRIDE:-}" ]; then
  # shellcheck disable=SC2034  # consumed by common.sh's cfg_get, sourced above
  BUGSWEEP_CONFIG="$_PREFLIGHT_TEST_CONFIG_OVERRIDE"
fi

# Parse optional --mode and --worktree flags (e.g. --mode autonomous --worktree)
bs_mode="detect"
bs_worktree="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) bs_mode="${2:-detect}"; shift 2 ;;
    --mode=*) bs_mode="${1#--mode=}"; shift ;;
    --worktree) bs_worktree="yes"; shift ;;
    *) shift ;;
  esac
done

require_git_repo

# --- Refuse unsafe repo states ------------------------------------------------
git_dir="$(git rev-parse --git-dir)"
[ -e "${git_dir}/rebase-merge" ] || [ -e "${git_dir}/rebase-apply" ] \
  && die "A rebase is in progress. Resolve it before running bugsweep."
[ -e "${git_dir}/MERGE_HEAD" ] \
  && die "A merge is in progress. Resolve it before running bugsweep."

orig_branch="$(current_branch)"
[ "$orig_branch" = "DETACHED" ] \
  && die "HEAD is detached. Check out a branch before running bugsweep so we can return you to it."

git rev-parse HEAD >/dev/null 2>&1 \
  || die "The repository has no commits yet. Make an initial commit first."

orig_head="$(git rev-parse HEAD)"

# --- Protected-branch guard ---------------------------------------------------
# We never COMMIT to the original branch (we cut a new one), but we also refuse to
# even start from a protected branch unless it is clean, to avoid any chance of
# entangling protected history with stash restore edge cases.
#
# This guard is SKIPPED in --worktree mode: the whole reason it exists is that
# the default path stashes the user's uncommitted work and later pops it back
# onto the (possibly protected) branch, which is exactly the "stash restore
# edge case" the comment above warns about. Worktree mode never stashes and
# never touches the user's branch at all (see the worktree branch below), so
# there is nothing to entangle with protected history — a dirty protected
# branch is perfectly safe to leave untouched while we cut an isolated
# worktree from its HEAD.
protected_default="main master develop production prod release"
protected="$(cfg_get '.protected_branches | join(" ")' "$protected_default")"
[ -z "$protected" ] && protected="$protected_default"

is_protected="no"
for p in $protected; do
  case "$orig_branch" in
    "$p"|"$p"/*) is_protected="yes" ;;
  esac
done

dirty="no"
git diff --quiet --ignore-submodules HEAD 2>/dev/null || dirty="yes"
[ -n "$(git ls-files --others --exclude-standard)" ] && dirty="yes"

if [ "$bs_worktree" != "yes" ] && [ "$is_protected" = "yes" ] && [ "$dirty" = "yes" ]; then
  die "You are on protected branch '$orig_branch' with uncommitted changes. Commit or stash them, or switch to a feature branch, then re-run. (This avoids any risk to protected history.)"
fi

# --- Collision-free id ---------------------------------------------------------
# ts alone is only second-resolution: 5 subagents launched by one orchestrator
# routinely start within the same second, so `bugsweep/<ts>` would collide for
# all but one of them (the bug this bead fixes). Append this process's pid and
# a short random suffix so the id is unique even under same-second, same-repo
# concurrent starts. $RANDOM is a bash 3.2 builtin (0-32767); two draws give
# enough entropy to make an accidental collision with a stale reused pid
# vanishingly unlikely without needing /dev/urandom or external tools.
ts="$(date +%Y%m%d-%H%M%S)"
bs_rand="$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
bs_id="${ts}-$$-${bs_rand}"

# Keep the internal run directory out of git entirely (local exclude — does NOT
# modify the user's tracked .gitignore). This prevents the run dir from being
# committed into the branch and then disappearing on checkout.
#
# Review fix C (bugsweep-p74): the exclude entry MUST anchor to the COMMON git
# dir — git reads info/exclude only from the shared .git, never from a
# per-worktree gitdir, and .bugsweep/ itself lands under the MAIN repo root
# (BUGSWEEP_REPO_ROOT). When the audited checkout is itself a linked worktree,
# `git rev-parse --git-dir` points at .git/worktrees/<name>/ — writing the
# exclude there does nothing, leaving .bugsweep/ untracked-and-unexcluded in
# the main checkout, one `git add -A` away from committing bugsweep state into
# real history. (The rebase/merge-in-progress checks above intentionally stay
# on --git-dir: rebase state is per-worktree, so that anchoring is correct.)
exclude_root="${BUGSWEEP_GIT_COMMON_DIR:-$git_dir}"
exclude_file="${exclude_root}/info/exclude"
mkdir -p "${exclude_root}/info" 2>/dev/null || true
if [ -f "$exclude_file" ] && ! grep -qx '.bugsweep/' "$exclude_file" 2>/dev/null; then
  printf '\n.bugsweep/\n' >> "$exclude_file"
elif [ ! -f "$exclude_file" ]; then
  printf '.bugsweep/\n' > "$exclude_file"
fi

# BLOCKER B fix (bugsweep-8d0 dataloss review): run the reaper from the MAIN
# repo root, mirroring finalize.sh's --reap-worktrees call site exactly, so
# TARGET_BRANCH/containment can never be resolved from whatever cwd this
# preflight invocation happens to be running in. A subshell is used (not a
# permanent `cd`) so preflight's own cwd is never altered for the rest of
# this script, out of caution — nothing after this point currently depends on
# the original cwd in worktree mode (every path used below is absolute), but
# there is no reason to risk it.
if [ "$bs_worktree" = "yes" ] && [ -f "${BUGSWEEP_SCRIPT_DIR}/bugsweep-cleanup.sh" ]; then
  ( cd "$BUGSWEEP_REPO_ROOT" 2>/dev/null && bash "${BUGSWEEP_SCRIPT_DIR}/bugsweep-cleanup.sh" --reap-worktrees ) >/dev/null 2>&1 \
    || log "worktree reaper skipped or failed before preflight (non-fatal)."
fi

start_epoch="$(date +%s)"
max_runtime_minutes="$(cfg_get '.caps.max_runtime_minutes' '120')"
case "$max_runtime_minutes" in
  ''|*[!0-9]*) max_runtime_minutes=120 ;;
esac
[ "$max_runtime_minutes" -gt 0 ] || max_runtime_minutes=120
deadline_epoch=$(( start_epoch + (max_runtime_minutes * 60) ))

# --- Run directory ---------------------------------------------------------
# Anchored to the MAIN repo root (not CWD, and not the linked worktree's own
# root) so every concurrent subagent's run dir lands in one shared, discoverable
# location, matching where .bugsweep/state/ and .bugsweep/worktrees/ live.
run_dir="${BUGSWEEP_REPO_ROOT}/.bugsweep/run-${bs_id}"
mkdir -p "$run_dir"

# --- Persist run state + acquire this run's lease (bugsweep-p74) --------------
# Factored into a function so BOTH modes can call it, but at DIFFERENT points
# relative to worktree/branch creation — see the BLOCKER A comment at the
# worktree-mode call site below for why the ordering matters there.
_bsw_persist_run_state_and_lease() {
  # bugsweep-06y: every value is emitted via _bsw_env_kv (common.sh) so the
  # written file is a single-quoted, source-safe KEY='value' line regardless
  # of content. This is allowlist-free by design — BUGSWEEP_ORIG_BRANCH is the
  # attacker-reachable one (an arbitrary git branch NAME), but every other key
  # goes through the exact same helper rather than trusting a per-key judgment
  # call about which values could ever carry unsafe content.
  {
    _bsw_env_kv BUGSWEEP_TS "$ts"
    # Collision-free durable identity for cross-run learning. BUGSWEEP_TS is
    # intentionally human-readable but only has second resolution; concurrent
    # worktree runs use bs_id so their outcome episodes can never collapse.
    _bsw_env_kv BUGSWEEP_RUN_ID "$bs_id"
    _bsw_env_kv BUGSWEEP_RUN_DIR "$run_dir"
    _bsw_env_kv BUGSWEEP_BRANCH "$branch"
    _bsw_env_kv BUGSWEEP_ORIG_BRANCH "$orig_branch"
    _bsw_env_kv BUGSWEEP_ORIG_HEAD "$orig_head"
    _bsw_env_kv BUGSWEEP_STASH_REF "$stash_ref"
    _bsw_env_kv BUGSWEEP_START_EPOCH "$start_epoch"
    _bsw_env_kv BUGSWEEP_DEADLINE_EPOCH "$deadline_epoch"
    _bsw_env_kv BUGSWEEP_MAX_RUNTIME_MINUTES "$max_runtime_minutes"
    _bsw_env_kv BUGSWEEP_MODE "$bs_mode"
    _bsw_env_kv BUGSWEEP_WORKTREE "$worktree_path"
  } > "${run_dir}/state.env"

  # bugsweep-06y: every interpolated value is also JSON-escaped (common.sh's
  # _bsw_json_escape) so a branch name containing a `"`, `\`, or control
  # character can never break this line's JSON structure.
  : > "${run_dir}/ledger.jsonl"
  printf '{"event":"preflight","ts":"%s","branch":"%s","orig_branch":"%s","stash":"%s","worktree":"%s"}\n' \
    "$(_bsw_json_escape "$ts")" "$(_bsw_json_escape "$branch")" "$(_bsw_json_escape "$orig_branch")" \
    "$(_bsw_json_escape "$stash_ref")" "$(_bsw_json_escape "$worktree_path")" >> "${run_dir}/ledger.jsonl"

  # Bookkeeping only: leases COEXIST (this is never a mutex that blocks
  # sibling subagents). Best-effort; a failure here must never fail preflight.
  #
  # Review fix B: the recorded liveness pid is the CALLER's shell ($PPID —
  # the process that owns the whole run), never this preflight process's own
  # $$ — preflight exits right after PREFLIGHT_OK, so its pid is dead moments
  # after the lease is written. Callers that know a better owner (e.g. an
  # orchestrator session) pass BUGSWEEP_LEASE_PID=$$ explicitly and it is
  # honored verbatim.
  #
  # bugsweep-re9: the recorded pid is IN FACT dead almost immediately in
  # every agent-driven flow — each Bash tool call is its own fresh shell, so
  # even a caller that dutifully passes BUGSWEEP_LEASE_PID=$$ is naming a
  # process that exits the instant that tool call returns, long before the
  # run itself finishes. The HEARTBEAT (guard.sh's lease-touch on every
  # iteration) is what actually keeps a long-running run's lease alive past
  # the grace window — see state.sh for the full rationale.
  BUGSWEEP_LEASE_PID="${BUGSWEEP_LEASE_PID:-$PPID}" bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" lease-acquire "$run_dir" >/dev/null 2>&1 || true
}

worktree_path=""
if [ "$bs_worktree" = "yes" ]; then
  # --- Worktree mode: isolated working dir, NEVER touch the user's tree ------
  branch="bugsweep/${bs_id}"
  worktree_path="${BUGSWEEP_WORKTREES_DIR}/${bs_id}"
  mkdir -p "${BUGSWEEP_WORKTREES_DIR}"
  stash_ref="none"

  # BLOCKER A fix (bugsweep-8d0 dataloss review): persist state.env (with
  # BUGSWEEP_WORKTREE already pointing at the not-yet-created path) and
  # acquire this run's lease BEFORE `git worktree add` creates the worktree.
  # Pre-fix, `git worktree add` ran up to ~75 lines before lease-acquire — a
  # concurrent sibling's --reap-worktrees call landing in that window would
  # see a brand-new, lease-less worktree and (under the old "no lease =>
  # remove if clean" reaper default) delete it and its branch outright,
  # destroying a live sibling under the exact 5-subagent concurrency this
  # bead protects. Ordering it this way means a lease-less bugsweep worktree
  # can never legitimately exist: from the very first moment the worktree
  # appears in `git worktree list`, a lease naming it is already on disk.
  # (The reaper also now has an unconditional minimum-age grace floor and
  # preserves-by-default on "no lease found" as further defense-in-depth —
  # see bugsweep-cleanup.sh — but this reordering is what closes the race
  # at its source.)
  _bsw_persist_run_state_and_lease

  # TEST-ONLY hook (bugsweep-8d0 dataloss review): lets
  # tests/bats/preflight-worktree.bats deterministically observe the exact
  # window this fix closes — the lease/state.env must already exist and the
  # worktree directory must NOT exist yet at this point. In production this
  # variable is unset and the line is a no-op. Same test-hook idiom as
  # _PREFLIGHT_TEST_CONFIG_OVERRIDE above and
  # BUGSWEEP_LEASE_TOUCH_RACE_SLEEP in state.sh.
  if [ -n "${_PREFLIGHT_TEST_PRE_ADD_HOOK:-}" ]; then
    eval "$_PREFLIGHT_TEST_PRE_ADD_HOOK"
  fi

  # Cut a brand-new linked worktree straight from the user's current HEAD, on a
  # brand-new branch. This never reads, stashes, or switches the user's tree —
  # `git worktree add` operates on the shared repo metadata only; the user's
  # working directory and index are left completely alone. There is nothing to
  # stash: the worktree starts clean at orig_head by construction, so any
  # uncommitted changes in the user's tree simply aren't part of this run's
  # view (they are neither lost nor moved — STASH=none reflects that there was
  # never anything to restore for THIS run).
  if ! git worktree add -q -b "$branch" "$worktree_path" "$orig_head" >/dev/null 2>&1; then
    bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" lease-release "$run_dir" >/dev/null 2>&1 || true
    rm -rf "$worktree_path" "$run_dir" 2>/dev/null || true
    die "Could not create worktree '$worktree_path' on branch '$branch'. No changes made to your working tree."
  fi
  log "Working in isolated worktree: $worktree_path (branch: $branch)"
else
  # --- Default mode: original single-run-per-tree contract, unchanged --------
  branch="bugsweep/${ts}"

  # --- Stash uncommitted work (including untracked) ---------------------------
  stash_ref="none"
  if [ "$dirty" = "yes" ]; then
    if git stash push -u -m "bugsweep-autostash-${ts}" >/dev/null 2>&1; then
      stash_ref="$(git rev-parse 'stash@{0}' 2>/dev/null || echo unknown)"
      log "Stashed your uncommitted work (will be restored at finalize)."
    else
      die "Failed to stash your uncommitted changes. Aborting without making any changes."
    fi
  fi

  # --- Create and switch to the throwaway branch in the shared tree -----------
  if ! git checkout -b "$branch" >/dev/null 2>&1; then
    # Roll back the stash if branch creation failed, so we leave things as we found them.
    [ "$stash_ref" != "none" ] && git stash pop >/dev/null 2>&1 || true
    die "Could not create branch '$branch'. No changes made."
  fi
  log "Working on throwaway branch: $branch"

  # In-place mode never creates a worktree under BUGSWEEP_WORKTREES_DIR, so
  # it is never visible to bugsweep-cleanup.sh's reaper in the first place
  # (reap_one_worktree scopes strictly to that directory) — the lease-before-
  # branch-creation reordering above is not needed here; this mirrors the
  # script's pre-existing (byte-for-byte unaffected) in-place-mode contract.
  _bsw_persist_run_state_and_lease
fi

# --- Prime coverage-first scope from prior runs (best-effort, never fatal) -----
# Reads .bugsweep/state/ and writes ${run_dir}/prior-coverage.json so context-build
# can put never-audited + stale + high-risk files on the critical-tier frontier.
# A broken/empty cache degrades to whole-repo scope; it must never fail preflight.
prior_summary=""
prior_summary="$(bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" prime "$run_dir" 2>/dev/null \
  | sed -n 's/^SUMMARY=//p' | head -1 || true)"
if [ -n "$prior_summary" ]; then
  log "Prior coverage: ${prior_summary}"
  printf '{"event":"primed","summary":"%s"}\n' "$(printf '%s' "$prior_summary" | tr '"' "'")" \
    >> "${run_dir}/ledger.jsonl"
fi

# --- Replay variant queries (WU1): re-hunt confirmed-bug siblings repo-wide ----
# Best-effort, never fatal. Writes variant-matches.jsonl into the run dir and a requeue
# list of sibling files that context-build folds into the critical-tier frontier.
: > "${run_dir}/variant-requeue.txt"
if [ -f "${BUGSWEEP_SCRIPT_DIR}/variants.sh" ]; then
  bash "${BUGSWEEP_SCRIPT_DIR}/variants.sh" replay "$run_dir" 2>/dev/null \
    | sed -n 's/^REQUEUE=//p' > "${run_dir}/variant-requeue.txt" 2>/dev/null || true
  vq="$(wc -l < "${run_dir}/variant-requeue.txt" 2>/dev/null | tr -d ' ' || echo 0)"
  case "$vq" in ''|*[!0-9]*) vq=0 ;; esac
  if [ "$vq" -gt 0 ]; then
    log "Variant queries flagged ${vq} sibling file(s) to re-hunt."
    printf '{"event":"variant_replay","requeued":%s}\n' "$vq" >> "${run_dir}/ledger.jsonl"
  fi
fi

# --- Shared index builds (bugsweep-p74: build-lock, never race) ---------------
# symbols.sh / graph.sh / reachability.sh all build/refresh indexes that live
# under the ONE shared .bugsweep/ dir (anchored to the main repo root, same as
# .bugsweep/state/). With up to 5 --worktree subagents priming at once, letting
# them all write these files concurrently would tear/corrupt them. All three
# are already best-effort/non-fatal, so the lock is short and cooperative: if
# another subagent already holds it, we skip the (re)build entirely rather than
# waiting — a slightly-stale shared index is fine, since these feed ranking
# heuristics, not correctness-critical safety logic. The BUILD happens once;
# whoever gets the lock first refreshes it for everyone.
index_lock="${BUGSWEEP_REPO_ROOT:+${BUGSWEEP_REPO_ROOT}/.bugsweep/.index-build.lock}"
if [ -n "$index_lock" ] && bugsweep_lock_acquire "$index_lock" 3; then
  # --- Build/refresh the symbol index (WU0): stable IDs for the graph/justification ----
  # layers. Incremental (only changed files re-parsed). Best-effort, never fatal.
  if [ -f "${BUGSWEEP_SCRIPT_DIR}/symbols.sh" ]; then
    bash "${BUGSWEEP_SCRIPT_DIR}/symbols.sh" build >/dev/null 2>&1 || log "symbols: index build skipped (non-fatal)."
  fi

  # --- Build the call/import graph + entry-point map (WU-G) ----------------------
  # Keyed to the WU0 symbol-ids; feeds WU3 reachability ranking and WU2 invalidation.
  # Built AFTER symbols.sh (callers join to WU0 ids). Best-effort: a failure leaves the
  # graph absent so WU3 falls back to sink+severity ordering — it never fails preflight.
  if [ -f "${BUGSWEEP_SCRIPT_DIR}/graph.sh" ]; then
    bash "${BUGSWEEP_SCRIPT_DIR}/graph.sh" build >/dev/null 2>&1 || log "graph: build skipped (non-fatal)."
  fi

  # --- Sanitizer-aware reachability + exposure ranking (WU3) ---------------------
  # Classifies sinks, computes LIVE/MAYBE/COLD attacker-exposure over the WU-G graph, and
  # writes <RUN_DIR>/exposure.json — context-build's in-tier sort. Best-effort: a failure
  # leaves exposure absent/empty so context-build keeps its sink/risk ordering (sinks stay
  # unconditionally in scope); it never fails preflight.
  if [ -f "${BUGSWEEP_SCRIPT_DIR}/reachability.sh" ]; then
    bash "${BUGSWEEP_SCRIPT_DIR}/reachability.sh" build >/dev/null 2>&1 || log "reachability: build skipped (non-fatal)."
  fi

  bugsweep_lock_release "$index_lock"
else
  log "shared index build already in progress by another run — skipping rebuild (using existing index, non-fatal)."
fi

# rank writes into THIS run's own run_dir (not the shared index), so it's safe
# to run outside the build-lock even when the build itself was skipped above.
if [ -f "${BUGSWEEP_SCRIPT_DIR}/reachability.sh" ]; then
  bash "${BUGSWEEP_SCRIPT_DIR}/reachability.sh" rank "$run_dir" >/dev/null 2>&1 || log "reachability: rank skipped (non-fatal)."
fi

# --- Re-evaluate prior "safe" conclusions (WU2) --------------------------------
# Runs AFTER reachability (it reads the WU3 path_hash). Re-opens any conclusion whose ground
# moved (premise/sanitizer hash, sink reachable-path set, or catalog version) and folds a
# `cleared` hint into exposure.json. Writes <RUN_DIR>/reopened-conclusions.txt — files that
# must rejoin the frontier. Fail-closed (any missing input -> reopen); never fails preflight.
if [ -f "${BUGSWEEP_SCRIPT_DIR}/conclusions.sh" ]; then
  reopened_summary="$(bash "${BUGSWEEP_SCRIPT_DIR}/conclusions.sh" prime "$run_dir" 2>/dev/null \
    | sed -n 's/^SUMMARY=//p' | head -1 || true)"
  [ -n "$reopened_summary" ] && log "Conclusions: ${reopened_summary}"
fi

# --- Output for the SKILL to read ---------------------------------------------
echo "RUN_DIR=${run_dir}"
echo "BRANCH=${branch}"
echo "ORIG_BRANCH=${orig_branch}"
echo "STASH=${stash_ref}"
[ -n "$worktree_path" ] && echo "WORKTREE=${worktree_path}"
[ -f "${run_dir}/prior-coverage.json" ] && echo "PRIOR_COVERAGE=${run_dir}/prior-coverage.json"
[ -f "${run_dir}/exposure.json" ] && echo "EXPOSURE=${run_dir}/exposure.json"
[ -s "${run_dir}/reopened-conclusions.txt" ] && echo "REOPENED_CONCLUSIONS=${run_dir}/reopened-conclusions.txt"
echo "PREFLIGHT_OK"
