#!/usr/bin/env bash
# bugsweep integrate — ORDERED, re-verifying multi-branch integration (bugsweep-5e8).
#
# bugsweep-cleanup.sh lands exactly ONE bugsweep/* branch. The nightshift orchestrator
# can produce up to 5 sibling branches to land on the same target in a single wave, and
# a fix that was green in isolation can go RED only after a sibling merges (a semantic
# conflict the per-branch quality gate never saw). This script merges an ORDERED list of
# branches (order chosen by the caller/orchestrator) one at a time, RE-RUNS the quality
# gate after EACH merge, and on the first red/conflict: abandons that merge cleanly,
# preserves that branch and every remaining branch untouched, and stops with stable
# KEY=VALUE result lines the orchestrator can parse to reorder or defer.
#
# SAFETY DESIGN — the target branch ref only ever moves FORWARD, by fast-forward, onto a
# commit that already PASSED the quality gate. We never move the user's target branch to a
# bad state, so there is never anything destructive to undo:
#   1. Detach HEAD at the current integration tip (initially the target's sha).
#   2. `git merge --no-ff` the branch there -> merge commit M (conflict -> `git merge
#      --abort`, preserve, stop). The target ref has NOT moved.
#   3. Run the quality gate at M.
#   4. PASS -> advance the real target branch to M by FAST-FORWARD only (verified via
#      `git merge-base --is-ancestor <target> M`, then `git update-ref`), and continue
#      from M. FAIL -> abandon M (just check the target branch back out; it never moved),
#      report gate_failed, stop.
# There is NO hard-reset of any ref and NO force operation of any kind on user content
# anywhere in this script (trust-contract rule 3). At the end HEAD is left on the target.
#
# QUALITY-GATE COMMANDS MUST BE TREE-NEUTRAL. The gate is run against the merged tree; it
# must write ONLY outside the repo (into RUN_DIR or a system temp), never leaving tracked
# or untracked changes behind. A gate that leaks artifacts (e.g. a test runner that writes
# .coverage or __pycache__/*.pyc into the repo) is detected: after the gate runs we check
# `git status --porcelain`, and if the tree was mutated we stop with `gate_dirtied_tree`
# rather than silently carrying the pollution into the next branch (we never auto-clean —
# `git clean`/`reset` are themselves forbidden destructive ops).
#
# Usage:
#   bash integrate.sh [--run-dir RUN_DIR] [--delete-merged] <target-branch> <branch1> [branch2 ...]
#
# Settings (override via environment variables):
#   BUGSWEEP_QUALITY_GATE_COMMAND   command to re-run after each merge.
#                                   Default: bash scripts/run_checks.sh verify <RUN_DIR>
#                                   (same convention as finalize.sh / bugsweep-cleanup.sh)
#   BUGSWEEP_FORCE_NO_PYTHON        set to 1 to force the degraded no-python3 JSON path
#                                   (test hook; also an operator escape hatch).
#
# Never force-merges, force-pushes, or force-deletes. Never pushes (the orchestrator
# pushes). Deletes a branch only after merge-base containment proof AND only when
# --delete-merged is passed (default: preserve every branch).

set -euo pipefail

# Logs go to stderr (matching common.sh's log): integrate_one's stdout is
# captured as the outcome code, so any log line on stdout would corrupt it.
log() { printf 'integrate: %s\n' "$*" >&2; }
die_usage() {
  log "ERROR: $*"
  cat <<'USAGE'
usage: integrate.sh [--run-dir RUN_DIR] [--delete-merged] <target-branch> <branch1> [branch2 ...]
USAGE
  exit 2
}

# --- Argument parsing (POSIX/bash-3.2 friendly; no getopts long-option support) ---
RUN_DIR=""
DELETE_MERGED=0
TARGET_BRANCH=""
BRANCHES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir)
      [ "$#" -ge 2 ] || die_usage "--run-dir requires a value"
      RUN_DIR="$2"
      shift 2
      ;;
    --run-dir=*)
      RUN_DIR="${1#--run-dir=}"
      shift
      ;;
    --delete-merged)
      DELETE_MERGED=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -ge 1 ] || die_usage "missing required <target-branch> argument (no defaulting to main — must be explicit)"
TARGET_BRANCH="$1"
shift

[ "$#" -ge 1 ] || die_usage "at least one branch to integrate must be given"
while [ "$#" -gt 0 ]; do
  BRANCHES+=("$1")
  shift
done

# --- MINOR 5: resolve/create RUN_DIR up front ----------------------------------
# A non-empty RUN_DIR that does not exist is CREATED (mkdir -p) or we die loudly —
# never silently substituted with a random temp path, which would make a caller
# that constructs the results path from --run-dir read a stale/missing file.
if [ -n "$RUN_DIR" ] && [ ! -d "$RUN_DIR" ]; then
  mkdir -p "$RUN_DIR" || die_usage "could not create --run-dir '$RUN_DIR'"
fi

# --- Preconditions -------------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die_usage "not inside a git repo"

git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
case "$git_common_dir" in
  /*) : ;;
  *) [ -n "$git_common_dir" ] && git_common_dir="$(cd "$git_common_dir" && pwd)" ;;
esac

merge_or_rebase_in_progress() {
  [ -n "$git_common_dir" ] || return 1
  [ -f "${git_common_dir}/MERGE_HEAD" ] \
    || [ -d "${git_common_dir}/rebase-merge" ] \
    || [ -d "${git_common_dir}/rebase-apply" ]
}

if merge_or_rebase_in_progress; then
  die_usage "a merge or rebase is already in progress in this working tree; resolve or abort it first"
fi

# True when the working tree has NO tracked-modification, staged change, or
# untracked file — i.e. safe to operate on. Reused at the top of every branch
# iteration (BLOCKER 2), not just at entry.
tree_is_clean() {
  git diff --quiet \
    && git diff --cached --quiet \
    && [ -z "$(git ls-files --others --exclude-standard)" ]
}

if ! tree_is_clean; then
  die_usage "working tree is not clean; refusing to run (this script never touches uncommitted work)"
fi

branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1"
}

git show-ref --verify --quiet "refs/heads/${TARGET_BRANCH}" \
  || die_usage "target branch '${TARGET_BRANCH}' does not exist as a local branch (no defaulting — pass it explicitly)"

for b in "${BRANCHES[@]}"; do
  branch_exists "$b" || die_usage "branch '$b' does not exist"
done

# --- Quality gate command resolution --------------------------------------------
# Same convention as finalize.sh's post-finalize-handoff quality_gate_command and
# bugsweep-cleanup.sh's BUGSWEEP_TEST_CMD: an environment override wins, else fall
# back to the documented run_checks.sh verify convention. MINOR 5: only interpolate
# RUN_DIR into the default command when it is non-empty.
if [ -n "${BUGSWEEP_QUALITY_GATE_COMMAND:-}" ]; then
  QUALITY_GATE_COMMAND="$BUGSWEEP_QUALITY_GATE_COMMAND"
elif [ -n "$RUN_DIR" ]; then
  QUALITY_GATE_COMMAND="bash scripts/run_checks.sh verify \"${RUN_DIR}\""
else
  QUALITY_GATE_COMMAND="bash scripts/run_checks.sh verify"
fi

run_quality_gate() {
  bash -c "$QUALITY_GATE_COMMAND"
}

# --- Containment idiom -----------------------------------------------------------
# Copied (not shared) from scripts/bugsweep-cleanup.sh's branch_contained_in_target,
# per the bead spec: siblings own bugsweep-cleanup.sh and common.sh this wave, so this
# script must not modify or import from either. This is the same merge-base ancestry
# check bugsweep-cleanup.sh uses to decide whether a branch is already landed.
branch_contained_in_target() {
  git merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

# --- Result tracking (bash-3.2: no associative arrays) ---------------------------
RESULT_BRANCHES=()
RESULT_CODES=()
MERGED_COUNT=0
ALREADY_CONTAINED_COUNT=0
PRESERVED_COUNT=0
STOPPED_AT=""
INTEGRATE_RESULT="complete"

record_result() {
  RESULT_BRANCHES+=("$1")
  RESULT_CODES+=("$2")
}

# --- Core per-branch integration -------------------------------------------------
# Prints the outcome code on stdout (merged|already_contained|conflict|gate_failed|
# gate_dirtied_tree|update_failed). Never moves the target branch to a bad state: it detaches HEAD
# at the target's current tip, builds the merge commit there, gates it, and only
# fast-forwards the real target ref onto a gate-passed commit. The next branch's
# iteration re-derives the tip from $TARGET_BRANCH, so there is no cross-iteration
# state to carry.
integrate_one() {
  local branch="$1" tip merge_sha

  if branch_contained_in_target "$branch" "$TARGET_BRANCH"; then
    log "$branch is already contained in $TARGET_BRANCH — skipping (idempotent re-run)"
    printf 'already_contained'
    return 0
  fi

  tip="$(git rev-parse "$TARGET_BRANCH")"

  # (1) Detach HEAD at the current target tip. The target ref itself does not move.
  # The tree was verified clean just before this in the main loop, so the checkout
  # cannot clobber work; guard anyway and bail safely if it somehow fails.
  if ! git checkout -q --detach "$tip" 2>/dev/null; then
    git checkout -q "$TARGET_BRANCH" >/dev/null 2>&1 || true
    log "could not detach HEAD at $TARGET_BRANCH tip to integrate $branch — preserving, stopping"
    printf 'gate_failed'
    return 1
  fi

  # (2) Build the merge commit on the detached HEAD. Conflict -> abort, preserve, stop.
  if ! git merge --no-ff -m "integrate(bugsweep): ${branch}" "$branch" >/dev/null 2>&1; then
    git merge --abort >/dev/null 2>&1 || true
    git checkout -q "$TARGET_BRANCH"      # target ref never moved; return HEAD to it
    log "CONFLICT merging $branch — aborted cleanly; branch preserved, remaining branches untouched"
    printf 'conflict'
    return 1
  fi
  merge_sha="$(git rev-parse HEAD)"

  # (3) Run the quality gate against the merged tree.
  log "re-running quality gate after merging $branch: ${QUALITY_GATE_COMMAND}"
  local gate_output gate_status=0
  gate_output="$(run_quality_gate 2>&1)" || gate_status=$?
  [ -n "$gate_output" ] && printf '%s\n' "$gate_output" | sed 's/^/integrate:   gate> /' >&2

  # (3a) BLOCKER 2: a gate that mutated the tree (tracked OR untracked) is a
  # contract violation — stop and report it; never silently proceed, never
  # auto-clean (git clean/reset are forbidden destructive ops).
  if ! tree_is_clean; then
    git checkout -q "$TARGET_BRANCH"      # target ref never moved
    log "QUALITY GATE DIRTIED THE WORKING TREE after merging $branch — stopping. Gate commands must be tree-neutral (write only outside the repo / into RUN_DIR)."
    printf 'gate_dirtied_tree'
    return 1
  fi

  # (3b) Gate failure: abandon the merge commit. The target ref never moved, so
  # there is nothing to reset — just return HEAD to the target branch.
  if [ "$gate_status" -ne 0 ]; then
    git checkout -q "$TARGET_BRANCH"
    log "QUALITY GATE FAILED after merging $branch (exit ${gate_status}) — abandoned the merge; target branch never moved"
    printf 'gate_failed'
    return 1
  fi

  # (4) Gate passed: fast-forward the real target branch onto the gate-passed
  # merge commit. Verify fast-forward first (the current target tip must be an
  # ancestor of merge_sha — it always is, since merge_sha's first parent IS the
  # tip), then move the ref. update-ref moves ONLY this ref; it never rewrites,
  # force-deletes, or touches any source branch.
  if ! git merge-base --is-ancestor "$tip" "$merge_sha" >/dev/null 2>&1; then
    # Defensive: should be impossible (merge_sha descends from tip). Abandon safely.
    git checkout -q "$TARGET_BRANCH"
    log "INTERNAL: refusing non-fast-forward advance of $TARGET_BRANCH onto $merge_sha — abandoning merge of $branch"
    printf 'gate_failed'
    return 1
  fi
  # The 3-arg form is a compare-and-swap: it advances the ref ONLY if it still
  # points at $tip (the sha we detached from). If a concurrent run advanced the
  # target out from under us, the CAS FAILS — and we must NOT report success.
  # (retry 2, MAJOR 2): integrate_one runs inside a command substitution guarded
  # by `|| true`, which disables set -e here, so we check the exit status
  # EXPLICITLY rather than relying on set -e to abort.
  local update_status=0
  git update-ref "refs/heads/${TARGET_BRANCH}" "$merge_sha" "$tip" || update_status=$?
  if [ "$update_status" -ne 0 ]; then
    git checkout -q "$TARGET_BRANCH" >/dev/null 2>&1 || true
    log "update-ref CAS failed advancing $TARGET_BRANCH onto $merge_sha (exit ${update_status}) — the target moved concurrently; NOT reporting merged. Preserving $branch, stopping."
    printf 'update_failed'
    return 1
  fi
  git checkout -q "$TARGET_BRANCH"
  log "quality gate passed after merging $branch — fast-forwarded $TARGET_BRANCH to ${merge_sha}"
  printf 'merged'
  return 0
}

# --- Main loop --------------------------------------------------------------------
# Deliberately stays on TARGET_BRANCH when done (no restore-to-starting-branch
# step): the orchestrator drives this script and is responsible for whatever
# happens next (push, further integration, etc.) — see the header note that this
# script itself never pushes.
git checkout -q "$TARGET_BRANCH" 2>/dev/null || die_usage "could not check out target branch '$TARGET_BRANCH'"

STOP=0
idx=0
total="${#BRANCHES[@]}"
while [ "$idx" -lt "$total" ]; do
  branch="${BRANCHES[$idx]}"

  if [ "$STOP" -eq 1 ]; then
    log "skipping $branch — stopped earlier in this run"
    record_result "$branch" "skipped_after_stop"
    PRESERVED_COUNT=$((PRESERVED_COUNT + 1))
    idx=$((idx + 1))
    continue
  fi

  # BLOCKER 2: re-verify the tree is clean at the TOP of each iteration — a prior
  # gate (or anything else) that left the tree dirty must not be silently built on.
  if ! tree_is_clean; then
    git checkout -q "$TARGET_BRANCH" >/dev/null 2>&1 || true
    log "working tree became dirty before integrating $branch — stopping to avoid building on polluted state"
    record_result "$branch" "gate_dirtied_tree"
    PRESERVED_COUNT=$((PRESERVED_COUNT + 1))
    STOP=1
    STOPPED_AT="$branch"
    INTEGRATE_RESULT="stopped"
    idx=$((idx + 1))
    continue
  fi

  # integrate_one returns non-zero on conflict/gate_failed/gate_dirtied_tree/
  # update_failed; that is an expected control-flow signal, not an error, so
  # shield it from set -e. The outcome code is on stdout; the return status only
  # echoes it. Because `|| true` disables set -e inside the substitution,
  # integrate_one checks its own critical exit statuses (e.g. update-ref CAS)
  # explicitly rather than relying on set -e — see MAJOR 2, retry 2.
  code="$(integrate_one "$branch")" || true
  record_result "$branch" "$code"
  case "$code" in
    merged)            MERGED_COUNT=$((MERGED_COUNT + 1)) ;;
    already_contained) ALREADY_CONTAINED_COUNT=$((ALREADY_CONTAINED_COUNT + 1)) ;;
    *)
      # conflict | gate_failed | gate_dirtied_tree | update_failed -> preserve, stop.
      PRESERVED_COUNT=$((PRESERVED_COUNT + 1))
      STOP=1
      STOPPED_AT="$branch"
      INTEGRATE_RESULT="stopped"
      ;;
  esac
  idx=$((idx + 1))
done

# --- Optional deletion of proven-contained branches (--delete-merged only) --------
if [ "$DELETE_MERGED" -eq 1 ]; then
  idx=0
  while [ "$idx" -lt "$total" ]; do
    b="${RESULT_BRANCHES[$idx]}"
    code="${RESULT_CODES[$idx]}"
    if { [ "$code" = "merged" ] || [ "$code" = "already_contained" ]; } \
      && branch_contained_in_target "$b" "$TARGET_BRANCH"; then
      if git branch -d "$b" >/dev/null 2>&1; then
        log "deleted contained branch $b (--delete-merged)"
      else
        log "could not delete $b with 'git branch -d' (non-fast-forward safety check failed or checked out elsewhere) — preserving"
      fi
    fi
    idx=$((idx + 1))
  done
fi

# --- Write integrate-results.json -------------------------------------------------
# Per the output contract: into RUN_DIR when given, else a CWD-adjacent temp
# directory — deliberately NOT directly inside the target repo's working tree,
# since that would leave an untracked file behind and make "working tree is
# clean" checks (ours and the orchestrator's) lie about run state.
#
# CONCURRENCY (retry 2, MAJOR 1): `mktemp -d` already gives a unique per-run dir,
# so we NEVER reap or glob-delete sibling bugsweep-integrate-results.* dirs. The
# p74 topology runs many integrate.sh invocations in sibling worktrees under one
# parent; an unconditional reaper would destroy a concurrent peer's live results
# dir (and its unread integrate-results.json), and even a "reap then mktemp"
# ordering is a TOCTOU against a peer's fresh dir. Cleanup of these sidecar temp
# dirs is the orchestrator/teardown's job (bead 8d0 owns unattended-run
# reclamation) — exactly like --run-dir, where the caller owns the directory.
results_json_path=""
if [ -n "$RUN_DIR" ]; then
  results_json_path="${RUN_DIR}/integrate-results.json"
else
  results_parent="$(dirname "$(pwd)")"
  results_json_tmpdir="$(mktemp -d "${results_parent}/bugsweep-integrate-results.XXXXXX" 2>/dev/null || mktemp -d)"
  results_json_path="${results_json_tmpdir}/integrate-results.json"
fi

# JSON string escaper for the degraded (no-python3) fallback: escapes backslash,
# double-quote, and control chars so a branch name containing any of them still
# produces valid JSON (MAJOR 4). git permits a literal '"' in ref names (verified
# via git check-ref-format) — that's the case a naive writer breaks on. It rejects
# backslash, but we escape it anyway for defense in depth. Special-char match and
# replacement literals are built with printf so no ambiguous shell-escaping of a
# backslash or quote is needed (keeps this shellcheck-clean).
json_escape() {
  local s="$1" out="" i c
  local bs dq tab nl cr
  bs="$(printf '\134')"   # backslash
  dq="$(printf '\042')"   # double-quote
  tab="$(printf '\t')"
  nl="$(printf '\n')"
  cr="$(printf '\r')"
  i=0
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    if [ "$c" = "$bs" ]; then
      out="${out}${bs}${bs}"
    elif [ "$c" = "$dq" ]; then
      out="${out}${bs}${dq}"
    elif [ "$c" = "$tab" ]; then
      out="${out}${bs}t"
    elif [ "$c" = "$nl" ]; then
      out="${out}${bs}n"
    elif [ "$c" = "$cr" ]; then
      out="${out}${bs}r"
    else
      out="${out}${c}"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

want_python() {
  [ -z "${BUGSWEEP_FORCE_NO_PYTHON:-}" ] && command -v python3 >/dev/null 2>&1
}

write_results_json() {
  local out="$1"
  if want_python; then
    BSW_TARGET="$TARGET_BRANCH" \
    BSW_RESULT="$INTEGRATE_RESULT" \
    BSW_STOPPED_AT="$STOPPED_AT" \
    BSW_MERGED_COUNT="$MERGED_COUNT" \
    BSW_ALREADY_CONTAINED_COUNT="$ALREADY_CONTAINED_COUNT" \
    BSW_PRESERVED_COUNT="$PRESERVED_COUNT" \
    BSW_BRANCHES="$(printf '%s\n' "${RESULT_BRANCHES[@]}")" \
    BSW_CODES="$(printf '%s\n' "${RESULT_CODES[@]}")" \
    python3 - "$out" <<'PY'
import json
import os
import sys

out_path = sys.argv[1]
# Branch names cannot contain newlines in git, so splitlines() is a safe pairing.
branches = os.environ["BSW_BRANCHES"].splitlines()
codes = os.environ["BSW_CODES"].splitlines()
data = {
    "target_branch": os.environ["BSW_TARGET"],
    "result": os.environ["BSW_RESULT"],
    "stopped_at": os.environ["BSW_STOPPED_AT"] or None,
    "merged_count": int(os.environ["BSW_MERGED_COUNT"]),
    "already_contained_count": int(os.environ["BSW_ALREADY_CONTAINED_COUNT"]),
    "preserved_count": int(os.environ["BSW_PRESERVED_COUNT"]),
    "branches": [
        {"branch": b, "status": c} for b, c in zip(branches, codes)
    ],
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  else
    # Degraded fallback for machines without python3 (or forced via
    # BUGSWEEP_FORCE_NO_PYTHON): hand-rolled JSON with every interpolated string
    # field passed through json_escape so quotes/backslashes stay valid (MAJOR 4).
    local first=1 fidx esc_target esc_stopped esc_branch esc_code
    esc_target="$(json_escape "$TARGET_BRANCH")"
    {
      printf '{\n'
      printf '  "target_branch": "%s",\n' "$esc_target"
      printf '  "result": "%s",\n' "$INTEGRATE_RESULT"
      if [ -n "$STOPPED_AT" ]; then
        esc_stopped="$(json_escape "$STOPPED_AT")"
        printf '  "stopped_at": "%s",\n' "$esc_stopped"
      else
        printf '  "stopped_at": null,\n'
      fi
      printf '  "merged_count": %s,\n' "$MERGED_COUNT"
      printf '  "already_contained_count": %s,\n' "$ALREADY_CONTAINED_COUNT"
      printf '  "preserved_count": %s,\n' "$PRESERVED_COUNT"
      printf '  "branches": [\n'
      fidx=0
      while [ "$fidx" -lt "$total" ]; do
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        esc_branch="$(json_escape "${RESULT_BRANCHES[$fidx]}")"
        esc_code="$(json_escape "${RESULT_CODES[$fidx]}")"
        printf '    {"branch": "%s", "status": "%s"}' "$esc_branch" "$esc_code"
        fidx=$((fidx + 1))
      done
      printf '\n  ]\n'
      printf '}\n'
    } > "$out"
  fi
}
write_results_json "$results_json_path"

# --- Stable output contract -------------------------------------------------------
idx=0
while [ "$idx" -lt "$total" ]; do
  echo "BRANCH_RESULT=${RESULT_BRANCHES[$idx]}:${RESULT_CODES[$idx]}"
  idx=$((idx + 1))
done

echo "INTEGRATE_RESULT=${INTEGRATE_RESULT}"
[ -n "$STOPPED_AT" ] && echo "STOPPED_AT=${STOPPED_AT}"
echo "MERGED_COUNT=${MERGED_COUNT}"
echo "ALREADY_CONTAINED_COUNT=${ALREADY_CONTAINED_COUNT}"
echo "PRESERVED_COUNT=${PRESERVED_COUNT}"
echo "RESULTS_JSON=${results_json_path}"

if [ "$INTEGRATE_RESULT" = "stopped" ]; then
  exit 1
fi
exit 0
