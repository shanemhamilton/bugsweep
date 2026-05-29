#!/usr/bin/env bash
#
# build.sh — build the bugsweep-bench analysis image reproducibly.
#
# Stages the bugsweep skill from a configurable source (default: the installed
# skill at ~/.claude/skills/bugsweep) into the build context at ./skill/, builds
# the image, and prints the resulting image id + the staged skill's commit so
# they can be recorded in the run provenance (run.sh reads the image id via
# `docker image inspect`).
#
# A locally-built image has no registry digest, so provenance records the image
# ID (sha256:...) — see bench/README.md "Provenance".
#
# usage:
#   bench/docker/build.sh                     # skill from ~/.claude/skills/bugsweep
#   BUGSWEEP_SKILL_SRC=/path/to/skill bench/docker/build.sh
#   BENCH_IMAGE_TAG=bugsweep-bench:pilot bench/docker/build.sh

set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOCKER_DIR

readonly IMAGE_TAG="${BENCH_IMAGE_TAG:-bugsweep-bench:latest}"
readonly PROXY_IMAGE_TAG="${BENCH_PROXY_IMAGE:-bugsweep-bench-proxy:latest}"
readonly SKILL_SRC="${BUGSWEEP_SKILL_SRC:-${HOME}/.claude/skills/bugsweep}"

die() {
  echo "build.sh: $*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
[[ -d "${SKILL_SRC}" ]] || die "bugsweep skill not found at ${SKILL_SRC} (set BUGSWEEP_SKILL_SRC)"
[[ -f "${SKILL_SRC}/SKILL.md" ]] || die "no SKILL.md under ${SKILL_SRC}; not a bugsweep skill dir"

# Stage the skill into the build context (docker COPY cannot reach outside it).
readonly STAGE="${DOCKER_DIR}/skill"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp -a "${SKILL_SRC}/." "${STAGE}/"

# Record the staged skill's provenance: a git commit if the source is a clone,
# else the VERSION file. This is what the leaderboard's `bugsweep @ <commit>`
# headline should reflect.
skill_commit="(unknown)"
if git -C "${SKILL_SRC}" rev-parse --short HEAD >/dev/null 2>&1; then
  skill_commit="$(git -C "${SKILL_SRC}" rev-parse --short HEAD)"
elif [[ -f "${SKILL_SRC}/VERSION" ]]; then
  skill_commit="v$(tr -d '[:space:]' <"${SKILL_SRC}/VERSION")"
fi

echo "build.sh: staging skill from ${SKILL_SRC} (commit ${skill_commit})"
docker build -t "${IMAGE_TAG}" "${DOCKER_DIR}"
image_id="$(docker image inspect --format '{{.Id}}' "${IMAGE_TAG}")"

# The CONNECT egress proxy image (no skill; independent build context).
echo "build.sh: building egress proxy image ${PROXY_IMAGE_TAG}"
docker build -f "${DOCKER_DIR}/Dockerfile.proxy" -t "${PROXY_IMAGE_TAG}" "${DOCKER_DIR}"
proxy_image_id="$(docker image inspect --format '{{.Id}}' "${PROXY_IMAGE_TAG}")"

cat <<EOF

build.sh: built
  ${IMAGE_TAG}
    image_id     = ${image_id}
    skill_commit = ${skill_commit}
  ${PROXY_IMAGE_TAG}
    image_id     = ${proxy_image_id}

Record these in the run provenance:
  export BENCH_CONTAINER_IMAGE_DIGEST="${image_id}"
  export BENCH_EGRESS_PROXY_IMAGE="${PROXY_IMAGE_TAG}@${proxy_image_id}"
  export BENCH_BUGSWEEP_COMMIT="${skill_commit}"
EOF
