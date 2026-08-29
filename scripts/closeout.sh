#!/usr/bin/env bash
# Enforce Bugsweep's terminal invariant for one exact run-owned branch/worktree.
# Usage: closeout.sh <RUN_DIR> <landed|recorded>

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="${1:-}"
outcome="${2:-}"
[ -n "$run_dir" ] && [ -d "$run_dir" ] \
  || die "usage: closeout.sh <RUN_DIR> <landed|recorded>"
case "$outcome" in landed|recorded) ;; *) die "outcome must be landed or recorded" ;; esac
run_dir="$(cd "$run_dir" && pwd)"
[ -f "${run_dir}/state.env" ] || die "missing ${run_dir}/state.env"
invoking_repo_root="$BUGSWEEP_REPO_ROOT"
# shellcheck disable=SC1090
. "${run_dir}/state.env"

require_git_repo
[ "${BUGSWEEP_REPO_ROOT:-}" = "$invoking_repo_root" ] \
  || die "run state belongs to a different repository"
case "$BUGSWEEP_BRANCH" in bugsweep/*) ;; *) die "refusing non-bugsweep branch: $BUGSWEEP_BRANCH" ;; esac

run_id="${BUGSWEEP_RUN_ID:-$BUGSWEEP_TS}"
block_dir="${BUGSWEEP_REPO_ROOT}/.bugsweep/state/closeout-blocked"
block_file="${block_dir}/${run_id}.json"
mkdir -p "$block_dir"
write_block() {
  local state="$1"
  printf '{"run_id":"%s","run_dir":"%s","branch":"%s","worktree":"%s","state":"%s"}\n' \
    "$(_bsw_json_escape "$run_id")" "$(_bsw_json_escape "$run_dir")" \
    "$(_bsw_json_escape "$BUGSWEEP_BRANCH")" "$(_bsw_json_escape "${BUGSWEEP_WORKTREE:-}")" \
    "$(_bsw_json_escape "$state")" > "$block_file"
}
write_block "INCOMPLETE_CLEANUP"

branch_exists() { git show-ref --verify --quiet "refs/heads/$1"; }
authorize_cleanup() {
  local tip
  tip="$(git rev-parse "$BUGSWEEP_BRANCH")"
  printf '{"authorized":true,"outcome":"%s","branch":"%s","tip":"%s"}\n' \
    "$(_bsw_json_escape "$outcome")" "$(_bsw_json_escape "$BUGSWEEP_BRANCH")" \
    "$(_bsw_json_escape "$tip")" > "${run_dir}/cleanup-authorization.json"
}
remove_owned_worktree() {
  [ -z "${BUGSWEEP_WORKTREE:-}" ] || [ ! -d "$BUGSWEEP_WORKTREE" ] || {
    python3 - "$BUGSWEEP_WORKTREE" "$BUGSWEEP_WORKTREES_DIR" "$BUGSWEEP_BRANCH" <<'PY'
import pathlib, subprocess, sys
path, root, branch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve(), sys.argv[3]
if path.parent != root:
    raise SystemExit(f"owned worktree is outside Bugsweep root: {path}")
blocks = subprocess.check_output(["git", "worktree", "list", "--porcelain"], text=True).split("\n\n")
expected = f"branch refs/heads/{branch}"
if not any(f"worktree {path}" in block.splitlines() and expected in block.splitlines() for block in blocks):
    raise SystemExit("state worktree path is not registered to the exact run branch")
PY
    cd "$BUGSWEEP_REPO_ROOT"
    git worktree remove "$BUGSWEEP_WORKTREE" \
      || die "could not remove exact owned worktree: $BUGSWEEP_WORKTREE"
  }
}
verify_tracker_receipts() {
  local include_fixed="${1:-no}"
  python3 - "$run_dir" "$run_id" "$include_fixed" <<'PY'
import json, pathlib, subprocess, sys
run, run_id, include_fixed = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "yes"
summary = json.loads((run / "run-summary.json").read_text())
required = set()
names = ["quarantined", "confirmed_unfixed"]
if include_fixed:
    names.append("fixed")
for name in names:
    values = summary.get(name, [])
    if not isinstance(values, list) or any(not isinstance(x, str) for x in values):
        raise SystemExit(f"invalid run-summary field: {name}")
    required.update(x for x in values if x)
if summary.get("follow_up"):
    required.add(f"run:{run_id}:follow-up")
seen = set()
receipts = run / "tracker-receipts.jsonl"
if receipts.exists():
    for line in receipts.read_text().splitlines():
        try:
            receipt = json.loads(line)
            valid = (receipt.get("readback_verified")
                     and (receipt.get("tracker") or receipt.get("provider"))
                     and receipt.get("item_id"))
            if valid:
                seen.update(str(key) for key in
                            (receipt.get("finding_key"), receipt.get("bug_id")) if key)
        except (json.JSONDecodeError, TypeError):
            pass
missing = required - seen
if missing:
    raise SystemExit("verified tracker readback missing keys: " + ", ".join(sorted(missing)))
if not seen:
    raise SystemExit("verified tracker readback receipt required before cleanup")
PY
}
verify_recovery_review() {
  python3 - "$run_dir" "$BUGSWEEP_BRANCH" <<'PY'
import hashlib, json, pathlib, subprocess, sys
run, branch = pathlib.Path(sys.argv[1]), sys.argv[2]
bundle = run / "recovery.bundle"
subprocess.run(["git", "bundle", "verify", str(bundle)], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
sha = hashlib.sha256(bundle.read_bytes()).hexdigest()
tip = subprocess.check_output(["git", "rev-parse", branch], text=True).strip()
heads = subprocess.check_output(["git", "bundle", "list-heads", str(bundle)], text=True).splitlines()
if f"{tip} refs/heads/{branch}" not in heads:
    raise SystemExit("recovery bundle does not contain the exact branch tip")
review = json.loads((run / "deletion-review.json").read_text())
if not (review.get("approved") is True and review.get("branch") == branch
        and review.get("tip") == tip and review.get("bundle_sha256") == sha):
    raise SystemExit("fresh deletion review does not match exact branch tip and bundle")
receipts = [json.loads(line) for line in (run / "tracker-receipts.jsonl").read_text().splitlines() if line.strip()]
if not any(r.get("readback_verified") and r.get("recovery_bundle") == str(bundle)
           and r.get("recovery_sha256") == sha for r in receipts):
    raise SystemExit("tracker readback does not contain the verified recovery bundle path and digest")
PY
}
summary_actionable() {
  python3 - "$run_dir" <<'PY'
import json, pathlib, sys
summary = json.loads((pathlib.Path(sys.argv[1]) / "run-summary.json").read_text())
if summary.get("degraded") is True:
    raise SystemExit("degraded run summary cannot prove tracker completeness")
print(int(any(summary.get(k) for k in ("quarantined", "confirmed_unfixed", "follow_up"))))
PY
}
summary_fixed_count() {
  python3 - "$run_dir" <<'PY'
import json, pathlib, sys
summary = json.loads((pathlib.Path(sys.argv[1]) / "run-summary.json").read_text())
fixed = summary.get("fixed", [])
if not isinstance(fixed, list) or any(not isinstance(item, str) for item in fixed):
    raise SystemExit("invalid run-summary field: fixed")
print(len(fixed))
PY
}
verify_landed_evidence() {
  local referee_votes referee_votes_cap
  referee_votes="$(cfg_get '.adversarial.referee_votes' '3')"
  referee_votes_cap="$(cfg_get '.adversarial.referee_votes_cap' '5')"
  case "$referee_votes" in ''|*[!0-9]*|0) referee_votes=3 ;; esac
  case "$referee_votes_cap" in ''|*[!0-9]*|0) referee_votes_cap=5 ;; esac
  [ "$referee_votes" -le "$referee_votes_cap" ] || referee_votes="$referee_votes_cap"
  python3 - "$run_dir" "$BUGSWEEP_BRANCH" "$BUGSWEEP_ORIG_BRANCH" "${BUGSWEEP_MODE:-detect}" "$referee_votes" <<'PY'
import json, pathlib, subprocess, sys
run, branch, target, mode, required_votes = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
try:
    integration = json.loads((run / "integrate-results.json").read_text())
except (FileNotFoundError, json.JSONDecodeError):
    raise SystemExit("COMPLETED_LANDED requires a successful integration quality-gate receipt")
rows = [row for row in integration.get("branches", []) if row.get("branch") == branch]
if not (integration.get("result") == "complete" and integration.get("target_branch") == target
        and isinstance(integration.get("quality_gate_command"), str)
        and integration.get("quality_gate_command")
        and len(rows) == 1 and rows[0].get("status") in {"merged", "already_contained"}
        and rows[0].get("quality_gate_passed") is True):
    raise SystemExit("COMPLETED_LANDED requires a successful integration quality-gate receipt")
row = rows[0]
source_tip = subprocess.check_output(["git", "rev-parse", branch], text=True).strip()
current_target = subprocess.check_output(["git", "rev-parse", target], text=True).strip()
if row.get("source_tip") != source_tip or not row.get("target_tip"):
    raise SystemExit("integration receipt does not match the exact current branch tip")
def is_ancestor(older, newer):
    return subprocess.run(["git", "merge-base", "--is-ancestor", older, newer]).returncode == 0
if not is_ancestor(source_tip, row["target_tip"]):
    raise SystemExit("gated target tip does not contain the exact source tip")
if not is_ancestor(row["target_tip"], current_target):
    raise SystemExit("gated target tip is not in the current target history")
events = []
for line in (run / "ledger.jsonl").read_text().splitlines():
    try:
        events.append(json.loads(line))
    except json.JSONDecodeError:
        pass
if any(e.get("event") == "fix_committed" and not e.get("bug_id") for e in events):
    raise SystemExit("landed fix lacks a bug_id required for authorization ordering")
valid_severities = {"low", "medium", "high", "critical"}
if any(e.get("event") == "fix_committed" and e.get("severity") not in valid_severities
       for e in events):
    raise SystemExit("landed fix lacks a valid severity required for authorization")
for fix_index, event in enumerate(events):
    if event.get("event") != "fix_committed":
        continue
    bug = str(event["bug_id"])
    confirmed = [i for i, e in enumerate(events[:fix_index])
                 if str(e.get("bug_id")) == bug and e.get("event") == "referee_verdict"
                 and e.get("verdict") == "CONFIRMED"]
    if not confirmed:
        raise SystemExit(f"landed fix lacks a preceding Referee verdict: {bug}")
    severity = event["severity"]
    if severity in {"high", "critical"}:
        verdict_index = confirmed[-1]
        votes_before_verdict = [e.get("verdict") for e in events[:verdict_index]
                                if str(e.get("bug_id")) == bug
                                and e.get("event") == "referee_vote"]
        votes_before_fix = [e for e in events[:fix_index]
                            if str(e.get("bug_id")) == bug
                            and e.get("event") == "referee_vote"]
        if len(votes_before_verdict) != required_votes or len(votes_before_fix) != required_votes:
            raise SystemExit(f"high/critical fix lacks {required_votes} Referee votes before its verdict: {bug}")
        confirmed_votes = sum(vote == "CONFIRMED" for vote in votes_before_verdict)
        if confirmed_votes <= required_votes - confirmed_votes:
            raise SystemExit(f"high/critical fix lacks a preceding Referee majority: {bug}")
    if mode == "approve":
        approved = [i for i, e in enumerate(events[:fix_index])
                    if str(e.get("bug_id")) == bug and e.get("event") == "approval"
                    and e.get("approved") is True and i > confirmed[-1]]
        if not approved:
            raise SystemExit(f"landed fix lacks a preceding approval receipt: {bug}")
        repro_before_fix = [i for i, e in enumerate(events[:fix_index])
                            if str(e.get("bug_id")) == bug and e.get("event") == "repro_status"]
        if repro_before_fix and approved[-1] > repro_before_fix[0]:
            raise SystemExit(f"approval receipt follows reproduction: {bug}")
PY
}
if ! branch_exists "$BUGSWEEP_BRANCH"; then
  [ -z "${BUGSWEEP_WORKTREE:-}" ] || [ ! -d "$BUGSWEEP_WORKTREE" ] \
    || die "branch is gone but owned worktree remains: $BUGSWEEP_WORKTREE"
  python3 - "$run_dir" "$BUGSWEEP_BRANCH" "$outcome" "$BUGSWEEP_ORIG_BRANCH" <<'PY'
import json, pathlib, subprocess, sys
run, branch, outcome, target = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
auth = json.loads((run / "cleanup-authorization.json").read_text())
if not (auth.get("authorized") is True and auth.get("branch") == branch and auth.get("outcome") == outcome):
    raise SystemExit("owned branch vanished without matching cleanup authorization")
if outcome == "landed":
    subprocess.run(["git", "merge-base", "--is-ancestor", auth["tip"], target], check=True)
PY
else
  if [ -n "${BUGSWEEP_WORKTREE:-}" ] && [ -d "$BUGSWEEP_WORKTREE" ]; then
    git -C "$BUGSWEEP_WORKTREE" diff --quiet \
      && git -C "$BUGSWEEP_WORKTREE" diff --cached --quiet \
      && [ -z "$(git -C "$BUGSWEEP_WORKTREE" ls-files --others --exclude-standard)" ] \
      && [ -z "$(git -C "$BUGSWEEP_WORKTREE" ls-files --others --ignored --exclude-standard)" ] \
      || die "owned worktree is dirty; restore or narrowly commit its exact changes before closeout"
  fi

  if [ "$outcome" = "landed" ]; then
    fixed_count="$(summary_fixed_count)"
    [ "$fixed_count" -gt 0 ] \
      || die "COMPLETED_LANDED requires at least one fixed finding; use recorded for a no-fix run"
    actionable="$(summary_actionable)"
    if [ "$actionable" != "0" ]; then
      write_block "INCOMPLETE_TRACKER"
      verify_tracker_receipts no
    fi
    verify_landed_evidence
    git merge-base --is-ancestor "$BUGSWEEP_BRANCH" "$BUGSWEEP_ORIG_BRANCH" \
      || die "$BUGSWEEP_BRANCH is not contained in $BUGSWEEP_ORIG_BRANCH"
    authorize_cleanup
    remove_owned_worktree
    git branch -d "$BUGSWEEP_BRANCH" \
      || die "contained branch could not be deleted: $BUGSWEEP_BRANCH"
  else
    actionable="$(summary_actionable)"
    if git merge-base --is-ancestor "$BUGSWEEP_BRANCH" "$BUGSWEEP_ORIG_BRANCH"; then
      fixed_count="$(summary_fixed_count)"
      [ "$fixed_count" -eq 0 ] \
        || die "recorded cannot close already-contained fixed findings; re-gate and use landed"
      if [ "$actionable" != "0" ]; then
        write_block "INCOMPLETE_TRACKER"
        verify_tracker_receipts yes
      fi
      write_block "INCOMPLETE_CLEANUP"
      authorize_cleanup
      remove_owned_worktree
      git branch -d "$BUGSWEEP_BRANCH" \
        || die "contained branch could not be deleted: $BUGSWEEP_BRANCH"
    else
      write_block "INCOMPLETE_TRACKER"
      verify_tracker_receipts yes
      verify_recovery_review
      write_block "INCOMPLETE_CLEANUP"
      authorize_cleanup
      remove_owned_worktree
      git branch -D "$BUGSWEEP_BRANCH" \
        || die "reviewed recovery branch could not be deleted: $BUGSWEEP_BRANCH"
    fi
  fi
fi

branch_exists "$BUGSWEEP_BRANCH" && die "owned branch remains after cleanup: $BUGSWEEP_BRANCH"
[ -z "${BUGSWEEP_WORKTREE:-}" ] || [ ! -d "$BUGSWEEP_WORKTREE" ] \
  || die "owned worktree remains after cleanup: $BUGSWEEP_WORKTREE"

bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" lease-release "$run_dir" >/dev/null 2>&1 || true
rm -f "$block_file"
rmdir "$block_dir" 2>/dev/null || true
state="COMPLETED_RECORDED"
[ "$outcome" = "landed" ] && state="COMPLETED_LANDED"
printf '{"event":"closeout","outcome":"%s","branch_removed":true,"worktree_removed":true}\n' \
  "$state" >> "${run_dir}/ledger.jsonl"
echo "OUTCOME=$state"
echo "BRANCH_REMOVED=$BUGSWEEP_BRANCH"
[ -n "${BUGSWEEP_WORKTREE:-}" ] && echo "WORKTREE_REMOVED=$BUGSWEEP_WORKTREE"
