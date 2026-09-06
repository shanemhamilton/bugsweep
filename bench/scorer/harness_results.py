"""Import frozen native benchmark output into blinded human-review packets."""
from __future__ import annotations

import hashlib
import math
from pathlib import Path
from typing import Any, Mapping, Sequence

from bench import _stages
from bench.harness import adapter_metadata, digest, write_once
from bench.scorer.calibration import build_blinded_packets, freeze_sample
from bench.scorer.evaluation import _read_frozen_json, reduce_evaluation
from bench.scorer.evidence import verify_packet
from scripts._execution import validate_execution_receipt
from scripts._review_evidence import _read, parse_host_message


def candidates_from_message(text: str, receipt: Mapping[str, Any], slot: Mapping[str, Any], *, hunter_candidates: Sequence[Mapping[str, Any]] = ()) -> list[dict[str, Any]]:
    """Parse the declared native contract. Invalid entries invalidate the slot."""
    rows = []
    originals = {item["bug_id"]: item for item in hunter_candidates}
    for item in _stages.parse_candidates(text):
        original = originals.get(item["bug_id"], item)
        identity = {key: receipt[key] for key in ("experiment_id", "host", "arm", "case_id", "repetition", "order_slot_sha256")}
        identity["stage_block"] = str(receipt.get("stage_block", "full_pipeline"))
        candidate_id = digest({**identity, "bug_id": item["bug_id"]})
        excerpt = next((source for source in receipt.get("trusted_source_excerpts", []) if isinstance(source, dict) and source.get("path") == item["file"] and type(source.get("start_line")) is int and type(source.get("end_line")) is int and source["start_line"] <= item["line"] <= source["end_line"]), None)
        packet = {"schema_version": 1, "candidate_id": candidate_id, "status": "verified", "reasons": [],
                  "source": {"path": item["file"], "sha256": excerpt.get("source_sha256"), "excerpt_start": excerpt.get("start_line"), "excerpt_end": excerpt.get("end_line"), "excerpt": excerpt.get("text")} if excerpt else None,
                  "claim": original["rationale"], "trigger": {"kind": "reported_condition", "value": original["trigger"]}, "repro": None}
        reasons = verify_packet(packet, trusted_excerpt=excerpt, expected_candidate_id=candidate_id, expected_source_path=item["file"])
        packet.update(status="unverified" if reasons else "verified", reasons=reasons)
        rows.append({**identity, "candidate_id": candidate_id, "bug_id": item["bug_id"], "file": item["file"], "line": item["line"],
                     "category": slot.get("category", ""), "repository": slot.get("repository", ""),
                     "severity": item["severity"], "status": item["status"], "rationale": item["rationale"], "evidence": packet})
    return rows


def _stage_blocks(protocol: Mapping[str, Any]) -> dict[str, tuple[str, ...]]:
    try:
        return {block["id"]: tuple(block["stages"]) for block in _stages.normalize_stage_blocks(protocol.get("ablation_blocks"))}
    except ValueError as exc:
        # Historical reduced-prompt artifacts have no actual stage evidence.
        if protocol.get("ablation_blocks") == ["current_skill", "previous_release", "no_skill_baseline"]:
            return {"full_pipeline": ()}
        raise ValueError("frozen protocol stage blocks are invalid") from exc


def _read_stage_chain(directory: Path, receipt: Mapping[str, Any], slot: Mapping[str, Any], protocol: Mapping[str, Any], stages: tuple[str, ...]) -> tuple[str, Mapping[str, Any], bytes, list[dict[str, Any]]]:
    """Return the final native message only after every recorded stage binds."""
    lineage = receipt.get("stage_lineage")
    records = receipt.get("stage_receipts")
    if not isinstance(lineage, Mapping) or not isinstance(records, list) or tuple(lineage.get("stages", ())) != stages or lineage.get("stage_count") != len(stages) or lineage.get("role") != "detect_only" or lineage.get("block_id") != slot.get("stage_block") or lineage.get("host") != slot.get("host") or lineage.get("model") != slot.get("model") or lineage.get("model_version") != protocol["hosts"][slot["host"]]["model_version"] or lineage.get("source_manifest_sha256") != slot.get("source_manifest_sha256") or lineage.get("configured_total_limits") != receipt.get("configured_limits"):
        raise ValueError("stage lineage binding mismatch")
    deadline = lineage.get("deadline_epoch")
    if isinstance(deadline, bool) or not isinstance(deadline, (int, float)) or not math.isfinite(float(deadline)):
        raise ValueError("stage deadline evidence invalid")
    proxy = lineage.get("proxy")
    if not isinstance(proxy, Mapping) or not isinstance(proxy.get("container_id"), str) or not proxy["container_id"]:
        raise ValueError("stage proxy binding unavailable")
    if len(records) != len(stages):
        raise ValueError("stage receipt count mismatch")
    assessments: dict[str, list[dict[str, Any]]] = {}
    seen_sessions: set[str] = set()
    final: tuple[str, Mapping[str, Any], bytes] | None = None
    expected_arm = protocol["hosts"][slot["host"]]["arms"][slot["arm"]]
    templates = lineage.get("stage_prompt_template_sha256")
    if not isinstance(templates, Mapping) or set(templates) != set(stages):
        raise ValueError("stage prompt lineage missing")
    for index, (stage, record) in enumerate(zip(stages, records), start=1):
        if not isinstance(record, Mapping) or record.get("stage") != stage or record.get("role") != stage or record.get("model") != slot.get("model") or record.get("source_manifest_sha256") != slot.get("source_manifest_sha256") or record.get("source_valid") is not True or record.get("lifecycle") != "completed" or record.get("reason_code") is not None:
            raise ValueError("stage receipt identity invalid")
        candidate_input = _stages.stage_input(stage, assessments)
        if record.get("candidate_input_sha256") != digest(candidate_input) or record.get("stage_prompt_template_sha256") != templates.get(stage) or record.get("stage_prompt_template_sha256") != digest(_stages.stage_prompt(stage)):
            raise ValueError("stage prompt or candidate lineage mismatch")
        stage_dir = directory / "stages" / f"{index:02d}-{stage}"
        raw_path, execution_path = stage_dir / "response.jsonl", stage_dir / "execution-receipt.json"
        if record.get("raw_response_path") != str(raw_path):
            raise ValueError("stage raw path mismatch")
        raw, execution = _read(raw_path), _read_frozen_json(execution_path, "stage execution receipt")
        raw_sha = hashlib.sha256(raw).hexdigest()
        if record.get("raw_response_sha256") != raw_sha or record.get("execution_receipt_sha256") != digest(execution):
            raise ValueError("stage raw or execution digest mismatch")
        sources = execution.get("source_identity", {}).get("source_file_sha256", {})
        if digest(sources) != slot["source_manifest_sha256"] or validate_execution_receipt(execution, expected_source_map=sources, required_network="approved-proxy-only"):
            raise ValueError("stage execution source evidence invalid")
        if not any(output.get("path") == str(raw_path) and output.get("sha256") == raw_sha for output in execution.get("outputs", [])):
            raise ValueError("stage native output binding mismatch")
        metadata = adapter_metadata(stage_dir / "adapter-metadata.json")
        if metadata.get("effective_prompt_sha256") != record.get("prompt_sha256") or metadata.get("loaded_skill_sha256") != expected_arm.get("skill_entrypoint_sha256"):
            raise ValueError("stage adapter provenance mismatch")
        message = parse_host_message(receipt["host"], raw.decode("utf-8"))
        if message["session_id"] != record.get("native_session_id"):
            raise ValueError("stage native session binding mismatch")
        if message["session_id"] in seen_sessions:
            raise ValueError("stage native session reused across stages")
        candidates = _stages.parse_candidates(message["text"])
        _stages.validate_stage_candidates(stage, candidates, assessments)
        assessments[stage] = candidates
        seen_sessions.add(message["session_id"])
        final = (message["text"], execution, raw)
    if final is None:
        raise ValueError("stage chain has no native final output")
    return (*final, assessments.get("hunter", []))


def import_harness_results(results_root: Path, frozen_root: Path, *, stage_block: str = "full_pipeline") -> dict[str, Any]:
    """Verify receipt/raw bytes and retain all scheduled slots, without a judge call."""
    if any(not root.is_absolute() or root.is_symlink() or not root.is_dir() for root in (results_root, frozen_root)):
        raise ValueError("result and frozen roots must be absolute directories")
    protocol, schedule, order = (_read_frozen_json(frozen_root / name, name) for name in ("evaluation-protocol.json", "schedule.json", "execution-order.json"))
    receipts = _read_frozen_json(results_root / "benchmark-receipts.json", "benchmark receipts")
    reduce_evaluation(protocol, schedule, receipts, execution_order=order)
    coordinator = _read_frozen_json(results_root / "coordinator-receipt.json", "coordinator receipt")
    if any(coordinator.get(key) != protocol[key] for key in ("schedule_sha256", "execution_order_sha256")) or coordinator.get("receipt_sha256") != digest(receipts):
        raise ValueError("coordinator receipt binding mismatch")
    blocks = _stage_blocks(protocol)
    if stage_block not in blocks:
        raise ValueError("selected stage block is not frozen in the protocol")
    by_ordinal: dict[int, Mapping[str, Any]] = {}
    for row in receipts:
        ordinal = row.get("ordinal") if isinstance(row, Mapping) else None
        if type(ordinal) is not int or ordinal in by_ordinal:
            raise ValueError("benchmark receipts have duplicate or malformed ordinals")
        by_ordinal[ordinal] = row
    frame, runs = [], []
    for slot in (row for row in order if row.get("stage_block", "full_pipeline") == stage_block):
        receipt = by_ordinal.get(slot["ordinal"])
        run = {key: slot[key] for key in ("ordinal", "host", "arm", "stage_block", "case_id", "repetition", "order_slot_sha256")}
        run.update(status="unverified", reason="receipt_missing", candidates=None)
        runs.append(run)
        if receipt is None:
            continue
        if receipt["lifecycle"] != "completed":
            run["reason"] = "invocation_" + receipt["lifecycle"]
            continue
        directory = results_root / f"invocation-{slot['ordinal']:06d}"
        try:
            local = _read_frozen_json(directory / "benchmark-invocation-receipt.json", "invocation receipt")
            if local != receipt or receipt.get("stage_block", "full_pipeline") != stage_block:
                raise ValueError("invocation receipt binding mismatch")
            if blocks[stage_block]:
                text, execution, raw, hunter_candidates = _read_stage_chain(directory, receipt, slot, protocol, blocks[stage_block])
                if receipt.get("execution_receipt_sha256") != digest(execution) or receipt.get("raw_response_sha256") != hashlib.sha256(raw).hexdigest():
                    raise ValueError("final stage receipt binding mismatch")
            else:  # Archived reduced-prompt evidence has no usable ablation result.
                raise ValueError("legacy stage evidence is not comparable")
            rows = candidates_from_message(text, receipt, slot, hunter_candidates=hunter_candidates)
            frame.extend(rows)
            run.update(status="parsed", reason=None, candidates=len(rows), session_id=parse_host_message(receipt["host"], raw.decode("utf-8"))["session_id"])
        except (ValueError, OSError, KeyError, TypeError) as exc:
            # Preserve malformed or unavailable slots. They are not zero findings.
            run["reason"] = "native_evidence_unverified"
    frozen = freeze_sample(frame, seed=protocol["seed"])
    packets, unblinding = build_blinded_packets(frame, frozen)
    return {"schema_version": 1, "stage_block": stage_block, "schedule_sha256": protocol["schedule_sha256"], "execution_order_sha256": protocol["execution_order_sha256"],
            "input_roots": {"results": str(results_root), "frozen": str(frozen_root)},
            "receipts_sha256": digest(receipts), "frame_complete": bool(runs) and all(run["status"] == "parsed" for run in runs),
            "runs": runs, "frame": frame, "frozen": frozen, "packets": packets, "unblinding": unblinding, "labels": [], "adjudications": []}


def write_review_export(bundle: Mapping[str, Any], output: Path) -> None:
    if output.exists() or not output.parent.is_dir():
        raise ValueError("review export requires a new output directory")
    output.mkdir(mode=0o700)
    write_once(output / "calibration-records.json", {key: value for key, value in bundle.items() if key != "packets"})
    write_once(output / "blinded-packets.json", bundle["packets"])
