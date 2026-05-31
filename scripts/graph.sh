#!/usr/bin/env bash
# bugsweep call/import graph + untrusted entry-point classifier (WU-G).
#
# Builds the two facts WU3 (reachability ranking) and WU2 (assumption invalidation)
# stand on: a graph of who-reaches-what, and which symbols are attacker-reachable
# entry points. Both are keyed by the WU0 stable symbol-ids so the layers join.
#
#   graph.sh build      (re)build .bugsweep/state/graph.jsonl + entry-points.jsonl
#   graph.sh stats      print a one-line summary of the current graph (for tests/ops)
#
# ── Honest scope (tree-sitter is absent; we never ship a fragile sub-file regex slicer) ──
#   Caller identity (call edges):
#     - PYTHON ONLY. Calls are attributed to their enclosing function/class via the SAME
#       qualified-name walk symbols.sh uses (path:Container.member, dot-nested), so a call
#       edge's `src` is byte-for-byte a WU0 symbol_id. Other languages get NO call edges
#       (a regex-sliced caller id would be wrong, and wrong is worse than absent here).
#   Callee resolution (two-tier, conservative — over-linking misranks, it never drops a sink):
#     - strong : the callee's bare name is unique among THIS file's own defs.
#     - weak   : not in-file, but the name is unique across the whole repo's defs.
#     - none   : ambiguous (collides) or unknown -> `dst_name` only, no `dst`. WU3 treats
#                strong > weak and may ignore `none` edges; it must never invent a target.
#   Import edges (all langs, file -> file): python via `ast`; js/ts/go via line regex.
#     Relative specifiers resolve to a repo file (`resolved":true`); bare/3rd-party stay
#     unresolved (`dst_name` only). Module->file resolution is candidate-path matching, best effort.
#   Entry-point classification (untrusted surface):
#     - http      : python decorators @app.route/@app.get|post|put|patch|delete|websocket,
#                   @router.* , @bp.* , @api.* ; django urls.py path()/re_path() (file-level);
#                   js/ts app.METHOD( / router.METHOD( / createServer / @RestController/@RequestMapping (file-level);
#                   go http.HandleFunc / .HandleFunc( (file-level).
#     - cli       : python argparse / @click.command|group / sys.argv / __main__ guard;
#                   js process.argv / commander ; go os.Args / flag.Parse (file-level).
#     - consumer  : python @task/@shared_task/@*.task/@*.subscribe/@*.consumer ;
#                   js .subscribe( / onMessage / addEventListener('message' ; (file-level for non-py).
#     - file_ipc  : python sys.stdin / socket / input() (file-level signal).
#   `evidence` is ALWAYS a fixed catalog TOKEN (e.g. "decorator:app.route", "argparse"),
#   never raw repo text — persisted facts are DATA, so we never copy attacker-controlled
#   source into a field that later lands in a prompt.
#
# ── Documented misses (by design; degrade WIDENS, never narrows) ──
#   - Indirect/dynamic dispatch (interface & abstract-method calls, getattr/setattr route
#     registration, decorators imported under an alias) is NOT resolved.
#   - A file that fails to parse contributes NO edges/entries -> WU3 falls back to
#     sink+severity ordering FOR THAT FILE (the whole-repo widen contract, per file).
#   - Whole-build failure (no python, or an unexpected error) -> files are absent/empty ->
#     WU3 falls back globally to sink+severity. We never crash and never fail the run.
#   - The no-python shell fallback classifies only http/cli entry points (not consumer/file_ipc)
#     and emits no call edges or module->file resolution -- absent entries just mean WU3 uses
#     sink+severity for those files (widen). Full classification requires the python path.
#
# Full rebuild every run (repo-scale is fine for a single session; per-symbol incremental
# invalidation is WU3's job). Each output is staged to .tmp and os.replace'd (per-file
# atomic rename — no file is ever seen half-written). POSIX has no atomic multi-file rename,
# so a crash between the two renames can leave the entry-points file one build behind the
# graph; that split state is widen-safe (both are real prior states) and self-heals next run.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Repo root, state dir, have_python come from common.sh.
REPO_ROOT="$BUGSWEEP_REPO_ROOT"
STATE_DIR="$BUGSWEEP_STATE_DIR"
GRAPH="${STATE_DIR}/graph.jsonl"
ENTRIES="${STATE_DIR}/entry-points.jsonl"

build() {
  bugsweep_state_dir_ready && mkdir -p "$STATE_DIR" 2>/dev/null \
    || { log "graph: cannot use project-scoped state dir (${STATE_DIR:-not in a git repo}); skipping."; return 0; }

  local excludes; excludes="$(cfg_get '.exclude_globs' '')"

  if have_python; then
    local out
    if out="$(REPO_ROOT="$REPO_ROOT" GRAPH="$GRAPH" ENTRIES="$ENTRIES" EXCLUDES="$excludes" python3 - <<'PY' 2>/dev/null
import json, os, ast, fnmatch, re, subprocess

root = os.environ["REPO_ROOT"]
graph_path = os.environ["GRAPH"]
entries_path = os.environ["ENTRIES"]
try:
    excludes = json.loads(os.environ.get("EXCLUDES") or "[]")
    if not isinstance(excludes, list):
        excludes = []
except Exception:
    excludes = []

CODE_EXTS = {".py", ".js", ".jsx", ".ts", ".tsx", ".go"}
LANG = {".py": "py", ".js": "js", ".jsx": "js", ".ts": "ts", ".tsx": "ts", ".go": "go"}
HTTP_METHODS = {"route", "get", "post", "put", "patch", "delete", "head", "options", "websocket"}
CONSUMER_DECOS = {"task", "shared_task", "subscribe", "consumer", "listen", "on"}

def excluded(path):
    return any(fnmatch.fnmatch(path, g) or fnmatch.fnmatch(path, g.rstrip("/") + "/*")
               for g in excludes)

try:
    files = [f for f in subprocess.check_output(
        ["git", "-C", root, "ls-files"], text=True).splitlines() if f]
except Exception:
    files = []

tracked = set()
py_files, web_files = [], []
for path in files:
    if excluded(path):
        continue
    ext = os.path.splitext(path)[1].lower()
    if ext not in CODE_EXTS:
        continue
    tracked.add(path)
    if ext == ".py":
        py_files.append(path)
    else:
        web_files.append((path, LANG.get(ext, ext.lstrip("."))))

# ── Pass 1: collect python defs (qualified names IDENTICAL to symbols.sh py_symbols) ──
# per-file tail-name -> [symbol_id]; global tail-name -> set(symbol_id)
file_defs = {}      # path -> {tail: [symbol_id, ...]}
global_tail = {}    # tail -> set(symbol_id)
py_src = {}         # path -> source (only for parseable files)

def collect_defs(path, src):
    local = {}
    try:
        tree = ast.parse(src)
    except Exception:
        return None  # unparseable -> no edges/entries for this file (per-file widen)
    def walk(node, prefix):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                qual = (prefix + "." if prefix else "") + child.name
                sid = "%s:%s" % (path, qual)
                tail = child.name
                local.setdefault(tail, []).append(sid)
                global_tail.setdefault(tail, set()).add(sid)
                walk(child, qual)
    walk(tree, "")
    return (tree, local)

parsed = {}  # path -> ast tree (parseable only)
for path in py_files:
    abs_p = os.path.join(root, path)
    try:
        src = open(abs_p, "r", encoding="utf-8", errors="replace").read()
    except Exception:
        continue  # unreadable -> skip (widen)
    res = collect_defs(path, src)
    if res is None:
        continue
    tree, local = res
    parsed[path] = tree
    file_defs[path] = local
    py_src[path] = src

def resolve_callee(path, name):
    # (dst_or_None, resolution)
    local = file_defs.get(path, {}).get(name)
    if local and len(local) == 1:
        return (local[0], "strong")
    g = global_tail.get(name)
    if g and len(g) == 1:
        return (next(iter(g)), "weak")
    return (None, "none")

# ── python module -> repo file resolution (candidate-path matching) ──
def module_to_file(mod):
    if not mod:
        return None
    parts = mod.split(".")
    for cand in ("/".join(parts) + ".py", "/".join(parts) + "/__init__.py"):
        if cand in tracked:
            return cand
    return None

def rel_module_to_file(curpath, level, mod):
    base = os.path.dirname(curpath)
    for _ in range(max(0, level - 1)):
        base = os.path.dirname(base)
    parts = [p for p in (mod.split(".") if mod else []) if p]
    stem = "/".join([base] + parts).lstrip("/") if (base or parts) else ""
    for cand in (stem + ".py", stem + "/__init__.py"):
        cand = cand.lstrip("/")
        if cand in tracked:
            return cand
    return None

graph_edges = []
entry_recs = []

def deco_dotted(dec):
    # @x.y.z(...) or @x.y / @x  ->  "x.y.z"
    node = dec.func if isinstance(dec, ast.Call) else dec
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
    return ".".join(reversed(parts))

# ── Pass 2: python calls, imports, entry points ──
for path in parsed:
    tree = parsed[path]
    src = py_src[path]
    file_http = file_cli = file_ipc = False
    cli_evidence = None

    # module-level textual signals (cheap, file-level) for cli / file_ipc
    if re.search(r'\bargparse\b', src):
        file_cli = True; cli_evidence = cli_evidence or "argparse"
    if re.search(r'\bsys\.argv\b', src):
        file_cli = True; cli_evidence = cli_evidence or "sys.argv"
    if re.search(r'if\s+__name__\s*==\s*[\x22\x27]__main__[\x22\x27]', src):
        file_cli = True; cli_evidence = cli_evidence or "__main__"
    if re.search(r'\bsys\.stdin\b', src):
        file_ipc = True
    if re.search(r'\bsocket\.socket\b', src):
        file_ipc = True
    if os.path.basename(path) == "urls.py" and re.search(r'\b(re_path|path|url)\s*\(', src):
        file_http = True

    # walk with enclosing-symbol tracking for call attribution + decorator entries.
    # skip_deco holds the node ids of decorator expressions: a decorator is metadata ON a
    # function, not a call BY it, so its whole subtree is excluded from call attribution
    # (otherwise @app.route("/x") would fabricate a `handler -> route` edge into the graph
    # WU3 ranks on). Classification still reads the decorator names below.
    skip_deco = set()
    def visit(node, enclosing):
        for child in ast.iter_child_nodes(node):
            if id(child) in skip_deco:
                continue
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                qual_sid = enclosing_child_id(enclosing, child)
                # decorator-based entry classification (precise). evidence is a FIXED token
                # (never the repo-derived decorator name) — persisted facts are DATA, and an
                # attacker-chosen decorator identifier must not flow into a downstream prompt.
                for dec in getattr(child, "decorator_list", []):
                    skip_deco.add(id(dec))
                    dotted = deco_dotted(dec)
                    last = dotted.split(".")[-1] if dotted else ""
                    if last in HTTP_METHODS:
                        entry_recs.append({"symbol_id": qual_sid, "file": path, "kind": "http",
                                           "evidence": "decorator:http", "lang": "py"})
                    elif last in CONSUMER_DECOS or "task" in last:
                        entry_recs.append({"symbol_id": qual_sid, "file": path, "kind": "consumer",
                                           "evidence": "decorator:consumer", "lang": "py"})
                    elif dotted.startswith("click.") and last in ("command", "group"):
                        entry_recs.append({"symbol_id": qual_sid, "file": path, "kind": "cli",
                                           "evidence": "decorator:cli", "lang": "py"})
                visit(child, qual_sid)
            else:
                if isinstance(child, ast.Call):
                    # Only an unqualified Name call (foo()) is resolved by name. A method/attr
                    # call (obj.foo()) is recorded as dst_name only, NEVER resolved — the
                    # receiver's type is unknown, so binding it to a same-named global would be
                    # a fabricated link (contract: a wrong/ambiguous link is never `resolved`).
                    f = child.func
                    name = None
                    if isinstance(f, ast.Name):
                        name = f.id
                        dst, res = resolve_callee(path, name)
                    elif isinstance(f, ast.Attribute):
                        name = f.attr
                        dst, res = (None, "none")
                    if name:
                        edge = {"kind": "call", "src": enclosing, "src_file": path,
                                "dst_name": name, "resolved": res, "lang": "py"}
                        if dst is not None:
                            edge["dst"] = dst
                        graph_edges.append(edge)
                # imports
                if isinstance(child, ast.Import):
                    for a in child.names:
                        dstf = module_to_file(a.name)
                        e = {"kind": "import", "src": path, "dst_name": a.name,
                             "resolved": bool(dstf), "lang": "py"}
                        if dstf:
                            e["dst"] = dstf
                        graph_edges.append(e)
                elif isinstance(child, ast.ImportFrom):
                    mod = child.module or ""
                    lvl = child.level or 0
                    dstf = rel_module_to_file(path, lvl, mod) if lvl else module_to_file(mod)
                    e = {"kind": "import", "src": path,
                         "dst_name": ("." * lvl) + mod, "resolved": bool(dstf), "lang": "py"}
                    if dstf:
                        e["dst"] = dstf
                    graph_edges.append(e)
                visit(child, enclosing)

    def enclosing_child_id(enclosing, child):
        # enclosing is either "path" (module) or "path:Qual"; append child name with dot
        if ":" in enclosing:
            base = enclosing.split(":", 1)[1]
            return "%s:%s.%s" % (path, base, child.name)
        return "%s:%s" % (path, child.name)

    if re.search(r'\binput\s*\(', src):
        file_ipc = True

    visit(tree, path)

    if file_http:
        entry_recs.append({"symbol_id": path, "file": path, "kind": "http",
                           "evidence": "django-urls", "lang": "py"})
    if file_cli:
        entry_recs.append({"symbol_id": path, "file": path, "kind": "cli",
                           "evidence": cli_evidence or "cli", "lang": "py"})
    if file_ipc:
        entry_recs.append({"symbol_id": path, "file": path, "kind": "file_ipc",
                           "evidence": "stdin/socket/input", "lang": "py"})

# ── js/ts/go: file-level import edges + file-level entry heuristics ──
# Quote chars are written as regex hex escapes (\x27, \x22) rather than literals to keep
# this heredoc body quote-balanced; the bash 3.2 command-substitution scanner miscounts otherwise.
JS_IMPORT = re.compile(
    r'(?:import\s+[^\x27\x22]*from\s+[\x27\x22]([^\x27\x22]+)[\x27\x22]'
    r'|require\(\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]\s*\)'
    r'|export\s+[^\x27\x22]*from\s+[\x27\x22]([^\x27\x22]+)[\x27\x22])')
GO_IMPORT = re.compile(r'^\s*(?:import\s+)?(?:[A-Za-z0-9_\.]+\s+)?\x22([^\x22]+)\x22')

def resolve_rel(curpath, spec):
    if not spec.startswith("."):
        return None
    base = os.path.dirname(curpath)
    target = os.path.normpath(os.path.join(base, spec))
    cands = [target]
    for ext in (".js", ".jsx", ".ts", ".tsx"):
        cands.append(target + ext)
        cands.append(os.path.normpath(os.path.join(target, "index" + ext)))
    for c in cands:
        if c in tracked:
            return c
    return None

HTTP_PAT = re.compile(r'\b(?:app|router|server|api)\.(?:get|post|put|patch|delete|use|all|head|options)\s*\('
                      r'|createServer\s*\(|HandleFunc\s*\(|@RestController|@RequestMapping|@(?:Get|Post|Put|Patch|Delete)Mapping')
CLI_PAT = re.compile(r'\bprocess\.argv\b|\bos\.Args\b|\bflag\.Parse\s*\(|require\(\s*[\x27\x22]commander[\x27\x22]\s*\)')
CONSUMER_PAT = re.compile(r'\.subscribe\s*\(|\bonMessage\b|addEventListener\(\s*[\x27\x22]message[\x27\x22]')

for path, lang in web_files:
    abs_p = os.path.join(root, path)
    try:
        text = open(abs_p, "r", encoding="utf-8", errors="replace").read()
    except Exception:
        continue
    if lang == "go":
        for m in GO_IMPORT.finditer(text):
            spec = m.group(1)
            graph_edges.append({"kind": "import", "src": path, "dst_name": spec,
                                "resolved": False, "lang": lang})
    else:
        for m in JS_IMPORT.finditer(text):
            spec = m.group(1) or m.group(2) or m.group(3)
            if not spec:
                continue
            dstf = resolve_rel(path, spec)
            e = {"kind": "import", "src": path, "dst_name": spec,
                 "resolved": bool(dstf), "lang": lang}
            if dstf:
                e["dst"] = dstf
            graph_edges.append(e)
    if HTTP_PAT.search(text):
        entry_recs.append({"symbol_id": path, "file": path, "kind": "http",
                           "evidence": "web-route-pattern", "lang": lang})
    if CLI_PAT.search(text):
        entry_recs.append({"symbol_id": path, "file": path, "kind": "cli",
                           "evidence": "argv-pattern", "lang": lang})
    if CONSUMER_PAT.search(text):
        entry_recs.append({"symbol_id": path, "file": path, "kind": "consumer",
                           "evidence": "consumer-pattern", "lang": lang})

# Both datasets are fully built in memory, then each is staged to .tmp and os.replace'd
# (a per-file atomic rename — neither file is ever observed half-written). There is no
# atomic MULTI-file rename on POSIX, so a crash in the gap between the two renames can leave
# the entry-points file one build behind the graph. We replace graph LAST so the surviving
# split state is {fresh entry seeds, prior-run graph} — both real prior states. WU3 must
# treat the graph as best-effort and MUST NOT use a missing node/edge to drop a file from
# scope (sink-bearing files stay in scope unconditionally); the next run rebuilds both.
gt, et = graph_path + ".tmp", entries_path + ".tmp"
with open(gt, "w") as f:
    for e in graph_edges:
        f.write(json.dumps(e) + "\n")
with open(et, "w") as f:
    for e in entry_recs:
        f.write(json.dumps(e) + "\n")
os.replace(et, entries_path)
os.replace(gt, graph_path)
print("FILES=%d EDGES=%d ENTRIES=%d" % (len(tracked), len(graph_edges), len(entry_recs)))
PY
)"; then
      log "graph: built (${out:-done})."
      return 0
    fi
    log "graph: python build failed; falling back to file-level import edges + entry grep."
  fi

  build_filelevel_shell
}

# Degrade path (no python3): file-level import edges + entry-point grep only.
# No call edges, no module->file resolution. Honest, and still WIDENS (never narrows).
build_filelevel_shell() {
  local gt="${GRAPH}.tmp" et="${ENTRIES}.tmp"
  : > "$gt"; : > "$et"
  # Process substitution (not a pipe) so this while runs in THIS shell and the final mv
  # always executes. Every grep is wrapped so a no-match exit 1 cannot trip set -e/pipefail
  # and abort the degrade path — the contract is "widen, never fail".
  local p abs specs spec q exg
  q="$(printf '%b' '\042\047')"   # the two quote chars: " and ' (no literals in source)
  exg="$(bugsweep_exclude_globs)" # honor exclude_globs so the fallback matches the python path
  while IFS= read -r p; do
    case "$p" in
      *.py|*.js|*.jsx|*.ts|*.tsx|*.go) ;;
      *) continue ;;
    esac
    bugsweep_excluded "$p" "$exg" && continue   # skip vendored/generated paths
    abs="${REPO_ROOT}/${p}"
    [ -f "$abs" ] || continue
    # imports (unresolved dst_name only — no resolution without python). Python modules are
    # unquoted dotted names; js/ts/go specifiers are quoted — extract per language.
    case "$p" in
      *.py)
        specs="$( { grep -hoE '^[[:space:]]*(import|from)[[:space:]]+[A-Za-z0-9_.]+' "$abs" 2>/dev/null || true; } \
                 | awk '{print $2}' | head -1000 )"
        ;;
      *)
        specs="$( { grep -hoE "(import|from|require|export)[^${q}]*[${q}][^${q}]+[${q}]" "$abs" 2>/dev/null || true; } \
                 | { grep -oE "[${q}][^${q}]+[${q}]" 2>/dev/null || true; } | head -1000 | tr -d "$q" )"
        ;;
    esac
    if [ -n "$specs" ]; then
      while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        printf '{"kind":"import","src":"%s","dst_name":"%s","resolved":false,"degraded":true}\n' \
          "$p" "$spec" >> "$gt"
      done <<EOF
$specs
EOF
    fi
    # entry-point grep (file-level)
    if grep -qE '@app\.(route|get|post|put|patch|delete)|@router\.|HandleFunc|app\.(get|post|put|use)\(|createServer|@RestController' "$abs" 2>/dev/null; then
      printf '{"symbol_id":"%s","file":"%s","kind":"http","evidence":"grep","degraded":true}\n' "$p" "$p" >> "$et"
    fi
    if grep -qE 'sys\.argv|process\.argv|argparse|os\.Args|flag\.Parse' "$abs" 2>/dev/null; then
      printf '{"symbol_id":"%s","file":"%s","kind":"cli","evidence":"grep","degraded":true}\n' "$p" "$p" >> "$et"
    fi
  done < <(git -C "$REPO_ROOT" ls-files 2>/dev/null || true)
  mv "$gt" "$GRAPH"; mv "$et" "$ENTRIES"
  log "graph: built degraded file-level graph ($(bugsweep_count_lines "$GRAPH") edges, $(bugsweep_count_lines "$ENTRIES") entries)."
}

stats() {
  [ -f "$GRAPH" ] || { echo "GRAPH=absent"; return 0; }
  echo "EDGES=$(bugsweep_count_lines "$GRAPH") CALLS=$(bugsweep_grep_count '"kind": ?"call"' "$GRAPH") IMPORTS=$(bugsweep_grep_count '"kind": ?"import"' "$GRAPH") ENTRIES=$(bugsweep_count_lines "$ENTRIES")"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  build) build ;;
  stats) stats ;;
  *)     die "usage: graph.sh <build|stats>" ;;
esac
