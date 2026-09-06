#!/usr/bin/env bash
# Structured executable repro gate. The coordinator supplies phase-specific
# requests: `pre RUN_DIR BUG_ID PRE_REQUEST.json`, then `post RUN_DIR BUG_ID
# POST_REQUEST.json`. For a combined final tree, use `reverify RUN_DIR BUG_ID
# REVERIFY_REQUEST.json`; it writes separate evidence and preserves the proof.
# `_proof.py` validates each request and uses only the
# shared execution provider; malformed or legacy calls fail closed.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$script_dir/_proof.py" repro "$@"
