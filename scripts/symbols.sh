#!/usr/bin/env bash
# bugsweep symbol index (WU0): the hybrid stable-ID layer that later work units
# (WU-G graph, WU3 reachability, WU2 justification ledger) key their facts to.
#
# Identity  = qualified name  "relative/path[:Container.member]"   (survives reformatting)
# Version   = content hash     of the file (always) and of each Python symbol body (exact)
#
# Honest scope (tree-sitter is absent on target machines, so we do NOT guess sub-file
# boundaries for languages we can't parse reliably):
#   - EVERY tracked code file gets a reliable file-level entry  (kind:file)  -- the floor.
#   - Python files additionally get EXACT sub-file symbols via the stdlib `ast` module.
#   - js/ts/go/etc. get file-level only (a wrong regex-sliced ID is worse than file-level).
# No safety property may depend on sub-file precision; consumers fall back to the file entry.
#
#   symbols.sh build            (re)build .bugsweep/state/symbol-index.jsonl (incremental)
#   symbols.sh lookup <id>      print the stored hash for a symbol_id (empty if unknown)
#   symbols.sh stale <id> <h>   exit 0 if the stored hash != <h> (changed/unknown), 1 if same
#
# Incremental: a file whose content hash is unchanged since the last build reuses its cached
# entries (never re-parsed). Degrades, never fails a run: no python3 -> file-level only.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Repo root, state dir, have_python come from common.sh.
REPO_ROOT="$BUGSWEEP_REPO_ROOT"
STATE_DIR="$BUGSWEEP_STATE_DIR"
INDEX="${STATE_DIR}/symbol-index.jsonl"

build() {
  mkdir -p "$STATE_DIR" 2>/dev/null || { log "symbols: cannot create ${STATE_DIR}; skipping."; return 0; }

  # Exclude globs come from config; pass as newline list to the extractor.
  local excludes; excludes="$(cfg_get '.exclude_globs' '')"

  if have_python; then
    local out
    if out="$(REPO_ROOT="$REPO_ROOT" INDEX="$INDEX" EXCLUDES="$excludes" python3 - <<'PY' 2>/dev/null

import json, os, sys, hashlib, subprocess, ast, fnmatch
root = os.environ["REPO_ROOT"]; idx = os.environ["INDEX"]
try:
    excludes = json.loads(os.environ.get("EXCLUDES") or "[]")
    if not isinstance(excludes, list): excludes = []
except Exception:
    excludes = []

CODE_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".go", ".rb", ".java", ".kt", ".kts",
    ".swift", ".rs", ".php", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs", ".scala",
    ".m", ".mm", ".sh", ".bash", ".lua", ".ex", ".exs", ".clj",
}
LANG = {".py": "py", ".js": "js", ".jsx": "js", ".ts": "ts", ".tsx": "ts", ".go": "go"}

def excluded(path):
    return any(fnmatch.fnmatch(path, g) or fnmatch.fnmatch(path, g.rstrip("/") + "/*")
               for g in excludes)

try:
    files = subprocess.check_output(["git", "-C", root, "ls-files"], text=True).splitlines()
except Exception:
    files = []

# Prior index: file path -> (filehash, [raw json lines]) for incremental reuse.
prior = {}
if os.path.exists(idx):
    cur = None
    for line in open(idx):
        line = line.strip()
        if not line: continue
        try: e = json.loads(line)
        except Exception: continue
        if e.get("kind") == "file":
            cur = e.get("symbol_id")
            prior.setdefault(cur, {"hash": e.get("hash"), "lines": []})
            prior[cur]["lines"].append(line)
        elif cur and e.get("symbol_id", "").startswith(cur + ":"):
            prior[cur]["lines"].append(line)

def py_symbols(path, src, lang):
    out = []
    try:
        tree = ast.parse(src)
    except Exception:
        return out  # unparseable -> file-level only (floor)
    stack = []
    def walk(node, prefix):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                qual = (prefix + "." if prefix else "") + child.name
                seg = ast.get_source_segment(src, child) or ""
                h = hashlib.sha256(seg.encode("utf-8", "replace")).hexdigest()[:12]
                kind = "class" if isinstance(child, ast.ClassDef) else ("method" if prefix else "function")
                out.append({"symbol_id": "%s:%s" % (path, qual), "hash": h, "lang": lang,
                            "start": child.lineno, "end": getattr(child, "end_lineno", child.lineno),
                            "kind": kind})
                walk(child, qual)
    walk(tree, "")
    return out

entries = []
seen = set()
for path in files:
    if excluded(path): continue
    ext = os.path.splitext(path)[1].lower()
    if ext not in CODE_EXTS: continue
    seen.add(path)
    abs_p = os.path.join(root, path)
    try:
        data = open(abs_p, "rb").read()
    except Exception:
        continue
    fh = hashlib.sha256(data).hexdigest()[:12]
    lang = LANG.get(ext, ext.lstrip("."))
    # Incremental reuse when file content is unchanged.
    pr = prior.get(path)
    if pr and pr.get("hash") == fh:
        entries.extend(pr["lines"]); continue
    entries.append(json.dumps({"symbol_id": path, "hash": fh, "lang": lang, "kind": "file"}))
    if ext == ".py":
        try:
            src = data.decode("utf-8", "replace")
        except Exception:
            src = ""
        for s in py_symbols(path, src, lang):
            entries.append(json.dumps(s))

tmp = idx + ".tmp"
with open(tmp, "w") as f:
    for e in entries:
        f.write((e if isinstance(e, str) else json.dumps(e)) + "\n")
os.replace(tmp, idx)
print("FILES=%d ENTRIES=%d" % (len(seen), len(entries)))
PY
)"; then
      log "symbols: built index (${out:-done})."
      return 0
    fi
    log "symbols: python build failed; falling back to file-level hashes only."
  fi

  # Degrade path: file-level hashes only, via shell (no sub-file symbols).
  build_filelevel_shell
}

# Pure-shell file-level fallback (no python3): hash each tracked code file.
build_filelevel_shell() {
  local hasher
  if command -v sha256sum >/dev/null 2>&1; then hasher="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then hasher="shasum -a 256"
  else log "symbols: no sha tool — cannot build index."; return 0; fi
  local tmp="${INDEX}.tmp"; : > "$tmp"
  git -C "$REPO_ROOT" ls-files | while IFS= read -r p; do
    case "$p" in
      *.py|*.js|*.jsx|*.ts|*.tsx|*.go|*.rb|*.java|*.kt|*.swift|*.rs|*.php|*.c|*.cc|*.cpp|*.h|*.hpp|*.cs|*.sh) ;;
      *) continue ;;
    esac
    [ -f "${REPO_ROOT}/${p}" ] || continue
    local h; h="$($hasher "${REPO_ROOT}/${p}" 2>/dev/null | awk '{print substr($1,1,12)}')"
    [ -n "$h" ] && printf '{"symbol_id":"%s","hash":"%s","kind":"file"}\n' "$p" "$h" >> "$tmp"
  done
  mv "$tmp" "$INDEX"
  log "symbols: built file-level index ($(wc -l < "$INDEX" 2>/dev/null | tr -d ' ') files)."
}

lookup() {
  local id="${1:-}"; [ -n "$id" ] || die "usage: symbols.sh lookup <symbol_id>"
  [ -f "$INDEX" ] || return 0
  # No-python path: extract just the hash (matching the shell-fallback's space-free JSON),
  # so the value is comparable in `stale` rather than a whole JSON line.
  have_python || { grep -F "\"symbol_id\":\"${id}\"" "$INDEX" 2>/dev/null | head -1 \
    | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p'; return 0; }
  INDEX="$INDEX" python3 - "$id" <<'PY' 2>/dev/null || true
import json, os, sys
idx = os.environ["INDEX"]; want = sys.argv[1]
for line in open(idx):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    if e.get("symbol_id") == want:
        print(e.get("hash", "")); break
PY
}

# stale <id> <hash>: exit 0 if changed/unknown (caller should re-open), 1 if hash matches.
stale() {
  local id="${1:-}" h="${2:-}"
  [ -n "$id" ] && [ -n "$h" ] || die "usage: symbols.sh stale <symbol_id> <hash>"
  local cur; cur="$(lookup "$id")"
  [ "$cur" = "$h" ] && return 1 || return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  build)  build ;;
  lookup) lookup "$@" ;;
  stale)  stale "$@" ;;
  *)      die "usage: symbols.sh <build|lookup|stale> ..." ;;
esac
