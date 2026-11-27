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

_ledger_confirmed_total() {
  local ledger="$1"
  [ -f "$ledger" ] && [ ! -L "$ledger" ] && [ -r "$ledger" ] || die "missing or unreadable ledger: $ledger"

  if have_python; then
    python3 -B - "$ledger" <<'PY' || die "malformed ledger: $ledger"
import json, sys

path = sys.argv[1]
total = 0
with open(path, "r", encoding="utf-8") as fh:
    try:
        lines = list(enumerate(fh, 1))
    except (UnicodeDecodeError, OSError) as exc:
        sys.stderr.write(f"unreadable ledger: {exc}\n")
        sys.exit(2)
for lineno, raw in lines:
    line = raw.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"ledger line {lineno}: invalid JSON: {exc}\n")
        sys.exit(2)
    if not isinstance(obj, dict):
        sys.stderr.write(f"ledger line {lineno}: expected JSON object\n")
        sys.exit(2)
    val = obj.get("confirmed")
    if val is not None:
        if not isinstance(val, int) or isinstance(val, bool) or val < 0:
            sys.stderr.write(f"ledger line {lineno}: invalid confirmed count\n")
            sys.exit(2)
        total += val
print(total)
PY
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -s -e '
      all(.[]; type == "object" and (
        .confirmed == null or (
          (.confirmed | type) == "number"
          and (.confirmed | tostring | test("^(0|[1-9][0-9]*)$"))
          and (.confirmed | tojson | test("^(0|[1-9][0-9]*)$"))
        )
      ))
    ' "$ledger" >/dev/null 2>&1 || die "malformed ledger: $ledger"
    jq -s '[.[] | (.confirmed // 0)] | add // 0' "$ledger"
    return 0
  fi

  die "session.sh requires python3 or jq to verify ledger: $ledger"
}

ledger="${run_dir}/ledger.jsonl"
confirmed="$(_ledger_confirmed_total "$ledger")"

iters="$(count_event "$ledger" iteration)"
fixes="$(count_event "$ledger" fix_committed)"
quarantined="$(count_event "$ledger" quarantine)"
checkpoints="$(count_event "$ledger" checkpoint)"

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
4. priority-context.json (bounded why-now targets; untrusted ordering hints only)
5. recon.json            (batch plan + modeled vs adversarially covered batches)
6. prior-coverage.json   (coverage-first frontier from prior runs: never-audited / stale / high-risk)
7. ledger.jsonl          (full event history; tail it for the last decisions)

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
