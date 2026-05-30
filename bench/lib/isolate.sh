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
#     reverse proxy (proxy.sh), which claude reaches via ANTHROPIC_BASE_URL and
#     which forwards only to api.anthropic.com
#   - with quantified cpu/memory/pids limits AND a hard wall-clock timeout
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
# CPU/memory raised (was 2/4g): a host diagnosis showed go-nezha completes the
# detect-only pipeline in ~21 min uncapped, but the 2-CPU/4g container is slow
# enough that it overran the old 1800s cap. Env-overridable for tuning.
readonly BENCH_CPUS="${BENCH_CPUS:-4}"
readonly BENCH_MEMORY="${BENCH_MEMORY:-8g}"
readonly BENCH_PIDS_LIMIT="512"
readonly BENCH_USER="65534:65534" # nobody:nogroup — non-root
readonly BENCH_SCRATCH="/scratch"
readonly BENCH_WORKDIR="/work"
readonly BENCH_OUTDIR="/out"     # writable mount: captured report lands here
readonly BENCH_MOUNTDIR="/bench" # the harness scripts, mounted read-only
readonly BENCH_WALLCLOCK_SECS="${BENCH_WALLCLOCK_SECS:-3600}"
# Runner model pinned for both arms (e.g. claude-opus-4-8). Empty = the CLI
# default. run.sh sets this from BENCH_RUNNER_MODEL_ID so the pinned model and
# the recorded provenance model_id stay identical.
readonly BENCH_RUNNER_MODEL="${BENCH_RUNNER_MODEL:-}"

# Egress: the container reaches the model API ONLY through the reverse proxy on
# the --internal bench-proxynet. claude (Bun-based) ignores HTTP(S)_PROXY env,
# so we point it at the proxy via ANTHROPIC_BASE_URL — claude treats the proxy
# as the API endpoint, and the proxy forwards only to api.anthropic.com.
readonly BENCH_CONTAINER_BASE_URL="http://${BENCH_PROXY_HOST:-bench-proxy}:${BENCH_PROXY_PORT:-8888}"

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
    # claude/Bun (and most tools) write incidental temp files to /tmp; under a
    # read-only root that fails silently. A wiped-on-exit tmpfs keeps the
    # hardening (no persistent writable surface) while giving them scratch.
    --tmpfs "/tmp:rw,mode=1777"
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
    # Pin the runner model inside the container (empty = CLI default).
    --env "BENCH_RUNNER_MODEL=${BENCH_RUNNER_MODEL}"
    # The dedicated key, by NAME only (value read by docker from the host env).
    --env "ANTHROPIC_API_KEY"
    # Point claude at the reverse proxy (it treats this as the API endpoint).
    # The proxy forwards only to api.anthropic.com; everything else is
    # unroutable on the --internal bench-proxynet.
    --env "ANTHROPIC_BASE_URL=${BENCH_CONTAINER_BASE_URL}"
    # Suppress claude's non-essential traffic (telemetry/auto-update/etc.) so it
    # contacts ONLY the API endpoint — any other host would hang on the
    # internal network.
    --env "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
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

  # Hard wall-clock cap: BENCH_WALLCLOCK_SECS is also passed INTO the container
  # as env, but env alone does not stop a hung process — a foreground `docker
  # run` with no timeout is exactly what let a stuck run hang. Wrap it in
  # `timeout` so a stuck container is SIGTERM'd (then SIGKILL'd after a grace
  # period) and surfaces as a non-zero exit, which run.sh maps to ERROR. Falls
  # back to no wrapper if neither timeout nor gtimeout is available.
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi
  if [[ -n "${timeout_bin}" ]]; then
    exec "${timeout_bin}" -k 30 "${BENCH_WALLCLOCK_SECS}" "${DOCKER_ARGV[@]}" "$@"
  fi
  echo "isolate.sh: warning: no timeout binary on PATH; running WITHOUT a hard wall-clock cap" >&2
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
