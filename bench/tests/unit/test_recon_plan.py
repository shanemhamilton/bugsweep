"""Tests for ``bench.scorer.recon_plan``.

Why this exists (bugsweep-e1r): ``prompts/context-build.md`` used to build
``repo-context.md`` + ``recon.json`` in a single, un-checkpointed pass. On a
large repo (1474 files) that pass stalled before ``recon.json`` was ever
written — leaving nothing to resume, reprioritize, or report (root cause
behind bead 2e5, "large repos fail silently"). ``recon_plan.py`` is the
deterministic, pure batch-planner that lets the caller write a valid
``recon.json`` from a file list BEFORE any modeling happens, so a run that
dies immediately after initialization still leaves a resumable, reportable
artifact on disk.

Design (see module docstring in ``bench/scorer/recon_plan.py`` for the
authoritative version):

* Files are grouped into batches by top-level subtree (first path segment
  that is a directory; files directly under the root form their own
  ``"."`` batch).
* Each batch gets a ``tier`` — ``critical`` for documented sink-ish dirs
  (auth/api/handlers/...), ``low`` for docs/asset-ish dirs, else ``normal``.
* Batches are ordered ``critical`` -> ``normal`` -> ``low``, tie-broken by
  directory name, for byte-identical determinism across runs.
* ``large_repo_mode`` activates from a file-count threshold (pure function
  over a count, no filesystem access).
* When large-repo mode is active, only the first ``cap`` ordered batches are
  eligible this pass; the rest are marked ``deferred: true`` so the
  coverage-first frontier (prior-coverage.json / state.sh) picks them up on
  a later run.

No network, no subprocess: everything here is pure functions over an
in-memory file list, mirroring bench/scorer/run_summary.py's style so this
module is unit-testable and coverage-gated the same way.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.recon_plan import (  # noqa: E402
    DEFAULT_FIRST_PASS_BATCHES,
    DEFAULT_FILE_THRESHOLD,
    SCHEMA_VERSION,
    build_plan,
    is_large_repo_mode,
)

try:
    import jsonschema

    HAVE_JSONSCHEMA = True
except ImportError:  # pragma: no cover - environment-dependent
    HAVE_JSONSCHEMA = False

SCHEMA_PATH = Path(__file__).resolve().parents[3] / "schemas" / "recon-plan.schema.json"


def _validate_against_schema(plan: dict) -> None:
    if not HAVE_JSONSCHEMA or not SCHEMA_PATH.is_file():  # pragma: no cover
        return
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    jsonschema.validate(instance=plan, schema=schema)


# ---------------------------------------------------------------------------
# is_large_repo_mode: pure function over a count, no filesystem needed.
# ---------------------------------------------------------------------------


def test_large_repo_mode_activates_above_threshold() -> None:
    assert is_large_repo_mode(file_count=801, threshold=800) is True


def test_large_repo_mode_inactive_at_threshold() -> None:
    # Boundary: exactly at the threshold is NOT "above" it.
    assert is_large_repo_mode(file_count=800, threshold=800) is False


def test_large_repo_mode_inactive_below_threshold() -> None:
    assert is_large_repo_mode(file_count=10, threshold=800) is False


def test_large_repo_mode_uses_documented_default_threshold() -> None:
    assert DEFAULT_FILE_THRESHOLD == 800
    assert is_large_repo_mode(file_count=801) is True
    assert is_large_repo_mode(file_count=800) is False


# ---------------------------------------------------------------------------
# build_plan: determinism
# ---------------------------------------------------------------------------


def test_plan_is_deterministic_for_fixed_tree() -> None:
    files = [
        "src/auth/login.py",
        "src/api/routes.py",
        "docs/readme.md",
        "src/utils/helpers.py",
        "assets/logo.png",
    ]
    plan_a = build_plan(files=files)
    plan_b = build_plan(files=list(reversed(files)))  # input order must not matter

    assert plan_a == plan_b
    assert json.dumps(plan_a, sort_keys=True) == json.dumps(plan_b, sort_keys=True)
    _validate_against_schema(plan_a)


def test_plan_stable_across_set_and_list_input() -> None:
    files_list = ["b/x.py", "a/y.py", "a/x.py"]
    files_set = set(files_list)

    plan_from_list = build_plan(files=files_list)
    plan_from_set = build_plan(files=files_set)

    assert plan_from_list == plan_from_set


def test_plan_every_file_appears_in_exactly_one_batch() -> None:
    files = ["a/1.py", "a/2.py", "b/1.py", "root.py"]
    plan = build_plan(files=files)

    seen: list[str] = []
    for batch in plan["batches"]:
        seen.extend(batch["files"])

    assert sorted(seen) == sorted(files)
    assert len(seen) == len(set(seen))


def test_plan_respects_exclusion_globs() -> None:
    files = [
        "src/app.py",
        "node_modules/pkg/index.js",
        "dist/bundle.js",
        "vendor/lib.go",
        ".git/HEAD",
        "src/x.min.js",
    ]
    plan = build_plan(
        files=files,
        exclude_globs=["node_modules/**", "dist/**", "vendor/**", ".git/**", "*.min.js"],
    )

    all_files = [f for batch in plan["batches"] for f in batch["files"]]
    assert "node_modules/pkg/index.js" not in all_files
    assert "dist/bundle.js" not in all_files
    assert "vendor/lib.go" not in all_files
    assert ".git/HEAD" not in all_files
    assert "src/x.min.js" not in all_files
    assert "src/app.py" in all_files
    assert plan["files_in_scope"] == 1


def test_plan_root_level_files_form_their_own_batch() -> None:
    files = ["README.md", "setup.py", "src/app.py"]
    plan = build_plan(files=files)

    root_batches = [b for b in plan["batches"] if b["dir"] == "."]
    assert len(root_batches) == 1
    assert sorted(root_batches[0]["files"]) == ["README.md", "setup.py"]


def test_plan_batch_ids_are_sequential_starting_at_one() -> None:
    files = ["a/1.py", "b/1.py", "c/1.py"]
    plan = build_plan(files=files)
    ids = [b["id"] for b in plan["batches"]]
    assert ids == list(range(1, len(ids) + 1))


def test_plan_covered_starts_empty() -> None:
    plan = build_plan(files=["a/1.py"])
    assert plan.get("covered", []) == []


def test_plan_schema_version_present() -> None:
    plan = build_plan(files=["a/1.py"])
    assert plan["schema_version"] == SCHEMA_VERSION


# ---------------------------------------------------------------------------
# Tier heuristics: documented sink-ish dirs sort ahead of docs/assets.
# ---------------------------------------------------------------------------


def test_tier_heuristic_places_auth_dir_in_critical_tier() -> None:
    plan = build_plan(files=["auth/login.py", "docs/readme.md"])
    by_dir = {b["dir"]: b["tier"] for b in plan["batches"]}
    assert by_dir["auth"] == "critical"
    assert by_dir["docs"] == "low"


def test_tier_heuristic_places_api_and_handlers_in_critical_tier() -> None:
    plan = build_plan(
        files=["api/routes.py", "handlers/webhook.py", "src/utils/misc.py"]
    )
    by_dir = {b["dir"]: b["tier"] for b in plan["batches"]}
    assert by_dir["api"] == "critical"
    assert by_dir["handlers"] == "critical"
    assert by_dir["src"] == "normal"


def test_tier_heuristic_critical_dirs_ordered_before_normal_and_low() -> None:
    files = ["assets/logo.png", "src/utils/misc.py", "auth/login.py"]
    plan = build_plan(files=files)
    tiers_in_order = [b["tier"] for b in plan["batches"]]
    # critical first, then normal, then low — deterministic total order.
    assert tiers_in_order == sorted(
        tiers_in_order, key=lambda t: {"critical": 0, "normal": 1, "low": 2}[t]
    )
    assert tiers_in_order[0] == "critical"
    assert tiers_in_order[-1] == "low"


def test_tier_heuristic_docs_and_assets_are_low_tier() -> None:
    plan = build_plan(files=["docs/a.md", "assets/b.png", "static/c.css", "public/d.html"])
    by_dir = {b["dir"]: b["tier"] for b in plan["batches"]}
    assert by_dir["docs"] == "low"
    assert by_dir["assets"] == "low"
    assert by_dir["static"] == "low"
    assert by_dir["public"] == "low"


def test_tier_heuristic_unmatched_dir_is_normal() -> None:
    plan = build_plan(files=["src/whatever.py"])
    by_dir = {b["dir"]: b["tier"] for b in plan["batches"]}
    assert by_dir["src"] == "normal"


def test_tier_ordering_is_tie_broken_by_dir_name_for_determinism() -> None:
    files = ["zeta/a.py", "alpha/b.py"]  # both "normal" tier
    plan = build_plan(files=files)
    dirs_in_order = [b["dir"] for b in plan["batches"]]
    assert dirs_in_order == ["alpha", "zeta"]


# ---------------------------------------------------------------------------
# large_repo_mode + deferred cap wiring inside build_plan
# ---------------------------------------------------------------------------


def test_build_plan_activates_large_repo_mode_and_caps_first_pass() -> None:
    # 5 dirs -> 5 batches; cap at 2 -> first 2 (by tier/dir order) eligible,
    # remaining 3 deferred. Force large_repo_mode via a low threshold since
    # file count here is small (threshold is a pure input, not tied to 800).
    files = [f"dir{i}/f.py" for i in range(5)]
    plan = build_plan(files=files, file_threshold=1, first_pass_batch_cap=2)

    assert plan["large_repo_mode"] is True
    assert plan["budget_batches"] == 2
    deferred_flags = [b["deferred"] for b in plan["batches"]]
    assert deferred_flags == [False, False, True, True, True]


def test_build_plan_no_deferral_when_not_large_repo_mode() -> None:
    files = [f"dir{i}/f.py" for i in range(5)]
    plan = build_plan(files=files, file_threshold=1000, first_pass_batch_cap=2)

    assert plan["large_repo_mode"] is False
    assert plan["budget_batches"] is None
    assert all(b["deferred"] is False for b in plan["batches"])


def test_build_plan_default_thresholds_match_documented_defaults() -> None:
    assert DEFAULT_FILE_THRESHOLD == 800
    assert DEFAULT_FIRST_PASS_BATCHES == 40


def test_build_plan_deferred_cap_does_not_drop_files_from_plan() -> None:
    # Deferred batches must still be present (and still enumerate their
    # files) -- capping affects priority/ordering metadata only, never
    # coverage. The whole repo stays in scope (context-build.md's
    # coverage-first contract).
    files = [f"dir{i}/f.py" for i in range(50)]
    plan = build_plan(files=files, file_threshold=1, first_pass_batch_cap=10)

    all_files = [f for b in plan["batches"] for f in b["files"]]
    assert sorted(all_files) == sorted(files)
    assert plan["files_in_scope"] == 50
    assert sum(1 for b in plan["batches"] if b["deferred"]) == 40


def test_build_plan_empty_file_list_produces_empty_valid_plan() -> None:
    plan = build_plan(files=[])
    assert plan["batches"] == []
    assert plan["files_in_scope"] == 0
    assert plan["batch_count"] == 0
    assert plan["large_repo_mode"] is False
    _validate_against_schema(plan)


def test_build_plan_result_is_json_serializable() -> None:
    plan = build_plan(files=["a/1.py", "auth/login.py", "docs/x.md"])
    # Must round-trip cleanly through json (no sets/tuples leaking out).
    round_tripped = json.loads(json.dumps(plan))
    assert round_tripped == plan
