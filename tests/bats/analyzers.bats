#!/usr/bin/env bats
#
# Contract guards for the R4 analyzer importer. Runtime coverage is in the
# pure Python tests because this session prohibits Git-backed shell fixtures.

ANALYZERS_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/analyzers.sh"
NORM_PY="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/_analyzer_norm.py"

@test "analyzers.sh imports coordinator SARIF and never auto-launches tools" {
  grep -q 'analyzer-imports.json' "$ANALYZERS_SH"
  grep -q 'SARIF_IMPORT_MANIFEST' "$ANALYZERS_SH"
  grep -q 'analysis_ran":false' "$ANALYZERS_SH"
  ! grep -q -- '--config auto' "$ANALYZERS_SH"
  ! grep -q 'command -v .*semgrep' "$ANALYZERS_SH"
  ! grep -q 'command -v .*codeql' "$ANALYZERS_SH"
}

@test "import entrypoint records data-only imported results and configured availability" {
  grep -q 'import_sarif_results' "$NORM_PY"
  grep -q 'trusted_context' "$NORM_PY"
  grep -q 'EXECUTION_PREPARATION_PATH' "$NORM_PY"
  grep -q 'analyzer_configs' "$NORM_PY"
}
