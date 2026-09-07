#!/usr/bin/env bash
# Update the installation containing this script, unless --all is explicit.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; ACTIVE_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)"; ALL=false
[ "${1:-}" = --all ] && { ALL=true; shift; }; [ "$#" -eq 0 ] || { printf 'usage: update-install.sh [--all]\n' >&2; exit 2; }
HOST="$(python3 - "$ACTIVE_ROOT/install-metadata.json" "$ACTIVE_ROOT" <<'PY'
import json,os,sys
with open(sys.argv[1]) as f:d=json.load(f)
assert d.get("schema_version")==1 and d.get("canonical_root")==os.path.realpath(sys.argv[2]) and d.get("host") in {"claude","codex"}
print(d["host"])
PY
)" || { printf 'bugsweep updater: active install metadata is invalid\n' >&2; exit 1; }
$ALL && exec bash "$ACTIVE_ROOT/install.sh" --all
case "$HOST" in claude) CLAUDE_SKILLS_DIR="$(dirname "$ACTIVE_ROOT")" exec bash "$ACTIVE_ROOT/install.sh" --claude;; codex) CODEX_DIR="$(dirname "$(dirname "$ACTIVE_ROOT")")" exec bash "$ACTIVE_ROOT/install.sh" --codex;; esac
