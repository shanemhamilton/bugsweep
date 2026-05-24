#!/usr/bin/env bash
# bugsweep cross-run state: the coverage-first persistence layer.
#
# Durable audit COVERAGE + historical RISK that survive across runs, so the hunt
# always spans the WHOLE repo (never-audited + stale + changed + risky + sinks),
# never just the latest diff. All state lives in <repo>/.bugsweep/state/ and is
# already kept out of git by preflight's info/exclude entry.
#
#   state.sh persist <RUN_DIR>   harvest this run's coverage+risk into .bugsweep/state/
#   state.sh prime   <RUN_DIR>   write <RUN_DIR>/prior-coverage.json; print SUMMARY=...
#   state.sh catalog-version     print the current anti-pattern catalog version
#
# Coverage-first contract: this layer NEVER narrows scope; it only REPRIORITIZES.
# The repo is never "done" — files never audited at the current catalog version,
# or audited too long ago, stay on the frontier across runs. If anything here
# fails, callers continue (a broken cache must never fail or shrink a run).

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# State location + have_python + bugsweep_meta_runs come from common.sh.
STATE_DIR="$BUGSWEEP_STATE_DIR"
AUDIT_LOG="${STATE_DIR}/audit-log.jsonl"
RISK_LOG="${STATE_DIR}/risk.jsonl"
META="${STATE_DIR}/meta.json"

# Coverage uses the AGGREGATE catalog version (sum of per-class versions, from common.sh):
# a file's audit goes stale when ANY detector class advances, so any catalog change re-audits
# broadly. Falls back to the legacy single-integer VERSION when versions.json is unreadable.
catalog_version() { catalog_aggregate_version; }

# ---------------------------------------------------------------------------
persist() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: state.sh persist <RUN_DIR>"
  run_dir="$(cd "$run_dir" && pwd)"
  # shellcheck disable=SC1090
  . "${run_dir}/state.env" 2>/dev/null || true

  mkdir -p "$STATE_DIR" 2>/dev/null || { log "state: cannot create ${STATE_DIR}; skipping persist."; return 0; }

  local cat_v ts run_id ordinal
  cat_v="$(catalog_version)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run_id="${BUGSWEEP_TS:-$(date +%Y%m%d-%H%M%S)}"
  ordinal=$(( $(bugsweep_meta_runs) + 1 ))

  if have_python; then
    AUDIT_LOG="$AUDIT_LOG" RISK_LOG="$RISK_LOG" META="$META" \
    python3 - "$run_dir" "$run_id" "$ordinal" "$cat_v" "$ts" <<'PY' 2>/dev/null || {
import json, os, sys
run_dir, run_id, ordinal, cat_v, ts = sys.argv[1:6]
ordinal = int(ordinal)
audit_log, risk_log, meta = os.environ["AUDIT_LOG"], os.environ["RISK_LOG"], os.environ["META"]
ledger = os.path.join(run_dir, "ledger.jsonl")
recon  = os.path.join(run_dir, "recon.json")

events, covered_ids = [], set()
if os.path.exists(ledger):
    for line in open(ledger):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        events.append(e)
        if e.get("event") == "batch_covered":
            bid = e.get("batch", e.get("id"))
            if bid is not None:
                covered_ids.add(bid)

batches = []
if os.path.exists(recon):
    try:
        r = json.load(open(recon))
        batches = r.get("batches", []) or []
        for c in (r.get("covered", []) or []):
            covered_ids.add(c)
    except Exception:
        pass

files = set()
for b in batches:
    if b.get("id") in covered_ids:
        for f in (b.get("files", []) or []):
            files.add(f)

with open(audit_log, "a") as out:
    for f in sorted(files):
        out.write(json.dumps({"run": ordinal, "run_id": run_id, "ts": ts,
                              "catalog_version": cat_v, "file": f, "outcome": "audited"}) + "\n")

RISK = {"fix_committed", "quarantine", "confirmed", "false_positive"}
with open(risk_log, "a") as out:
    for e in events:
        ev = e.get("event")
        if ev in RISK and e.get("file"):
            out.write(json.dumps({"run": ordinal, "run_id": run_id, "ts": ts,
                                  "file": e["file"], "event": ev,
                                  "severity": e.get("severity", "")}) + "\n")

d = {}
if os.path.exists(meta):
    try:
        d = json.load(open(meta))
    except Exception:
        d = {}
d["runs"] = ordinal
d.setdefault("schema", 1)
json.dump(d, open(meta, "w"))
print("AUDITED_FILES=%d" % len(files))
PY
      log "state: python harvest failed; persisting risk events via fallback."
      _persist_fallback "$run_dir" "$run_id" "$ordinal" "$ts"
    }
  else
    log "state: python3 unavailable — persisting risk events only (coverage harvest skipped)."
    _persist_fallback "$run_dir" "$run_id" "$ordinal" "$ts"
  fi
}

# Minimal degraded persist: harvest fix_committed lines that carry a file, and
# bump the runs counter, without the recon batch→file expansion.
_persist_fallback() {
  local run_dir="$1" run_id="$2" ordinal="$3" ts="$4"
  local ledger="${run_dir}/ledger.jsonl"
  if [ -f "$ledger" ]; then
    while IFS= read -r line; do
      case "$line" in
        *'"event":"fix_committed"'*|*'"event":"quarantine"'*)
          local f
          f="$(printf '%s' "$line" | grep -o '"file":"[^"]*"' | head -1 | sed 's/"file":"//; s/"$//')"
          [ -n "$f" ] || continue
          local ev='fix_committed'
          case "$line" in *'"event":"quarantine"'*) ev='quarantine' ;; esac
          printf '{"run":%s,"run_id":"%s","ts":"%s","file":"%s","event":"%s","severity":""}\n' \
            "$ordinal" "$run_id" "$ts" "$f" "$ev" >> "$RISK_LOG"
          ;;
      esac
    done < "$ledger"
  fi
  printf '{"schema":1,"runs":%s}\n' "$ordinal" > "$META"
}

# ---------------------------------------------------------------------------
prime() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: state.sh prime <RUN_DIR>"
  run_dir="$(cd "$run_dir" && pwd)"
  local out_path="${run_dir}/prior-coverage.json"

  local cat_v decay top_n recheck
  cat_v="$(catalog_version)"
  decay="$(cfg_get '.context.decay_factor' '0.85')"
  top_n="$(cfg_get '.context.high_risk_top_n' '25')"
  recheck="$(cfg_get '.context.recheck_audited_after_runs' '5')"

  if have_python; then
    AUDIT_LOG="$AUDIT_LOG" RISK_LOG="$RISK_LOG" META="$META" \
    python3 - "$cat_v" "$decay" "$top_n" "$recheck" "$out_path" <<'PY' 2>/dev/null && return 0
import json, os, sys
cat_v, decay, top_n, recheck, out_path = sys.argv[1:6]
decay = float(decay); top_n = int(top_n); recheck = int(recheck)
audit_log, risk_log, meta = os.environ["AUDIT_LOG"], os.environ["RISK_LOG"], os.environ["META"]

runs = 0
if os.path.exists(meta):
    try:
        runs = int(json.load(open(meta)).get("runs", 0))
    except Exception:
        runs = 0
current = runs + 1

def vkey(v):
    try:
        return (1, [int(x) for x in str(v).split(".")])
    except Exception:
        return (0, str(v))

# file -> (best catalog_version, last run audited)
best = {}
if os.path.exists(audit_log):
    for line in open(audit_log):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        f = e.get("file")
        if not f:
            continue
        cv = str(e.get("catalog_version", "0"))
        rn = int(e.get("run", 0))
        cur_best = best.get(f)
        if cur_best is None:
            best[f] = [cv, rn]
        else:
            if vkey(cv) > vkey(cur_best[0]):
                cur_best[0] = cv
            if rn > cur_best[1]:
                cur_best[1] = rn

cur = str(cat_v)
audited_current, audited_stale = [], []
for f, (cv, rn) in best.items():
    catalog_ok = vkey(cv) >= vkey(cur)
    fresh = (current - rn) < recheck
    if catalog_ok and fresh:
        audited_current.append(f)
    else:
        audited_stale.append(f)
audited_current.sort(); audited_stale.sort()

WEIGHTS = {"fix_committed": 3, "quarantine": 2, "confirmed": 1, "false_positive": -1}
score = {}
if os.path.exists(risk_log):
    for line in open(risk_log):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        f = e.get("file")
        if not f:
            continue
        w = WEIGHTS.get(e.get("event"), 0)
        age = max(0, current - int(e.get("run", current)))
        score[f] = score.get(f, 0.0) + w * (decay ** age)
high = sorted(((f, round(max(0.0, s), 3)) for f, s in score.items() if s > 0),
             key=lambda x: -x[1])[:top_n]

CAP = 200
out = {
    "schema": 1,
    "catalog_version": cur,
    "prior_runs": runs,
    "files_audited_current_catalog": audited_current[:CAP],
    "files_audited_current_catalog_count": len(audited_current),
    "files_audited_stale_catalog": audited_stale[:CAP],
    "files_audited_stale_catalog_count": len(audited_stale),
    "high_risk_files": [{"file": f, "score": s} for f, s in high],
    "truncated": len(audited_current) > CAP or len(audited_stale) > CAP,
}
json.dump(out, open(out_path, "w"), indent=2)

if runs == 0:
    print("SUMMARY=first run on this repo — entire codebase is the unaudited frontier; whole-repo scope.")
else:
    print("SUMMARY=prior_runs=%d audited@v%s=%d stale=%d high_risk=%d"
          % (runs, cur, len(audited_current), len(audited_stale), len(high)))
PY
  fi

  # Degraded path: no python3 or no state yet. Emit an empty-history file so
  # context-build treats the WHOLE repo as the frontier (safe: never narrows).
  local runs; runs="$(bugsweep_meta_runs)"
  cat > "$out_path" <<EOF
{"schema":1,"catalog_version":"${cat_v}","prior_runs":${runs},"files_audited_current_catalog":[],"files_audited_current_catalog_count":0,"files_audited_stale_catalog":[],"files_audited_stale_catalog_count":0,"high_risk_files":[],"degraded":true}
EOF
  if [ "$runs" = "0" ]; then
    echo "SUMMARY=first run on this repo — entire codebase is the unaudited frontier; whole-repo scope."
  else
    echo "SUMMARY=coverage history unavailable (no python3) — whole-repo scope, no reprioritization applied."
  fi
}

# ---------------------------------------------------------------------------
cmd="${1:-}"
case "$cmd" in
  persist)         persist "${2:-}" ;;
  prime)           prime "${2:-}" ;;
  catalog-version) catalog_version; echo ;;
  *)               die "usage: state.sh <persist|prime|catalog-version> [RUN_DIR]" ;;
esac
