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

# Refuse any operation that would touch a remote. Defense in depth: the scripts
# never call push/fetch, but this makes the intent explicit and greppable.
assert_no_remote_op() { :; }
