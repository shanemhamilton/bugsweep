"""Synthetic native output exercises offline frame production; no model calls."""
import hashlib
import json

import pytest

from bench import _stages
from bench.scorer.harness_results import candidates_from_message


def test_candidates_keep_full_slot_identity_rejections_and_trusted_source():
    receipt = {"experiment_id": "e", "host": "codex", "arm": "current_skill", "case_id": "c", "repetition": 1, "order_slot_sha256": "a" * 64,
               "trusted_source_excerpts": [{"path": "app.py", "start_line": 1, "end_line": 1, "source_sha256": hashlib.sha256(b"pass\n").hexdigest(), "text": "pass"}]}
    candidate = {"bug_id": "B1", "file": "app.py", "location": "app.py:1", "line": 1, "severity": "high", "status": "rejected", "rationale": "reason", "trigger": "condition"}
    rows = candidates_from_message(json.dumps({"candidates": [candidate]}), receipt, {"category": "logic", "repository": "repo"})
    assert rows[0]["status"] == "rejected"
    assert rows[0]["evidence"]["source"]["excerpt"] == "pass"
    assert rows[0]["evidence"]["trigger"] == {"kind": "reported_condition", "value": "condition"}
    other = candidates_from_message(json.dumps({"candidates": [candidate]}), {**receipt, "host": "claude", "order_slot_sha256": "b" * 64}, {})
    assert rows[0]["candidate_id"] != other[0]["candidate_id"]
    candidate["line"] = 20; candidate["location"] = "app.py:20"
    missing = candidates_from_message(json.dumps({"candidates": [candidate]}), receipt, {})
    assert missing[0]["evidence"]["status"] == "unverified"


@pytest.mark.parametrize("message", ['prose', '{"candidates": [null]}', '{"candidates": [{}]}', '{"candidates":[],"candidates":[]}'])
def test_invalid_native_candidate_output_cannot_become_zero_findings(message):
    with pytest.raises(ValueError):
        candidates_from_message(message, {}, {})
    assert candidates_from_message('{"candidates": []}', {}, {}) == []


def test_offline_import_preserves_missing_failed_and_malformed_slots(tmp_path, monkeypatch):
    from bench import harness
    from bench.scorer import harness_results, precision_score
    from bench.tests.unit.test_harness import _protocol
    source, frozen_dir, results = (tmp_path / name for name in ("source", "frozen", "results"))
    for directory in (source, frozen_dir, results):
        directory.mkdir()
    (source / "app.py").write_text("pass\n")
    manifest = harness.source_manifest(source)
    case = {"id": "c1", "source_manifest_sha256": manifest["sha256"], "language": "python", "size_ceiling": {}, "task_description": "Inspect source.", "repository": "repo", "category": "logic"}
    frozen = harness.freeze_documents(_protocol(), [case], 3)
    for name, key in (("evaluation-protocol.json", "protocol"), ("schedule.json", "schedule"), ("execution-order.json", "execution_order")):
        harness.write_once(frozen_dir / name, frozen[key])
    receipts = []
    selected = [slot for slot in frozen["execution_order"] if slot["stage_block"] == "full_pipeline"]
    successful_ordinal = selected[1]["ordinal"]
    for slot in frozen["execution_order"]:
        if slot["ordinal"] == selected[0]["ordinal"]:  # selected first invocation is absent
            continue
        receipt = harness._error_receipt(frozen["protocol"], slot, manifest, "startup_failed")
        if slot["ordinal"] == successful_ordinal:
            directory = results / f"invocation-{slot['ordinal']:06d}"; directory.mkdir()
            # Synthetic transport receipt: isolation itself is covered by provider tests.
            message = '{"candidates": []}'
            stage_receipts = []
            assessments = {}
            for index, stage in enumerate(("hunter", "skeptic", "referee", "synthesis"), start=1):
                stage_dir = directory / "stages" / f"{index:02d}-{stage}"; stage_dir.mkdir(parents=True)
                session = f"s-{index}"
                native = [{"type": "thread.started", "thread_id": session}, {"type": "item.completed", "item": {"type": "agent_message", "text": message}}, {"type": "turn.completed"}] if slot["host"] == "codex" else [{"type": "system", "subtype": "init", "session_id": session}, {"type": "result", "subtype": "success", "session_id": session, "result": message}]
                raw = "\n".join(json.dumps(event) for event in native).encode()
                raw_path = stage_dir / "response.jsonl"; raw_path.write_bytes(raw)
                execution = {"source_identity": manifest, "outputs": [{"path": str(raw_path), "sha256": hashlib.sha256(raw).hexdigest()}]}
                harness.write_once(stage_dir / "execution-receipt.json", execution)
                prompt_sha = (str(index) * 64)[:64]
                (stage_dir / "adapter-metadata.json").write_text(json.dumps({"effective_prompt_sha256": prompt_sha, "loaded_skill_sha256": receipt["provenance"]["skill_entrypoint_sha256"], "first_finding_unix_seconds": None}))
                stage_receipts.append({"stage": stage, "role": stage, "model": slot["model"], "source_manifest_sha256": manifest["sha256"], "source_valid": True, "candidate_input_sha256": harness.digest(_stages.stage_input(stage, assessments)), "stage_prompt_template_sha256": harness.digest(_stages.stage_prompt(stage)), "prompt_sha256": prompt_sha, "execution_receipt_sha256": harness.digest(execution), "raw_response_path": str(raw_path), "raw_response_sha256": hashlib.sha256(raw).hexdigest(), "native_session_id": session, "lifecycle": "completed", "reason_code": None})
                assessments[stage] = []
            receipt["applied_limits"].pop("reason")
            receipt.update(lifecycle="completed", source={"expected_manifest_sha256": manifest["sha256"], "observed_pre_manifest_sha256": manifest["sha256"], "observed_post_manifest_sha256": manifest["sha256"], "valid": True},
                           effective_prompt_sha256="e" * 64, effective_prompt_binding_sha256=harness.effective_prompt_binding("e" * 64, slot, receipt["provenance"]), execution_receipt_sha256=harness.digest(execution), raw_response_sha256=hashlib.sha256(raw).hexdigest(),
                           stage_lineage={"block_id": "full_pipeline", "stages": ["hunter", "skeptic", "referee", "synthesis"], "stage_count": 4, "role": "detect_only", "host": slot["host"], "model": slot["model"], "model_version": receipt["provenance"]["model_version"], "source_manifest_sha256": manifest["sha256"], "deadline_epoch": 1, "configured_total_limits": receipt["configured_limits"], "stage_prompt_template_sha256": {stage["stage"]: stage["stage_prompt_template_sha256"] for stage in stage_receipts}, "proxy": {"container_id": "p"}}, stage_receipts=stage_receipts)
            harness.write_once(directory / "benchmark-invocation-receipt.json", receipt)
        receipts.append(receipt)
    harness.write_once(results / "benchmark-receipts.json", receipts)
    harness.write_once(results / "coordinator-receipt.json", {"schedule_sha256": frozen["protocol"]["schedule_sha256"], "execution_order_sha256": frozen["protocol"]["execution_order_sha256"], "receipt_sha256": harness.digest(receipts)})
    monkeypatch.setattr(harness_results, "validate_execution_receipt", lambda *_args, **_kwargs: [])
    bundle = harness_results.import_harness_results(results, frozen_dir)
    assert bundle["stage_block"] == "full_pipeline"
    assert len(bundle["runs"]) == len(selected) and bundle["frame_complete"] is False
    assert bundle["runs"][0]["reason"] == "receipt_missing"
    parsed = next(run for run in bundle["runs"] if run["ordinal"] == successful_ordinal)
    assert parsed["status"] == "parsed" and parsed["candidates"] == 0
    assert bundle["runs"][2]["reason"] == "invocation_error"
    ablation = harness_results.import_harness_results(results, frozen_dir, stage_block="hunter_only")
    assert ablation["stage_block"] == "hunter_only" and all(run["stage_block"] == "hunter_only" for run in ablation["runs"])
    with pytest.raises(ValueError, match="selected stage block"):
        harness_results.import_harness_results(results, frozen_dir, stage_block="not_frozen")
    output = tmp_path / "review-export"
    assert precision_score.main([str(output), "--harness-results", str(results), "--frozen-dir", str(frozen_dir)]) == 0
    assert json.loads((output / "calibration-records.json").read_text())["labels"] == []
    assert json.loads((output / "blinded-packets.json").read_text()) == []
    from bench.scorer import calibration_finalize
    labels, adjudications = tmp_path / "labels.json", tmp_path / "adjudications.json"
    labels.write_text("[]"); adjudications.write_text("[]")
    completed = tmp_path / "completed-calibration"
    assert calibration_finalize.main(["--records", str(output / "calibration-records.json"), "--labels", str(labels), "--adjudications", str(adjudications), "--output-dir", str(completed), "--source-manifest-sha256", manifest["sha256"]]) == 0
    assert json.loads((completed / "human-calibration.json").read_text())["result"] == "blocked"
    assert json.loads((completed / "completed-calibration-records.json").read_text())["input_roots"] == bundle["input_roots"]
    from bench.scorer.calibration import evaluation_calibration_from_records
    assert evaluation_calibration_from_records(bundle, receipts)["hosts"] == {}
    bundle["runs"][0]["status"] = "parsed"
    with pytest.raises(ValueError, match="native evidence"):
        evaluation_calibration_from_records(bundle, receipts)
    raw_path.write_text("altered")
    changed = harness_results.import_harness_results(results, frozen_dir)
    changed_run = next(run for run in changed["runs"] if run["ordinal"] == successful_ordinal)
    assert changed_run["candidates"] is None
    assert changed_run["reason"] == "native_evidence_unverified"
