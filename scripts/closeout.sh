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

# state.env is data. Validate and read it through the inert allowlisted parser;
# never source a run-owned file as shell code.
_lifecycle_py="${BUGSWEEP_SCRIPT_DIR}/_terminal_lifecycle.py"
_state_get() { python3 -B "$_lifecycle_py" get "$run_dir" "$1"; }
invoking_repo_root="$BUGSWEEP_REPO_ROOT"
BUGSWEEP_REPO_ROOT="$(_state_get BUGSWEEP_REPO_ROOT)"
BUGSWEEP_RUN_ID="$(_state_get BUGSWEEP_RUN_ID)"
BUGSWEEP_TS="$(_state_get BUGSWEEP_TS)"
BUGSWEEP_BRANCH="$(_state_get BUGSWEEP_BRANCH)"
BUGSWEEP_ORIG_BRANCH="$(_state_get BUGSWEEP_ORIG_BRANCH)"
BUGSWEEP_WORKTREE="$(_state_get BUGSWEEP_WORKTREE)"
BUGSWEEP_MODE="$(_state_get BUGSWEEP_MODE)"

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
python3 -B "$_lifecycle_py" init "$run_dir" PENDING_CLOSEOUT >/dev/null

# Recorded closeout is also destructive. Validate the whole deterministic
# summary before either outcome can remove an exact branch/worktree.
python3 - "$run_dir" "$BUGSWEEP_SCRIPT_DIR" <<'PY'
import json, pathlib, sys
import jsonschema
run, script_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
def pairs(items):
    result = {}
    for key, value in items:
        if key in result: raise ValueError("duplicate JSON key")
        result[key] = value
    return result
summary = json.loads((run / "run-summary.json").read_text(encoding="utf-8"), object_pairs_hook=pairs)
schema = json.loads((script_dir.parent / "schemas" / "run-summary.schema.json").read_text(encoding="utf-8"))
jsonschema.Draft202012Validator(schema).validate(summary)
PY

# A crash after receipt fsync but before blocker removal is a completed
# destructive closeout with unfinished bookkeeping. Reconcile only that tail;
# never attempt branch/worktree removal again.
if terminal_state="$(python3 -B "$_lifecycle_py" terminal "$run_dir" 2>/dev/null)"; then
  expected_terminal="COMPLETED_RECORDED"
  [ "$outcome" = landed ] && expected_terminal="COMPLETED_LANDED"
  [ "$terminal_state" = "$expected_terminal" ] || die "terminal receipt outcome disagrees with requested closeout"
  rm -f "$block_file"
  rmdir "$block_dir" 2>/dev/null || true
  if ! grep -q '"event":"closeout"' "${run_dir}/ledger.jsonl" 2>/dev/null; then
    printf '{"event":"closeout","outcome":"%s","branch_removed":true,"worktree_removed":true}\n' "$terminal_state" >> "${run_dir}/ledger.jsonl"
  fi
  echo "OUTCOME=$terminal_state"
  exit 0
fi

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
  python3 -B "$_lifecycle_py" advance "$run_dir" WORKTREE_REMOVED >/dev/null
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
  python3 - "$run_dir" "$BUGSWEEP_BRANCH" "$BUGSWEEP_ORIG_BRANCH" "${BUGSWEEP_MODE:-detect}" "$referee_votes" "${BUGSWEEP_WORKTREE:-}" "$BUGSWEEP_REPO_ROOT" "$BUGSWEEP_SCRIPT_DIR" <<'PY'
import hashlib, json, pathlib, subprocess, sys
run, branch, target, mode, required_votes = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
source_root = pathlib.Path(sys.argv[6] or sys.argv[7]).resolve()
schema_path = pathlib.Path(sys.argv[8]).parent / "schemas" / "run-summary.schema.json"
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

# Ledger events describe workflow history only.  Auto-land additionally
# requires coordinator-native review, executable repro, and suite receipts
# bound to the frozen final source manifest. Missing producers fail closed.
try:
    from scripts._proof import validate_fix_proof, validate_fix_reverification, validate_suite_receipt
    from scripts._review_evidence import validate_review_set
    from scripts._execution import _capture_source_files
    import jsonschema
    def no_duplicate_object(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate JSON key")
            value[key] = item
        return value
    def strict_object(path):
        return json.loads(path.read_text(), object_pairs_hook=no_duplicate_object)
    sources = strict_object(run / "source-digests.json")
    if not isinstance(sources, dict):
        raise ValueError("source digest manifest is not an object")
    if _capture_source_files(source_root, allow_symlinks=False) != sources:
        raise ValueError("source manifest does not match complete final checkout")
    source_sha256 = hashlib.sha256(json.dumps(sources, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()).hexdigest()
    summary = strict_object(run / "run-summary.json")
    jsonschema.Draft202012Validator(strict_object(schema_path)).validate(summary)
    suite_receipt = strict_object(run / "check-results-verify.json")
    if suite_receipt.get("source_manifest_sha256") != source_sha256:
        raise ValueError("suite source manifest identity mismatch")
    suite = validate_suite_receipt(suite_receipt, run_id, sources)
    if not suite.get("complete"):
        raise ValueError("suite proof incomplete: " + ", ".join(suite.get("reasons", [])))
    integration_path = row.get("integration_suite_receipt_path")
    integration_file = (run / integration_path).resolve() if isinstance(integration_path, str) else None
    if (integration_file is None or run not in integration_file.parents or not integration_file.is_file()
            or row.get("integration_suite_receipt_sha256") != hashlib.sha256(integration_file.read_bytes()).hexdigest()
            or row.get("integration_merge_sha") != row.get("target_tip")):
        raise ValueError("missing immutable merged-source integration receipt")
    integration_suite = strict_object(integration_file)
    integration_sources = integration_suite.get("source_file_sha256")
    integration_sha256 = hashlib.sha256(json.dumps(integration_sources, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()).hexdigest() if isinstance(integration_sources, dict) else None
    if (integration_suite.get("schema_version") != 1 or integration_suite.get("kind") != "integration-suite"
            or integration_suite.get("run_id") != run_id or integration_suite.get("branch") != branch
            or integration_suite.get("merge_sha") != row.get("target_tip")
            or integration_suite.get("status") != "verified"
            or integration_suite.get("source_manifest_sha256") != integration_sha256
            or integration_suite.get("source_manifest_sha256") != row.get("integration_source_manifest_sha256")):
        raise ValueError("integration receipt identity mismatch")
    integrated = validate_suite_receipt({"schema_version": 1, "run_id": run_id, "phase": "verify", "source_file_sha256": integration_sources, "checks": integration_suite.get("checks"), "regressions": integration_suite.get("regressions", []), "proof_error": integration_suite.get("proof_errors", False)}, run_id, integration_sources)
    if not integrated.get("complete"):
        raise ValueError("integration suite proof incomplete: " + ", ".join(integrated.get("reasons", [])))
    for bug in summary.get("fixed", []):
        if not isinstance(bug, str) or not bug:
            raise ValueError("invalid fixed bug identity")
        proof_receipt = strict_object(run / "proofs" / f"{bug}.json")
        original_sources = proof_receipt.get("after", {}).get("source_file_sha256") if isinstance(proof_receipt.get("after"), dict) else None
        original_sha256 = hashlib.sha256(json.dumps(original_sources, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()).hexdigest() if isinstance(original_sources, dict) else None
        if proof_receipt.get("source_manifest_sha256") != original_sha256:
            raise ValueError("original proof source manifest identity mismatch for " + bug)
        review_sha256 = proof_receipt.get("review_source_manifest_sha256")
        if not isinstance(review_sha256, str):
            raise ValueError("missing reviewed source identity for " + bug)
        review = validate_review_set(run, bug, review_sha256, required_votes=required_votes)
        if not review.get("eligible"):
            raise ValueError("review provenance incomplete for " + bug + ": " + ", ".join(review.get("reasons", [])))
        proof = validate_fix_proof(proof_receipt, run_id, bug, original_sources)
        if not proof.get("complete"):
            raise ValueError("fix proof incomplete for " + bug + ": " + ", ".join(proof.get("reasons", [])))
        original = [event for event in events if event.get("event") == "fix_committed" and str(event.get("bug_id")) == bug]
        reverified = [event for event in events if event.get("event") == "fix_reverified" and str(event.get("bug_id")) == bug]
        if len(original) != 1 or not reverified:
            raise ValueError("missing immutable fix revalidation for " + bug)
        valid = []
        for event in reverified:
            path = event.get("path")
            record_path = (run / path).resolve() if isinstance(path, str) else None
            if record_path is None or run not in record_path.parents or not record_path.is_file() or event.get("sha256") != hashlib.sha256(record_path.read_bytes()).hexdigest():
                continue
            record = strict_object(record_path)
            result = validate_fix_reverification(record, proof_receipt, run_id, bug, sources)
            if result.get("complete") and record.get("original_fix_commit") == original[0].get("commit") and record.get("final_source_manifest_sha256") == source_sha256:
                valid.append(record)
        if len(valid) != 1:
            raise ValueError("expected exactly one current-final-source revalidation for " + bug)
except (ImportError, OSError, ValueError, TypeError, json.JSONDecodeError, jsonschema.ValidationError) as exc:
    raise SystemExit("COMPLETED_LANDED requires verified execution and review provenance: " + str(exc))
PY
}
if ! branch_exists "$BUGSWEEP_BRANCH"; then
  [ -z "${BUGSWEEP_WORKTREE:-}" ] || { [ ! -e "$BUGSWEEP_WORKTREE" ] && [ ! -L "$BUGSWEEP_WORKTREE" ]; } \
    || die "branch is gone but owned worktree remains: $BUGSWEEP_WORKTREE"
  # Readback established both resources are absent.  Reconcile every durable
  # crash boundary before any receipt is allowed; this does not delete or
  # infer anything from a ledger entry.
  python3 -B "$_lifecycle_py" recover-absent "$run_dir" confirmed >/dev/null
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
    python3 -B "$_lifecycle_py" advance "$run_dir" READY_FOR_CLEANUP >/dev/null
    remove_owned_worktree
    git branch -d "$BUGSWEEP_BRANCH" \
      || die "contained branch could not be deleted: $BUGSWEEP_BRANCH"
    python3 -B "$_lifecycle_py" advance "$run_dir" BRANCH_REMOVED >/dev/null
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
      python3 -B "$_lifecycle_py" advance "$run_dir" READY_FOR_CLEANUP >/dev/null
      remove_owned_worktree
      git branch -d "$BUGSWEEP_BRANCH" \
        || die "contained branch could not be deleted: $BUGSWEEP_BRANCH"
      python3 -B "$_lifecycle_py" advance "$run_dir" BRANCH_REMOVED >/dev/null
    else
      write_block "INCOMPLETE_TRACKER"
      verify_tracker_receipts yes
      verify_recovery_review
      write_block "INCOMPLETE_CLEANUP"
      authorize_cleanup
      python3 -B "$_lifecycle_py" advance "$run_dir" READY_FOR_CLEANUP >/dev/null
      remove_owned_worktree
      git branch -D "$BUGSWEEP_BRANCH" \
        || die "reviewed recovery branch could not be deleted: $BUGSWEEP_BRANCH"
      python3 -B "$_lifecycle_py" advance "$run_dir" BRANCH_REMOVED >/dev/null
    fi
  fi
fi

branch_exists "$BUGSWEEP_BRANCH" && die "owned branch remains after cleanup: $BUGSWEEP_BRANCH"
[ -z "${BUGSWEEP_WORKTREE:-}" ] || { [ ! -e "$BUGSWEEP_WORKTREE" ] && [ ! -L "$BUGSWEEP_WORKTREE" ]; } \
  || die "owned worktree remains after cleanup: $BUGSWEEP_WORKTREE"

bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" lease-release "$run_dir" >/dev/null 2>&1 || true
state="COMPLETED_RECORDED"
[ "$outcome" = "landed" ] && state="COMPLETED_LANDED"
python3 -B "$_lifecycle_py" advance "$run_dir" RECEIPT_PENDING >/dev/null
# branch_exists and the worktree check immediately above are the coordinator's
# exact readback; persist them before a receipt can claim terminal completion.
python3 -B "$_lifecycle_py" observe-absence "$run_dir" confirmed >/dev/null
python3 -B "$_lifecycle_py" receipt "$run_dir" "$state" >/dev/null
rm -f "$block_file"
rmdir "$block_dir" 2>/dev/null || true
printf '{"event":"closeout","outcome":"%s","branch_removed":true,"worktree_removed":true}\n' \
  "$state" >> "${run_dir}/ledger.jsonl"
echo "OUTCOME=$state"
echo "BRANCH_REMOVED=$BUGSWEEP_BRANCH"
[ -n "${BUGSWEEP_WORKTREE:-}" ] && echo "WORKTREE_REMOVED=$BUGSWEEP_WORKTREE"
exit 0
