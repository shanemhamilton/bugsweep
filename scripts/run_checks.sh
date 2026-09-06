#!/usr/bin/env bash
# Structured suite gate. Usage: `baseline RUN_DIR` or `verify RUN_DIR`.
# The check plan is coordinator-authored at RUN_DIR/check-plan.json; execution
# always goes through the shared provider and errors fail closed.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$script_dir/_proof.py" checks "$@"
