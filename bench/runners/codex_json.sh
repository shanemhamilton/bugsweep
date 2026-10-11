#!/usr/bin/env bash
# Native Codex Responses-API adapter. The provider endpoint is the owned proxy.
set -euo pipefail
model="$1" prompt="$2" arm="$3"
[[ -n "${CODEX_BENCH_BASE_URL:-}" && "${BENCH_INERT_CLIENT_ID:-}" == "benchmark-inert-client-credential" && -n "${BUGSWEEP_OUTPUT_DIR:-}" ]] || {
  echo "codex adapter requires proxy endpoint and inert client credential" >&2; exit 64; }
export OPENAI_API_KEY="${BENCH_INERT_CLIENT_ID}"
readonly_sandbox=(--sandbox read-only)
loaded_skill_json="null"
export CODEX_HOME="${TMPDIR:-/tmp}/codex-bench-home"
mkdir -p "${CODEX_HOME}"
sha256_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi | awk '{print $1}'
}
case "${arm}" in
  current_skill | previous_release)
    skill_root="/opt/bugsweep-benchmark-arms/${arm}"
    [[ -f "${skill_root}/SKILL.md" ]] || { echo "missing pinned ${arm} SKILL.md" >&2; exit 65; }
    skill_sha="$(sha256_digest "${skill_root}/SKILL.md")"
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
prompt_sha="$(printf '%s' "${prompt}" | sha256_digest)"
codex exec --json --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check \
  "${readonly_sandbox[@]}" \
  -c "model=${model}" -c 'model_provider=benchmark' \
  -c "model_providers.benchmark.base_url=${CODEX_BENCH_BASE_URL}" \
  -c 'model_providers.benchmark.wire_api=responses' \
  -c 'model_providers.benchmark.requires_openai_auth=false' \
  -c 'model_providers.benchmark.supports_websockets=false' \
  "${prompt}" | tee "${BUGSWEEP_OUTPUT_DIR}/response.jsonl"
python3 - "${BUGSWEEP_OUTPUT_DIR}/response.jsonl" "${BUGSWEEP_OUTPUT_DIR}/candidate-events.json" <<'PY'
import json, sys, time
source, destination = sys.argv[1:]
events = []
for line in open(source, encoding="utf-8"):
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        continue
    item = value.get("item") if value.get("type") == "item.completed" else None
    text = item.get("text") if isinstance(item, dict) and item.get("type") == "agent_message" else None
    if not isinstance(text, str):
        continue
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        continue
    for candidate in payload.get("candidates", []) if isinstance(payload, dict) else []:
        if isinstance(candidate, dict) and isinstance(candidate.get("bug_id"), str) and candidate["bug_id"].strip():
            events.append({"capture_source": "adapter", "capture_granularity": "adapter_completion", "candidate_id": candidate["bug_id"], "captured_at_unix_seconds": time.time()})
with open(destination, "w", encoding="utf-8") as stream:
    json.dump(events, stream, separators=(",", ":"))
PY
events_sha="$(sha256_digest "${BUGSWEEP_OUTPUT_DIR}/candidate-events.json")"
printf '{"effective_prompt_sha256":"%s","loaded_skill_sha256":%s,"candidate_events_sha256":"%s"}\n' "${prompt_sha}" "${loaded_skill_json}" "${events_sha}" >"${BUGSWEEP_OUTPUT_DIR}/adapter-metadata.json"
