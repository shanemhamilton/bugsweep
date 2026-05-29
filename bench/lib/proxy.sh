#!/usr/bin/env bash
#
# proxy.sh — the CONNECT-only, egress allow-list forward proxy for the bench
# harness.
#
# Isolation model (deliberate, post-Design-Review-Gate decision — see
# bench/README.md "Security model"): the dedicated, revocable model-API key
# lives INSIDE the analysis container, but that container sits on an --internal
# docker network with NO internet. Its only path out is this proxy, which:
#   (a) straddles two networks — `bench-proxynet` (--internal; the analysis
#       container's only neighbour) and `bench-egressnet` (its path to the
#       internet),
#   (b) permits HTTP CONNECT tunnels ONLY to an exact-host allow-list (default
#       api.anthropic.com:443; extend via BENCH_PROXY_ALLOW), 403-ing all other
#       hosts and any non-443 CONNECT,
#   (c) does NOT terminate TLS — the tunnel is end-to-end, so the API key rides
#       inside the encrypted stream and is never visible to the proxy (no key
#       injection, no auth stripping),
#   (d) writes a per-run usage log (CONNECT counts) to
#       results/<run-id>/proxy-usage.json so the accepted budget-abuse residual
#       is observable. Token/$ volume comes from the runner's captured usage via
#       cost.sh — the proxy is blind to it by design (end-to-end TLS).
#
# The accepted residual: untrusted code in the container CAN read the key and
# spend against it (bounded by the budget cap + revocability), but CANNOT
# exfiltrate it anywhere except the allow-listed model API.
#
# Modes:
#   proxy.sh --print-cmd        Print (do NOT launch) the proxy wiring/config so
#                               the Tier-A bats suite can assert the security
#                               wiring without starting a live forwarder.
#   proxy.sh start <run-id>     Create the networks, launch the forwarder, and
#                               initialize results/<run-id>/proxy-usage.json.
#   proxy.sh stop <run-id>      Record observed CONNECT counts, tear the
#                               forwarder down.
#
# BENCH_PROXY_NO_LAUNCH=1 (TEST-ONLY) initializes the usage log + prints wiring
# without creating networks or launching the forwarder (keeps Tier-A
# container-free). It MUST NOT be set for a real run.
#
# Fails closed (exit 1) if docker is absent (BENCH_FAKE_NO_DOCKER=1 simulates
# absence for the bats suite).

set -euo pipefail

readonly BENCH_NETWORK="bench-proxynet"           # --internal: analysis container's only neighbour
readonly BENCH_EGRESS_NETWORK="bench-egressnet"   # normal bridge: the proxy's path to the internet
readonly BENCH_PROXY_DEFAULT_ALLOW="api.anthropic.com"
readonly BENCH_PROXY_IMAGE="${BENCH_PROXY_IMAGE:-bugsweep-bench-proxy:latest}"
readonly BENCH_PROXY_CONTAINER="bench-proxy"
readonly BENCH_PROXY_PORT="8888"
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

# Effective exact-host allow-list: the default plus any hosts in
# BENCH_PROXY_ALLOW (comma- or space-separated). Echoes a comma-joined list.
allow_hosts() {
  local extra="${BENCH_PROXY_ALLOW:-}"
  local hosts="${BENCH_PROXY_DEFAULT_ALLOW}"
  if [[ -n "${extra}" ]]; then
    local normalized="${extra//,/ }"
    local h
    for h in ${normalized}; do
      [[ -n "${h}" ]] && hosts="${hosts},${h}"
    done
  fi
  echo "${hosts}"
}

# The allow-list as comma-joined host:443 CONNECT targets.
connect_allow() {
  local out="" h
  local normalized; normalized="$(allow_hosts)"
  normalized="${normalized//,/ }"
  for h in ${normalized}; do
    [[ -n "${h}" ]] && out="${out}${out:+,}${h}:443"
  done
  echo "${out}"
}

# Print the proxy wiring/config. Never prints any key value — the key is not
# handled by the proxy at all in this model.
print_cmd() {
  require_docker
  cat <<EOF
# bench egress proxy wiring (dry-run; no live forwarder launched)
network=${BENCH_NETWORK}
network_internal=true
egress_network=${BENCH_EGRESS_NETWORK}
allow_hosts=$(allow_hosts)
connect_allow=$(connect_allow)
match_mode=exact_host
refuse_connect=false
key_in_container=true
proxy_image=${BENCH_PROXY_IMAGE}
listen_port=${BENCH_PROXY_PORT}
usage_log=${RESULTS_DIR}/<run-id>/proxy-usage.json
EOF
}

# Initialize the per-run usage log. The CONNECT proxy is blind to tokens
# (end-to-end TLS), so it records CONNECT request counts only.
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
    json.dump({"connect_requests": 0, "denied_connects": 0}, fh, indent=2)
    fh.write("\n")
PY
  echo "${log}"
}

# Write the tinyproxy config + hostname filter (exact-host, default-deny) into
# the per-run config dir. CONNECT is restricted to port 443; the Filter is an
# anchored exact-host allow-list applied to the CONNECT host.
write_proxy_conf() {
  local cfg_dir="$1"
  local conf="${cfg_dir}/tinyproxy.conf"
  local filter="${cfg_dir}/filter"

  # One anchored regex per allowed host (dots escaped, ^…$ for exact match).
  : >"${filter}"
  local h normalized; normalized="$(allow_hosts)"; normalized="${normalized//,/ }"
  for h in ${normalized}; do
    [[ -z "${h}" ]] && continue
    printf '^%s$\n' "${h//./\\.}" >>"${filter}"
  done

  cat >"${conf}" <<EOF
# Generated by proxy.sh — CONNECT-only egress allow-list. Do not edit by hand.
User nobody
Group nogroup
Port ${BENCH_PROXY_PORT}
Timeout 600
# Inbound ACL: only the --internal bench network can reach this proxy, so allow
# the RFC1918 ranges docker assigns; nothing external can route here.
Allow 10.0.0.0/8
Allow 172.16.0.0/12
Allow 192.168.0.0/16
# CONNECT (HTTPS tunnel) permitted to port 443 only.
ConnectPort 443
# Exact-host allow-list applied to the CONNECT host. Default-deny: only hosts
# matching a filter line are tunnelled; everything else gets 403 Filtered.
Filter "/etc/tinyproxy/filter"
FilterDefaultDeny Yes
FilterExtended On
FilterURLs Off
FilterCaseSensitive Off
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

# Launch the forwarder attached to BOTH networks. docker run takes one network;
# the second is attached with `network connect` immediately after.
launch_proxy() {
  local run_id="$1"
  local cfg_dir; cfg_dir="$(abs_path "${RESULTS_DIR}/${run_id}/proxy")"
  mkdir -p "${cfg_dir}"
  write_proxy_conf "${cfg_dir}"

  docker rm -f "${BENCH_PROXY_CONTAINER}" >/dev/null 2>&1 || true
  docker run -d --name "${BENCH_PROXY_CONTAINER}" \
    --network "${BENCH_EGRESS_NETWORK}" \
    --volume "${cfg_dir}/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro" \
    --volume "${cfg_dir}/filter:/etc/tinyproxy/filter:ro" \
    "${BENCH_PROXY_IMAGE}" >/dev/null \
    || die "could not launch egress proxy container"
  docker network connect "${BENCH_NETWORK}" "${BENCH_PROXY_CONTAINER}" \
    || die "could not attach ${BENCH_PROXY_CONTAINER} to ${BENCH_NETWORK}"
}

# Best-effort: tally CONNECT outcomes from the forwarder log into the usage log.
record_usage() {
  local run_id="$1"
  local log="${RESULTS_DIR}/${run_id}/proxy-usage.json"
  [[ -f "${log}" ]] || return 0
  local logs connects denied
  logs="$(docker logs "${BENCH_PROXY_CONTAINER}" 2>&1 || true)"
  connects="$(printf '%s\n' "${logs}" | grep -c -i "Connect (file descriptor" || true)"
  denied="$(printf '%s\n' "${logs}" | grep -c -i "Filtered" || true)"
  python3 - "${log}" "${connects:-0}" "${denied:-0}" <<'PY'
import json
import sys

path, connects, denied = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["connect_requests"] = connects
data["denied_connects"] = denied
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
  echo "proxy.sh: egress proxy '${BENCH_PROXY_CONTAINER}' up on ${BENCH_NETWORK} (connect_allow=$(connect_allow))"
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
