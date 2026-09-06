"""Frozen, prompt-level detect-only pipeline interventions."""
from __future__ import annotations

import json
from pathlib import PurePosixPath
from typing import Any, Mapping, Sequence


STAGES = ("hunter", "skeptic", "referee", "synthesis")


def normalize_stage_blocks(value: object) -> tuple[dict[str, Any], ...]:
    if not isinstance(value, list) or not value:
        raise ValueError("pipeline-stage ablation blocks are required")
    blocks: list[dict[str, Any]] = []
    ids: set[str] = set()
    lineages: set[tuple[str, ...]] = set()
    for block in value:
        if not isinstance(block, Mapping) or set(block) != {"id", "stages"}:
            raise ValueError("stage block must contain only id and stages")
        identifier, stages = block["id"], block["stages"]
        if (not isinstance(identifier, str) or not identifier
                or not isinstance(stages, list) or not stages
                or any(stage not in STAGES for stage in stages)
                or stages != sorted(set(stages), key=STAGES.index)
                or stages[0] != "hunter"):
            raise ValueError("invalid stage block")
        lineage = tuple(stages)
        if identifier in ids or lineage in lineages:
            raise ValueError("stage blocks must have independent ids and lineages")
        ids.add(identifier)
        lineages.add(lineage)
        blocks.append({"id": identifier, "stages": list(lineage)})
    if not any(block["id"] == "full_pipeline" and tuple(block["stages"]) == STAGES for block in blocks):
        raise ValueError("stage blocks require the full Hunter/Skeptic/Referee/Synthesis control")
    for block in blocks:
        stages = tuple(block["stages"])
        if stages != ("hunter",) and stages[-1] != "synthesis":
            raise ValueError("non-Hunter ablations must end in synthesis")
    return tuple(blocks)


def _hunter_claims(candidates: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    return [{key: candidate[key] for key in ("bug_id", "file", "location", "line", "rationale", "trigger")}
            for candidate in candidates]


def stage_input(stage: str, assessments: Mapping[str, Sequence[Mapping[str, Any]]]) -> dict[str, Any]:
    """Return the one frozen handoff shape shared by runner and importer."""
    hunter = assessments.get("hunter", ())
    if stage in {"hunter", "skeptic", "referee"}:
        return {"hunter_candidate_claims": _hunter_claims(hunter)}
    if stage == "synthesis":
        return {"hunter_candidate_claims": _hunter_claims(hunter),
                "skeptic_assessment": {"candidates": list(assessments.get("skeptic", ()))},
                "referee_assessment": {"candidates": list(assessments.get("referee", ()))} }
    raise ValueError("unsupported stage")


def stage_prompt(stage: str, *, assessments: Mapping[str, Sequence[Mapping[str, Any]]] | None = None) -> str:
    """One fresh native stage request; prior verdicts never enter Referee input."""
    if stage not in STAGES:
        raise ValueError("unsupported stage")
    contract = ('Return exactly one JSON object {"candidates": [...]} and nothing else. Each candidate needs string bug_id, file, location, rationale, trigger; integer line >= 1; severity critical/high/medium/low; status confirmed/rejected. '
                'Do not invent stage votes, labels, sessions, counts, or evidence.')
    if stage == "hunter":
        return "STAGE: Hunter. Find source-supported candidate bugs in the mounted archive. " + contract
    candidate_input = json.dumps(stage_input(stage, assessments or {}), sort_keys=True, separators=(",", ":"))
    if stage == "skeptic":
        return ("STAGE: Skeptic. Independently test every Hunter claim against source. Return every supplied bug_id and location exactly once with confirmed or rejected status; do not report a vote or confidence. "
                + contract + "\nHunter claims:\n" + candidate_input)
    if stage == "referee":
        return ("STAGE: Referee. Independently adjudicate every Hunter claim against source. Skeptic verdicts and confidence are deliberately withheld. Return every supplied bug_id and location exactly once with confirmed or rejected status. "
                + contract + "\nHunter claims:\n" + candidate_input)
    return ("STAGE: Synthesis. Reconcile the preserved Hunter claims and independent Skeptic and Referee assessments. Return every supplied Hunter bug_id and location exactly once with confirmed or rejected status. An omitted role has no assessment and is not a rejection. This native response is the final determination; do not report votes. "
            + contract + "\nStage handoff:\n" + candidate_input)


def validate_stage_candidates(stage: str, candidates: Sequence[Mapping[str, Any]], assessments: Mapping[str, Sequence[Mapping[str, Any]]]) -> None:
    """Every post-Hunter role must explicitly audit each original claim."""
    if stage == "hunter":
        return
    expected = {item["bug_id"]: (item["file"], item["location"], item["line"])
                for item in assessments.get("hunter", ())}
    actual = {item["bug_id"]: (item["file"], item["location"], item["line"])
              for item in candidates}
    if actual != expected:
        raise ValueError("stage response must preserve every Hunter candidate id and location")


def parse_candidates(text: object) -> list[dict[str, Any]]:
    """Strict native candidate JSON; invalid stage output is unverified."""
    from scripts._review_evidence import _loads

    try:
        value = _loads(text) if isinstance(text, str) else None
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid candidate JSON") from exc
    if not isinstance(value, dict) or set(value) != {"candidates"} or not isinstance(value["candidates"], list) or len(value["candidates"]) > 1000:
        raise ValueError("invalid candidate response")
    candidates: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in value["candidates"]:
        if not isinstance(item, Mapping):
            raise ValueError("invalid candidate contract")
        path = PurePosixPath(str(item.get("file", "")))
        if (any(not isinstance(item.get(key), str) or not item[key].strip() or len(item[key].encode()) > 8192 for key in ("bug_id", "file", "location", "rationale", "trigger"))
                or item["bug_id"] in seen or item.get("severity") not in {"critical", "high", "medium", "low"}
                or item.get("status") not in {"confirmed", "rejected"} or type(item.get("line")) is not int or item["line"] < 1
                or path.is_absolute() or ".." in path.parts or "\\" in item["file"]
                or str(path) != item["file"] or item["location"] != f"{path}:{item['line']}"):
            raise ValueError("invalid candidate contract")
        seen.add(item["bug_id"])
        candidates.append(dict(item))
    return candidates
