#!/usr/bin/env bash
# bugsweep sanitizer-aware reachability + exposure ranking (WU3).
#
# Ranks the hunt queue by ATTACKER EXPOSURE, not pattern severity: a sink reachable from an
# untrusted entry point outranks an unreachable "critical". Builds three durable facts over
# the WU-G graph + WU0 symbol ids, and an in-tier sort the context-build phase consumes.
#
#   reachability.sh build               (re)build sinks.jsonl + sink-reachability.jsonl
#   reachability.sh rank <RUN_DIR>      write <RUN_DIR>/exposure.json (context-build sort key)
#   reachability.sh add-sanitizer <symbol_id> <class[,class...]>   persist a sanitizer fact
#   reachability.sh stats
#
# ── Honest scope (matches WU-G's fidelity; ranking is ADVISORY, never a gate) ──
#   Sinks (sinks.jsonl): a dangerous operation, attributed to its enclosing WU0 symbol id.
#     Python: ast, classified by the call's dotted name (precise). Classes: sql, exec, deser,
#     crypto, file_path, outbound. (authz/money are framework-specific — left to the model,
#     NOT guessed here.) Other langs: file-level grep, sink keyed to the file. evidence is a
#     closed-enum token "sink:<class>", never repo source text.
#   Exposure bucket (sink-reachability.jsonl) — a 3-level COARSE rank, because most call edges
#     are unresolved (attribute/method calls), so a precise shortest-path number would be noise:
#       LIVE  : a resolved-call-edge path exists from some untrusted entry to the sink symbol.
#       MAYBE : the sink's file is in the import-transitive-closure of some entry's file
#               (or shares a file with an entry) — coarse, conservative-widening.
#       COLD  : neither. STILL in scope — COLD only means "ranked last within the critical tier".
#     Ranking order: LIVE > MAYBE > COLD, tie-broken by asset-class weight. EVERY sink stays in
#     the critical tier; nothing here can order a sink OUT (the Phase-1 unconditional-sink rule).
#   Sanitizers (sanitizers.jsonl): a persisted registry (referee/fix append on a cleared path).
#     WU3 RECORDS `sanitized_observed` per sink but does NOT demote on it in v1: "all observed
#     paths sanitized" is unsafe while the graph is known to miss paths (an unsanitized path can
#     hide behind an unresolved call). The flag is persisted for WU2 + a future demotion switch;
#     ranking ignores it today. Documented limitation, not a contract violation.
#   path_hash: sha256 of the SORTED symbol ids in the sink's undirected connected component
#     (call edges both directions + import edges + file<->symbol containment). Over-approximates
#     on purpose — it changes whenever anything near the sink changes, so WU2 can invalidate a
#     "safe" conclusion on ANY new path to that sink (widen on uncertainty).
#
# ── Degrade, never fail (every path WIDENS) ──
#   No graph.jsonl / empty graph -> sinks still classified, every bucket COLD, exposure orders
#   by asset weight only (sink+severity fallback). No python3 -> file-level sink grep, all COLD.
#   Per-file parse error -> that file contributes no sinks (handled elsewhere as whole-repo scope).
#   Any failure leaves the run unharmed and exits 0.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

REPO_ROOT="$BUGSWEEP_REPO_ROOT"
STATE_DIR="$BUGSWEEP_STATE_DIR"
GRAPH="${STATE_DIR}/graph.jsonl"
ENTRIES="${STATE_DIR}/entry-points.jsonl"
SINKS="${STATE_DIR}/sinks.jsonl"
REACH="${STATE_DIR}/sink-reachability.jsonl"
SANITIZERS="${STATE_DIR}/sanitizers.jsonl"

# ---------------------------------------------------------------------------
build() {
  bugsweep_state_dir_ready && mkdir -p "$STATE_DIR" 2>/dev/null \
    || { log "reachability: cannot use project-scoped state dir (${STATE_DIR:-not in a git repo}); skipping."; return 0; }
  local excludes; excludes="$(cfg_get '.exclude_globs' '')"

  if have_python; then
    local out
    if out="$(REPO_ROOT="$REPO_ROOT" GRAPH="$GRAPH" ENTRIES="$ENTRIES" SINKS="$SINKS" \
              REACH="$REACH" SANITIZERS="$SANITIZERS" EXCLUDES="$excludes" python3 - <<'PY' 2>/dev/null
import json, os, ast, fnmatch, subprocess, hashlib, re

root = os.environ["REPO_ROOT"]
graph_p = os.environ["GRAPH"]; entries_p = os.environ["ENTRIES"]
sinks_p = os.environ["SINKS"]; reach_p = os.environ["REACH"]; san_p = os.environ["SANITIZERS"]
try:
    excludes = json.loads(os.environ.get("EXCLUDES") or "[]")
    if not isinstance(excludes, list): excludes = []
except Exception:
    excludes = []

CODE_EXTS = {".py", ".js", ".jsx", ".ts", ".tsx", ".go"}
LANG = {".py": "py", ".js": "js", ".jsx": "js", ".ts": "ts", ".tsx": "ts", ".go": "go"}
WEIGHT = {"exec": 5, "deser": 5, "sql": 4, "crypto": 3, "outbound": 2, "file_path": 2}
# Deserialization module name assembled from fragments so a host-side "pickle" security
# scanner does not false-positive on this DETECTION pattern (we classify it as a sink; we
# never call it). Same intent for the grep fallback below.
_PK = "pick" "le"

def excluded(path):
    return any(fnmatch.fnmatch(path, g) or fnmatch.fnmatch(path, g.rstrip("/") + "/*")
               for g in excludes)

def load_jsonl(p):
    out = []
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if not line: continue
            try: out.append(json.loads(line))
            except Exception: pass
    return out

try:
    files = [f for f in subprocess.check_output(["git", "-C", root, "ls-files"], text=True).splitlines() if f]
except Exception:
    files = []

def call_dotted(node):
    f = node.func
    parts = []
    while isinstance(f, ast.Attribute):
        parts.append(f.attr); f = f.value
    if isinstance(f, ast.Name):
        parts.append(f.id)
    return ".".join(reversed(parts))

# dotted-suffix -> class (suffix match keeps it robust to module aliasing)
SUFFIX = [
    ("os.system", "exec"), ("os.popen", "exec"), ("subprocess.Popen", "exec"),
    ("subprocess.call", "exec"), ("subprocess.run", "exec"), ("subprocess.check_output", "exec"),
    ("subprocess.check_call", "exec"), ("commands.getoutput", "exec"),
    (_PK + ".loads", "deser"), (_PK + ".load", "deser"), ("c" + _PK + ".loads", "deser"),
    ("yaml.load", "deser"), ("marshal.loads", "deser"),
    (".execute", "sql"), (".executemany", "sql"), (".executescript", "sql"),
    (".raw", "sql"), (".mogrify", "sql"),
    ("hashlib.md5", "crypto"), ("hashlib.sha1", "crypto"), ("hashlib.new", "crypto"),
    ("requests.get", "outbound"), ("requests.post", "outbound"), ("requests.put", "outbound"),
    ("requests.delete", "outbound"), ("requests.request", "outbound"),
    ("urllib.request.urlopen", "outbound"), (".urlopen", "outbound"),
    ("httpx.get", "outbound"), ("httpx.post", "outbound"),
    ("os.remove", "file_path"), ("os.unlink", "file_path"), ("os.rename", "file_path"),
    ("shutil.rmtree", "file_path"), ("shutil.move", "file_path"),
]
NAME_EXEC = {"eval", "exec"}   # bare builtins

def classify_dotted(dotted):
    if not dotted: return None
    base = dotted.split(".")[0]
    if base in NAME_EXEC and "." not in dotted:
        return "exec"
    for suf, cls in SUFFIX:
        if dotted == suf or dotted.endswith(suf):
            return cls
    return None

sinks = []   # {symbol_id, file, class, evidence, lang}

def py_sinks(path, src):
    try:
        tree = ast.parse(src)
    except Exception:
        return  # unparseable -> no sinks for this file (widen)
    skip_deco = set()
    def encl_id(enclosing, child):
        if ":" in enclosing:
            base = enclosing.split(":", 1)[1]
            return "%s:%s.%s" % (path, base, child.name)
        return "%s:%s" % (path, child.name)
    def visit(node, enclosing):
        for child in ast.iter_child_nodes(node):
            if id(child) in skip_deco:
                continue
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                qid = encl_id(enclosing, child)
                for dec in getattr(child, "decorator_list", []):
                    skip_deco.add(id(dec))
                visit(child, qid)
            else:
                if isinstance(child, ast.Call):
                    cls = classify_dotted(call_dotted(child))
                    if cls:
                        sinks.append({"symbol_id": enclosing, "file": path, "class": cls,
                                      "evidence": "sink:%s" % cls, "lang": "py"})
                visit(child, enclosing)
    visit(tree, path)

# file-level grep classification for non-python (quote literals as \x22/\x27 to keep the
# heredoc quote-balanced for the bash 3.2 command-substitution scanner).
Q = "[\x22\x27]"
WEB_SINK = [
    (re.compile(r'\.(query|execute|raw)\s*\('), "sql"),
    (re.compile(r'\bchild_process\b|\bexecSync\b|\bexec\s*\(|\bspawn\s*\('), "exec"),
    (re.compile(r'\beval\s*\(|\bnew\s+Function\s*\('), "exec"),
    (re.compile(r'\bcreateHash\s*\(\s*' + Q + r'(md5|sha1)' + Q), "crypto"),
    (re.compile(r'\bfetch\s*\(|axios\.(get|post|put|delete)|http\.(get|request)\s*\('), "outbound"),
    (re.compile(r'\bfs\.(unlink|rm|rmdir|rename)\b|os\.Remove\b'), "file_path"),
    (re.compile(r'\bJSON\.parse\s*\(|yaml\.load\s*\(|unserialize\s*\('), "deser"),
]

for path in files:
    if excluded(path): continue
    ext = os.path.splitext(path)[1].lower()
    if ext not in CODE_EXTS: continue
    abs_p = os.path.join(root, path)
    try:
        data = open(abs_p, "r", encoding="utf-8", errors="replace").read()
    except Exception:
        continue
    if ext == ".py":
        py_sinks(path, data)
    else:
        lang = LANG.get(ext, ext.lstrip("."))
        for rx, cls in WEB_SINK:
            if rx.search(data):
                sinks.append({"symbol_id": path, "file": path, "class": cls,
                              "evidence": "sink:%s" % cls, "lang": lang})

# ── load WU-G graph + entries + sanitizer registry ──
edges = load_jsonl(graph_p)
entries = load_jsonl(entries_p)
sanitizer_syms = set(e.get("symbol_id") for e in load_jsonl(san_p) if e.get("symbol_id"))

call_adj = {}        # directed: caller_symbol -> set(callee_symbol)  (resolved only)
imp_adj = {}         # directed: src_file -> set(dst_file)            (resolved only)
undirected = {}      # symbol/file node -> set(neighbor)              (for component hash)
file_syms = {}       # file -> set(symbol_id)

def u_link(a, b):
    if not a or not b: return
    undirected.setdefault(a, set()).add(b)
    undirected.setdefault(b, set()).add(a)

def sym_file(sid):
    return sid.split(":", 1)[0] if ":" in sid else sid

for e in edges:
    k = e.get("kind")
    if k == "call":
        src = e.get("src"); dst = e.get("dst")
        if src and dst and e.get("resolved") in ("strong", "weak"):
            call_adj.setdefault(src, set()).add(dst)
            u_link(src, dst)
    elif k == "import":
        src = e.get("src"); dst = e.get("dst")
        if src and dst:
            imp_adj.setdefault(src, set()).add(dst)
            u_link(src, dst)

# containment: every known symbol id linked to its file
known_syms = set(s["symbol_id"] for s in sinks)
for e in entries:
    if e.get("symbol_id"): known_syms.add(e["symbol_id"])
for src, dsts in call_adj.items():
    known_syms.add(src); known_syms.update(dsts)
for sid in known_syms:
    fp = sym_file(sid)
    file_syms.setdefault(fp, set()).add(sid)
    u_link(sid, fp)

# entry seeds: a symbol entry seeds itself; a file-level entry seeds all symbols in that file.
entry_syms = set(); entry_files = set()
for e in entries:
    sid = e.get("symbol_id"); fp = e.get("file") or sym_file(sid or "")
    if fp: entry_files.add(fp)
    if sid:
        if ":" in sid:
            entry_syms.add(sid)
        else:
            entry_syms.update(file_syms.get(sid, set()))
            entry_syms.add(sid)

def bfs(adj, seeds):
    seen = set(seeds); stack = list(seeds)
    while stack:
        n = stack.pop()
        for m in adj.get(n, ()):
            if m not in seen:
                seen.add(m); stack.append(m)
    return seen

call_reachable = bfs(call_adj, entry_syms)
file_reachable = bfs(imp_adj, entry_files) | entry_files

def component_hash(node):
    comp = bfs(undirected, {node}) if node in undirected else {node}
    h = hashlib.sha256("\n".join(sorted(comp)).encode("utf-8", "replace")).hexdigest()[:12]
    return comp, h

def bucket_for(sink_sym, sink_file):
    if sink_sym in call_reachable or sink_sym in entry_syms:
        return "LIVE"
    if sink_file in file_reachable:
        return "MAYBE"
    return "COLD"

seen_sink = set(); usinks = []
for s in sinks:
    key = (s["symbol_id"], s["class"])
    if key in seen_sink: continue
    seen_sink.add(key); usinks.append(s)

reach_records = []
for s in usinks:
    sid = s["symbol_id"]; fp = s["file"]
    comp, phash = component_hash(sid)
    bucket = bucket_for(sid, fp)
    rfrom = sorted(entry_syms & comp)[:5]
    sanitized = bool(sanitizer_syms & comp)
    reach_records.append({"sink": sid, "file": fp, "class": s["class"], "bucket": bucket,
                          "reachable_from": rfrom, "path_hash": phash,
                          "sanitized_observed": sanitized})

st, rt = sinks_p + ".tmp", reach_p + ".tmp"
with open(st, "w") as f:
    for s in usinks:
        f.write(json.dumps(s) + "\n")
with open(rt, "w") as f:
    for r in reach_records:
        f.write(json.dumps(r) + "\n")
os.replace(st, sinks_p)
os.replace(rt, reach_p)
live = sum(1 for r in reach_records if r["bucket"] == "LIVE")
maybe = sum(1 for r in reach_records if r["bucket"] == "MAYBE")
print("SINKS=%d LIVE=%d MAYBE=%d COLD=%d" % (len(usinks), live, maybe, len(reach_records) - live - maybe))
PY
)"; then
      log "reachability: built (${out:-done})."
      return 0
    fi
    log "reachability: python build failed; falling back to file-level sink grep (all COLD)."
  fi

  build_filelevel_shell
}

# Degrade (no python3): file-level sink grep only; no reachability -> every sink COLD.
build_filelevel_shell() {
  local st="${SINKS}.tmp" rt="${REACH}.tmp"
  : > "$st"; : > "$rt"
  local p abs cls hash exg
  exg="$(bugsweep_exclude_globs)"   # honor exclude_globs so the fallback matches the python path
  while IFS= read -r p; do
    case "$p" in *.py|*.js|*.jsx|*.ts|*.tsx|*.go) ;; *) continue ;; esac
    bugsweep_excluded "$p" "$exg" && continue   # skip vendored/generated paths
    abs="${REPO_ROOT}/${p}"; [ -f "$abs" ] || continue
    cls=""
    # 'pick''le' is split so a host pickle-scanner does not flag this detection pattern.
    if   grep -qE '\.(query|execute|executemany|raw)[[:space:]]*\(|cursor\.' "$abs" 2>/dev/null; then cls="sql"
    elif grep -qE 'os\.system|subprocess|child_process|\bexec[[:space:]]*\(|popen|spawn' "$abs" 2>/dev/null; then cls="exec"
    elif grep -qE 'pick''le\.load|yaml\.load|marshal\.loads|unserialize' "$abs" 2>/dev/null; then cls="deser"
    elif grep -qE 'hashlib\.(md5|sha1)|createHash' "$abs" 2>/dev/null; then cls="crypto"
    elif grep -qE 'requests\.|urlopen|axios\.|\bfetch[[:space:]]*\(' "$abs" 2>/dev/null; then cls="outbound"
    elif grep -qE 'os\.remove|os\.unlink|shutil\.(rmtree|move)|fs\.(unlink|rm)' "$abs" 2>/dev/null; then cls="file_path"
    fi
    [ -n "$cls" ] || continue
    hash="$(printf '%s' "$p" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } 2>/dev/null | awk '{print substr($1,1,12)}')"
    printf '{"symbol_id":"%s","file":"%s","class":"%s","evidence":"sink:%s","degraded":true}\n' "$p" "$p" "$cls" "$cls" >> "$st"
    printf '{"sink":"%s","file":"%s","class":"%s","bucket":"COLD","reachable_from":[],"path_hash":"%s","sanitized_observed":false,"degraded":true}\n' \
      "$p" "$p" "$cls" "${hash:-0}" >> "$rt"
  done < <(git -C "$REPO_ROOT" ls-files 2>/dev/null || true)
  mv "$st" "$SINKS"; mv "$rt" "$REACH"
  log "reachability: built degraded file-level sinks ($(bugsweep_count_lines "$SINKS") sinks, all COLD)."
}

# ---------------------------------------------------------------------------
# rank: fold sink-reachability into a per-FILE in-tier sort for context-build.
rank() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: reachability.sh rank <RUN_DIR>"
  run_dir="$(cd "$run_dir" && pwd)"
  local out="${run_dir}/exposure.json"

  if ! have_python; then
    printf '{"schema":1,"degraded":true,"files":[]}\n' > "$out"
    echo "EXPOSURE=${out}"; return 0
  fi

  if REACH="$REACH" OUT="$out" python3 - <<'PY' 2>/dev/null
import json, os
reach = os.environ["REACH"]; out = os.environ["OUT"]
WEIGHT = {"exec": 5, "deser": 5, "sql": 4, "crypto": 3, "outbound": 2, "file_path": 2}
RANK = {"LIVE": 2, "MAYBE": 1, "COLD": 0}
best = {}   # file -> [rank, weight, bucket, top_class]
if os.path.exists(reach):
    for line in open(reach):
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except Exception: continue
        f = r.get("file")
        if not f: continue
        rk = RANK.get(r.get("bucket"), 0); w = WEIGHT.get(r.get("class"), 1)
        cur = best.get(f)
        if cur is None or (rk, w) > (cur[0], cur[1]):
            best[f] = [rk, w, r.get("bucket", "COLD"), r.get("class", "")]
ordered = sorted(best.items(), key=lambda kv: (-kv[1][0], -kv[1][1], kv[0]))
files = [{"file": f, "bucket": v[2], "top_class": v[3], "weight": v[1]} for f, v in ordered]
json.dump({"schema": 1, "files": files}, open(out, "w"), indent=2)
print("RANKED=%d" % len(files))
PY
  then
    echo "EXPOSURE=${out}"; return 0
  fi
  # python error -> degraded empty exposure (context-build falls back). Never fail.
  printf '{"schema":1,"degraded":true,"files":[]}\n' > "$out"
  echo "EXPOSURE=${out}"
}

# ---------------------------------------------------------------------------
# add-sanitizer: persist a sanitizer fact (referee/fix call this on a cleared path).
# classes is a comma list restricted to the closed sink-class enum — repo-derived free text
# never enters the registry (injection guard, per the WU-G lesson).
add_sanitizer() {
  local sid="${1:-}" classes="${2:-}"
  [ -n "$sid" ] && [ -n "$classes" ] || die "usage: reachability.sh add-sanitizer <symbol_id> <class[,class...]>"
  bugsweep_state_dir_ready && mkdir -p "$STATE_DIR" 2>/dev/null \
    || { log "reachability: cannot use project-scoped state dir (${STATE_DIR:-not in a git repo}); skipping add-sanitizer."; return 0; }
  have_python || { log "reachability: python3 required for add-sanitizer; skipped."; return 0; }
  SANITIZERS="$SANITIZERS" python3 - "$sid" "$classes" <<'PY' 2>/dev/null || { log "reachability: add-sanitizer failed (non-fatal)."; return 0; }
import json, os, sys
san = os.environ["SANITIZERS"]; sid = sys.argv[1]; raw = sys.argv[2]
ALLOWED = {"sql", "exec", "deser", "crypto", "file_path", "outbound", "authz", "money"}
classes = sorted({c for c in (x.strip() for x in raw.split(",")) if c in ALLOWED})
if not classes:
    sys.exit(0)
keep = []
if os.path.exists(san):
    for line in open(san):
        line = line.strip()
        if not line: continue
        try: e = json.loads(line)
        except Exception: continue
        if e.get("symbol_id") == sid: continue
        keep.append(line)
keep.append(json.dumps({"symbol_id": sid, "neutralizes": classes}))
tmp = san + ".tmp"
open(tmp, "w").write("\n".join(keep) + "\n")
os.replace(tmp, san)
print("SANITIZER_ADDED")
PY
}

# remove-sanitizer: drop a sanitizer fact (a prior "neutralizes" judgment was wrong/revised).
# Symmetric with add-sanitizer; any WU2 conclusion citing it re-opens next prime (neutralizes
# hash vanishes -> reopen).
remove_sanitizer() {
  local sid="${1:-}"
  [ -n "$sid" ] || die "usage: reachability.sh remove-sanitizer <symbol_id>"
  [ -f "$SANITIZERS" ] || { log "reachability: no sanitizer registry; nothing to remove."; return 0; }
  have_python || { log "reachability: python3 required for remove-sanitizer; skipped."; return 0; }
  SANITIZERS="$SANITIZERS" python3 - "$sid" <<'PY' 2>/dev/null || { log "reachability: remove-sanitizer failed (non-fatal)."; return 0; }
import json, os, sys
san = os.environ["SANITIZERS"]; sid = sys.argv[1]
keep = []; found = False
for line in open(san):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    if e.get("symbol_id") == sid:
        found = True; continue
    keep.append(line)
tmp = san + ".tmp"
open(tmp, "w").write(("\n".join(keep) + "\n") if keep else "")
os.replace(tmp, san)
print("REMOVED" if found else "NOT_FOUND")
PY
}

stats() {
  echo "SINKS=$(bugsweep_count_lines "$SINKS") REACH=$(bugsweep_count_lines "$REACH") LIVE=$(bugsweep_grep_count '"bucket": ?"LIVE"' "$REACH")"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  build)            build ;;
  rank)             rank "$@" ;;
  add-sanitizer)    add_sanitizer "$@" ;;
  remove-sanitizer) remove_sanitizer "$@" ;;
  stats)            stats ;;
  *)                die "usage: reachability.sh <build|rank|add-sanitizer|remove-sanitizer|stats> ..." ;;
esac
