#!/usr/bin/env bash
# bugsweep preflight: the fail-closed safety gate. Run before anything else.
# Guarantees on success:
#   - we are on a fresh bugsweep/<timestamp> branch cut from the user's HEAD
#   - the user's uncommitted work is stashed and recorded for later restore
#   - a run directory + ledger exist under .bugsweep/
# On ANY problem it exits non-zero and changes nothing it can't undo.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

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

if [ "$is_protected" = "yes" ] && [ "$dirty" = "yes" ]; then
  die "You are on protected branch '$orig_branch' with uncommitted changes. Commit or stash them, or switch to a feature branch, then re-run. (This avoids any risk to protected history.)"
fi

# --- Run directory + ledger ---------------------------------------------------
ts="$(date +%Y%m%d-%H%M%S)"
run_dir=".bugsweep/run-${ts}"
mkdir -p "$run_dir"

# Keep the internal run directory out of git entirely (local exclude — does NOT
# modify the user's tracked .gitignore). This prevents the run dir from being
# committed into the branch and then disappearing on checkout.
exclude_file="${git_dir}/info/exclude"
mkdir -p "${git_dir}/info" 2>/dev/null || true
if [ -f "$exclude_file" ] && ! grep -qx '.bugsweep/' "$exclude_file" 2>/dev/null; then
  printf '\n.bugsweep/\n' >> "$exclude_file"
elif [ ! -f "$exclude_file" ]; then
  printf '.bugsweep/\n' > "$exclude_file"
fi

start_epoch="$(date +%s)"
branch="bugsweep/${ts}"

# --- Stash uncommitted work (including untracked) -----------------------------
stash_ref="none"
if [ "$dirty" = "yes" ]; then
  if git stash push -u -m "bugsweep-autostash-${ts}" >/dev/null 2>&1; then
    stash_ref="$(git rev-parse stash@{0} 2>/dev/null || echo unknown)"
    log "Stashed your uncommitted work (will be restored at finalize)."
  else
    die "Failed to stash your uncommitted changes. Aborting without making any changes."
  fi
fi

# --- Create and switch to the throwaway branch --------------------------------
if ! git checkout -b "$branch" >/dev/null 2>&1; then
  # Roll back the stash if branch creation failed, so we leave things as we found them.
  [ "$stash_ref" != "none" ] && git stash pop >/dev/null 2>&1 || true
  die "Could not create branch '$branch'. No changes made."
fi
log "Working on throwaway branch: $branch"

# --- Persist run state (consumed by guard.sh / finalize.sh) -------------------
cat > "${run_dir}/state.env" <<EOF
BUGSWEEP_TS=${ts}
BUGSWEEP_RUN_DIR=${run_dir}
BUGSWEEP_BRANCH=${branch}
BUGSWEEP_ORIG_BRANCH=${orig_branch}
BUGSWEEP_ORIG_HEAD=${orig_head}
BUGSWEEP_STASH_REF=${stash_ref}
BUGSWEEP_START_EPOCH=${start_epoch}
EOF

: > "${run_dir}/ledger.jsonl"
printf '{"event":"preflight","ts":"%s","branch":"%s","orig_branch":"%s","stash":"%s"}\n' \
  "$ts" "$branch" "$orig_branch" "$stash_ref" >> "${run_dir}/ledger.jsonl"

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
[ -f "${run_dir}/prior-coverage.json" ] && echo "PRIOR_COVERAGE=${run_dir}/prior-coverage.json"
[ -f "${run_dir}/exposure.json" ] && echo "EXPOSURE=${run_dir}/exposure.json"
[ -s "${run_dir}/reopened-conclusions.txt" ] && echo "REOPENED_CONCLUSIONS=${run_dir}/reopened-conclusions.txt"
echo "PREFLIGHT_OK"
