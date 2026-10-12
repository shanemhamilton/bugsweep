#!/usr/bin/env bash
# Update the installation containing this script, unless --all is explicit.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; ACTIVE_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)"; ALL=false
[ "${1:-}" = --all ] && { ALL=true; shift; }; [ "$#" -eq 0 ] || { printf 'usage: update-install.sh [--all]\n' >&2; exit 2; }
METADATA="$(python3 - "$ACTIVE_ROOT/install-metadata.json" "$ACTIVE_ROOT" <<'PY'
import json,os,sys
with open(sys.argv[1]) as f:d=json.load(f)
root=os.path.realpath(sys.argv[2])
host=d.get("host")
skills_root=d.get("skills_root")
legacy_root=d.get("legacy_root")
if d.get("schema_version") != 1 or d.get("canonical_root") != root or host not in {"claude","codex","agy"}:
    raise SystemExit(1)
if skills_root is None:
    skills_root=os.path.dirname(root)
if not isinstance(skills_root,str) or "\t" in skills_root or "\n" in skills_root:
    raise SystemExit(1)
if legacy_root is not None and (not isinstance(legacy_root,str) or "\t" in legacy_root or "\n" in legacy_root):
    raise SystemExit(1)
if legacy_root is None and host == "codex" and "legacy_root" not in d:
    legacy_root=os.path.dirname(os.path.realpath(skills_root))
legacy_root=legacy_root or ""
if os.path.realpath(skills_root) != os.path.dirname(root):
    raise SystemExit(1)
if legacy_root and (host != "codex" or os.path.realpath(legacy_root) != os.path.dirname(os.path.realpath(skills_root))):
    raise SystemExit(1)
print("{}\t{}\t{}".format(host,os.path.realpath(skills_root),os.path.realpath(legacy_root) if legacy_root else ""))
PY
)" || { printf 'bugsweep updater: active install metadata is invalid\n' >&2; exit 1; }
IFS="$(printf '\t')" read -r HOST SKILLS_ROOT LEGACY_ROOT <<EOF
$METADATA
EOF
case "$HOST" in
  claude)
    INSTALL_FLAG=--claude; $ALL && INSTALL_FLAG=--all
    CLAUDE_SKILLS_DIR="$SKILLS_ROOT" exec bash "$ACTIVE_ROOT/install.sh" "$INSTALL_FLAG"
    ;;
  codex)
    if [ -n "$LEGACY_ROOT" ]; then
      unset CODEX_SKILLS_DIR
      INSTALL_FLAG=--codex; $ALL && INSTALL_FLAG=--all
      CODEX_DIR="$LEGACY_ROOT" exec bash "$ACTIVE_ROOT/install.sh" "$INSTALL_FLAG"
    else
      unset CODEX_DIR
      INSTALL_FLAG=--codex; $ALL && INSTALL_FLAG=--all
      CODEX_SKILLS_DIR="$SKILLS_ROOT" exec bash "$ACTIVE_ROOT/install.sh" "$INSTALL_FLAG"
    fi
    ;;
  agy)
    INSTALL_FLAG=--agy; $ALL && INSTALL_FLAG=--all
    AGY_SKILLS_DIR="$SKILLS_ROOT" exec bash "$ACTIVE_ROOT/install.sh" "$INSTALL_FLAG"
    ;;
  *) printf 'bugsweep updater: active install metadata is invalid\n' >&2; exit 1;;
esac
