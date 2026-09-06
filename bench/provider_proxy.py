#!/usr/bin/env python3
"""Per-invocation provider reverse proxy.

The analysis container can only supply the inert benchmark credential.  This
process validates a frozen nonsecret policy, replaces that credential from its
private mount, and sends a bounded POST to one provider hostname.  It emits
redacted JSON usage events to stdout; ``proxy.sh`` seals those events after the
container stops.
"""
from __future__ import annotations

import http.client
import json
import math
import os
import stat
import sys
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Mapping

INERT_CREDENTIAL = "benchmark-inert-client-credential"
MAX_POLICY_BYTES = 65_536
MAX_HARD_REQUEST_BYTES = 8 * 1024 * 1024
MAX_HARD_RESPONSE_BYTES = 16 * 1024 * 1024
EXPECTED = {
    "claude": ("api.anthropic.com", "/v1/messages", "max_tokens"),
    "codex": ("api.openai.com", "/v1/responses", "max_output_tokens"),
}


class PolicyError(ValueError):
    pass


def _number(value: object, *, nonnegative: bool = True) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        raise PolicyError("numeric policy value required")
    if nonnegative and value < 0:
        raise PolicyError("numeric policy value must be nonnegative")
    return float(value)


def _limit_int(value: object, name: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise PolicyError(f"{name} must be a nonnegative integer or null")
    return value


def _read_json_file(path: str, maximum: int) -> Mapping[str, Any]:
    if not os.path.isabs(path):
        raise PolicyError("policy path must be absolute")
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
        raise PolicyError("policy must be a bounded regular file")
    with open(path, "rb") as handle:
        value = json.load(handle)
    if not isinstance(value, Mapping):
        raise PolicyError("policy must be an object")
    return value


@dataclass(frozen=True)
class Policy:
    host: str
    upstream: str
    path: str
    model: str
    secret: str
    listen_port: int
    max_request_bytes: int
    max_response_bytes: int
    max_inflight_requests: int
    max_turns: int | None
    max_input_tokens: int | None
    max_output_tokens: int | None
    max_spend_usd: float | None
    reservation_usd: float | None
    input_usd_per_million_tokens: float | None
    output_usd_per_million_tokens: float | None


def load_policy(path: str) -> Policy:
    value = _read_json_file(path, MAX_POLICY_BYTES)
    host = value.get("host")
    if host not in EXPECTED:
        raise PolicyError("unsupported provider host")
    expected_upstream, expected_path, _ = EXPECTED[host]
    if value.get("schema_version") != 1 or value.get("upstream") != expected_upstream:
        raise PolicyError("policy upstream is not the fixed provider endpoint")
    if value.get("allowed_method") != "POST" or value.get("allowed_paths") != [expected_path]:
        raise PolicyError("policy endpoint allowlist is invalid")
    model = value.get("model")
    if not isinstance(model, str) or not model or len(model.encode()) > 256:
        raise PolicyError("policy model is required")
    secret_path = value.get("secret_path")
    if not isinstance(secret_path, str) or not os.path.isabs(secret_path):
        raise PolicyError("policy secret path is invalid")
    secret_info = os.lstat(secret_path)
    if not stat.S_ISREG(secret_info.st_mode) or secret_info.st_size > 8192:
        raise PolicyError("provider secret must be a bounded regular file")
    with open(secret_path, encoding="utf-8") as handle:
        secret = handle.read().strip()
    if not secret or secret == INERT_CREDENTIAL:
        raise PolicyError("provider secret is absent or inert")
    controls, limits = value.get("controls"), value.get("limits")
    if not isinstance(controls, Mapping) or not isinstance(limits, Mapping):
        raise PolicyError("policy requires operator controls and limits")
    request_bytes = _limit_int(controls.get("max_request_bytes"), "max_request_bytes")
    response_bytes = _limit_int(controls.get("max_response_bytes"), "max_response_bytes")
    inflight = _limit_int(controls.get("max_inflight_requests"), "max_inflight_requests")
    if request_bytes is None or not 1 <= request_bytes <= MAX_HARD_REQUEST_BYTES:
        raise PolicyError("request byte ceiling is invalid")
    if response_bytes is None or not 1 <= response_bytes <= MAX_HARD_RESPONSE_BYTES:
        raise PolicyError("response byte ceiling is invalid")
    if inflight is None or not 1 <= inflight <= 32:
        raise PolicyError("inflight ceiling is invalid")
    max_turns = _limit_int(limits.get("max_turns"), "max_turns")
    max_input = _limit_int(limits.get("max_input_tokens"), "max_input_tokens")
    max_output = _limit_int(limits.get("max_output_tokens"), "max_output_tokens")
    # A request has at most one token per UTF-8 byte.  Requiring the policy's
    # byte ceiling to be no greater than the input-token cap is conservative.
    if max_input is not None and request_bytes > max_input:
        raise PolicyError("request byte ceiling exceeds input-token cap")
    max_spend = _number(limits.get("max_spend_usd"))
    reservation = _number(controls.get("reservation_usd"))
    input_rate = _number(controls.get("input_usd_per_million_tokens"))
    output_rate = _number(controls.get("output_usd_per_million_tokens"))
    if max_spend is None:
        if reservation is not None:
            raise PolicyError("unbounded spend cannot carry a reservation")
    elif reservation is None or reservation <= 0 or reservation > max_spend:
        raise PolicyError("spend cap requires an operator reservation")
    port = _limit_int(value.get("listen_port"), "listen_port")
    if port is None or not 1 <= port <= 65535:
        raise PolicyError("listen port is invalid")
    return Policy(host, expected_upstream, expected_path, model, secret, port, request_bytes,
                  response_bytes, inflight, max_turns, max_input, max_output, max_spend,
                  reservation, input_rate, output_rate)


def _usage(value: object) -> tuple[int | None, int | None]:
    """Extract native provider usage without trusting a model-produced claim."""
    if not isinstance(value, Mapping):
        return None, None
    usage = value.get("usage")
    if not isinstance(usage, Mapping):
        return None, None
    input_tokens = usage.get("input_tokens", usage.get("input"))
    output_tokens = usage.get("output_tokens", usage.get("output"))
    valid = lambda item: isinstance(item, int) and not isinstance(item, bool) and item >= 0
    return (input_tokens if valid(input_tokens) else None,
            output_tokens if valid(output_tokens) else None)


def _response_usage(raw: bytes) -> tuple[int | None, int | None]:
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        value = None
    input_tokens, output_tokens = _usage(value)
    if input_tokens is not None or output_tokens is not None:
        return input_tokens, output_tokens
    # Streaming APIs put final usage in a JSON SSE data frame.
    for line in raw.splitlines():
        if line.startswith(b"data:"):
            try:
                input_tokens, output_tokens = _usage(json.loads(line[5:].strip()))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if input_tokens is not None or output_tokens is not None:
                return input_tokens, output_tokens
    return None, None


class Budget:
    def __init__(self, policy: Policy) -> None:
        self.policy, self.lock = policy, threading.Lock()
        self.turns = self.inflight = 0
        self.reserved = self.settled = 0.0
        self.input_reserved = self.input_settled = 0
        self.output_reserved = self.output_settled = 0

    def admit(self, input_reservation: int, output_reservation: int) -> float:
        with self.lock:
            if self.policy.max_turns is not None and self.turns >= self.policy.max_turns:
                raise PolicyError("turn cap exhausted")
            if self.inflight >= self.policy.max_inflight_requests:
                raise PolicyError("inflight cap exhausted")
            reservation = self.policy.reservation_usd or 0.0
            if self.policy.max_spend_usd is not None and self.settled + self.reserved + reservation > self.policy.max_spend_usd:
                raise PolicyError("spend reservation exhausted")
            if self.policy.max_input_tokens is not None and self.input_settled + self.input_reserved + input_reservation > self.policy.max_input_tokens:
                raise PolicyError("input token cap exhausted")
            if self.policy.max_output_tokens is not None and self.output_settled + self.output_reserved + output_reservation > self.policy.max_output_tokens:
                raise PolicyError("output token cap exhausted")
            self.turns += 1
            self.inflight += 1
            self.reserved += reservation
            self.input_reserved += input_reservation
            self.output_reserved += output_reservation
            return reservation

    def settle(self, reservation: float, input_reservation: int, output_reservation: int, input_tokens: int | None, output_tokens: int | None, *, uncertain: bool) -> dict[str, Any]:
        estimated_cost = None
        if input_tokens is not None and output_tokens is not None and self.policy.input_usd_per_million_tokens is not None and self.policy.output_usd_per_million_tokens is not None:
            estimated_cost = (input_tokens * self.policy.input_usd_per_million_tokens + output_tokens * self.policy.output_usd_per_million_tokens) / 1_000_000
        charged = reservation if uncertain or estimated_cost is None else max(reservation, estimated_cost)
        with self.lock:
            self.inflight -= 1
            self.reserved -= reservation
            self.settled += charged
            self.input_reserved -= input_reservation
            self.output_reserved -= output_reservation
            self.input_settled += input_reservation if input_tokens is None else input_tokens
            self.output_settled += output_reservation if output_tokens is None else output_tokens
            overshoot = max(0.0, self.settled + self.reserved - (self.policy.max_spend_usd or float("inf")))
        return {"input_tokens": input_tokens, "output_tokens": output_tokens,
                "estimated_cost_usd": estimated_cost, "reserved_usd": reservation,
                "budget_charged_usd": charged, "budget_overshoot_usd": overshoot,
                "cost_source": "rate_estimated" if estimated_cost is not None else "unknown",
                "admitted_turns": self.turns, "inflight_requests": self.inflight,
                "cumulative_input_tokens": self.input_settled, "cumulative_output_tokens": self.output_settled}


def normalize_request(policy: Policy, raw: bytes) -> tuple[bytes, int]:
    if len(raw) > policy.max_request_bytes:
        raise PolicyError("request byte cap exceeded")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PolicyError("request must be JSON") from exc
    if not isinstance(value, dict) or value.get("model") != policy.model:
        raise PolicyError("request model is not pinned")
    _, _, output_key = EXPECTED[policy.host]
    if policy.max_output_tokens is not None:
        requested = value.get(output_key)
        if requested is not None and (isinstance(requested, bool) or not isinstance(requested, int) or requested < 0):
            raise PolicyError("requested output cap is invalid")
        if requested is not None and requested > policy.max_output_tokens:
            raise PolicyError("requested output cap exceeds policy")
        value[output_key] = policy.max_output_tokens
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(encoded) > policy.max_request_bytes:
        raise PolicyError("normalized request byte cap exceeded")
    output_reservation = value.get(output_key, 0)
    if isinstance(output_reservation, bool) or not isinstance(output_reservation, int) or output_reservation < 0:
        raise PolicyError("normalized output cap is invalid")
    return encoded, output_reservation


def _emit(value: Mapping[str, Any]) -> None:
    print(json.dumps({"kind": "bugsweep-proxy-usage", **value}, sort_keys=True, separators=(",", ":")), flush=True)


class ProviderProxy(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address: tuple[str, int], policy: Policy) -> None:
        self.policy, self.budget = policy, Budget(policy)
        super().__init__(address, ProviderHandler)


class ProviderHandler(BaseHTTPRequestHandler):
    server: ProviderProxy
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _reject(self, code: int, reason: str) -> None:
        body = json.dumps({"error": "benchmark_proxy_rejected", "reason": reason}, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        _emit({"status": "rejected", "reason": reason})

    def do_POST(self) -> None:
        policy = self.server.policy
        if self.path != policy.path:
            self._reject(404, "path_not_allowed")
            return
        content_length = self.headers.get("Content-Length")
        if not content_length or not content_length.isdecimal():
            self._reject(411, "content_length_required")
            return
        size = int(content_length)
        if size > policy.max_request_bytes:
            self._reject(413, "request_byte_cap_exceeded")
            return
        expected_auth = self.headers.get("x-api-key") if policy.host == "claude" else self.headers.get("Authorization")
        if expected_auth != (INERT_CREDENTIAL if policy.host == "claude" else f"Bearer {INERT_CREDENTIAL}"):
            self._reject(401, "inert_credential_required")
            return
        try:
            body, output_reservation = normalize_request(policy, self.rfile.read(size))
            input_reservation = len(body)
            reservation = self.server.budget.admit(input_reservation, output_reservation)
        except PolicyError as exc:
            self._reject(429, str(exc).replace(" ", "_"))
            return
        headers = {"Content-Type": "application/json", "Accept": self.headers.get("Accept", "application/json")}
        if policy.host == "claude":
            headers["x-api-key"] = policy.secret
            for key in ("anthropic-version", "anthropic-beta"):
                if self.headers.get(key):
                    headers[key] = self.headers[key]
        else:
            headers["Authorization"] = f"Bearer {policy.secret}"
        try:
            upstream = http.client.HTTPSConnection(policy.upstream, timeout=60)
            upstream.request("POST", policy.path, body=body, headers=headers)
            response = upstream.getresponse()
            response_body = response.read(policy.max_response_bytes + 1)
            if len(response_body) > policy.max_response_bytes:
                raise PolicyError("response byte cap exceeded")
            input_tokens, output_tokens = _response_usage(response_body)
            usage = self.server.budget.settle(reservation, input_reservation, output_reservation, input_tokens, output_tokens, uncertain=response.status >= 400)
            self.send_response(response.status)
            for key in ("Content-Type", "Request-Id", "x-request-id"):
                if response.getheader(key):
                    self.send_header(key, response.getheader(key))
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)
            _emit({"status": "forwarded", "http_status": response.status, "response_bytes": len(response_body), **usage})
        except Exception as exc:  # The reservation remains charged on uncertainty.
            usage = self.server.budget.settle(reservation, input_reservation, output_reservation, None, None, uncertain=True)
            self._reject(502, "upstream_unavailable")
            _emit({"status": "upstream_error", "error": type(exc).__name__, **usage})

    def do_GET(self) -> None:
        self._reject(405, "method_not_allowed")


def main() -> int:
    try:
        policy_path = os.environ.get("BUGSWEEP_PROXY_POLICY", "")
        policy = load_policy(policy_path)
    except (OSError, PolicyError, json.JSONDecodeError) as exc:
        print(f"provider proxy refused policy: {exc}", file=sys.stderr)
        return 64
    server = ProviderProxy(("0.0.0.0", policy.listen_port), policy)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
