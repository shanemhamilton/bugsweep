#!/usr/bin/env bash
# bugsweep finalize: return the user to exactly where they started, with the fix
# commits quarantined on the bugsweep branch for review. Idempotent and safe.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="${1:-}"
[ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: finalize.sh <RUN_DIR>"
# Resolve to absolute so appends still work after we switch branches/cwd.
run_dir="$(cd "$run_dir" && pwd)"
# shellcheck disable=SC1090
. "${run_dir}/state.env"

require_git_repo

# Commit any stray uncommitted fix work on the bugsweep branch so switching is clean.
if ! git diff --quiet --ignore-submodules HEAD 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  git add -A >/dev/null 2>&1 || true
  git commit -m "fix(bugsweep): finalize uncommitted work" >/dev/null 2>&1 || true
fi

# Persist this run's audit coverage + risk into .bugsweep/state/ so the next run
# resumes the whole-repo frontier instead of starting blind. Best-effort: a failure
# here must never block finalize or strand the user off their branch.
if bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" persist "$run_dir" >/dev/null 2>&1; then
  log "Persisted audit coverage + risk to .bugsweep/state/ for future runs."
else
  log "WARNING: could not persist cross-run state (continuing; not fatal)."
fi
bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" lease-release "$run_dir" >/dev/null 2>&1 || true  # bugsweep-p74: release this run's lease (best-effort, non-fatal)

# Emit a stub report when report.md was never written (silent-failure backstop).
# A large-repo run may stall during context-build or the architectural hunt before
# the model ever reaches the report template. This backstop ensures the user always
# gets a coverage summary from on-disk state, regardless of where execution stopped.
_emit_stub_report() {
  local report="${run_dir}/report.md"
  [ -f "$report" ] && return 0          # real report exists — do not overwrite

  local covered=0 total=0
  if [ -f "${run_dir}/recon.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      covered="$(jq -r '.covered | length'         "${run_dir}/recon.json" 2>/dev/null || printf '0')"
      total="$(  jq -r '.batch_count // (.batches | length)' "${run_dir}/recon.json" 2>/dev/null || printf '0')"
    elif command -v python3 >/dev/null 2>&1; then
      covered="$(python3 -c \
        'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("covered",[])))' \
        "${run_dir}/recon.json" 2>/dev/null || printf '0')"
      total="$(python3 -c \
        'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("batch_count",len(d.get("batches",[]))))' \
        "${run_dir}/recon.json" 2>/dev/null || printf '0')"
    fi
  fi
  # Sanitise: accept only digits so arithmetic below never sees garbage.
  case "$covered" in ''|*[!0-9]*) covered=0 ;; esac
  case "$total"   in ''|*[!0-9]*) total=0   ;; esac

  local fixes
  fixes="$(count_event "${run_dir}/ledger.jsonl" "fix_committed")"

  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"

  cat > "$report" <<STUB
# bugsweep report — ${ts}
**Branch:** ${BUGSWEEP_BRANCH}   **Mode:** detect-only (partial)
**WARNING: INCOMPLETE RUN** — the model did not produce a full report. The run likely
stalled during context-build or the architectural hunt before reaching the report step.

## Summary
- Coverage: ${covered}/${total} batches — PARTIAL RUN (stalled before report)
- Fixes committed: ${fixes}
- See ledger.jsonl for the full event log

## How to review
git diff ${BUGSWEEP_ORIG_BRANCH}..${BUGSWEEP_BRANCH}
git -C . log --oneline ${BUGSWEEP_ORIG_BRANCH}..${BUGSWEEP_BRANCH}
STUB

  # Sentinel: the durable, content-independent record that this run's report.md
  # is the script-emitted stub. Primary stub-detection signal (see below) — a
  # retried finalize must classify from this, never from a this-invocation-wrote-it
  # flag, and never from an unanchored content grep that a REAL report quoting the
  # warning text (or our own appended machine block) could trigger.
  : > "${run_dir}/.report-is-stub"

  log "WARNING: report.md was missing — emitted a stub from on-disk state. Check ledger.jsonl."
}
_emit_stub_report

# Stub-ness detection, in priority order:
#   1. Sentinel file .report-is-stub — written by _emit_stub_report alongside the
#      stub. Content-independent, so a REAL report whose prose merely QUOTES the
#      stub's warning text (routine on bugsweep-on-bugsweep runs) can never be
#      misclassified, and a retried finalize stays stable.
#   2. Fallback for PRE-SENTINEL run dirs only (stub written by an older finalize
#      that had no sentinel): grep for the stub template's exact warning-line form
#      (the line the heredoc above starts with '**WARNING: INCOMPLETE RUN**'),
#      restricted to the region of report.md BEFORE the script-appended
#      '## Findings (machine-readable)' heading — so our own appended block, which
#      may embed marker-quoting finding rationales from the ledger, can never
#      trigger it on a retry.
_bugsweep_report_was_stub=false
if [ -f "${run_dir}/.report-is-stub" ]; then
  _bugsweep_report_was_stub=true
elif [ -f "${run_dir}/report.md" ] \
  && sed '/^## Findings (machine-readable)$/,$d' "${run_dir}/report.md" 2>/dev/null \
     | grep -q '^\*\*WARNING: INCOMPLETE RUN\*\*'; then
  _bugsweep_report_was_stub=true
fi

# Reduce ledger.jsonl + recon.json into run-summary.json UNCONDITIONALLY — on both
# the real-report path and the stub/partial path above — so a headless scheduler
# (nightshift) always has a deterministic, schema-valid summary to branch on,
# regardless of where the run stopped. See scripts/summarize.sh.
_bugsweep_run_summary_path=""
_write_run_summary_and_machine_block() {
  local report="${run_dir}/report.md"
  local summary_out
  if ! summary_out="$(bash "${BUGSWEEP_SCRIPT_DIR}/summarize.sh" "$run_dir" "$_bugsweep_report_was_stub" "${BUGSWEEP_MODE:-}" 2>&1)"; then
    log "WARNING: summarize.sh failed; run-summary.json may be missing. Output: ${summary_out}"
    return 0
  fi
  _bugsweep_run_summary_path="${summary_out#RUN_SUMMARY=}"
  [ -f "$_bugsweep_run_summary_path" ] || { log "WARNING: summarize.sh reported success but ${_bugsweep_run_summary_path} is missing."; return 0; }

  # Generate the report's "Findings (machine-readable)" block FROM run-summary.json
  # so prose and JSON never diverge (SKILL.md's report template no longer asks the
  # model to author this block itself). Skip only if report.md already has one —
  # idempotent re-runs (e.g. a retried finalize) must not duplicate the section —
  # but WARN when skipping: a pre-existing block (an old-format model-authored
  # report, or a prior finalize's block over changed state) may diverge from the
  # freshly reduced run-summary.json, and that divergence must be visible.
  if [ -f "$report" ]; then
    if grep -q '^## Findings (machine-readable)$' "$report" 2>/dev/null; then
      log "WARNING: report.md already contains a 'Findings (machine-readable)' section — leaving it untouched. If it predates this finalize (e.g. a model-authored block from an older template), its JSON may diverge from ${_bugsweep_run_summary_path}; trust run-summary.json."
    else
      {
        printf '\n## Findings (machine-readable)\n```json\n'
        if command -v python3 >/dev/null 2>&1; then
          python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get("findings",[]), indent=2))' \
            "$_bugsweep_run_summary_path" 2>/dev/null || printf '[]'
        else
          printf '[]'
        fi
        printf '\n```\n'
      } >> "$report"
    fi
  fi
}
_write_run_summary_and_machine_block

_write_post_finalize_handoff() {
  local handoff="${run_dir}/post-finalize-handoff.json"
  local report="${run_dir}/report.md"
  local quality_gate="${BUGSWEEP_QUALITY_GATE_COMMAND:-bash scripts/run_checks.sh verify \"${run_dir}\"}"
  local push_policy="${BUGSWEEP_PUSH_POLICY:-Push the target branch only after merge, quality gate, smoke checks, and remote read-back succeed; never force-push.}"
  local cleanup_policy="${BUGSWEEP_CLEANUP_POLICY:-Use scripts/bugsweep-cleanup.sh after approval; delete the bugsweep branch only after merge-base containment proof, removing only clean linked worktrees and never using --force.}"

  if command -v python3 >/dev/null 2>&1; then
    RUN_DIR="$run_dir" \
    ORIGINAL_BRANCH="$BUGSWEEP_ORIG_BRANCH" \
    PRESERVED_BRANCH="$BUGSWEEP_BRANCH" \
    REPORT_PATH="$report" \
    QUALITY_GATE_COMMAND="$quality_gate" \
    BUGSWEEP_FOCUSED_TESTS="${BUGSWEEP_FOCUSED_TESTS:-}" \
    BUGSWEEP_SMOKE_TEST_COMMANDS="${BUGSWEEP_SMOKE_TEST_COMMANDS:-}" \
    BUGSWEEP_WORKTREE="${BUGSWEEP_WORKTREE:-}" \
    PUSH_POLICY="$push_policy" \
    CLEANUP_POLICY="$cleanup_policy" \
    python3 - "$handoff" <<'PY'
import json
import os
import subprocess
import sys

handoff_path = sys.argv[1]
run_dir = os.environ["RUN_DIR"]
original = os.environ["ORIGINAL_BRANCH"]
preserved = os.environ["PRESERVED_BRANCH"]
report = os.environ["REPORT_PATH"]
quality_gate = os.environ["QUALITY_GATE_COMMAND"]


def split_commands(value):
    return [line.strip() for line in value.splitlines() if line.strip()]


def git_lines(args):
    try:
        proc = subprocess.run(
            ["git"] + args,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


fix_commits = []
for sha in git_lines(["rev-list", "--reverse", f"{original}..{preserved}"]):
    subject = git_lines(["log", "-1", "--format=%s", sha])
    fix_commits.append({"sha": sha, "subject": subject[0] if subject else ""})

handoff = {
    "run_dir": run_dir,
    "original_branch": original,
    "preserved_branch": preserved,
    "report_path": report,
    # Manual-cleanup breadcrumb for worktree-mode runs (empty string otherwise);
    # full worktree teardown is bead 8d0's job, not finalize's.
    "worktree_path": os.environ.get("BUGSWEEP_WORKTREE", ""),
    "fix_commits": fix_commits,
    "focused_tests": split_commands(os.environ.get("BUGSWEEP_FOCUSED_TESTS", "")),
    "quality_gate_command": quality_gate,
    "smoke_test_commands": split_commands(os.environ.get("BUGSWEEP_SMOKE_TEST_COMMANDS", "")),
    "push_policy": os.environ["PUSH_POLICY"],
    "cleanup_policy": os.environ["CLEANUP_POLICY"],
    "safe_to_delete_branch_after": (
        f"git merge-base --is-ancestor {preserved} <target-branch> succeeds; "
        "if the branch is checked out in a linked worktree, that worktree must be clean "
        "before it may be removed."
    ),
    "final_readback_commands": [
        "git status --short --branch",
        f"git merge-base --is-ancestor {preserved} <target-branch> && echo BRANCH_CONTAINED={preserved}",
        "git branch --list 'bugsweep/*'",
        "git ls-remote --heads origin <target-branch>",
    ],
}

with open(handoff_path, "w", encoding="utf-8") as f:
    json.dump(handoff, f, indent=2)
    f.write("\n")
PY
  else
    # Minimal fallback for bare machines. The normal path above records commits too.
    cat > "$handoff" <<JSON
{
  "run_dir": "${run_dir}",
  "original_branch": "${BUGSWEEP_ORIG_BRANCH}",
  "preserved_branch": "${BUGSWEEP_BRANCH}",
  "report_path": "${report}",
  "worktree_path": "${BUGSWEEP_WORKTREE:-}",
  "fix_commits": [],
  "focused_tests": [],
  "quality_gate_command": "${quality_gate}",
  "smoke_test_commands": [],
  "push_policy": "${push_policy}",
  "cleanup_policy": "${cleanup_policy}",
  "safe_to_delete_branch_after": "git merge-base --is-ancestor ${BUGSWEEP_BRANCH} <target-branch> succeeds; linked worktree must be clean before removal.",
  "final_readback_commands": [
    "git status --short --branch",
    "git merge-base --is-ancestor ${BUGSWEEP_BRANCH} <target-branch> && echo BRANCH_CONTAINED=${BUGSWEEP_BRANCH}",
    "git branch --list 'bugsweep/*'",
    "git ls-remote --heads origin <target-branch>"
  ]
}
JSON
  fi
}
_write_post_finalize_handoff

# Return the user to their original branch (the bugsweep branch is preserved).
#
# Review fix E (bugsweep-p74): in worktree mode there is nothing to return or
# restore — the run never touched the user's tree (it worked in its own linked
# worktree, and STASH is always none), and git's checkout collision guard
# would (correctly) refuse to check the original branch out here anyway, since
# the user's main checkout still holds it. Skipping with an accurate log line
# replaces the old misleading generic WARNING. Worktree/branch teardown itself
# is deliberately NOT done here (bead 8d0's job); post-finalize-handoff.json
# carries worktree_path as the manual-cleanup breadcrumb.
if [ -n "${BUGSWEEP_WORKTREE:-}" ]; then
  log "worktree run — user's tree untouched, nothing to restore (worktree: ${BUGSWEEP_WORKTREE})."
else
  if [ "$(current_branch)" != "$BUGSWEEP_ORIG_BRANCH" ]; then
    git checkout "$BUGSWEEP_ORIG_BRANCH" >/dev/null 2>&1 \
      || log "WARNING: could not switch back to ${BUGSWEEP_ORIG_BRANCH}; you are still on ${BUGSWEEP_BRANCH}."
  fi

  # Restore the user's stashed work, if any.
  if [ "${BUGSWEEP_STASH_REF}" != "none" ]; then
    if git stash list | grep -q "bugsweep-autostash-${BUGSWEEP_TS}"; then
      if git stash pop >/dev/null 2>&1; then
        log "Restored your stashed work onto ${BUGSWEEP_ORIG_BRANCH}."
      else
        log "WARNING: could not auto-restore your stash. It is safe in: git stash list (bugsweep-autostash-${BUGSWEEP_TS})."
      fi
    fi
  fi
fi

if [ -n "${BUGSWEEP_WORKTREE:-}" ] && [ -f "${BUGSWEEP_SCRIPT_DIR}/bugsweep-cleanup.sh" ]; then
  # bugsweep-8d0 dataloss re-review MAJOR 1: write a durable ".finalized"
  # sentinel into this run's run_dir BEFORE invoking the reaper. This is the
  # positive "the run is definitively over" signal the reaper needs to safely
  # reap THIS worktree — the reaper now preserves-on-ambiguity (a released
  # lease is indistinguishable from a reclaimed-stale one, and the ledger is
  # typically fresh at finalize time), so without this sentinel a
  # just-finalized worktree whose lease is already released would be preserved
  # forever ("no live lease + stale-ledger only" is the reap path; a released
  # lease is "no lease record" → ambiguous → preserve). The sentinel lives
  # under .bugsweep/ (git-excluded) and lets BOTH this reaper call and any
  # later session-end sweep reap finalized runs deterministically. (Same
  # sentinel-file idiom finalize already uses for .report-is-stub.)
  : > "${run_dir}/.finalized" 2>/dev/null || true
  if cd "$BUGSWEEP_REPO_ROOT" 2>/dev/null; then
    bash "${BUGSWEEP_SCRIPT_DIR}/bugsweep-cleanup.sh" --reap-worktrees \
      || log "WARNING: worktree reaper failed; ${BUGSWEEP_WORKTREE} may still need manual cleanup."
  else
    log "WARNING: could not enter repo root for worktree reaper; ${BUGSWEEP_WORKTREE} may still need manual cleanup."
  fi
fi

printf '{"event":"finalize","branch":"%s","orig_branch":"%s"}\n' \
  "$BUGSWEEP_BRANCH" "$BUGSWEEP_ORIG_BRANCH" >> "${run_dir}/ledger.jsonl" 2>/dev/null || true

echo "FINALIZED"
echo "REVIEW_WITH=git diff ${BUGSWEEP_ORIG_BRANCH}..${BUGSWEEP_BRANCH}"
echo "REPORT=${run_dir}/report.md"
echo "RUN_SUMMARY=${_bugsweep_run_summary_path:-${run_dir}/run-summary.json}"
echo "POST_FINALIZE_HANDOFF=${run_dir}/post-finalize-handoff.json"
echo "BRANCH_PRESERVED=${BUGSWEEP_BRANCH}"
