#!/usr/bin/env python3
"""WU6 benchmark coordinator.

This module deliberately does not start containers or model CLIs itself.  A
trusted execution-profile owner supplies the policy consumed by
``scripts._execution.run_command``.  Keeping that boundary here prevents a
benchmark from silently falling back to an ambient login or an unbounded host
process.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import random
import stat
import sys
import time
import re
import subprocess
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from bench import _stages

ARM_SET = ("current_skill", "previous_release", "no_skill_baseline")
MAX_RESPONSE_BYTES = 1_048_576
MAX_MANIFEST_DESCRIPTION_BYTES = 8_192


class HarnessError(ValueError):
    pass


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest(value: Any) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def file_digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(64 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def source_manifest(root: Path, excludes: Iterable[str] = (".git",)) -> dict[str, Any]:
    """Hash the complete scoped source tree; unexpected files are included."""
    root = root.resolve(strict=True)
    forbidden = {PurePosixPath(item).as_posix().strip("/") for item in excludes}
    files: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if any(relative == item or relative.startswith(item + "/") for item in forbidden):
            continue
        if path.is_symlink():
            raise HarnessError(f"source scope contains symlink: {relative}")
        if not path.is_file():
            if path.exists() and not path.is_dir():
                raise HarnessError(f"source scope contains non-regular path: {relative}")
            continue
        files[relative] = file_digest(path)
    if not files:
        raise HarnessError("source scope is empty")
    return {"kind": "content-manifest-sha256", "sha256": digest(files), "source_file_sha256": files}


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HarnessError(f"invalid JSON: {path}") from exc
    if not isinstance(value, dict):
        raise HarnessError(f"JSON object required: {path}")
    return value


def _sha256(value: object) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def validate_protocol(protocol: Mapping[str, Any], *, frozen: bool = False) -> dict[str, Any]:
    if protocol.get("schema_version") != 1 or not isinstance(protocol.get("experiment_id"), str):
        raise HarnessError("protocol requires schema_version=1 and experiment_id")
    hosts = protocol.get("hosts")
    if not isinstance(hosts, Mapping) or set(hosts) != {"claude", "codex"}:
        raise HarnessError("protocol must freeze exactly claude and codex hosts")
    for host_name, host in hosts.items():
        if not isinstance(host, Mapping):
            raise HarnessError("host must be claude or codex")
        if not isinstance(host.get("model"), str) or not host["model"] or not isinstance(host.get("model_version"), str) or not host["model_version"]:
            raise HarnessError(f"host {host_name} must pin model and model_version")
        arms = host.get("arms")
        if not isinstance(arms, Mapping) or not set(ARM_SET).issubset(arms):
            raise HarnessError(f"host {host_name} lacks required arm provenance")
        for arm in ARM_SET:
            provenance = arms[arm]
            if not isinstance(provenance, Mapping) or any(not _sha256(provenance.get(k)) for k in ("skill_content_sha256", "adapter_sha256", "prompt_sha256", "config_sha256")) or not isinstance(provenance.get("skill_revision"), str):
                raise HarnessError(f"host {host_name} arm {arm} has incomplete provenance")
            entrypoint = provenance.get("skill_entrypoint_sha256")
            if (arm == "no_skill_baseline" and entrypoint is not None) or (arm != "no_skill_baseline" and not _sha256(entrypoint)):
                raise HarnessError(f"host {host_name} arm {arm} has invalid SKILL.md provenance")
        if arms["current_skill"]["skill_content_sha256"] == arms["previous_release"]["skill_content_sha256"]:
            raise HarnessError(f"host {host_name} previous_release content must differ from current_skill")
    limits = protocol.get("limits")
    if not isinstance(limits, Mapping) or isinstance(limits.get("wall_clock_seconds"), bool) or not isinstance(limits.get("wall_clock_seconds"), int) or limits["wall_clock_seconds"] < 1:
        raise HarnessError("protocol requires a positive wall_clock_seconds limit")
    for key in ("max_turns", "max_input_tokens", "max_output_tokens", "max_spend_usd"):
        if key not in limits or (limits[key] is not None and (not isinstance(limits[key], (int, float)) or isinstance(limits[key], bool) or not math.isfinite(float(limits[key])) or limits[key] < 0)):
            raise HarnessError(f"protocol limit is invalid: {key}")
    if protocol.get("cap_approval") != "operator-approved":
        raise HarnessError("protocol is not approved for a live evaluation")
    if protocol.get("core_arms") != list(ARM_SET):
        raise HarnessError("protocol must freeze the required core comparison arms")
    try:
        _stages.normalize_stage_blocks(protocol.get("ablation_blocks"))
    except ValueError as exc:
        raise HarnessError("protocol must declare independent pipeline-stage ablation blocks") from exc
    if frozen and (not _sha256(protocol.get("schedule_sha256")) or not _sha256(protocol.get("execution_order_sha256"))):
        raise HarnessError("frozen protocol requires schedule and execution-order digests")
    if frozen and (isinstance(protocol.get("repetitions"), bool) or not isinstance(protocol.get("repetitions"), int) or protocol["repetitions"] < 3):
        raise HarnessError("frozen protocol requires at least three repetitions")
    rate_table = protocol.get("rate_table")
    if not isinstance(rate_table, Mapping) or not isinstance(rate_table.get("version"), str) or not rate_table["version"] or not _sha256(rate_table.get("sha256")):
        raise HarnessError("protocol requires an operator-pinned rate_table version and sha256")
    if frozen and protocol.get("evaluation_mode") != "reduced_detect_only_prompt_methodology":
        raise HarnessError("frozen protocol must declare the reduced detect-only evaluation mode")
    return dict(protocol)


def read_protocol(path: Path, *, frozen: bool = False) -> dict[str, Any]:
    return validate_protocol(read_json(path), frozen=frozen)


def redacted_case(case: Mapping[str, Any]) -> dict[str, Any]:
    """Only the task-facing, non-truth manifest is ever placed beside an agent."""
    description = case.get("task_description", "")
    if not isinstance(description, str) or len(description.encode()) > MAX_MANIFEST_DESCRIPTION_BYTES:
        raise HarnessError("case task_description is missing or too large")
    return {"id": case.get("id"), "language": case.get("language"), "size_ceiling": case.get("size_ceiling"), "task_description": description}


def build_schedule(protocol: Mapping[str, Any], cases: list[Mapping[str, Any]], repetitions: int) -> list[dict[str, Any]]:
    if repetitions < 3:
        raise HarnessError("repetitions must be at least three")
    stage_blocks = _stages.normalize_stage_blocks(protocol["ablation_blocks"])
    slots: list[dict[str, Any]] = []
    for host_name, host in protocol["hosts"].items():
        for case in cases:
            source = case.get("source_manifest_sha256")
            if not isinstance(source, str) or len(source) != 64:
                raise HarnessError("each redacted case requires source_manifest_sha256")
            for repetition in range(1, repetitions + 1):
                slot = {
                    "experiment_id": protocol["experiment_id"], "host": host_name,
                    "model": host["model"], "case_id": case.get("id"),
                    "category": case.get("category", ""), "repository": case.get("repository", ""),
                    "repetition": repetition, "limit_profile": protocol.get("limit_profile", "default"),
                    "source_manifest_sha256": source, "arms": list(ARM_SET),
                    "stage_blocks": [block["id"] for block in stage_blocks],
                    "redacted_manifest_sha256": digest(redacted_case(case)),
                }
                slot["schedule_slot_sha256"] = digest(slot)
                slots.append(slot)
    return sorted(slots, key=lambda slot: (slot["host"], slot["case_id"], slot["repetition"]))


def execution_order(protocol: Mapping[str, Any], schedule: list[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Seeded core-arm and actual stage-block order."""
    order = [{**slot, "arm": arm, "stage_block": stage_block}
             for slot in schedule for arm in ARM_SET for stage_block in slot["stage_blocks"]]
    seed = protocol.get("seed")
    if not isinstance(seed, int):
        raise HarnessError("protocol requires integer seed")
    random.Random(seed).shuffle(order)
    frozen_order = []
    for ordinal, slot in enumerate(order, start=1):
        identity = {"ordinal": ordinal, "schedule_slot_sha256": slot["schedule_slot_sha256"], "arm": slot["arm"], "stage_block": slot["stage_block"]}
        frozen_order.append({**slot, "ordinal": ordinal, "order_slot_sha256": digest(identity)})
    return frozen_order


def freeze_documents(protocol: Mapping[str, Any], cases: list[Mapping[str, Any]], repetitions: int) -> dict[str, Any]:
    """Freeze a draft protocol and its deterministic schedule without self-hashing.

    Schedule rows deliberately omit the generated digest fields, so binding the
    two output digests into the protocol does not create a circular hash.
    """
    if isinstance(repetitions, bool) or not isinstance(repetitions, int) or repetitions < 3:
        raise HarnessError("freeze requires at least three repetitions")
    draft = validate_protocol(protocol)
    if "schedule_sha256" in draft or "execution_order_sha256" in draft:
        raise HarnessError("freeze input must not already contain generated schedule digests")
    schedule = build_schedule(draft, cases, repetitions)
    order = execution_order(draft, schedule)
    frozen = {**draft, "repetitions": repetitions, "evaluation_mode": "reduced_detect_only_prompt_methodology", "schedule_sha256": digest(schedule), "execution_order_sha256": digest(order)}
    validate_protocol(frozen, frozen=True)
    return {"protocol": frozen, "schedule": schedule, "execution_order": order}


def validate_order_slot(slot: Mapping[str, Any]) -> None:
    ordinal = slot.get("ordinal")
    identity = {"ordinal": ordinal, "schedule_slot_sha256": slot.get("schedule_slot_sha256"), "arm": slot.get("arm"), "stage_block": slot.get("stage_block")}
    if isinstance(ordinal, bool) or not isinstance(ordinal, int) or ordinal < 1 or not _sha256(slot.get("schedule_slot_sha256")) or not isinstance(slot.get("stage_block"), str) or slot.get("order_slot_sha256") != digest(identity):
        raise HarnessError("scheduled execution-order slot is invalid")


def adapter_argv(host: str, model: str, prompt: str, arm: str) -> list[str]:
    # Native structured formats are parsed after the execution provider has
    # bounded/captured stdout.  No OAuth, user config, or provider key is used.
    if host == "claude":
        return ["/usr/local/bin/bench-host-adapter", host, model, arm, prompt]
    if host == "codex":
        return ["/usr/local/bin/bench-host-adapter", host, model, arm, prompt]
    raise HarnessError("unsupported host")


def native_usage(raw: Path, host: str, rate_table: Mapping[str, Any]) -> dict[str, Any]:
    """Read only native JSON usage; estimates require an explicit provider value."""
    input_tokens = output_tokens = total_tokens = None
    cost_usd: float | None = None
    cost_source = "unknown"
    rate_table_version: str | None = None
    rate_table_sha256: str | None = None
    pinned_rate_version = rate_table.get("version") if isinstance(rate_table, Mapping) else None
    pinned_rate_sha256 = rate_table.get("sha256") if isinstance(rate_table, Mapping) else None
    if raw.exists() and raw.stat().st_size <= MAX_RESPONSE_BYTES:
        for line in raw.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, Mapping):
                continue
            usage = event.get("usage") or event.get("message", {}).get("usage") if isinstance(event.get("message"), Mapping) else event.get("usage")
            if not isinstance(usage, Mapping):
                continue
            candidate_input = usage.get("input_tokens", usage.get("input"))
            candidate_output = usage.get("output_tokens", usage.get("output"))
            candidate_total = usage.get("total_tokens", usage.get("total"))
            input_tokens = candidate_input if isinstance(candidate_input, int) and not isinstance(candidate_input, bool) and candidate_input >= 0 else input_tokens
            output_tokens = candidate_output if isinstance(candidate_output, int) and not isinstance(candidate_output, bool) and candidate_output >= 0 else output_tokens
            total_tokens = candidate_total if isinstance(candidate_total, int) and not isinstance(candidate_total, bool) and candidate_total >= 0 else total_tokens
            if isinstance(usage.get("cost_usd"), (int, float)) and not isinstance(usage.get("cost_usd"), bool) and math.isfinite(float(usage["cost_usd"])) and usage["cost_usd"] >= 0:
                cost_usd, cost_source = float(usage["cost_usd"]), "actual"
            elif (isinstance(usage.get("estimated_cost_usd"), (int, float)) and not isinstance(usage.get("estimated_cost_usd"), bool)
                  and math.isfinite(float(usage["estimated_cost_usd"])) and usage["estimated_cost_usd"] >= 0
                  and cost_source == "unknown" and usage.get("rate_table_version") == pinned_rate_version
                  and usage.get("rate_table_sha256") == pinned_rate_sha256):
                cost_usd, cost_source = float(usage["estimated_cost_usd"]), "rate_estimated"
                rate_table_version, rate_table_sha256 = str(pinned_rate_version), str(pinned_rate_sha256)
    if total_tokens is None and isinstance(input_tokens, int) and isinstance(output_tokens, int):
        total_tokens = input_tokens + output_tokens
    return {"input_tokens": input_tokens, "output_tokens": output_tokens, "total_tokens": total_tokens, "cost_usd": cost_usd, "cost_source": cost_source, "provider": host,
            "rate_table_version": rate_table_version, "rate_table_sha256": rate_table_sha256}


def write_once(path: Path, value: Any) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as fh:
        fh.write(canonical(value))
        fh.flush()
        os.fsync(fh.fileno())


def receipt_elapsed_seconds(receipt: Mapping[str, Any]) -> float | None:
    try:
        started = dt.datetime.fromisoformat(str(receipt["started_at"]).replace("Z", "+00:00"))
        finished = dt.datetime.fromisoformat(str(receipt["finished_at"]).replace("Z", "+00:00"))
    except (KeyError, TypeError, ValueError):
        return None
    return max(0.0, (finished - started).total_seconds())


def trusted_source_excerpts(source_root: Path, raw: Path) -> list[dict[str, Any]]:
    """Derive bounded excerpts from the frozen source, never model-supplied text."""
    if not raw.exists() or raw.stat().st_size > MAX_RESPONSE_BYTES:
        return []
    excerpts: list[dict[str, Any]] = []
    seen: set[tuple[str, int]] = set()
    for match in re.finditer(r"(?P<path>[A-Za-z0-9_./-]+):(?P<line>[1-9][0-9]{0,6})", raw.read_text(encoding="utf-8", errors="replace")):
        relative, line = match.group("path"), int(match.group("line"))
        if relative.startswith("/") or ".." in PurePosixPath(relative).parts or (relative, line) in seen:
            continue
        path = source_root.joinpath(*PurePosixPath(relative).parts)
        if path.is_symlink() or not path.is_file():
            continue
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        if line > len(lines):
            continue
        seen.add((relative, line))
        start, end = max(1, line - 5), min(len(lines), line + 5)
        excerpts.append({"path": relative, "start_line": start, "end_line": end, "source_sha256": file_digest(path), "text": "\n".join(lines[start - 1:end])})
        if len(excerpts) == 8:
            break
    return excerpts


def preflight(protocol: Mapping[str, Any]) -> list[str]:
    reasons: list[str] = []
    profile = os.environ.get("BENCH_TRUSTED_BENCHMARK_PROFILE")
    if not profile or not Path(profile).is_absolute() or not Path(profile).is_file():
        reasons.append("trusted_benchmark_network_profile_missing")
    else:
        try:
            policy = read_json(Path(profile))
        except HarnessError:
            reasons.append("trusted_benchmark_network_profile_invalid")
        else:
            benchmark = policy.get("benchmark_profile")
            if policy.get("network_mode") != "approved-proxy-only" or not isinstance(benchmark, Mapping):
                reasons.append("trusted_benchmark_network_profile_invalid")
    if os.environ.get("BENCH_CAP_APPROVAL_ID", "") != protocol.get("cap_approval_id", ""):
        reasons.append("operator_cap_approval_missing_or_mismatched")
    return reasons


def _prompt(case: Mapping[str, Any], arm: str) -> str:
    manifest = canonical(redacted_case(case)).decode("utf-8")
    instruction = {
        "current_skill": "Use the supplied current Bugsweep skill snapshot.",
        "previous_release": "Use only the supplied previous-release Bugsweep skill snapshot.",
        "no_skill_baseline": "Do not load any Bugsweep skill; perform the baseline review directly.",
    }[arm]
    return ("BENCHMARK REDUCED DETECT-ONLY PROMPT METHODOLOGY: this does not execute or measure the full Bugsweep workflow, lifecycle, tracker, or subagent phase protocols. Inspect only the mounted archive source. Do not run commands, Git, "
            "trackers, tests, lifecycle scripts, network tools, or write files. Do not read parent directories, "
            "benchmark metadata, gold data, advisory history, or future runs. Apply the supplied immutable skill "
            "excerpt only as source-review methodology; every operational workflow instruction is out of scope. "
            "A later frozen role prompt supplies the candidate contract and replaces the legacy `FINDING:` marker with strict JSON-only output. " + instruction +
            "\nRedacted task manifest:\n" + manifest)


def _stage_block(protocol: Mapping[str, Any], identifier: object) -> Mapping[str, Any]:
    for block in _stages.normalize_stage_blocks(protocol["ablation_blocks"]):
        if block["id"] == identifier:
            return block
    raise HarnessError("execution slot references an undeclared stage block")


def _run_pipeline_stages(*, protocol: Mapping[str, Any], slot: Mapping[str, Any], case: Mapping[str, Any], source_root: Path, output: Path, profile: Mapping[str, Any], expected_arm: Mapping[str, Any], endpoint_env: Mapping[str, str]) -> tuple[list[dict[str, Any]], Mapping[str, Any] | None, Path | None, dict[str, Any]]:
    """Run each declared stage as a fresh native invocation under one slot deadline.

    The executor owns raw artifacts.  This coordinator only records their
    observed hashes and native session ids after parsing the host format.
    """
    from scripts import _execution
    from scripts._review_evidence import parse_host_message

    block = _stage_block(protocol, slot.get("stage_block"))
    deadline = time.time() + int(protocol["limits"]["wall_clock_seconds"])
    proxy = profile.get("benchmark_profile", {}).get("proxy", {}) if isinstance(profile.get("benchmark_profile"), Mapping) else {}
    lineage = {"block_id": block["id"], "stages": block["stages"], "stage_count": len(block["stages"]),
               "role": "detect_only", "host": slot["host"], "model": slot["model"],
               "model_version": protocol["hosts"][slot["host"]]["model_version"],
               "source_manifest_sha256": slot["source_manifest_sha256"], "deadline_epoch": deadline,
               "configured_total_limits": dict(protocol["limits"]),
               "stage_prompt_template_sha256": {stage: digest(_stages.stage_prompt(stage)) for stage in block["stages"]},
               "proxy": {key: proxy.get(key) for key in ("container_name", "container_id", "image_digest")}}
    stage_receipts: list[dict[str, Any]] = []
    assessments: dict[str, list[dict[str, Any]]] = {}
    seen_sessions: set[str] = set()
    final_execution: Mapping[str, Any] | None = None
    final_raw: Path | None = None
    final_metadata: dict[str, Any] = {}
    executions: list[Mapping[str, Any] | None] = []
    raws: list[Path | None] = []
    metadata_by_stage: list[dict[str, Any]] = []
    for index, stage in enumerate(block["stages"], start=1):
        stage_output = output / "stages" / f"{index:02d}-{stage}"
        stage_output.mkdir(mode=0o700, parents=True)
        candidate_input = _stages.stage_input(stage, assessments)
        prompt = _prompt(case, str(slot["arm"])) + "\n\n" + _stages.stage_prompt(stage, assessments=assessments)
        execution: Mapping[str, Any] | None = None
        reason: str | None = None
        try:
            execution = _execution.run_command(
                adapter_argv(str(slot["host"]), str(slot["model"]), prompt, str(slot["arm"])),
                source_root, stage_output, deadline, profile, dict(endpoint_env),
                ({"path": "response.jsonl", "kind": "host-adapter-json", "max_bytes": MAX_RESPONSE_BYTES},
                 {"path": "adapter-metadata.json", "kind": "host-adapter-json", "max_bytes": 256}),
            )
        except (OSError, ValueError) as exc:
            reason = f"execution_error:{type(exc).__name__}"
        raw = stage_output / "response.jsonl"
        metadata = adapter_metadata(stage_output / "adapter-metadata.json")
        executions.append(execution)
        raws.append(raw if raw.is_file() else None)
        metadata_by_stage.append(metadata)
        session_id = None
        candidates: list[dict[str, Any]] | None = None
        if execution is not None and execution.get("termination") == "exited" and execution.get("exit_code") == 0 and raw.is_file():
            try:
                message = parse_host_message(str(slot["host"]), raw.read_text(encoding="utf-8", errors="strict"))
                session_id = message["session_id"]
                candidates = _stages.parse_candidates(message["text"])
                _stages.validate_stage_candidates(stage, candidates, assessments)
                if session_id in seen_sessions:
                    raise ValueError("native session reused across stages")
            except (OSError, UnicodeDecodeError, ValueError) as exc:
                reason = f"native_stage_unverified:{type(exc).__name__}"
        elif execution is not None:
            reason = str(execution.get("reason") or "native_stage_not_completed")[:160]
        observed = source_manifest(source_root)
        source_valid = observed["sha256"] == slot["source_manifest_sha256"]
        prompt_valid = _sha256(metadata.get("effective_prompt_sha256")) and metadata.get("loaded_skill_sha256") == expected_arm.get("skill_entrypoint_sha256")
        prior_unverified = any(item["lifecycle"] != "completed" for item in stage_receipts)
        if prior_unverified and reason is None:
            reason = "prior_stage_unverified"
        lifecycle = "completed" if candidates is not None and reason is None and source_valid and prompt_valid and not prior_unverified else "error"
        stage_receipts.append({"stage": stage, "role": stage, "model": slot["model"],
                               "source_manifest_sha256": observed["sha256"], "source_valid": source_valid,
                               "candidate_input_sha256": digest(candidate_input),
                               "stage_prompt_template_sha256": lineage["stage_prompt_template_sha256"][stage],
                               "prompt_sha256": metadata.get("effective_prompt_sha256") if prompt_valid else None,
                               "execution_receipt_sha256": digest(execution) if execution is not None else None,
                               "raw_response_path": str(raw) if raw.is_file() else None,
                               "raw_response_sha256": file_digest(raw) if raw.is_file() else None,
                               "native_session_id": session_id, "lifecycle": lifecycle, "reason_code": reason})
        if candidates is not None:
            assessments[stage] = candidates
            if lifecycle == "completed" and session_id is not None:
                seen_sessions.add(session_id)
        if stage == block["stages"][-1]:
            final_execution, final_raw, final_metadata = execution, raw if raw.is_file() else None, metadata
    return stage_receipts, final_execution, final_raw, {"lineage": lineage, "metadata": final_metadata, "executions": executions, "raws": raws, "metadata_by_stage": metadata_by_stage}


def invoke_slot(protocol: Mapping[str, Any], slot: Mapping[str, Any], case: Mapping[str, Any], source_root: Path, output: Path, *, finalize: bool = True) -> dict[str, Any]:
    """Run one already-scheduled slot through the shared trusted executor.

    The externally owned profile must bind this exact snapshot.  It is not
    generated here, because turning a benchmark's mutable inputs into its own
    execution policy would defeat the policy boundary.
    """
    validate_protocol(protocol, frozen=True)
    validate_order_slot(slot)
    if slot.get("schedule_sha256") not in {None, protocol["schedule_sha256"]} or slot.get("execution_order_sha256") not in {None, protocol["execution_order_sha256"]}:
        raise HarnessError("slot is bound to different schedule documents")
    reasons = preflight(protocol)
    if reasons:
        raise HarnessError("live invocation refused: " + ",".join(reasons))
    if slot.get("host") not in protocol["hosts"] or slot.get("arm") not in ARM_SET:
        raise HarnessError("slot is not from this protocol")
    if slot.get("redacted_manifest_sha256") != digest(redacted_case(case)):
        raise HarnessError("case prompt differs from the frozen schedule")
    pre = source_manifest(source_root)
    if pre["sha256"] != slot.get("source_manifest_sha256"):
        raise HarnessError("source pre-manifest does not match scheduled slot")
    profile = read_json(Path(os.environ["BENCH_TRUSTED_BENCHMARK_PROFILE"]))
    if profile.get("source_identity") != pre or Path(str(profile.get("target_root", ""))).resolve() != source_root.resolve():
        raise HarnessError("trusted execution profile is not bound to this source snapshot")
    host = str(slot["host"])
    expected_arm = protocol["hosts"][host]["arms"][slot["arm"]]
    benchmark = profile.get("benchmark_profile")
    if not isinstance(benchmark, Mapping) or benchmark.get("host") != host:
        raise HarnessError("trusted execution profile does not bind this host")
    proxy = benchmark.get("proxy")
    client = benchmark.get("client")
    if not isinstance(proxy, Mapping) or not isinstance(proxy.get("container_name"), str) or not isinstance(client, Mapping) or client.get("inert_credential_literal") != "benchmark-inert-client-credential":
        raise HarnessError("trusted execution profile lacks a verified inert proxy client")
    profile_arm = {"current_skill": "current", "previous_release": "previous", "no_skill_baseline": "baseline"}[str(slot["arm"])]
    arms = benchmark.get("arms")
    if not isinstance(arms, Mapping) or arms.get(profile_arm) != {"skill_revision": expected_arm["skill_revision"], "skill_content_sha256": expected_arm["skill_content_sha256"]}:
        raise HarnessError("trusted execution profile does not bind the exact arm snapshot")
    endpoint = f"http://{proxy['container_name']}:8888"
    # The strings below are placeholders only. The proxy overwrites the outbound
    # auth header from its operator-owned 0600 secret file; no real key enters
    # the analysis client, command, result, or invocation receipt.
    env = {"BENCH_INERT_CLIENT_ID": "benchmark-inert-client-credential"}
    if host == "claude":
        env["ANTHROPIC_BASE_URL"] = endpoint
    else:
        env["CODEX_BENCH_BASE_URL"] = endpoint
    stage_receipts, execution, raw, stage_run = _run_pipeline_stages(
        protocol=protocol, slot=slot, case=case, source_root=source_root, output=output,
        profile=profile, expected_arm=expected_arm, endpoint_env=env)
    post = source_manifest(source_root)
    source_ok = pre["sha256"] == post["sha256"] == slot["source_manifest_sha256"]
    stage_usage = [native_usage(stage_raw, host, protocol["rate_table"]) if stage_raw else native_usage(Path("/nonexistent"), host, protocol["rate_table"]) for stage_raw in stage_run["raws"]]
    usage = {"input_tokens": None, "output_tokens": None, "total_tokens": None, "cost_usd": None, "cost_source": "unknown", "provider": host, "rate_table_version": None, "rate_table_sha256": None}
    token_keys = ("input_tokens", "output_tokens", "total_tokens")
    if stage_usage and all(isinstance(item.get(key), int) and not isinstance(item.get(key), bool) for item in stage_usage for key in token_keys):
        usage.update({key: sum(item[key] for item in stage_usage) for key in token_keys})
    cost_sources = {item.get("cost_source") for item in stage_usage}
    if len(cost_sources) == 1 and cost_sources <= {"actual", "rate_estimated"} and all(isinstance(item.get("cost_usd"), float) for item in stage_usage):
        source = next(iter(cost_sources))
        usage.update(cost_usd=sum(item["cost_usd"] for item in stage_usage), cost_source=source)
        if source == "rate_estimated":
            versions = {(item.get("rate_table_version"), item.get("rate_table_sha256")) for item in stage_usage}
            if len(versions) != 1:
                usage.update(cost_usd=None, cost_source="unknown")
            else:
                usage["rate_table_version"], usage["rate_table_sha256"] = versions.pop()
    excerpts = trusted_source_excerpts(source_root, raw) if source_ok and raw else []
    metadata = stage_run["metadata"]
    loaded_skill = metadata.get("loaded_skill_sha256")
    expected_skill = expected_arm.get("skill_entrypoint_sha256")
    prompt_ok = _sha256(metadata.get("effective_prompt_sha256")) and loaded_skill == expected_skill
    completed = (execution is not None and execution.get("termination") == "exited" and execution.get("exit_code") == 0
                 and source_ok and prompt_ok and all(stage["lifecycle"] == "completed" for stage in stage_receipts))
    skipped = execution is not None and execution.get("termination") == "exited" and execution.get("exit_code") == 10
    lifecycle = "completed" if completed else "skipped" if skipped else "error"
    intervals = []
    for stage_execution in stage_run["executions"]:
        if stage_execution is None or receipt_elapsed_seconds(stage_execution) is None:
            continue
        try:
            intervals.append((dt.datetime.fromisoformat(str(stage_execution["started_at"]).replace("Z", "+00:00")), dt.datetime.fromisoformat(str(stage_execution["finished_at"]).replace("Z", "+00:00"))))
        except (KeyError, TypeError, ValueError):
            continue
    slot_start = min((started for started, _ in intervals), default=None)
    wall_clock = (max(finished for _, finished in intervals) - slot_start).total_seconds() if slot_start is not None else None
    first_finding = min((value for metadata in stage_run["metadata_by_stage"] if slot_start is not None for value in [first_finding_wallclock(metadata.get("first_finding_unix_seconds"), {"started_at": slot_start.isoformat()})] if value is not None), default=None)
    accounting = "complete" if usage["cost_source"] in {"actual", "rate_estimated"} and all(isinstance(usage[key], int) and not isinstance(usage[key], bool) for key in ("input_tokens", "output_tokens", "total_tokens")) and isinstance(usage["cost_usd"], float) and isinstance(wall_clock, float) else "unknown"
    configured = dict(protocol["limits"])
    provider_execution = execution or next((item for item in reversed(stage_run["executions"]) if item is not None), None)
    provider_limits = provider_execution.get("applied_limits") if provider_execution is not None else None
    applied = {key: provider_limits.get(key) if isinstance(provider_limits, Mapping) else None for key in configured}
    applied["enforced"] = bool(isinstance(provider_limits, Mapping) and provider_limits.get("enforced") is True and all(applied[key] == configured[key] for key in configured))
    applied["proof_execution_receipt_sha256"] = digest(provider_execution) if provider_execution is not None else None
    receipt = {
        "schema_version": 1, **{key: slot[key] for key in ("experiment_id", "host", "model", "case_id", "repetition", "limit_profile", "arm", "stage_block", "ordinal", "schedule_slot_sha256", "order_slot_sha256")},
        "schedule_sha256": protocol["schedule_sha256"], "execution_order_sha256": protocol["execution_order_sha256"], "evaluation_mode": protocol["evaluation_mode"], "effective_prompt_sha256": metadata.get("effective_prompt_sha256") if prompt_ok else None,
        "effective_prompt_binding_sha256": effective_prompt_binding(metadata.get("effective_prompt_sha256"), case, expected_arm) if prompt_ok else None,
        "provenance": {"model_version": protocol["hosts"][host]["model_version"], **protocol["hosts"][host]["arms"][slot["arm"]]},
        "configured_limits": configured, "applied_limits": applied,
        "source": {"expected_manifest_sha256": slot["source_manifest_sha256"], "observed_pre_manifest_sha256": pre["sha256"], "observed_post_manifest_sha256": post["sha256"], "valid": source_ok},
        "stage_lineage": stage_run["lineage"], "stage_receipts": stage_receipts,
        "execution_receipt_sha256": digest(provider_execution) if provider_execution is not None else None, "raw_response_sha256": file_digest(raw) if raw else None, "trusted_source_excerpts": excerpts,
        "first_finding_wallclock_seconds": first_finding, "lifecycle": lifecycle,
        "result": "completed_unscored" if completed else "skipped" if skipped else "error", "reason_code": "source_mutated" if not source_ok else "effective_prompt_provenance_mismatch" if not prompt_ok else execution.get("reason") if execution is not None else "stage_execution_unavailable",
        "usage": {**usage, "wall_clock_seconds": wall_clock}, "accounting_state": accounting, "limit_evidence": None,
    }
    if finalize:
        write_once(output / "benchmark-invocation-receipt.json", receipt)
    return receipt


def adapter_metadata(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    if not isinstance(value, Mapping) or not _sha256(value.get("effective_prompt_sha256")):
        return {}
    loaded = value.get("loaded_skill_sha256")
    if loaded is not None and not _sha256(loaded):
        return {}
    timestamp = value.get("first_finding_unix_seconds")
    if timestamp is not None and (isinstance(timestamp, bool) or not isinstance(timestamp, (int, float)) or not math.isfinite(float(timestamp))):
        return {}
    return dict(value)


def effective_prompt_binding(effective_prompt_sha256: object, case: Mapping[str, Any], arm: Mapping[str, Any]) -> str:
    """Bind trusted adapter-reported prompt bytes to frozen arm and case inputs."""
    if not _sha256(effective_prompt_sha256):
        raise HarnessError("adapter effective prompt digest is invalid")
    manifest_sha = case.get("redacted_manifest_sha256", digest(redacted_case(case)))
    if not _sha256(manifest_sha):
        raise HarnessError("frozen prompt manifest digest is invalid")
    return digest({"effective_prompt_sha256": effective_prompt_sha256,
                   "redacted_manifest_sha256": manifest_sha,
                   "skill_content_sha256": arm["skill_content_sha256"],
                   "skill_entrypoint_sha256": arm.get("skill_entrypoint_sha256"),
                   "prompt_template_sha256": arm["prompt_sha256"],
                   "adapter_sha256": arm["adapter_sha256"]})


def first_finding_wallclock(epoch: object, execution: Mapping[str, Any]) -> float | None:
    """Return actual elapsed time to the first required FINDING marker, if any."""
    try:
        epoch = float(epoch)
        started = dt.datetime.fromisoformat(str(execution["started_at"]).replace("Z", "+00:00")).timestamp()
    except (OSError, ValueError, KeyError, TypeError):
        return None
    elapsed = epoch - started
    return elapsed if math.isfinite(elapsed) and elapsed >= 0 else None




def _error_receipt(protocol: Mapping[str, Any], slot: Mapping[str, Any], source: Mapping[str, Any] | None, reason: str) -> dict[str, Any]:
    """Keep every scheduled failure visible without fabricating execution data."""
    configured = dict(protocol["limits"])
    observed = source.get("sha256") if isinstance(source, Mapping) else None
    host = str(slot["host"])
    return {
        "schema_version": 1, **{key: slot[key] for key in ("experiment_id", "host", "model", "case_id", "repetition", "limit_profile", "arm", "stage_block", "ordinal", "schedule_slot_sha256", "order_slot_sha256")},
        "schedule_sha256": protocol["schedule_sha256"], "execution_order_sha256": protocol["execution_order_sha256"], "evaluation_mode": protocol["evaluation_mode"], "effective_prompt_sha256": None, "effective_prompt_binding_sha256": None,
        "provenance": {"model_version": protocol["hosts"][host]["model_version"], **protocol["hosts"][host]["arms"][slot["arm"]]},
        "configured_limits": configured,
        "applied_limits": {**{key: None for key in configured}, "enforced": False, "reason": "not_started", "proof_execution_receipt_sha256": None},
        "source": {"expected_manifest_sha256": slot["source_manifest_sha256"], "observed_pre_manifest_sha256": observed, "observed_post_manifest_sha256": observed, "valid": observed == slot["source_manifest_sha256"]},
        "stage_lineage": {"block_id": slot["stage_block"], "stages": [], "stage_count": None, "role": "detect_only", "host": host, "model": slot["model"], "model_version": protocol["hosts"][host]["model_version"], "source_manifest_sha256": slot["source_manifest_sha256"], "deadline_epoch": None, "configured_total_limits": configured, "stage_prompt_template_sha256": {}, "proxy": {}}, "stage_receipts": [],
        "execution_receipt_sha256": None, "raw_response_sha256": None, "trusted_source_excerpts": [],
        "first_finding_wallclock_seconds": None, "lifecycle": "error", "result": "error", "reason_code": reason[:160],
        "usage": {"input_tokens": None, "output_tokens": None, "total_tokens": None, "cost_usd": None, "cost_source": "unknown", "provider": host, "wall_clock_seconds": None, "rate_table_version": None, "rate_table_sha256": None}, "accounting_state": "unknown", "limit_evidence": None,
    }


def _await_prestarted_profile(path: Path, wait_seconds: int) -> dict[str, Any]:
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if path.is_file() and not path.is_symlink():
            return read_json(path)
        time.sleep(0.1)
    raise HarnessError("prestarted_proxy_profile_not_ready")


def invoke_all(protocol: Mapping[str, Any], cases: list[Mapping[str, Any]], source_roots: Mapping[str, str], profiles_dir: Path, output_root: Path, profile_ready_wait_seconds: int) -> list[dict[str, Any]]:
    """Run every frozen order row once, preserving absent/error evidence.

    An external lifecycle operator starts one owned proxy and writes each
    ordinal profile just before its turn, then tears that proxy down afterward.
    This coordinator consumes those prestarted profiles; it never creates or
    tears down Docker resources. Each arm-level invocation needs a new proxy.
    """
    validate_protocol(protocol, frozen=True)
    if isinstance(profile_ready_wait_seconds, bool) or not isinstance(profile_ready_wait_seconds, int) or profile_ready_wait_seconds < 1:
        raise HarnessError("profile readiness wait must be a positive operator value")
    if not profiles_dir.is_absolute() or not profiles_dir.is_dir() or output_root.exists() or not output_root.parent.exists():
        raise HarnessError("invoke-all requires an external profile directory and new output directory")
    repetitions = protocol.get("repetitions")
    if isinstance(repetitions, bool) or not isinstance(repetitions, int) or repetitions < 1:
        raise HarnessError("frozen protocol repetitions is invalid")
    schedule = build_schedule(protocol, cases, repetitions)
    order = execution_order(protocol, schedule)
    if digest(schedule) != protocol["schedule_sha256"] or digest(order) != protocol["execution_order_sha256"]:
        raise HarnessError("protocol does not bind the supplied cases at k=3")
    roots: dict[str, Path] = {}
    for case_id, source in source_roots.items():
        if not isinstance(case_id, str) or not isinstance(source, str) or not Path(source).is_absolute():
            raise HarnessError("trusted source map must contain absolute paths")
        roots[case_id] = Path(source).resolve(strict=True)
    output_root.mkdir(mode=0o700)
    old_profile = os.environ.get("BENCH_TRUSTED_BENCHMARK_PROFILE")
    seen_proxy_ids: set[str] = set()
    receipts = []
    for slot in order:
        ordinal = slot["ordinal"]
        out = output_root / f"invocation-{ordinal:06d}"
        out.mkdir(mode=0o700)
        source_root = roots.get(str(slot["case_id"]))
        observed = None
        try:
            if source_root is None:
                raise HarnessError("trusted_source_root_missing")
            observed = source_manifest(source_root)
            profile_path = profiles_dir / f"{ordinal:06d}.json"
            profile = _await_prestarted_profile(profile_path, profile_ready_wait_seconds)
            proxy_id = profile.get("benchmark_profile", {}).get("proxy", {}).get("container_id") if isinstance(profile.get("benchmark_profile"), Mapping) else None
            if not isinstance(proxy_id, str) or proxy_id in seen_proxy_ids:
                raise HarnessError("per-slot trusted proxy identity missing or reused")
            seen_proxy_ids.add(proxy_id)
            os.environ["BENCH_TRUSTED_BENCHMARK_PROFILE"] = str(profile_path)
            case = next(item for item in cases if item.get("id") == slot["case_id"])
            receipt = invoke_slot(protocol, slot, case, source_root, out)
        except (HarnessError, OSError, StopIteration) as exc:
            receipt = _error_receipt(protocol, slot, observed, str(exc))
            write_once(out / "benchmark-invocation-receipt.json", receipt)
        receipts.append(receipt)
    if old_profile is None:
        os.environ.pop("BENCH_TRUSTED_BENCHMARK_PROFILE", None)
    else:
        os.environ["BENCH_TRUSTED_BENCHMARK_PROFILE"] = old_profile
    write_once(output_root / "benchmark-receipts.json", receipts)
    write_once(output_root / "coordinator-receipt.json", {"schema_version": 1, "schedule_sha256": protocol["schedule_sha256"], "execution_order_sha256": protocol["execution_order_sha256"], "receipt_sha256": digest(receipts), "expected_slots": len(order), "proxy_lifecycle": "external_prestarted_per_slot_profiles", "clock_sources": {"wall_clock_seconds": "trusted_execution_receipt_started_at_finished_at", "first_finding_wallclock_seconds": "adapter_FINDING_marker_unix_time"}})
    return receipts


def _external_regular_json(path: Path, label: str) -> dict[str, Any]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise HarnessError(f"{label} must be an absolute regular file")
    return read_json(path)


def _host_path(values: Mapping[str, Any], host: str, label: str) -> Path:
    value = values.get(host)
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise HarnessError(f"{label} must provide an absolute {host} path")
    return Path(value)


def _managed_run_id(experiment_id: str, ordinal: int) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "-", experiment_id).strip(".-")[:60] or "evaluation"
    return f"{cleaned}-{ordinal:06d}"


def _profile_from_proxy_receipt(template: Mapping[str, Any], receipt_path: Path, receipt: Mapping[str, Any], host: str, source_root: Path, source: Mapping[str, Any]) -> dict[str, Any]:
    """Bind static, external host policy fields to one observed proxy receipt."""
    execution, static = template.get("execution_policy"), template.get("benchmark_static")
    if not isinstance(execution, Mapping) or not isinstance(static, Mapping) or set(static) != {"analysis", "client", "arms"}:
        raise HarnessError("host policy template requires execution_policy and benchmark_static")
    proxy, internal, egress, upstream, limits = (receipt.get(key) for key in ("proxy", "internal_network", "egress_network", "upstream", "limits"))
    if receipt.get("schema_version") != 1 or receipt.get("owner") != "bench/lib/proxy.sh" or receipt.get("host") != host or not all(isinstance(value, Mapping) for value in (proxy, internal, egress, upstream, limits)):
        raise HarnessError("proxy start did not produce a valid host receipt")
    image = proxy.get("image_digest")
    if not isinstance(image, str) or not image.startswith("sha256:") or not _sha256(image[7:]):
        raise HarnessError("proxy receipt image identity is invalid")
    result = dict(execution)
    result.update({"target_root": str(source_root), "source_mount_mode": "archive-ro", "source_identity": dict(source), "network_mode": "approved-proxy-only",
                   "benchmark_profile": {"host": host, "proxy_receipt": {"path": str(receipt_path), "sha256": file_digest(receipt_path), "schema_version": 1, "owner": "bench/lib/proxy.sh"},
                                         "internal_network": dict(internal), "egress_network": dict(egress),
                                         "proxy": {"container_name": proxy.get("container_name"), "container_id": proxy.get("container_id"), "image_digest": image},
                                         "upstream": dict(upstream), "analysis": dict(static["analysis"]), "client": dict(static["client"]), "arms": dict(static["arms"]), "limits": dict(limits)}})
    return result


def _post_stop_limit_evidence(run_id: str, proxy_receipt_path: Path, invocation: Mapping[str, Any], proxy_results_dir: Path, proxy_receipts_dir: Path, stopped: bool) -> dict[str, Any]:
    """Seal post-stop proxy facts separately from the raw execution receipt.

    This record deliberately leaves live cap verification false until a trusted
    provider can prove drain and cumulative accounting from the sealed ledger.
    """
    proxy_receipt = _external_regular_json(proxy_receipt_path, "proxy receipt")
    usage_path = proxy_results_dir / run_id / "proxy-usage.json"
    usage: dict[str, Any] = {}
    if usage_path.is_file() and not usage_path.is_symlink():
        usage = read_json(usage_path)
    event_path = usage.get("event_log_path")
    event_sha = usage.get("event_log_sha256")
    event_ok = isinstance(event_path, str) and Path(event_path).is_absolute() and Path(event_path).is_file() and not Path(event_path).is_symlink() and isinstance(event_sha, str) and _sha256(event_sha) and file_digest(Path(event_path)) == event_sha
    proxy = proxy_receipt.get("proxy") if isinstance(proxy_receipt.get("proxy"), Mapping) else {}
    source = proxy_receipt.get("source_evidence") if isinstance(proxy_receipt.get("source_evidence"), Mapping) else {}
    evidence = {
        "schema_version": 1, "kind": "benchmark-limit-evidence", "owner": "bench/harness.py", "run_id": run_id,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
        "execution_receipt_sha256": invocation.get("execution_receipt_sha256"), "proxy_receipt_sha256": file_digest(proxy_receipt_path),
        "proxy_policy_sha256": (proxy_receipt.get("policy") or {}).get("sha256") if isinstance(proxy_receipt.get("policy"), Mapping) else None,
        "configured_limits": invocation.get("configured_limits"),
        "source_evidence": {"proxy_image_digest": proxy.get("image_digest"), "provider_proxy_sha256": source.get("provider_proxy_sha256"), "image_label_matches": source.get("image_label_matches") is True},
        "lifecycle": {"proxy_drained": False, "proxy_removed": stopped, "internal_network_removed": stopped, "egress_network_removed": stopped},
        "usage": {"event_log_path": event_path if event_ok else None, "event_log_sha256": event_sha if event_ok else None,
                  "event_count": usage.get("event_count"), "admitted_turns": usage.get("admitted_turns"), "rejected_requests": usage.get("rejected_requests"),
                  "input_tokens": usage.get("input_tokens"), "output_tokens": usage.get("output_tokens"), "budget_charged_usd": usage.get("budget_charged_usd"),
                  "budget_overshoot_usd": usage.get("budget_overshoot_usd"), "inflight_requests_at_stop": usage.get("inflight_requests_at_stop"),
                  "accounting_complete": usage.get("accounting_complete") is True and event_ok},
        "live_cap_verified": False, "reason": "live_cap_verification_unavailable",
    }
    path = proxy_receipts_dir / f"{run_id}.limit-evidence.json"
    write_once(path, evidence)
    return {"path": str(path), "sha256": file_digest(path), "schema_version": 1, "owner": "bench/harness.py"}


def invoke_all_managed(protocol: Mapping[str, Any], cases: list[Mapping[str, Any]], source_roots: Mapping[str, Any], templates: Mapping[str, Any], secrets: Mapping[str, Any], cap_documents: Mapping[str, Any], proxy_results_dir: Path, proxy_receipts_dir: Path, profile_dir: Path, output_root: Path) -> list[dict[str, Any]]:
    """Run the frozen order with one actual proxy start/invoke/stop lifecycle."""
    validate_protocol(protocol, frozen=True)
    for directory in (proxy_results_dir, proxy_receipts_dir, profile_dir):
        if not directory.is_absolute() or directory.is_symlink() or not directory.is_dir():
            raise HarnessError("managed lifecycle directories must be external and pre-created")
    if output_root.exists() or not output_root.parent.exists():
        raise HarnessError("managed lifecycle output root must be new")
    schedule = build_schedule(protocol, cases, protocol["repetitions"])
    order = execution_order(protocol, schedule)
    if digest(schedule) != protocol["schedule_sha256"] or digest(order) != protocol["execution_order_sha256"]:
        raise HarnessError("protocol does not bind this schedule")
    roots = {case_id: Path(value).resolve(strict=True) for case_id, value in source_roots.items() if isinstance(case_id, str) and isinstance(value, str) and Path(value).is_absolute()}
    if len(roots) != len(source_roots):
        raise HarnessError("trusted source map must contain absolute paths")
    output_root.mkdir(mode=0o700)
    old_profile, receipts, lifecycle, seen_proxy_ids = os.environ.get("BENCH_TRUSTED_BENCHMARK_PROFILE"), [], [], set()
    halt_reason, interrupted = "", None
    try:
        for slot in order:
            ordinal, host, out = slot["ordinal"], str(slot["host"]), output_root / f"invocation-{slot['ordinal']:06d}"
            out.mkdir(mode=0o700)
            source_root, observed, started, stopped, cleanup_pending, proxy_receipt_path = roots.get(str(slot["case_id"])), None, False, False, False, None
            run_id = _managed_run_id(str(protocol["experiment_id"]), ordinal)
            start_attempted = False
            receipt = _error_receipt(protocol, slot, None, "invocation_interrupted")
            proxy_receipt_path = proxy_receipts_dir / f"{run_id}.proxy-receipt.json"
            try:
                if halt_reason:
                    raise HarnessError(halt_reason)
                if source_root is None:
                    raise HarnessError("trusted_source_root_missing")
                observed = source_manifest(source_root)
                if observed["sha256"] != slot["source_manifest_sha256"]:
                    raise HarnessError("source pre-manifest does not match scheduled slot")
                secret, cap, template_path = (_host_path(secrets, host, "proxy secrets"), _host_path(cap_documents, host, "approved cap documents"), _host_path(templates, host, "host templates"))
                proxy_env = {**os.environ, "BENCH_RESULTS_DIR": str(proxy_results_dir), "BENCH_PROXY_RECEIPTS_DIR": str(proxy_receipts_dir)}
                start_attempted = True
                subprocess.run([str(ROOT / "bench/lib/proxy.sh"), "start", run_id, host, str(secret), str(cap)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=proxy_env)
                started = True
                proxy_receipt_path = proxy_receipts_dir / f"{run_id}.proxy-receipt.json"
                proxy_receipt = _external_regular_json(proxy_receipt_path, "actual proxy receipt")
                proxy_id = proxy_receipt.get("proxy", {}).get("container_id") if isinstance(proxy_receipt.get("proxy"), Mapping) else None
                if not isinstance(proxy_id, str) or proxy_id in seen_proxy_ids:
                    raise HarnessError("managed proxy identity is missing or reused")
                seen_proxy_ids.add(proxy_id)
                profile_path = profile_dir / f"{ordinal:06d}.json"
                if profile_path.exists():
                    raise HarnessError("materialized profile already exists")
                profile = _profile_from_proxy_receipt(_external_regular_json(template_path, "host policy template"), proxy_receipt_path, proxy_receipt, host, source_root, observed)
                write_once(profile_path, profile)
                os.environ["BENCH_TRUSTED_BENCHMARK_PROFILE"] = str(profile_path)
                case = next(item for item in cases if item.get("id") == slot["case_id"])
                receipt = invoke_slot(protocol, slot, case, source_root, out, finalize=False)
            except Exception as exc:
                receipt = _error_receipt(protocol, slot, observed, str(exc))
            except (KeyboardInterrupt, SystemExit) as exc:
                interrupted, halt_reason = exc, "coordinator_interrupted"
            finally:
                if start_attempted and proxy_receipt_path.is_file():
                    try:
                        subprocess.run([str(ROOT / "bench/lib/proxy.sh"), "stop", run_id], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env={**os.environ, "BENCH_RESULTS_DIR": str(proxy_results_dir), "BENCH_PROXY_RECEIPTS_DIR": str(proxy_receipts_dir)})
                        stopped = True
                    except (OSError, subprocess.SubprocessError):
                        cleanup_pending = True
                elif start_attempted:
                    # Startup can fail after creating resources but before sealing
                    # their ownership receipt. Preserve uncertainty and stop work.
                    cleanup_pending = True
                if started and proxy_receipt_path is not None and proxy_receipt_path.is_file():
                    try:
                        receipt["limit_evidence"] = _post_stop_limit_evidence(run_id, proxy_receipt_path, receipt, proxy_results_dir, proxy_receipts_dir, stopped)
                    except (HarnessError, OSError):
                        receipt["limit_evidence"] = None
                        cleanup_pending = True
                write_once(out / "benchmark-invocation-receipt.json", receipt)
                receipts.append(receipt)
                lifecycle.append({"ordinal": ordinal, "run_id": run_id, "started": started, "stopped": stopped, "cleanup_pending": cleanup_pending})
                if cleanup_pending:
                    halt_reason = "prior_proxy_cleanup_pending"
    finally:
        if old_profile is None:
            os.environ.pop("BENCH_TRUSTED_BENCHMARK_PROFILE", None)
        else:
            os.environ["BENCH_TRUSTED_BENCHMARK_PROFILE"] = old_profile
    write_once(output_root / "benchmark-receipts.json", receipts)
    write_once(output_root / "coordinator-receipt.json", {"schema_version": 1, "schedule_sha256": protocol["schedule_sha256"], "execution_order_sha256": protocol["execution_order_sha256"], "receipt_sha256": digest(receipts), "expected_slots": len(order), "proxy_lifecycle": lifecycle, "cleanup_pending_ordinals": [record["ordinal"] for record in lifecycle if record["cleanup_pending"]], "clock_sources": {"wall_clock_seconds": "trusted_execution_receipt_started_at_finished_at", "first_finding_wallclock_seconds": "adapter_FINDING_marker_unix_time"}})
    if interrupted is not None:
        raise interrupted
    return receipts


def dry_run(protocol: Mapping[str, Any], cases: list[Mapping[str, Any]], repetitions: int) -> dict[str, Any]:
    frozen = freeze_documents(protocol, cases, repetitions)
    return {"schema_version": 1, "protocol_sha256": digest(frozen["protocol"]), "schedule_sha256": frozen["protocol"]["schedule_sha256"], "execution_order_sha256": frozen["protocol"]["execution_order_sha256"], "expected_slots": len(frozen["execution_order"]), "preflight_reasons": preflight(frozen["protocol"]), **frozen}


def main() -> int:
    parser = argparse.ArgumentParser(description="Bugsweep WU6 benchmark coordinator")
    parser.add_argument("--protocol", type=Path, required=True)
    parser.add_argument("--cases", type=Path, required=True, help="redacted case manifest JSON array")
    parser.add_argument("-k", type=int, default=3)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--freeze-dir", type=Path, help="new directory for frozen protocol, schedule, and execution order")
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--invoke-slot", type=Path)
    parser.add_argument("--invoke-all", action="store_true")
    parser.add_argument("--invoke-all-prestarted", action="store_true", help="diagnostic consumer for externally prestarted profiles")
    parser.add_argument("--trusted-source-map", type=Path, help="external JSON mapping case ids to frozen source roots")
    parser.add_argument("--host-policy-templates", type=Path, help="external JSON mapping host to policy-template path")
    parser.add_argument("--proxy-secret-files", type=Path, help="external JSON mapping host to 0600 secret path")
    parser.add_argument("--approved-cap-documents", type=Path, help="external JSON mapping host to approved cap document")
    parser.add_argument("--proxy-results-dir", type=Path)
    parser.add_argument("--proxy-receipts-dir", type=Path)
    parser.add_argument("--materialized-profile-dir", type=Path)
    parser.add_argument("--profiles-dir", type=Path, help="external trusted profile files named 000001.json, etc.")
    parser.add_argument("--profile-ready-wait-seconds", type=int, help="operator-approved wait for each externally prestarted profile")
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--output-root", type=Path)
    args = parser.parse_args()
    protocol = read_protocol(args.protocol)
    try:
        cases = json.loads(args.cases.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HarnessError("redacted case manifest must be JSON") from exc
    if not isinstance(cases, list) or not all(isinstance(case, Mapping) for case in cases):
        raise HarnessError("redacted case manifest must be an array")
    for case in cases:
        redacted_case(case)
    if args.freeze_dir:
        if args.freeze_dir.exists() or not args.freeze_dir.parent.exists():
            raise HarnessError("--freeze-dir must be a new directory under an existing parent")
        frozen = freeze_documents(protocol, list(cases), args.k)
        args.freeze_dir.mkdir(mode=0o700)
        write_once(args.freeze_dir / "evaluation-protocol.json", frozen["protocol"])
        write_once(args.freeze_dir / "schedule.json", frozen["schedule"])
        write_once(args.freeze_dir / "execution-order.json", frozen["execution_order"])
        print(canonical({"protocol_sha256": digest(frozen["protocol"]), "schedule_sha256": frozen["protocol"]["schedule_sha256"], "execution_order_sha256": frozen["protocol"]["execution_order_sha256"], "directory": str(args.freeze_dir)}).decode())
        return 0
    if args.preflight:
        print(canonical({"ok": not preflight(protocol), "reasons": preflight(protocol)}).decode())
        return 0 if not preflight(protocol) else 10
    if args.dry_run:
        print(canonical(dry_run(protocol, list(cases), args.k)).decode())
        return 0
    if args.invoke_slot:
        if not args.source_root or not args.output_dir:
            raise HarnessError("--invoke-slot requires --source-root and --output-dir")
        slot = read_json(args.invoke_slot)
        matching = [case for case in cases if case.get("id") == slot.get("case_id")]
        if len(matching) != 1:
            raise HarnessError("slot does not identify exactly one redacted case")
        print(canonical(invoke_slot(protocol, slot, matching[0], args.source_root, args.output_dir)).decode())
        return 0
    if args.invoke_all:
        required = (args.trusted_source_map, args.host_policy_templates, args.proxy_secret_files, args.approved_cap_documents, args.proxy_results_dir, args.proxy_receipts_dir, args.materialized_profile_dir, args.output_root)
        if not all(required):
            raise HarnessError("--invoke-all requires source map, host templates, secret/cap mappings, proxy directories, materialized profile directory, and output root")
        receipts = invoke_all_managed(protocol, list(cases), read_json(args.trusted_source_map), read_json(args.host_policy_templates), read_json(args.proxy_secret_files), read_json(args.approved_cap_documents), args.proxy_results_dir, args.proxy_receipts_dir, args.materialized_profile_dir, args.output_root)
        print(canonical({"expected_slots": len(receipts), "receipt_sha256": digest(receipts), "output_root": str(args.output_root)}).decode())
        return 0
    if args.invoke_all_prestarted:
        if not args.trusted_source_map or not args.profiles_dir or not args.output_root or args.profile_ready_wait_seconds is None:
            raise HarnessError("--invoke-all requires --trusted-source-map, --profiles-dir, --output-root, and --profile-ready-wait-seconds")
        source_roots = read_json(args.trusted_source_map)
        receipts = invoke_all(protocol, list(cases), source_roots, args.profiles_dir, args.output_root, args.profile_ready_wait_seconds)
        print(canonical({"expected_slots": len(receipts), "receipt_sha256": digest(receipts), "output_root": str(args.output_root)}).decode())
        return 0
    raise HarnessError("live evaluation is disabled until the trusted execution provider exposes approved-proxy-only")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessError as exc:
        print(f"benchmark: {exc}", file=sys.stderr)
        raise SystemExit(2)
