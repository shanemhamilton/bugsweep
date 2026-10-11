"""Deterministic, explainable priority evidence for Bugsweep.

The reducer in this module never decides whether a bug exists.  It only answers
"where should the next bounded investigation start, and why now?" from closed,
locally-collected evidence kinds.  Callers remain responsible for Bugsweep's
Hunter -> Skeptic -> Referee confirmation chain.

The reducer is deliberately pure: filesystem, Git, issue-file, and baseline-log
collection live behind ``scripts/priority-context.sh``.  Keeping this layer free
of subprocesses makes its ordering, caps, and frozen-scope invariants easy to
test and safe to reuse.
"""

from __future__ import annotations

import fnmatch
import posixpath
import unicodedata
from copy import deepcopy
from typing import Any, Collection, Mapping, Sequence

SCHEMA_VERSION = 1

LANE_RANK = {"must_focus": 0, "high": 1, "elevated": 2, "normal": 3}
TIER_RANK = {"critical": 0, "normal": 1, "low": 2}
CATEGORY_CAPS = {
    "impact_value": 30,
    "active_evidence": 25,
    "change_likelihood": 15,
    "reachability": 15,
    "recurrence_learning": 10,
    "audit_staleness": 5,
}
HARD_MAX_TARGETS = 200
HARD_MAX_REASONS = 8
HARD_MAX_PROMOTION_BATCHES = 20
HARD_MAX_PROMOTION_CANDIDATES = HARD_MAX_TARGETS
HARD_MAX_GLOB_MATCHES = 100
HARD_TEXT_CAP = 200

_REASON_ORDER = {
    "baseline_failure": 0,
    "active_incident": 1,
    "release_blocker": 2,
    "reopened_conclusion": 3,
    "variant_match": 4,
    "live_sink": 5,
    "content_changed_since_audit": 6,
    "changed_since_last_run": 7,
    "critical_path": 8,
    "user_impact": 9,
    "local_bug_issue": 10,
    "project_priority": 11,
    "revert_history": 12,
    "fix_history": 13,
    "prior_bug_history": 14,
    "git_history": 15,
    "stale_audit": 16,
    "runtime_without_test_change": 17,
    "maybe_sink": 18,
    "cold_sink": 19,
}
_LANE_REASON_CODES = {
    "baseline_failure",
    "active_incident",
    "release_blocker",
    "reopened_conclusion",
    "variant_match",
    "live_sink",
    "content_changed_since_audit",
    "critical_path",
    "local_bug_issue",
    "project_priority",
    "revert_history",
    "fix_history",
    "prior_bug_history",
}
_MUST_FOCUS_REASON_CODES = {
    "baseline_failure",
    "active_incident",
    "release_blocker",
    "reopened_conclusion",
    "variant_match",
}
REASON_CODES = frozenset(_REASON_ORDER)


def _bounded_int(value: object, default: int, low: int, high: int) -> int:
    try:
        parsed = int(str(value))
    except (TypeError, ValueError):
        return default
    return max(low, min(high, parsed))


def _bounded_float(value: object, default: float = 0.0) -> float:
    try:
        parsed = float(str(value))
    except (TypeError, ValueError):
        return default
    return max(0.0, parsed)


def sanitize_text(value: object, max_chars: int = HARD_TEXT_CAP) -> str:
    """Return bounded, one-line data text with control characters removed.

    Shell metacharacters intentionally remain ordinary characters: collection
    never evaluates this text, and JSON serialization escapes it.  Removing
    control characters and newlines keeps the artifact compact and prevents
    terminal-control payloads from masquerading as structure.
    """

    limit = _bounded_int(max_chars, HARD_TEXT_CAP, 0, HARD_TEXT_CAP)
    raw = str(value or "")
    cleaned = "".join(" " if unicodedata.category(ch).startswith("C") else ch for ch in raw)
    return " ".join(cleaned.split())[:limit]


def normalize_repo_path(value: object, tracked_files: Collection[str]) -> str | None:
    """Validate a path against the already-established tracked-file scope."""

    if not isinstance(value, str) or not value or "\x00" in value:
        return None
    candidate = value.strip()
    if candidate.startswith(("/", "~", "\\")):
        return None
    while candidate.startswith("./"):
        candidate = candidate[2:]
    parts = candidate.split("/")
    if not candidate or any(part in {"", ".", ".."} for part in parts):
        return None
    normalized = posixpath.normpath(candidate)
    if normalized.startswith("../") or normalized == "..":
        return None
    return normalized if normalized in tracked_files else None


def _is_test_path(path: str) -> bool:
    lower = path.lower()
    parts = lower.split("/")
    name = parts[-1]
    return (
        any(part in {"test", "tests", "spec", "specs", "__tests__"} for part in parts[:-1])
        or name.startswith("test_")
        or ".test." in name
        or ".spec." in name
        or name.endswith("_test.go")
    )


def _reason(
    code: str,
    category: str,
    points: int,
    source: str,
    summary: str,
    evidence: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "code": code,
        "category": category,
        "raw_points": max(0, int(points)),
        "source": source,
        "summary": summary,
        "evidence": dict(evidence or {}),
    }


def _priority_points(priority: object) -> int:
    value = _bounded_int(priority, 3, 0, 4)
    return {0: 25, 1: 20, 2: 14, 3: 8, 4: 4}[value]


def _severity_points(severity: object) -> int:
    return {"critical": 25, "high": 20, "medium": 12, "low": 6}.get(str(severity or "").lower(), 6)


def _set_lane(lanes: dict[str, int], path: str, lane: str) -> None:
    lanes[path] = min(lanes.get(path, LANE_RANK["normal"]), LANE_RANK[lane])


def _append_reason(
    reasons: dict[str, list[dict[str, Any]]],
    tracked: set[str],
    path: object,
    reason: dict[str, Any],
) -> str | None:
    normalized = normalize_repo_path(path, tracked)
    if normalized is None:
        return None
    reasons.setdefault(normalized, []).append(reason)
    return normalized


def _prior_membership(prior: Mapping[str, Any], kind: str) -> Sequence[object]:
    """Read exact state membership when its index is authoritative.

    ``prior-coverage.json`` keeps capped display summaries for humans. The I/O
    collector merges exact lists from the compact membership artifact before
    calling this pure scorer. A corrupt index is explicitly unknown and must
    not be interpreted as "nothing" or as a truncated list. Legacy artifacts
    without the new status contract retain their old capped behavior.
    """

    exact_key = f"files_audited_{kind}_catalog_exact"
    status = prior.get("audit_membership")
    if isinstance(status, Mapping) and status.get("status") == "exact":
        exact = prior.get(exact_key)
        return exact if isinstance(exact, list) else []
    if status is None:
        legacy = prior.get(f"files_audited_{kind}_catalog")
        return legacy if isinstance(legacy, list) else []
    return []


def build_priority_context(
    *,
    tracked_files: Sequence[str],
    current_head: str | None,
    previous_head: str | None,
    change_window: Mapping[str, str],
    content_changed: Collection[str],
    history_records: Sequence[Mapping[str, Any]],
    recent_commits: Sequence[Mapping[str, Any]],
    baseline: Mapping[str, Any] | None,
    baseline_file_hits: Mapping[str, Sequence[str]],
    exposure: Mapping[str, Mapping[str, Any]],
    prior_coverage: Mapping[str, Any] | None,
    reopened: Collection[str],
    variant_matches: Collection[str],
    issue_signals: Sequence[Mapping[str, Any]],
    project_signals: Sequence[Mapping[str, Any]],
    critical_globs: Sequence[str],
    max_targets: int = 50,
    promotion_limit: int = 8,
    max_reasons: int = 5,
    max_glob_matches: int = 25,
    promotion_file_budget: int = 200,
    source_status: Mapping[str, str] | None = None,
    signal_health: Mapping[str, int] | None = None,
    unmapped_focus_signals: Sequence[Mapping[str, Any]] = (),
    signal_yield: Sequence[Mapping[str, Any]] = (),
) -> dict[str, Any]:
    """Merge normalized local evidence into a deterministic ranked artifact."""

    tracked = {f for f in tracked_files if isinstance(f, str) and f}
    targets_cap = _bounded_int(max_targets, 50, 1, HARD_MAX_TARGETS)
    reason_cap = _bounded_int(max_reasons, 5, 1, HARD_MAX_REASONS)
    promotion_cap = _bounded_int(promotion_limit, 8, 0, HARD_MAX_PROMOTION_BATCHES)
    promotion_files_cap = _bounded_int(promotion_file_budget, 200, 0, 1_000)
    glob_cap = _bounded_int(max_glob_matches, 25, 1, HARD_MAX_GLOB_MATCHES)

    reasons: dict[str, list[dict[str, Any]]] = {}
    lanes: dict[str, int] = {}
    changed_now: set[str] = set()
    changed_content: set[str] = set()
    overmatched_globs: list[str] = []

    for raw_path, raw_kind in sorted(change_window.items()):
        path = normalize_repo_path(raw_path, tracked)
        if path is None:
            continue
        changed_now.add(path)
        _append_reason(
            reasons,
            tracked,
            path,
            _reason(
                "changed_since_last_run",
                "change_likelihood",
                10,
                "git_diff",
                "changed since the last finalized Bugsweep run",
                {"change_kind": sanitize_text(raw_kind, 32)},
            ),
        )
        _set_lane(lanes, path, "elevated")

    for raw_path in sorted(content_changed):
        path = normalize_repo_path(raw_path, tracked)
        if path is None:
            continue
        changed_content.add(path)
        _append_reason(
            reasons,
            tracked,
            path,
            _reason(
                "content_changed_since_audit",
                "change_likelihood",
                15,
                "audit_fingerprint",
                "content changed since this file's last completed hunt",
            ),
        )
        _set_lane(lanes, path, "high")

    history_by_file: dict[str, Mapping[str, Any]] = {}
    for record in history_records:
        path = normalize_repo_path(record.get("file"), tracked)
        if path is None:
            continue
        previous = history_by_file.get(path)
        if previous is None or _bounded_float(record.get("history_score")) > _bounded_float(
            previous.get("history_score")
        ):
            history_by_file[path] = record

    for path in sorted(history_by_file):
        record = history_by_file[path]
        commits = _bounded_int(record.get("commits"), 0, 0, 20)
        fixes = _bounded_int(record.get("fix_commits"), 0, 0, 10)
        score = min(1.0, _bounded_float(record.get("history_score")))
        if commits:
            _append_reason(
                reasons,
                tracked,
                path,
                _reason(
                    "git_history",
                    "change_likelihood",
                    max(1, min(4, round(score * 4))),
                    "git_history",
                    "bounded Git history shows elevated change pressure",
                    {"commits": commits, "fix_commits": fixes, "history_score": round(score, 3)},
                ),
            )
            _set_lane(lanes, path, "elevated")
        if fixes:
            _append_reason(
                reasons,
                tracked,
                path,
                _reason(
                    "fix_history",
                    "recurrence_learning",
                    min(10, 2 + fixes * 2),
                    "git_history",
                    "recent history repeatedly repairs this file",
                    {"fix_commits": fixes},
                ),
            )
            _set_lane(lanes, path, "high" if fixes >= 2 else "elevated")

    fix_counts: dict[str, int] = {}
    revert_counts: dict[str, int] = {}
    recent_repairs: list[dict[str, Any]] = []
    for commit in recent_commits:
        kind = str(commit.get("kind") or "change").lower()
        if kind not in {"fix", "revert", "hotfix", "change"}:
            kind = "change"
        files = sorted(
            {
                normalized
                for raw in (commit.get("files") or [])
                if (normalized := normalize_repo_path(raw, tracked)) is not None
            }
        )
        if kind in {"fix", "hotfix", "revert"} and files:
            recent_repairs.append(
                {
                    "commit": sanitize_text(commit.get("sha"), 40),
                    "kind": kind,
                    "files": files,
                }
            )
        for path in files:
            if kind in {"fix", "hotfix"}:
                fix_counts[path] = fix_counts.get(path, 0) + 1
            elif kind == "revert":
                revert_counts[path] = revert_counts.get(path, 0) + 1

    for path in sorted(set(fix_counts) | set(revert_counts)):
        fixes = min(10, fix_counts.get(path, 0))
        reverts = min(5, revert_counts.get(path, 0))
        if fixes:
            _append_reason(
                reasons,
                tracked,
                path,
                _reason(
                    "fix_history",
                    "recurrence_learning",
                    min(10, 2 + fixes * 2),
                    "recent_commits",
                    "recent commits repeatedly repair this file",
                    {"fix_commits": fixes},
                ),
            )
        if reverts:
            _append_reason(
                reasons,
                tracked,
                path,
                _reason(
                    "revert_history",
                    "change_likelihood",
                    min(10, 5 + reverts * 2),
                    "recent_commits",
                    "recent work in this file was reverted",
                    {"revert_commits": reverts},
                ),
            )
            _set_lane(lanes, path, "high")

    exposure_by_file: dict[str, Mapping[str, Any]] = {}
    for raw_path, item in exposure.items():
        path = normalize_repo_path(raw_path, tracked)
        if path is None:
            continue
        exposure_by_file[path] = item
        bucket = str(item.get("bucket") or "COLD").upper()
        if bucket == "LIVE":
            code, points, summary, lane = (
                "live_sink",
                15,
                "a sensitive sink is reachable from an untrusted entry",
                "high",
            )
        elif bucket == "MAYBE":
            code, points, summary, lane = (
                "maybe_sink",
                8,
                "a sensitive sink may be reachable at import granularity",
                "elevated",
            )
        else:
            code, points, summary, lane = (
                "cold_sink",
                2,
                "a sensitive sink exists but no live path was observed",
                "elevated",
            )
        _append_reason(
            reasons,
            tracked,
            path,
            _reason(
                code,
                "reachability",
                points,
                "exposure",
                summary,
                {
                    "bucket": bucket if bucket in {"LIVE", "MAYBE", "COLD"} else "COLD",
                    "sink_class": sanitize_text(item.get("top_class"), 40),
                    "weight": _bounded_int(item.get("weight"), 0, 0, 5),
                },
            ),
        )
        _set_lane(lanes, path, lane)

    prior = prior_coverage or {}
    for item in prior.get("high_risk_files", []) or []:
        if not isinstance(item, Mapping):
            continue
        path = normalize_repo_path(item.get("file"), tracked)
        if path is None:
            continue
        risk = _bounded_float(item.get("score"))
        event_score_present = "event_score" in item
        event_score = _bounded_float(item.get("event_score")) if event_score_present else 0.0
        _append_reason(
            reasons,
            tracked,
            path,
            _reason(
                "prior_bug_history",
                "recurrence_learning",
                min(10, max(1, round(risk * 3))),
                "bugsweep_state",
                "earlier Bugsweep runs found risk in this file",
                {
                    "decayed_risk_score": round(risk, 3),
                    "event_score": round(event_score, 3) if event_score_present else None,
                    "provenance": "confirmed_outcome"
                    if event_score > 0
                    else "legacy_or_history_only",
                },
            ),
        )
        # Only confirmed/fixed/quarantined outcome provenance can promote. Old
        # artifacts without provenance remain useful ordering hints, but may be
        # pure Git churn and therefore stay elevated.
        _set_lane(lanes, path, "high" if event_score > 0 else "elevated")

    for raw_path in _prior_membership(prior, "stale"):
        path = _append_reason(
            reasons,
            tracked,
            raw_path,
            _reason(
                "stale_audit",
                "audit_staleness",
                5,
                "bugsweep_state",
                "the prior hunt is stale under the current catalog or run age",
            ),
        )
        if path:
            _set_lane(lanes, path, "elevated")

    for raw_path in sorted(reopened):
        path = _append_reason(
            reasons,
            tracked,
            raw_path,
            _reason(
                "reopened_conclusion",
                "active_evidence",
                25,
                "conclusions",
                "a prior safety conclusion was invalidated by changed evidence",
            ),
        )
        if path:
            _set_lane(lanes, path, "must_focus")

    for raw_path in sorted(variant_matches):
        path = _append_reason(
            reasons,
            tracked,
            raw_path,
            _reason(
                "variant_match",
                "recurrence_learning",
                10,
                "variants",
                "the file matches a transferable pattern from a confirmed bug",
            ),
        )
        if path:
            _set_lane(lanes, path, "must_focus")

    failing_checks: list[str] = []
    no_checks = False
    if baseline:
        no_checks = str(baseline.get("has_any_check") or "yes").lower() == "no"
        for check in baseline.get("checks", []) or []:
            if not isinstance(check, Mapping) or str(check.get("status")) != "fail":
                continue
            name = sanitize_text(check.get("check"), 40)
            if name:
                failing_checks.append(name)
    failing_checks = sorted(set(failing_checks))
    for check in failing_checks:
        for raw_path in baseline_file_hits.get(check, []) or []:
            path = _append_reason(
                reasons,
                tracked,
                raw_path,
                _reason(
                    "baseline_failure",
                    "active_evidence",
                    25,
                    "baseline",
                    f"the baseline {check} check is failing and names this file",
                    {"check": check, "stability": "unknown"},
                ),
            )
            if path:
                _set_lane(lanes, path, "must_focus")

    normalized_issues = sorted(
        issue_signals,
        key=lambda item: (
            _bounded_int(item.get("priority"), 3, 0, 4),
            sanitize_text(item.get("id"), 80),
        ),
    )
    mapped_issue_count = 0
    for issue in normalized_issues:
        issue_id = sanitize_text(issue.get("id"), 80)
        priority = _bounded_int(issue.get("priority"), 3, 0, 4)
        for raw_path in issue.get("files", []) or []:
            path = _append_reason(
                reasons,
                tracked,
                raw_path,
                _reason(
                    "local_bug_issue",
                    "active_evidence",
                    _priority_points(priority),
                    "local_issues",
                    "an open repository-local bug points at this file",
                    {"issue_id": issue_id, "priority": priority},
                ),
            )
            if path:
                mapped_issue_count += 1
                _set_lane(lanes, path, "high" if priority <= 2 else "elevated")

    normalized_project_signals = sorted(
        project_signals,
        key=lambda item: (
            sanitize_text(item.get("kind"), 40),
            sanitize_text(item.get("id"), 80),
        ),
    )
    for signal in normalized_project_signals:
        kind = sanitize_text(signal.get("kind"), 40).lower() or "project_priority"
        severity = sanitize_text(signal.get("severity"), 16).lower() or "low"
        signal_id = sanitize_text(signal.get("id"), 80)
        confidence = _bounded_int(signal.get("confidence"), 50, 0, 100)
        source = sanitize_text(signal.get("source"), 80)
        if kind in {"incident", "runtime_incident"}:
            code, summary = "active_incident", "an active runtime incident points at this file"
        elif kind in {"release_blocker", "regression"}:
            code, summary = (
                "release_blocker",
                "an active release-blocking regression points at this file",
            )
        else:
            code, summary = "project_priority", "an explicit project priority points at this file"
        raw_files = signal.get("files")
        if not isinstance(raw_files, Sequence) or isinstance(raw_files, (str, bytes)):
            raw_files = []
        for raw_path in raw_files:
            active_points = max(1, round(_severity_points(severity) * confidence / 100.0))
            path = _append_reason(
                reasons,
                tracked,
                raw_path,
                _reason(
                    code,
                    "active_evidence" if code != "project_priority" else "impact_value",
                    active_points,
                    "project_signals",
                    summary,
                    {
                        "signal_id": signal_id,
                        "source": source,
                        "kind": kind,
                        "severity": severity,
                        "confidence": confidence,
                        "observed_at": signal.get("observed_at"),
                        "expires_at": signal.get("expires_at"),
                        "environment": sanitize_text(signal.get("environment"), 40),
                        "release": sanitize_text(signal.get("release"), 80),
                    },
                ),
            )
            if path:
                affected_users = _bounded_int(signal.get("affected_users"), 0, 0, 1_000_000_000)
                occurrences = _bounded_int(signal.get("occurrence_count"), 0, 0, 1_000_000_000)
                impact_points = 0
                if affected_users >= 1_000:
                    impact_points += 20
                elif affected_users >= 100:
                    impact_points += 15
                elif affected_users > 0:
                    impact_points += 8
                if occurrences >= 1_000:
                    impact_points += 10
                elif occurrences >= 100:
                    impact_points += 6
                elif occurrences > 0:
                    impact_points += 3
                if impact_points:
                    _append_reason(
                        reasons,
                        tracked,
                        path,
                        _reason(
                            "user_impact",
                            "impact_value",
                            min(30, impact_points),
                            "project_signals",
                            "bounded production-impact metrics point at this file",
                            {
                                "signal_id": signal_id,
                                "affected_users": affected_users,
                                "occurrence_count": occurrences,
                            },
                        ),
                    )
                if (
                    code in {"active_incident", "release_blocker"}
                    and severity in {"critical", "high"}
                    and confidence >= 70
                ):
                    _set_lane(lanes, path, "must_focus")
                elif code in {"active_incident", "release_blocker"} and severity in {
                    "critical",
                    "high",
                    "medium",
                }:
                    _set_lane(lanes, path, "high")
                elif code == "project_priority" and severity in {"critical", "high"}:
                    _set_lane(lanes, path, "high")
                else:
                    _set_lane(lanes, path, "elevated" if severity == "medium" else "normal")

    for raw_glob in sorted({sanitize_text(g, HARD_TEXT_CAP) for g in critical_globs if g}):
        matches = sorted(path for path in tracked if fnmatch.fnmatchcase(path, raw_glob))
        if len(matches) > glob_cap:
            overmatched_globs.append(raw_glob)
            continue
        for path in matches:
            _append_reason(
                reasons,
                tracked,
                path,
                _reason(
                    "critical_path",
                    "impact_value",
                    30,
                    "configured_priority",
                    "the project explicitly marks this path as business-critical",
                    {"glob": raw_glob},
                ),
            )
            _set_lane(lanes, path, "high")

    changed_tests = {path for path in changed_now if _is_test_path(path)}
    if changed_now and not changed_tests:
        for path in sorted(changed_now):
            if _is_test_path(path):
                continue
            _append_reason(
                reasons,
                tracked,
                path,
                _reason(
                    "runtime_without_test_change",
                    "change_likelihood",
                    2,
                    "git_diff",
                    "runtime code changed without a test-file change in the same window",
                ),
            )

    # A changed LIVE sink is the strongest locally-provable hard focus lane.
    for path in sorted((changed_now | changed_content) & set(exposure_by_file)):
        if str(exposure_by_file[path].get("bucket") or "").upper() == "LIVE":
            _set_lane(lanes, path, "must_focus")

    rendered: list[dict[str, Any]] = []
    omitted_reasons = 0
    for path in sorted(reasons):
        by_code: dict[str, dict[str, Any]] = {}
        for item in reasons[path]:
            code = str(item["code"])
            current = by_code.get(code)
            if current is None or int(item["raw_points"]) > int(current["raw_points"]):
                by_code[code] = item
        ordered = sorted(
            by_code.values(),
            key=lambda item: (_REASON_ORDER.get(str(item["code"]), 999), str(item["code"])),
        )
        breakdown = {name: 0 for name in CATEGORY_CAPS}
        scored: list[tuple[dict[str, Any], int]] = []
        # Score ALL normalized reasons first. Output-size tuning must never
        # alter rank. Within a category, stronger evidence consumes the cap
        # first; reason order only breaks equal-strength ties.
        score_order = sorted(
            ordered,
            key=lambda item: (
                str(item["category"]),
                -int(item["raw_points"]),
                _REASON_ORDER.get(str(item["code"]), 999),
            ),
        )
        for item in score_order:
            category = str(item["category"])
            remaining = CATEGORY_CAPS[category] - breakdown[category]
            contribution = max(0, min(remaining, int(item["raw_points"])))
            breakdown[category] += contribution
            scored.append((item, contribution))

        lane_rank = lanes.get(path, LANE_RANK["normal"])
        lane = next(name for name, rank in LANE_RANK.items() if rank == lane_rank)
        preferred_codes = _MUST_FOCUS_REASON_CODES if lane == "must_focus" else _LANE_REASON_CODES
        display_order = sorted(
            scored,
            key=lambda pair: (
                str(pair[0]["code"]) not in preferred_codes,
                pair[1] == 0,
                -pair[1],
                _REASON_ORDER.get(str(pair[0]["code"]), 999),
                str(pair[0]["code"]),
            ),
        )
        selected = display_order[:reason_cap]
        omitted_reasons += max(0, len(display_order) - len(selected))
        rendered_reasons: list[dict[str, Any]] = []
        for item, contribution in selected:
            category = str(item["category"])
            rendered_reasons.append(
                {
                    "code": item["code"],
                    "category": category,
                    "contribution": contribution,
                    "source": item["source"],
                    "evidence": item["evidence"],
                }
            )
        if not rendered_reasons:
            continue
        score = sum(breakdown.values())
        summaries = [str(item["summary"]) for item, _ in selected[:3]]
        why_now = "; ".join(summaries)
        if why_now:
            why_now = why_now[0].upper() + why_now[1:] + "."
        rendered.append(
            {
                "file": path,
                "lane": lane,
                "priority_score": score,
                "breakdown": breakdown,
                # Closed codes for outcome attribution are independent of the
                # display-only reason cap. They carry no prose and never change
                # ranking; later ledger events must explicitly cite the codes
                # that seeded a candidate before yield can credit them.
                "attribution_reason_codes": [str(item["code"]) for item in ordered],
                "reasons": rendered_reasons,
                "why_now": why_now,
                "promotion_candidate": lane in {"must_focus", "high"},
            }
        )

    rendered.sort(
        key=lambda item: (
            LANE_RANK[str(item["lane"])],
            -int(item["priority_score"]),
            str(item["file"]),
        )
    )
    total_targets = len(rendered)
    visible_targets = rendered[:targets_cap]
    # Hard-focus and high-value evidence may enter the current run, but only
    # through this explicit bounded list.  Elevated recency/churn alone never
    # clears a large-repo deferral.
    promotions = [item["file"] for item in visible_targets if item["promotion_candidate"]][
        :HARD_MAX_PROMOTION_CANDIDATES
    ]
    promotion_set = set(promotions)
    for item in visible_targets:
        item["promotion_candidate"] = item["file"] in promotion_set

    recent_repairs.sort(key=lambda item: (str(item["commit"]), str(item["kind"])))
    recent_repairs = recent_repairs[:50]

    return {
        "schema_version": SCHEMA_VERSION,
        "scope_contract": "priority_only_frozen_invocation_scope_remains_in_scope",
        "generated_from": {
            "head": sanitize_text(current_head, 40) or None,
            "previous_run_head": sanitize_text(previous_head, 40) or None,
            "prior_runs": _bounded_int(prior.get("prior_runs"), 0, 0, 1_000_000),
        },
        "source_status": dict(sorted((source_status or {}).items())),
        "project_signals": {
            "failing_checks": failing_checks,
            "baseline_stability": "unknown" if (not baseline or failing_checks) else "not_applicable",
            "no_checks": no_checks,
            "mapped_local_issue_count": mapped_issue_count,
            "external_signal_count": len(normalized_project_signals),
            "overmatched_globs": overmatched_globs,
            "signal_health": dict(sorted((signal_health or {}).items())),
            "unmapped_focus_signals": [dict(item) for item in unmapped_focus_signals[:20]],
            "signal_yield": [dict(item) for item in signal_yield[:50]],
        },
        "recent_repairs": recent_repairs,
        "promotion_budget": {
            "max_batches": promotion_cap,
            "max_files": promotion_files_cap,
        },
        "promotion_candidates": promotions,
        "targets": visible_targets,
        "truncated": {
            "targets_omitted": max(0, total_targets - len(visible_targets)),
            "reasons_omitted": omitted_reasons,
        },
    }


def reprioritize_recon(
    recon: Mapping[str, Any], context: Mapping[str, Any], *,
    fresh_audited_files: Sequence[str] = (),
) -> dict[str, Any]:
    """Reorder an existing recon plan without changing its file scope.

    Only files already present in ``recon`` can influence ordering.  A bounded
    ``promotion_candidates`` list may promote matching batches to ``critical``
    and clear ``deferred``; every other field, batch, and file is retained.
    """

    result = deepcopy(dict(recon))
    raw_batches = result.get("batches")
    if not isinstance(raw_batches, list):
        raise ValueError("recon batches must be an array")

    batches: list[dict[str, Any]] = []
    seen_batch_ids: set[str] = set()
    file_to_batch: dict[str, int] = {}
    for index, raw_batch in enumerate(raw_batches):
        if not isinstance(raw_batch, Mapping):
            raise ValueError(f"recon batch {index} must be an object")
        batch = deepcopy(dict(raw_batch))
        if "id" not in batch:
            raise ValueError(f"recon batch {index} has no id")
        batch_id = str(batch["id"])
        if batch_id in seen_batch_ids:
            raise ValueError(f"duplicate recon batch id: {batch_id}")
        seen_batch_ids.add(batch_id)
        raw_files = batch.get("files")
        if not isinstance(raw_files, list) or not all(isinstance(path, str) for path in raw_files):
            raise ValueError(f"recon batch {batch_id} files must be a string array")
        for path in raw_files:
            if path in file_to_batch:
                raise ValueError(f"recon file appears in multiple batches: {path}")
            file_to_batch[path] = index
        batches.append(batch)

    bounded = result.get("large_repo_mode") is True
    budget = result.get("budget_batches")
    covered = result.get("covered", [])
    if bounded and (type(budget) is not int or budget < 0
                    or not isinstance(covered, list)
                    or any(type(value) is not int or str(value) not in seen_batch_ids for value in covered)
                    or any(type(batch["id"]) is not int or batch["id"] < 1 for batch in batches)):
        raise ValueError("invalid bounded admission budget or progress")
    fresh = {path for path in fresh_audited_files if isinstance(path, str) and path in file_to_batch}

    def all_fresh(batch: Mapping[str, Any]) -> bool:
        return bool(batch["files"]) and all(path in fresh for path in batch["files"])

    # Admission belongs to the run, not to each application/checkpoint. Reusing
    # this receipt prevents a resume from admitting another base budget after
    # earlier batches have been covered.
    if bounded and "admission" in result:
        admission = result["admission"]
        if not isinstance(admission, Mapping) or admission.get("schema_version") != 1:
            raise ValueError("invalid frozen admission")
        base, extra = admission.get("base_batch_ids"), admission.get("promoted_batch_ids")
        if (not isinstance(base, list) or not isinstance(extra, list)
                or any(type(value) is not int or str(value) not in seen_batch_ids for value in base + extra)
                or len(set(base + extra)) != len(base + extra)
                or len(base) > budget or len(extra) > HARD_MAX_PROMOTION_BATCHES
                or sum(len(batch["files"]) for batch in batches if batch["id"] in extra) > 1_000
                or not set(covered).issubset(base + extra)):
            raise ValueError("frozen admission exceeds scope or budget")
        for batch in batches:
            batch["deferred"] = batch["id"] not in base + extra
        result["batches"] = batches
        return result

    def admit(ordered_batches: list[dict[str, Any]], eligible: set[str],
              max_batches: int = 0, max_files: int = 0) -> None:
        """Select a bounded base frontier, then freeze any explicit extension."""
        if not bounded:
            return
        base = list(dict.fromkeys(covered))
        if len(base) > budget:
            raise ValueError("covered work already exceeds the base admission budget")
        for batch in ordered_batches:
            if len(base) < budget and batch["id"] not in base:
                base.append(batch["id"])
        extra, added_files = [], 0
        for batch in ordered_batches:
            if batch["id"] in base or str(batch["id"]) not in eligible:
                continue
            size = len(batch["files"])
            if len(extra) < max_batches and added_files + size <= max_files:
                extra.append(batch["id"])
                added_files += size
        for batch in ordered_batches:
            batch["deferred"] = batch["id"] not in base + extra
        result["admission"] = {"schema_version": 1, "base_batch_ids": base,
                               "promoted_batch_ids": extra}

    # A degraded/empty artifact does not authorize reshuffling, but the final
    # admission guard still repairs model-cleared deferrals in its existing
    # order.
    if context.get("degraded") is True:
        if bounded:
            batches.sort(key=all_fresh)
        admit(batches, set())
        result["batches"] = batches
        return result
    if context.get("schema_version") != SCHEMA_VERSION or context.get("scope_contract") != (
        "priority_only_frozen_invocation_scope_remains_in_scope"
    ):
        raise ValueError("priority context contract is missing or unsupported")
    raw_targets = context.get("targets")
    if not isinstance(raw_targets, list):
        raise ValueError("priority targets must be an array")
    if len(raw_targets) > HARD_MAX_TARGETS:
        raise ValueError("priority targets exceed the hard cap")
    targets: dict[str, tuple[int, int, bool]] = {}
    for index, item in enumerate(raw_targets):
        if not isinstance(item, Mapping) or not isinstance(item.get("file"), str):
            raise ValueError(f"priority target {index} is malformed")
        path = str(item["file"])
        if path in targets:
            raise ValueError(f"duplicate priority target: {path}")
        lane = str(item.get("lane") or "")
        if lane not in LANE_RANK:
            raise ValueError(f"priority target {path} has an invalid lane")
        score = _bounded_int(item.get("priority_score"), 0, 0, 100)
        eligible = item.get("promotion_candidate") is True and lane in {"must_focus", "high"}
        targets[path] = (LANE_RANK[lane], score, eligible)

    raw_promotions = context.get("promotion_candidates")
    if not isinstance(raw_promotions, list):
        raise ValueError("promotion_candidates must be an array")
    if len(raw_promotions) > HARD_MAX_PROMOTION_CANDIDATES:
        raise ValueError("promotion_candidates exceed the hard cap")
    promotion_files: list[str] = []
    for value in raw_promotions:
        if not isinstance(value, str):
            raise ValueError("promotion candidate paths must be strings")
        if value in promotion_files:
            raise ValueError(f"duplicate promotion candidate: {value}")
        target = targets.get(value)
        if target is None or not target[2]:
            raise ValueError(f"promotion candidate is not an eligible target: {value}")
        promotion_files.append(value)

    raw_budget = context.get("promotion_budget")
    if not isinstance(raw_budget, Mapping):
        raise ValueError("promotion_budget must be an object")
    if not isinstance(raw_budget.get("max_batches"), int) or isinstance(
        raw_budget.get("max_batches"), bool
    ):
        raise ValueError("promotion_budget.max_batches must be an integer")
    if not isinstance(raw_budget.get("max_files"), int) or isinstance(
        raw_budget.get("max_files"), bool
    ):
        raise ValueError("promotion_budget.max_files must be an integer")
    max_batches = int(raw_budget["max_batches"])
    max_files = int(raw_budget["max_files"])
    if not 0 <= max_batches <= HARD_MAX_PROMOTION_BATCHES or not 0 <= max_files <= 1_000:
        raise ValueError("promotion budget exceeds hard bounds")
    covered_ids = {
        str(value)
        for value in (result.get("covered", []) or [])
        if isinstance(value, (str, int)) and not isinstance(value, bool)
    }
    if not targets:
        if bounded:
            batches.sort(key=all_fresh)
        admit(batches, set())
        result["batches"] = batches
        return result

    if bounded:
        eligible = {str(batches[file_to_batch[path]]["id"])
                    for path in promotion_files if path in file_to_batch}
        def order_key(batch: Mapping[str, Any]) -> tuple:
            evidence = [targets[path] for path in batch["files"] if path in targets]
            hard_focus = str(batch["id"]) in eligible
            return (
                all_fresh(batch) and not hard_focus,
                0 if hard_focus or batch.get("tier") == "critical" else 1,
                min((entry[0] for entry in evidence), default=99),
                -max((entry[1] for entry in evidence), default=0),
                TIER_RANK.get(str(batch.get("tier")), 1),
            )
        batches.sort(key=order_key)
        for batch in batches:
            if str(batch["id"]) in eligible:
                batch["tier"] = "critical"
        admit(batches, eligible, max_batches, max_files)
        result["batches"] = batches
        return result

    promoted_indexes: set[int] = set()
    added_files = 0
    for path in promotion_files:
        batch_index = file_to_batch.get(path)
        if batch_index is None or batch_index in promoted_indexes:
            continue
        batch = batches[batch_index]
        # Already-in-budget work needs no promotion and consumes no added-work
        # budget. Its target evidence can still reorder it inside its tier.
        if batch.get("deferred") is False or str(batch.get("id")) in covered_ids:
            continue
        batch_size = len(batch.get("files", []))
        if len(promoted_indexes) >= max_batches or added_files + batch_size > max_files:
            continue
        promoted_indexes.add(batch_index)
        added_files += batch_size

    sortable: list[tuple[tuple[int, int, int, int, int], dict[str, Any]]] = []
    for index, batch in enumerate(batches):
        original_tier = str(batch.get("tier") or "normal")
        promoted = index in promoted_indexes
        if promoted:
            batch["tier"] = "critical"
            batch["deferred"] = False
        files = batch.get("files", [])
        evidence = [targets[path] for path in files if path in targets]
        best_lane = min((entry[0] for entry in evidence), default=99)
        best_score = max((entry[1] for entry in evidence), default=0)
        if promoted:
            group = 1
        elif original_tier == "critical":
            group = 0
        else:
            group = 2
        key = (
            group,
            TIER_RANK.get(original_tier, 1) if group == 2 else 0,
            best_lane,
            -best_score,
            index,
        )
        sortable.append((key, batch))

    sortable.sort(key=lambda entry: entry[0])
    ordered_batches = [batch for _, batch in sortable]

    # Admission is decided only after the final evidence ordering. Stable
    # batch IDs identify work, but they must not pin the original first-pass
    # slice forever on warm runs. Preserve covered progress while selecting the
    # bounded base frontier from this final order; explicitly promoted batches
    # are the bounded extension selected above.
    admit(ordered_batches, {str(batches[index].get("id")) for index in promoted_indexes})

    result["batches"] = ordered_batches
    return result
