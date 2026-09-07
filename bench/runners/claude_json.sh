#!/usr/bin/env bash
# Native Claude structured-output adapter. Called only by the trusted executor.
set -euo pipefail

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
model="$1" prompt="$2" arm="$3"
[[ -n "${ANTHROPIC_BASE_URL:-}" && "${BENCH_INERT_CLIENT_ID:-}" == "benchmark-inert-client-credential" && -n "${BUGSWEEP_OUTPUT_DIR:-}" ]] || {
  echo "claude adapter requires proxy endpoint and inert client credential" >&2; exit 64; }
export ANTHROPIC_API_KEY="${BENCH_INERT_CLIENT_ID}"
allowed_tools="Read"
loaded_skill_json="null"
export HOME="${TMPDIR:-/tmp}/claude-bench-home"
mkdir -p "${HOME}"
case "${arm}" in
  current_skill | previous_release)
    # The selected immutable SKILL.md is inserted into the native prompt. This
    # avoids depending on ambient client skill discovery and keeps its digest
    # visible in the captured invocation command/prompt provenance.
    skill_root="/opt/bugsweep-benchmark-arms/${arm}"
    [[ -f "${skill_root}/SKILL.md" ]] || { echo "missing pinned ${arm} SKILL.md" >&2; exit 65; }
    skill_sha="$(sha256 "${skill_root}/SKILL.md" | awk '{print $1}')"
    loaded_skill_json="\"${skill_sha}\""
    skill_excerpt="$(head -c 49152 "${skill_root}/SKILL.md")"
    prompt+=$'\n\nIMMUTABLE BENCHMARK SKILL EXCERPT (detect-only methodology only; no operational commands):\nsha256='"${skill_sha}"$'\n---\n'"${skill_excerpt}"
    ;;
  no_skill_baseline) ;;
  review)
    # Review has no arm or user configuration.
    export HOME="${TMPDIR:-/tmp}/claude-review-home"
    mkdir -p "${HOME}"
    allowed_tools="Read"
    ;;
  *) echo "unsupported arm" >&2; exit 64 ;;
esac
if [[ "${arm}" == "review" ]]; then
  exec claude -p "${prompt}" --model "${model}" --output-format stream-json --verbose \
    --allowedTools "${allowed_tools}" --permission-mode default
fi
prompt_sha="$(printf '%s' "${prompt}" | sha256 | awk '{print $1}')"
marker="${BUGSWEEP_OUTPUT_DIR}/first-finding-unix-seconds.txt"
claude -p "${prompt}" --model "${model}" --output-format stream-json --verbose \
  --allowedTools "${allowed_tools}" --permission-mode default \
  | tee "${BUGSWEEP_OUTPUT_DIR}/response.jsonl" | awk -v marker="${marker}" '
      /FINDING:/ && !seen { command="date +%s"; command | getline now; close(command); print now > marker; close(marker); seen=1 } { print }
    '
first="null"
[[ -f "${marker}" ]] && first="$(cat "${marker}")"
printf '{"effective_prompt_sha256":"%s","loaded_skill_sha256":%s,"first_finding_unix_seconds":%s}\n' "${prompt_sha}" "${loaded_skill_json}" "${first}" >"${BUGSWEEP_OUTPUT_DIR}/adapter-metadata.json"
