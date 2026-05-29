#!/usr/bin/env bash
#
# proxy.sh — the egress REVERSE proxy for the bench harness.
#
# Isolation model (key-in-container — see bench/README.md "Security model"): the
# dedicated, revocable model-API key lives INSIDE the analysis container, but
# that container sits on an --internal docker network with NO internet. Its only
# path out is this proxy, an nginx reverse proxy that:
#   (a) straddles two networks — `bench-proxynet` (--internal; the analysis
#       container's only neighbour) and `bench-egressnet` (its path to the
#       internet),
#   (b) forwards EVERY request to a single hardcoded upstream,
#       https://api.anthropic.com, and nowhere else — so the container can reach
#       the model API and nothing else,
#   (c) is what claude actually uses: the container is pointed at this proxy via
#       ANTHROPIC_BASE_URL (the `claude` CLI runs on Bun and ignores
#       HTTP(S)_PROXY env, so a CONNECT forward proxy would never be used),
#   (d) writes a per-run usage log (forwarded-request count) to
#       results/<run-id>/proxy-usage.json so the accepted budget-abuse residual
#       is observable, and NEVER logs the Authorization header.
#
# The claude->proxy leg is plaintext on the private --internal network, so the
# proxy sees the key. That is no new exposure: the key is already in the
# container (key-in-container model), and egress is still restricted to the
# model API by the internal network + the hardcoded upstream.
#
# Modes:
#   proxy.sh --print-cmd        Print (do NOT launch) the proxy wiring so the
#                               Tier-A bats suite can assert it without starting
#                               a live forwarder.
#   proxy.sh start <run-id>     Create the networks, launch nginx, and
#                               initialize results/<run-id>/proxy-usage.json.
#   proxy.sh stop <run-id>      Record the forwarded-request count, tear nginx
#                               down.
#
# BENCH_PROXY_NO_LAUNCH=1 (TEST-ONLY) initializes the usage log + prints wiring
# without creating networks or launching nginx (keeps Tier-A container-free). It
# MUST NOT be set for a real run.
#
# Fails closed (exit 1) if docker is absent (BENCH_FAKE_NO_DOCKER=1 simulates
# absence for the bats suite).

set -euo pipefail

readonly BENCH_NETWORK="bench-proxynet"           # --internal: analysis container's only neighbour
readonly BENCH_EGRESS_NETWORK="bench-egressnet"   # normal bridge: the proxy's path to the internet
readonly BENCH_UPSTREAM_HOST="api.anthropic.com"  # the ONLY upstream nginx forwards to
readonly BENCH_PROXY_IMAGE="${BENCH_PROXY_IMAGE:-bugsweep-bench-proxy:latest}"
readonly BENCH_PROXY_CONTAINER="bench-proxy"
readonly BENCH_PROXY_PORT="8888"
# What the analysis container sets ANTHROPIC_BASE_URL to (kept in sync with
# isolate.sh, which injects it).
readonly BENCH_CONTAINER_BASE_URL="http://${BENCH_PROXY_CONTAINER}:${BENCH_PROXY_PORT}"
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

# Resolve a (possibly relative) path to an absolute one for docker bind mounts.
abs_path() {
  local p="$1"
  case "${p}" in
    /*) echo "${p}" ;;
    *) echo "$(pwd)/${p}" ;;
  esac
}

# Print the proxy wiring. Never prints any key — the key is not handled here;
# claude sends it through the plaintext leg, which nginx forwards but does not
# log (the access-log format omits the Authorization header).
print_cmd() {
  require_docker
  cat <<EOF
# bench egress reverse-proxy wiring (dry-run; no live forwarder launched)
network=${BENCH_NETWORK}
network_internal=true
egress_network=${BENCH_EGRESS_NETWORK}
mode=reverse_proxy
upstream=${BENCH_UPSTREAM_HOST}
container_base_url=${BENCH_CONTAINER_BASE_URL}
key_in_container=true
proxy_image=${BENCH_PROXY_IMAGE}
listen_port=${BENCH_PROXY_PORT}
usage_log=${RESULTS_DIR}/<run-id>/proxy-usage.json
EOF
}

# Initialize the per-run usage log. The reverse proxy forwards opaque HTTPS
# bodies, so it records the forwarded-request count + any upstream errors.
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
    json.dump({"api_requests": 0, "upstream_errors": 0}, fh, indent=2)
    fh.write("\n")
PY
  echo "${log}"
}

# Write the nginx reverse-proxy config into the per-run config dir. Forwards ALL
# requests to the single hardcoded upstream (api.anthropic.com over TLS); the
# resolver is pinned IPv4-only (ipv6=off) so nginx does not waste a failed
# connect on an IPv6 address the docker net cannot route. The access-log format
# deliberately OMITS the Authorization header so the key is never logged.
write_proxy_conf() {
  local cfg_dir="$1"
  local conf="${cfg_dir}/nginx.conf"
  cat >"${conf}" <<EOF
# Generated by proxy.sh — egress reverse proxy. Do not edit by hand.
events {}
http {
  log_format bench '\$remote_addr "\$request" \$status \${body_bytes_sent}b ua="\$http_user_agent"';
  access_log /dev/stdout bench;
  error_log /dev/stderr warn;

  server {
    listen ${BENCH_PROXY_PORT};
    # Docker embedded DNS, IPv4 only (the egress net has no IPv6 route).
    resolver 127.0.0.11 ipv6=off valid=30s;
    location / {
      set \$bench_upstream "${BENCH_UPSTREAM_HOST}";
      proxy_pass https://\$bench_upstream\$request_uri;
      proxy_set_header Host ${BENCH_UPSTREAM_HOST};
      proxy_ssl_server_name on;
      proxy_ssl_name ${BENCH_UPSTREAM_HOST};
      proxy_http_version 1.1;
    }
  }
}
EOF
}

ensure_networks() {
  docker network inspect "${BENCH_NETWORK}" >/dev/null 2>&1 \
    || docker network create --internal "${BENCH_NETWORK}" >/dev/null \
    || die "could not create internal network ${BENCH_NETWORK}"
  docker network inspect "${BENCH_EGRESS_NETWORK}" >/dev/null 2>&1 \
    || docker network create "${BENCH_EGRESS_NETWORK}" >/dev/null \
    || die "could not create egress network ${BENCH_EGRESS_NETWORK}"
}

# Launch nginx attached to BOTH networks. docker run takes one network; the
# second is attached with `network connect` immediately after.
launch_proxy() {
  local run_id="$1"
  local cfg_dir; cfg_dir="$(abs_path "${RESULTS_DIR}/${run_id}/proxy")"
  mkdir -p "${cfg_dir}"
  write_proxy_conf "${cfg_dir}"

  docker rm -f "${BENCH_PROXY_CONTAINER}" >/dev/null 2>&1 || true
  docker run -d --name "${BENCH_PROXY_CONTAINER}" \
    --network "${BENCH_EGRESS_NETWORK}" \
    --volume "${cfg_dir}/nginx.conf:/etc/nginx/nginx.conf:ro" \
    "${BENCH_PROXY_IMAGE}" >/dev/null \
    || die "could not launch egress proxy container"
  docker network connect "${BENCH_NETWORK}" "${BENCH_PROXY_CONTAINER}" \
    || die "could not attach ${BENCH_PROXY_CONTAINER} to ${BENCH_NETWORK}"
}

# Best-effort: tally forwarded requests + upstream errors from the nginx log.
record_usage() {
  local run_id="$1"
  local log="${RESULTS_DIR}/${run_id}/proxy-usage.json"
  [[ -f "${log}" ]] || return 0
  local logs requests errors
  logs="$(docker logs "${BENCH_PROXY_CONTAINER}" 2>&1 || true)"
  requests="$(printf '%s\n' "${logs}" | grep -c '"[A-Z].* HTTP/' || true)"
  errors="$(printf '%s\n' "${logs}" | grep -c -iE '\[error\]|upstream' || true)"
  python3 - "${log}" "${requests:-0}" "${errors:-0}" <<'PY'
import json
import sys

path, requests, errors = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["api_requests"] = requests
data["upstream_errors"] = errors
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

cmd_start() {
  [[ $# -eq 1 ]] || usage
  local run_id="$1"
  require_docker
  local log
  log="$(init_usage_log "${run_id}")"
  echo "proxy.sh: initialized usage log at ${log}"

  if [[ "${BENCH_PROXY_NO_LAUNCH:-0}" == "1" ]]; then
    echo "proxy.sh: BENCH_PROXY_NO_LAUNCH=1 — wiring only, forwarder NOT launched (test-only)"
    return 0
  fi

  ensure_networks
  launch_proxy "${run_id}"
  echo "proxy.sh: reverse proxy '${BENCH_PROXY_CONTAINER}' up on ${BENCH_NETWORK} (upstream=${BENCH_UPSTREAM_HOST}, container_base_url=${BENCH_CONTAINER_BASE_URL})"
}

cmd_stop() {
  [[ $# -eq 1 ]] || usage
  local run_id="$1"
  require_docker

  if [[ "${BENCH_PROXY_NO_LAUNCH:-0}" == "1" ]]; then
    echo "proxy.sh: BENCH_PROXY_NO_LAUNCH=1 — nothing to tear down (test-only)"
    return 0
  fi

  record_usage "${run_id}" || true
  docker rm -f "${BENCH_PROXY_CONTAINER}" >/dev/null 2>&1 || true
  echo "proxy.sh: stopped egress proxy for run ${run_id}"
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
