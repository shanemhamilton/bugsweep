"""Pure contracts for detect-only pipeline-stage interventions."""

import hashlib
import json
from pathlib import Path

import pytest

from bench import _stages
from bench import harness


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def _protocol() -> dict:
    arm = lambda name: {"skill_revision": name, "skill_content_sha256": _hash(name + "skill"), "skill_entrypoint_sha256": None if name == "no_skill_baseline" else _hash(name + "entry"), "adapter_sha256": _hash(name + "adapter"), "prompt_sha256": _hash(name + "prompt"), "config_sha256": _hash(name + "config")}
    return {"schema_version": 1, "experiment_id": "e", "seed": 1, "cap_approval": "operator-approved", "cap_approval_id": "cap", "limit_profile": "p", "limits": {"wall_clock_seconds": 30, "max_turns": 1, "max_input_tokens": 1, "max_output_tokens": 1, "max_spend_usd": None}, "rate_table": {"version": "v", "sha256": _hash("rate")}, "hosts": {host: {"model": host + "-model", "model_version": "v1", "arms": {name: arm(name) for name in harness.ARM_SET}} for host in ("claude", "codex")}, "core_arms": list(harness.ARM_SET), "ablation_blocks": [{"id": "full_pipeline", "stages": ["hunter", "skeptic", "referee", "synthesis"]}, {"id": "hunter_only", "stages": ["hunter"]}]}


def test_stage_blocks_are_independent_and_keep_the_full_pipeline_control() -> None:
    blocks = _stages.normalize_stage_blocks([
        {"id": "full_pipeline", "stages": ["hunter", "skeptic", "referee", "synthesis"]},
        {"id": "without_skeptic", "stages": ["hunter", "referee", "synthesis"]},
        {"id": "without_referee", "stages": ["hunter", "skeptic", "synthesis"]},
        {"id": "hunter_only", "stages": ["hunter"]},
    ])
    assert blocks[0]["id"] == "full_pipeline"
    assert len({tuple(block["stages"]) for block in blocks}) == len(blocks)


def test_fresh_stage_prompts_hide_skeptic_verdicts_from_referee() -> None:
    hunter = [{"bug_id": "b", "file": "app.py", "location": "app.py:1", "line": 1, "rationale": "claim", "trigger": "input", "severity": "high", "status": "confirmed"}]
    assessments = {"hunter": hunter}
    skeptic = _stages.stage_prompt("skeptic", assessments=assessments)
    referee = _stages.stage_prompt("referee", assessments=assessments)
    assert skeptic != referee
    assert "Skeptic verdicts and confidence are deliberately withheld" in referee
    assert '"status"' not in referee.split("Hunter claims:\n", 1)[1]
    assert '{"candidates": [...]}' in referee


def test_synthesis_gets_preserved_role_outputs_and_every_role_audits_hunter_ids() -> None:
    hunter = [{"bug_id": "b", "file": "app.py", "location": "app.py:1", "line": 1, "rationale": "claim", "trigger": "input", "severity": "high", "status": "confirmed"}]
    skeptic = [{**hunter[0], "rationale": "skeptic rejects", "status": "rejected"}]
    referee = [{**hunter[0], "rationale": "referee confirms", "status": "confirmed"}]
    handoff = _stages.stage_input("synthesis", {"hunter": hunter, "skeptic": skeptic, "referee": referee})
    assert handoff["skeptic_assessment"]["candidates"] == skeptic
    assert handoff["referee_assessment"]["candidates"] == referee
    _stages.validate_stage_candidates("synthesis", referee, {"hunter": hunter})
    with pytest.raises(ValueError):
        _stages.validate_stage_candidates("skeptic", [], {"hunter": hunter})


def test_candidate_contract_rejects_free_form_or_bad_locations() -> None:
    valid = '{"candidates":[{"bug_id":"b","file":"app.py","location":"app.py:1","line":1,"rationale":"r","trigger":"t","severity":"high","status":"confirmed"}]}'
    assert _stages.parse_candidates(valid)[0]["bug_id"] == "b"
    try:
        _stages.parse_candidates('{"candidates":[{"bug_id":"b","file":"app.py","location":"wrong","line":1,"rationale":"r","trigger":"t","severity":"high","status":"confirmed"}]}')
    except ValueError:
        pass
    else:
        raise AssertionError("bad locations must be rejected")


@pytest.mark.parametrize("reused_stage", [None, 2, 4])
def test_full_pipeline_runs_fresh_native_stages_under_one_deadline(tmp_path: Path, monkeypatch, reused_stage: int | None) -> None:
    source = tmp_path / "source"; source.mkdir(); (source / "app.py").write_text("bug\n")
    case = {"id": "c", "category": "logic", "repository": "r", "source_manifest_sha256": harness.source_manifest(source)["sha256"], "language": "python", "size_ceiling": {}, "task_description": "Inspect."}
    frozen = harness.freeze_documents(_protocol(), [case], 3)["protocol"]
    slot = next(row for row in harness.execution_order(frozen, harness.build_schedule(frozen, [case], 3)) if row["host"] == "codex" and row["arm"] == "current_skill" and row["stage_block"] == "full_pipeline")
    arm = frozen["hosts"]["codex"]["arms"]["current_skill"]
    profile = {"network_mode": "approved-proxy-only", "target_root": str(source), "source_identity": harness.source_manifest(source), "benchmark_profile": {"host": "codex", "proxy": {"container_name": "owned", "container_id": _hash("proxy"), "image_digest": "sha256:" + "a" * 64}, "client": {"inert_credential_literal": "benchmark-inert-client-credential"}, "arms": {"current": {"skill_revision": arm["skill_revision"], "skill_content_sha256": arm["skill_content_sha256"]}, "previous": {"skill_revision": frozen["hosts"]["codex"]["arms"]["previous_release"]["skill_revision"], "skill_content_sha256": frozen["hosts"]["codex"]["arms"]["previous_release"]["skill_content_sha256"]}, "baseline": {"skill_revision": frozen["hosts"]["codex"]["arms"]["no_skill_baseline"]["skill_revision"], "skill_content_sha256": frozen["hosts"]["codex"]["arms"]["no_skill_baseline"]["skill_content_sha256"]}}}}
    profile_path = tmp_path / "profile.json"; profile_path.write_text(json.dumps(profile))
    deadlines, profiles = [], []
    def fake_run(_argv, _root, out, deadline, received_profile, _env, _outputs):
        deadlines.append(deadline); profiles.append(received_profile)
        text = json.dumps({"candidates": [{"bug_id": "b", "file": "app.py", "location": "app.py:1", "line": 1, "rationale": "r", "trigger": "t", "severity": "high", "status": "confirmed"}]})
        session = 1 if reused_stage == len(deadlines) else len(deadlines)
        (out / "response.jsonl").write_text("\n".join([json.dumps({"type": "thread.started", "thread_id": f"native-{session}"}), json.dumps({"usage": {"input_tokens": 1, "output_tokens": 2, "cost_usd": .01}}), json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": text}}), json.dumps({"type": "turn.completed"})]))
        (out / "adapter-metadata.json").write_text(json.dumps({"effective_prompt_sha256": _hash(str(len(deadlines))), "loaded_skill_sha256": arm["skill_entrypoint_sha256"], "first_finding_unix_seconds": 1767225600.5 if len(deadlines) == 1 else None}))
        start = (0, 2, 5, 7)[len(deadlines) - 1]
        finish = (1, 4, 6, 8)[len(deadlines) - 1]
        return {"termination": "exited", "exit_code": 0, "started_at": f"2026-01-01T00:00:0{start}Z", "finished_at": f"2026-01-01T00:00:0{finish}Z", "applied_limits": {**frozen["limits"], "enforced": False}}
    import scripts._execution as execution
    monkeypatch.setattr(execution, "run_command", fake_run)
    monkeypatch.setenv("BENCH_TRUSTED_BENCHMARK_PROFILE", str(profile_path)); monkeypatch.setenv("BENCH_CAP_APPROVAL_ID", "cap")
    receipt = harness.invoke_slot(frozen, slot, case, source, tmp_path / "out")
    assert len(deadlines) == 4 and len(set(deadlines)) == 1 and profiles == [profile] * 4
    assert [stage["stage"] for stage in receipt["stage_receipts"]] == ["hunter", "skeptic", "referee", "synthesis"]
    assert receipt["stage_receipts"][-1]["native_session_id"] == ("native-1" if reused_stage == 4 else "native-4")
    assert receipt["stage_receipts"][1]["candidate_input_sha256"] == receipt["stage_receipts"][2]["candidate_input_sha256"]
    assert [stage["lifecycle"] for stage in receipt["stage_receipts"]] == (["completed"] * 4 if reused_stage is None else ["completed", "error", "error", "error"] if reused_stage == 2 else ["completed", "completed", "completed", "error"])
    assert receipt["lifecycle"] == ("completed" if reused_stage is None else "error")
    assert receipt["usage"]["input_tokens"] == 4
    assert receipt["usage"]["output_tokens"] == 8
    assert receipt["usage"]["cost_usd"] == .04
    assert receipt["usage"]["wall_clock_seconds"] == 8
    assert receipt["first_finding_wallclock_seconds"] == .5


def test_stage_error_keeps_prior_and_later_native_receipts(tmp_path: Path, monkeypatch) -> None:
    source = tmp_path / "source"; source.mkdir(); (source / "app.py").write_text("bug\n")
    case = {"id": "c", "category": "logic", "repository": "r", "source_manifest_sha256": harness.source_manifest(source)["sha256"], "language": "python", "size_ceiling": {}, "task_description": "Inspect."}
    frozen = harness.freeze_documents(_protocol(), [case], 3)["protocol"]
    slot = next(row for row in harness.execution_order(frozen, harness.build_schedule(frozen, [case], 3)) if row["host"] == "codex" and row["arm"] == "current_skill" and row["stage_block"] == "full_pipeline")
    arm = frozen["hosts"]["codex"]["arms"]["current_skill"]
    profile = {"network_mode": "approved-proxy-only", "target_root": str(source), "source_identity": harness.source_manifest(source), "benchmark_profile": {"host": "codex", "proxy": {"container_name": "owned", "container_id": _hash("proxy"), "image_digest": "sha256:" + "a" * 64}, "client": {"inert_credential_literal": "benchmark-inert-client-credential"}, "arms": {"current": {"skill_revision": arm["skill_revision"], "skill_content_sha256": arm["skill_content_sha256"]}, "previous": {"skill_revision": frozen["hosts"]["codex"]["arms"]["previous_release"]["skill_revision"], "skill_content_sha256": frozen["hosts"]["codex"]["arms"]["previous_release"]["skill_content_sha256"]}, "baseline": {"skill_revision": frozen["hosts"]["codex"]["arms"]["no_skill_baseline"]["skill_revision"], "skill_content_sha256": frozen["hosts"]["codex"]["arms"]["no_skill_baseline"]["skill_content_sha256"]}}}}
    profile_path = tmp_path / "profile.json"; profile_path.write_text(json.dumps(profile))
    calls = []
    def fake_run(_argv, _root, out, _deadline, _profile, _env, _outputs):
        calls.append(out)
        if len(calls) == 2:
            (out / "response.jsonl").write_text(json.dumps({"usage": {"input_tokens": 1, "output_tokens": 2, "cost_usd": .01}}))
            raise OSError("synthetic stage failure")
        text = json.dumps({"candidates": [{"bug_id": "b", "file": "app.py", "location": "app.py:1", "line": 1, "rationale": "r", "trigger": "t", "severity": "high", "status": "confirmed"}]})
        (out / "response.jsonl").write_text("\n".join([json.dumps({"type": "thread.started", "thread_id": str(len(calls))}), json.dumps({"usage": {"input_tokens": 1, "output_tokens": 2, "cost_usd": .01}}), json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": text}}), json.dumps({"type": "turn.completed"})]))
        (out / "adapter-metadata.json").write_text(json.dumps({"effective_prompt_sha256": _hash(str(len(calls))), "loaded_skill_sha256": arm["skill_entrypoint_sha256"], "first_finding_unix_seconds": None}))
        return {"termination": "exited", "exit_code": 0, "started_at": "2026-01-01T00:00:00Z", "finished_at": "2026-01-01T00:00:01Z", "applied_limits": {**frozen["limits"], "enforced": False}}
    import scripts._execution as execution
    monkeypatch.setattr(execution, "run_command", fake_run)
    monkeypatch.setenv("BENCH_TRUSTED_BENCHMARK_PROFILE", str(profile_path)); monkeypatch.setenv("BENCH_CAP_APPROVAL_ID", "cap")
    receipt = harness.invoke_slot(frozen, slot, case, source, tmp_path / "out")
    assert len(calls) == 4
    assert [stage["lifecycle"] for stage in receipt["stage_receipts"]] == ["completed", "error", "error", "error"]
    assert receipt["lifecycle"] == "error"
    assert receipt["usage"]["cost_usd"] == .04
