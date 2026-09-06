#!/usr/bin/env bash
# Import coordinator-captured SARIF before the hunt. Source and settings come
# only from the frozen run; this wrapper never runs a project or Git command.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
run_dir="${1:-}"
if [ -z "$run_dir" ] || [ ! -d "$run_dir" ]; then
  echo 'usage: analyzers.sh <RUN_DIR>' >&2
  exit 2
fi
run_dir="$(CDPATH='' cd -- "$run_dir" && pwd -P)"
hits_path="${run_dir}/analyzer-hits.json"
if RUN_DIR="$run_dir" SARIF_IMPORT_MANIFEST="${run_dir}/analyzer-imports.json" \
   EXECUTION_PREPARATION_PATH="${run_dir}/execution-preparation.json" \
   SOURCE_DIGESTS_PATH="${run_dir}/source-digests.json" \
   python3 -B "${SCRIPT_DIR}/_analyzer_norm.py" "$hits_path"; then
  hit_count="$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["count"])' "$hits_path")"
  printf '{"event":"analyzers","data_only":true,"analysis_ran":false,"hits":%s}\n' "$hit_count" \
    >> "${run_dir}/ledger.jsonl"
  printf 'analyzers: wrote %s (%s imported hints)\n' "$hits_path" "$hit_count" >&2
else
  code=$?
  if [ "$code" -eq 10 ]; then exit 0; fi
  echo 'analyzers: import unavailable; do not interpret this as a zero-hit scan' >&2
  exit "$code"
fi
