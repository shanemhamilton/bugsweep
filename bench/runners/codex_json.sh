#!/usr/bin/env bash
# Native Codex Responses-API adapter. The provider endpoint is the owned proxy.
set -euo pipefail

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
model="$1" prompt="$2" arm="$3"
[[ -n "${CODEX_BENCH_BASE_URL:-}" && "${BENCH_INERT_CLIENT_ID:-}" == "benchmark-inert-client-credential" && -n "${BUGSWEEP_OUTPUT_DIR:-}" ]] || {
  echo "codex adapter requires proxy endpoint and inert client credential" >&2; exit 64; }
export OPENAI_API_KEY="${BENCH_INERT_CLIENT_ID}"
readonly_sandbox=(--sandbox read-only)
loaded_skill_json="null"
export CODEX_HOME="${TMPDIR:-/tmp}/codex-bench-home"
mkdir -p "${CODEX_HOME}"
case "${arm}" in
  current_skill | previous_release)
    skill_root="/opt/bugsweep-benchmark-arms/${arm}"
    [[ -f "${skill_root}/SKILL.md" ]] || { echo "missing pinned ${arm} SKILL.md" >&2; exit 65; }
    skill_sha="$(sha256 "${skill_root}/SKILL.md" | awk '{print $1}')"
    loaded_skill_json="\"${skill_sha}\""
    skill_excerpt="$(head -c 49152 "${skill_root}/SKILL.md")"
    prompt+=$'\n\nIMMUTABLE BENCHMARK SKILL EXCERPT (detect-only methodology only; no operational commands):\nsha256='"${skill_sha}"$'\n---\n'"${skill_excerpt}"
    ;;
  no_skill_baseline) ;;
  review)
    # Start with an empty client home and use the native read-only sandbox.
    # No benchmark arm, host configuration, or rules are available here.
    export CODEX_HOME="${TMPDIR:-/tmp}/codex-review-home"
    mkdir -p "${CODEX_HOME}"
    ;;
  *) echo "unsupported arm" >&2; exit 64 ;;
esac
if [[ "${arm}" == "review" ]]; then
  exec codex exec --json --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check \
    "${readonly_sandbox[@]}" \
    -c "model=${model}" -c 'model_provider=benchmark' \
    -c "model_providers.benchmark.base_url=${CODEX_BENCH_BASE_URL}" \
    -c 'model_providers.benchmark.wire_api=responses' \
    -c 'model_providers.benchmark.requires_openai_auth=false' \
    -c 'model_providers.benchmark.supports_websockets=false' \
    "${prompt}"
fi
prompt_sha="$(printf '%s' "${prompt}" | sha256 | awk '{print $1}')"
marker="${BUGSWEEP_OUTPUT_DIR}/first-finding-unix-seconds.txt"
codex exec --json --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check \
  "${readonly_sandbox[@]}" \
  -c "model=${model}" -c 'model_provider=benchmark' \
  -c "model_providers.benchmark.base_url=${CODEX_BENCH_BASE_URL}" \
  -c 'model_providers.benchmark.wire_api=responses' \
  -c 'model_providers.benchmark.requires_openai_auth=false' \
  -c 'model_providers.benchmark.supports_websockets=false' \
  "${prompt}" | tee "${BUGSWEEP_OUTPUT_DIR}/response.jsonl" | awk -v marker="${marker}" '
      /FINDING:/ && !seen { command="date +%s"; command | getline now; close(command); print now > marker; close(marker); seen=1 } { print }
    '
first="null"
[[ -f "${marker}" ]] && first="$(cat "${marker}")"
printf '{"effective_prompt_sha256":"%s","loaded_skill_sha256":%s,"first_finding_unix_seconds":%s}\n' "${prompt_sha}" "${loaded_skill_json}" "${first}" >"${BUGSWEEP_OUTPUT_DIR}/adapter-metadata.json"
