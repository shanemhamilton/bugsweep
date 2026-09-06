"""Evaluation reducer rejects altered evidence and leaves missing slots visible."""

import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.evaluation import EvaluationError, reduce_evaluation, verify_published_evaluation
from jsonschema.validators import Draft202012Validator


@pytest.mark.parametrize("field,value", [("label", "false"), ("seconds", 3), ("reason", "different"), ("reviewer_id", "c"), ("role", "adjudicator"), ("review_id", "different")])
def test_human_artifact_cannot_change_measured_label_records(field, value):
    from bench.scorer.evaluation import _valid_human_calibration_payload
    labels = [{"candidate_id": "c1", "review_id": "r1", "reviewer_id": reviewer, "role": "primary", "label": "real", "seconds": 1, "reason": "shown"} for reviewer in ("a", "b")]
    calibration = {"frame_sha256": "f" * 64, "sampled_candidate_ids": ["c1"], "metrics": {}, "labels": labels, "labels_sha256": _digest(labels)}
    content = {"payload": {"frame_sha256": calibration["frame_sha256"], "calibration_sha256": _digest(calibration), "reviewed_candidate_ids": ["c1"], "metrics": {}, "labels": json.loads(json.dumps(labels)), "labels_sha256": _digest(labels)}}
    assert _valid_human_calibration_payload(content, calibration)
    content["payload"]["labels"][0][field] = value
    assert not _valid_human_calibration_payload(content, calibration)


def _digest(value):
    return hashlib.sha256(__import__("json").dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _inputs():
    schedule = [{"experiment_id": "e1", "host": "codex", "model": "m", "case_id": "case-1", "category": "security", "repository": "r1", "repetition": 1, "limit_profile": "p", "source_manifest_sha256": "d" * 64, "arms": ["current_skill", "previous_release", "no_skill_baseline"]}]
    arms = {
        arm: {"skill_revision": arm + "-rev", "skill_content_sha256": arm[0] * 64, "adapter_sha256": "a" * 64, "prompt_sha256": "b" * 64, "config_sha256": "c" * 64}
        for arm in schedule[0]["arms"]
    }
    protocol = {"schema_version": 1, "experiment_id": "e1", "seed": 7, "dataset_manifest_sha256": "d" * 64, "schedule_sha256": _digest(schedule), "limit_profile": "p", "limits": {"wall_clock_seconds": 30}, "hosts": {"codex": {"model": "m", "model_version": "v1", "arms": arms}}, "matching_policy": "exact"}
    def receipt(arm):
        return {"schema_version": 1, "experiment_id": "e1", "host": "codex", "model": "m", "case_id": "case-1", "repetition": 1, "limit_profile": "p", "arm": arm, "provenance": {"model_version": "v1", **arms[arm]}, "configured_limits": {"wall_clock_seconds": 30}, "applied_limits": {"wall_clock_seconds": 30, "enforced": True}, "source": {"expected_manifest_sha256": "d" * 64, "observed_pre_manifest_sha256": "d" * 64, "observed_post_manifest_sha256": "d" * 64, "valid": True}, "lifecycle": "completed", "result": "detected", "reason_code": None, "usage": {"input_tokens": 3, "output_tokens": 4, "total_tokens": 7, "cost_usd": 0.01, "cost_source": "actual", "wall_clock_seconds": 3}, "accounting_state": "complete"}
    return protocol, schedule, [receipt(arm) for arm in schedule[0]["arms"]]


def _bind_execution_order(protocol, schedule, receipts):
    from bench.harness import effective_prompt_binding
    protocol["repetitions"] = 3
    protocol["evaluation_mode"] = "reduced_detect_only_prompt_methodology"
    schedule[0]["redacted_manifest_sha256"] = "f" * 64
    schedule_slot = dict(schedule[0])
    schedule[0]["schedule_slot_sha256"] = _digest(schedule_slot)
    protocol["schedule_sha256"] = _digest(schedule)
    order = []
    for ordinal, arm in enumerate(schedule[0]["arms"], start=1):
        slot = {**schedule[0], "arm": arm, "ordinal": ordinal}
        slot["order_slot_sha256"] = _digest({"ordinal": ordinal, "schedule_slot_sha256": slot["schedule_slot_sha256"], "arm": arm})
        order.append(slot)
        receipt = next(item for item in receipts if item["arm"] == arm)
        receipt.update({field: slot[field] for field in ("ordinal", "schedule_slot_sha256", "order_slot_sha256")})
    protocol["execution_order_sha256"] = _digest(order)
    for receipt in receipts:
        receipt["schedule_sha256"] = protocol["schedule_sha256"]
        receipt["execution_order_sha256"] = protocol["execution_order_sha256"]
        receipt["evaluation_mode"] = protocol["evaluation_mode"]
        receipt["effective_prompt_sha256"] = "e" * 64
        receipt["effective_prompt_binding_sha256"] = effective_prompt_binding("e" * 64, schedule[0], receipt["provenance"])
    return order


def test_reducer_preserves_arm_specific_pins_and_missing_slots() -> None:
    protocol, schedule, receipts = _inputs()
    result = reduce_evaluation(protocol, schedule, receipts[:2])
    host = result["hosts"]["codex"]
    assert host["expected_slots"] == 3
    assert host["missing_slots"] == 1
    assert result["evaluation_decision"] == "inconclusive"


def test_reducer_retains_bound_error_receipt_in_denominator() -> None:
    protocol, schedule, receipts = _inputs()
    order = _bind_execution_order(protocol, schedule, receipts)
    error = receipts[0]
    error.update({"lifecycle": "error", "result": "error", "reason_code": "profile_missing", "accounting_state": "unknown"})
    error["effective_prompt_sha256"] = None
    error["applied_limits"] = {"wall_clock_seconds": None, "enforced": False, "reason": "not_started", "proof_execution_receipt_sha256": None}
    error["source"] = {"expected_manifest_sha256": "d" * 64, "observed_pre_manifest_sha256": None, "observed_post_manifest_sha256": None, "valid": False}
    error["usage"] = {"input_tokens": None, "output_tokens": None, "total_tokens": None, "cost_usd": None, "cost_source": "unknown", "wall_clock_seconds": None}
    result = reduce_evaluation(protocol, schedule, receipts, execution_order=order)
    host = result["hosts"]["codex"]
    assert host["received_slots"] == host["expected_slots"] == 3
    assert host["lifecycle"]["error"] == 1
    assert host["attrition"] == pytest.approx(1 / 3)


def test_reducer_retains_truthful_post_start_error_limit_observations() -> None:
    protocol, schedule, receipts = _inputs()
    order = _bind_execution_order(protocol, schedule, receipts)
    error = receipts[0]
    error.update({"lifecycle": "error", "result": "error", "reason_code": "deadline", "accounting_state": "incomplete", "effective_prompt_sha256": None})
    error["applied_limits"] = {"wall_clock_seconds": 30, "enforced": True, "reason": "deadline", "proof_execution_receipt_sha256": "a" * 64}
    result = reduce_evaluation(protocol, schedule, receipts, execution_order=order)
    assert result["hosts"]["codex"]["lifecycle"]["error"] == 1


def test_reducer_rejects_receipt_with_wrong_frozen_order_slot() -> None:
    protocol, schedule, receipts = _inputs()
    order = _bind_execution_order(protocol, schedule, receipts)
    receipts[0]["order_slot_sha256"] = "z" * 64
    with pytest.raises(EvaluationError, match="execution-order"):
        reduce_evaluation(protocol, schedule, receipts, execution_order=order)


def test_reducer_rejects_wrong_evaluation_mode_or_missing_effective_prompt() -> None:
    protocol, schedule, receipts = _inputs()
    order = _bind_execution_order(protocol, schedule, receipts)
    receipts[0]["evaluation_mode"] = "different"
    with pytest.raises(EvaluationError, match="evaluation mode"):
        reduce_evaluation(protocol, schedule, receipts, execution_order=order)


def test_reducer_accepts_effective_prompt_bound_to_case_and_rejects_rebinding() -> None:
    protocol, schedule, receipts = _inputs()
    order = _bind_execution_order(protocol, schedule, receipts)
    assert reduce_evaluation(protocol, schedule, receipts, execution_order=order)["hosts"]["codex"]["received_slots"] == 3
    assert "scheduled_repetitions_incomplete" in reduce_evaluation(protocol, schedule, receipts, execution_order=order)["hosts"]["codex"]["comparability_reasons"]
    receipts[0]["effective_prompt_sha256"] = "a" * 64
    with pytest.raises(EvaluationError, match="effective prompt"):
        reduce_evaluation(protocol, schedule, receipts, execution_order=order)
    protocol, schedule, receipts = _inputs()
    order = _bind_execution_order(protocol, schedule, receipts)
    receipts[0]["effective_prompt_sha256"] = None
    with pytest.raises(EvaluationError, match="effective prompt"):
        reduce_evaluation(protocol, schedule, receipts, execution_order=order)


def test_reducer_rejects_wrong_arm_pin_or_source_mutation() -> None:
    protocol, schedule, receipts = _inputs()
    receipts[0]["provenance"]["skill_content_sha256"] = "z" * 64
    with pytest.raises(EvaluationError, match="provenance"):
        reduce_evaluation(protocol, schedule, receipts)
    protocol, schedule, receipts = _inputs()
    receipts[0]["source"]["observed_post_manifest_sha256"] = "z" * 64
    with pytest.raises(EvaluationError, match="source"):
        reduce_evaluation(protocol, schedule, receipts)


def test_reducer_binds_each_slot_to_its_source_manifest() -> None:
    protocol, schedule, receipts = _inputs()
    schedule[0]["source_manifest_sha256"] = "f" * 64
    protocol["schedule_sha256"] = _digest(schedule)
    with pytest.raises(EvaluationError, match="source"):
        reduce_evaluation(protocol, schedule, receipts)


def test_reducer_rejects_schedule_without_case_source_identity() -> None:
    protocol, schedule, receipts = _inputs()
    schedule[0].pop("source_manifest_sha256")
    protocol["schedule_sha256"] = _digest(schedule)
    with pytest.raises(EvaluationError, match="source manifest"):
        reduce_evaluation(protocol, schedule, receipts)


def test_reducer_rejects_unenforced_or_mismatched_limit_receipt() -> None:
    protocol, schedule, receipts = _inputs()
    receipts[0]["applied_limits"]["wall_clock_seconds"] = 29
    with pytest.raises(EvaluationError, match="limits"):
        reduce_evaluation(protocol, schedule, receipts)
    protocol, schedule, receipts = _inputs()
    protocol["limits"] = {}
    receipts[0]["configured_limits"] = {}
    receipts[0]["applied_limits"] = {"enforced": True}
    with pytest.raises(EvaluationError, match="limits"):
        reduce_evaluation(protocol, schedule, receipts)


def test_reducer_rejects_differently_applied_arm_limits() -> None:
    protocol, schedule, receipts = _inputs()
    receipts[1]["configured_limits"]["wall_clock_seconds"] = 31
    receipts[1]["applied_limits"]["wall_clock_seconds"] = 31
    with pytest.raises(EvaluationError, match="limits"):
        reduce_evaluation(protocol, schedule, receipts)


def test_verification_distinguishes_evaluation_decision_from_release_eligibility() -> None:
    protocol, schedule, receipts = _inputs()
    result = reduce_evaluation(protocol, schedule, receipts, required_evidence=[{"kind": "human_calibration", "digest": "e" * 64, "live": True}])
    assert result["verification"]["complete"] is False
    assert result["release_eligibility"] is False


def test_verification_requires_identity_matched_live_artifact() -> None:
    protocol, schedule, receipts = _inputs()
    required = [{"kind": "human_calibration", "digest": "e" * 64, "source_manifest_sha256": "d" * 64}]
    artifact = {"kind": "human_calibration", "digest": "e" * 64, "result": "passed", "live": True, "source_manifest_sha256": "d" * 64}
    result = reduce_evaluation(protocol, schedule, receipts, required_evidence=required, evidence_artifacts=[artifact])
    assert result["verification"]["source_completeness"] is False
    assert result["release_eligibility"] is False  # the one-case fixture is inconclusive


def test_verification_reads_bounded_artifact_content_not_caller_flags(tmp_path) -> None:
    protocol, schedule, receipts = _inputs()
    calibration = {"frame_sha256": "f" * 64, "sampled_candidate_ids": ["c1"], "metrics": {"serious_precision_lower": 1.0, "baseline_precision_upper": 1.0, "review_time_ratio": 1.0, "cost_per_serious_ratio": 1.0, "unresolved_fraction": 0.0}, "hosts": {"codex": {"actual_humans": True}}}
    content = {"kind": "human_calibration", "schema_version": 1, "producer": "calibration.py", "producer_version": "1", "authority": "trusted_coordinator", "tested_source_manifest_sha256": "d" * 64, "tested_revision": "r1", "invocation_id": "i1", "result": "passed", "limitations": [], "payload": {"frame_sha256": "f" * 64, "calibration_sha256": _digest(calibration), "reviewed_candidate_ids": ["c1"], "labels": [{"candidate_id": "c1", "reviewer_id": "a", "role": "primary", "label": "real", "seconds": 1, "reason": "x"}, {"candidate_id": "c1", "reviewer_id": "b", "role": "primary", "label": "real", "seconds": 1, "reason": "x"}], "metrics": {"serious_precision_lower": 1.0, "baseline_precision_upper": 1.0, "review_time_ratio": 1.0, "cost_per_serious_ratio": 1.0, "unresolved_fraction": 0.0}}}
    raw = json.dumps(content, sort_keys=True).encode()
    artifact = tmp_path / "human.json"
    artifact.write_bytes(raw)
    required = [{"kind": "human_calibration", "path": "human.json", "digest": hashlib.sha256(raw).hexdigest(), "schema_version": 1, "producer": "calibration.py", "source_manifest_sha256": "d" * 64}]
    result = reduce_evaluation(protocol, schedule, receipts, calibration=calibration, required_evidence=required, evidence_artifacts=[{"kind": "human_calibration", "path": "wrong.json", "result": "forged"}], evidence_root=tmp_path)
    assert result["verification"]["complete"] is False
    assert "missing_release_evidence:cross_platform_ci" in result["verification"]["reasons"]


def test_verification_rejects_digest_matched_schemaless_artifact(tmp_path) -> None:
    protocol, schedule, receipts = _inputs()
    # These were enough fields for the former caller-flag verifier.  A file
    # bearing its expected digest remains invalid without the required trusted
    # producer identity, revision, invocation, and limitations fields.
    content = {"kind": "human_calibration", "schema_version": 1, "producer": "calibration.py", "authority": "trusted_coordinator", "result": "passed", "tested_source_manifest_sha256": "d" * 64}
    raw = json.dumps(content, sort_keys=True).encode()
    (tmp_path / "human.json").write_bytes(raw)
    required = [{"kind": "human_calibration", "path": "human.json", "digest": hashlib.sha256(raw).hexdigest(), "schema_version": 1, "producer": "calibration.py", "source_manifest_sha256": "d" * 64}]
    result = reduce_evaluation(protocol, schedule, receipts, required_evidence=required, evidence_root=tmp_path)
    assert result["verification"]["complete"] is False
    assert "invalid_required_evidence:human_calibration" in result["verification"]["reasons"]


def test_human_calibration_artifact_requires_two_primary_labels_per_candidate(tmp_path) -> None:
    protocol, schedule, receipts = _inputs()
    calibration = {"frame_sha256": "f" * 64, "sampled_candidate_ids": ["c1"], "metrics": {"serious_precision_lower": 1.0, "baseline_precision_upper": 1.0, "review_time_ratio": 1.0, "cost_per_serious_ratio": 1.0, "unresolved_fraction": 0.0}, "hosts": {"codex": {"actual_humans": True}}}
    content = {"kind": "human_calibration", "schema_version": 1, "producer": "calibration.py", "producer_version": "1", "authority": "trusted_coordinator", "tested_source_manifest_sha256": "d" * 64, "tested_revision": "r1", "invocation_id": "i1", "result": "passed", "limitations": [], "payload": {"frame_sha256": "f" * 64, "calibration_sha256": _digest(calibration), "reviewed_candidate_ids": ["c1"], "labels": [], "metrics": {"serious_precision_lower": 1.0, "baseline_precision_upper": 1.0, "review_time_ratio": 1.0, "cost_per_serious_ratio": 1.0, "unresolved_fraction": 0.0}}}
    raw = json.dumps(content, sort_keys=True).encode()
    (tmp_path / "human.json").write_bytes(raw)
    required = [{"kind": "human_calibration", "path": "human.json", "digest": hashlib.sha256(raw).hexdigest(), "schema_version": 1, "producer": "calibration.py", "source_manifest_sha256": "d" * 64}]
    result = reduce_evaluation(protocol, schedule, receipts, calibration=calibration, required_evidence=required, evidence_root=tmp_path)
    assert result["verification"]["complete"] is False


def test_human_calibration_artifact_requires_adjudication_for_disagreement(tmp_path) -> None:
    protocol, schedule, receipts = _inputs()
    calibration = {"frame_sha256": "f" * 64, "sampled_candidate_ids": ["c1"], "metrics": {"serious_precision_lower": 1.0, "baseline_precision_upper": 1.0, "review_time_ratio": 1.0, "cost_per_serious_ratio": 1.0, "unresolved_fraction": 0.0}, "hosts": {"codex": {"actual_humans": True}}}
    labels = [{"candidate_id": "c1", "reviewer_id": "a", "role": "primary", "label": "real", "seconds": 1, "reason": "x"}, {"candidate_id": "c1", "reviewer_id": "b", "role": "primary", "label": "false", "seconds": 1, "reason": "x"}]
    content = {"kind": "human_calibration", "schema_version": 1, "producer": "calibration.py", "producer_version": "1", "authority": "trusted_coordinator", "tested_source_manifest_sha256": "d" * 64, "tested_revision": "r1", "invocation_id": "i1", "result": "passed", "limitations": [], "payload": {"frame_sha256": "f" * 64, "calibration_sha256": _digest(calibration), "reviewed_candidate_ids": ["c1"], "labels": labels, "metrics": {"serious_precision_lower": 1.0, "baseline_precision_upper": 1.0, "review_time_ratio": 1.0, "cost_per_serious_ratio": 1.0, "unresolved_fraction": 0.0}}}
    raw = json.dumps(content, sort_keys=True).encode()
    (tmp_path / "human.json").write_bytes(raw)
    required = [{"kind": "human_calibration", "path": "human.json", "digest": hashlib.sha256(raw).hexdigest(), "schema_version": 1, "producer": "calibration.py", "source_manifest_sha256": "d" * 64}]
    result = reduce_evaluation(protocol, schedule, receipts, calibration=calibration, required_evidence=required, evidence_root=tmp_path)
    assert result["verification"]["complete"] is False


def test_published_release_flag_cannot_override_fresh_reducer_readback(tmp_path) -> None:
    protocol, schedule, receipts = _inputs()
    execution_order = _bind_execution_order(protocol, schedule, receipts)
    calibration = {"frame_sha256": "f" * 64, "sampled_candidate_ids": ["c1"], "metrics": {"serious_precision_lower": 1.0, "baseline_precision_upper": 1.0, "review_time_ratio": 1.0, "cost_per_serious_ratio": 1.0, "unresolved_fraction": 0.0}, "hosts": {"codex": {"actual_humans": True}}}
    content = {"kind": "human_calibration", "schema_version": 1, "producer": "calibration.py", "producer_version": "1", "authority": "trusted_coordinator", "tested_source_manifest_sha256": "d" * 64, "tested_revision": "r1", "invocation_id": "i1", "result": "passed", "limitations": [], "payload": {"frame_sha256": "f" * 64, "calibration_sha256": _digest(calibration), "reviewed_candidate_ids": ["c1"], "labels": [{"candidate_id": "c1", "reviewer_id": reviewer, "role": "primary", "label": "real", "seconds": 1, "reason": "x"} for reviewer in ("a", "b")], "metrics": {"serious_precision_lower": 1.0, "baseline_precision_upper": 1.0, "review_time_ratio": 1.0, "cost_per_serious_ratio": 1.0, "unresolved_fraction": 0.0}}}
    raw = json.dumps(content, sort_keys=True).encode()
    (tmp_path / "human.json").write_bytes(raw)
    required = [{"kind": "human_calibration", "path": "human.json", "digest": hashlib.sha256(raw).hexdigest(), "schema_version": 1, "producer": "calibration.py", "source_manifest_sha256": "d" * 64}]
    published = reduce_evaluation(protocol, schedule, receipts, execution_order=execution_order, calibration=calibration, required_evidence=required, evidence_root=tmp_path)
    published["release_eligibility"] = True  # valid schema shape, forged decision
    for name, value in (("published.json", published), ("protocol.json", protocol), ("schedule.json", schedule), ("execution-order.json", execution_order), ("receipts.json", receipts), ("required.json", required), ("calibration.json", calibration)):
        (tmp_path / name).write_text(json.dumps(value), encoding="utf-8")
    with pytest.raises(EvaluationError, match="does not match"):
        verify_published_evaluation(published_summary=tmp_path / "published.json", protocol_path=tmp_path / "protocol.json", schedule_path=tmp_path / "schedule.json", execution_order_path=tmp_path / "execution-order.json", receipts_path=tmp_path / "receipts.json", required_evidence_path=tmp_path / "required.json", evidence_root=tmp_path)


def test_protocol_host_without_schedule_slots_stays_visible_and_inconclusive() -> None:
    protocol, schedule, receipts = _inputs()
    protocol["hosts"]["claude"] = protocol["hosts"]["codex"]
    result = reduce_evaluation(protocol, schedule, receipts)
    assert result["hosts"]["claude"]["expected_slots"] == 0
    assert result["hosts"]["claude"]["decision"] == "inconclusive"


def test_single_supported_host_cannot_produce_release_decision() -> None:
    protocol, schedule, receipts = _inputs()
    result = reduce_evaluation(protocol, schedule, receipts)
    assert result["evaluation_decision"] == "inconclusive"
    assert "both_supported_hosts_required" in result["hosts"]["codex"]["comparability_reasons"]


def test_complete_accounting_rejects_incomplete_usage_and_partial_limit_match() -> None:
    protocol, schedule, receipts = _inputs()
    receipts[0]["usage"]["cost_usd"] = None
    with pytest.raises(EvaluationError, match="accounting"):
        reduce_evaluation(protocol, schedule, receipts)
    protocol, schedule, receipts = _inputs()
    receipts[0]["configured_limits"]["max_tokens"] = 10
    receipts[0]["applied_limits"]["max_tokens"] = 9
    with pytest.raises(EvaluationError, match="limits"):
        reduce_evaluation(protocol, schedule, receipts)


def test_reducer_rejects_json_boolean_usage_empty_hosts_and_profile_drift() -> None:
    protocol, schedule, receipts = _inputs()
    receipts[0]["usage"]["input_tokens"] = True
    with pytest.raises(EvaluationError, match="accounting"):
        reduce_evaluation(protocol, schedule, receipts)
    protocol, schedule, receipts = _inputs()
    protocol["benchmark_hosts"] = []
    with pytest.raises(EvaluationError, match="benchmark_hosts"):
        reduce_evaluation(protocol, schedule, receipts)
    protocol, schedule, receipts = _inputs()
    schedule[0]["limit_profile"] = "other"
    for receipt in receipts:
        receipt["limit_profile"] = "other"
    protocol["schedule_sha256"] = _digest(schedule)
    with pytest.raises(EvaluationError, match="limits"):
        reduce_evaluation(protocol, schedule, receipts)


def test_receipt_local_proof_digests_do_not_break_equal_limit_comparison() -> None:
    protocol, schedule, receipts = _inputs()
    for index, receipt in enumerate(receipts):
        receipt["applied_limits"]["proof_execution_receipt_sha256"] = str(index) * 64
    result = reduce_evaluation(protocol, schedule, receipts)
    assert "matched_limits_mismatch" not in result["hosts"]["codex"]["comparability_reasons"]


def test_evaluation_result_matches_schema() -> None:
    protocol, schedule, receipts = _inputs()
    result = reduce_evaluation(protocol, schedule, receipts)
    schema = json.loads((Path(__file__).resolve().parents[2] / "schemas" / "evaluation-result.schema.json").read_text())
    Draft202012Validator(schema).validate(result)


def test_stage_experiments_keep_separate_denominators_and_calibration():
    from bench import harness
    from bench.tests.unit.test_stage_ablations import _protocol
    case = {"id": "case", "source_manifest_sha256": "a" * 64, "task_description": "Inspect", "repository": "repo", "category": "logic"}
    frozen = harness.freeze_documents(_protocol(), [case], 3)
    receipts = [harness._error_receipt(frozen["protocol"], row, None, "not_started") for row in frozen["execution_order"] if row["stage_block"] == "full_pipeline"]
    result = reduce_evaluation(frozen["protocol"], frozen["schedule"], receipts, execution_order=frozen["execution_order"], calibration={"stage_block": "hunter_only", "hosts": {"codex": {"test_marker": "separate"}}})
    assert result["hosts"]["codex"]["expected_slots"] == 9
    assert result["hosts"]["codex"]["received_slots"] == 9
    assert result["hosts"]["codex"]["metrics"]["human"] == {"status": "unverified"}
    experimental = result["stage_experiments"]["hunter_only"]["hosts"]["codex"]
    assert experimental["expected_slots"] == experimental["missing_slots"] == 9
    assert experimental["metrics"]["human"] == {"test_marker": "separate"}
    assert "ablation_evidence_incomplete" in result["verification"]["reasons"]
    Draft202012Validator(json.loads((Path(__file__).resolve().parents[2] / "schemas/evaluation-result.schema.json").read_text())).validate(result)
    receipts[0]["stage_block"] = "hunter_only"
    with pytest.raises(EvaluationError, match="execution-order"):
        reduce_evaluation(frozen["protocol"], frozen["schedule"], receipts, execution_order=frozen["execution_order"])


def test_detection_claims_require_native_matching_evidence():
    protocol, schedule, receipts = _inputs()
    result = reduce_evaluation(protocol, schedule, receipts)
    assert "detection_evidence_unavailable" in result["hosts"]["codex"]["comparability_reasons"]
    assert result["hosts"]["codex"]["metrics"]["detection"]["status"] == "unverified"
    assert result["thresholds"]["detection_point_delta"] == .20
    assert result["thresholds"]["detection_paired95_lower_exclusive"] == 0
    assert result["thresholds"]["additional_cross_file_detections"] == 1


def test_confirmed_unsafe_landing_remains_redesign_with_missing_measurements():
    protocol, schedule, receipts = _inputs()
    result = reduce_evaluation(protocol, schedule, receipts, calibration={"hosts": {"codex": {"unsafe_auto_landing": True}}})
    assert result["hosts"]["codex"]["decision"] == "redesign"
    assert "confirmed_unsafe_auto_landing" in result["hosts"]["codex"]["comparability_reasons"]
    assert result["evaluation_decision"] == "redesign"
    assert result["release_eligibility"] is False
