"""Fail-closed reducer for frozen, host-separated benchmark evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Mapping, Sequence

from jsonschema.validators import Draft202012Validator

from bench.scorer.calibration import evaluation_calibration_from_records
from bench.harness import canonical, effective_prompt_binding, HarnessError
from bench.scorer.ci_evidence import validate_ci_receipt
from bench._stages import STAGES, normalize_stage_blocks
from scripts._review_evidence import _loads

ARM_SET = frozenset({"current_skill", "previous_release", "no_skill_baseline"})
RELEASE_EVIDENCE_KINDS = frozenset({"cross_platform_ci", "host_invocations", "human_calibration", "sandbox_negative", "analyzer_compatibility", "installer_recovery", "independent_final_review"})
THRESHOLDS = {"serious_precision_lower": .95, "precision_noninferiority_margin": -.02, "review_time_ratio": 1.0, "cost_per_serious_ratio": 1.25, "max_unresolved_fraction": .10, "detection_point_delta": .20, "detection_paired95_lower_exclusive": 0, "additional_cross_file_detections": 1}
EVIDENCE_SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "schemas" / "evidence-artifact.schema.json").read_text(encoding="utf-8"))
EVALUATION_RESULT_SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "schemas" / "evaluation-result.schema.json").read_text(encoding="utf-8"))
EVIDENCE_VALIDATOR = Draft202012Validator(EVIDENCE_SCHEMA)
EVALUATION_RESULT_VALIDATOR = Draft202012Validator(EVALUATION_RESULT_SCHEMA)
MAX_FROZEN_INPUT_BYTES = 10_000_000


class EvaluationError(ValueError):
    pass


def _read_frozen_json(path: Path, label: str) -> Any:
    """Read a bounded regular frozen input, never a caller-selected symlink."""
    try:
        if not path.is_absolute() or path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_FROZEN_INPUT_BYTES:
            raise EvaluationError(f"{label} must be an absolute bounded regular file")
        return _loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise EvaluationError(f"{label} is unreadable JSON") from exc


def _validate_published_result(result: Any) -> Mapping[str, Any]:
    if not isinstance(result, Mapping) or list(EVALUATION_RESULT_VALIDATOR.iter_errors(result)):
        raise EvaluationError("published evaluation does not match the result schema")
    hosts = result.get("hosts")
    if not isinstance(hosts, Mapping) or not hosts:
        raise EvaluationError("published evaluation has no configured hosts")
    return result


def _validate_required_evidence(requirements: Any) -> list[Mapping[str, Any]]:
    if not isinstance(requirements, list) or not requirements:
        raise EvaluationError("frozen required evidence is missing")
    required_fields = ("kind", "path", "digest", "schema_version", "producer", "source_manifest_sha256")
    if any(not isinstance(item, Mapping) or any(not item.get(field) for field in required_fields) for item in requirements):
        raise EvaluationError("frozen required evidence is malformed")
    return list(requirements)


def _digest(value: Any) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def _sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def _slot(slot: Mapping[str, Any], arm: str) -> tuple:
    return (str(slot["experiment_id"]), str(slot["host"]), str(slot["model"]), str(slot["case_id"]), int(slot["repetition"]), str(slot["limit_profile"]), arm, str(slot.get("stage_block", "full_pipeline")))


def _expanded_slots(schedule: Sequence[Mapping[str, Any]]):
    for slot in schedule:
        for block in slot.get("stage_blocks", ["full_pipeline"]):
            yield {**slot, "stage_block": block} if "stage_blocks" in slot else slot


def _validate_execution_order(protocol: Mapping[str, Any], schedule: Sequence[Mapping[str, Any]], execution_order: Sequence[Mapping[str, Any]] | None) -> dict[tuple, Mapping[str, Any]] | None:
    """Bind every receipt to its frozen interleaved arm-level order slot."""
    if execution_order is None:
        return None
    if not isinstance(protocol.get("execution_order_sha256"), str) or protocol["execution_order_sha256"] != _digest(execution_order):
        raise EvaluationError("protocol execution-order digest mismatch")
    schedule_by_key = {_slot(slot, arm): slot for slot in _expanded_slots(schedule) for arm in slot.get("arms", [])}
    order_by_key: dict[tuple, Mapping[str, Any]] = {}
    for order_slot in execution_order:
        try:
            key = _slot(order_slot, str(order_slot.get("arm", "")))
        except (KeyError, TypeError, ValueError) as exc:
            raise EvaluationError("malformed execution-order slot") from exc
        expected = schedule_by_key.get(key)
        identity = {"ordinal": order_slot.get("ordinal"), "schedule_slot_sha256": order_slot.get("schedule_slot_sha256"), "arm": order_slot.get("arm")}
        if "stage_block" in order_slot:
            identity["stage_block"] = order_slot["stage_block"]
        if expected is None or key in order_by_key or any(order_slot.get(field) != value for field, value in expected.items()) or type(order_slot.get("ordinal")) is not int or order_slot["ordinal"] < 1 or order_slot.get("order_slot_sha256") != _digest(identity):
            raise EvaluationError("execution-order slot mismatch")
        order_by_key[key] = order_slot
    if set(order_by_key) != set(schedule_by_key) or {int(slot["ordinal"]) for slot in order_by_key.values()} != set(range(1, len(order_by_key) + 1)):
        raise EvaluationError("execution-order is incomplete")
    return order_by_key


def _validate_receipt(protocol: Mapping[str, Any], slot: Mapping[str, Any], receipt: Mapping[str, Any], order_slot: Mapping[str, Any] | None = None) -> None:
    key = _slot(receipt, str(receipt.get("arm", "")))
    if key != _slot(slot, str(receipt.get("arm", ""))):
        raise EvaluationError("receipt schedule slot mismatch")
    if order_slot is not None and any(receipt.get(field) != order_slot.get(field) for field in ("ordinal", "schedule_slot_sha256", "order_slot_sha256")):
        raise EvaluationError("receipt execution-order slot mismatch")
    if order_slot is not None and (receipt.get("schedule_sha256") != protocol.get("schedule_sha256") or receipt.get("execution_order_sha256") != protocol.get("execution_order_sha256")):
        raise EvaluationError("receipt schedule document mismatch")
    host = protocol.get("hosts", {}).get(receipt["host"], {})
    if receipt.get("model") != host.get("model"):
        raise EvaluationError("receipt model provenance mismatch")
    arm = receipt["arm"]
    expected = host.get("arms", {}).get(arm)
    if not isinstance(expected, Mapping):
        raise EvaluationError("receipt arm provenance missing")
    provenance = receipt.get("provenance")
    if not isinstance(provenance, Mapping) or provenance.get("model_version") != host.get("model_version") or any(provenance.get(field) != expected.get(field) for field in ("skill_revision", "skill_content_sha256", "skill_entrypoint_sha256", "adapter_sha256", "prompt_sha256", "config_sha256")):
        raise EvaluationError("receipt arm provenance mismatch")
    configured, applied = receipt.get("configured_limits"), receipt.get("applied_limits")
    protocol_limits = protocol.get("limits")
    wall_clock = protocol_limits.get("wall_clock_seconds") if isinstance(protocol_limits, Mapping) else None
    lifecycle = receipt.get("lifecycle")
    if order_slot is not None and receipt.get("evaluation_mode") != protocol.get("evaluation_mode"):
        raise EvaluationError("receipt evaluation mode mismatch")
    if slot.get("limit_profile") != protocol.get("limit_profile") or receipt.get("limit_profile") != protocol.get("limit_profile") or not isinstance(protocol_limits, Mapping) or isinstance(wall_clock, bool) or not isinstance(wall_clock, int) or wall_clock < 1 or configured != protocol_limits or not isinstance(applied, Mapping):
        raise EvaluationError("receipt applied limits mismatch")
    if lifecycle == "completed":
        # A native exit can be real while cap-finalization is unavailable. Keep
        # that raw receipt, but make it incomparable downstream.  Values that
        # contradict the frozen cap are still malformed and reject.
        if not isinstance(applied.get("enforced"), bool) or any(applied.get(key) not in {None, value} for key, value in configured.items()) or set(applied) - set(configured) - {"enforced", "proof_execution_receipt_sha256"}:
            raise EvaluationError("receipt applied limits mismatch")
    elif lifecycle in {"error", "skipped"}:
        # A pre-start error has no applied cap.  A post-start error must retain
        # the provider's truthful partial enforcement rather than be discarded.
        allowed = {"enforced", "reason", "proof_execution_receipt_sha256"}
        if not isinstance(applied.get("enforced"), bool) or any(applied.get(key) not in {None, configured[key]} for key in configured) or set(applied) - set(configured) - allowed or (applied.get("reason") == "not_started" and (applied.get("enforced") is not False or any(applied.get(key) is not None for key in configured))):
            raise EvaluationError("error receipt applied limits mismatch")
    else:
        raise EvaluationError("receipt lifecycle is invalid")
    if order_slot is not None:
        effective = receipt.get("effective_prompt_sha256")
        if effective is not None:
            try:
                binding = effective_prompt_binding(effective, slot, expected)
            except HarnessError as exc:
                raise EvaluationError("receipt effective prompt provenance mismatch") from exc
            if receipt.get("effective_prompt_binding_sha256") != binding:
                raise EvaluationError("receipt effective prompt provenance mismatch")
        elif lifecycle == "completed":
            raise EvaluationError("receipt effective prompt provenance missing")
    usage = receipt.get("usage")
    if receipt.get("accounting_state") == "complete":
        if not isinstance(usage, Mapping) or usage.get("cost_source") not in {"actual", "rate_estimated"} or any(isinstance(usage.get(key), bool) or not isinstance(usage.get(key), (int, float)) or not math.isfinite(float(usage[key])) or float(usage[key]) < 0 for key in ("input_tokens", "output_tokens", "total_tokens", "cost_usd", "wall_clock_seconds")):
            raise EvaluationError("receipt complete accounting has incomplete usage")
        if any(isinstance(usage[key], bool) or not isinstance(usage[key], int) for key in ("input_tokens", "output_tokens", "total_tokens")) or usage["total_tokens"] != usage["input_tokens"] + usage["output_tokens"]:
            raise EvaluationError("receipt complete accounting has invalid token usage")
        if usage.get("cost_source") == "rate_estimated":
            rate_table = protocol.get("rate_table")
            if not isinstance(rate_table, Mapping) or not isinstance(rate_table.get("version"), str) or not _sha256(rate_table.get("sha256")) or usage.get("rate_table_version") != rate_table["version"] or usage.get("rate_table_sha256") != rate_table["sha256"]:
                raise EvaluationError("receipt rate estimate provenance mismatch")
    source = receipt.get("source")
    expected_source = slot.get("source_manifest_sha256")
    if not isinstance(expected_source, str) or not isinstance(source, Mapping) or source.get("expected_manifest_sha256") != expected_source:
        raise EvaluationError("receipt source manifest mismatch")
    if lifecycle == "completed" and (not source.get("valid") or any(source.get(field) != expected_source for field in ("observed_pre_manifest_sha256", "observed_post_manifest_sha256"))):
        raise EvaluationError("receipt source manifest mismatch")


def _human_decision(human: Mapping[str, Any] | None) -> tuple[str, list[str]]:
    if isinstance(human, Mapping) and human.get("unsafe_auto_landing") is True:
        return "redesign", ["confirmed_unsafe_auto_landing"]
    if not isinstance(human, Mapping) or not human.get("actual_humans"):
        return "inconclusive", ["human_calibration_unavailable"]
    if human.get("frame_complete") is not True:
        return "inconclusive", ["human_frame_incomplete"]
    fields = ("serious_precision_lower", "baseline_precision_upper", "review_time_ratio", "cost_per_serious_ratio", "unresolved_fraction")
    if not human.get("review_time_complete") or any(isinstance(human.get(key), bool) or not isinstance(human.get(key), (int, float)) or not math.isfinite(float(human[key])) for key in fields):
        return "inconclusive", ["human_measurement_incomplete"]
    if human.get("rejection_audit_complete") is not True:
        return "inconclusive", ["rejection_audit_unavailable"]
    if human["unresolved_fraction"] > THRESHOLDS["max_unresolved_fraction"]:
        return "inconclusive", ["unresolved_adjudications_over_10_percent"]
    reasons = []
    if human["serious_precision_lower"] < THRESHOLDS["serious_precision_lower"]: reasons.append("serious_precision_below_threshold")
    if human["serious_precision_lower"] - human["baseline_precision_upper"] < THRESHOLDS["precision_noninferiority_margin"]: reasons.append("precision_noninferiority_failed")
    if human["review_time_ratio"] > THRESHOLDS["review_time_ratio"]: reasons.append("review_time_ratio_failed")
    if human["cost_per_serious_ratio"] > THRESHOLDS["cost_per_serious_ratio"]: reasons.append("cost_per_serious_ratio_failed")
    return ("redesign", reasons) if reasons else ("proceed", [])


def _valid_human_calibration_payload(content: Mapping[str, Any], calibration: Mapping[str, Any] | None) -> bool:
    """Bind label-level human evidence to the exact calibration input."""
    payload = content.get("payload")
    if not isinstance(payload, Mapping) or not isinstance(calibration, Mapping) or calibration.get("stage_block", "full_pipeline") != "full_pipeline" or payload.get("calibration_sha256") != _digest(calibration):
        return False
    candidates = payload.get("reviewed_candidate_ids")
    labels = payload.get("labels")
    if not isinstance(labels, list) or labels != calibration.get("labels") or payload.get("labels_sha256") != _digest(labels) or payload["labels_sha256"] != calibration.get("labels_sha256"):
        return False
    if payload.get("frame_sha256") != calibration.get("frame_sha256") or payload.get("metrics") != calibration.get("metrics") or not isinstance(candidates, list) or candidates != calibration.get("sampled_candidate_ids") or not isinstance(labels, list) or not candidates or len(set(candidates)) != len(candidates):
        return False
    primary_by_candidate: dict[str, set[str]] = defaultdict(set)
    primary_labels: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    adjudicators: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for label in labels:
        if not isinstance(label, Mapping) or label.get("candidate_id") not in candidates or label.get("role") not in {"primary", "adjudicator"} or label.get("label") not in {"real", "false", "unverifiable"} or not isinstance(label.get("reviewer_id"), str) or not label["reviewer_id"] or isinstance(label.get("seconds"), bool) or not isinstance(label.get("seconds"), (int, float)) or label["seconds"] <= 0 or not isinstance(label.get("reason"), str) or not label["reason"].strip():
            return False
        if label["role"] == "primary":
            primary_by_candidate[str(label["candidate_id"])].add(label["reviewer_id"])
            primary_labels[str(label["candidate_id"])].append(label)
        else:
            adjudicators[str(label["candidate_id"])].append(label)
    for candidate in candidates:
        votes = primary_labels[candidate]
        if len(votes) != 2 or len(primary_by_candidate[candidate]) != 2:
            return False
        disagreement = votes[0]["label"] != votes[1]["label"] or "unverifiable" in {votes[0]["label"], votes[1]["label"]}
        decisions = adjudicators[candidate]
        if disagreement and (len(decisions) != 1 or decisions[0]["reviewer_id"] in primary_by_candidate[candidate]):
            return False
        if not disagreement and decisions:
            return False
    return True


def _verify(required: Sequence[Mapping[str, Any]], supplied: Sequence[Mapping[str, Any]], evidence_root: Path | None, calibration: Mapping[str, Any] | None = None) -> dict[str, Any]:
    if not required:
        return {"complete": False, "source_completeness": False, "reasons": ["required_evidence_unavailable"]}
    reasons: list[str] = [f"missing_release_evidence:{kind}" for kind in sorted(RELEASE_EVIDENCE_KINDS - {str(item.get("kind", "")) for item in required if isinstance(item, Mapping)})]
    for requirement in required:
        kind = str(requirement.get("kind", "unknown"))
        if evidence_root is None:
            reasons.append(f"missing_required_evidence:{kind}")
            continue
        # The frozen requirement chooses the path. Caller-provided artifact
        # flags cannot redirect the verification target.
        path = requirement.get("path")
        if not isinstance(path, str) or not path:
            reasons.append(f"missing_required_evidence:{kind}")
            continue
        candidate = evidence_root / str(path)
        try:
            resolved = candidate.resolve(strict=True)
            root = evidence_root.resolve(strict=True)
            if root not in resolved.parents or candidate.is_symlink() or resolved.stat().st_size > 1_000_000:
                raise ValueError
            raw = resolved.read_bytes()
            actual = hashlib.sha256(raw).hexdigest()
            content = _loads(raw.decode("utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            reasons.append(f"unreadable_required_evidence:{kind}")
            continue
        if kind not in {"human_calibration", "cross_platform_ci"}:
            reasons.append(f"unsupported_required_evidence:{kind}")
        elif not isinstance(content, Mapping) or list(EVIDENCE_VALIDATOR.iter_errors(content)) or not requirement.get("source_manifest_sha256") or not requirement.get("producer") or not isinstance(requirement.get("schema_version", 1), int) or actual != requirement.get("digest") or content.get("kind") != kind or content.get("schema_version") != requirement.get("schema_version", 1) or content.get("producer") != requirement.get("producer") or content.get("authority") != "trusted_coordinator" or content.get("result") != "passed" or content.get("tested_source_manifest_sha256") != requirement.get("source_manifest_sha256"):
            reasons.append(f"invalid_required_evidence:{kind}")
        elif kind == "human_calibration" and not _valid_human_calibration_payload(content, calibration):
            reasons.append(f"invalid_required_evidence:{kind}")
        elif kind == "cross_platform_ci":
            subject = requirement.get("subject")
            payload = content["payload"]
            if not isinstance(subject, Mapping) or set(subject) != {"repository", "workflow_path", "source_commit", "run_id", "run_attempt"} or any(payload.get(key) != value for key, value in subject.items()) or content.get("tested_revision") != subject["source_commit"] or content.get("invocation_id") != f"actions:{subject['run_id']}:{subject['run_attempt']}" or validate_ci_receipt(payload, repository=subject["repository"], workflow_path=subject["workflow_path"], source_commit=subject["source_commit"]):
                reasons.append("invalid_required_evidence:cross_platform_ci")
    complete = not reasons
    return {"complete": complete, "source_completeness": complete, "reasons": reasons}


def reduce_evaluation(protocol: Mapping[str, Any], schedule: Sequence[Mapping[str, Any]], receipts: Sequence[Mapping[str, Any]], *, execution_order: Sequence[Mapping[str, Any]] | None = None, calibration: Mapping[str, Any] | None = None, calibration_records: Mapping[str, Any] | None = None, stage_calibration_records: Sequence[Mapping[str, Any]] = (), required_evidence: Sequence[Mapping[str, Any]] = (), evidence_artifacts: Sequence[Mapping[str, Any]] = (), evidence_root: Path | None = None) -> dict[str, Any]:
    """Validate receipts and retain scheduled absent/error/unknown slots in output."""
    if calibration_records is not None:
        try:
            calibration = evaluation_calibration_from_records(calibration_records, receipts)
        except ValueError as exc:
            raise EvaluationError("calibration records are invalid") from exc
    if protocol.get("schema_version") != 1 or protocol.get("schedule_sha256") != _digest(schedule):
        raise EvaluationError("protocol schedule digest mismatch")
    if execution_order is not None and (isinstance(protocol.get("repetitions"), bool) or not isinstance(protocol.get("repetitions"), int) or protocol["repetitions"] < 3):
        raise EvaluationError("frozen protocol requires k>=3 repetitions")
    expected: dict[tuple, Mapping[str, Any]] = {}
    blocks = ["full_pipeline"]
    if "ablation_blocks" in protocol:
        try:
            configured_blocks = normalize_stage_blocks(protocol["ablation_blocks"])
        except ValueError as exc:
            raise EvaluationError("invalid protocol stage blocks") from exc
        blocks = [block["id"] for block in configured_blocks]
        if not any(block["id"] == "full_pipeline" and block["stages"] == list(STAGES) for block in configured_blocks) or any(slot.get("stage_blocks") != blocks for slot in schedule):
            raise EvaluationError("schedule stage blocks differ from frozen protocol")
    elif any("stage_blocks" in slot for slot in schedule):
        raise EvaluationError("schedule has unfrozen stage blocks")
    for slot in _expanded_slots(schedule):
        if slot.get("experiment_id") != protocol.get("experiment_id") or slot.get("host") not in protocol.get("hosts", {}):
            raise EvaluationError("schedule protocol identity mismatch")
        if not isinstance(slot.get("source_manifest_sha256"), str):
            raise EvaluationError("schedule source manifest missing")
        arms = slot.get("arms", [])
        if set(arms) != ARM_SET:
            raise EvaluationError("schedule must contain exactly the required arms")
        for arm in arms:
            key = _slot(slot, arm)
            if key in expected:
                raise EvaluationError("duplicate schedule slot")
            expected[key] = slot
    calibrations = {}
    if calibration is not None:
        calibrations[calibration.get("stage_block", "full_pipeline")] = calibration
    for records in stage_calibration_records:
        try:
            stage_calibration = evaluation_calibration_from_records(records, receipts)
        except (ValueError, TypeError) as exc:
            raise EvaluationError("stage calibration records are invalid") from exc
        stage = stage_calibration["stage_block"]
        if stage in calibrations or stage not in blocks:
            raise EvaluationError("duplicate or unfrozen stage calibration")
        calibrations[stage] = stage_calibration
    if set(calibrations) - set(blocks):
        raise EvaluationError("unfrozen calibration stage")
    calibration = calibrations.get("full_pipeline")
    order_by_key = _validate_execution_order(protocol, schedule, execution_order)
    seen: dict[tuple, Mapping[str, Any]] = {}
    for receipt in receipts:
        try:
            key = _slot(receipt, str(receipt.get("arm", "")))
        except (KeyError, TypeError, ValueError) as exc:
            raise EvaluationError("malformed receipt") from exc
        if key not in expected or key in seen:
            raise EvaluationError("unexpected or duplicate receipt")
        _validate_receipt(protocol, expected[key], receipt, order_by_key.get(key) if order_by_key else None)
        seen[key] = receipt
    configured_hosts = protocol.get("benchmark_hosts", sorted(protocol.get("hosts", {})))
    if not isinstance(configured_hosts, Sequence) or isinstance(configured_hosts, str) or not configured_hosts or any(host not in protocol.get("hosts", {}) for host in configured_hosts):
        raise EvaluationError("invalid benchmark_hosts")
    supported_hosts_complete = set(configured_hosts) == {"claude", "codex"} and set(protocol.get("hosts", {})) == {"claude", "codex"}
    stage_results: dict[str, Any] = {}
    for stage_block in blocks:
        hosts: dict[str, dict[str, Any]] = {}
        for host in sorted(set(configured_hosts)):
            host_keys = [key for key in expected if key[1] == host and key[7] == stage_block]
            host_receipts = [seen[key] for key in host_keys if key in seen]
            missing = [key for key in host_keys if key not in seen]
            lifecycle = defaultdict(int)
            accounting = defaultdict(int)
            by_arm: dict[str, int] = defaultdict(int)
            categories: set[str] = set()
            repositories: set[str] = set()
            comparable_cases: set[str] = set()
            # Native imports currently verify candidate provenance, not matches
            # against independently validated held-out truth. A caller-written
            # receipt result cannot replace that missing measurement.
            reasons: list[str] = ["detection_evidence_unavailable"]
            if order_by_key is None:
                reasons.append("execution_order_unavailable")
            if not supported_hosts_complete:
                reasons.append("both_supported_hosts_required")
            repetitions = protocol.get("repetitions")
            if type(repetitions) is not int or repetitions < 3 or any(
                {key[4] for key in host_keys if key[3] == case_id} != set(range(1, repetitions + 1))
                for case_id in {key[3] for key in host_keys}
            ):
                reasons.append("scheduled_repetitions_incomplete")
            for key in host_keys:
                slot = expected[key]
                categories.add(str(slot.get("category", "")))
                repositories.add(str(slot.get("repository", "")))
            for receipt in host_receipts:
                lifecycle[str(receipt.get("lifecycle", "unknown"))] += 1
                accounting[str(receipt.get("accounting_state", "unknown"))] += 1
                by_arm[str(receipt["arm"])] += 1
                applied = receipt.get("applied_limits")
                configured = receipt.get("configured_limits")
                if receipt.get("lifecycle") == "completed" and (not isinstance(applied, Mapping) or applied.get("enforced") is not True or not isinstance(configured, Mapping) or any(applied.get(key) != value for key, value in configured.items())):
                    reasons.append("limits_incomplete")
            paired_limits: dict[tuple[str, int, str], str] = {}
            for key in host_keys:
                receipt = seen.get(key)
                if not receipt:
                    continue
                pair_key = (key[3], key[4], key[5])
                # Receipt-local proof digests are expected to differ per arm.  Only
                # the protocol-bound limit values are a paired-comparability claim.
                applied = json.dumps(
                    {name: receipt["applied_limits"].get(name) for name in receipt["configured_limits"]},
                    sort_keys=True,
                    separators=(",", ":"),
                )
                if pair_key in paired_limits and paired_limits[pair_key] != applied:
                    reasons.append("matched_limits_mismatch")
                paired_limits[pair_key] = applied
            for case_id in {key[3] for key in host_keys}:
                case_rows = [seen.get(key) for key in host_keys if key[3] == case_id]
                if all(row and row.get("lifecycle") == "completed" and row.get("accounting_state") == "complete" for row in case_rows):
                    comparable_cases.add(case_id)
            attrition = (len(missing) + sum(count for state, count in lifecycle.items() if state != "completed")) / len(host_keys) if host_keys else 1.0
            if missing: reasons.append("missing_receipts")
            if not host_keys: reasons.append("missing_schedule_slots")
            if attrition > .20: reasons.append("attrition_over_20_percent")
            if len(comparable_cases) < 16: reasons.append("fewer_than_16_comparable_cases")
            if len(categories - {""}) < 5: reasons.append("categories_incomplete")
            if any(by_arm[arm] == 0 for arm in ARM_SET): reasons.append("missing_arm")
            if any(state != "complete" and count for state, count in accounting.items()): reasons.append("accounting_incomplete")
            block_calibration = calibrations.get(stage_block, {})
            human = block_calibration.get("hosts", {}).get(host) if isinstance(block_calibration.get("hosts"), Mapping) else None
            human_decision, human_reasons = _human_decision(human)
            reasons.extend(human_reasons)
            inconclusive = {"detection_evidence_unavailable", "execution_order_unavailable", "both_supported_hosts_required", "missing_schedule_slots", "scheduled_repetitions_incomplete", "missing_receipts", "attrition_over_20_percent", "fewer_than_16_comparable_cases", "categories_incomplete", "missing_arm", "matched_limits_mismatch", "limits_incomplete", "accounting_incomplete", "human_calibration_unavailable", "human_measurement_incomplete", "rejection_audit_unavailable", "unresolved_adjudications_over_10_percent"}
            decision = "inconclusive" if any(reason in inconclusive for reason in reasons) else human_decision
            if "confirmed_unsafe_auto_landing" in human_reasons:
                decision = "redesign"
            hosts[host] = {"expected_slots": len(host_keys), "received_slots": len(host_receipts), "missing_slots": len(missing), "attrition": attrition, "comparable_cases": len(comparable_cases), "categories": sorted(categories - {""}), "repositories": sorted(repositories - {""}), "arms": dict(sorted(by_arm.items())), "lifecycle": dict(lifecycle), "accounting": dict(accounting), "comparability_reasons": reasons, "metrics": {"human": human or {"status": "unverified"}, "detection": {"status": "unverified", "reason": "native_ground_truth_matches_unavailable"}}, "decision": decision}
        stage_results[stage_block] = {"hosts": hosts, "calibration": calibrations.get(stage_block, {"status": "unverified"})}
    hosts = stage_results["full_pipeline"]["hosts"]
    host_decisions = {host["decision"] for host in hosts.values()}
    decision = "redesign" if "redesign" in host_decisions else "inconclusive" if "inconclusive" in host_decisions else "proceed"
    verified = _verify(required_evidence, evidence_artifacts, evidence_root, calibration)
    if any(host["decision"] == "inconclusive" for block, result in stage_results.items() if block != "full_pipeline" for host in result["hosts"].values()):
        verified["reasons"].append("ablation_evidence_incomplete")
        verified.update(complete=False, source_completeness=False)
    verification = {**verified, "evaluation_decision": decision, "release_eligibility": verified["complete"] and decision == "proceed"}
    return {"schema_version": 1, "protocol_sha256": _digest(protocol), "schedule_sha256": _digest(schedule), "execution_order_sha256": protocol.get("execution_order_sha256") if execution_order is not None else None, "receipt_sha256": _digest(receipts), "thresholds": THRESHOLDS, "hosts": hosts, "stage_experiments": {block: result for block, result in stage_results.items() if block != "full_pipeline"}, "calibration": calibration or {"status": "unverified", "reason": "human_calibration_unavailable"}, "evaluation_decision": decision, "verification": verification, "release_eligibility": verification["release_eligibility"]}


def verify_published_evaluation(
    *,
    published_summary: Path,
    protocol_path: Path,
    schedule_path: Path,
    execution_order_path: Path,
    receipts_path: Path,
    required_evidence_path: Path,
    evidence_root: Path,
    calibration_path: Path | None = None,
    stage_calibration_paths: Sequence[Path] = (),
) -> dict[str, Any]:
    """Recompute a published decision from the frozen inputs it claims to summarize."""
    if not evidence_root.is_absolute() or evidence_root.is_symlink() or not evidence_root.is_dir():
        raise EvaluationError("evidence root must be an absolute regular directory")
    published = _validate_published_result(_read_frozen_json(published_summary, "published evaluation"))
    protocol = _read_frozen_json(protocol_path, "frozen protocol")
    schedule = _read_frozen_json(schedule_path, "frozen schedule")
    execution_order = _read_frozen_json(execution_order_path, "frozen execution order")
    receipts = _read_frozen_json(receipts_path, "frozen receipts")
    requirements = _validate_required_evidence(_read_frozen_json(required_evidence_path, "frozen required evidence"))
    calibration_records = _read_frozen_json(calibration_path, "frozen calibration records") if calibration_path else None
    if calibration_records is not None and not isinstance(calibration_records, Mapping):
        raise EvaluationError("frozen calibration records have invalid shape")
    if not isinstance(protocol, Mapping) or not isinstance(schedule, list) or not isinstance(execution_order, list) or not isinstance(receipts, list):
        raise EvaluationError("frozen evaluation inputs have invalid shapes")
    recomputed = reduce_evaluation(
        protocol,
        schedule,
        receipts,
        execution_order=execution_order,
        calibration_records=calibration_records,
        stage_calibration_records=[_read_frozen_json(path, "frozen stage calibration records") for path in stage_calibration_paths],
        required_evidence=requirements,
        evidence_root=evidence_root,
    )
    _validate_published_result(recomputed)
    if published != recomputed:
        raise EvaluationError("published evaluation does not match frozen reducer output")
    if recomputed.get("release_eligibility") is not True:
        raise EvaluationError("recomputed evaluation is not release eligible")
    return recomputed


def main(argv: Sequence[str] | None = None) -> int:  # pragma: no cover - exercised by quality-check integration
    parser = argparse.ArgumentParser(description="Recompute and verify a frozen Bugsweep evaluation publication")
    parser.add_argument("--published-summary", required=True, type=Path)
    parser.add_argument("--protocol", required=True, type=Path)
    parser.add_argument("--schedule", required=True, type=Path)
    parser.add_argument("--execution-order", required=True, type=Path)
    parser.add_argument("--receipts", required=True, type=Path)
    parser.add_argument("--required-evidence", required=True, type=Path)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--calibration", type=Path)
    parser.add_argument("--stage-calibration", type=Path, action="append", default=[])
    args = parser.parse_args(argv)
    try:
        result = verify_published_evaluation(
            published_summary=args.published_summary,
            protocol_path=args.protocol,
            schedule_path=args.schedule,
            execution_order_path=args.execution_order,
            receipts_path=args.receipts,
            required_evidence_path=args.required_evidence,
            evidence_root=args.evidence_root,
            calibration_path=args.calibration,
            stage_calibration_paths=args.stage_calibration,
        )
    except EvaluationError as exc:
        print(f"evaluation verification failed: {exc}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
