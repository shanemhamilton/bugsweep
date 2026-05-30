"""Tests for ``bench.scorer.leaderboard.render_leaderboard``.

The renderer is the most-attacked output: it must surface a 3-column per-case
table (bugsweep | baseline | ground-truth), detection rate with Wilson CIs, the
paired bugsweep−baseline delta WITH each arm's ERROR/SKIPPED counts beside it, a
headline LABELED ``bugsweep @ <commit>`` (never ``v0.1.0``), a post/pre-cutoff
split, and a provenance block enumerating every required field. These tests pin
each of those so a regression that drops one fails loudly.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.leaderboard import (  # noqa: E402
    PROVENANCE_FIELDS,
    render_leaderboard,
)
from bench.scorer.score import (  # noqa: E402
    DETECTED,
    ERROR,
    NOT_DETECTED,
    SKIPPED,
    CaseRunVerdict,
)


def _bs(case_id: str, verdict: str, *, post_cutoff: bool = True) -> CaseRunVerdict:
    return CaseRunVerdict(
        case_id=case_id, run=1, arm="bugsweep", verdict=verdict, post_cutoff=post_cutoff
    )


def _bl(case_id: str, verdict: str, *, post_cutoff: bool = True) -> CaseRunVerdict:
    return CaseRunVerdict(
        case_id=case_id, run=1, arm="baseline", verdict=verdict, post_cutoff=post_cutoff
    )


def _provenance() -> dict[str, object]:
    """A fully-populated provenance mapping (every enumerated field present)."""
    return {
        "runner_model_id": "claude-opus-4-7",
        "runner_cutoff_date": "2026-01-31",
        "judge_model_id": "gpt-x-judge",
        "judge_prompt_hash": "deadbeefcafef00d",
        "bugsweep_commit": "abc1234",
        "case_verified_shas": {"c-post": "1111111111111111111111111111111111111111"},
        "container_image_digest": "sha256:0123456789abcdef",
        "egress_proxy_image": "tinyproxy:1.11.1",
        "line_window": 10,
        "k": 3,
    }


def _ground_truths() -> dict[str, dict[str, object]]:
    return {
        "c-post": {"description": "post-cutoff sqli in users.py", "category": "security"},
        "c-pre": {"description": "pre-cutoff path traversal", "category": "security"},
    }


def _verdicts() -> tuple[list[CaseRunVerdict], list[CaseRunVerdict]]:
    bugsweep = [_bs("c-post", DETECTED), _bs("c-pre", DETECTED, post_cutoff=False)]
    baseline = [_bl("c-post", NOT_DETECTED), _bl("c-pre", DETECTED, post_cutoff=False)]
    return bugsweep, baseline


def _render() -> str:
    bugsweep, baseline = _verdicts()
    return render_leaderboard(
        bugsweep=bugsweep,
        baseline=baseline,
        ground_truths=_ground_truths(),
        provenance=_provenance(),
    )


# --- 3-column per-case table ------------------------------------------------


def test_three_column_table_header_renders() -> None:
    md = _render()
    assert "bugsweep" in md
    assert "baseline" in md
    assert "ground-truth" in md or "ground truth" in md


def test_three_column_table_shows_each_case_with_both_arm_verdicts() -> None:
    md = _render()
    # Each case id appears, with a row carrying both arms' verdicts side by side.
    assert "c-post" in md
    # The post case: bugsweep DETECTED, baseline NOT_DETECTED — both must show.
    rows = [line for line in md.splitlines() if "c-post" in line and "|" in line]
    assert rows, "expected a table row for c-post"
    row = rows[0]
    assert DETECTED in row
    assert NOT_DETECTED in row


# --- detection rate with Wilson CIs -----------------------------------------


def test_wilson_ci_rendered() -> None:
    md = _render()
    assert "Wilson" in md or "CI" in md or "95%" in md


# --- paired delta WITH per-arm ERROR/SKIPPED counts beside it ---------------


def _section(md: str, heading: str) -> str:
    """Return the markdown between ``heading`` and the next ``## `` heading."""
    lines = md.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == heading)
    body: list[str] = []
    for line in lines[start + 1 :]:
        if line.startswith("## "):
            break
        body.append(line)
    return "\n".join(body)


def test_paired_delta_and_per_arm_error_skipped_appear() -> None:
    bugsweep = [_bs("c-post", DETECTED), _bs("c-err", ERROR)]
    baseline = [_bl("c-post", NOT_DETECTED), _bl("c-skip", SKIPPED)]
    md = render_leaderboard(
        bugsweep=bugsweep,
        baseline=baseline,
        ground_truths={"c-post": {"description": "d", "category": "c"}},
        provenance=_provenance(),
    )
    assert "delta" in md.lower()
    # Per-arm ERROR/SKIPPED counts must be surfaced INSIDE the paired-delta
    # section — not merely somewhere in the document (e.g. a per-case cell).
    delta_section = _section(md, "## Paired delta (bugsweep − baseline)")
    assert "ERROR" in delta_section
    assert "SKIPPED" in delta_section
    # The bugsweep ERROR and baseline SKIPPED from the fixture are both counted.
    assert "ERROR: 1" in delta_section
    assert "SKIPPED: 1" in delta_section


# --- headline labeled `bugsweep @ <commit>`, never v0.1.0 -------------------


def test_headline_uses_bugsweep_at_commit_label() -> None:
    md = _render()
    assert "bugsweep @ " in md
    assert "bugsweep @ abc1234" in md


def test_headline_does_not_use_version_label() -> None:
    md = _render()
    assert "v0.1.0" not in md


# --- post/pre-cutoff split --------------------------------------------------


def test_post_pre_cutoff_split_renders() -> None:
    md = _render()
    lower = md.lower()
    assert "post-cutoff" in lower
    assert "pre-cutoff" in lower


# --- provenance block enumerates EVERY required field -----------------------


def test_provenance_block_contains_every_enumerated_field() -> None:
    md = _render()
    missing = [field for field in PROVENANCE_FIELDS if field not in md]
    assert not missing, f"provenance block missing fields: {missing}"


def test_provenance_block_shows_field_values() -> None:
    md = _render()
    prov = _provenance()
    # A representative sample of the actual values must be rendered, not just
    # the field labels.
    assert str(prov["runner_model_id"]) in md
    assert str(prov["judge_prompt_hash"]) in md
    assert str(prov["container_image_digest"]) in md
    assert str(prov["egress_proxy_image"]) in md
    assert str(prov["line_window"]) in md


def test_missing_provenance_field_renders_placeholder_not_crash() -> None:
    prov = _provenance()
    del prov["egress_proxy_image"]
    bugsweep, baseline = _verdicts()
    md = render_leaderboard(
        bugsweep=bugsweep,
        baseline=baseline,
        ground_truths=_ground_truths(),
        provenance=prov,
    )
    # The field LABEL still renders (enumerated), with an explicit unknown marker.
    assert "egress_proxy_image" in md
    assert "(unknown)" in md


def test_empty_mapping_provenance_field_renders_unknown() -> None:
    # A present-but-empty mapping (e.g. no verified SHAs yet) renders (unknown),
    # not an empty cell, so the enumeration stays honest.
    prov = _provenance()
    prov["case_verified_shas"] = {}
    bugsweep, baseline = _verdicts()
    md = render_leaderboard(
        bugsweep=bugsweep,
        baseline=baseline,
        ground_truths=_ground_truths(),
        provenance=prov,
    )
    sha_rows = [
        line for line in md.splitlines() if line.startswith("| case_verified_shas |")
    ]
    assert sha_rows
    assert "(unknown)" in sha_rows[0]


def test_blank_ground_truth_description_renders_unknown_cell() -> None:
    # A case whose ground truth has a blank description still gets a row; the
    # ground-truth cell shows (unknown) rather than an empty cell.
    bugsweep = [_bs("c-blank", DETECTED)]
    baseline = [_bl("c-blank", NOT_DETECTED)]
    md = render_leaderboard(
        bugsweep=bugsweep,
        baseline=baseline,
        ground_truths={"c-blank": {"description": "   ", "category": "security"}},
        provenance=_provenance(),
    )
    rows = [line for line in md.splitlines() if "c-blank" in line and "|" in line]
    assert rows
    assert "(unknown)" in rows[0]


# --- contamination split + majority aggregation labels present --------------


def test_majority_aggregation_label_present() -> None:
    md = _render()
    assert "majority" in md.lower()


# --- empty input does not crash ---------------------------------------------


def test_empty_verdicts_render_without_crash() -> None:
    md = render_leaderboard(
        bugsweep=[],
        baseline=[],
        ground_truths={},
        provenance=_provenance(),
    )
    assert "bugsweep @ abc1234" in md
    assert "post-cutoff" in md.lower()


# ── Precision track section ───────────────────────────────────────────────────

from bench.scorer.leaderboard import render_precision_section  # noqa: E402
from bench.scorer.precision import PrecisionCaseResult  # noqa: E402


def _precision_result(
    case_id: str = "c1",
    run: int = 1,
    arm: str = "bugsweep",
    total_confirmed: int = 5,
    sampled: int = 4,
    real: int = 3,
    precision: float = 0.75,
) -> PrecisionCaseResult:
    return PrecisionCaseResult(
        case_id=case_id,
        run=run,
        arm=arm,
        total_confirmed=total_confirmed,
        sampled=sampled,
        real=real,
        precision=precision,
        findings=(),
    )


def test_render_precision_section_empty_shows_placeholder() -> None:
    section = render_precision_section([])
    assert "## Precision track" in section
    assert "precision_score" in section


def test_render_precision_section_shows_arm_row() -> None:
    section = render_precision_section([_precision_result()])
    assert "## Precision track" in section
    assert "bugsweep" in section


def test_render_precision_section_shows_precision_percent() -> None:
    section = render_precision_section([_precision_result(real=3, sampled=4)])
    assert "75.0%" in section


def test_render_precision_section_aggregates_across_runs() -> None:
    results = [
        _precision_result("c1", 1, total_confirmed=5, sampled=4, real=3),
        _precision_result("c1", 2, total_confirmed=6, sampled=4, real=2),
    ]
    section = render_precision_section(results)
    assert "2" in section   # 2 case-runs
    assert "11" in section  # total confirmed (5+6)
    assert "8" in section   # sampled (4+4)
    assert "5" in section   # real (3+2)


def test_render_precision_section_zero_sample_shows_zero_percent() -> None:
    section = render_precision_section([_precision_result(sampled=0, real=0, precision=0.0)])
    assert "0.0%" in section


def test_render_leaderboard_includes_precision_section() -> None:
    results = [_precision_result(total_confirmed=10, sampled=5, real=4, precision=0.8)]
    md = render_leaderboard(
        bugsweep=[_bs("c-post", DETECTED)],
        baseline=[_bl("c-post", NOT_DETECTED)],
        ground_truths=_ground_truths(),
        provenance=_provenance(),
        precision_results=results,
    )
    assert "## Precision track" in md
    assert "80.0%" in md


def test_render_leaderboard_precision_defaults_to_placeholder() -> None:
    md = render_leaderboard(
        bugsweep=[_bs("c-post", DETECTED)],
        baseline=[_bl("c-post", NOT_DETECTED)],
        ground_truths=_ground_truths(),
        provenance=_provenance(),
    )
    assert "## Precision track" in md
    assert "precision_score" in md
