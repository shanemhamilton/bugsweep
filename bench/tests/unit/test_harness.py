"""Pure WU6 harness checks: no Git, Docker, network, or model invocation."""

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import jsonschema
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench import harness


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def _protocol() -> dict:
    arm = lambda name: {"skill_revision": name, "skill_content_sha256": _hash(name + "skill"), "skill_entrypoint_sha256": None if name == "no_skill_baseline" else _hash(name + "entrypoint"), "adapter_sha256": _hash(name + "adapter"), "prompt_sha256": _hash(name + "prompt"), "config_sha256": _hash(name + "config")}
    return {"schema_version": 1, "experiment_id": "e1", "seed": 7, "cap_approval": "operator-approved", "cap_approval_id": "approved", "limit_profile": "p", "limits": {"wall_clock_seconds": 30, "max_turns": 1, "max_input_tokens": 1, "max_output_tokens": 1, "max_spend_usd": None}, "rate_table": {"version": "operator-v1", "sha256": _hash("rate-card")}, "hosts": {host: {"model": host + "-model", "model_version": "v1", "arms": {name: arm(name) for name in harness.ARM_SET}} for host in ("claude", "codex")}, "core_arms": list(harness.ARM_SET), "ablation_blocks": [{"id": "full_pipeline", "stages": ["hunter", "skeptic", "referee", "synthesis"]}, {"id": "without_skeptic", "stages": ["hunter", "referee", "synthesis"]}, {"id": "without_referee", "stages": ["hunter", "skeptic", "synthesis"]}, {"id": "hunter_only", "stages": ["hunter"]}]}


def test_schedule_is_seeded_interleaved_and_has_every_core_slot() -> None:
    protocol = _protocol()
    cases = [{"id": "c1", "category": "security", "repository": "r", "source_manifest_sha256": _hash("c1"), "language": "python", "size_ceiling": {}, "task_description": "Inspect this source."}]
    first = harness.build_schedule(protocol, cases, 3)
    second = harness.build_schedule(protocol, cases, 3)
    order = harness.execution_order(protocol, first)
    assert first == second
    assert len(first) == 6
    assert len(order) == 72
    assert {slot["arm"] for slot in order} == set(harness.ARM_SET)
    assert all(slot["arms"] == list(harness.ARM_SET) for slot in first)
    assert [slot["ordinal"] for slot in order] == list(range(1, 73))
    assert all(len(slot["order_slot_sha256"]) == 64 for slot in order)


def test_freeze_binds_non_circular_schedule_and_execution_order_digests() -> None:
    cases = [{"id": "c1", "category": "security", "repository": "r", "source_manifest_sha256": _hash("c1"), "language": "python", "size_ceiling": {}, "task_description": "Inspect this source."}]
    frozen = harness.freeze_documents(_protocol(), cases, 3)
    assert frozen["protocol"]["schedule_sha256"] == harness.digest(frozen["schedule"])
    assert frozen["protocol"]["execution_order_sha256"] == harness.digest(frozen["execution_order"])
    harness.validate_protocol(frozen["protocol"], frozen=True)
    jsonschema.validate(frozen["protocol"], json.loads((Path(__file__).resolve().parents[2] / "schemas/evaluation-protocol.schema.json").read_text()))


def test_freeze_cli_writes_protocol_schedule_and_seeded_order(tmp_path: Path) -> None:
    protocol_path, cases_path, frozen_dir = tmp_path / "draft.json", tmp_path / "cases.json", tmp_path / "frozen"
    protocol_path.write_text(json.dumps(_protocol()))
    cases_path.write_text(json.dumps([{"id": "c1", "category": "security", "repository": "r", "source_manifest_sha256": _hash("c1"), "language": "python", "size_ceiling": {}, "task_description": "Inspect this source."}]))
    result = subprocess.run([sys.executable, "-B", str(Path(harness.__file__)), "--protocol", str(protocol_path), "--cases", str(cases_path), "-k", "3", "--freeze-dir", str(frozen_dir)], check=True, text=True, capture_output=True, env={"PYTHONDONTWRITEBYTECODE": "1"})
    written = json.loads(result.stdout)
    assert written["schedule_sha256"] == harness.digest(json.loads((frozen_dir / "schedule.json").read_text()))
    assert written["execution_order_sha256"] == harness.digest(json.loads((frozen_dir / "execution-order.json").read_text()))
    assert json.loads((frozen_dir / "evaluation-protocol.json").read_text())["schedule_sha256"] == written["schedule_sha256"]


def test_source_manifest_detects_new_and_changed_source_paths(tmp_path: Path) -> None:
    (tmp_path / "a.py").write_text("one\n")
    before = harness.source_manifest(tmp_path)
    (tmp_path / "a.py").write_text("two\n")
    changed = harness.source_manifest(tmp_path)
    (tmp_path / "new.py").write_text("three\n")
    added = harness.source_manifest(tmp_path)
    assert before["sha256"] != changed["sha256"] != added["sha256"]


def test_excerpts_are_read_from_source_not_response_text(tmp_path: Path) -> None:
    (tmp_path / "app.py").write_text("one\ntwo\nthree\n")
    raw = tmp_path / "response.jsonl"
    raw.write_text('{"text":"app.py:2 fabricated source sentence"}\n')
    excerpts = harness.trusted_source_excerpts(tmp_path, raw)
    assert excerpts[0]["text"] == "one\ntwo\nthree"
    assert "fabricated" not in excerpts[0]["text"]


def test_native_usage_preserves_unknown_cost_without_inventing_codex_price(tmp_path: Path) -> None:
    raw = tmp_path / "events.jsonl"
    raw.write_text(json.dumps({"type": "response.completed", "usage": {"input_tokens": 2, "output_tokens": 3}}) + "\n")
    usage = harness.native_usage(raw, "codex", _protocol()["rate_table"])
    assert usage["total_tokens"] == 5
    assert usage["cost_usd"] is None
    assert usage["cost_source"] == "unknown"


def test_native_usage_rejects_boolean_tokens_and_costs(tmp_path: Path) -> None:
    raw = tmp_path / "events.jsonl"
    raw.write_text(json.dumps({"usage": {"input_tokens": True, "output_tokens": False, "cost_usd": True}}) + "\n")
    usage = harness.native_usage(raw, "claude", _protocol()["rate_table"])
    assert usage["input_tokens"] is None and usage["output_tokens"] is None
    assert usage["cost_usd"] is None and usage["cost_source"] == "unknown"


def test_native_usage_names_rate_estimates_without_claiming_actual_cost(tmp_path: Path) -> None:
    raw = tmp_path / "events.jsonl"
    rate_table = _protocol()["rate_table"]
    raw.write_text(json.dumps({"usage": {"input_tokens": 2, "output_tokens": 3, "estimated_cost_usd": 0.02, "rate_table_version": rate_table["version"], "rate_table_sha256": rate_table["sha256"]}}) + "\n")
    usage = harness.native_usage(raw, "claude", rate_table)
    assert usage["cost_source"] == "rate_estimated" and usage["cost_usd"] == 0.02


def test_host_argv_uses_the_provider_verified_image_entrypoint() -> None:
    assert harness.adapter_argv("codex", "pinned", "review", "current_skill")[:4] == ["/usr/local/bin/bench-host-adapter", "codex", "pinned", "current_skill"]


def test_prompt_is_explicitly_detect_only_and_requires_first_finding_marker() -> None:
    prompt = harness._prompt({"id": "c1", "language": "python", "size_ceiling": {}, "task_description": "Inspect source."}, "current_skill")
    assert "REDUCED DETECT-ONLY PROMPT METHODOLOGY" in prompt and "Do not run commands, Git, trackers" in prompt
    assert "FINDING:" in prompt


@pytest.mark.parametrize("failure", [None, "before_receipt", "coordinator_error", "after_receipt", "interrupt"])
def test_managed_all_slots_start_invoke_stop_one_proxy_per_ordinal(tmp_path: Path, monkeypatch, failure) -> None:
    source = tmp_path / "archive"
    source.mkdir(); (source / "app.py").write_text("pass\n")
    manifest = harness.source_manifest(source)["sha256"]
    cases = [{"id": "c1", "category": "security", "repository": "r", "source_manifest_sha256": manifest, "language": "python", "size_ceiling": {}, "task_description": "Inspect this source."}]
    frozen = harness.freeze_documents(_protocol(), cases, 3)["protocol"]
    external = tmp_path / "external"
    results, proxy_receipts, profiles, output = (external / name for name in ("results", "receipts", "profiles", "output"))
    for directory in (results, proxy_receipts, profiles): directory.mkdir(parents=True)
    template = external / "template.json"
    template.write_text(json.dumps({"execution_policy": {"schema_version": 1}, "benchmark_static": {"analysis": {}, "client": {}, "arms": {}}}))
    secret = external / "secret"; secret.write_text("not-used")
    cap = external / "cap.json"; cap.write_text("{}")
    calls = []
    def fake_run(argv, **_kwargs):
        calls.append(argv)
        if argv[1] == "start":
            if failure == "coordinator_error":
                raise ValueError("synthetic coordinator failure")
            if failure == "before_receipt":
                raise subprocess.CalledProcessError(1, argv)
            run_id, host = argv[2], argv[3]
            receipt = {"schema_version": 1, "owner": "bench/lib/proxy.sh", "host": host,
                       "proxy": {"container_name": "bugsweep-proxy-" + run_id, "container_id": _hash(run_id), "image_digest": "sha256:" + "b" * 64},
                       "internal_network": {"name": "internal-" + run_id, "id": "c" * 64}, "egress_network": {"name": "egress-" + run_id, "id": "d" * 64},
                       "upstream": {"host": "api.anthropic.com" if host == "claude" else "api.openai.com", "allowed_paths": ["/v1/messages"] if host == "claude" else ["/v1/responses"]}, "limits": {}}
            (proxy_receipts / f"{run_id}.proxy-receipt.json").write_text(json.dumps(receipt))
            if failure == "after_receipt":
                raise subprocess.CalledProcessError(1, argv)
            if failure == "interrupt":
                raise KeyboardInterrupt
        return subprocess.CompletedProcess(argv, 0, "", "")
    monkeypatch.setattr(harness.subprocess, "run", fake_run)
    monkeypatch.setattr(harness, "invoke_slot", lambda protocol, slot, case, root, out, **_kwargs: {"ordinal": slot["ordinal"], "lifecycle": "completed", "execution_receipt_sha256": None, "configured_limits": protocol["limits"]})
    args = (frozen, cases, {"c1": str(source)}, {"claude": str(template), "codex": str(template)}, {"claude": str(secret), "codex": str(secret)}, {"claude": str(cap), "codex": str(cap)}, results, proxy_receipts, profiles, output)
    monkeypatch.setenv("BENCH_TRUSTED_BENCHMARK_PROFILE", "original")
    if failure == "interrupt":
        with pytest.raises(KeyboardInterrupt):
            harness.invoke_all_managed(*args)
        receipts = json.loads((output / "benchmark-receipts.json").read_text())
    else:
        receipts = harness.invoke_all_managed(*args)
    assert os.environ["BENCH_TRUSTED_BENCHMARK_PROFILE"] == "original"
    expected_slots = len(harness.execution_order(frozen, harness.build_schedule(frozen, cases, 3)))
    assert len(receipts) == expected_slots
    expected_calls = ["start"] if failure in {"before_receipt", "coordinator_error"} else ["start", "stop"] if failure == "interrupt" else [item for _ in range(expected_slots) for item in ("start", "stop")]
    assert [call[1] for call in calls] == expected_calls
    assert len(list(profiles.glob("*.json"))) == (0 if failure else expected_slots)
    if failure:
        assert all(receipt["lifecycle"] == "error" for receipt in receipts)
        coordinator = json.loads((output / "coordinator-receipt.json").read_text())
        assert coordinator["cleanup_pending_ordinals"] == ([1] if failure in {"before_receipt", "coordinator_error"} else [])


def test_preflight_fails_closed_without_operator_owned_network_profile(monkeypatch) -> None:
    monkeypatch.delenv("BENCH_TRUSTED_BENCHMARK_PROFILE", raising=False)
    monkeypatch.delenv("BENCH_CAP_APPROVAL_ID", raising=False)
    reasons = harness.preflight(_protocol())
    assert "trusted_benchmark_network_profile_missing" in reasons


@pytest.mark.parametrize("selected_arm", harness.ARM_SET)
def test_invoke_slot_uses_only_supported_outputs_and_allowlisted_environment(tmp_path: Path, monkeypatch, selected_arm) -> None:
    """Exercise producer declarations through the real shared validators."""
    from scripts import _execution
    source = tmp_path / "archive"
    source.mkdir(); (source / "app.py").write_text("pass\n")
    case = {"id": "c1", "category": "security", "repository": "r", "source_manifest_sha256": harness.source_manifest(source)["sha256"], "language": "python", "size_ceiling": {}, "task_description": "Inspect source."}
    frozen = harness.freeze_documents(_protocol(), [case], 3)["protocol"]
    slot = next(item for item in harness.execution_order(frozen, harness.build_schedule(frozen, [case], 3)) if item["arm"] == selected_arm)
    arm = frozen["hosts"][slot["host"]]["arms"][slot["arm"]]
    profile = {"network_mode": "approved-proxy-only", "target_root": str(source), "source_identity": harness.source_manifest(source),
               "benchmark_profile": {"host": slot["host"], "proxy": {"container_name": "owned-proxy", "container_id": _hash("proxy"), "image_digest": "sha256:" + "a" * 64},
                                     "client": {"inert_credential_literal": "benchmark-inert-client-credential"},
                                     "arms": {"current": {"skill_revision": frozen["hosts"][slot["host"]]["arms"]["current_skill"]["skill_revision"], "skill_content_sha256": frozen["hosts"][slot["host"]]["arms"]["current_skill"]["skill_content_sha256"]}, "previous": {"skill_revision": frozen["hosts"][slot["host"]]["arms"]["previous_release"]["skill_revision"], "skill_content_sha256": frozen["hosts"][slot["host"]]["arms"]["previous_release"]["skill_content_sha256"]}, "baseline": {"skill_revision": frozen["hosts"][slot["host"]]["arms"]["no_skill_baseline"]["skill_revision"], "skill_content_sha256": frozen["hosts"][slot["host"]]["arms"]["no_skill_baseline"]["skill_content_sha256"]}}}}
    profile_path = tmp_path / "profile.json"; profile_path.write_text(json.dumps(profile))
    output = tmp_path / "out"; output.mkdir()
    def fake_run(_argv, _root, output_dir, _deadline, _profile, env, outputs):
        _execution._validate_outputs(outputs)
        _execution._validate_environment(env)
        (output_dir / "response.jsonl").write_text('{"usage":{"input_tokens":1,"output_tokens":1}}\n')
        loaded = arm["skill_entrypoint_sha256"]
        (output_dir / "adapter-metadata.json").write_text(json.dumps({"effective_prompt_sha256": _hash("effective"), "loaded_skill_sha256": loaded, "first_finding_unix_seconds": None}))
        return {"termination": "exited", "exit_code": 0, "reason": None, "started_at": "2026-01-01T00:00:00.000000Z", "finished_at": "2026-01-01T00:00:01.000000Z", "applied_limits": {**frozen["limits"], "enforced": False}}
    monkeypatch.setattr(_execution, "run_command", fake_run)
    monkeypatch.setenv("BENCH_TRUSTED_BENCHMARK_PROFILE", str(profile_path)); monkeypatch.setenv("BENCH_CAP_APPROVAL_ID", "approved")
    receipt = harness.invoke_slot(frozen, slot, case, source, output)
    assert receipt["effective_prompt_sha256"] == _hash("effective")
    assert receipt["effective_prompt_binding_sha256"] == harness.effective_prompt_binding(_hash("effective"), case, arm)
