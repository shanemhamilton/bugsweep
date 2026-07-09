#!/usr/bin/env bash
# bugsweep repro gate (bugsweep-hty): turns a described bug trigger into
# EXECUTABLE proof by running a bug-specific repro test before and after a
# fix, so "the fix works" is demonstrated by a test going red -> green, not
# just inferred from the general suite staying green (which a fix that never
# actually touches the real bug can trivially satisfy when nothing in the
# existing suite exercises that code path).
#
# Usage:
#   scripts/repro.sh pre  <RUN_DIR> <BUG_ID> ["<REPRO_CMD>"]
#   scripts/repro.sh post <RUN_DIR> <BUG_ID>
#
# `pre` runs BEFORE the fix is applied, once a repro test has been
# synthesized for a CONFIRMED bug (see prompts/repro.md). It runs
# <REPRO_CMD> ONCE and classifies the result:
#   - REPRO_CMD empty/absent          -> "none": no repro was synthesizable
#     for this bug (no test framework detected, or the bug's shape isn't
#     reproducible as a minimal test). TERMINAL — recorded to the ledger
#     immediately; `post` will always report "none" for this bug_id.
#   - REPRO_CMD FAILS (nonzero exit)  -> "red_confirmed": the repro
#     demonstrates the bug. NON-TERMINAL — the outcome isn't known until
#     `post` re-runs it after the fix, so only LOCAL state
#     (<RUN_DIR>/repro-<BUG_ID>.json) is written; nothing reaches the ledger
#     yet.
#   - REPRO_CMD PASSES (zero exit)    -> "unreproduced": the test did NOT
#     fail before the fix, so it never demonstrated the bug and proves
#     nothing either way. TERMINAL — recorded immediately, same as "none".
#
# `post` runs AFTER the fix is applied, AFTER (in addition to, never instead
# of) `scripts/run_checks.sh verify` has already made its own independent
# suite-green/REGRESSION decision — see prompts/fix.md. It looks up the
# status `pre` recorded for <BUG_ID>:
#   - anything other than "red_confirmed" (never ran `pre`, or `pre` already
#     recorded a terminal "none"/"unreproduced") -> prints REPRO=none and
#     exits 0. This is the fallback path: this script contributes NOTHING to
#     the revert decision, and behavior is EXACTLY today's — suite-only
#     gating via run_checks.sh verify alone (the acceptance-criterion
#     "no framework / non-reproducible shape degrades cleanly to CURRENT
#     behavior").
#   - "red_confirmed" -> re-runs the SAME stored command:
#       - PASSES now  -> "confirmed" (red before the fix, green after it —
#         the strongest evidence the fix actually resolved the bug).
#         Recorded to the ledger. Prints REPRO=confirmed, exits 0.
#       - STILL FAILS -> "failed" (the fix did not resolve what the repro
#         demonstrates). Recorded to the ledger. Prints REPRO=failed, EXITS
#         1 — the caller (prompts/fix.md) treats a nonzero exit here exactly
#         like run_checks.sh's REGRESSION: revert the fix and quarantine the
#         bug, citing the repro failure.
#
# SAFETY CONTRACT (bugsweep-hty — read alongside prompts/fix.md):
#   - This is a SEPARATE, ADDITIVE gate. It never replaces, reorders, or
#     weakens scripts/run_checks.sh's existing verify/revert decision — the
#     gli/ml7/7hw logic in that file is untouched by this feature; this
#     script does not source, call, or otherwise depend on run_checks.sh. A
#     landed fix must satisfy BOTH gates: run_checks.sh's suite-green check
#     (unchanged) AND, only when a repro was pre-confirmed red, this
#     script's post-fix green check.
#   - The decision can only get MORE strict, never less: `post` exits
#     non-zero ONLY when a repro was independently confirmed red before the
#     fix. It can never turn a genuine REGRESSION into a pass, and it can
#     never invent a revert reason when no repro was ever confirmed.
#   - A repro that does not go red pre-fix is not proof of anything — it is
#     classified "unreproduced" and excluded from the gate entirely, exactly
#     like "none". This script never revert-gates on an inconclusive repro.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

sub="${1:-}"; run_dir="${2:-}"; bug_id="${3:-}"
case "$sub" in
  pre|post) : ;;
  *) die 'usage: repro.sh <pre|post> <RUN_DIR> <BUG_ID> ["<REPRO_CMD>"]' ;;
esac
[ -n "$run_dir" ] && [ -n "$bug_id" ] || die 'usage: repro.sh <pre|post> <RUN_DIR> <BUG_ID> ["<REPRO_CMD>"]'
[ -d "$run_dir" ] || die "run dir not found: $run_dir"
# bug_id becomes part of on-disk filenames below -- refuse anything that
# could escape RUN_DIR (path traversal) or split across directories.
case "$bug_id" in
  */*|*'..'*) die "invalid BUG_ID (must not contain '/' or '..'): $bug_id" ;;
esac

state_file="${run_dir}/repro-${bug_id}.json"

# Minimal JSON string escaping (backslash then quote) -- the same
# "sufficient for the values we ever pass here" contract
# scripts/run_checks.sh's json_str_or_null already documents. bug_id and
# repro commands are bugsweep-synthesized identifiers/shell invocations, not
# arbitrary untrusted text. Known limitation of the grep/sed FALLBACK tier
# only (see _read_state_cmd): a repro command containing an embedded double
# quote round-trips correctly under the preferred python3 tier, but the
# non-python fallback's grep pattern cannot distinguish an escaped quote from
# a real closing quote. Realistic repro commands (test-runner invocations,
# single-quoted paths) never hit this.
_json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
_json_unesc() { printf '%s' "$1" | sed 's/\\"/"/g; s/\\\\/\\/g'; }

_append_ledger_status() {
  local status="$1"
  printf '{"event":"repro_status","bug_id":"%s","status":"%s"}\n' \
    "$(_json_esc "$bug_id")" "$status" >> "${run_dir}/ledger.jsonl"
}

# Persist local (non-ledger) bookkeeping: the current status plus (when
# known) the exact repro command, so `post` re-runs the SAME command `pre`
# ran. Prefers python3 for a real JSON encode (repro commands can contain
# quotes); falls back to the minimal sed-based escaping above when python3
# is unavailable (BUGSWEEP_NO_PYTHON=1 / a bare machine) -- the
# no-framework/degraded path must work with neither.
_write_state() {
  local status="$1" cmd="${2:-}"
  if have_python; then
    if BSW_BUGID="$bug_id" BSW_STATUS="$status" BSW_CMD="$cmd" python3 -c '
import json, os
cmd = os.environ["BSW_CMD"]
d = {"bug_id": os.environ["BSW_BUGID"], "status": os.environ["BSW_STATUS"],
     "cmd": cmd if cmd else None}
print(json.dumps(d))
' > "$state_file" 2>/dev/null; then
      return 0
    fi
  fi
  if [ -n "$cmd" ]; then
    printf '{"bug_id":"%s","status":"%s","cmd":"%s"}\n' \
      "$(_json_esc "$bug_id")" "$status" "$(_json_esc "$cmd")" > "$state_file"
  else
    printf '{"bug_id":"%s","status":"%s","cmd":null}\n' \
      "$(_json_esc "$bug_id")" "$status" > "$state_file"
  fi
}

_read_state_status() {
  [ -f "$state_file" ] || return 0
  if have_python; then
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get("status")
    sys.stdout.write(v if isinstance(v, str) else "")
except Exception:
    pass
' "$state_file" 2>/dev/null && return 0
  fi
  grep -o '"status":"[a-zA-Z_]*"' "$state_file" 2>/dev/null | head -1 | sed 's/.*:"//; s/"$//'
}

_read_state_cmd() {
  [ -f "$state_file" ] || return 0
  if have_python; then
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get("cmd")
    sys.stdout.write(v if isinstance(v, str) else "")
except Exception:
    pass
' "$state_file" 2>/dev/null && return 0
  fi
  local raw
  raw="$(grep -o '"cmd":"[^"]*"' "$state_file" 2>/dev/null | head -1 | sed 's/.*:"//; s/"$//')"
  [ -n "$raw" ] && _json_unesc "$raw"
  return 0
}

case "$sub" in
  pre)
    repro_cmd="${4:-}"
    if [ -z "$repro_cmd" ]; then
      _write_state "none"
      _append_ledger_status "none"
      echo "REPRO=none"
      exit 0
    fi
    log "repro pre-check for ${bug_id}: ${repro_cmd}"
    if ( eval "$repro_cmd" ) >"${run_dir}/repro-${bug_id}-pre.log" 2>&1; then
      # Passed BEFORE the fix -> never demonstrated the bug.
      _write_state "unreproduced" "$repro_cmd"
      _append_ledger_status "unreproduced"
      echo "REPRO=unreproduced"
      exit 0
    fi
    # Failed BEFORE the fix -> bug reproduced. Non-terminal: `post` records
    # the ledger event once the post-fix outcome is known.
    _write_state "red_confirmed" "$repro_cmd"
    echo "REPRO=red_confirmed"
    exit 0
    ;;
  post)
    status="$(_read_state_status)"
    if [ "$status" != "red_confirmed" ]; then
      # Never pre-confirmed red (never ran `pre`, or `pre` already recorded
      # a terminal "none"/"unreproduced") -- nothing to gate. Fall back to
      # today's behavior: run_checks.sh verify's suite-only decision is the
      # sole gate. Never (re-)writes a ledger event here -- `pre` already
      # wrote the terminal one, or nothing was ever recorded.
      echo "REPRO=none"
      exit 0
    fi
    repro_cmd="$(_read_state_cmd)"
    log "repro post-check for ${bug_id}: ${repro_cmd}"
    if ( eval "$repro_cmd" ) >"${run_dir}/repro-${bug_id}-post.log" 2>&1; then
      _write_state "confirmed" "$repro_cmd"
      _append_ledger_status "confirmed"
      echo "REPRO=confirmed"
      exit 0
    fi
    _write_state "failed" "$repro_cmd"
    _append_ledger_status "failed"
    echo "REPRO=failed"
    exit 1
    ;;
esac
