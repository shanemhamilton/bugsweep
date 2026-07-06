#!/usr/bin/env bash
# bugsweep aggregate-summaries: merge N run-summary.json files (as produced by
# scripts/summarize.sh) into one session-summary.json — the machine-readable
# contract an overnight/nightshift scheduler can branch on for "how did the
# whole session go?" without re-deriving totals/clusters/follow-up from each
# run-summary.json separately.
#
# Tiered-degradation pattern (same shape as scripts/summarize.sh):
#   Tier 1: python3 available -> bench/scorer/session_summary.py does the real
#           merge (totals, cross-run cluster re-merge, deduped follow_up,
#           worst-status roll-up).
#   Tier 2: python3 unavailable, or the Tier 1 merge fails for any reason ->
#           emit a minimal schema-valid session-summary.json with
#           "degraded": true, zero totals, and empty
#           clusters/follow_up/runs — a bare machine or an unexpected merge
#           failure must never leave the aggregate missing entirely.
#
# Usage: aggregate-summaries.sh <out.json> <summary1.json> [summary2.json ...]
# Prints: SESSION_SUMMARY=<path to written session-summary.json>

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

out_path="${1:-}"
[ -n "$out_path" ] || die "usage: aggregate-summaries.sh <out.json> <summary1.json> [summary2.json ...]"
shift
# Remaining args are the input run-summary.json paths; zero is valid (an empty
# session — e.g. a nightshift run that produced no runs yet) and must still
# emit a schema-valid, zeroed session-summary.json rather than erroring.

# The degraded path can't parse the input summaries without python3, so it
# cannot know how many runs there were or their statuses. It emits the
# non-success sentinel (run_count 0 / worst_status "no_runs") alongside
# "degraded": true so a scheduler never mistakes a bare-machine fallback for a
# clean all-complete session (review BLOCKER 1 applies to this path too).
_write_degraded_session() {
  cat > "$out_path" <<'JSON'
{
  "schema_version": 1,
  "degraded": true,
  "totals": {"critical": 0, "high": 0, "medium": 0, "low": 0, "architectural": 0},
  "root_cause_clusters": [],
  "follow_up": [],
  "runs": [],
  "run_count": 0,
  "worst_status": "no_runs"
}
JSON
}

_run_degraded() {
  log "aggregate-summaries: emitting degraded session-summary.json (no merge performed)."
  _write_degraded_session
}

_py_reducer="${BUGSWEEP_SCRIPT_DIR}/_session_summary_reduce.py"

if have_python && [ -f "$_py_reducer" ]; then
  if ! BUGSWEEP_ROOT="$BUGSWEEP_ROOT" python3 "$_py_reducer" "$out_path" "$@" 2>/dev/null; then
    log "aggregate-summaries: python3 merge failed; falling back to degraded aggregate."
    _run_degraded
  fi
else
  [ -f "$_py_reducer" ] || log "aggregate-summaries: reducer entrypoint missing (${_py_reducer})."
  _run_degraded
fi

[ -f "$out_path" ] || die "aggregate-summaries: failed to write ${out_path}"

echo "SESSION_SUMMARY=${out_path}"
