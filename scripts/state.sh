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
#   state.sh lease-acquire <RUN_DIR>   record a per-run liveness lease (bugsweep-p74)
#   state.sh lease-touch   <RUN_DIR>   refresh an EXISTING lease's mtime (bugsweep-re9 heartbeat)
#   state.sh lease-release <RUN_DIR>   release this run's lease
#   state.sh lease-list                list currently-live leases (LEASE=<run_dir> lines)
#
# Coverage-first contract: this layer NEVER narrows scope; it only REPRIORITIZES.
# The repo is never "done" — files never audited at the current catalog version,
# or audited too long ago, stay on the frontier across runs. If anything here
# fails, callers continue (a broken cache must never fail or shrink a run).
#
# bugsweep-p74 concurrency note: up to N subagents of one metaswarm orchestrator
# may call `persist` at the same moment against the SAME .bugsweep/state/ dir
# (they share BUGSWEEP_STATE_DIR — see common.sh). Leases below are bookkeeping
# only (liveness + stale reclaim); they COEXIST, they never block a sibling run.
# The one true mutual-exclusion need is meta.json's run counter: the ordinal
# MUST be computed and written inside a single lock's critical section, or two
# concurrent persists both read runs=R and both write runs=R+1, silently losing
# a count. See persist() below.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# State location + have_python + bugsweep_meta_runs come from common.sh.
STATE_DIR="$BUGSWEEP_STATE_DIR"
AUDIT_LOG="${STATE_DIR}/audit-log.jsonl"
RISK_LOG="${STATE_DIR}/risk.jsonl"
META="${STATE_DIR}/meta.json"
META_LOCK="${STATE_DIR}/meta.lock"
LEASES_DIR="${STATE_DIR}/leases"
# How old (seconds) an on-disk lease may be before it's considered stale even
# with a live pid (defends against a pid recycled by the OS onto an unrelated
# process). A dead pid is NOT reclaimed immediately — the recorded pid
# legitimately dies with the shell that ran preflight — it is reclaimed only
# once the lease file's mtime ages past BUGSWEEP_LEASE_GRACE_SECONDS (default
# 900s; see _lease_is_stale).
LEASE_STALE_SECONDS="${BUGSWEEP_LEASE_STALE_SECONDS:-14400}"  # 4h

# Coverage uses the AGGREGATE catalog version (sum of per-class versions, from common.sh):
# a file's audit goes stale when ANY detector class advances, so any catalog change re-audits
# broadly. Falls back to the legacy single-integer VERSION when versions.json is unreadable.
catalog_version() { catalog_aggregate_version; }

# Reserve the next run ordinal and persist it into meta.json, ALL inside a single
# mkdir-lock critical section. This is the fix for bugsweep-p74: previously the
# ordinal was computed via bugsweep_meta_runs() (a plain read of meta.json)
# BEFORE any lock was taken, so N concurrent persists all read the same "runs"
# value and each wrote back runs+1 — last writer wins, count silently loses
# N-1 increments. Reading AND writing meta.json now happens only while holding
# META_LOCK, so five concurrent finalizes yield runs == prior + 5, never less.
# Prints the reserved ordinal on stdout. Falls back to an unlocked read (best
# effort, may race) only if the lock cannot be acquired within its timeout —
# this keeps `persist` non-fatal per the coverage-first contract.
_reserve_run_ordinal() {
  local run_dir="${1:-}" lock_timeout="${BUGSWEEP_META_LOCK_TIMEOUT:-15}" ordinal
  if bugsweep_lock_acquire "$META_LOCK" "$lock_timeout"; then
    ordinal=$(( $(bugsweep_meta_runs) + 1 ))
    if have_python; then
      ORDINAL="$ordinal" META="$META" python3 -c '
import json, os
meta, ordinal = os.environ["META"], int(os.environ["ORDINAL"])
d = {}
if os.path.exists(meta):
    try:
        d = json.load(open(meta))
    except Exception:
        d = {}
d["runs"] = ordinal
d.setdefault("schema", 1)
json.dump(d, open(meta, "w"))
' 2>/dev/null || printf '{"schema":1,"runs":%s}\n' "$ordinal" > "$META"
    else
      printf '{"schema":1,"runs":%s}\n' "$ordinal" > "$META"
    fi
    bugsweep_lock_release "$META_LOCK"
  else
    log "state: meta.lock busy after ${lock_timeout} poll attempts — reserving ordinal unlocked (best effort)."
    ordinal=$(( $(bugsweep_meta_runs) + 1 ))
    # Review fix G (bugsweep-p74): make the degraded path LOUD in the run's own
    # ledger, not just a stderr line nobody persists — an unlocked ordinal is a
    # silent risk of an incorrect cross-run count and must be auditable.
    if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
      printf '{"event":"state_lock_timeout","ts":"%s","lock":"meta.lock","ordinal_best_effort":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ordinal" >> "${run_dir}/ledger.jsonl" 2>/dev/null || true
    fi
  fi
  printf '%s' "$ordinal"
}

# ---------------------------------------------------------------------------
persist() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: state.sh persist <RUN_DIR>"
  run_dir="$(cd "$run_dir" && pwd)"
  # shellcheck disable=SC1090
  . "${run_dir}/state.env" 2>/dev/null || true

  bugsweep_state_dir_ready && mkdir -p "$STATE_DIR" 2>/dev/null \
    || { log "state: cannot use project-scoped state dir (${STATE_DIR:-not in a git repo}); skipping persist."; return 0; }

  # bugsweep-re9 retry 1 (MAJOR 2): persist() deliberately does NOT touch the
  # lease. persist() is invoked exactly ONCE per run, at the very end
  # (finalize.sh, five lines before lease-release) — never per iteration — so a
  # heartbeat here would refresh a lease that is about to be deleted and gives
  # ZERO mid-run protection. guard.sh (called between every iteration) is the
  # SOLE per-iteration heartbeat.

  local cat_v ts run_id ordinal
  cat_v="$(catalog_version)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run_id="${BUGSWEEP_TS:-$(date +%Y%m%d-%H%M%S)}"
  ordinal="$(_reserve_run_ordinal "$run_dir")"

  if have_python; then
    AUDIT_LOG="$AUDIT_LOG" RISK_LOG="$RISK_LOG" \
    python3 - "$run_dir" "$run_id" "$ordinal" "$cat_v" "$ts" <<'PY' 2>/dev/null || {
import json, os, sys
run_dir, run_id, ordinal, cat_v, ts = sys.argv[1:6]
ordinal = int(ordinal)
audit_log, risk_log = os.environ["AUDIT_LOG"], os.environ["RISK_LOG"]
ledger = os.path.join(run_dir, "ledger.jsonl")
recon  = os.path.join(run_dir, "recon.json")

# bugsweep-p74: append one full JSON line per record via a dedicated
# os.open(..., O_APPEND) + os.write() call each time, instead of batching many
# writes inside one `open(...).write()` block. A single write(2) syscall of a
# small buffer (well under PIPE_BUF) with O_APPEND is atomic on POSIX: the
# kernel seeks-to-end and writes in one step, so concurrent bugsweep processes
# appending to the SAME audit-log.jsonl / risk.jsonl can never interleave
# mid-line or tear a record, even without any external lock.
def append_line(path, obj):
    data = (json.dumps(obj) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)

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

for f in sorted(files):
    append_line(audit_log, {"run": ordinal, "run_id": run_id, "ts": ts,
                             "catalog_version": cat_v, "file": f, "outcome": "audited"})

RISK = {"fix_committed", "quarantine", "confirmed", "false_positive"}
for e in events:
    ev = e.get("event")
    if ev in RISK and e.get("file"):
        append_line(risk_log, {"run": ordinal, "run_id": run_id, "ts": ts,
                                "file": e["file"], "event": ev,
                                "severity": e.get("severity", "")})

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

# Minimal degraded persist: harvest fix_committed/quarantine lines that carry a
# file into the risk log, without the recon batch→file expansion. It
# deliberately does NOT touch meta.json — the run ordinal was already reserved
# AND persisted inside _reserve_run_ordinal's locked critical section before
# this runs. Rewriting meta.json here (as this function once did) happened
# OUTSIDE the lock and clobbered concurrent runs' counts: N concurrent
# fallback-path persists could end with runs advanced by only 1 (review
# blocker A, bugsweep-p74).
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
# Per-run leases (bugsweep-p74).
#
# A lease is a liveness record for ONE run — "this pid, working in this
# worktree/run-dir, is still alive". Leases are bookkeeping, not a mutex: any
# number of them may exist at once (that is the whole point of `preflight.sh
# --worktree` — up to 5 sibling subagents run concurrently). The ONLY lock
# used here is the short mkdir-lock around LEASES_DIR list/write operations,
# to avoid two callers racing on the same lease file's create/delete.
#
# bugsweep-re9 HEARTBEAT: liveness here is ultimately judged by the lease
# FILE's mtime once the recorded pid is dead (_lease_is_stale's grace-window
# branch) — and the recorded pid is *routinely* dead almost immediately in
# agent-driven flows, because every Bash tool call is a fresh shell. Even the
# documented `BUGSWEEP_LEASE_PID=$$` override only records the pid of THAT
# shell invocation, which exits the moment the tool call returns. Without a
# heartbeat, the lease file's mtime is set once at lease-acquire time and
# never refreshed, so any run longer than BUGSWEEP_LEASE_GRACE_SECONDS
# (default 900s) is reclaimed by a sibling's stale-lease pass while still
# genuinely in-flight. `lease_touch` (below) closes this: guard.sh, which
# runs between every loop iteration, calls it (best-effort, non-fatal) on
# every pass so the lease's mtime keeps advancing for as long as the run is
# alive, independent of whether its recorded pid still exists. guard.sh is the
# SOLE per-iteration heartbeat — persist() runs only once at teardown and does
# NOT touch the lease (bugsweep-re9 retry 1, MAJOR 2). `lease_touch` MUST NOT
# create a lease that was never acquired — it only refreshes a lease file that
# already exists, under the leases lock so a concurrent lease-release can never
# be raced into recreating a zombie (bugsweep-re9 retry 1, BLOCKER 1).
#
# Lease id is derived from the run dir's basename so it's stable and
# human-readable in `lease-list` output (e.g. "run-20260706-153000-8421-a1b2").
_lease_id() {
  local run_dir="$1"
  basename "$run_dir" | tr -c 'A-Za-z0-9._-' '_'
}

# Portable file mtime in epoch seconds (GNU vs BSD stat); 0 when unreadable —
# which makes an unreadable lease file "very old", i.e. reclaimable.
_file_mtime() {
  local m
  if stat --version >/dev/null 2>&1; then
    m="$(stat -c %Y "$1" 2>/dev/null || true)"
  else
    m="$(stat -f %m "$1" 2>/dev/null || true)"
  fi
  case "$m" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$m" ;; esac
}

# True (0) if a lease is stale and may be reclaimed. Review-hardened semantics
# (bugsweep-p74 retry 1, review blocker B):
#   - alive pid  -> stale only past the hard age cap (LEASE_STALE_SECONDS, 4h):
#                   guards against an OS-recycled pid keeping a zombie lease alive.
#   - dead pid   -> stale only when the lease FILE's mtime is older than the
#                   grace window (BUGSWEEP_LEASE_GRACE_SECONDS, default 900s).
#                   The recorded pid legitimately dies the moment preflight
#                   exits in the plain `bash preflight.sh` invocation path, so
#                   a dead pid alone must NEVER trigger reclaim mid-run; a
#                   genuinely crashed run is still reclaimed once the grace
#                   window passes.
#   - unreadable pid -> treated as dead (grace window applies).
_lease_is_stale() {
  local lease_file="$1" pid started now age mtime grace
  grace="${BUGSWEEP_LEASE_GRACE_SECONDS:-900}"
  pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$lease_file" 2>/dev/null | head -1)"
  started="$(sed -n 's/.*"started"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$lease_file" 2>/dev/null | head -1)"
  now="$(date +%s)"
  case "$pid" in
    ''|*[!0-9]*) pid="" ;;
  esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    case "$started" in
      ''|*[!0-9]*) return 1 ;;  # alive and no timestamp to judge age -> not stale
    esac
    age=$(( now - started ))
    if [ "$age" -ge "$LEASE_STALE_SECONDS" ]; then return 0; fi
    return 1
  fi
  # Dead/unknown pid: reclaim only once the lease file has aged past the grace window.
  mtime="$(_file_mtime "$lease_file")"
  [ $(( now - mtime )) -ge "$grace" ]
}

# Reclaim (delete) any stale lease files. Best-effort; runs inside the caller's
# lock so it never races a concurrent acquire/list/release.
_lease_reclaim_stale() {
  [ -d "$LEASES_DIR" ] || return 0
  local f
  for f in "$LEASES_DIR"/*.json; do
    [ -e "$f" ] || continue
    if _lease_is_stale "$f"; then
      rm -f "$f" 2>/dev/null || true
    fi
  done
}

lease_acquire() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: state.sh lease-acquire <RUN_DIR>"
  run_dir="$(cd "$run_dir" && pwd)"
  bugsweep_state_dir_ready || { log "state: no project-scoped state dir; skipping lease."; return 0; }
  mkdir -p "$LEASES_DIR" 2>/dev/null || true

  local lock="${LEASES_DIR}.lock" id lease_file
  id="$(_lease_id "$run_dir")"
  lease_file="${LEASES_DIR}/${id}.json"
  # The lease's liveness pid must be the PROCESS THAT OWNS THE RUN, not this
  # short-lived `state.sh` invocation (which exits the instant this command
  # returns). That is normally the calling shell — $PPID. Allow an explicit
  # override via BUGSWEEP_LEASE_PID for callers (e.g. a long-running
  # orchestrator dispatching subagents) that know a more accurate owner pid.
  local BUGSWEEP_LEASE_PID="${BUGSWEEP_LEASE_PID:-$PPID}"

  if bugsweep_lock_acquire "$lock" 10; then
    _lease_reclaim_stale
    printf '{"pid":%s,"run_dir":"%s","started":%s}\n' "$BUGSWEEP_LEASE_PID" "$run_dir" "$(date +%s)" > "$lease_file"
    bugsweep_lock_release "$lock"
  else
    # Lock contention should never block a sibling run from starting; write
    # the lease unlocked as a best-effort fallback (a lost stale-reclaim pass
    # just means cleanup happens on the next acquire/list instead).
    log "state: leases.lock busy — writing lease unlocked (best effort)."
    printf '{"pid":%s,"run_dir":"%s","started":%s}\n' "$BUGSWEEP_LEASE_PID" "$run_dir" "$(date +%s)" > "$lease_file"
  fi
  echo "LEASE_ACQUIRED=${run_dir}"
}

# Heartbeat (bugsweep-re9): refresh an EXISTING lease's mtime so a run that
# outlives BUGSWEEP_LEASE_GRACE_SECONDS is not reclaimed by a sibling's
# stale-lease pass while genuinely still in-flight. Deliberately a NO-OP
# (never creates a lease) when no lease file exists for this run_dir — a
# heartbeat must never resurrect or fabricate a lease that lease-acquire was
# never called for. The lifecycle is: lease-acquire once up front
# (preflight.sh), then lease-touch on every loop iteration (guard.sh — the
# SOLE per-iteration heartbeat), then lease-release once at teardown
# (finalize.sh). persist() does NOT touch the lease: it runs a single time at
# the end of the run, so a heartbeat there would refresh a lease that is about
# to be released and provide no mid-run protection (bugsweep-re9 retry 1,
# MAJOR 2). Best-effort and non-fatal like every other lease operation: a
# failed touch just means the NEXT touch (or the grace window) determines
# reclaim, never a hard failure of the caller.
lease_touch() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] || die "usage: state.sh lease-touch <RUN_DIR>"
  bugsweep_state_dir_ready || return 0
  [ -d "$run_dir" ] && run_dir="$(cd "$run_dir" && pwd)"

  local lock="${LEASES_DIR}.lock" id lease_file
  id="$(_lease_id "$run_dir")"
  lease_file="${LEASES_DIR}/${id}.json"

  # Fast unlocked pre-check: if there is plainly no lease, do nothing and skip
  # the lock entirely (the common case — most runs have exactly one lease and
  # never race). This is ONLY an optimization; the create-vs-touch decision is
  # re-made UNDER the lock below, so a lease deleted after this check can never
  # be resurrected by us.
  [ -f "$lease_file" ] || return 0

  # bugsweep-re9 retry 1 (BLOCKER 1): `touch` CREATES the file when absent — it
  # is NOT a pure mtime bump. Without a lock, a concurrent lock-guarded
  # lease-release could delete the lease between the pre-check above and the
  # touch below, and our touch would then recreate a 0-byte ZOMBIE lease (no
  # pid/run_dir/started, fresh mtime) that survives the entire grace window.
  # Take the SAME leases lock that lease-acquire/lease-release use, and
  # re-verify existence UNDER the lock before touching — so a delete that
  # committed before we got the lock is observed and we do nothing, and a
  # delete that comes after cannot interleave (release must take this lock).
  if bugsweep_lock_acquire "$lock" 10; then
    # Deterministic race hook (tests only): force the check→act window open so
    # a concurrent lease-release can commit its delete before we re-check. In
    # production this variable is unset and this is a no-op. The point of the
    # test is that even WITH the window forced open, the re-check under the
    # lock below refuses to recreate the file.
    [ -n "${BUGSWEEP_LEASE_TOUCH_RACE_SLEEP:-}" ] && sleep "${BUGSWEEP_LEASE_TOUCH_RACE_SLEEP}" 2>/dev/null
    if [ -f "$lease_file" ]; then
      touch "$lease_file" 2>/dev/null || true
    fi
    bugsweep_lock_release "$lock"
  else
    # Lock contention must never block/fail a heartbeat — but it must also never
    # do an UNGUARDED touch (that reintroduces exactly the check-then-act zombie
    # this fix closes). So on contention we simply SKIP this heartbeat entirely:
    # a missed touch is harmless (guard.sh retries on the very next iteration,
    # and the grace window is 900s), whereas an unlocked touch could recreate a
    # lease a concurrent release just deleted. Only the fully lock-atomic path
    # above ever writes.
    log "state: leases.lock busy — skipping this lease heartbeat (best effort; next guard iteration retries)."
  fi
  echo "LEASE_TOUCHED=${run_dir}"
}

lease_release() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] || die "usage: state.sh lease-release <RUN_DIR>"
  bugsweep_state_dir_ready || return 0
  [ -d "$run_dir" ] && run_dir="$(cd "$run_dir" && pwd)"

  local lock="${LEASES_DIR}.lock" id lease_file
  id="$(_lease_id "$run_dir")"
  lease_file="${LEASES_DIR}/${id}.json"

  if bugsweep_lock_acquire "$lock" 10; then
    rm -f "$lease_file" 2>/dev/null || true
    bugsweep_lock_release "$lock"
  else
    rm -f "$lease_file" 2>/dev/null || true
  fi
  echo "LEASE_RELEASED=${run_dir}"
}

lease_list() {
  bugsweep_state_dir_ready || return 0
  [ -d "$LEASES_DIR" ] || return 0

  local lock="${LEASES_DIR}.lock" f run_dir
  if bugsweep_lock_acquire "$lock" 10; then
    _lease_reclaim_stale
    bugsweep_lock_release "$lock"
  fi
  for f in "$LEASES_DIR"/*.json; do
    [ -e "$f" ] || continue
    run_dir="$(sed -n 's/.*"run_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)"
    [ -n "$run_dir" ] && echo "LEASE=${run_dir}"
  done
  # bugsweep-re9 retry 1 (MAJOR 2): explicit success — otherwise the function's
  # exit status is that of the final loop iteration's `[ -n "$run_dir" ] && echo`,
  # so an empty/zombie lease file (no run_dir) as the last entry would make
  # lease-list exit 1 despite having listed successfully.
  return 0
}

# ---------------------------------------------------------------------------
cmd="${1:-}"
case "$cmd" in
  persist)         persist "${2:-}" ;;
  prime)           prime "${2:-}" ;;
  catalog-version) catalog_version; echo ;;
  lease-acquire)   lease_acquire "${2:-}" ;;
  lease-touch)     lease_touch "${2:-}" ;;
  lease-release)   lease_release "${2:-}" ;;
  lease-list)      lease_list ;;
  *)               die "usage: state.sh <persist|prime|catalog-version|lease-acquire|lease-touch|lease-release|lease-list> [RUN_DIR]" ;;
esac
