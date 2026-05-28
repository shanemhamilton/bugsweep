#!/usr/bin/env bash
#
# isolate.sh — build the `docker run` argv that executes an untrusted/vulnerable
# clone inside a hardened, key-free, no-network-except-proxy container.
#
# The container is the primary mitigation for arbitrary code execution from the
# repos under analysis (see docs/plans/2026-05-28-bugsweep-bench-design.md
# "Security model"). It runs:
#   - non-root          (--user 65534:65534, the `nobody` uid/gid)
#   - read-only root    (--read-only) with a writable tmpfs scratch (/scratch)
#   - the clone mounted READ-ONLY at /work
#   - on the bench-proxynet docker network only (no other egress)
#   - with quantified cpu/memory/pids limits
#   - with NO key-shaped environment variable (no *_API_KEY / *_TOKEN / *_KEY);
#     the dedicated key lives only in the host egress proxy, never here.
#
# Modes:
#   isolate.sh --print-cmd <image> [clone-dir]
#       Print (do NOT execute) the docker run argv that WOULD be used. Used by
#       the Tier-A bats suite to assert argument construction without launching
#       a container.
#   isolate.sh <image> [clone-dir] -- <cmd...>
#       Execute the container running <cmd...> against the clone.
#
# Fails closed (exit 1) if docker is not available. The bats suite exercises
# the fail-closed path via BENCH_FAKE_NO_DOCKER=1 (simulated absence) so docker
# need not be uninstalled.

set -euo pipefail

# --- tunables (quantified limits asserted by the bats suite) ----------------
readonly BENCH_NETWORK="bench-proxynet"
readonly BENCH_CPUS="2"
readonly BENCH_MEMORY="4g"
readonly BENCH_PIDS_LIMIT="512"
readonly BENCH_USER="65534:65534" # nobody:nogroup — non-root
readonly BENCH_SCRATCH="/scratch"
readonly BENCH_WORKDIR="/work"
readonly BENCH_WALLCLOCK_SECS="${BENCH_WALLCLOCK_SECS:-1800}"

die() {
  echo "isolate.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  isolate.sh --print-cmd <image> [clone-dir]
  isolate.sh <image> [clone-dir] -- <command...>
EOF
  exit 1
}

# Verify the docker runtime is available, else fail closed. BENCH_FAKE_NO_DOCKER
# is honored BEFORE probing PATH so tests can simulate absence without removing
# docker from the host.
require_docker() {
  if [[ "${BENCH_FAKE_NO_DOCKER:-0}" == "1" ]]; then
    die "docker runtime not found on PATH (BENCH_FAKE_NO_DOCKER=1); cannot isolate untrusted code — refusing to run"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "docker runtime not found on PATH; cannot isolate untrusted code — refusing to run"
  fi
}

# Build the docker run argv into the global array DOCKER_ARGV.
#
# Deliberately key-free: we pass NO host environment into the container, so no
# *_API_KEY / *_TOKEN / *_KEY can leak. Only explicit, non-secret env is set.
build_argv() {
  local image="$1" clone_dir="$2"
  DOCKER_ARGV=(
    docker run --rm
    --network="${BENCH_NETWORK}"
    --read-only
    --tmpfs "${BENCH_SCRATCH}"
    --cpus="${BENCH_CPUS}"
    --memory="${BENCH_MEMORY}"
    --pids-limit="${BENCH_PIDS_LIMIT}"
    --user "${BENCH_USER}"
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --volume "${clone_dir}:${BENCH_WORKDIR}:ro"
    --workdir "${BENCH_WORKDIR}"
    # Non-secret env only. allow_web_research is forced off so a no-network
    # container cannot silently degrade (design doc line 99). No host env is
    # forwarded, so no key-shaped variable can reach the container.
    --env "BUGSWEEP_ALLOW_WEB_RESEARCH=false"
    --env "BENCH_WALLCLOCK_SECS=${BENCH_WALLCLOCK_SECS}"
    "${image}"
  )
}

print_cmd() {
  [[ $# -ge 1 ]] || usage
  require_docker
  local image="$1"
  local clone_dir="${2:-${BENCH_CLONE:-/tmp/bench-clone}}"
  build_argv "${image}" "${clone_dir}"
  printf '%s ' "${DOCKER_ARGV[@]}"
  printf '\n'
}

run_container() {
  require_docker
  local image="$1"
  shift
  local clone_dir="${BENCH_CLONE:-/tmp/bench-clone}"
  # Optional positional clone-dir before the `--` command separator.
  if [[ $# -ge 1 && "$1" != "--" ]]; then
    clone_dir="$1"
    shift
  fi
  [[ "${1:-}" == "--" ]] || usage
  shift
  build_argv "${image}" "${clone_dir}"
  exec "${DOCKER_ARGV[@]}" "$@"
}

main() {
  [[ $# -ge 1 ]] || usage
  case "$1" in
    --print-cmd)
      shift
      print_cmd "$@"
      ;;
    -h | --help)
      usage
      ;;
    *)
      run_container "$@"
      ;;
  esac
}

main "$@"
