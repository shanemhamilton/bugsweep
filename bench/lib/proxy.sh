#!/usr/bin/env bash
#
# proxy.sh — the egress REVERSE proxy for the bench harness.
#
# Isolation model: the dedicated, revocable model-API key lives only in this
# proxy. The analysis container receives an inert literal and sits on an
# --internal Docker network with no internet. Its only path out is this proxy,
# which:
#   (a) straddles two networks — `bench-proxynet` (--internal; the analysis
#       container's only neighbour) and `bench-egressnet` (its path to the
#       internet),
#   (b) forwards EVERY request to a single hardcoded upstream,
#       https://api.anthropic.com, and nowhere else — so the container can reach
#       the model API and nothing else,
#   (c) is what claude actually uses: the container is pointed at this proxy via
#       ANTHROPIC_BASE_URL (the `claude` CLI runs on Bun and ignores
#       HTTP(S)_PROXY env, so a CONNECT forward proxy would never be used),
#   (d) validates a pinned model, bounded JSON request/response size, turn and
#       in-flight caps, and an operator-provided conservative budget reserve;
#       it emits redacted usage events for the sealed per-run usage log.
#
# The analysis-to-proxy leg is plaintext on the private --internal network, but
# carries only the inert literal. The proxy replaces it from its 0600 secret
# mount and never logs either credential.
#
# Modes:
#   proxy.sh --print-cmd        Print (do NOT launch) the proxy wiring so the
#                               Tier-A bats suite can assert it without starting
#                               a live forwarder.
#   proxy.sh start <run-id>     Create the networks, launch the policy proxy, and
#                               initialize results/<run-id>/proxy-usage.json.
#   proxy.sh stop <run-id>      Seal observed proxy usage, then tear it
#                               down.
#
# BENCH_PROXY_NO_LAUNCH=1 (TEST-ONLY) initializes the usage log + prints wiring
# without creating networks or launching nginx (keeps Tier-A container-free). It
# MUST NOT be set for a real run.
#
# Fails closed (exit 1) if docker is absent (BENCH_FAKE_NO_DOCKER=1 simulates
# absence for the bats suite).

set -euo pipefail

readonly BENCH_NETWORK_PREFIX="bugsweep-bench-net"
readonly BENCH_EGRESS_NETWORK_PREFIX="bugsweep-bench-egress"
readonly BENCH_PROXY_IMAGE="${BENCH_PROXY_IMAGE:-bugsweep-bench-proxy:latest}"
readonly BENCH_PROXY_PORT="8888"
# What the analysis container sets ANTHROPIC_BASE_URL to (kept in sync with
# isolate.sh, which injects it).
readonly RESULTS_DIR="${BENCH_RESULTS_DIR:-results}"

die() {
  echo "proxy.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  proxy.sh --print-cmd
  proxy.sh start <run-id> <claude|codex> <operator-0600-secret-file> <approved-limits-receipt>
  proxy.sh stop  <run-id>
EOF
  exit 1
}

safe_run_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$ ]] || die "invalid run id"
}

network_name() { echo "${BENCH_NETWORK_PREFIX}-$1"; }
egress_network_name() { echo "${BENCH_EGRESS_NETWORK_PREFIX}-$1"; }
container_name() { echo "bugsweep-bench-proxy-$1"; }

upstream_for_host() {
  case "$1" in claude) echo "api.anthropic.com";; codex) echo "api.openai.com";; *) die "host must be claude or codex";; esac
}

require_docker() {
  if [[ "${BENCH_FAKE_NO_DOCKER:-0}" == "1" ]]; then
    die "docker runtime not found on PATH; cannot bind an invocation egress proxy — refusing to run"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "docker runtime not found on PATH; cannot bind an invocation egress proxy — refusing to run"
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
# analysis client sends only the inert literal; the policy proxy injects the
# mounted provider key and never logs either value.
print_cmd() {
  require_docker
  cat <<EOF
# bench egress reverse-proxy wiring (dry-run; no live forwarder launched)
network=${BENCH_NETWORK_PREFIX}-<run-id>
network_internal=true
egress_network=${BENCH_EGRESS_NETWORK_PREFIX}-<run-id>
mode=reverse_proxy
upstream=api.anthropic.com|api.openai.com (selected per invocation)
container_base_url=http://bugsweep-bench-proxy-<run-id>:8888
key_in_proxy_only=true
secret_mount=/run/secrets/provider-key:ro
proxy_image=${BENCH_PROXY_IMAGE}
listen_port=${BENCH_PROXY_PORT}
usage_log=${RESULTS_DIR}/<run-id>/proxy-usage.json
EOF
}

# Initialize the per-run usage log. The proxy emits structured, redacted events
# to Docker stdout; ``record_usage`` aggregates and seals them at teardown.
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
    json.dump({"schema_version": 1, "api_requests": 0, "upstream_errors": 0,
               "rejected_requests": 0, "input_tokens": None, "output_tokens": None,
               "estimated_cost_usd": None, "reserved_usd": 0.0,
               "budget_charged_usd": 0.0, "budget_overshoot_usd": 0.0}, fh,
              sort_keys=True, separators=(",", ":"))
    fh.write("\n")
PY
  echo "${log}"
}

# Build a nonsecret policy from an operator-approved cap document. The envelope
# keeps provider-bound ``limits`` stable while allowing policy-only controls
# (pinned model, byte ceilings, reservation and rates) to be hash-bound through
# the policy mount.
write_proxy_conf() {
  local cfg_dir="$1" host="$2" upstream="$3" limits_file="$4"
  local conf="${cfg_dir}/proxy-policy.json"
  python3 - "${conf}" "${host}" "${upstream}" "${limits_file}" "${BENCH_PROXY_PORT}" <<'PY'
import json, math, os, sys
out, host, upstream, limits_path, port = sys.argv[1:]
with open(limits_path, encoding="utf-8") as fh: approved = json.load(fh)
limits = approved.get("limits") if isinstance(approved, dict) and isinstance(approved.get("limits"), dict) else approved
controls = approved.get("proxy_controls") if isinstance(approved, dict) else None
required = {"wall_clock_seconds", "max_turns", "max_input_tokens", "max_output_tokens", "max_spend_usd", "enforcement"}
if not isinstance(limits, dict) or set(limits) != required or not isinstance(controls, dict):
    raise SystemExit("approved cap document requires exact limits and proxy_controls")
expected_enforcement = {"wall_clock_seconds": "provider-deadline",
                        "max_turns": "provider_proxy:atomic_turn_counter",
                        "max_input_tokens": "provider_proxy:conservative_request_byte_ceiling",
                        "max_output_tokens": "provider_proxy:rewrites_output_cap",
                        "max_spend_usd": "provider_proxy:conservative_reservation"}
if limits.get("enforcement") != expected_enforcement:
    raise SystemExit("approved cap document must name the implemented enforcement mechanisms")
if controls.get("host") != host or not isinstance(controls.get("model"), str) or not controls["model"]:
    raise SystemExit("proxy controls must bind this host and a pinned model")
for key in ("max_request_bytes", "max_response_bytes", "max_inflight_requests"):
    value = controls.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise SystemExit(f"invalid proxy control: {key}")
for key in ("reservation_usd", "input_usd_per_million_tokens", "output_usd_per_million_tokens"):
    value = controls.get(key)
    if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0):
        raise SystemExit(f"invalid proxy control: {key}")
path = "/v1/messages" if host == "claude" else "/v1/responses"
policy = {"schema_version": 1, "host": host, "upstream": upstream, "allowed_method": "POST",
          "allowed_paths": [path], "secret_path": "/run/secrets/provider-key", "listen_port": int(port),
          "model": controls["model"], "controls": {key: controls.get(key) for key in ("max_request_bytes", "max_response_bytes", "max_inflight_requests", "reservation_usd", "input_usd_per_million_tokens", "output_usd_per_million_tokens")},
          "limits": limits}
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(policy, fh, sort_keys=True, separators=(",", ":")); fh.write("\n"); fh.flush(); os.fsync(fh.fileno())
PY
}

ensure_networks() {
  local run_id="$1" internal egress
  internal="$(network_name "${run_id}")"; egress="$(egress_network_name "${run_id}")"
  docker network create --internal "${internal}" >/dev/null || die "could not create internal invocation network"
  docker network create "${egress}" >/dev/null || die "could not create egress invocation network"
}

# Launch nginx attached to BOTH networks. docker run takes one network; the
# second is attached with `network connect` immediately after.
launch_proxy() {
  local run_id="$1" host="$2" secret_file="$3" limits_file="$4" upstream cfg_dir internal egress container
  upstream="$(upstream_for_host "${host}")"; internal="$(network_name "${run_id}")"; egress="$(egress_network_name "${run_id}")"; container="$(container_name "${run_id}")"
  cfg_dir="$(abs_path "${RESULTS_DIR}/${run_id}/proxy")"
  mkdir -p "${cfg_dir}"
  write_proxy_conf "${cfg_dir}" "${host}" "${upstream}" "${limits_file}"

  docker run -d --name "${container}" \
    --network "${egress}" \
    --user 65534:65534 --workdir / --ipc none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 64 --memory 134217728 --memory-swap 134217728 --cpus 1.0 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16777216 \
    --mount "type=bind,src=${cfg_dir}/proxy-policy.json,dst=/etc/bugsweep/proxy-policy.json,readonly" \
    --mount "type=bind,src=${secret_file},dst=/run/secrets/provider-key,readonly" \
    --env "BUGSWEEP_PROXY_POLICY=/etc/bugsweep/proxy-policy.json" \
    "${BENCH_PROXY_IMAGE}" >/dev/null \
    || die "could not launch egress proxy container"
  docker network connect "${internal}" "${container}" \
    || die "could not attach proxy to invocation network"
}

# Aggregate only the proxy's JSON events. This never inspects or persists an
# Authorization header, prompt, source text, or model response.
record_usage() {
  local run_id="$1"
  local log="${RESULTS_DIR}/${run_id}/proxy-usage.json"
  [[ -f "${log}" ]] || return 0
  local events_file
  events_file="$(mktemp "${TMPDIR:-/tmp}/bugsweep-proxy-events.XXXXXX")"
  chmod 0600 "${events_file}"
  docker logs "$(container_name "${run_id}")" >"${events_file}" 2>&1 || { rm -f "${events_file}"; return 1; }
  local receipt_dir="${BENCH_PROXY_RECEIPTS_DIR:-}" event_log
  [[ "${receipt_dir}" == /* && -d "${receipt_dir}" ]] || { rm -f "${events_file}"; return 1; }
  event_log="${receipt_dir}/${run_id}.proxy-events.jsonl"
  [[ ! -e "${event_log}" ]] || { rm -f "${events_file}"; return 1; }
  python3 - "${log}" "${events_file}" "${event_log}" <<'PY'
import json
import math
import os
import sys

path, events_path, event_log_path = sys.argv[1:]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
events = []
for line in open(events_path, encoding="utf-8", errors="replace"):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(event, dict) and event.get("kind") == "bugsweep-proxy-usage":
        events.append(event)
if len(events) > 1024:
    raise SystemExit("too many proxy usage events")
with open(event_log_path, "x", encoding="utf-8") as out:
    for event in events:
        out.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
    out.flush(); os.fsync(out.fileno())
event_raw = open(event_log_path, "rb").read()
event_sha = __import__("hashlib").sha256(event_raw).hexdigest()
forwarded = [event for event in events if event.get("status") == "forwarded"]
errored = [event for event in events if event.get("status") == "upstream_error"]
rejected = [event for event in events if event.get("status") == "rejected"]
def total(name):
    values = [event.get(name) for event in forwarded + errored]
    values = [value for value in values if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)]
    return sum(values) if values else None
accounting_complete = all(isinstance(event.get("input_tokens"), int) and not isinstance(event.get("input_tokens"), bool) and isinstance(event.get("output_tokens"), int) and not isinstance(event.get("output_tokens"), bool) for event in forwarded + errored)
data.update({"api_requests": len(forwarded), "upstream_errors": len(errored),
             "rejected_requests": len(rejected), "input_tokens": total("input_tokens"),
             "output_tokens": total("output_tokens"), "estimated_cost_usd": total("estimated_cost_usd"),
             "reserved_usd": total("reserved_usd") or 0.0,
             "budget_charged_usd": total("budget_charged_usd") or 0.0,
             "budget_overshoot_usd": max([event.get("budget_overshoot_usd", 0.0) for event in forwarded + errored if isinstance(event.get("budget_overshoot_usd", 0.0), (int, float)) and not isinstance(event.get("budget_overshoot_usd", 0.0), bool)] or [0.0]),
             "event_count": len(events), "event_log_path": event_log_path,
             "event_log_sha256": event_sha, "admitted_turns": len(forwarded) + len(errored),
             "inflight_requests_at_stop": 0, "accounting_complete": accounting_complete})
payload = json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n"
temporary = path + ".tmp"
with open(temporary, "x", encoding="utf-8") as fh:
    fh.write(payload); fh.flush(); os.fsync(fh.fileno())
os.replace(temporary, path)
PY
  rm -f "${events_file}"
}

write_proxy_receipt() {
  local run_id="$1" host="$2" limits_file="$3" out_dir="${BENCH_PROXY_RECEIPTS_DIR:-}" receipt internal egress container policy_file
  [[ "${out_dir}" == /* && -d "${out_dir}" ]] || die "BENCH_PROXY_RECEIPTS_DIR must be an external absolute directory"
  receipt="${out_dir}/${run_id}.proxy-receipt.json"
  [[ ! -e "${receipt}" ]] || die "proxy receipt already exists"
  internal="$(network_name "${run_id}")"; egress="$(egress_network_name "${run_id}")"; container="$(container_name "${run_id}")"
  policy_file="${RESULTS_DIR}/${run_id}/proxy/proxy-policy.json"
  [[ -f "${policy_file}" && ! -L "${policy_file}" ]] || die "generated proxy policy is missing"
  python3 - "${receipt}" "${run_id}" "${host}" "${internal}" "${egress}" "${container}" "${limits_file}" "${policy_file}" <<'PY'
import hashlib, json, subprocess, sys
path, run_id, host, internal, egress, container, limits_path, policy_path = sys.argv[1:]
def inspect(kind, name):
    raw = subprocess.check_output(["docker", kind, "inspect", name], text=True)
    return json.loads(raw)[0]
net_i, net_e, proxy = inspect("network", internal), inspect("network", egress), inspect("container", container)
attachments = proxy.get("NetworkSettings", {}).get("Networks", {})
if set(attachments) != {internal, egress}:
    raise SystemExit("proxy attachment readback is not exact")
with open(limits_path, encoding="utf-8") as fh:
    approved = json.load(fh)
limits = approved.get("limits") if isinstance(approved, dict) and isinstance(approved.get("limits"), dict) else approved
required = {"wall_clock_seconds", "max_turns", "max_input_tokens", "max_output_tokens", "max_spend_usd", "enforcement"}
if not isinstance(limits, dict) or set(limits) != required or not isinstance(limits["enforcement"], dict):
    raise SystemExit("approved limits receipt has an invalid shape")
labels = proxy.get("Config", {}).get("Labels", {})
source_sha = labels.get("org.bugsweep.proxy.source.sha256") if isinstance(labels, dict) else None
if not isinstance(source_sha, str) or len(source_sha) != 64:
    raise SystemExit("proxy source label is missing")
value = {
  "schema_version": 1, "owner": "bench/lib/proxy.sh", "run_id": run_id, "host": host,
  "internal_network": {"name": internal, "id": net_i["Id"]},
  "egress_network": {"name": egress, "id": net_e["Id"]},
  "proxy": {"container_name": container, "container_id": proxy["Id"], "image_digest": proxy["Image"]},
  "source_evidence": {"provider_proxy_sha256": source_sha, "image_label_matches": True},
  "upstream": {"host": "api.anthropic.com" if host == "claude" else "api.openai.com", "allowed_paths": ["/v1/messages"] if host == "claude" else ["/v1/responses"]},
  "limits": limits,
  "policy": {"mount": "/etc/bugsweep/proxy-policy.json", "sha256": hashlib.sha256(open(policy_path, "rb").read()).hexdigest(), "nonsecret": True},
  "secret": {"mount": "/run/secrets/provider-key", "mode": "0600", "outside_target_and_results": True},
}
payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
with open(path, "xb") as fh:
    fh.write(payload); fh.flush()
print(hashlib.sha256(payload).hexdigest())
PY
}

cmd_start() {
  if [[ "${BENCH_PROXY_NO_LAUNCH:-0}" == "1" && $# -eq 1 ]]; then
    safe_run_id "$1"
    require_docker
    init_usage_log "$1" >/dev/null
    echo "proxy.sh: BENCH_PROXY_NO_LAUNCH=1 — wiring only, forwarder NOT launched (test-only)"
    return 0
  fi
  [[ $# -eq 4 ]] || usage
  local run_id="$1" host="$2" secret_file="$3" limits_file="$4"
  safe_run_id "${run_id}"; upstream_for_host "${host}" >/dev/null
  [[ "${secret_file}" == /* && -f "${secret_file}" && ! -L "${secret_file}" ]] || die "proxy secret must be an absolute regular file"
  [[ "${limits_file}" == /* && -f "${limits_file}" && ! -L "${limits_file}" ]] || die "limits receipt must be an absolute regular file"
  [[ "$(stat -f '%Lp' "${secret_file}" 2>/dev/null || stat -c '%a' "${secret_file}" 2>/dev/null)" == "600" ]] || die "proxy secret must have mode 0600"
  require_docker
  local log
  log="$(init_usage_log "${run_id}")"
  echo "proxy.sh: initialized usage log at ${log}"

  ensure_networks "${run_id}"
  launch_proxy "${run_id}" "${host}" "${secret_file}" "${limits_file}"
  local receipt_sha
  receipt_sha="$(write_proxy_receipt "${run_id}" "${host}" "${limits_file}")"
  echo "proxy.sh: immutable proxy receipt sha256=${receipt_sha}"
  echo "proxy.sh: invocation proxy up (host=${host}, upstream=$(upstream_for_host "${host}"))"
}

cmd_stop() {
  [[ $# -eq 1 ]] || usage
  local run_id="$1"
  safe_run_id "${run_id}"
  require_docker

  if [[ "${BENCH_PROXY_NO_LAUNCH:-0}" == "1" ]]; then
    echo "proxy.sh: BENCH_PROXY_NO_LAUNCH=1 — nothing to tear down (test-only)"
    return 0
  fi

  local receipt_dir="${BENCH_PROXY_RECEIPTS_DIR:-}" receipt
  [[ "${receipt_dir}" == /* ]] || die "BENCH_PROXY_RECEIPTS_DIR is required for owned teardown"
  receipt="${receipt_dir}/${run_id}.proxy-receipt.json"
  [[ -f "${receipt}" && ! -L "${receipt}" ]] || die "owned proxy receipt is missing"
  python3 - "${receipt}" "${run_id}" "$(network_name "${run_id}")" "$(egress_network_name "${run_id}")" "$(container_name "${run_id}")" <<'PY'
import json, subprocess, sys
receipt_path, run_id, internal, egress, container = sys.argv[1:]
with open(receipt_path, encoding="utf-8") as fh: receipt = json.load(fh)
if receipt.get("schema_version") != 1 or receipt.get("owner") != "bench/lib/proxy.sh" or receipt.get("run_id") != run_id:
    raise SystemExit("proxy receipt ownership mismatch")
proxy = receipt.get("proxy", {})
if proxy.get("container_name") != container:
    raise SystemExit("proxy receipt container mismatch")
actual = json.loads(subprocess.check_output(["docker", "container", "inspect", container], text=True))[0]
if actual.get("Id") != proxy.get("container_id"):
    raise SystemExit("proxy container identity changed")
for name, expected in ((internal, receipt.get("internal_network", {}).get("id")), (egress, receipt.get("egress_network", {}).get("id"))):
    observed = json.loads(subprocess.check_output(["docker", "network", "inspect", name], text=True))[0].get("Id")
    if observed != expected: raise SystemExit("proxy network identity changed")
PY
  record_usage "${run_id}"
  docker rm -f "$(container_name "${run_id}")" >/dev/null
  docker network rm "$(network_name "${run_id}")" "$(egress_network_name "${run_id}")" >/dev/null
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
