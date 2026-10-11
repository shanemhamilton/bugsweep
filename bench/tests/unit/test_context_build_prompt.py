"""Coordinator prompt contracts not enforced by the deterministic planner.

Batch sizing, exact membership, and admission are tested behaviorally in their
own unit/integration suites. These checks guard the handoff to those mechanisms.
"""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]


def test_context_calls_mechanical_admission_and_preserves_scope() -> None:
    text = (REPO_ROOT / "prompts/context-build.md").read_text()
    assert '"$SKILL_ROOT/scripts/recon-plan.sh"' in text
    assert '"$SKILL_ROOT/scripts/priority-context.sh" apply' in text
    assert "Do not clear `deferred` manually" in text
    assert "must never remove files" in text
    assert "capped" in text and "display sample" in text


def test_slice_review_precedes_next_modeling_batch() -> None:
    text = (REPO_ROOT / "prompts/context-build.md").read_text()
    loop = text.split("For each non-deferred batch, in `recon.json`'s order:", 1)[1]
    assert loop.index("Hunter → Skeptic → Referee") < loop.index("session.sh checkpoint")
    assert loop.index("session.sh checkpoint") < loop.index("before starting another batch")
    assert "Modeling must not add" in loop and "`covered`" in loop
    assert "Do not advance to another modeling" in loop


def test_slice_stop_routes_to_closeout_with_fix_cap_exception() -> None:
    text = (REPO_ROOT / "prompts/context-build.md").read_text()
    assert '"$SKILL_ROOT/scripts/guard.sh" "$RUN_DIR"' in text
    assert "'STOP fix_cap_reached'*) DETECT_ONLY_REMAINDER=1" in text
    assert 'STOP*) STOP_REASON="${guard_out#STOP }"; break' in text
    assert "Finalize and close" in text and "finalize.sh" in text


def test_detect_only_priority_is_a_separate_preparation_step() -> None:
    text = (REPO_ROOT / "SKILL.md").read_text()
    baseline = text.index('scripts/run_checks.sh" baseline')
    priority = text.index('scripts/priority-context.sh" build')
    assert baseline < priority
    assert "Build local priority evidence in every mode" in text[baseline:priority]
    assert "including detect-only when execution is" in text[baseline:priority]
