#!/usr/bin/env bash
#
# proxy.sh — the host-side, key-injecting egress proxy for the bench harness.
#
# The dedicated, revocable model-API key lives ONLY here, on the host, never in
# the analysis container. The container reaches the network solely through this
# proxy on the `bench-proxynet` docker network. The proxy:
#   (a) binds the `bench-proxynet` docker network (the only egress path),
#   (b) enforces an EXACT-host upstream allow-list (default api.anthropic.com;
#       extend via BENCH_PROXY_ALLOW — comma/space separated exact hostnames;
#       no substring/suffix matching),
#   (c) refuses CONNECT tunneling (no opaque TLS tunnel to arbitrary hosts),
#   (d) strips inbound client-supplied auth headers and injects the dedicated
#       key read from the BENCH_PROXY_KEY env var (the value is never printed),
#   (e) writes a per-run usage log (request count + token volume) to
#       results/<run-id>/proxy-usage.json so the accepted budget-abuse residual
#       is observable.
#
# Modes:
#   proxy.sh --print-cmd        Print (do NOT launch) the proxy wiring/config so
#                               the Tier-A bats suite can assert the security
#                               wiring without starting a live forwarder.
#   proxy.sh start <run-id>     Initialize results/<run-id>/proxy-usage.json and
#                               (Tier-B) launch the forwarder.
#   proxy.sh stop <run-id>      Tear the forwarder down.
#
# LIVE forwarding is Tier-B (out of scope for WU0): `start` here initializes the
# usage log and prints the wiring; it does not yet proxy real traffic.
#
# Fails closed (exit 1) if docker is absent (BENCH_FAKE_NO_DOCKER=1 simulates
# absence for the bats suite).

set -euo pipefail

readonly BENCH_NETWORK="bench-proxynet"
readonly BENCH_PROXY_DEFAULT_ALLOW="api.anthropic.com"
readonly RESULTS_DIR="${BENCH_RESULTS_DIR:-results}"

die() {
  echo "proxy.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  proxy.sh --print-cmd
  proxy.sh start <run-id>
  proxy.sh stop  <run-id>
EOF
  exit 1
}

require_docker() {
  if [[ "${BENCH_FAKE_NO_DOCKER:-0}" == "1" ]]; then
    die "docker runtime not found on PATH (BENCH_FAKE_NO_DOCKER=1); cannot bind ${BENCH_NETWORK} egress proxy — refusing to run"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "docker runtime not found on PATH; cannot bind ${BENCH_NETWORK} egress proxy — refusing to run"
  fi
}

# Compute the effective exact-host allow-list: the default plus any hosts in
# BENCH_PROXY_ALLOW (comma- or space-separated). Echoes a comma-joined list.
allow_hosts() {
  local extra="${BENCH_PROXY_ALLOW:-}"
  local hosts="${BENCH_PROXY_DEFAULT_ALLOW}"
  if [[ -n "${extra}" ]]; then
    # Normalize separators to spaces, then append.
    local normalized="${extra//,/ }"
    local h
    for h in ${normalized}; do
      [[ -n "${h}" ]] && hosts="${hosts},${h}"
    done
  fi
  echo "${hosts}"
}

# Print the proxy wiring/config. Never prints the BENCH_PROXY_KEY value — only
# the NAME of the variable the key is injected from.
print_cmd() {
  require_docker
  local hosts
  hosts="$(allow_hosts)"
  cat <<EOF
# bench egress proxy wiring (dry-run; no live forwarder launched)
network=${BENCH_NETWORK}
allow_hosts=${hosts}
match_mode=exact_host
refuse_connect=true
strip_client_auth=true
inject_key_from=BENCH_PROXY_KEY
usage_log=${RESULTS_DIR}/<run-id>/proxy-usage.json
EOF
}

# Initialize the per-run usage log to a zeroed counter object.
init_usage_log() {
  local run_id="$1"
  local out_dir="${RESULTS_DIR}/${run_id}"
  mkdir -p "${out_dir}"
  local log="${out_dir}/proxy-usage.json"
  python3 - "$log" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"requests": 0, "tokens": 0}, fh, indent=2)
    fh.write("\n")
PY
  echo "${log}"
}

cmd_start() {
  [[ $# -eq 1 ]] || usage
  local run_id="$1"
  require_docker
  local log
  log="$(init_usage_log "${run_id}")"
  echo "proxy.sh: initialized usage log at ${log}"
  echo "proxy.sh: allow_hosts=$(allow_hosts) network=${BENCH_NETWORK} (live forwarder is Tier-B; not launched in WU0)"
}

cmd_stop() {
  [[ $# -eq 1 ]] || usage
  local run_id="$1"
  require_docker
  echo "proxy.sh: stopped egress proxy for run ${run_id} (no live forwarder in WU0)"
}

main() {
  [[ $# -ge 1 ]] || usage
  case "$1" in
    --print-cmd)
      print_cmd
      ;;
    start)
      shift
      cmd_start "$@"
      ;;
    stop)
      shift
      cmd_stop "$@"
      ;;
    -h | --help)
      usage
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
