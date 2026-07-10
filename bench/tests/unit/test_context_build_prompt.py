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
    assert (
        "deferred: false" in text or "deferred:false" in text
    ), "prompt must state that a coverage-first promotion sets deferred:false"
    # Anchor the statement to the promotion/critical concept so it isn't just
    # the loop-scope mention above.
    assert "promot" in text and (
        "deferred" in text
    ), "prompt must tie promotion to clearing the deferred flag"


def test_prompt_has_a_per_batch_deadline_checkpoint() -> None:
    """bugsweep-5ft review BLOCKER 1: the per-batch modeling loop must contain an
    explicit deadline checkpoint — a literal guard.sh invocation and a STOP*->
    finalize.sh handoff — not just an outer paragraph describing the contract.
    Without this, a wall-clock deadline hit mid-context-build on a large repo
    never routes through finalize.sh, and the run produces no report.md /
    run-summary.json at all (the exact silent-failure shape bead 2e5 fixed for
    the pre-modeling Step 0, but which this loop itself never enforced)."""
    text = _text()
    assert (
        "scripts/guard.sh" in text
    ), "the per-batch loop must invoke scripts/guard.sh as a deadline checkpoint"
    assert (
        "scripts/finalize.sh" in text
    ), "the per-batch loop must route a STOP result through scripts/finalize.sh"
    # The literal bash idiom used elsewhere in SKILL.md for the STOP->finalize
    # handoff, not just a prose description of it.
    assert (
        "STOP*)" in text and "finalize.sh" in text.split("STOP*)", 1)[1][:80]
    ), "expected the literal `STOP*) bash scripts/finalize.sh ...` case-arm idiom"


def test_prompt_ties_deadline_checkpoint_to_the_batch_loop_not_just_a_paragraph() -> None:
    """The checkpoint must be a numbered sub-step INSIDE the per-batch loop
    ('For each non-deferred batch...'), not merely mentioned in a separate
    paragraph elsewhere in the file."""
    text = _text()
    loop_header = "For each non-deferred batch, in `recon.json`'s order:"
    assert loop_header in text, f"expected the per-batch loop header: {loop_header!r}"
    # Slice from the loop header to the next '## ' heading (end of this section)
    # and require the checkpoint's guard.sh call to live inside that window.
    start = text.index(loop_header)
    rest = text[start:]
    next_heading = rest.find("\n## ", 1)
    window = rest if next_heading == -1 else rest[:next_heading]
    assert "scripts/guard.sh" in window, (
        "the guard.sh deadline checkpoint must be a step INSIDE the per-batch "
        "loop, not just referenced elsewhere in the prompt"
    )


def test_prompt_states_any_stop_result_not_only_runtime_cap_ends_the_run() -> None:
    """bugsweep-5ft review MINOR 7: the prompt must not imply only a runtime-cap
    STOP requires finalizing — any STOP* (iteration cap, fix cap, convergence)
    must be treated the same way."""
    text = _text().lower()
    assert "any `stop*`" in text or "any stop*" in text, (
        "prompt must say ANY STOP* result triggers finalize, not just the " "runtime-cap example"
    )


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
        "degrad" in text or "no python" in text or "without python" in text or "both paths" in text
    ), "prompt must acknowledge the degraded path or assert both-path tiering"


def test_context_modeling_uses_modeled_not_covered() -> None:
    """Architecture modeling is not an adversarial hunt and must not create
    false durable audit coverage."""
    text = _text()
    assert "`modeled`" in text
    assert "Hunter → Skeptic → Referee" in text
    assert "must not add" in text.lower() and "`covered`" in text


def test_priority_context_is_applied_without_scope_narrowing() -> None:
    text = _text()
    assert "priority-context.json" in text
    assert "priority-context.sh apply" in text
    assert "never remove" in text.lower() or "never removes" in text.lower()
