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
# Integration gates always reuse the frozen RUN_DIR check plan and external
# execution policy. Legacy BUGSWEEP_QUALITY_GATE_COMMAND text is never evaluated
# on the host and cannot replace those frozen gates.
#
# Never force-merges, force-pushes, or force-deletes. Never pushes (the orchestrator
# pushes). Deletes a branch only after merge-base containment proof AND only when
# --delete-merged is passed (default: preserve every branch).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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
[ -n "$RUN_DIR" ] || die_usage "--run-dir is required for source-bound integration evidence"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
[ -f "${RUN_DIR}/check-plan.json" ] || die_usage "RUN_DIR lacks frozen check-plan.json"
[ -f "${RUN_DIR}/baseline.json" ] || die_usage "RUN_DIR lacks baseline.json"
command -v python3 >/dev/null 2>&1 || die_usage "python3 is required for trusted integration checks"

# --- Preconditions -------------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die_usage "not inside a git repo"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
# _integration_checks.py accepts only a canonical regular executable. `command
# -v git` may be a Homebrew symlink, so resolve it before the trusted handoff.
GIT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$(command -v git)")"

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
# This label is evidence metadata. Target execution happens only inside the shared
# provider, against the exact merged-tree export made by _integration_checks.py.
QUALITY_GATE_COMMAND="provider:frozen-check-plan"
if [ -n "${BUGSWEEP_QUALITY_GATE_COMMAND:-}" ]; then
  log "ignoring legacy BUGSWEEP_QUALITY_GATE_COMMAND; frozen provider checks are mandatory"
fi

run_quality_gate() {
  local merge_sha="$1" branch="$2"
  python3 -B "${SCRIPT_DIR}/_integration_checks.py" \
    --run-dir "$RUN_DIR" \
    --repo-root "$REPO_ROOT" \
    --merge-sha "$merge_sha" \
    --branch "$branch" \
    --git-path "$GIT_PATH"
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
RESULT_SOURCE_TIPS=()
RESULT_TARGET_TIPS=()
RESULT_GATE_PASSED=()
MERGED_COUNT=0
ALREADY_CONTAINED_COUNT=0
PRESERVED_COUNT=0
STOPPED_AT=""
INTEGRATE_RESULT="complete"

record_result() {
  RESULT_BRANCHES+=("$1")
  RESULT_CODES+=("$2")
  RESULT_SOURCE_TIPS+=("${3:-}")
  RESULT_TARGET_TIPS+=("${4:-}")
  RESULT_GATE_PASSED+=("${5:-false}")
}

# --- Core per-branch integration -------------------------------------------------
# Prints the outcome code on stdout (merged|already_contained|conflict|gate_failed|
# gate_dirtied_tree|update_failed). Never moves the target branch to a bad state: it detaches HEAD
# at the target's current tip, builds the merge commit there, gates it, and only
# fast-forwards the real target ref onto a gate-passed commit. The next branch's
# iteration re-derives the tip from $TARGET_BRANCH, so there is no cross-iteration
# state to carry.
integrate_one() {
  local branch="$1" tip merge_sha gate_sha

  if branch_contained_in_target "$branch" "$TARGET_BRANCH"; then
    log "$branch is already contained in $TARGET_BRANCH — re-running the quality gate for a tip-bound receipt"
    local contained_output contained_status=0
    gate_sha="$(git rev-parse "$TARGET_BRANCH")"
    contained_output="$(run_quality_gate "$gate_sha" "$branch" 2>&1)" || contained_status=$?
    [ -n "$contained_output" ] && printf '%s\n' "$contained_output" | sed 's/^/integrate:   gate> /' >&2
    if ! tree_is_clean; then
      log "QUALITY GATE DIRTIED THE WORKING TREE for already-contained $branch — stopping"
      printf 'gate_dirtied_tree'
      return 1
    fi
    if [ "$contained_status" -ne 0 ]; then
      log "QUALITY GATE FAILED for already-contained $branch (exit ${contained_status}) — stopping"
      printf 'gate_failed'
      return 1
    fi
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
  gate_output="$(run_quality_gate "$merge_sha" "$branch" 2>&1)" || gate_status=$?
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
    record_result "$branch" "skipped_after_stop" "$(git rev-parse "$branch")" "$(git rev-parse "$TARGET_BRANCH")" false
    PRESERVED_COUNT=$((PRESERVED_COUNT + 1))
    idx=$((idx + 1))
    continue
  fi

  # BLOCKER 2: re-verify the tree is clean at the TOP of each iteration — a prior
  # gate (or anything else) that left the tree dirty must not be silently built on.
  if ! tree_is_clean; then
    git checkout -q "$TARGET_BRANCH" >/dev/null 2>&1 || true
    log "working tree became dirty before integrating $branch — stopping to avoid building on polluted state"
    record_result "$branch" "gate_dirtied_tree" "$(git rev-parse "$branch")" "$(git rev-parse "$TARGET_BRANCH")" false
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
  source_tip="$(git rev-parse "$branch")"
  code="$(integrate_one "$branch")" || true
  target_tip="$(git rev-parse "$TARGET_BRANCH")"
  gate_passed=false
  case "$code" in merged|already_contained) gate_passed=true ;; esac
  record_result "$branch" "$code" "$source_tip" "$target_tip" "$gate_passed"
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
# RUN_DIR is mandatory because successful rows must bind immutable provider and
# merged-source evidence held outside the target repository.
results_json_path="${RUN_DIR}/integrate-results.json"

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
  command -v python3 >/dev/null 2>&1
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
    BSW_SOURCE_TIPS="$(printf '%s\n' "${RESULT_SOURCE_TIPS[@]}")" \
    BSW_TARGET_TIPS="$(printf '%s\n' "${RESULT_TARGET_TIPS[@]}")" \
    BSW_GATE_PASSED="$(printf '%s\n' "${RESULT_GATE_PASSED[@]}")" \
    BSW_GATE_COMMAND="$QUALITY_GATE_COMMAND" \
    BSW_RUN_DIR="$RUN_DIR" \
    python3 - "$out" <<'PY'
import hashlib
import json
import os
import sys

out_path = sys.argv[1]
# Branch names cannot contain newlines in git, so splitlines() is a safe pairing.
branches = os.environ["BSW_BRANCHES"].splitlines()
codes = os.environ["BSW_CODES"].splitlines()
source_tips = os.environ["BSW_SOURCE_TIPS"].splitlines()
target_tips = os.environ["BSW_TARGET_TIPS"].splitlines()
gate_passed = os.environ["BSW_GATE_PASSED"].splitlines()
run_dir = os.path.realpath(os.environ["BSW_RUN_DIR"])
rows = []
for branch, code, source, target, passed in zip(
        branches, codes, source_tips, target_tips, gate_passed):
    row = {"branch": branch, "status": code, "source_tip": source,
           "target_tip": target, "quality_gate_passed": passed == "true"}
    if passed == "true":
        branch_hash = hashlib.sha256(branch.encode("utf-8")).hexdigest()[:16]
        receipt = os.path.join(run_dir, "integration-check-results", f"{target}-{branch_hash}.json")
        if os.path.islink(receipt) or os.path.getsize(receipt) > 256 * 1024 * 1024:
            raise SystemExit("integration suite receipt path is unsafe")
        with open(receipt, "rb") as handle:
            raw = handle.read()
        suite = json.loads(raw)
        if (suite.get("status") != "verified" or suite.get("merge_sha") != target
                or suite.get("branch") != branch):
            raise SystemExit("integration suite binding is invalid")
        row.update({
            "integration_suite_receipt_path": os.path.relpath(receipt, run_dir),
            "integration_suite_receipt_sha256": hashlib.sha256(raw).hexdigest(),
            "integration_merge_sha": suite["merge_sha"],
            "integration_source_manifest_sha256": suite["source_manifest_sha256"],
        })
    rows.append(row)
data = {
    "target_branch": os.environ["BSW_TARGET"],
    "quality_gate_command": os.environ["BSW_GATE_COMMAND"],
    "result": os.environ["BSW_RESULT"],
    "stopped_at": os.environ["BSW_STOPPED_AT"] or None,
    "merged_count": int(os.environ["BSW_MERGED_COUNT"]),
    "already_contained_count": int(os.environ["BSW_ALREADY_CONTAINED_COUNT"]),
    "preserved_count": int(os.environ["BSW_PRESERVED_COUNT"]),
    "branches": rows,
}
with open(out_path, "x", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  else
    # Degraded fallback for machines without python3 (or forced via
    # BUGSWEEP_FORCE_NO_PYTHON): hand-rolled JSON with every interpolated string
    # field passed through json_escape so quotes/backslashes stay valid (MAJOR 4).
    local first=1 fidx esc_target esc_stopped esc_branch esc_code esc_source esc_result_target esc_gate_command
    esc_target="$(json_escape "$TARGET_BRANCH")"
    esc_gate_command="$(json_escape "$QUALITY_GATE_COMMAND")"
    {
      printf '{\n'
      printf '  "target_branch": "%s",\n' "$esc_target"
      printf '  "quality_gate_command": "%s",\n' "$esc_gate_command"
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
        esc_source="$(json_escape "${RESULT_SOURCE_TIPS[$fidx]}")"
        esc_result_target="$(json_escape "${RESULT_TARGET_TIPS[$fidx]}")"
        printf '    {"branch": "%s", "status": "%s", "source_tip": "%s", "target_tip": "%s", "quality_gate_passed": %s}' \
          "$esc_branch" "$esc_code" "$esc_source" "$esc_result_target" "${RESULT_GATE_PASSED[$fidx]}"
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
