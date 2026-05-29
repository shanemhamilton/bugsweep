#!/usr/bin/env bash
#
# isolate.sh — build the `docker run` argv that executes an untrusted/vulnerable
# clone inside a hardened, egress-allow-listed container.
#
# The container is the primary mitigation for arbitrary code execution from the
# repos under analysis (see docs/plans/2026-05-28-bugsweep-bench-design.md
# "Security model"). It runs:
#   - non-root          (--user 65534:65534, the `nobody` uid/gid)
#   - read-only root    (--read-only) with a writable tmpfs scratch (/scratch)
#   - the host clone mounted READ-ONLY at /work (entrypoint copies it to a
#     writable /scratch/repo); the captured report on a writable /out mount
#   - on the --internal bench-proxynet network only — its sole egress is the
#     CONNECT allow-list proxy (proxy.sh), reachable as bench-proxy:8888
#   - with quantified cpu/memory/pids limits
#   - with the dedicated ANTHROPIC_API_KEY injected BY NAME (key-in-container
#     model — see proxy.sh); NO other host env (no OpenAI judge key, no other
#     *_API_KEY / *_TOKEN / *_KEY) is forwarded.
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
readonly BENCH_OUTDIR="/out"     # writable mount: captured report lands here
readonly BENCH_MOUNTDIR="/bench" # the harness scripts, mounted read-only
readonly BENCH_WALLCLOCK_SECS="${BENCH_WALLCLOCK_SECS:-1800}"

# Egress: the container reaches the model API ONLY through the proxy on the
# --internal bench-proxynet (proxy.sh launches it as `bench-proxy:8888`).
readonly BENCH_PROXY_URL="http://${BENCH_PROXY_HOST:-bench-proxy}:${BENCH_PROXY_PORT:-8888}"

# The bench harness dir (parent of lib/), mounted read-only at /bench so the
# runner scripts are available in the container without baking them into the
# image (they are apparatus, not the subject under test).
_ISOLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BENCH_HARNESS_DIR="${_ISOLATE_DIR%/lib}"

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
# Key handling (key-in-container model — see proxy.sh / bench/README.md): the
# ONE permitted key passthrough is the dedicated, revocable ANTHROPIC_API_KEY,
# injected BY NAME (`--env ANTHROPIC_API_KEY`) so docker reads the value from
# the host env and the value never appears in the argv. NO other host env is
# forwarded, so the OpenAI judge key, *_TOKEN, and other *_KEY values stay out.
# Egress is bounded by the CONNECT allow-list proxy, not by withholding the key.
build_argv() {
  local image="$1" clone_dir="$2"
  local out_dir="${BENCH_OUT:-/tmp/bench-out}"
  DOCKER_ARGV=(
    docker run --rm
    --network="${BENCH_NETWORK}"
    --read-only
    --tmpfs "${BENCH_SCRATCH}:rw,mode=1777"
    --cpus="${BENCH_CPUS}"
    --memory="${BENCH_MEMORY}"
    --pids-limit="${BENCH_PIDS_LIMIT}"
    --user "${BENCH_USER}"
    --cap-drop=ALL
    --security-opt=no-new-privileges
    # Clone stays READ-ONLY (pristine); the entrypoint copies it to a writable
    # tmpfs (/scratch/repo) so detect-only bugsweep can write .bugsweep/ + cut
    # its throwaway branch. /out is the writable report sink; /bench is the
    # apparatus, read-only.
    --volume "${clone_dir}:${BENCH_WORKDIR}:ro"
    --volume "${out_dir}:${BENCH_OUTDIR}"
    --volume "${BENCH_HARNESS_DIR}:${BENCH_MOUNTDIR}:ro"
    --workdir "${BENCH_WORKDIR}"
    # allow_web_research forced off so a no-network container cannot silently
    # degrade (design doc line 99).
    --env "BUGSWEEP_ALLOW_WEB_RESEARCH=false"
    --env "BENCH_WALLCLOCK_SECS=${BENCH_WALLCLOCK_SECS}"
    # The dedicated key, by NAME only (value read by docker from the host env).
    --env "ANTHROPIC_API_KEY"
    # Egress only via the proxy; everything else is unroutable on bench-proxynet.
    --env "HTTPS_PROXY=${BENCH_PROXY_URL}"
    --env "HTTP_PROXY=${BENCH_PROXY_URL}"
    --env "https_proxy=${BENCH_PROXY_URL}"
    --env "http_proxy=${BENCH_PROXY_URL}"
    --env "NO_PROXY=localhost,127.0.0.1"
    --env "no_proxy=localhost,127.0.0.1"
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
