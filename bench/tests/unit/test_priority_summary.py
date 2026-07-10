from __future__ import annotations

from bench.scorer.priority_summary import build_priority_summary


def test_priority_summary_reports_actual_application_and_attributed_outcome() -> None:
    context = {
        "schema_version": 1,
        "scope_contract": "priority_only_whole_repo_remains_in_scope",
        "targets": [
            {
                "file": "src/pay.py",
                "lane": "must_focus",
                "priority_score": 91,
                "attribution_reason_codes": ["active_incident", "user_impact"],
            }
        ],
        "project_signals": {
            "signal_health": {"accepted": 1, "unmapped": 1},
            "unmapped_focus_signals": [
                {
                    "id": "inc-2",
                    "source": "sentry",
                    "kind": "incident",
                    "severity": "high",
                    "component": "payments",
                    "flow": "checkout",
                }
            ],
            "signal_yield": [],
        },
    }
    application = {
        "schema_version": 1,
        "scope_contract": "priority_only_whole_repo_remains_in_scope",
        "candidate_count": 1,
        "promoted_batches": ["2"],
        "promoted_batch_count": 1,
        "added_file_count": 3,
        "already_in_budget_candidates": [],
        "skipped_candidates": [],
    }
    events = [
        {
            "event": "confirmed",
            "file": "src/pay.py",
            "priority_reason_codes": ["active_incident"],
        }
    ]
    recon = {"batches": [{"id": 2, "files": ["src/pay.py"]}]}

    result = build_priority_summary(
        context=context,
        application=application,
        events=events,
        recon=recon,
        verified_covered_ids=set(),
    )

    assert result["available"] is True
    assert result["degraded_reason"] is None
    assert result["application_available"] is True
    assert result["application_reason"] is None
    assert result["top_targets"][0]["outcome"] == "confirmed"
    assert result["top_targets"][0]["investigated"] is True
    assert result["application"]["promoted_batches"] == ["2"]
    assert result["signal_health"]["malformed"] == 0
    assert result["unmapped_focus_signals"][0]["component"] == "payments"


def test_priority_summary_does_not_credit_same_file_coincidence() -> None:
    result = build_priority_summary(
        context={
            "schema_version": 1,
            "scope_contract": "priority_only_whole_repo_remains_in_scope",
            "targets": [
                {
                    "file": "src/pay.py",
                    "lane": "high",
                    "priority_score": 70,
                    "attribution_reason_codes": ["fix_history"],
                }
            ],
        },
        application={},
        events=[{"event": "confirmed", "file": "src/pay.py"}],
        recon={"batches": [{"id": 1, "files": ["src/pay.py"]}]},
        verified_covered_ids={1},
    )

    target = result["top_targets"][0]
    assert target["investigated"] is True
    assert target["outcome"] == "unattributed"


def test_priority_summary_reports_no_finding_only_for_verified_coverage() -> None:
    context = {
        "schema_version": 1,
        "scope_contract": "priority_only_whole_repo_remains_in_scope",
        "targets": [
            {
                "file": "src/pay.py",
                "lane": "high",
                "priority_score": 70,
                "attribution_reason_codes": ["fix_history"],
            }
        ],
    }
    recon = {"batches": [{"id": 1, "files": ["src/pay.py"]}]}

    not_reviewed = build_priority_summary(
        context=context,
        application={},
        events=[],
        recon=recon,
        verified_covered_ids=set(),
    )
    reviewed = build_priority_summary(
        context=context,
        application={},
        events=[],
        recon=recon,
        verified_covered_ids={1},
    )

    assert not_reviewed["top_targets"][0]["outcome"] == "not_reviewed"
    assert reviewed["top_targets"][0]["outcome"] == "no_finding"


def test_priority_summary_marks_missing_and_degraded_context_unavailable() -> None:
    missing = build_priority_summary(
        context={},
        application={},
        events=[],
        recon={},
        verified_covered_ids=set(),
    )
    degraded = build_priority_summary(
        context={
            "schema_version": 1,
            "scope_contract": "priority_only_whole_repo_remains_in_scope",
            "degraded": True,
            "source_status": {"collector": "git_unavailable"},
        },
        application={},
        events=[],
        recon={},
        verified_covered_ids=set(),
    )

    assert missing["available"] is False
    assert missing["degraded_reason"] == "priority_context_missing"
    assert degraded["available"] is False
    assert degraded["degraded_reason"] == "git_unavailable"
    assert missing["application_available"] is False
    assert missing["application_reason"] == "priority_application_missing"


def test_priority_summary_does_not_infer_zeroes_from_an_invalid_application_receipt() -> None:
    result = build_priority_summary(
        context={
            "schema_version": 1,
            "scope_contract": "priority_only_whole_repo_remains_in_scope",
            "targets": [],
        },
        application={"schema_version": 1, "candidate_count": 0},
        events=[],
        recon={},
        verified_covered_ids=set(),
    )

    assert result["available"] is True
    assert result["application_available"] is False
    assert result["application_reason"] == "priority_application_invalid"
    assert result["application"]["promoted_batch_count"] == 0
