#!/usr/bin/env bash
# bugsweep loop guard. Prints "CONTINUE" or "STOP <reason>".
# Reads caps from config and progress from the ledger. This is the deterministic
# brake that bounds cost and runtime on unattended runs.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="${1:-}"
[ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: guard.sh <RUN_DIR>"
# shellcheck disable=SC1090
. "${run_dir}/state.env"

bash "${BUGSWEEP_SCRIPT_DIR}/state.sh" lease-touch "$run_dir" >/dev/null 2>&1 || true  # bugsweep-re9: per-iteration lease heartbeat (best-effort, non-fatal)

max_iter="$(cfg_get '.caps.max_iterations' '10')"
max_minutes="$(cfg_get '.caps.max_runtime_minutes' '120')"
max_fixes="$(cfg_get '.caps.max_fixes_per_run' '50')"
no_progress_stop="$(cfg_get '.caps.no_progress_streak_to_stop' '2')"
case "$max_minutes" in
  ''|*[!0-9]*) max_minutes=120 ;;
esac
[ "$max_minutes" -gt 0 ] || max_minutes=120

ledger="${run_dir}/ledger.jsonl"
iters="$(count_event "$ledger" iteration)"
fixes="$(count_event "$ledger" fix_committed)"

# Runtime cap
now="$(date +%s)"
elapsed_sec=$(( now - BUGSWEEP_START_EPOCH ))
[ "$elapsed_sec" -ge 0 ] || elapsed_sec=0
elapsed_min=$(( elapsed_sec / 60 ))
deadline_epoch="${BUGSWEEP_DEADLINE_EPOCH:-}"
case "$deadline_epoch" in
  ''|*[!0-9]*) deadline_epoch=$(( BUGSWEEP_START_EPOCH + (max_minutes * 60) )) ;;
esac
remaining_sec=$(( deadline_epoch - now ))
[ "$remaining_sec" -ge 0 ] || remaining_sec=0

# No-progress streak: count trailing iterations whose "new_bugs" was 0.
streak=0
while IFS= read -r line; do
  case "$line" in
    *'"event":"iteration"'*)
      nb="$(printf '%s' "$line" | grep -o '"new_bugs":[0-9]*' | grep -o '[0-9]*' || echo 1)"
      if [ "${nb:-1}" -eq 0 ]; then streak=$((streak+1)); else streak=0; fi
      ;;
  esac
done < "$ledger"

if [ "$iters" -ge "$max_iter" ]; then echo "STOP iteration_cap_reached(${iters}/${max_iter})"; exit 0; fi
if [ "$now" -ge "$deadline_epoch" ]; then echo "STOP runtime_cap_reached(${elapsed_min}m/${max_minutes}m,remaining_sec=${remaining_sec},deadline_epoch=${deadline_epoch})"; exit 0; fi
if [ "$fixes" -ge "$max_fixes" ]; then echo "STOP fix_cap_reached(${fixes}/${max_fixes})"; exit 0; fi
if [ "$streak" -ge "$no_progress_stop" ]; then echo "STOP converged_no_new_bugs(streak=${streak})"; exit 0; fi

echo "CONTINUE iters=${iters} fixes=${fixes} elapsed_min=${elapsed_min} remaining_sec=${remaining_sec} deadline_epoch=${deadline_epoch} no_progress_streak=${streak}"
