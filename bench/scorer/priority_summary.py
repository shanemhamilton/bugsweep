"""Deterministic reporting view for Bugsweep's priority intelligence."""

from __future__ import annotations

from typing import Any, Mapping, Sequence

from .priority_context import LANE_RANK, REASON_CODES, sanitize_text

OUTCOME_EVENTS = {"fix_committed", "quarantine", "confirmed", "false_positive"}


def _integer(value: object, *, low: int = 0, high: int = 1_000_000) -> int:
    if isinstance(value, bool):
        return low
    try:
        parsed = int(str(value))
    except (TypeError, ValueError):
        return low
    return max(low, min(high, parsed))


def _reason_codes(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return sorted({item for item in value[:20] if isinstance(item, str) and item in REASON_CODES})


def _rate(value: object) -> float:
    try:
        parsed = float(str(value))
    except (TypeError, ValueError):
        return 0.0
    return max(0.0, min(1.0, parsed))


def _batch_map(recon: Mapping[str, Any]) -> dict[str, int]:
    result: dict[str, int] = {}
    raw_batches = recon.get("batches")
    if not isinstance(raw_batches, list):
        return result
    for batch in raw_batches:
        if not isinstance(batch, Mapping):
            continue
        batch_id = batch.get("id")
        files = batch.get("files")
        if (
            not isinstance(batch_id, int)
            or isinstance(batch_id, bool)
            or batch_id < 1
            or not isinstance(files, list)
        ):
            continue
        for path in files:
            if isinstance(path, str):
                result.setdefault(path, batch_id)
    return result


def _application(value: Mapping[str, Any]) -> tuple[dict[str, Any], str | None]:
    empty = {
        "candidate_count": 0,
        "promoted_batches": [],
        "promoted_batch_count": 0,
        "added_file_count": 0,
        "already_in_budget_count": 0,
        "skipped_candidate_count": 0,
    }
    if not value:
        return empty, "priority_application_missing"

    promoted = value.get("promoted_batches")
    skipped = value.get("skipped_candidates")
    already = value.get("already_in_budget_candidates")
    candidate_count = value.get("candidate_count")
    promoted_count = value.get("promoted_batch_count")
    added_file_count = value.get("added_file_count")
    valid = (
        value.get("schema_version") == 1
        and value.get("scope_contract") == "priority_only_whole_repo_remains_in_scope"
        and isinstance(candidate_count, int)
        and not isinstance(candidate_count, bool)
        and 0 <= candidate_count <= 200
        and isinstance(promoted, list)
        and len(promoted) <= 20
        and all(isinstance(item, str) and 0 < len(item) <= 80 for item in promoted)
        and len(set(promoted)) == len(promoted)
        and isinstance(promoted_count, int)
        and not isinstance(promoted_count, bool)
        and promoted_count == len(promoted)
        and isinstance(added_file_count, int)
        and not isinstance(added_file_count, bool)
        and 0 <= added_file_count <= 1_000
        and isinstance(already, list)
        and len(already) <= 200
        and all(isinstance(item, str) for item in already)
        and len(set(already)) == len(already)
        and isinstance(skipped, list)
        and len(skipped) <= 200
        and all(
            isinstance(item, Mapping)
            and isinstance(item.get("file"), str)
            and item.get("reason") in {"outside_recon", "budget_limited"}
            for item in skipped
        )
    )
    if not valid:
        return empty, "priority_application_invalid"
    assert isinstance(promoted, list)
    assert isinstance(promoted_count, int)
    assert isinstance(added_file_count, int)
    assert isinstance(candidate_count, int)
    assert isinstance(already, list)
    assert isinstance(skipped, list)

    return (
        {
            "candidate_count": candidate_count,
            "promoted_batches": list(promoted),
            "promoted_batch_count": promoted_count,
            "added_file_count": added_file_count,
            "already_in_budget_count": len(already),
            "skipped_candidate_count": len(skipped),
        },
        None,
    )


def build_priority_summary(
    *,
    context: Mapping[str, Any],
    application: Mapping[str, Any],
    events: Sequence[Mapping[str, Any]],
    recon: Mapping[str, Any],
    verified_covered_ids: set[int],
) -> dict[str, Any]:
    """Build a bounded, attribution-aware priority report object."""

    if not context:
        degraded_reason: str | None = "priority_context_missing"
    elif context.get("degraded") is True:
        raw_status = context.get("source_status")
        status = raw_status if isinstance(raw_status, Mapping) else {}
        degraded_reason = sanitize_text(status.get("collector") or "priority_context_degraded", 80)
    elif context.get("schema_version") != 1 or context.get("scope_contract") != (
        "priority_only_whole_repo_remains_in_scope"
    ):
        degraded_reason = "priority_context_invalid"
    else:
        degraded_reason = None

    project = context.get("project_signals")
    project = project if isinstance(project, Mapping) else {}
    raw_health = project.get("signal_health")
    raw_health = raw_health if isinstance(raw_health, Mapping) else {}
    health = {
        key: _integer(raw_health.get(key))
        for key in ("accepted", "expired", "inactive", "malformed", "unmapped", "overmatched")
    }

    by_file: dict[str, list[Mapping[str, Any]]] = {}
    for event in events:
        path = event.get("file")
        if isinstance(path, str):
            by_file.setdefault(path, []).append(event)
    file_batches = _batch_map(recon)

    top_targets: list[dict[str, Any]] = []
    raw_targets = context.get("targets")
    if isinstance(raw_targets, list):
        for target in raw_targets[:10]:
            if not isinstance(target, Mapping) or not isinstance(target.get("file"), str):
                continue
            path = str(target["file"])
            codes = _reason_codes(target.get("attribution_reason_codes"))
            file_events = by_file.get(path, [])
            confirmed_codes = {
                code
                for event in file_events
                if event.get("event") in {"fix_committed", "quarantine", "confirmed"}
                for code in _reason_codes(event.get("priority_reason_codes"))
            }
            rejected_codes = {
                code
                for event in file_events
                if event.get("event") == "false_positive"
                for code in _reason_codes(event.get("priority_reason_codes"))
            }
            has_outcome = any(event.get("event") in OUTCOME_EVENTS for event in file_events)
            investigated = file_batches.get(path) in verified_covered_ids or bool(
                confirmed_codes or rejected_codes
            )
            if confirmed_codes.intersection(codes):
                outcome = "confirmed"
            elif rejected_codes.intersection(codes):
                outcome = "rejected"
            elif investigated and has_outcome:
                outcome = "unattributed"
            elif investigated:
                outcome = "no_finding"
            else:
                outcome = "not_reviewed"
            lane = str(target.get("lane") or "normal")
            if lane not in LANE_RANK:
                lane = "normal"
            top_targets.append(
                {
                    "file": path,
                    "lane": lane,
                    "priority_score": _integer(target.get("priority_score"), high=100),
                    "reason_codes": codes,
                    "investigated": investigated,
                    "outcome": outcome,
                }
            )

    unmapped: list[dict[str, Any]] = []
    raw_unmapped = project.get("unmapped_focus_signals")
    if isinstance(raw_unmapped, list):
        for item in raw_unmapped[:10]:
            if not isinstance(item, Mapping):
                continue
            unmapped.append(
                {
                    key: str(item.get(key) or "")[:80]
                    for key in ("id", "source", "kind", "severity", "component", "flow")
                }
            )

    yields: list[dict[str, Any]] = []
    raw_yields = project.get("signal_yield")
    if isinstance(raw_yields, list):
        for item in raw_yields[:50]:
            if not isinstance(item, Mapping) or not isinstance(item.get("reason"), str):
                continue
            reason = str(item["reason"])
            if reason not in REASON_CODES:
                continue
            yields.append(
                {
                    "reason": reason,
                    **{
                        key: _integer(item.get(key))
                        for key in (
                            "observed",
                            "investigated",
                            "attributed",
                            "confirmed",
                            "rejected",
                            "no_finding",
                            "unattributed",
                        )
                    },
                    "confirmation_rate": _rate(item.get("confirmation_rate")),
                }
            )

    application_summary, application_reason = _application(application)
    return {
        "available": degraded_reason is None,
        "degraded_reason": degraded_reason,
        "application_available": application_reason is None,
        "application_reason": application_reason,
        "top_targets": top_targets,
        "signal_health": health,
        "unmapped_focus_signals": unmapped,
        "signal_yield": yields,
        "application": application_summary,
    }
