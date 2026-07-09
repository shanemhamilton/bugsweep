#!/usr/bin/env bash
# bugsweep summarize: reduce <RUN_DIR>/ledger.jsonl + recon.json into a
# deterministic, schema-valid <RUN_DIR>/run-summary.json — the machine-readable
# contract a headless scheduler (nightshift) can branch on without parsing
# model prose or the (historically format-varying) report.md "Findings
# (machine-readable)" block.
#
# Tiered-degradation pattern (see common.sh's cfg_get / catalog_class_version):
#   Tier 1: python3 available -> bench/scorer/run_summary.py does the real
#           reduction (severities, categories, per-finding detail, plus the
#           bugsweep-xdw additions: root_cause_clusters/follow_up/flaky —
#           follow_up also reads <RUN_DIR>/prior-coverage.json, written by
#           preflight.sh via scripts/state.sh's `prime`, when present).
#   Tier 2: python3 unavailable, or the Tier 1 reduction fails for any reason
#           -> emit a minimal schema-valid run-summary.json from grep-able
#           ledger/recon values only, with "degraded": true and empty
#           findings/root_cause_clusters/follow_up/flaky. The nightshift
#           contract is "run-summary.json ALWAYS exists after finalize" —
#           this tier is what keeps that true on a bare machine or after an
#           unexpected reduction failure.
#
# Usage: summarize.sh <RUN_DIR> <REPORT_IS_STUB: true|false> [MODE] [--recall]
# Prints: RUN_SUMMARY=<path to written run-summary.json>

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# TEST-ONLY config redirection, same pattern as scripts/preflight.sh and
# scripts/analyzers.sh: common.sh unconditionally sets BUGSWEEP_CONFIG to the
# real repo config (a plain assignment, not `:=`), so this underscore-
# prefixed hook lets tests/bats/summarize.bats exercise the .recall.enabled
# config-knob path via a temp config, without a production-path env override.
if [ -n "${_SUMMARIZE_TEST_CONFIG_OVERRIDE:-}" ]; then
  # shellcheck disable=SC2034  # consumed by common.sh's cfg_get, sourced above
  BUGSWEEP_CONFIG="$_SUMMARIZE_TEST_CONFIG_OVERRIDE"
fi

run_dir="${1:-}"
report_is_stub="${2:-false}"
mode="${3:-}"
recall_flag="${4:-}"
[ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: summarize.sh <RUN_DIR> <REPORT_IS_STUB> [MODE] [--recall]"
run_dir="$(cd "$run_dir" && pwd)"

case "$report_is_stub" in
  true|false) : ;;
  *) die "usage: summarize.sh <RUN_DIR> <REPORT_IS_STUB: true|false> [MODE] [--recall]" ;;
esac

# --recall (bugsweep-dxh): gates ONLY whether run-summary.json's near_misses[]
# is populated from near_miss ledger events (Referee-recorded, confidence
# 50-67 — see bench/scorer/run_summary.py's reduce_run 'recall' param). It can
# NEVER affect fixed/quarantined/confirmed_unfixed/findings: those are
# computed from FINDING_EVENTS, which near_miss is not a member of. An
# explicit "--recall" 4th arg wins; otherwise falls back to the
# .recall.enabled config knob (default false) so a caller that always invokes
# summarize.sh the same way (e.g. finalize.sh) still honors a config change
# without needing its own --recall wiring.
recall_enabled="false"
if [ "$recall_flag" = "--recall" ]; then
  recall_enabled="true"
else
  recall_enabled="$(cfg_get '.recall.enabled' 'false')"
fi

summary_path="${run_dir}/run-summary.json"

# --- Tier 2 helpers: grep-able coverage extraction, no python3 required -------
_degraded_coverage() {
  local recon="${run_dir}/recon.json" covered=0 total=0 body
  if [ -f "$recon" ]; then
    body="$(grep -o '"covered"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$recon" 2>/dev/null \
      | sed 's/.*\[//; s/\].*//; s/[[:space:]]//g')"
    if [ -z "$body" ]; then
      covered=0
    else
      covered=$(( $(printf '%s' "$body" | grep -o ',' | wc -l | tr -d ' ') + 1 ))
    fi
    total="$(grep -o '"batch_count"[[:space:]]*:[[:space:]]*[0-9]*' "$recon" 2>/dev/null \
      | grep -o '[0-9]*$' | head -1)"
  fi
  case "$covered" in ''|*[!0-9]*) covered=0 ;; esac
  case "$total"   in ''|*[!0-9]*) total=0   ;; esac
  printf '%s %s' "$covered" "$total"
}

# Minimal JSON string escaper for the degraded path (bash-3.2 + POSIX tools only).
# JSON forbids raw control chars in strings and the degraded path never needs them,
# so strip 0x00-0x1F (incl. newlines/tabs) first, THEN escape backslash BEFORE
# double-quote — reversing that order would re-escape the backslashes the quote
# escaping just introduced. sed replacement backslashes are doubled per POSIX
# semantics ('\\\\' in the script emits ONE literal backslash in the output).
_json_escape() {
  printf '%s' "${1:-}" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

_write_degraded_summary() {
  local covered="$1" total="$2" status stop_reason mode_json
  if [ "$report_is_stub" = "false" ]; then
    status="complete"
    stop_reason="null"
  elif [ "$covered" -gt 0 ]; then
    status="partial"
    stop_reason='"report.md was never written but some hunt batches were covered — the run made partial progress before stopping (e.g. during the architectural hunt)."'
  else
    status="stalled"
    stop_reason='"report.md was never written and no hunt batches were covered — the run stalled before making any progress (e.g. during context-build)."'
  fi

  mode_json="null"
  [ -n "$mode" ] && mode_json="\"$(_json_escape "$mode")\""

  cat > "$summary_path" <<JSON
{
  "schema_version": 1,
  "mode": ${mode_json},
  "status": "${status}",
  "stop_reason": ${stop_reason},
  "degraded": true,
  "coverage": {"covered": ${covered}, "total": ${total}},
  "counts": {"critical": 0, "high": 0, "medium": 0, "low": 0, "architectural": 0},
  "fixed": [],
  "quarantined": [],
  "confirmed_unfixed": [],
  "findings": [],
  "root_cause_clusters": [],
  "follow_up": [],
  "flaky": [],
  "near_misses": []
}
JSON
}

_run_degraded() {
  log "summarize: emitting degraded run-summary.json (grep-derived coverage only)."
  local cov tot
  # shellcheck disable=SC2046
  set -- $(_degraded_coverage)
  cov="${1:-0}"; tot="${2:-0}"
  _write_degraded_summary "$cov" "$tot"
}

# --- Tier 1: python3 reduction, via a real script file (never heredoc-nest) --
_py_reducer="${BUGSWEEP_SCRIPT_DIR}/_run_summary_reduce.py"

if have_python && [ -f "$_py_reducer" ]; then
  if ! MODE="$mode" REPORT_IS_STUB="$report_is_stub" RUN_DIR="$run_dir" \
       RECALL="$recall_enabled" \
       BUGSWEEP_ROOT="$BUGSWEEP_ROOT" \
       python3 "$_py_reducer" "$summary_path" 2>/dev/null; then
    log "summarize: python3 reduction failed; falling back to degraded summary."
    _run_degraded
  fi
else
  [ -f "$_py_reducer" ] || log "summarize: reducer entrypoint missing (${_py_reducer})."
  _run_degraded
fi

[ -f "$summary_path" ] || die "summarize: failed to write ${summary_path}"

echo "RUN_SUMMARY=${summary_path}"
