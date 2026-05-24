#!/usr/bin/env bash
# bugsweep common helpers. Sourced by the other scripts.
# Kept POSIX/bash-3.2 friendly so it runs on stock macOS bash.

set -euo pipefail

# Resolve the skill root (directory that contains this scripts/ folder).
BUGSWEEP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUGSWEEP_ROOT="$(cd "${BUGSWEEP_SCRIPT_DIR}/.." && pwd)"
BUGSWEEP_CONFIG="${BUGSWEEP_ROOT}/config/bugsweep.config.json"

log()  { printf '[bugsweep] %s\n' "$*" >&2; }
die()  { printf '[bugsweep][FATAL] %s\n' "$*" >&2; exit 1; }

# Read a value from the JSON config. Works with jq, else python3, else a grep
# fallback for simple scalars — so the config is honored even on a bare machine.
# Usage: cfg_get '.caps.max_iterations' 'default'
cfg_get() {
  local path="$1" default="${2:-}"
  [ -f "$BUGSWEEP_CONFIG" ] || { printf '%s' "$default"; return 0; }

  # Tier 1: jq (handles everything, including '| join(" ")').
  if command -v jq >/dev/null 2>&1; then
    local v; v="$(jq -r "$path // empty" "$BUGSWEEP_CONFIG" 2>/dev/null || true)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    printf '%s' "$default"; return 0
  fi

  # Tier 2: python3. Translate the limited dotted-path dialect we use.
  if command -v python3 >/dev/null 2>&1; then
    local v
    v="$(BSW_PATH="$path" python3 - "$BUGSWEEP_CONFIG" <<'PY' 2>/dev/null || true
import json,os,sys
p=os.environ["BSW_PATH"].strip()
data=json.load(open(sys.argv[1]))
join=False
if p.endswith('| join(" ")'):
    join=True; p=p.split("|")[0].strip()
cur=data
for part in [s for s in p.lstrip(".").split(".") if s]:
    if isinstance(cur,dict) and part in cur: cur=cur[part]
    else: cur=None; break
if cur is None: print("",end="")
elif join and isinstance(cur,list): print(" ".join(str(x) for x in cur),end="")
elif isinstance(cur,(list,dict)): print(json.dumps(cur),end="")
else: print(cur,end="")
PY
)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    printf '%s' "$default"; return 0
  fi

  # Tier 3: grep fallback for a flat scalar leaf (e.g. .caps.max_iterations -> max_iterations).
  local leaf v
  leaf="$(printf '%s' "$path" | sed 's/.*\.//')"
  v="$(grep -o "\"${leaf}\"[[:space:]]*:[[:space:]]*[^,}]*" "$BUGSWEEP_CONFIG" 2>/dev/null \
        | head -1 | sed 's/.*:[[:space:]]*//; s/^"//; s/"$//')"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  printf '%s' "$default"
}

require_git_repo() {
  command -v git >/dev/null 2>&1 || die "git is not installed."
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "Not inside a git repository. bugsweep only runs in a git repo so it can quarantine all changes safely."
}

current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "DETACHED"
}

# Count ledger events matching an event name. ALWAYS prints exactly one integer,
# even on zero matches or a missing file. (grep -c prints 0 AND exits non-zero on
# no match, so a naive '|| echo 0' double-counts and breaks integer comparisons.)
count_event() {
  local file="$1" name="$2" n
  n="$(grep -c "\"event\":\"${name}\"" "$file" 2>/dev/null || true)"
  case "$n" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$n" ;;
  esac
}

# Line count of a file, or 0 if missing/empty/unreadable. Always prints exactly one integer
# (the JSONL state files end every record with a newline, so this counts records).
bugsweep_count_lines() {
  local file="${1:-}" n
  [ -f "$file" ] || { printf '0'; return 0; }
  n="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
  case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

# Count lines of <file> matching extended-regex <pattern>, or 0. Always prints one integer
# (grep -c exits non-zero AND prints 0 on no match, which a naive '|| echo 0' double-counts).
bugsweep_grep_count() {
  local pattern="${1:-}" file="${2:-}" n
  { [ -n "$pattern" ] && [ -f "$file" ]; } || { printf '0'; return 0; }
  n="$(grep -cE "$pattern" "$file" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

# Refuse any operation that would touch a remote. Defense in depth: the scripts
# never call push/fetch, but this makes the intent explicit and greppable.
assert_no_remote_op() { :; }

# --- Cross-run state location + shared helpers --------------------------------
# Used by state.sh / variants.sh / symbols.sh. Anchored to the repo root so paths
# stay stable regardless of CWD or branch checkouts. (git missing -> pwd fallback;
# require_git_repo enforces the real check later.)
BUGSWEEP_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BUGSWEEP_STATE_DIR="${BUGSWEEP_REPO_ROOT}/.bugsweep/state"

have_python() { command -v python3 >/dev/null 2>&1; }

# --- Anti-pattern catalog versioning -----------------------------------------
# Source of truth is references/antipatterns/versions.json (a per-detector-class integer map);
# the legacy single-integer references/antipatterns/VERSION is the fallback when the map is
# unreadable (no python3, or file missing). Two views:
#   catalog_class_version <class>   -> that class's version (for WU2 per-class invalidation)
#   catalog_aggregate_version       -> sum of all class versions (advances on ANY bump; used by
#                                      state.sh coverage so any catalog change re-audits broadly)
BUGSWEEP_CATALOG_VERSIONS="${BUGSWEEP_ROOT}/references/antipatterns/versions.json"
BUGSWEEP_CATALOG_VERSION_LEGACY="${BUGSWEEP_ROOT}/references/antipatterns/VERSION"

_catalog_legacy() {
  if [ -f "$BUGSWEEP_CATALOG_VERSION_LEGACY" ]; then
    tr -d '[:space:]' < "$BUGSWEEP_CATALOG_VERSION_LEGACY"
  else
    printf '0'
  fi
}

catalog_class_version() {
  local cls="${1:-}"
  [ -n "$cls" ] || { printf '0'; return 0; }
  if [ -f "$BUGSWEEP_CATALOG_VERSIONS" ] && have_python; then
    # class name passed via env (never interpolated into -c); file path is a controlled arg.
    BSW_CLS="$cls" python3 -c 'import json,os,sys
try:
    d=json.load(open(sys.argv[1])); print(int(d.get(os.environ["BSW_CLS"],0)))
except Exception:
    print("__FAIL__")' "$BUGSWEEP_CATALOG_VERSIONS" 2>/dev/null | {
      read -r v
      case "$v" in ''|__FAIL__|*[!0-9]*) _catalog_legacy ;; *) printf '%s' "$v" ;; esac
    }
    return 0
  fi
  _catalog_legacy
}

catalog_aggregate_version() {
  if [ -f "$BUGSWEEP_CATALOG_VERSIONS" ] && have_python; then
    python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(sum(int(v) for k,v in d.items() if not str(k).startswith("_")))
except Exception:
    print("__FAIL__")' "$BUGSWEEP_CATALOG_VERSIONS" 2>/dev/null | {
      read -r v
      case "$v" in ''|__FAIL__|*[!0-9]*) _catalog_legacy ;; *) printf '%s' "$v" ;; esac
    }
    return 0
  fi
  _catalog_legacy
}

# Emit the raw per-class versions JSON (or empty if unreadable) — for passing to a python
# evaluator that needs the whole map (conclusions.sh prime).
catalog_versions_json() {
  [ -f "$BUGSWEEP_CATALOG_VERSIONS" ] && cat "$BUGSWEEP_CATALOG_VERSIONS" 2>/dev/null || printf ''
}

# Resolve the exclude-glob list for the file-level shell fallbacks (graph.sh / reachability.sh),
# one glob per line. Parses .exclude_globs from config (quote chars built via printf so no
# literals are needed); `**`->`*` because bash `case` globbing already spans '/'. When neither
# jq nor python3 can parse the JSON array, falls back to a hardcoded floor of the documented
# defaults so the degrade path never indexes vendored/generated code.
bugsweep_exclude_globs() {
  local q exg
  q="$(printf '%b' '\042\047')"
  exg="$(cfg_get '.exclude_globs' '' | grep -oE "[${q}][^${q}]+[${q}]" 2>/dev/null | tr -d "$q" | sed 's#\*\*#*#g' || true)"
  if [ -z "$exg" ]; then
    exg="$(printf '%s\n' 'node_modules/*' 'dist/*' 'build/*' '.git/*' 'vendor/*' \
      'Pods/*' '.next/*' 'coverage/*' '*.lock' '*.min.js' '*/__generated__/*')"
  fi
  printf '%s\n' "$exg"
}

# bugsweep_excluded <path> <newline-glob-list>: exit 0 if <path> matches any glob (skip it),
# 1 otherwise. Used by the shell fallbacks to honor exclude_globs the same way the python paths do.
bugsweep_excluded() {
  local path="$1" globs="$2" glob
  [ -n "$globs" ] || return 1
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    case "$path" in $glob) return 0 ;; esac
  done <<EOF
$globs
EOF
  return 1
}

# Count of completed runs recorded in the cross-run meta file (0 if none/unreadable).
bugsweep_meta_runs() {
  local meta="${BUGSWEEP_STATE_DIR}/meta.json"
  [ -f "$meta" ] || { printf '0'; return 0; }
  if have_python; then
    python3 -c 'import json,sys
try:
    print(int(json.load(open(sys.argv[1])).get("runs",0)))
except Exception:
    print(0)' "$meta" 2>/dev/null || printf '0'
  else
    grep -o '"runs"[[:space:]]*:[[:space:]]*[0-9]*' "$meta" 2>/dev/null | grep -o '[0-9]*' | head -1 || printf '0'
  fi
}
