"""Pure fake-upstream tests for the stdlib benchmark provider proxy."""

import http.client
import importlib.util
import json
import sys
import threading
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[3]


def _module():
    spec = importlib.util.spec_from_file_location("bench_provider_proxy", ROOT / "bench/provider_proxy.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _policy_file(tmp_path: Path, *, spend: float | None = 1.0) -> Path:
    secret = tmp_path / "secret"
    secret.write_text("provider-secret\n")
    policy = {
        "schema_version": 1, "host": "claude", "upstream": "api.anthropic.com",
        "allowed_method": "POST", "allowed_paths": ["/v1/messages"],
        "secret_path": str(secret), "listen_port": 8888, "model": "pinned-model",
        "controls": {"max_request_bytes": 4096, "max_response_bytes": 4096,
                     "max_inflight_requests": 2, "reservation_usd": 0.4 if spend is not None else None,
                     "input_usd_per_million_tokens": 1.0, "output_usd_per_million_tokens": 2.0},
        "limits": {"wall_clock_seconds": 60, "max_turns": 2, "max_input_tokens": 4096,
                   "max_output_tokens": 7, "max_spend_usd": spend, "enforcement": {}},
    }
    path = tmp_path / "policy.json"
    path.write_text(json.dumps(policy))
    return path


def test_proxy_rewrites_inert_auth_and_clamps_output_against_a_fake_upstream(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    proxy = _module()
    policy = proxy.load_policy(str(_policy_file(tmp_path)))
    observed: dict[str, object] = {}

    class Response:
        status = 200
        def read(self, _maximum: int) -> bytes:
            return b'{"usage":{"input_tokens":3,"output_tokens":4}}'
        def getheader(self, _name: str):
            return "application/json" if _name == "Content-Type" else None

    class Connection:
        def __init__(self, host: str, timeout: int) -> None:
            observed["host"], observed["timeout"] = host, timeout
        def request(self, method: str, path: str, body: bytes, headers: dict[str, str]) -> None:
            observed.update(method=method, path=path, body=json.loads(body), headers=headers)
        def getresponse(self) -> Response:
            return Response()

    monkeypatch.setattr(proxy.http.client, "HTTPSConnection", Connection)
    server = proxy.ProviderProxy(("127.0.0.1", 0), policy)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        client = http.client.HTTPConnection("127.0.0.1", server.server_address[1])
        request = json.dumps({"model": "pinned-model", "messages": [], "max_tokens": 4})
        client.request("POST", "/v1/messages", request,
                       {"x-api-key": proxy.INERT_CREDENTIAL, "Content-Type": "application/json"})
        response = client.getresponse()
        assert response.status == 200
        assert json.loads(response.read())["usage"]["output_tokens"] == 4
    finally:
        server.shutdown()
        worker.join(timeout=2)
        server.server_close()
    assert observed["host"] == "api.anthropic.com"
    assert observed["headers"]["x-api-key"] == "provider-secret"
    assert observed["body"]["max_tokens"] == 7


def test_proxy_budget_reserves_before_each_inflight_request(tmp_path: Path) -> None:
    proxy = _module()
    budget = proxy.Budget(proxy.load_policy(str(_policy_file(tmp_path, spend=0.5))))
    budget.admit(10, 7)
    with pytest.raises(proxy.PolicyError, match="spend reservation exhausted"):
        budget.admit(10, 7)


def test_proxy_labels_operator_rate_card_costs_as_rate_estimated(tmp_path: Path) -> None:
    proxy = _module()
    budget = proxy.Budget(proxy.load_policy(str(_policy_file(tmp_path))))
    reservation = budget.admit(10, 7)
    assert budget.settle(reservation, 10, 7, 2, 3, uncertain=False)["cost_source"] == "rate_estimated"


def test_proxy_rejects_unpinned_model_before_forwarding(tmp_path: Path) -> None:
    proxy = _module()
    policy = proxy.load_policy(str(_policy_file(tmp_path)))
    with pytest.raises(proxy.PolicyError, match="model is not pinned"):
        proxy.normalize_request(policy, b'{"model":"other","messages":[]}')
