#!/usr/bin/env bash
# bugsweep justification ledger / assumption invalidation (WU2).
#
# Persists "safe because" conclusions and re-opens them the moment the ground they stand on
# moves. The original (rejected) design keyed a verdict only to its NAMED premises, so a NEW
# path to the same sink — which changes none of those hashes — let the verdict auto-renew and
# the file drop off the frontier: "we didn't look" silently became "we proved it safe." For a
# security tool that is worse than no ledger. This v2 fixes it with two hard rules:
#
#   1. A "safe" conclusion may only DEPRIORITIZE its file WITHIN the critical tier (ordered after
#      uncleared peers). It may NEVER remove a file from scope — sink-bearing files stay in the
#      critical tier unconditionally (Phase-1 rule); `cleared` is a sort hint, not a gate.
#   2. It is invalidated (re-opened, file rejoins the frontier) by ANY of:
#        - a premise symbol's body hash changed or vanished        (WU0 symbols.sh)
#        - the sink's reachable-path set changed                   (WU3 path_hash — a NEW path)
#        - a cited sanitizer's declared `neutralizes` set changed   (WU3 sanitizers.jsonl)
#        - the anti-pattern catalog advanced past the relied-on ver (per-class version map)
#        - ANY required input is missing/unreadable                (fail CLOSED = reopen/widen)
#      Missing data NEVER means "still safe" — it means "look again".
#
#   conclusions.sh add <sink_symbol> <class> <claim> [premise_sym ...] [--sanitizer sym ...]
#   conclusions.sh prime <RUN_DIR>     re-evaluate; write reopened-conclusions.txt + fold a
#                                      `cleared` flag into <RUN_DIR>/exposure.json (re-sorted)
#   conclusions.sh retire <id>         mark a conclusion inactive (model revised / human marked)
#   conclusions.sh stats
#
# Notes: `claim` is repo-derived DATA — capped at 256 chars, stored escaped, and NEVER fed into
# a prompt in v1 (the frontier signal is a file list, not the claim text), so it cannot carry an
# injection. catalog_versions is a per-class MAP: a conclusion stores the catalog version of the
# detector class it relied on, and re-opens only when THAT class advances (references/antipatterns/
# versions.json; legacy single-integer VERSION is the fallback). Degrades, never fails a run.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

REPO_ROOT="$BUGSWEEP_REPO_ROOT"
STATE_DIR="$BUGSWEEP_STATE_DIR"
LEDGER="${STATE_DIR}/conclusions.jsonl"
SYMS="${STATE_DIR}/symbol-index.jsonl"
REACH="${STATE_DIR}/sink-reachability.jsonl"
SANITIZERS="${STATE_DIR}/sanitizers.jsonl"
CLAIM_MAX=256
# catalog versioning helpers (catalog_class_version / catalog_aggregate_version /
# catalog_versions_json) come from common.sh.

# ---------------------------------------------------------------------------
add() {
  local sink="${1:-}" cls="${2:-}" claim="${3:-}"
  [ -n "$sink" ] && [ -n "$cls" ] && [ -n "$claim" ] \
    || die "usage: conclusions.sh add <sink_symbol> <class> <claim> [premise_sym ...] [--sanitizer sym ...]"
  shift 3 || true
  local premises="" sanitizers=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sanitizer) [ -n "${2:-}" ] && sanitizers="${sanitizers}${2}
"; shift 2 || shift ;;
      --premise)   [ -n "${2:-}" ] && premises="${premises}${2}
"; shift 2 || shift ;;
      *)           premises="${premises}${1}
"; shift ;;
    esac
  done

  mkdir -p "$STATE_DIR" 2>/dev/null || { log "conclusions: cannot create ${STATE_DIR}; skipping add."; return 0; }
  have_python || { log "conclusions: python3 required for add; skipped."; return 0; }

  LEDGER="$LEDGER" SYMS="$SYMS" REACH="$REACH" SANITIZERS="$SANITIZERS" \
  PREMISES="$premises" SANITIZER_SYMS="$sanitizers" CATV="$(catalog_class_version "$cls")" CLAIM_MAX="$CLAIM_MAX" \
  python3 - "$sink" "$cls" "$claim" <<'PY' 2>/dev/null || { log "conclusions: add failed (non-fatal)."; return 0; }
import json, os, sys, hashlib
sink, cls, claim = sys.argv[1], sys.argv[2], sys.argv[3]
ledger = os.environ["LEDGER"]; syms = os.environ["SYMS"]; reach = os.environ["REACH"]
san_p = os.environ["SANITIZERS"]; catv = os.environ["CATV"] or "0"
claim_max = int(os.environ["CLAIM_MAX"])
premises = [x for x in os.environ.get("PREMISES", "").splitlines() if x.strip()]
san_syms = [x for x in os.environ.get("SANITIZER_SYMS", "").splitlines() if x.strip()]

def load_jsonl(p):
    out = []
    if os.path.exists(p):
        for ln in open(p):
            ln = ln.strip()
            if not ln: continue
            try: out.append(json.loads(ln))
            except Exception: pass
    return out

# symbol_id -> body/file hash (WU0)
sym_hash = {e.get("symbol_id"): e.get("hash") for e in load_jsonl(syms) if e.get("symbol_id")}
# sink_symbol -> path_hash (WU3). Absent -> None (stored as null -> always reopens = widen).
sink_ph = {}
for r in load_jsonl(reach):
    if r.get("sink"): sink_ph[r["sink"]] = r.get("path_hash")
# sanitizer symbol -> neutralizes_hash (sha256 of sorted classes)
san_neu = {}
for s in load_jsonl(san_p):
    sid = s.get("symbol_id")
    if sid:
        classes = sorted(s.get("neutralizes", []) or [])
        san_neu[sid] = hashlib.sha256("\n".join(classes).encode("utf-8", "replace")).hexdigest()[:12]

prior = load_jsonl(ledger)
maxid = 0
for e in prior:
    cid = str(e.get("id", ""))
    if cid.startswith("C-"):
        try: maxid = max(maxid, int(cid[2:]))
        except Exception: pass

rec = {
    "id": "C-%d" % (maxid + 1),
    "active": True,
    "sink": sink,
    "class": cls,
    "claim": claim[:claim_max],
    "sink_hash": sym_hash.get(sink),                     # the sink's OWN body is an implicit premise:
                                                         # editing the function that holds the sink
                                                         # (e.g. a bypass) must reopen its own verdict
    "path_hash": sink_ph.get(sink),                      # None if WU3 hasn't run -> always reopen
    "premises": [{"symbol_id": p, "hash": sym_hash.get(p)} for p in premises],
    # a cited sanitizer reopens the conclusion if EITHER its declared neutralizes-set changes
    # (neutralizes_hash) OR its implementation changes (body_hash from WU0) — a weakened escape
    # must invalidate the "safe" verdict that relied on it.
    "sanitizer_symbols": [{"symbol_id": s, "neutralizes_hash": san_neu.get(s),
                           "body_hash": sym_hash.get(s)} for s in san_syms],
    "catalog_versions": {cls: catv},                     # the cited class's catalog version (per-class)
    "run": 0,
}
tmp = ledger + ".tmp"
lines = [json.dumps(e) for e in prior] + [json.dumps(rec)]
open(tmp, "w").write("\n".join(lines) + "\n")
os.replace(tmp, ledger)
print("ADDED=%s" % rec["id"])
PY
}

# ---------------------------------------------------------------------------
prime() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: conclusions.sh prime <RUN_DIR>"
  run_dir="$(cd "$run_dir" && pwd)"
  local reopened="${run_dir}/reopened-conclusions.txt"
  : > "$reopened"

  # No ledger or no python -> nothing to evaluate. (Empty reopened list; exposure untouched.)
  [ -f "$LEDGER" ] || { echo "SUMMARY=no conclusions ledger — nothing to invalidate."; return 0; }
  have_python || { log "conclusions: python3 unavailable — cannot evaluate ledger; leaving exposure as-is."; \
    echo "SUMMARY=python3 unavailable — conclusion invalidation skipped."; return 0; }

  LEDGER="$LEDGER" SYMS="$SYMS" REACH="$REACH" SANITIZERS="$SANITIZERS" \
  EXPOSURE="${run_dir}/exposure.json" REOPENED="$reopened" \
  CATVMAP="$(catalog_versions_json)" CATV_FALLBACK="$(_catalog_legacy)" \
  python3 - <<'PY' 2>/dev/null || { log "conclusions: prime failed; treating all conclusions as reopened (widen)."; \
    _prime_failclosed "$run_dir" "$reopened"; return 0; }
import json, os, hashlib
ledger = os.environ["LEDGER"]; syms = os.environ["SYMS"]; reach = os.environ["REACH"]
san_p = os.environ["SANITIZERS"]; exposure = os.environ["EXPOSURE"]; reopened = os.environ["REOPENED"]
# per-class catalog versions (versions.json). When the map is unreadable, fall back to the
# single legacy VERSION for every class (mirrors how `add` resolved catalog_class_version).
try:
    _cat_map = json.loads(os.environ.get("CATVMAP", "") or "null")
    if not isinstance(_cat_map, dict): _cat_map = None
except Exception:
    _cat_map = None
_cat_fallback = os.environ.get("CATV_FALLBACK", "0") or "0"

def load_jsonl(p):
    out = []
    if os.path.exists(p):
        for ln in open(p):
            ln = ln.strip()
            if not ln: continue
            try: out.append(json.loads(ln))
            except Exception: pass
    return out

def vnum(v):
    try: return [int(x) for x in str(v).split(".")]
    except Exception: return [0]

def current_class_version(cls):
    # map present -> that class's version (absent class = 0); map absent -> legacy VERSION.
    # A non-integer class value falls back to legacy, matching how `add`'s catalog_class_version
    # coerces it — so the two halves never disagree under a corrupted versions.json.
    if _cat_map is not None:
        v = _cat_map.get(cls, 0)
        try:
            int(str(v))
            return v
        except Exception:
            return _cat_fallback
    return _cat_fallback

sym_hash = {e.get("symbol_id"): e.get("hash") for e in load_jsonl(syms) if e.get("symbol_id")}
sink_ph = {}
have_reach = os.path.exists(reach)
for r in load_jsonl(reach):
    if r.get("sink"): sink_ph[r["sink"]] = r.get("path_hash")
san_neu = {}
for s in load_jsonl(san_p):
    sid = s.get("symbol_id")
    if sid:
        classes = sorted(s.get("neutralizes", []) or [])
        san_neu[sid] = hashlib.sha256("\n".join(classes).encode("utf-8", "replace")).hexdigest()[:12]

def file_of(sid):
    return sid.split(":", 1)[0] if ":" in sid else sid

conclusions = load_jsonl(ledger)

def is_valid(c):
    # Returns True only if EVERY check passes. Any missing input -> False (reopen/widen).
    if not c.get("active", True):
        return False  # retired -> treated as not-cleared (no effect, never validates)
    sink = c.get("sink")
    # WU3 path_hash: missing reach file, sink absent, stored null, or changed -> reopen.
    if not have_reach:
        return False
    if sink not in sink_ph:
        return False
    stored_ph = c.get("path_hash")
    if stored_ph is None or sink_ph[sink] is None or sink_ph[sink] != stored_ph:
        return False
    # the sink's own body is an implicit premise: a bypass edited INTO the sink function
    # leaves path_hash (component structure) unchanged, so check the body hash directly.
    stored_sh = c.get("sink_hash"); cur_sh = sym_hash.get(sink)
    if stored_sh is None or cur_sh is None or cur_sh != stored_sh:
        return False
    # premises: any changed or unknown -> reopen. A stored null also reopens (was unknown at add).
    for pr in c.get("premises", []):
        sid = pr.get("symbol_id"); stored = pr.get("hash")
        cur = sym_hash.get(sid)
        if stored is None or cur is None or cur != stored:
            return False
    # cited sanitizers: declared neutralizes-set OR implementation body changed/vanished -> reopen.
    for sa in c.get("sanitizer_symbols", []):
        sid = sa.get("symbol_id")
        stored_neu = sa.get("neutralizes_hash"); cur_neu = san_neu.get(sid)
        if stored_neu is None or cur_neu is None or cur_neu != stored_neu:
            return False
        stored_body = sa.get("body_hash"); cur_body = sym_hash.get(sid)
        if stored_body is None or cur_body is None or cur_body != stored_body:
            return False
    # catalog: reopen if the live version of a RELIED-ON class advanced past the stored one.
    # Per-class, so bumping (say) the sql catalog re-opens only sql-relying conclusions.
    for cls_name, stored_v in (c.get("catalog_versions") or {}).items():
        if vnum(current_class_version(cls_name)) > vnum(stored_v):
            return False
    return True

reopen_files = set()
cleared_files = set()
for c in conclusions:
    if not c.get("active", True):
        continue
    valid = is_valid(c)
    files = {file_of(c.get("sink", ""))}
    for pr in c.get("premises", []):
        files.add(file_of(pr.get("symbol_id", "")))
    for sa in c.get("sanitizer_symbols", []):
        files.add(file_of(sa.get("symbol_id", "")))
    files.discard("")
    if valid:
        cleared_files.add(file_of(c.get("sink", "")))
    else:
        reopen_files |= files

# A file with ANY reopened conclusion is NOT cleared (reopen dominates).
cleared_files -= reopen_files

with open(reopened, "w") as f:
    for p in sorted(reopen_files):
        f.write(p + "\n")

# Fold `cleared` into exposure.json and re-sort: (bucket desc, uncleared-before-cleared,
# weight desc, file). This NEVER removes a file — cleared only orders it after uncleared peers.
ranked = 0
if os.path.exists(exposure):
    try:
        data = json.load(open(exposure))
    except Exception:
        data = None
    if isinstance(data, dict) and isinstance(data.get("files"), list):
        RANK = {"LIVE": 2, "MAYBE": 1, "COLD": 0}
        for fe in data["files"]:
            fe["cleared"] = bool(fe.get("file") in cleared_files)
        data["files"].sort(key=lambda fe: (-RANK.get(fe.get("bucket"), 0),
                                            1 if fe.get("cleared") else 0,
                                            -(fe.get("weight") or 0),
                                            fe.get("file") or ""))
        tmp = exposure + ".tmp"
        json.dump(data, open(tmp, "w"), indent=2)
        os.replace(tmp, exposure)
        ranked = sum(1 for fe in data["files"] if fe.get("cleared"))

print("SUMMARY=conclusions=%d reopened_files=%d cleared_files=%d"
      % (len(conclusions), len(reopen_files), len(cleared_files)))
PY
}

# Fail-closed fallback: if the python evaluator errors, re-queue EVERY active conclusion's files
# (sink + premises + cited sanitizers) so nothing a broken evaluator touched is treated as still
# safe. python3 is guaranteed here — prime returns early if it is absent — so we parse the ledger
# as JSON rather than regex (the records are json.dumps output: "sink": "x", WITH a space, which a
# no-space grep silently misses — that miss would re-queue nothing and resurrect the exact stale-
# safe bug this fallback exists to prevent).
_prime_failclosed() {
  local run_dir="$1" reopened="$2"
  : > "$reopened"
  [ -f "$LEDGER" ] || { echo "SUMMARY=conclusion evaluator failed — no ledger to re-queue."; return 0; }
  local n
  n="$(LEDGER="$LEDGER" REOPENED="$reopened" python3 - <<'PY' 2>/dev/null || true
import json, os
ledger = os.environ["LEDGER"]; reopened = os.environ["REOPENED"]
def file_of(sid):
    return sid.split(":", 1)[0] if ":" in sid else sid
files = set()
for ln in open(ledger):
    ln = ln.strip()
    if not ln: continue
    try: e = json.loads(ln)
    except Exception: continue
    if not e.get("active", True): continue
    if e.get("sink"): files.add(file_of(e["sink"]))
    for pr in e.get("premises", []):
        if pr.get("symbol_id"): files.add(file_of(pr["symbol_id"]))
    for sa in e.get("sanitizer_symbols", []):
        if sa.get("symbol_id"): files.add(file_of(sa["symbol_id"]))
files.discard("")
with open(reopened, "w") as f:
    for p in sorted(files):
        f.write(p + "\n")
print(len(files))
PY
)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "SUMMARY=conclusion evaluator failed — re-queued ${n} conclusion file(s) (fail-closed widen)."
}

# ---------------------------------------------------------------------------
retire() {
  local id="${1:-}"
  [ -n "$id" ] || die "usage: conclusions.sh retire <id>"
  [ -f "$LEDGER" ] || die "retire: no conclusions ledger."
  have_python || die "retire: requires python3."
  LEDGER="$LEDGER" python3 - "$id" <<'PY' 2>/dev/null || die "retire: failed."
import json, os, sys
ledger = os.environ["LEDGER"]; cid = sys.argv[1]
out = []; found = False
for ln in open(ledger):
    ln = ln.strip()
    if not ln: continue
    try: e = json.loads(ln)
    except Exception: continue
    if e.get("id") == cid:
        e["active"] = False; e["retired"] = True; found = True
    out.append(json.dumps(e))
tmp = ledger + ".tmp"
open(tmp, "w").write("\n".join(out) + ("\n" if out else ""))
os.replace(tmp, ledger)
print("RETIRED" if found else "NOT_FOUND")
PY
}

stats() {
  echo "CONCLUSIONS=$(bugsweep_count_lines "$LEDGER") ACTIVE=$(bugsweep_grep_count '"active": ?true' "$LEDGER")"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  add)    add "$@" ;;
  prime)  prime "$@" ;;
  retire) retire "$@" ;;
  stats)  stats ;;
  *)      die "usage: conclusions.sh <add|prime|retire|stats> ..." ;;
esac
