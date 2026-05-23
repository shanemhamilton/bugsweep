#!/usr/bin/env bash
# bugsweep session continuity. Durable state lives on disk, so a context reset
# (compaction / fresh window) drops only working memory, never progress.
#   session.sh checkpoint <RUN_DIR>   -> refresh SESSION.md; print RESET_RECOMMENDED if due
#   session.sh brief      <RUN_DIR>   -> print the rehydration brief to read after a reset

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

cmd="${1:-}"; run_dir="${2:-}"
[ -n "$cmd" ] && [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: session.sh <checkpoint|brief> <RUN_DIR>"
run_dir="$(cd "$run_dir" && pwd)"
# shellcheck disable=SC1090
. "${run_dir}/state.env"

ledger="${run_dir}/ledger.jsonl"

iters="$(count_event "$ledger" iteration)"
fixes="$(count_event "$ledger" fix_committed)"
quarantined="$(count_event "$ledger" quarantine)"
checkpoints="$(count_event "$ledger" checkpoint)"
# Confirmed-open = confirmed bugs minus those fixed or quarantined (best-effort from events).
confirmed="$(grep -o '"confirmed":[0-9]*' "$ledger" 2>/dev/null | grep -o '[0-9]*' | awk '{s+=$1} END{print s+0}')"

every="$(cfg_get '.session.checkpoint_every_iterations' '3')"

# Pull the "next action" / coverage line if recon.json + a coverage note exist.
coverage="unknown"
if [ -f "${run_dir}/recon.json" ]; then
  total="$(grep -o '"files_in_scope":[0-9]*' "${run_dir}/recon.json" | grep -o '[0-9]*' | head -1 || echo '?')"
  covered="$(count_event "$ledger" batch_covered)"
  batches="$(grep -o '"batch_count":[0-9]*' "${run_dir}/recon.json" | grep -o '[0-9]*' | head -1 || echo '?')"
  coverage="${covered}/${batches} batches  (~${total} files in scope)"
fi

if [ "$cmd" = "checkpoint" ]; then
  printf '{"event":"checkpoint","iters":%s,"fixes":%s}\n' "$iters" "$fixes" >> "$ledger"
  cat > "${run_dir}/SESSION.md" <<EOF
# bugsweep session continuity anchor
_Last checkpoint: $(date '+%Y-%m-%d %H:%M:%S')_

Branch: ${BUGSWEEP_BRANCH}   (original: ${BUGSWEEP_ORIG_BRANCH})
Progress: iteration ${iters} · fixes committed ${fixes} · quarantined ${quarantined} · confirmed total ${confirmed}
Coverage: ${coverage}

## To resume after a context reset, read these in order, then continue the loop:
1. SESSION.md            (this file — where we are)
2. repo-context.md       (architecture, trust boundaries, sensitive sinks, call chains)
3. antipatterns.md       (stack-specific patterns the hunters must watch for)
4. recon.json            (batch plan + which batches are already covered)
5. prior-coverage.json   (coverage-first frontier from prior runs: never-audited / stale / high-risk)
6. ledger.jsonl          (full event history; tail it for the last decisions)

## Next action
Run guard.sh; if CONTINUE, hunt the next uncovered batch in recon.json. Do NOT re-hunt
covered batches. Preserve all findings already recorded in the ledger.
EOF

  # Recommend a reset on the cadence so the main thread never bloats on long runs.
  if [ "$every" -gt 0 ] && [ "$iters" -gt 0 ] && [ $(( iters % every )) -eq 0 ]; then
    echo "RESET_RECOMMENDED iters=${iters} every=${every}"
  else
    echo "OK iters=${iters} fixes=${fixes} coverage=${coverage}"
  fi
  exit 0
fi

if [ "$cmd" = "brief" ]; then
  [ -f "${run_dir}/SESSION.md" ] && cat "${run_dir}/SESSION.md" || echo "No SESSION.md yet — run a checkpoint first."
  exit 0
fi

die "unknown command: $cmd"
