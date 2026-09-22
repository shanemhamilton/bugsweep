"""Deterministic blinded human-review sampling and conservative summaries."""

from __future__ import annotations

import hashlib
import json
import math
import random
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

STRATUM_FIELDS = ("host", "arm", "category", "severity", "status")
VALID_LABELS = frozenset({"real", "false", "unverifiable"})


def _finite_nonnegative(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value)) and value >= 0


def _canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def _stratum(row: Mapping[str, Any]) -> tuple[str, ...]:
    return tuple(str(row.get(field, "")) for field in STRATUM_FIELDS)


def _frame_identity(frame: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            **{field: row.get(field) for field in ("candidate_id", "experiment_id", "case_id", "repository", *STRATUM_FIELDS)},
            # Reviewers decide from evidence.  Freezing only candidate metadata
            # would permit that evidence to be swapped after sampling.
            "evidence": row.get("evidence"),
        }
        for row in sorted(frame, key=lambda item: str(item.get("candidate_id", "")))
    ]


def freeze_sample(frame: Sequence[Mapping[str, Any]], *, seed: int, minimum: int = 60) -> dict[str, Any]:
    """Freeze a representative seeded sample with inclusion probabilities."""
    rows = sorted((dict(item) for item in frame), key=lambda item: str(item.get("candidate_id", "")))
    ids = [str(row.get("candidate_id", "")) for row in rows]
    if not all(ids) or len(set(ids)) != len(ids):
        raise ValueError("frame candidate_id values must be unique and nonempty")
    grouped: dict[tuple[str, ...], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[_stratum(row)].append(row)
    target = len(rows) if len(rows) <= minimum else min(len(rows), max(minimum, len(grouped)))
    allocations = {key: 1 for key in grouped}
    remaining = target - len(grouped)
    ranked = sorted(grouped, key=lambda key: (-len(grouped[key]), key))
    while remaining > 0:
        progressed = False
        for key in ranked:
            if allocations[key] < len(grouped[key]):
                allocations[key] += 1
                remaining -= 1
                progressed = True
                if not remaining:
                    break
        if not progressed:
            break
    selected: list[str] = []
    strata: list[dict[str, Any]] = []
    for key in sorted(grouped):
        population = sorted(grouped[key], key=lambda item: str(item["candidate_id"]))
        draw = random.Random(f"{seed}:{'|'.join(key)}").sample(population, allocations[key])
        chosen = sorted(str(item["candidate_id"]) for item in draw)
        selected.extend(chosen)
        strata.append({
            "key": dict(zip(STRATUM_FIELDS, key)), "population_n": len(population),
            "sampled_n": len(chosen), "inclusion_probability": len(chosen) / len(population),
            "candidate_ids": chosen,
        })
    frame_identity = _frame_identity(rows)
    return {
        "schema_version": 1, "seed": seed, "minimum": minimum, "frame_sha256": hashlib.sha256(_canonical(frame_identity).encode()).hexdigest(),
        "population_n": len(rows), "sampled_candidate_ids": sorted(selected), "strata": strata,
    }


def _validate_frozen_selection(frame: Sequence[Mapping[str, Any]], frozen: Mapping[str, Any]) -> None:
    """A frame digest alone does not bind which deterministic draw was selected."""
    if isinstance(frozen.get("seed"), bool) or not isinstance(frozen.get("seed"), int) or isinstance(frozen.get("minimum"), bool) or not isinstance(frozen.get("minimum"), int) or frozen["minimum"] < 1:
        raise ValueError("frozen sampling parameters are invalid")
    expected = freeze_sample(frame, seed=frozen["seed"], minimum=frozen["minimum"])
    if dict(frozen) != expected:
        raise ValueError("frozen selection does not match deterministic sample")


def build_blinded_packets(frame: Sequence[Mapping[str, Any]], frozen: Mapping[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Export source/trigger/repro uniformly while separating the unblinding map."""
    selected = set(frozen.get("sampled_candidate_ids", []))
    if frozen.get("frame_sha256") != hashlib.sha256(_canonical(_frame_identity(frame)).encode()).hexdigest():
        raise ValueError("frame no longer matches frozen sample")
    _validate_frozen_selection(frame, frozen)
    by_id = {str(row.get("candidate_id")): row for row in frame}
    if selected - set(by_id):
        raise ValueError("sample references candidates absent from frame")
    probabilities = {candidate: row["inclusion_probability"] for row in frozen.get("strata", []) for candidate in row.get("candidate_ids", [])}
    if set(probabilities) != selected or any(not isinstance(value, (int, float)) or value <= 0 or value > 1 for value in probabilities.values()):
        raise ValueError("frozen inclusion map is incomplete")
    packets: list[dict[str, Any]] = []
    unblinding: list[dict[str, Any]] = []
    for ordinal, candidate_id in enumerate(sorted(selected), 1):
        row = by_id[candidate_id]
        evidence = row.get("evidence") if isinstance(row.get("evidence"), Mapping) else {}
        source = evidence.get("source") if isinstance(evidence.get("source"), Mapping) else None
        packets.append({
            "review_id": f"review-{ordinal:04d}", "frame_sha256": frozen["frame_sha256"],
            "evidence": {
                "source": source.get("excerpt", "unavailable") if source else "unavailable",
                "source_identity": {field: source.get(field) for field in ("path", "sha256", "excerpt_start", "excerpt_end")} if source else None,
                "claim": evidence.get("claim", "unavailable"),
                "trigger": evidence.get("trigger", "unavailable"),
                "repro": evidence.get("repro", "unavailable"),
            },
        })
        unblinding.append({"review_id": f"review-{ordinal:04d}", "candidate_id": candidate_id, "inclusion_probability": probabilities[candidate_id]})
    return packets, unblinding


def resolve_labels(packets: Sequence[Mapping[str, Any]], labels: Iterable[Mapping[str, Any]], adjudications: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Resolve only two independent matching labels or a distinct adjudicator."""
    packet_ids = {str(packet.get("review_id")) for packet in packets}
    grouped: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for row in labels:
        review_id, reviewer, label = row.get("review_id"), row.get("reviewer_id"), row.get("label")
        if review_id not in packet_ids or not isinstance(reviewer, str) or not reviewer.strip() or row.get("role") != "primary" or label not in VALID_LABELS or not _finite_nonnegative(row.get("seconds")) or row["seconds"] <= 0 or not isinstance(row.get("reason"), str) or not row["reason"].strip():
            raise ValueError("invalid human label")
        if len(grouped[review_id]) >= 2 or any(str(old.get("reviewer_id")) == reviewer for old in grouped[review_id]):
            raise ValueError("duplicate reviewer label")
        grouped[review_id].append(row)
    adjudicated: dict[str, Mapping[str, Any]] = {}
    for row in adjudications:
        review_id = str(row.get("review_id", ""))
        votes = grouped.get(review_id, [])
        disagree = len(votes) == 2 and (votes[0]["label"] != votes[1]["label"] or "unverifiable" in {votes[0]["label"], votes[1]["label"]})
        if review_id not in packet_ids or not disagree or row.get("role") != "adjudicator" or row.get("label") not in VALID_LABELS or not _finite_nonnegative(row.get("seconds")) or row["seconds"] <= 0 or not isinstance(row.get("reason"), str) or not row["reason"].strip() or not isinstance(row.get("reviewer_id"), str) or not row["reviewer_id"].strip() or row["reviewer_id"] in {v.get("reviewer_id") for v in votes}:
            raise ValueError("invalid adjudication")
        if review_id in adjudicated:
            raise ValueError("duplicate adjudication")
        adjudicated[review_id] = row
    result: list[dict[str, Any]] = []
    for packet in packets:
        review_id = str(packet["review_id"])
        votes = grouped[review_id]
        final = adjudicated.get(review_id)
        disagreement = len(votes) == 2 and (votes[0]["label"] != votes[1]["label"] or "unverifiable" in {votes[0]["label"], votes[1]["label"]})
        if final:
            label, status = final["label"], "adjudicated"
        elif len(votes) == 2 and votes[0]["label"] == votes[1]["label"] and votes[0]["label"] != "unverifiable":
            label, status = votes[0]["label"], "agreed"
        else:
            label, status = None, "unresolved"
        result.append({"review_id": review_id, "label": label, "status": status, "primary_reviewer_count": len(votes), "review_seconds": sum(float(v["seconds"]) for v in votes) + (float(final["seconds"]) if final else 0.0), "genuine_disagreement": disagreement})
    return result


def weighted_rate(rows: Sequence[Mapping[str, Any]], *, positive: str = "real") -> dict[str, float | None]:
    """Population-weighted estimate with unresolved lower/upper sensitivity."""
    weights = [1 / float(row["inclusion_probability"]) for row in rows if float(row.get("inclusion_probability", 0)) > 0]
    if len(weights) != len(rows) or not weights:
        return {"estimate": None, "lower": None, "upper": None}
    total = sum(weights)
    lower = sum(weight for row, weight in zip(rows, weights) if row.get("label") == positive) / total
    upper = sum(weight for row, weight in zip(rows, weights) if row.get("label") in {positive, None}) / total
    return {"estimate": lower if lower == upper else None, "lower": lower, "upper": upper}


def _weighted_median(values: Sequence[tuple[float, float]]) -> float | None:
    """Return the inclusion-weighted median review time."""
    if not values or any(not _finite_nonnegative(value) or weight <= 0 or not math.isfinite(weight) for value, weight in values):
        return None
    total = sum(weight for _, weight in values)
    running = 0.0
    for value, weight in sorted(values):
        running += weight
        if running >= total / 2:
            return value
    return None


def cluster_bootstrap_interval(rows: Sequence[Mapping[str, Any]], *, seed: int, positive: str = "real", repetitions: int = 1000) -> dict[str, float | None]:
    """Stratified, paired case/repository bootstrap preserving unresolved bounds."""
    eligible = [row for row in rows if float(row.get("inclusion_probability", 0)) > 0]
    if not eligible or repetitions < 1:
        return {"low": None, "high": None, "sensitivity_low": None, "sensitivity_high": None, "clusters": 0}
    # Draw within strata so each sampled stratum remains represented.  The same
    # case/repository draw is reused for strata with the same cluster universe,
    # preserving arm comparisons without letting a large stratum erase a small
    # one.  This is also deterministic across a frozen frame.
    grouped: dict[tuple[str, ...], dict[tuple[str, str], list[Mapping[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for row in eligible:
        grouped[_stratum(row)][(str(row.get("case_id", "")), str(row.get("repository", "")))].append(row)
    cluster_ids = {cluster_id for by_cluster in grouped.values() for cluster_id in by_cluster}
    if len(cluster_ids) < 2:
        return {"low": None, "high": None, "sensitivity_low": None, "sensitivity_high": None, "clusters": len(cluster_ids)}
    lowers: list[float] = []
    uppers: list[float] = []
    for replicate in range(repetitions):
        draws_by_universe: dict[tuple[tuple[str, str], ...], list[tuple[str, str]]] = {}
        sampled: list[Mapping[str, Any]] = []
        for stratum in sorted(grouped):
            by_cluster = grouped[stratum]
            universe = tuple(sorted(by_cluster))
            draw = draws_by_universe.get(universe)
            if draw is None:
                rng = random.Random(f"{seed}:{replicate}:{universe}")
                draw = [rng.choice(universe) for _ in universe]
                draws_by_universe[universe] = draw
            for cluster_id in draw:
                sampled.extend(by_cluster[cluster_id])
        bounds = weighted_rate(sampled, positive=positive)
        if bounds["lower"] is not None:
            lowers.append(bounds["lower"])
            uppers.append(bounds["upper"])
    if not lowers:
        return {"low": None, "high": None, "sensitivity_low": None, "sensitivity_high": None, "clusters": len(cluster_ids)}
    lowers.sort()
    uppers.sort()
    return {
        "low": lowers[max(0, int(.025 * (len(lowers) - 1)))],
        "high": lowers[min(len(lowers) - 1, int(.975 * (len(lowers) - 1)))],
        "sensitivity_low": uppers[max(0, int(.025 * (len(uppers) - 1)))],
        "sensitivity_high": uppers[min(len(uppers) - 1, int(.975 * (len(uppers) - 1)))],
        "clusters": len(cluster_ids),
    }


def paired_cluster_bootstrap_difference(rows: Sequence[Mapping[str, Any]], *, current_arm: str = "current_skill", reference_arm: str = "previous_release", positive: str = "real", seed: int, repetitions: int = 1000) -> dict[str, float | None]:
    """Bootstrap current-minus-reference with shared case/repository draws."""
    by_stratum: dict[tuple[str, ...], dict[str, dict[tuple[str, str], list[Mapping[str, Any]]]]] = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for row in rows:
        if row.get("arm") not in {current_arm, reference_arm} or float(row.get("inclusion_probability", 0)) <= 0:
            continue
        stratum = tuple(str(row.get(field, "")) for field in ("host", "category", "severity", "status"))
        by_stratum[stratum][str(row["arm"])][(str(row.get("case_id", "")), str(row.get("repository", "")))].append(row)
    paired = {
        stratum: set(arms.get(current_arm, {})) & set(arms.get(reference_arm, {}))
        for stratum, arms in by_stratum.items()
    }
    if not paired or any(not clusters for clusters in paired.values()) or repetitions < 1:
        return {"low": None, "high": None, "sensitivity_low": None, "sensitivity_high": None, "clusters": 0}
    paired_cluster_count = len(set().union(*paired.values()))
    # Independently selected marginal samples do not establish pair inclusion
    # probabilities. Restrict paired inference to complete shared censuses.
    probabilities = {
        float(row["inclusion_probability"])
        for stratum, clusters in paired.items()
        for arm in (current_arm, reference_arm)
        for cluster in clusters
        for row in by_stratum[stratum][arm][cluster]
    }
    if paired_cluster_count < 2 or probabilities != {1.0} or any(set(arms.get(current_arm, {})) != set(arms.get(reference_arm, {})) for arms in by_stratum.values()):
        return {"low": None, "high": None, "sensitivity_low": None, "sensitivity_high": None, "clusters": paired_cluster_count}
    lowers: list[float] = []
    uppers: list[float] = []
    for replicate in range(repetitions):
        current_rows: list[Mapping[str, Any]] = []
        reference_rows: list[Mapping[str, Any]] = []
        for stratum, clusters in sorted(paired.items()):
            universe = tuple(sorted(clusters))
            rng = random.Random(f"{seed}:{replicate}:{stratum}:{universe}")
            for cluster in [rng.choice(universe) for _ in universe]:
                current_rows.extend(by_stratum[stratum][current_arm][cluster])
                reference_rows.extend(by_stratum[stratum][reference_arm][cluster])
        current = weighted_rate(current_rows, positive=positive)
        reference = weighted_rate(reference_rows, positive=positive)
        if current["lower"] is not None and reference["upper"] is not None:
            lowers.append(current["lower"] - reference["upper"])
            uppers.append(current["upper"] - reference["lower"])
    if not lowers:
        return {"low": None, "high": None, "sensitivity_low": None, "sensitivity_high": None, "clusters": paired_cluster_count}
    lowers.sort()
    uppers.sort()
    return {
        "low": lowers[max(0, int(.025 * (len(lowers) - 1)))],
        "high": lowers[min(len(lowers) - 1, int(.975 * (len(lowers) - 1)))],
        "sensitivity_low": uppers[max(0, int(.025 * (len(uppers) - 1)))],
        "sensitivity_high": uppers[min(len(uppers) - 1, int(.975 * (len(uppers) - 1)))],
        "clusters": paired_cluster_count,
    }


def summarize_calibration(frame: Sequence[Mapping[str, Any]], frozen: Mapping[str, Any], resolved: Sequence[Mapping[str, Any]], unblinding: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Return separate confirmation/rejection metrics without inventing labels."""
    frame_by_id = {str(row["candidate_id"]): row for row in frame}
    resolution_by_review = {str(row["review_id"]): row for row in resolved}
    if frozen.get("frame_sha256") != hashlib.sha256(_canonical(_frame_identity(frame)).encode()).hexdigest():
        raise ValueError("frame no longer matches frozen sample")
    _validate_frozen_selection(frame, frozen)
    expected_ids = set(frozen.get("sampled_candidate_ids", []))
    mapped_ids = [str(item.get("candidate_id", "")) for item in unblinding]
    review_ids = [str(item.get("review_id", "")) for item in unblinding]
    if set(mapped_ids) != expected_ids or len(mapped_ids) != len(expected_ids) or len(set(review_ids)) != len(review_ids) or set(review_ids) != set(resolution_by_review):
        raise ValueError("unblinding map is truncated or inconsistent")
    frozen_probabilities = {
        str(candidate): stratum.get("inclusion_probability")
        for stratum in frozen.get("strata", [])
        if isinstance(stratum, Mapping)
        for candidate in stratum.get("candidate_ids", [])
    }
    if set(frozen_probabilities) != expected_ids:
        raise ValueError("frozen inclusion map is incomplete")
    rows: list[dict[str, Any]] = []
    for item in unblinding:
        candidate_id = str(item["candidate_id"])
        source = frame_by_id.get(candidate_id)
        resolution = resolution_by_review.get(str(item["review_id"]))
        if source is None or resolution is None:
            raise ValueError("unblinding does not match frozen frame and labels")
        probability = item.get("inclusion_probability")
        if isinstance(probability, bool) or not isinstance(probability, (int, float)) or probability != frozen_probabilities[candidate_id]:
            raise ValueError("unblinding inclusion probability does not match frozen sample")
        rows.append({**{field: source.get(field) for field in ("case_id", "repository", *STRATUM_FIELDS)}, "label": resolution.get("label"), "inclusion_probability": frozen_probabilities[candidate_id], "primary_reviewer_count": resolution.get("primary_reviewer_count", 0), "review_seconds": resolution.get("review_seconds", 0)})
    def metric_for(source_rows: Sequence[Mapping[str, Any]], status: str) -> dict[str, Any]:
        subset = [row for row in source_rows if row["status"] == status]
        return {
            "population_weighted": weighted_rate(subset),
            "cluster_bootstrap95": cluster_bootstrap_interval(subset, seed=int(frozen["seed"])),
            "sampled": len(subset),
            "unresolved": sum(row["label"] is None for row in subset),
        }

    def metric(status: str) -> dict[str, Any]:
        return metric_for(rows, status)
    by_host_arm: dict[str, dict[str, dict[str, Any]]] = {}
    for host in sorted({str(row["host"]) for row in rows}):
        by_host_arm[host] = {}
        for arm in sorted({str(row["arm"]) for row in rows if str(row["host"]) == host}):
            subset = [row for row in rows if str(row["host"]) == host and str(row["arm"]) == arm]
            by_host_arm[host][arm] = {
                "confirmation_precision": metric_for(subset, "confirmed"),
                "serious_confirmation_precision": metric_for([row for row in subset if row["severity"] in {"high", "critical"}], "confirmed"),
                "rejection_miss": metric_for(subset, "rejected"),
            }
        host_rows = [row for row in rows if str(row["host"]) == host and row["status"] == "confirmed"]
        by_host_arm[host]["paired_current_minus_previous"] = paired_cluster_bootstrap_difference(host_rows, seed=int(frozen["seed"]))
    return {
        "schema_version": 1,
        "frame_sha256": frozen["frame_sha256"],
        "sampled_candidate_ids": sorted(expected_ids),
        "actual_humans": bool(rows) and all(row["primary_reviewer_count"] == 2 for row in rows),
        "confirmation_precision": metric("confirmed"),
        "rejection_miss": metric("rejected"),
        "rejection_audit_complete": bool(metric("rejected")["sampled"]),
        "by_host_arm": by_host_arm,
        "review_time_complete": bool(rows) and all(isinstance(row["review_seconds"], (int, float)) and row["review_seconds"] > 0 for row in rows),
    }


def evaluation_calibration_from_records(records: Mapping[str, Any], receipts: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Derive release metrics from frozen human records; never accept thresholds as input."""
    frame, frozen = records.get("frame"), records.get("frozen")
    stage_block = records.get("stage_block", "full_pipeline")
    labels, adjudications, unblinding = records.get("labels", []), records.get("adjudications", []), records.get("unblinding")
    if not isinstance(frame, list) or not isinstance(frozen, Mapping) or not isinstance(labels, list) or not isinstance(adjudications, list) or not isinstance(unblinding, list):
        raise ValueError("calibration records are malformed")
    if not isinstance(stage_block, str) or not stage_block or any(row.get("stage_block", "full_pipeline") != stage_block for row in frame):
        raise ValueError("calibration must contain exactly one stage block")
    packets, expected_unblinding = build_blinded_packets(frame, frozen)
    if unblinding != expected_unblinding:
        raise ValueError("calibration unblinding does not match frozen packets")
    resolved = resolve_labels(packets, labels, adjudications)
    summary = summarize_calibration(frame, frozen, resolved, unblinding)
    frame_complete = False
    roots = records.get("input_roots")
    if isinstance(roots, Mapping):
        # Rebuild from immutable native evidence; a caller's completion flag
        # or frame digest cannot stand in for the producer's raw artifacts.
        from bench.scorer.harness_results import import_harness_results
        if set(roots) != {"results", "frozen"} or not all(isinstance(value, str) for value in roots.values()):
            raise ValueError("calibration input roots are invalid")
        rebuilt = import_harness_results(Path(roots["results"]), Path(roots["frozen"]), stage_block=stage_block)
        if any(records.get(key) != rebuilt[key] for key in ("frame", "frozen", "unblinding", "runs", "receipts_sha256")):
            raise ValueError("calibration frame differs from native evidence")
        from bench.harness import digest
        if digest(receipts) != rebuilt["receipts_sha256"]:
            raise ValueError("calibration receipts differ from evaluation receipts")
        frame_complete = rebuilt["frame_complete"]
    by_candidate = {str(row["candidate_id"]): row for row in frame}
    review_to_candidate = {str(row["review_id"]): str(row["candidate_id"]) for row in unblinding}
    resolved_by_candidate = {review_to_candidate[str(row["review_id"])]: row for row in resolved}
    canonical_labels = sorted(
        [
            {
                "candidate_id": review_to_candidate[str(row["review_id"])],
                "review_id": str(row["review_id"]),
                "reviewer_id": row["reviewer_id"],
                "role": row["role"],
                "label": row["label"],
                "seconds": row["seconds"],
                "reason": row["reason"],
            }
            for row in [*labels, *adjudications]
        ],
        key=lambda row: (row["candidate_id"], row["role"], row["reviewer_id"], row["review_id"]),
    )
    probabilities = {str(item["candidate_id"]): float(item["inclusion_probability"]) for item in unblinding}
    hosts: dict[str, dict[str, Any]] = {}
    for host, arms in summary["by_host_arm"].items():
        current = arms.get("current_skill", {}).get("serious_confirmation_precision", {}).get("cluster_bootstrap95", {})
        baseline = arms.get("previous_release", {}).get("serious_confirmation_precision", {}).get("cluster_bootstrap95", {})
        host_candidates = [candidate for candidate in resolved_by_candidate if str(by_candidate[candidate].get("host")) == host]
        def finite_census(arm: str) -> bool:
            population = [
                str(row["candidate_id"])
                for row in frame
                if row.get("host") == host and row.get("arm") == arm and row.get("status") == "confirmed" and row.get("severity") in {"high", "critical"}
            ]
            return bool(population) and set(population).issubset(resolved_by_candidate) and all(
                resolved_by_candidate[candidate].get("label") in {"real", "false"} for candidate in population
            )

        # Percentile bootstrap values describe resampled observed clusters.
        # A complete finite benchmark census is exact for this corpus only;
        # it is not a confidence interval or a population inference.
        current_census = finite_census("current_skill")
        baseline_census = finite_census("previous_release")
        current_lower = (
            summary["by_host_arm"][host]["current_skill"]["serious_confirmation_precision"]["population_weighted"]["lower"]
            if current_census else current.get("low") if current.get("low") != current.get("high") else None
        )
        baseline_upper = (
            summary["by_host_arm"][host]["previous_release"]["serious_confirmation_precision"]["population_weighted"]["upper"]
            if baseline_census else baseline.get("sensitivity_high") if baseline.get("low") != baseline.get("sensitivity_high") else None
        )
        review_medians = {
            arm: _weighted_median([
                (float(resolved_by_candidate[candidate]["review_seconds"]), 1 / probabilities[candidate])
                for candidate in host_candidates if by_candidate[candidate].get("arm") == arm
            ])
            for arm in ("current_skill", "previous_release")
        }
        review_ratio = review_medians["current_skill"] / review_medians["previous_release"] if review_medians["current_skill"] is not None and review_medians["previous_release"] not in {None, 0} else None
        costs: dict[str, float | None] = {}
        serious: dict[str, float | None] = {}
        for arm in ("current_skill", "previous_release"):
            # Failed paid invocations remain in the numerator. Any unknown bill
            # prevents a cost comparison instead of silently becoming zero.
            arm_receipts = [receipt for receipt in receipts if receipt.get("host") == host and receipt.get("arm") == arm and receipt.get("stage_block", "full_pipeline") == stage_block]
            costs[arm] = sum(float(receipt["usage"]["cost_usd"]) for receipt in arm_receipts) if arm_receipts and all(receipt.get("accounting_state") == "complete" and isinstance(receipt.get("usage"), Mapping) and receipt["usage"].get("cost_source") == "actual" and _finite_nonnegative(receipt["usage"].get("cost_usd")) for receipt in arm_receipts) else None
            candidates = [candidate for candidate in host_candidates if by_candidate[candidate].get("arm") == arm and by_candidate[candidate].get("status") == "confirmed" and by_candidate[candidate].get("severity") in {"high", "critical"}]
            serious[arm] = sum(1 / probabilities[candidate] for candidate in candidates if resolved_by_candidate[candidate].get("label") == "real") if candidates and all(resolved_by_candidate[candidate].get("label") in {"real", "false"} for candidate in candidates) else None
        current_cost = costs["current_skill"] / serious["current_skill"] if costs["current_skill"] is not None and serious["current_skill"] else None
        baseline_cost = costs["previous_release"] / serious["previous_release"] if costs["previous_release"] is not None and serious["previous_release"] else None
        unresolved_weight = sum(1 / probabilities[candidate] for candidate in host_candidates if resolved_by_candidate[candidate].get("label") in {None, "unverifiable"})
        total_weight = sum(1 / probabilities[candidate] for candidate in host_candidates)
        rejected = [candidate for candidate in host_candidates if by_candidate[candidate].get("status") == "rejected"]
        hosts[host] = {
            "frame_complete": frame_complete,
            "actual_humans": summary["actual_humans"], "review_time_complete": summary["review_time_complete"],
            "rejection_audit_complete": {"current_skill", "previous_release", "no_skill_baseline"}.issubset(arms) and bool(rejected) and all(resolved_by_candidate[candidate].get("label") in {"real", "false"} for candidate in rejected),
            "serious_precision_lower": current_lower, "baseline_precision_upper": baseline_upper,
            "serious_precision_basis": "exact_finite_census" if current_census else "cluster_bootstrap95" if current_lower is not None else "unavailable",
            "baseline_precision_basis": "exact_finite_census" if baseline_census else "cluster_bootstrap95" if baseline_upper is not None else "unavailable",
            "review_time_ratio": review_ratio,
            "cost_per_serious_ratio": current_cost / baseline_cost if current_cost is not None and baseline_cost not in {None, 0} else None,
            "unresolved_fraction": unresolved_weight / total_weight if total_weight else None,
        }
    metric_names = ("serious_precision_lower", "baseline_precision_upper", "review_time_ratio", "cost_per_serious_ratio", "unresolved_fraction")
    metrics: dict[str, float] = {}
    for name in metric_names:
        values = [float(host[name]) for host in hosts.values() if isinstance(host.get(name), (int, float))]
        if not hosts or len(values) != len(hosts):
            continue
        metrics[name] = min(values) if name == "serious_precision_lower" else max(values)
    return {"stage_block": stage_block, "frame_sha256": summary["frame_sha256"], "sampled_candidate_ids": summary["sampled_candidate_ids"], "labels": canonical_labels, "labels_sha256": hashlib.sha256(_canonical(canonical_labels).encode()).hexdigest(), "metrics": metrics, "summary": summary, "hosts": hosts}
