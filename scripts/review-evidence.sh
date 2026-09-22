#!/usr/bin/env bash
# Coordinator-only entry point; does not source target-repository state.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$script_dir/_review_evidence.py" "$@"
