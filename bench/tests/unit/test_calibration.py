"""Human calibration stays deterministic, blinded, and incomplete without humans."""

import hashlib
import sys
import json
import pytest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.calibration import (
    build_blinded_packets,
    cluster_bootstrap_interval,
    evaluation_calibration_from_records,
    freeze_sample,
    paired_cluster_bootstrap_difference,
    resolve_labels,
    summarize_calibration,
    weighted_rate,
)
from jsonschema.validators import Draft202012Validator


def _frame(count: int = 61):
    return [
        {
            "candidate_id": f"c{i}",
            "experiment_id": "e1",
            "host": "codex",
            "arm": "current_skill" if i % 2 else "previous_release",
            "category": "security" if i % 2 else "logic",
            "severity": "high",
            "status": "confirmed" if i % 3 else "rejected",
            "case_id": f"case-{i // 2}",
            "repository": f"repo-{i % 3}",
            "evidence": {"status": "unverified", "reasons": ["missing_source"]},
        }
        for i in range(count)
    ]


def test_freeze_sample_is_seeded_and_preserves_each_stratum() -> None:
    first = freeze_sample(_frame(), seed=9)
    second = freeze_sample(list(reversed(_frame())), seed=9)
    assert first["frame_sha256"] == second["frame_sha256"]
    assert first["sampled_candidate_ids"] == second["sampled_candidate_ids"]
    assert len(first["sampled_candidate_ids"]) >= 60
    assert all(row["sampled_n"] >= 1 for row in first["strata"])


def test_blinded_packets_hide_arm_status_and_labels_but_show_evidence_layout() -> None:
    frozen = freeze_sample(_frame(2), seed=1)
    packets, unblinding = build_blinded_packets(_frame(2), frozen)
    serialized = str(packets)
    assert "previous_release" not in serialized
    assert "confirmed" not in serialized
    assert packets[0]["evidence"]["source"] == "unavailable"
    assert unblinding[0]["candidate_id"] in {"c0", "c1"}


def test_two_distinct_humans_and_adjudication_required_for_resolved_label() -> None:
    frozen = freeze_sample(_frame(2), seed=1)
    packets, _ = build_blinded_packets(_frame(2), frozen)
    item = packets[0]["review_id"]
    labels = [
        {"review_id": item, "reviewer_id": "a", "role": "primary", "label": "real", "reason": "x", "seconds": 10},
        {"review_id": item, "reviewer_id": "b", "role": "primary", "label": "false", "reason": "y", "seconds": 12},
    ]
    resolved = resolve_labels(packets, labels, [])
    assert resolved[0]["label"] is None
    assert resolved[0]["status"] == "unresolved"
    adjudicated = resolve_labels(
        packets,
        labels,
        [{"review_id": item, "reviewer_id": "c", "role": "adjudicator", "label": "real", "reason": "z", "seconds": 8}],
    )
    assert adjudicated[0]["label"] == "real"


def test_weighted_rate_keeps_unresolved_as_sensitivity_not_false() -> None:
    result = weighted_rate(
        [
            {"label": "real", "inclusion_probability": 0.5},
            {"label": None, "inclusion_probability": 0.5},
        ]
    )
    assert result["estimate"] is None
    assert result["lower"] == 0.5
    assert result["upper"] == 1.0


def test_cluster_bootstrap_draws_paired_case_repository_rows_once() -> None:
    rows = [
        {"case_id": "c1", "repository": "r", "host": "codex", "arm": arm, "category": "security", "severity": "high", "status": "confirmed", "label": label, "inclusion_probability": 1.0}
        for arm, label in (("current_skill", "real"), ("previous_release", None))
    ] + [
        {"case_id": "c2", "repository": "r", "host": "codex", "arm": arm, "category": "security", "severity": "high", "status": "confirmed", "label": label, "inclusion_probability": 1.0}
        for arm, label in (("current_skill", "false"), ("previous_release", "real"))
    ]
    interval = cluster_bootstrap_interval(rows, seed=1, repetitions=20)
    assert interval["clusters"] == 2
    assert interval["sensitivity_high"] >= interval["high"]


def test_cluster_bootstrap_keeps_one_cluster_per_stratum_in_every_draw() -> None:
    # A global cluster bootstrap can draw c1 twice and c2 zero times, turning
    # this balanced frame into 1.0.  Stratification must retain both strata.
    rows = [
        {"case_id": "c1", "repository": "r", "host": "codex", "arm": "current_skill", "category": "security", "severity": "high", "status": "confirmed", "label": "real", "inclusion_probability": 1.0},
        {"case_id": "c2", "repository": "r", "host": "codex", "arm": "current_skill", "category": "logic", "severity": "high", "status": "confirmed", "label": "false", "inclusion_probability": 1.0},
    ]
    interval = cluster_bootstrap_interval(rows, seed=7, repetitions=25)
    assert interval["low"] == interval["high"] == 0.5


def test_evidence_change_invalidates_frozen_frame() -> None:
    frame = _frame(2)
    frozen = freeze_sample(frame, seed=1)
    changed = [dict(row) for row in frame]
    changed[0]["evidence"] = {"status": "verified", "source": {"excerpt": "forged"}}
    with pytest.raises(ValueError, match="frame"):
        build_blinded_packets(changed, frozen)


def test_frozen_selection_cannot_swap_selected_and_excluded_candidates() -> None:
    frame = _frame(61)
    # One stratum makes selection membership the only changed artifact field.
    for row in frame:
        row.update({"host": "codex", "arm": "current_skill", "category": "security", "severity": "high", "status": "confirmed"})
    frozen = freeze_sample(frame, seed=9)
    selected = frozen["sampled_candidate_ids"][0]
    excluded = next(row["candidate_id"] for row in frame if row["candidate_id"] not in frozen["sampled_candidate_ids"])
    frozen["sampled_candidate_ids"] = [excluded if item == selected else item for item in frozen["sampled_candidate_ids"]]
    frozen["strata"][0]["candidate_ids"] = [excluded if item == selected else item for item in frozen["strata"][0]["candidate_ids"]]
    with pytest.raises(ValueError, match="deterministic sample"):
        build_blinded_packets(frame, frozen)


def test_frozen_frame_matches_its_schema() -> None:
    schema = json.loads((Path(__file__).resolve().parents[2] / "schemas" / "calibration.schema.json").read_text())
    frozen = freeze_sample(_frame(2), seed=1)
    Draft202012Validator(schema).validate(frozen)


def test_summary_reports_confirmed_and_rejected_separately_with_unknowns() -> None:
    frame = _frame(4)
    frozen = freeze_sample(frame, seed=1)
    packets, unblinding = build_blinded_packets(frame, frozen)
    labels = [
        {"review_id": packet["review_id"], "reviewer_id": "a", "role": "primary", "label": "real", "reason": "x", "seconds": 1}
        for packet in packets
    ]
    labels.extend(
        {"review_id": packet["review_id"], "reviewer_id": "b", "role": "primary", "label": "real", "reason": "x", "seconds": 1}
        for packet in packets
    )
    summary = summarize_calibration(frame, frozen, resolve_labels(packets, labels, []), unblinding)
    assert summary["actual_humans"] is True
    assert summary["confirmation_precision"]["sampled"] > 0
    assert summary["rejection_miss"]["sampled"] > 0


@pytest.mark.parametrize("count", [4, 121])
def test_evaluation_calibration_is_derived_from_frozen_records_not_thresholds(count) -> None:
    frame = _frame(count)
    frozen = freeze_sample(frame, seed=1)
    packets, unblinding = build_blinded_packets(frame, frozen)
    labels = [
        {"review_id": packet["review_id"], "reviewer_id": reviewer, "role": "primary", "label": "real", "reason": "x", "seconds": 1}
        for packet in packets for reviewer in ("a", "b")
    ]
    calibration = evaluation_calibration_from_records({"frame": frame, "frozen": frozen, "labels": labels, "adjudications": [], "unblinding": unblinding}, [])
    assert calibration["frame_sha256"] == frozen["frame_sha256"]
    assert set(calibration["hosts"]) == {"codex"}
    assert calibration["hosts"]["codex"]["cost_per_serious_ratio"] is None
    assert calibration["hosts"]["codex"]["review_time_ratio"] == 1.0


@pytest.mark.parametrize("seconds", [True, float("nan"), float("inf")])
def test_human_review_time_must_be_finite_numeric_seconds(seconds) -> None:
    with pytest.raises(ValueError, match="human label"):
        resolve_labels([{"review_id": "r"}], [{"review_id": "r", "reviewer_id": "a", "role": "primary", "label": "real", "reason": "x", "seconds": seconds}], [])


def test_canonical_labels_bind_unicode_reason_and_weighted_median_review_ratio() -> None:
    frame = _frame(4)
    for index, row in enumerate(frame):
        row.update(arm="current_skill" if index < 2 else "previous_release", status="confirmed", severity="high")
    frozen = freeze_sample(frame, seed=1)
    packets, unblinding = build_blinded_packets(frame, frozen)
    labels = []
    for packet, item in zip(packets, unblinding):
        seconds = 2 if item["candidate_id"] in {"c0", "c1"} else 10
        labels.extend({"review_id": packet["review_id"], "reviewer_id": reviewer, "role": "primary", "label": "real", "reason": "observed café", "seconds": seconds} for reviewer in ("a", "b"))
    calibration = evaluation_calibration_from_records({"frame": frame, "frozen": frozen, "labels": labels, "adjudications": [], "unblinding": unblinding}, [])
    assert "café" in str(calibration["labels"])
    assert calibration["labels_sha256"] == hashlib.sha256(json.dumps(calibration["labels"], sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    assert calibration["hosts"]["codex"]["review_time_ratio"] == .2


def test_blank_adjudicator_cannot_resolve_disagreement() -> None:
    labels = [{"review_id": "r", "reviewer_id": reviewer, "role": "primary", "label": label, "reason": "x", "seconds": 1} for reviewer, label in (("a", "real"), ("b", "false"))]
    with pytest.raises(ValueError, match="adjudication"):
        resolve_labels([{"review_id": "r"}], labels, [{"review_id": "r", "reviewer_id": "", "role": "adjudicator", "label": "real", "reason": "x", "seconds": 1}])


def test_cost_includes_failed_runs_and_only_serious_confirmed_yield() -> None:
    frame = _frame(12)
    for i, row in enumerate(frame):
        row.update(arm="current_skill" if i < 6 else "previous_release", category="logic", status="confirmed", severity="high" if i % 6 < 2 else "low")
    frozen = freeze_sample(frame, seed=1)
    packets, unblinding = build_blinded_packets(frame, frozen)
    labels = [{"review_id": packet["review_id"], "reviewer_id": reviewer, "role": "primary", "label": "real", "reason": "x", "seconds": 1} for packet in packets for reviewer in ("a", "b")]
    records = {"frame": frame, "frozen": frozen, "labels": labels, "unblinding": unblinding}
    receipts = [{"host": "codex", "arm": arm, "lifecycle": lifecycle, "accounting_state": "complete", "usage": {"cost_usd": cost, "cost_source": "actual"}} for arm, lifecycle, cost in (("current_skill", "completed", 1), ("current_skill", "error", 2), ("previous_release", "completed", 1))]
    host = evaluation_calibration_from_records(records, receipts)["hosts"]["codex"]
    assert host["cost_per_serious_ratio"] == 3
    assert host["serious_precision_lower"] == 1.0  # exact for this complete finite benchmark census
    assert host["serious_precision_basis"] == "exact_finite_census"
    receipts[1]["accounting_state"] = "unknown"
    assert evaluation_calibration_from_records(records, receipts)["hosts"]["codex"]["cost_per_serious_ratio"] is None


def test_adjudication_without_two_primary_humans_is_rejected() -> None:
    frozen = freeze_sample(_frame(2), seed=1)
    packets, _ = build_blinded_packets(_frame(2), frozen)
    with pytest.raises(ValueError, match="adjudication"):
        resolve_labels(packets, [], [{"review_id": packets[0]["review_id"], "reviewer_id": "c", "role": "adjudicator", "label": "real", "reason": "x", "seconds": 1}])


def test_changed_frame_or_truncated_unblinding_cannot_be_reweighted() -> None:
    frame = _frame(2)
    frozen = freeze_sample(frame, seed=1)
    changed = [dict(row) for row in frame]
    changed[0]["status"] = "rejected" if changed[0]["status"] == "confirmed" else "confirmed"
    with pytest.raises(ValueError, match="frame"):
        build_blinded_packets(changed, frozen)
    packets, unblinding = build_blinded_packets(frame, frozen)
    resolved = resolve_labels(packets, [], [])
    with pytest.raises(ValueError, match="unblinding"):
        summarize_calibration(frame, frozen, resolved, unblinding[:-1])


def test_unblinding_cannot_change_frozen_inclusion_probability() -> None:
    frame = _frame(2)
    frozen = freeze_sample(frame, seed=1)
    packets, unblinding = build_blinded_packets(frame, frozen)
    labels = [
        {"review_id": packet["review_id"], "reviewer_id": reviewer, "role": "primary", "label": "real", "reason": "x", "seconds": 1}
        for packet in packets for reviewer in ("a", "b")
    ]
    unblinding[0]["inclusion_probability"] = .01
    with pytest.raises(ValueError, match="inclusion probability"):
        summarize_calibration(frame, frozen, resolve_labels(packets, labels, []), unblinding)


def test_summary_separates_host_arm_metrics_and_paired_difference() -> None:
    frame = _frame(4)
    for index, row in enumerate(frame):
        row["host"] = "codex"
        row["arm"] = "current_skill" if index < 2 else "previous_release"
        row["case_id"] = f"case-{index % 2}"
        row["repository"] = "repo"
        row["status"] = "confirmed"
    frozen = freeze_sample(frame, seed=1)
    packets, unblinding = build_blinded_packets(frame, frozen)
    labels = []
    for packet, item in zip(packets, unblinding):
        label = "real" if item["candidate_id"] in {"c0", "c1"} else "false"
        labels.extend({"review_id": packet["review_id"], "reviewer_id": reviewer, "role": "primary", "label": label, "reason": "x", "seconds": 1} for reviewer in ("a", "b"))
    summary = summarize_calibration(frame, frozen, resolve_labels(packets, labels, []), unblinding)
    per_arm = summary["by_host_arm"]["codex"]
    assert per_arm["current_skill"]["confirmation_precision"]["population_weighted"]["lower"] == 1.0
    assert per_arm["previous_release"]["confirmation_precision"]["population_weighted"]["lower"] == 0.0
    assert per_arm["paired_current_minus_previous"]["low"] == 1.0


def test_paired_bootstrap_uses_shared_case_draws_for_arm_difference() -> None:
    rows = [
        {"case_id": case, "repository": "r", "host": "codex", "arm": arm, "category": "security", "severity": "high", "status": "confirmed", "label": label, "inclusion_probability": 1.0}
        for case, arm, label in (("c1", "current_skill", "real"), ("c1", "previous_release", "false"), ("c2", "current_skill", "false"), ("c2", "previous_release", "real"))
    ]
    interval = paired_cluster_bootstrap_difference(rows, seed=1, repetitions=20)
    assert interval["clusters"] == 2
    assert interval["low"] <= 0 <= interval["high"]


def test_paired_bootstrap_requires_two_clusters_and_equal_pair_design() -> None:
    one_cluster = [
        {"case_id": "c1", "repository": "r", "host": "codex", "arm": arm, "category": "security", "severity": "high", "status": "confirmed", "label": label, "inclusion_probability": 1.0}
        for arm, label in (("current_skill", "real"), ("previous_release", "false"))
    ]
    assert paired_cluster_bootstrap_difference(one_cluster, seed=1)["low"] is None
    unequal = one_cluster + [
        {"case_id": "c2", "repository": "r", "host": "codex", "arm": arm, "category": "security", "severity": "high", "status": "confirmed", "label": label, "inclusion_probability": probability}
        for arm, label, probability in (("current_skill", "real", .5), ("previous_release", "false", 1.0))
    ]
    assert paired_cluster_bootstrap_difference(unequal, seed=1)["low"] is None


def test_calibration_returns_the_exact_candidate_keyed_labels_used_for_metrics() -> None:
    frame = _frame(2)
    frozen = freeze_sample(frame, seed=1)
    packets, unblinding = build_blinded_packets(frame, frozen)
    labels = [
        {"review_id": packet["review_id"], "reviewer_id": reviewer, "role": "primary", "label": "real", "reason": reason, "seconds": seconds}
        for packet in packets
        for reviewer, reason, seconds in (("a", "first", 2), ("b", "second", 3))
    ]
    calibration = evaluation_calibration_from_records(
        {"frame": frame, "frozen": frozen, "labels": labels, "adjudications": [], "unblinding": unblinding}, []
    )
    assert calibration["labels_sha256"]
    assert {(row["candidate_id"], row["reviewer_id"], row["role"], row["seconds"], row["reason"]) for row in calibration["labels"]} == {
        (item["candidate_id"], reviewer, "primary", seconds, reason)
        for item in unblinding
        for reviewer, reason, seconds in (("a", "first", 2), ("b", "second", 3))
    }


def test_complete_finite_census_preserves_exact_bound_without_population_claim() -> None:
    frame = _frame(4)
    for row in frame:
        row.update(host="codex", arm="current_skill", category="logic", severity="high", status="confirmed")
    frozen = freeze_sample(frame, seed=1, minimum=60)
    packets, unblinding = build_blinded_packets(frame, frozen)
    labels = [
        {"review_id": packet["review_id"], "reviewer_id": reviewer, "role": "primary", "label": "real", "reason": "observed", "seconds": 1}
        for packet in packets for reviewer in ("a", "b")
    ]
    calibration = evaluation_calibration_from_records(
        {"frame": frame, "frozen": frozen, "labels": labels, "adjudications": [], "unblinding": unblinding}, []
    )
    host = calibration["hosts"]["codex"]
    assert host["serious_precision_lower"] == 1.0
    assert host["serious_precision_basis"] == "exact_finite_census"


def test_stage_calibration_never_pools_other_pipeline_costs():
    from bench.tests.unit.test_calibration_finalize import _records
    from bench.scorer.calibration import evaluation_calibration_from_records
    records = _records(60)
    records["stage_block"] = "hunter_only"
    for candidate in records["frame"]:
        candidate["stage_block"] = "hunter_only"
    receipts = [
        {"host": "codex", "arm": arm, "stage_block": block, "accounting_state": "complete", "usage": {"cost_usd": cost, "cost_source": "actual"}}
        for block, arm, cost in (("hunter_only", "current_skill", 1), ("hunter_only", "previous_release", 1), ("full_pipeline", "current_skill", 100), ("full_pipeline", "previous_release", 1000))
    ]
    result = evaluation_calibration_from_records(records, receipts)
    assert result["stage_block"] == "hunter_only"
    assert result["hosts"]["codex"]["cost_per_serious_ratio"] == 1
    records["frame"][0]["stage_block"] = "full_pipeline"
    with pytest.raises(ValueError, match="exactly one stage"):
        evaluation_calibration_from_records(records, receipts)
