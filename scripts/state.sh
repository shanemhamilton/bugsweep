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
PRIORITY_OUTCOME_LOG="${STATE_DIR}/priority-outcomes.jsonl"
META="${STATE_DIR}/meta.json"
META_LOCK="${STATE_DIR}/meta.lock"
LEASES_DIR="${STATE_DIR}/leases"
META_MAX_BYTES=65536
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

_state_meta_runs() {
  [ -f "$META" ] && [ ! -L "$META" ] || { printf '0'; return 0; }
  if have_python; then
    META_PATH="$META" META_MAX_BYTES="$META_MAX_BYTES" python3 - <<'PY' 2>/dev/null || printf '0'
import json, os, stat
path = os.environ["META_PATH"]
limit = int(os.environ["META_MAX_BYTES"])
flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
try:
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError
        raw = os.read(fd, limit + 1)
    finally:
        os.close(fd)
    value = json.loads(raw)
    print(max(0, int(value.get("runs", 0))) if isinstance(value, dict) else 0)
except Exception:
    print(0)
PY
  else
    local size
    size="$(stat -f '%z' "$META" 2>/dev/null || stat -c '%s' "$META" 2>/dev/null || printf '')"
    case "$size" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
    [ "$size" -le "$META_MAX_BYTES" ] || { printf '0'; return 0; }
    grep -o '"runs"[[:space:]]*:[[:space:]]*[0-9]*' "$META" 2>/dev/null \
      | grep -o '[0-9]*' | head -1 || printf '0'
  fi
}

_write_meta_fallback() {
  local ordinal="$1" temp_path
  temp_path="$(mktemp "${STATE_DIR}/.meta.fallback.XXXXXX" 2>/dev/null || true)"
  [ -n "$temp_path" ] || return 1
  printf '{"schema":1,"runs":%s}\n' "$ordinal" > "$temp_path" || {
    rm -f -- "$temp_path"
    return 1
  }
  mv -f -- "$temp_path" "$META"
}

_state_storage_safe() {
  bugsweep_state_dir_ready || return 1
  local state_parent
  state_parent="$(dirname "$STATE_DIR")"
  [ ! -L "$state_parent" ] && [ ! -L "$STATE_DIR" ]
}

_write_meta_python() {
  local ordinal="$1" last_run_head="$2" run_id="$3" ts="$4" orig_branch="$5"
  META_PATH="$META" META_MAX_BYTES="$META_MAX_BYTES" ORDINAL="$ordinal" \
    LAST_RUN_HEAD="$last_run_head" RUN_ID="$run_id" RUN_TS="$ts" ORIG_BRANCH="$orig_branch" \
    python3 - <<'PY'
import json, os, stat, tempfile

meta = os.environ["META_PATH"]
limit = int(os.environ["META_MAX_BYTES"])
ordinal = int(os.environ["ORDINAL"])

def read_meta():
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(meta, flags)
    except FileNotFoundError:
        return {}
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            return {}
        raw = os.read(fd, limit + 1)
    finally:
        os.close(fd)
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}

d = read_meta()
d["runs"] = ordinal
d.setdefault("schema", 1)
head = os.environ.get("LAST_RUN_HEAD", "")
if head:
    d["last_run_head"] = head
    d["last_run_ordinal"] = ordinal
    d["last_run_id"] = os.environ.get("RUN_ID", "")
    d["last_run_at"] = os.environ.get("RUN_TS", "")
    branch = os.environ.get("ORIG_BRANCH", "")
    if branch and len(branch) <= 240 and "\x00" not in branch:
        raw_heads = d.get("last_run_heads")
        heads = dict(raw_heads) if isinstance(raw_heads, dict) else {}
        heads[branch] = {
            "head": head,
            "ordinal": ordinal,
            "run_id": os.environ.get("RUN_ID", ""),
            "at": os.environ.get("RUN_TS", ""),
        }
        if len(heads) > 50:
            def order(item):
                value = item[1]
                if not isinstance(value, dict):
                    return 0
                try:
                    return int(value.get("ordinal", 0))
                except (TypeError, ValueError):
                    return 0
            heads = dict(sorted(heads.items(), key=order, reverse=True)[:50])
        d["last_run_heads"] = heads

encoded = (json.dumps(d, separators=(",", ":")) + "\n").encode("utf-8")
if len(encoded) > limit:
    raise SystemExit("bounded meta.json would exceed its size limit")
temp_name = ""
try:
    with tempfile.NamedTemporaryFile(mode="wb", prefix=".meta.tmp-", dir=os.path.dirname(meta), delete=False) as handle:
        temp_name = handle.name
        os.fchmod(handle.fileno(), 0o600)
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_name, meta)
finally:
    if temp_name:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
PY
}

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
  local run_dir="${1:-}" last_run_head="${2:-}" run_id="${3:-}" ts="${4:-}" orig_branch="${5:-}"
  local lock_timeout="${BUGSWEEP_META_LOCK_TIMEOUT:-15}" ordinal
  if bugsweep_lock_acquire "$META_LOCK" "$lock_timeout"; then
    ordinal=$(( $(_state_meta_runs) + 1 ))
    if have_python; then
      _write_meta_python "$ordinal" "$last_run_head" "$run_id" "$ts" "$orig_branch" \
        2>/dev/null || _write_meta_fallback "$ordinal" || true
    else
      _write_meta_fallback "$ordinal" || true
    fi
    bugsweep_lock_release "$META_LOCK"
  else
    log "state: meta.lock busy after ${lock_timeout} poll attempts — reserving ordinal unlocked (best effort)."
    ordinal=$(( $(_state_meta_runs) + 1 ))
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

  # state.env is a run artifact, not executable configuration. Parse only the
  # exact keys this function needs; never source a file the model can modify.
  local state_env saved_ts saved_run_id saved_head saved_branch saved_worktree
  state_env="${run_dir}/state.env"
  saved_ts="$(_bsw_state_env_get "$state_env" BUGSWEEP_TS)"
  saved_run_id="$(_bsw_state_env_get "$state_env" BUGSWEEP_RUN_ID)"
  saved_head="$(_bsw_state_env_get "$state_env" BUGSWEEP_ORIG_HEAD)"
  saved_branch="$(_bsw_state_env_get "$state_env" BUGSWEEP_ORIG_BRANCH)"
  saved_worktree="$(_bsw_state_env_get "$state_env" BUGSWEEP_WORKTREE)"

  if ! _state_storage_safe || ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    log "state: cannot use project-scoped state dir (${STATE_DIR:-not in a git repo}); skipping persist."
    return 0
  fi

  # bugsweep-re9 retry 1 (MAJOR 2): persist() deliberately does NOT touch the
  # lease. persist() is invoked exactly ONCE per run, at the very end
  # (finalize.sh, five lines before lease-release) — never per iteration — so a
  # heartbeat here would refresh a lease that is about to be deleted and gives
  # ZERO mid-run protection. guard.sh (called between every iteration) is the
  # SOLE per-iteration heartbeat.

  local cat_v ts run_id ordinal repo_root
  cat_v="$(catalog_version)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # New runs persist preflight's collision-free bs_id. Keep BUGSWEEP_TS as a
  # compatibility fallback for old run directories that predate RUN_ID.
  run_id="${saved_run_id:-${saved_ts:-$(date +%Y%m%d-%H%M%S)}}"
  repo_root="$saved_worktree"
  if [ -z "$repo_root" ] || [ ! -d "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  ordinal="$(_reserve_run_ordinal "$run_dir" "$saved_head" "$run_id" "$ts" "$saved_branch")"

  if have_python; then
    AUDIT_LOG="$AUDIT_LOG" RISK_LOG="$RISK_LOG" PRIORITY_OUTCOME_LOG="$PRIORITY_OUTCOME_LOG" \
    BUGSWEEP_PERSIST_REPO="$repo_root" BUGSWEEP_PERSIST_SCRIPT_DIR="$BUGSWEEP_SCRIPT_DIR" \
    python3 - "$run_dir" "$run_id" "$ordinal" "$cat_v" "$ts" <<'PY' 2>/dev/null || {
import json, os, re, stat, sys
from pathlib import Path
run_dir, run_id, ordinal, cat_v, ts = sys.argv[1:6]
ordinal = int(ordinal)
audit_log = os.environ["AUDIT_LOG"]
risk_log = os.environ["RISK_LOG"]
priority_outcome_log = os.environ["PRIORITY_OUTCOME_LOG"]
ledger = os.path.join(run_dir, "ledger.jsonl")
recon  = os.path.join(run_dir, "recon.json")
priority_context = os.path.join(run_dir, "priority-context.json")

MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_JSONL_BYTES = 32 * 1024 * 1024
MAX_JSONL_LINE = 64 * 1024
MAX_EVENTS = 200_000
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9_.:/-]{1,120}$")
ALLOWED_PRIORITY_REASONS = {
    "active_incident", "baseline_failure", "changed_since_last_run", "cold_sink",
    "content_changed_since_audit", "critical_path", "fix_history", "git_history",
    "live_sink", "local_bug_issue", "maybe_sink", "prior_bug_history",
    "project_priority", "release_blocker", "reopened_conclusion", "revert_history",
    "runtime_without_test_change", "stale_audit", "user_impact", "variant_match",
}

def open_regular_read(path):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(path, flags)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError("not a regular file")
    return fd

def load_json(path):
    try:
        fd = open_regular_read(path)
        try:
            raw = os.read(fd, MAX_JSON_BYTES + 1)
        finally:
            os.close(fd)
        if len(raw) > MAX_JSON_BYTES:
            return {}
        value = json.loads(raw)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}

def load_jsonl_tail(path):
    try:
        fd = open_regular_read(path)
        try:
            size = os.fstat(fd).st_size
            offset = max(0, size - MAX_JSONL_BYTES)
            os.lseek(fd, offset, os.SEEK_SET)
            raw = bytearray()
            while len(raw) < MAX_JSONL_BYTES:
                chunk = os.read(fd, min(64 * 1024, MAX_JSONL_BYTES - len(raw)))
                if not chunk:
                    break
                raw.extend(chunk)
            raw = bytes(raw)
        finally:
            os.close(fd)
    except OSError:
        return []
    if offset:
        split = raw.find(b"\n")
        raw = b"" if split < 0 else raw[split + 1:]
    if raw and not raw.endswith(b"\n"):
        split = raw.rfind(b"\n")
        raw = b"" if split < 0 else raw[:split + 1]
    values = []
    for line in raw.splitlines()[-MAX_EVENTS:]:
        if not line or len(line) > MAX_JSONL_LINE:
            continue
        try:
            value = json.loads(line)
        except (UnicodeDecodeError, ValueError):
            continue
        if isinstance(value, dict):
            values.append(value)
    return values

def safe_token(value, default=""):
    candidate = str(value or "")
    return candidate if SAFE_TOKEN.fullmatch(candidate) else default

def bounded_int(value, default=0, low=0, high=100):
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = default
    return max(low, min(high, parsed))

def priority_reason_codes(value):
    if not isinstance(value, list):
        return []
    return sorted(
        {
            code
            for item in value[:20]
            if (code := safe_token(item)) in ALLOWED_PRIORITY_REASONS
        }
    )

# bugsweep-p74: append one full JSON line per record via a dedicated
# os.open(..., O_APPEND) + os.write() call each time, instead of batching many
# writes inside one `open(...).write()` block. A single write(2) syscall of a
# small buffer (well under PIPE_BUF) with O_APPEND is atomic on POSIX: the
# kernel seeks-to-end and writes in one step, so concurrent bugsweep processes
# appending to the SAME audit-log.jsonl / risk.jsonl can never interleave
# mid-line or tear a record, even without any external lock.
def append_line(path, obj):
    data = (json.dumps(obj) + "\n").encode("utf-8")
    if len(data) > MAX_JSONL_LINE:
        raise OSError("state record exceeds line cap")
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(path, flags, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("state output is not a regular file")
        if os.write(fd, data) != len(data):
            raise OSError("short state append")
    finally:
        os.close(fd)

events = load_jsonl_tail(ledger)

recon_value = load_json(recon)
batches = recon_value.get("batches", [])
if not isinstance(batches, list):
    batches = []
batch_files = {}
file_to_batch = {}
for batch in batches:
    if not isinstance(batch, dict) or "id" not in batch:
        continue
    batch_id = str(batch["id"])
    raw_files = batch.get("files", [])
    if not isinstance(raw_files, list) or not all(isinstance(path, str) for path in raw_files):
        continue
    batch_files[batch_id] = raw_files
    for path in raw_files:
        file_to_batch.setdefault(path, batch_id)

verified_records = []
repo_path = os.environ.get("BUGSWEEP_PERSIST_REPO", "")
script_dir = os.environ.get("BUGSWEEP_PERSIST_SCRIPT_DIR", "")
if repo_path and script_dir:
    try:
        sys.path.insert(0, script_dir)
        from _mark_batch_covered import verify_run_coverage
        verified_records = verify_run_coverage(Path(run_dir), Path(repo_path))
    except Exception:
        # Coverage is a cache optimization, so verification failure underreports
        # rather than blocking risk/outcome persistence or blessing forged state.
        verified_records = []

snapshot_by_key = {
    (str(item["batch"]), str(item["file"])): (str(item["head"]), str(item["blob_oid"]))
    for item in verified_records
}
verified_covered_ids = {str(item["batch"]) for item in verified_records}

audited_files = set()
for batch_id in sorted(verified_covered_ids):
    for path in sorted(set(batch_files.get(batch_id, []))):
        snapshot = snapshot_by_key.get((batch_id, path))
        if snapshot is None:
            continue
        head, blob_oid = snapshot
        append_line(audit_log, {
            "run": ordinal, "run_id": run_id, "ts": ts,
            "catalog_version": cat_v, "file": path, "outcome": "audited",
            "head": head, "blob_oid": blob_oid,
        })
        audited_files.add(path)

RISK = {"fix_committed", "quarantine", "confirmed", "false_positive"}
for e in events:
    ev = e.get("event")
    if ev in RISK and e.get("file"):
        record = {"run": ordinal, "run_id": run_id, "ts": ts,
                  "file": e["file"], "event": ev,
                  "severity": safe_token(e.get("severity"))}
        for key in ("category", "pattern_key", "finding_fingerprint"):
            value = safe_token(e.get(key))
            if value:
                record[key] = value
        cited_reasons = priority_reason_codes(e.get("priority_reason_codes"))
        if cited_reasons:
            record["priority_reason_codes"] = cited_reasons
        append_line(risk_log, record)

# Learning is observability-only: join why-now reasons to actual investigation
# outcomes, but never mutate weights or confirmation/fix gates automatically.
context = load_json(priority_context)
targets = context.get("targets", [])
if not isinstance(targets, list):
    targets = []
events_by_file = {}
for event in events:
    path = event.get("file")
    if isinstance(path, str):
        events_by_file.setdefault(path, []).append(event)

for target in targets[:200]:
    if not isinstance(target, dict) or not isinstance(target.get("file"), str):
        continue
    path = target["file"]
    batch_id = file_to_batch.get(path)
    if batch_id is None:
        continue
    file_events = events_by_file.get(path, [])
    event_names = {event.get("event") for event in file_events}
    confirmed_codes = {
        code
        for event in file_events
        if event.get("event") in {"fix_committed", "quarantine", "confirmed"}
        for code in priority_reason_codes(event.get("priority_reason_codes"))
    }
    rejected_codes = {
        code
        for event in file_events
        if event.get("event") == "false_positive"
        for code in priority_reason_codes(event.get("priority_reason_codes"))
    }
    has_finding_outcome = bool(
        event_names & {"fix_committed", "quarantine", "confirmed", "false_positive"}
    )
    investigated = (
        batch_id in verified_covered_ids and (batch_id, path) in snapshot_by_key
    ) or bool(confirmed_codes or rejected_codes)
    severities = [safe_token(event.get("severity")) for event in file_events]
    severity = next((value for value in severities if value), "")
    reasons = target.get("reasons", [])
    if not isinstance(reasons, list):
        reasons = []
    source_by_code = {
        safe_token(reason.get("code")): safe_token(reason.get("source"))
        for reason in reasons[:8]
        if isinstance(reason, dict)
    }
    attribution_codes = priority_reason_codes(target.get("attribution_reason_codes"))
    for code in attribution_codes:
        source = source_by_code.get(code, "")
        if code in confirmed_codes:
            outcome = "confirmed"
        elif code in rejected_codes:
            outcome = "rejected"
        elif investigated and has_finding_outcome:
            outcome = "unattributed"
        elif investigated:
            outcome = "no_finding"
        else:
            outcome = "not_reviewed"
        fix_result = "none"
        if outcome == "confirmed" and "fix_committed" in event_names:
            fix_result = "committed"
        elif outcome == "confirmed" and "quarantine" in event_names:
            fix_result = "quarantined"
        append_line(priority_outcome_log, {
            "run": ordinal,
            "run_id": run_id,
            "ts": ts,
            "file": path,
            "batch": batch_id,
            "reason": code,
            "source": source,
            "lane": safe_token(target.get("lane"), "normal"),
            "initial_score": bounded_int(target.get("priority_score")),
            "investigated": investigated,
            "outcome": outcome,
            "severity": severity,
            "fix_result": fix_result,
        })

print("AUDITED_FILES=%d" % len(audited_files))
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
  if { [ -e "$RISK_LOG" ] || [ -L "$RISK_LOG" ]; } \
    && { [ -L "$RISK_LOG" ] || [ ! -f "$RISK_LOG" ]; }; then
    log "state: refusing degraded risk persistence through a non-regular state file."
    return 0
  fi
  if [ -f "$ledger" ] && [ ! -L "$ledger" ]; then
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
_write_degraded_coverage() {
  local run_dir="$1" out_path="$2" payload="$3" temp_out
  temp_out="$(mktemp "${run_dir}/.prior-coverage.XXXXXX" 2>/dev/null || true)"
  [ -n "$temp_out" ] || return 1
  printf '%s\n' "$payload" > "$temp_out" || {
    rm -f -- "$temp_out"
    return 1
  }
  mv -f -- "$temp_out" "$out_path"
}

prime() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: state.sh prime <RUN_DIR>"
  run_dir="$(cd "$run_dir" && pwd)"
  local out_path="${run_dir}/prior-coverage.json"
  if ! _state_storage_safe; then
    _write_degraded_coverage "$run_dir" "$out_path" \
      '{"schema":1,"catalog_version":"0","prior_runs":0,"files_audited_current_catalog":[],"files_audited_current_catalog_count":0,"files_audited_stale_catalog":[],"files_audited_stale_catalog_count":0,"high_risk_files":[],"degraded":true}' \
      || true
    echo "SUMMARY=coverage history unavailable (unsafe state path) — whole-repo scope, no reprioritization applied."
    return 0
  fi

  local cat_v decay top_n recheck
  cat_v="$(catalog_version)"
  decay="$(cfg_get '.context.decay_factor' '0.85')"
  top_n="$(cfg_get '.context.high_risk_top_n' '25')"
  recheck="$(cfg_get '.context.recheck_audited_after_runs' '5')"

  # bugsweep-t6e: bounded git-history risk signal (commit frequency, recency,
  # fix-commit density from scripts/git-history-risk.sh), folded into the risk
  # score below with a hard-capped weight (HISTORY_MAX_WEIGHT in the python
  # fold) so it can only break ties among files with equal existing signal or
  # nudge close scores -- it can never let churn alone outrank a file with a
  # genuine confirmed/quarantine/fix_committed finding (see HISTORY_MAX_WEIGHT's
  # comment for the bound proof). Best-effort: any failure here (no git repo,
  # no python3, helper missing) just yields zero history signal, never a
  # failed prime() -- matches this file's coverage-first "never fail" contract.
  local history_log_path=""
  if have_python && [ -f "${BUGSWEEP_SCRIPT_DIR}/git-history-risk.sh" ]; then
    history_log_path="$(mktemp "${run_dir}/.state-history.XXXXXX" 2>/dev/null || true)"
    if [ -n "$history_log_path" ]; then
      ( bash "${BUGSWEEP_SCRIPT_DIR}/git-history-risk.sh" \
          "${BUGSWEEP_REPO_ROOT:-$run_dir}" 2>/dev/null || true ) \
        | dd of="$history_log_path" bs=65536 count=32 2>/dev/null || true
    fi
  fi

  if have_python; then
    local prior_runs
    prior_runs="$(_state_meta_runs)"
    if AUDIT_LOG="$AUDIT_LOG" RISK_LOG="$RISK_LOG" PRIOR_RUNS="$prior_runs" HISTORY_LOG_PATH="$history_log_path" \
      python3 - "$cat_v" "$decay" "$top_n" "$recheck" "$out_path" <<'PY' 2>/dev/null
import json, os, stat, sys, tempfile
cat_v, decay, top_n, recheck, out_path = sys.argv[1:6]
decay = float(decay); top_n = int(top_n); recheck = int(recheck)
audit_log, risk_log = os.environ["AUDIT_LOG"], os.environ["RISK_LOG"]
history_log_path = os.environ.get("HISTORY_LOG_PATH", "")

def jsonl_tail(path, max_bytes=32 * 1024 * 1024, max_line=64 * 1024):
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        fd = os.open(path, flags)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                return []
            offset = max(0, info.st_size - max_bytes)
            os.lseek(fd, offset, os.SEEK_SET)
            raw = bytearray()
            while len(raw) < max_bytes:
                chunk = os.read(fd, min(64 * 1024, max_bytes - len(raw)))
                if not chunk:
                    break
                raw.extend(chunk)
            raw = bytes(raw)
        finally:
            os.close(fd)
    except OSError:
        return []
    if offset:
        split = raw.find(b"\n")
        raw = b"" if split < 0 else raw[split + 1:]
    if raw and not raw.endswith(b"\n"):
        split = raw.rfind(b"\n")
        raw = b"" if split < 0 else raw[:split + 1]
    values = []
    for line in raw.splitlines():
        if not line or len(line) > max_line:
            continue
        try:
            value = json.loads(line)
        except (UnicodeDecodeError, ValueError):
            continue
        if isinstance(value, dict):
            values.append(value)
    return values

runs = max(0, int(os.environ.get("PRIOR_RUNS", "0")))
current = runs + 1

def vkey(v):
    try:
        return (1, [int(x) for x in str(v).split(".")])
    except Exception:
        return (0, str(v))

# file -> (best catalog_version, last run audited)
best = {}
for e in jsonl_tail(audit_log):
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
event_score = {}
for e in jsonl_tail(risk_log):
    f = e.get("file")
    if not f:
        continue
    w = WEIGHTS.get(e.get("event"), 0)
    age = max(0, current - int(e.get("run", current)))
    event_score[f] = event_score.get(f, 0.0) + w * (decay ** age)

# bugsweep-t6e: bounded fold of the git-history signal (scripts/git-history-risk.sh).
# HISTORY_MAX_WEIGHT (0.5) is deliberately smaller than the smallest gap between
# any two WEIGHTS tiers above (fix_committed=3, quarantine=2, confirmed=1,
# false_positive=-1 -> every adjacent gap is >= 1). That means a maxed-out
# history contribution (history_score == 1.0 -> +0.5) can NEVER let a file
# overtake another file whose existing score is even one weight-tier higher at
# the same decay age -- history can only break ties among files with EQUAL
# existing signal (including two files with none at all) or nudge scores
# within the same tier. The existing sink/coverage-derived signal always wins
# a genuine gap; history only reprioritizes among otherwise-equal files.
HISTORY_MAX_WEIGHT = 0.5
history_score = {}
for e in jsonl_tail(history_log_path, max_bytes=2 * 1024 * 1024) if history_log_path else []:
    f = e.get("file")
    if not f:
        continue
    try:
        h = float(e.get("history_score", 0.0))
    except (TypeError, ValueError):
        continue
    # Defensive re-clamp: git-history-risk.sh already bounds history_score to
    # [0, 1], but a hand-edited or corrupted line must never be able to smuggle
    # an out-of-range value past the bound this fold exists to guarantee.
    h = max(0.0, min(1.0, h))
    history_score[f] = history_score.get(f, 0.0) + HISTORY_MAX_WEIGHT * h

combined = {
    f: event_score.get(f, 0.0) + history_score.get(f, 0.0)
    for f in set(event_score) | set(history_score)
}
high = sorted(
    (
        f,
        round(max(0.0, total), 3),
        round(event_score.get(f, 0.0), 3),
        round(history_score.get(f, 0.0), 3),
    )
    for f, total in combined.items()
    if total > 0
)
high.sort(key=lambda item: (-item[1], item[0]))
high = high[:top_n]

CAP = 200
out = {
    "schema": 1,
    "catalog_version": cur,
    "prior_runs": runs,
    "files_audited_current_catalog": audited_current[:CAP],
    "files_audited_current_catalog_count": len(audited_current),
    "files_audited_stale_catalog": audited_stale[:CAP],
    "files_audited_stale_catalog_count": len(audited_stale),
    "high_risk_files": [
        {"file": f, "score": score, "event_score": events, "history_score": history}
        for f, score, events, history in high
    ],
    "truncated": len(audited_current) > CAP or len(audited_stale) > CAP,
}
temp_name = ""
try:
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", prefix=".prior-coverage.",
        dir=os.path.dirname(out_path), delete=False,
    ) as handle:
        temp_name = handle.name
        os.fchmod(handle.fileno(), 0o600)
        json.dump(out, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_name, out_path)
    temp_name = ""
finally:
    if temp_name:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass

if runs == 0:
    print("SUMMARY=first run on this repo — entire codebase is the unaudited frontier; whole-repo scope.")
else:
    print("SUMMARY=prior_runs=%d audited@v%s=%d stale=%d high_risk=%d"
          % (runs, cur, len(audited_current), len(audited_stale), len(high)))
PY
    then
      [ -z "$history_log_path" ] || rm -f -- "$history_log_path"
      return 0
    fi
  fi
  [ -z "$history_log_path" ] || rm -f -- "$history_log_path"

  # Degraded path: no python3 or no state yet. Emit an empty-history file so
  # context-build treats the WHOLE repo as the frontier (safe: never narrows).
  local runs; runs="$(_state_meta_runs)"
  _write_degraded_coverage "$run_dir" "$out_path" \
    "{\"schema\":1,\"catalog_version\":\"${cat_v}\",\"prior_runs\":${runs},\"files_audited_current_catalog\":[],\"files_audited_current_catalog_count\":0,\"files_audited_stale_catalog\":[],\"files_audited_stale_catalog_count\":0,\"high_risk_files\":[],\"degraded\":true}" \
    || true
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
  _state_storage_safe || { log "state: no safe project-scoped state dir; skipping lease."; return 0; }
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
  _state_storage_safe || return 0
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
  _state_storage_safe || return 0
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
  _state_storage_safe || return 0
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
