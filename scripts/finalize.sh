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

# Anchored, region-restricted stub-content check shared by _emit_stub_report's
# stale-sentinel invalidation (bugsweep-je8 residual 2) and the classification
# fallback below (bugsweep-je8 residual 1's pre-sentinel legacy path). Matches
# only the stub template's exact '**WARNING: INCOMPLETE RUN**' line form, and
# only in the region of report.md BEFORE the script-appended
# '## Findings (machine-readable)' heading — so a real report's own appended
# machine block (which may embed marker-quoting finding rationales from the
# ledger) can never match.
_report_content_looks_like_stub() {
  local report="${run_dir}/report.md"
  [ -f "$report" ] || return 1
  sed '/^## Findings (machine-readable)$/,$d' "$report" 2>/dev/null \
    | grep -q '^\*\*WARNING: INCOMPLETE RUN\*\*'
}

# Emit a stub report when report.md was never written (silent-failure backstop).
# A large-repo run may stall during context-build or the architectural hunt before
# the model ever reaches the report template. This backstop ensures the user always
# gets a coverage summary from on-disk state, regardless of where execution stopped.
_emit_stub_report() {
  local report="${run_dir}/report.md"
  if [ -f "$report" ]; then
    # bugsweep-je8 residual 2: a resumed session may write a REAL report.md
    # AFTER an earlier finalize call already emitted the stub + sentinel.
    # If report.md's content no longer looks like the stub, the sentinel is
    # stale — clear it so classification isn't pinned to a superseded stub.
    # An unrelated RETRIED finalize on an UNCHANGED stub must keep the
    # sentinel (and keep classifying stalled) — only clear when the content
    # actually changed underneath it.
    if [ -f "${run_dir}/.report-is-stub" ] && ! _report_content_looks_like_stub; then
      rm -f "${run_dir}/.report-is-stub" 2>/dev/null || true
    fi
    return 0                            # real report exists — do not overwrite
  fi

  local covered=0 total=0 verify_repo="" verified_covered=""
  if [ -f "${run_dir}/recon.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      total="$(  jq -r '.batch_count // (.batches | length)' "${run_dir}/recon.json" 2>/dev/null || printf '0')"
    elif have_python; then
      total="$(python3 -c \
        'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("batch_count",len(d.get("batches",[]))))' \
        "${run_dir}/recon.json" 2>/dev/null || printf '0')"
    fi
  fi
  # Human-facing stub coverage must use the same exact Git-object verifier as
  # run-summary.json and cross-run state. recon.covered is a model-writable
  # receipt, not proof by itself: a batch counts only when recon + ledger + the
  # complete schema-1 snapshot set agree with objects in this local worktree.
  # If Python, the verifier, or its repository is unavailable, fail closed at
  # zero rather than displaying forgeable progress.
  if have_python && [ -f "${BUGSWEEP_SCRIPT_DIR}/_mark_batch_covered.py" ]; then
    verify_repo="${BUGSWEEP_WORKTREE:-}"
    if [ -z "$verify_repo" ] || [ ! -d "$verify_repo" ]; then
      verify_repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [ -n "$verify_repo" ]; then
      verified_covered="$(
        BUGSWEEP_VERIFY_SCRIPT_DIR="$BUGSWEEP_SCRIPT_DIR" \
          python3 - "$run_dir" "$verify_repo" <<'PY' 2>/dev/null || printf '0'
import os
import sys
from pathlib import Path

sys.path.insert(0, os.environ["BUGSWEEP_VERIFY_SCRIPT_DIR"])
from _mark_batch_covered import verify_run_coverage

records = verify_run_coverage(Path(sys.argv[1]), Path(sys.argv[2]))
print(len({int(record["batch"]) for record in records}))
PY
      )"
      covered="$verified_covered"
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
#      misclassified, and a retried finalize stays stable. _emit_stub_report
#      clears this sentinel above if report.md's content no longer looks like
#      the stub (bugsweep-je8 residual 2: a resumed session overwrote it).
#   2. Sentinel file .report-is-real — a memoized "not stub" determination,
#      written below once established for this run_dir. Content-independent
#      and checked BEFORE the fallback grep, so once a run_dir's real-report
#      status is known, a RETRIED finalize never re-evaluates report.md's
#      prose again — retiring the fallback below for sentinel-era run dirs
#      (bugsweep-je8 residual 1: the fallback must not evaluate forever).
#   3. Fallback for run dirs with NEITHER sentinel yet (first-ever finalize
#      call on a run_dir, or a genuinely PRE-SENTINEL run dir whose stub was
#      written by an older finalize): grep for the stub template's exact
#      warning-line form (the line the heredoc above starts with
#      '**WARNING: INCOMPLETE RUN**'), restricted to the region of report.md
#      BEFORE the script-appended '## Findings (machine-readable)' heading —
#      see _report_content_looks_like_stub.
_bugsweep_report_was_stub=false
if [ -f "${run_dir}/.report-is-stub" ]; then
  _bugsweep_report_was_stub=true
elif [ -f "${run_dir}/.report-is-real" ]; then
  _bugsweep_report_was_stub=false
elif _report_content_looks_like_stub; then
  _bugsweep_report_was_stub=true
fi

# Memoize a "not stub" determination (bugsweep-je8 residual 1): once real-report
# status is established for this run_dir — by the sentinel-absent default above,
# or by the fallback grep finding no match — persist it so a RETRIED finalize
# never re-greps report.md's prose again. A genuine stub can never masquerade as
# real afterward: _emit_stub_report's stub-emission path (report.md missing)
# always (re)writes .report-is-stub, which is checked with priority above.
if [ "$_bugsweep_report_was_stub" = false ] && [ -f "${run_dir}/report.md" ]; then
  : > "${run_dir}/.report-is-real"
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

  # Priority focus is script-rendered from the same deterministic run summary,
  # after state persistence and coverage verification. The model never guesses
  # current outcomes or actual promotion counts.
  if [ -f "$report" ] \
    && ! grep -q '^## Priority focus (deterministic)$' "$report" 2>/dev/null \
    && have_python \
    && [ -f "${BUGSWEEP_SCRIPT_DIR}/_priority_report.py" ]; then
    {
      printf '\n'
      python3 "${BUGSWEEP_SCRIPT_DIR}/_priority_report.py" "$_bugsweep_run_summary_path" 2>/dev/null || true
    } >> "$report"
  fi

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
        if have_python; then
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

# Minimal JSON string escaper for the no-python heredoc fallback below
# (bash-3.2 + POSIX tools only, no external helper is importable without
# sourcing another script's side effects — see scripts/summarize.sh's
# _json_escape / scripts/recon-plan.sh's _json_escape_deg / scripts/run_checks.sh's
# json_str_or_null for the same established repo-wide pattern). Every value
# interpolated into that heredoc MUST be piped through this: the DEFAULT
# BUGSWEEP_QUALITY_GATE_COMMAND embeds literal double quotes
# (`verify "${run_dir}"`), and interpolating it raw breaks the emitted JSON
# (bugsweep-yvq). Strip control chars first (JSON forbids raw control chars
# in strings and this path never needs them), THEN escape backslash BEFORE
# double-quote — reversing that order would re-escape the backslashes the
# quote escaping just introduced.
_json_escape() {
  printf '%s' "${1:-}" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

_write_post_finalize_handoff() {
  local handoff="${run_dir}/post-finalize-handoff.json"
  local report="${run_dir}/report.md"
  local quality_gate="${BUGSWEEP_QUALITY_GATE_COMMAND:-bash scripts/run_checks.sh verify \"${run_dir}\"}"
  local push_policy="${BUGSWEEP_PUSH_POLICY:-Push the target branch only after merge, quality gate, smoke checks, and remote read-back succeed; never force-push.}"
  local cleanup_policy="${BUGSWEEP_CLEANUP_POLICY:-Use scripts/bugsweep-cleanup.sh after approval; delete the bugsweep branch only after merge-base containment proof, removing only clean linked worktrees and never using --force.}"

  if have_python; then
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
    # Every field below is JSON-escaped (bugsweep-yvq) — the default
    # quality_gate value alone embeds literal double quotes, and this heredoc
    # uses an unquoted delimiter, so bash interpolates every ${...} verbatim.
    local esc_run_dir esc_orig_branch esc_branch esc_report esc_worktree \
      esc_quality_gate esc_push_policy esc_cleanup_policy
    esc_run_dir="$(_json_escape "$run_dir")"
    esc_orig_branch="$(_json_escape "$BUGSWEEP_ORIG_BRANCH")"
    esc_branch="$(_json_escape "$BUGSWEEP_BRANCH")"
    esc_report="$(_json_escape "$report")"
    esc_worktree="$(_json_escape "${BUGSWEEP_WORKTREE:-}")"
    esc_quality_gate="$(_json_escape "$quality_gate")"
    esc_push_policy="$(_json_escape "$push_policy")"
    esc_cleanup_policy="$(_json_escape "$cleanup_policy")"
    cat > "$handoff" <<JSON
{
  "run_dir": "${esc_run_dir}",
  "original_branch": "${esc_orig_branch}",
  "preserved_branch": "${esc_branch}",
  "report_path": "${esc_report}",
  "worktree_path": "${esc_worktree}",
  "fix_commits": [],
  "focused_tests": [],
  "quality_gate_command": "${esc_quality_gate}",
  "smoke_test_commands": [],
  "push_policy": "${esc_push_policy}",
  "cleanup_policy": "${esc_cleanup_policy}",
  "safe_to_delete_branch_after": "git merge-base --is-ancestor ${esc_branch} <target-branch> succeeds; linked worktree must be clean before removal.",
  "final_readback_commands": [
    "git status --short --branch",
    "git merge-base --is-ancestor ${esc_branch} <target-branch> && echo BRANCH_CONTAINED=${esc_branch}",
    "git branch --list 'bugsweep/*'",
    "git ls-remote --heads origin <target-branch>"
  ]
}
JSON
  fi
}
_write_post_finalize_handoff

# --- Cross-repo/night operator rollup (bugsweep-6w8) --------------------------
# nightshift/automation-optimizer runs bugsweep across many repos overnight;
# without a rollup, each run only leaves its own report.md + this run's
# post-finalize-handoff.json, so an operator sweeping N repos gets N places to
# check instead of one inbox. When BUGSWEEP_ROLLUP_FILE is set, append one
# compact, dated digest line per run:
#
#   <date> <repo> <branch> - confirmed C/H/M/L - fixed F quarantined Q -
#     coverage x/y - <stop_reason> - ACTION: land|discard|review (<report path>)
#
# OFF by default: BUGSWEEP_ROLLUP_FILE unset is a complete no-op (no file
# created, no error) — this is opt-in nightshift plumbing, not bugsweep-core
# behavior.
#
# Idempotent per run, keyed by RUN_DIR: a companion sentinel file
# "<run_dir>/.rollup-appended" is written right after a successful append, and
# its presence short-circuits every later finalize call on the SAME run_dir —
# so a retried/resumed finalize never duplicates the line, even across a
# different BUGSWEEP_ROLLUP_FILE value between calls.
#
# ACTION is derived from run-summary.json's own arrays, most-actionable first:
#   fixed[] non-empty                                    -> land    (there is
#                                                           already-committed
#                                                           fix work worth
#                                                           merging)
#   else confirmed_unfixed[] or quarantined[] non-empty  -> review  (something
#                                                           was found but
#                                                           needs a human call
#                                                           before it lands)
#   else                                                  -> discard (a clean
#                                                           run — nothing to
#                                                           do)
#
# JSON reads mirror common.sh's cfg_get tiering: jq first, then have_python
# (python3 stdlib json), then a minimal grep fallback — never hard-require
# python3 (bare-machine contract).
_rollup_sanitize_int() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Tier-3 (no jq, no python3) element count for a top-level JSON string array
# "<key>": [...] in a run-summary.json this codebase itself produced. `grep -o`
# only matches within a single line, so it cannot span the multi-line
# json.dumps(indent=2) shape bench/scorer/run_summary.py emits for a non-empty
# array (one quoted element per line, between a "<key>": [ line and a closing
# ] line) — this awk pass reads line-by-line instead, so it handles BOTH real
# shapes: the compact "<key>": [] (empty) summarize.sh's own degraded tier
# also emits, and the multi-line non-empty form. It is NOT a general JSON
# array parser (e.g. a hypothetical single-line non-empty array would
# mis-count) — sufficient because those are the only two shapes this
# codebase's own producers ever write.
_rollup_grep_array_len() {
  local key="$1" file="$2"
  awk -v k="\"${key}\":" '
    $0 ~ k {
      if ($0 ~ /\[\]/) { print 0; exit }
      if ($0 ~ /\[/) { collecting=1; count=0; next }
    }
    collecting && /\]/ { print count; exit }
    collecting && /"/ { count++ }
  ' "$file" 2>/dev/null
}

_write_rollup_digest() {
  local rollup_file="${BUGSWEEP_ROLLUP_FILE:-}"
  [ -n "$rollup_file" ] || return 0                     # default off: true no-op

  local sentinel="${run_dir}/.rollup-appended"
  [ -f "$sentinel" ] && return 0                        # idempotent per RUN_DIR

  local summary="${run_dir}/run-summary.json"
  if [ ! -f "$summary" ]; then
    log "WARNING: rollup skipped — ${summary} is missing (summarize.sh may have failed)."
    return 0
  fi

  local critical high medium low fixed_n quarantined_n confirmed_n covered total status stop_reason
  critical=0; high=0; medium=0; low=0
  fixed_n=0; quarantined_n=0; confirmed_n=0
  covered=0; total=0
  status=""; stop_reason=""

  if command -v jq >/dev/null 2>&1; then
    critical="$(jq -r '.counts.critical // 0'                   "$summary" 2>/dev/null || printf 0)"
    high="$(jq -r '.counts.high // 0'                            "$summary" 2>/dev/null || printf 0)"
    medium="$(jq -r '.counts.medium // 0'                        "$summary" 2>/dev/null || printf 0)"
    low="$(jq -r '.counts.low // 0'                               "$summary" 2>/dev/null || printf 0)"
    fixed_n="$(jq -r '(.fixed // []) | length'                    "$summary" 2>/dev/null || printf 0)"
    quarantined_n="$(jq -r '(.quarantined // []) | length'        "$summary" 2>/dev/null || printf 0)"
    confirmed_n="$(jq -r '(.confirmed_unfixed // []) | length'    "$summary" 2>/dev/null || printf 0)"
    covered="$(jq -r '.coverage.covered // 0'                     "$summary" 2>/dev/null || printf 0)"
    total="$(jq -r '.coverage.total // 0'                         "$summary" 2>/dev/null || printf 0)"
    status="$(jq -r '.status // ""'                               "$summary" 2>/dev/null || printf '')"
    stop_reason="$(jq -r '.stop_reason // ""'                     "$summary" 2>/dev/null || printf '')"
  elif have_python; then
    local py_out
    py_out="$(python3 - "$summary" <<'PY' 2>/dev/null || true
import json, sys

try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}


def as_int(x):
    return x if isinstance(x, int) else 0


counts = d.get("counts") or {}
coverage = d.get("coverage") or {}
for value in (
    as_int(counts.get("critical")),
    as_int(counts.get("high")),
    as_int(counts.get("medium")),
    as_int(counts.get("low")),
    len(d.get("fixed") or []),
    len(d.get("quarantined") or []),
    len(d.get("confirmed_unfixed") or []),
    as_int(coverage.get("covered")),
    as_int(coverage.get("total")),
    d.get("status") or "",
    d.get("stop_reason") or "",
):
    print(value)
PY
)"
    critical="$(printf      '%s\n' "$py_out" | sed -n '1p')"
    high="$(printf          '%s\n' "$py_out" | sed -n '2p')"
    medium="$(printf        '%s\n' "$py_out" | sed -n '3p')"
    low="$(printf           '%s\n' "$py_out" | sed -n '4p')"
    fixed_n="$(printf       '%s\n' "$py_out" | sed -n '5p')"
    quarantined_n="$(printf '%s\n' "$py_out" | sed -n '6p')"
    confirmed_n="$(printf   '%s\n' "$py_out" | sed -n '7p')"
    covered="$(printf       '%s\n' "$py_out" | sed -n '8p')"
    total="$(printf         '%s\n' "$py_out" | sed -n '9p')"
    status="$(printf        '%s\n' "$py_out" | sed -n '10p')"
    stop_reason="$(printf   '%s\n' "$py_out" | sed -n '11p')"
  else
    # Tier 3: minimal grep/sed fallback for the bare-machine contract (no jq,
    # no python3). Handles the flat-scalar shapes both the real reducer and
    # summarize.sh's degraded tier emit; a miss just defaults to 0/"" below —
    # never fatal. Every pipeline ends in `|| true`: under this script's
    # `set -euo pipefail`, `grep -o` finding no match exits non-zero and
    # `pipefail` propagates that through `head`/`sed` even though THEY
    # succeed on the resulting empty input — without `|| true` a legitimately
    # absent field (e.g. stop_reason is JSON null, not a string, on every
    # "complete" run) would abort finalize.sh entirely instead of degrading
    # to "" here.
    critical="$(grep -o '"critical"[[:space:]]*:[[:space:]]*[0-9]*'          "$summary" 2>/dev/null | grep -o '[0-9]*$' | head -1 || true)"
    high="$(    grep -o '"high"[[:space:]]*:[[:space:]]*[0-9]*'              "$summary" 2>/dev/null | grep -o '[0-9]*$' | head -1 || true)"
    medium="$(  grep -o '"medium"[[:space:]]*:[[:space:]]*[0-9]*'            "$summary" 2>/dev/null | grep -o '[0-9]*$' | head -1 || true)"
    low="$(     grep -o '"low"[[:space:]]*:[[:space:]]*[0-9]*'               "$summary" 2>/dev/null | grep -o '[0-9]*$' | head -1 || true)"
    covered="$( grep -o '"covered"[[:space:]]*:[[:space:]]*[0-9]*'           "$summary" 2>/dev/null | grep -o '[0-9]*$' | head -1 || true)"
    total="$(   grep -o '"total"[[:space:]]*:[[:space:]]*[0-9]*'             "$summary" 2>/dev/null | grep -o '[0-9]*$' | head -1 || true)"
    # `|| var=0`: these are plain (non-`local`) re-assignments, so under this
    # script's `set -euo pipefail` a non-zero from the helper (its `awk` erroring
    # on a vanished/unreadable summary — a TOCTOU after the line-416 existence
    # check, or a permission change) would otherwise abort the whole assignment
    # statement. Belt-and-suspenders with the isolated call site (see the tail of
    # this script): the digest must never be able to propagate a failure into
    # finalize's trust-critical teardown.
    fixed_n="$(_rollup_grep_array_len       fixed             "$summary")" || fixed_n=0
    quarantined_n="$(_rollup_grep_array_len quarantined       "$summary")" || quarantined_n=0
    confirmed_n="$(_rollup_grep_array_len   confirmed_unfixed "$summary")" || confirmed_n=0
    status="$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$summary" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//' || true)"
    stop_reason="$(grep -o '"stop_reason"[[:space:]]*:[[:space:]]*"[^"]*"' "$summary" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//' || true)"
  fi

  critical="$(_rollup_sanitize_int "$critical")"
  high="$(_rollup_sanitize_int "$high")"
  medium="$(_rollup_sanitize_int "$medium")"
  low="$(_rollup_sanitize_int "$low")"
  fixed_n="$(_rollup_sanitize_int "$fixed_n")"
  quarantined_n="$(_rollup_sanitize_int "$quarantined_n")"
  confirmed_n="$(_rollup_sanitize_int "$confirmed_n")"
  covered="$(_rollup_sanitize_int "$covered")"
  total="$(_rollup_sanitize_int "$total")"

  local action
  if [ "$fixed_n" -gt 0 ]; then
    action="land"
  elif [ "$confirmed_n" -gt 0 ] || [ "$quarantined_n" -gt 0 ]; then
    action="review"
  else
    action="discard"
  fi

  # <stop_reason> slot: prefer the actual stop_reason text; a completed run's
  # stop_reason is null/empty, so fall back to status ("complete") — still
  # meaningful context for the digest line.
  local reason_text="${stop_reason:-$status}"
  [ -n "$reason_text" ] || reason_text="unknown"

  local repo_name
  repo_name="$(basename "${BUGSWEEP_REPO_ROOT:-$(pwd)}")"

  local line
  line="$(printf '%s %s %s - confirmed %s/%s/%s/%s - fixed %s quarantined %s - coverage %s/%s - %s - ACTION: %s (%s)' \
    "$BUGSWEEP_TS" "$repo_name" "$BUGSWEEP_BRANCH" \
    "$critical" "$high" "$medium" "$low" \
    "$fixed_n" "$quarantined_n" \
    "$covered" "$total" \
    "$reason_text" "$action" "${run_dir}/report.md")"

  # `>>` append of one short line is atomic under PIPE_BUF on every POSIX
  # filesystem bugsweep runs on, so concurrent finalize calls targeting the
  # SAME rollup file across different repos/run_dirs never interleave.
  if printf '%s\n' "$line" >> "$rollup_file" 2>/dev/null; then
    : > "$sentinel" 2>/dev/null || true
  else
    log "WARNING: could not append rollup digest to BUGSWEEP_ROLLUP_FILE=${rollup_file}."
  fi
}
# NOTE: _write_rollup_digest is deliberately NOT invoked here. The rollup is a
# cosmetic, default-OFF operator convenience; it must run AFTER the
# trust-critical teardown (branch-restore + stash-pop) below, at the very tail
# of this script — never before it. See the invocation at the end of the file.

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

# Cross-repo/night operator rollup digest — LAST, and isolated. This runs only
# AFTER the trust-critical teardown above (branch-restore + stash-pop + worktree
# reaper) and after the stdout contract, because it is the least-important,
# most-fragile step: a cosmetic, default-OFF operator convenience that must
# NEVER be able to strand the user on the bugsweep branch. It only READS
# run-summary.json (already on disk, under the main repo's .bugsweep/ — never in
# the reaped worktree) plus env (BUGSWEEP_BRANCH/TS/REPO_ROOT), none of which the
# teardown touches, so running it last is safe. The `|| log` makes it
# unabortable: any failure inside is swallowed to a warning so it can never
# propagate to finalize's exit status. Defense in depth with the internal
# `|| var=0` guards above.
_write_rollup_digest || log "WARNING: rollup digest emission failed (non-fatal; run still finalized)."
