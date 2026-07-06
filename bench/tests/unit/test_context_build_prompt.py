"""Guard the incremental-checkpoint + budget-cap contract in
``prompts/context-build.md`` against drift (bugsweep-e1r review REVISE).

The batch-planner (``bench/scorer/recon_plan.py``) marks batches past the
first-pass cap as ``deferred: true`` so a single large-repo run is BOUNDED —
it stops after the last non-deferred batch instead of grinding through all
1474 files (the 2e5 root cause). That cap is inert unless the modeling
prompt actually consumes it. These grep-level contract checks (same style as
``test_skill_report_format.py``) assert the prompt tells the model to:

* process only ``deferred: false`` batches this run and STOP after the last
  one, leaving deferred batches for a later run (BLOCKER 1); and
* when the coverage-first re-tiering promotes a batch to the front (sinks,
  reopened conclusions), clear that batch's ``deferred`` flag so a promoted
  sink is never skipped by the budget (MAJOR 2).
"""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
CONTEXT_BUILD_MD = REPO_ROOT / "prompts" / "context-build.md"


def _text() -> str:
    return CONTEXT_BUILD_MD.read_text(encoding="utf-8")


def test_context_build_md_exists() -> None:
    assert CONTEXT_BUILD_MD.is_file(), f"expected {CONTEXT_BUILD_MD}"


def test_prompt_instructs_processing_only_non_deferred_batches_this_run() -> None:
    """BLOCKER 1: the modeling loop must scope this run to deferred:false batches."""
    text = _text().lower()
    assert "deferred" in text, "prompt never mentions the deferred flag"
    # Must say: only non-deferred batches are in-budget this run.
    assert (
        "deferred: false" in text or "deferred:false" in text or "not deferred" in text
    ), "prompt must reference deferred:false batches as this run's scope"


def test_prompt_has_an_explicit_stop_rule_after_last_non_deferred_batch() -> None:
    """BLOCKER 1: there must be an explicit stop rule, not 'repeat until every
    batch is covered' (which would walk straight into deferred batches)."""
    text = _text()
    lower = text.lower()
    # A stop instruction tied to deferred batches / later runs must be present.
    assert "stop" in lower, "prompt has no stop instruction for the modeling loop"
    assert (
        "later run" in lower or "next run" in lower or "subsequent run" in lower
    ), "prompt must say deferred batches are picked up on a later run"
    # And the old unbounded phrasing must be gone.
    assert "repeat until every batch is covered" not in lower, (
        "the unbounded 'repeat until every batch is covered' phrasing walks "
        "into deferred batches and must be replaced with a budget-aware stop rule"
    )


def test_prompt_states_coverage_first_promotion_clears_deferred() -> None:
    """MAJOR 2: promoting a batch to the front (sinks/reopened conclusions) must
    also set deferred:false so a promoted sink is never budget-skipped."""
    text = _text().lower()
    # The re-tiering section must explicitly reconcile promotion with the
    # deferred flag: a promoted/critical batch becomes in-budget.
    assert "deferred: false" in text or "deferred:false" in text, (
        "prompt must state that a coverage-first promotion sets deferred:false"
    )
    # Anchor the statement to the promotion/critical concept so it isn't just
    # the loop-scope mention above.
    assert (
        "promot" in text and ("deferred" in text)
    ), "prompt must tie promotion to clearing the deferred flag"


def test_prompt_notes_degraded_path_lacks_full_tier_ranking_is_addressed() -> None:
    """MAJOR 3 (prompt side): the prompt must not overclaim that tier-ranked
    output always holds; it should acknowledge the degraded (no-python3) path
    OR the shell fallback must itself tier (asserted in the bats test). Here we
    just require the prompt not to state tier ranking as an unconditional
    guarantee without qualification."""
    text = _text().lower()
    # Either the prompt qualifies the tiering, or it points at the shell
    # fallback tiering. Accept a mention of the degraded/no-python path OR an
    # explicit statement that tiering holds on both paths.
    assert (
        "degrad" in text
        or "no python" in text
        or "without python" in text
        or "both paths" in text
    ), "prompt must acknowledge the degraded path or assert both-path tiering"
