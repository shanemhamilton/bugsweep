#!/usr/bin/env bash
#
# Build only from operator-supplied, already-verified artifacts. It never
# fetches installers, downloads CLIs, or reads an ambient CLI login.

set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOCKER_DIR

readonly IMAGE_TAG="${BENCH_IMAGE_TAG:-bugsweep-bench:latest}"
readonly PROXY_IMAGE_TAG="${BENCH_PROXY_IMAGE:-bugsweep-bench-proxy:latest}"
readonly BASE_IMAGE="${BENCH_BASE_IMAGE:?set a pinned BENCH_BASE_IMAGE}"
readonly CLAUDE_BIN="${BENCH_CLAUDE_CLI_BIN:?set BENCH_CLAUDE_CLI_BIN}"
readonly CLAUDE_SHA256="${BENCH_CLAUDE_CLI_SHA256:?set BENCH_CLAUDE_CLI_SHA256}"
readonly CODEX_BIN="${BENCH_CODEX_CLI_BIN:?set BENCH_CODEX_CLI_BIN}"
readonly CODEX_SHA256="${BENCH_CODEX_CLI_SHA256:?set BENCH_CODEX_CLI_SHA256}"
readonly CURRENT_SKILL_SRC="${BENCH_CURRENT_SKILL_SRC:?set BENCH_CURRENT_SKILL_SRC}"
readonly CURRENT_SKILL_REVISION="${BENCH_CURRENT_SKILL_REVISION:?set BENCH_CURRENT_SKILL_REVISION}"
readonly PREVIOUS_SKILL_SRC="${BENCH_PREVIOUS_SKILL_SRC:?set BENCH_PREVIOUS_SKILL_SRC}"
readonly PREVIOUS_SKILL_REVISION="${BENCH_PREVIOUS_SKILL_REVISION:?set BENCH_PREVIOUS_SKILL_REVISION}"
readonly PROXY_BASE_IMAGE="${BENCH_PROXY_BASE_IMAGE:?set a pinned BENCH_PROXY_BASE_IMAGE}"

die() {
  echo "build.sh: $*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
[[ "${BASE_IMAGE}" =~ @sha256:[a-f0-9]{64}$ ]] || die "BENCH_BASE_IMAGE must be pinned by sha256"
[[ "${PROXY_BASE_IMAGE}" =~ @sha256:[a-f0-9]{64}$ ]] || die "BENCH_PROXY_BASE_IMAGE must be pinned by sha256"
for value in "${CLAUDE_SHA256}" "${CODEX_SHA256}"; do [[ "${value}" =~ ^[a-f0-9]{64}$ ]] || die "binary digest must be lowercase sha256"; done
for binary in "${CLAUDE_BIN}" "${CODEX_BIN}"; do [[ "${binary}" == /* && -f "${binary}" && ! -L "${binary}" ]] || die "CLI must be an absolute regular file"; done
for skill in "${CURRENT_SKILL_SRC}" "${PREVIOUS_SKILL_SRC}"; do [[ "${skill}" == /* && -d "${skill}" && -f "${skill}/SKILL.md" ]] || die "skill snapshot must be an absolute directory with SKILL.md"; done

# Stage the skill into the build context (docker COPY cannot reach outside it).
readonly STAGE="${DOCKER_DIR}/stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/bin" "${STAGE}/arms/current_skill" "${STAGE}/arms/previous_release" "${STAGE}/arms/baseline" "${STAGE}/runners"
cp "${CLAUDE_BIN}" "${STAGE}/bin/claude"
cp "${CODEX_BIN}" "${STAGE}/bin/codex"
cp "${DOCKER_DIR}/bench-host-adapter" "${STAGE}/bench-host-adapter"
cp "${DOCKER_DIR}/../provider_proxy.py" "${STAGE}/provider_proxy.py"
cp "${DOCKER_DIR}/provider_proxy_entrypoint.sh" "${STAGE}/provider_proxy_entrypoint.sh"
cp -a "${DOCKER_DIR}/../runners/." "${STAGE}/runners/"
copy_snapshot() {
  python3 - "$1" "$2" <<'PY'
import os, shutil, stat, sys
source, destination = map(os.path.realpath, sys.argv[1:])
for directory, dirs, names in os.walk(source):
  dirs[:] = sorted(d for d in dirs if d != '.git')
  relative = os.path.relpath(directory, source)
  out_dir = destination if relative == '.' else os.path.join(destination, relative)
  os.makedirs(out_dir, exist_ok=True)
  for name in sorted(names):
    path = os.path.join(directory, name)
    if os.path.islink(path) or not stat.S_ISREG(os.stat(path, follow_symlinks=False).st_mode):
      raise SystemExit('skill snapshot contains a non-regular file')
    shutil.copyfile(path, os.path.join(out_dir, name), follow_symlinks=False)
PY
}
copy_snapshot "${CURRENT_SKILL_SRC}" "${STAGE}/arms/current_skill"
copy_snapshot "${PREVIOUS_SKILL_SRC}" "${STAGE}/arms/previous_release"
printf 'no skill is mounted for this arm\n' >"${STAGE}/arms/baseline/NO_SKILL"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
[[ "$(sha256 "${STAGE}/bin/claude")" == "${CLAUDE_SHA256}" ]] || die "Claude CLI digest mismatch"
[[ "$(sha256 "${STAGE}/bin/codex")" == "${CODEX_SHA256}" ]] || die "Codex CLI digest mismatch"
proxy_source_sha="$(sha256 "${STAGE}/provider_proxy.py")"
adapter_sha="$(sha256 "${STAGE}/bench-host-adapter")"
arms_json="$(python3 - "${STAGE}/arms" "${CURRENT_SKILL_REVISION}" "${PREVIOUS_SKILL_REVISION}" <<'PY'
import hashlib, json, os, sys
root, current, previous = sys.argv[1:]
def tree(name):
  files = {}
  base = os.path.join(root, name)
  for directory, dirs, names in os.walk(base):
    dirs[:] = sorted(d for d in dirs if d != '.git')
    for item in sorted(names):
      path = os.path.join(directory, item); rel = os.path.relpath(path, base)
      if os.path.islink(path): raise SystemExit('symlink in arm snapshot')
      files[rel] = hashlib.sha256(open(path, 'rb').read()).hexdigest()
  return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
print(json.dumps({'baseline': {'skill_revision':'none','skill_content_sha256':tree('baseline')}, 'current': {'skill_revision':current,'skill_content_sha256':tree('current_skill')}, 'previous': {'skill_revision':previous,'skill_content_sha256':tree('previous_release')}}, sort_keys=True, separators=(',', ':')))
PY
)"
arms_sha="$(printf '%s' "${arms_json}" | shasum -a 256 | awk '{print $1}')"
printf '%s' "${arms_json}" >"${STAGE}/arms.json"

echo "build.sh: staging verified local binaries and arm snapshots"
docker build -f "${DOCKER_DIR}/Dockerfile" -t "${IMAGE_TAG}" \
  --build-arg "BENCH_BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "CLAUDE_CLI_SHA256=${CLAUDE_SHA256}" \
  --build-arg "CODEX_CLI_SHA256=${CODEX_SHA256}" \
  --build-arg "ADAPTER_SHA256=${adapter_sha}" \
  --build-arg "ARMS_SHA256=${arms_sha}" \
  "${STAGE}"
image_id="$(docker image inspect --format '{{.Id}}' "${IMAGE_TAG}")"

echo "build.sh: staging the source-verified standard-library provider proxy"
docker build -f "${DOCKER_DIR}/Dockerfile.proxy" -t "${PROXY_IMAGE_TAG}" \
  --build-arg "BENCH_PROXY_BASE_IMAGE=${PROXY_BASE_IMAGE}" \
  --build-arg "PROXY_SOURCE_SHA256=${proxy_source_sha}" \
  "${STAGE}"
proxy_image_id="$(docker image inspect --format '{{.Id}}' "${PROXY_IMAGE_TAG}")"

cat <<EOF

build.sh: built
  ${IMAGE_TAG}
    image_id     = ${image_id}
    adapter_sha256 = ${adapter_sha}
    arms_sha256    = ${arms_sha}
  ${PROXY_IMAGE_TAG}
    image_id     = ${proxy_image_id}
    proxy_source_sha256 = ${proxy_source_sha}

Record these in the run provenance:
  export BENCH_CONTAINER_IMAGE_DIGEST="${image_id}"
  benchmark_profile.arms = ${arms_json}
EOF
