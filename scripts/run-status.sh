#!/usr/bin/env bash
# Read-only terminal lifecycle status.  No common.sh: status must not run Git.
set -euo pipefail

run_dir="${1:-}"
format="${2:-}"
[ -n "$run_dir" ] || { echo "usage: run-status.sh <RUN_DIR> [--json]" >&2; exit 2; }
case "$format" in ''|--json) ;; *) echo "usage: run-status.sh <RUN_DIR> [--json]" >&2; exit 2 ;; esac
args=(status "$run_dir")
[ "$format" = --json ] && args+=(--json)
exec python3 -B "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_terminal_lifecycle.py" "${args[@]}"
