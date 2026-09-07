"""Focused fault checks for the durable terminal lifecycle."""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from scripts._terminal_lifecycle import (  # noqa: E402
    LifecycleError,
    advance_closeout,
    initialize_closeout,
    read_run_status,
    write_terminal_receipt,
)


def _state(run: Path) -> dict[str, str]:
    return {
        "BUGSWEEP_RUN_ID": "run-1",
        "BUGSWEEP_BRANCH": "bugsweep/run-1",
        "BUGSWEEP_ORIG_BRANCH": "main",
        "BUGSWEEP_WORKTREE": str(run / "worktree"),
    "BUGSWEEP_ORIG_HEAD": "a" * 40,
        "BUGSWEEP_REPO_ROOT": str(run.parent / "repo"),
        "BUGSWEEP_RUN_DIR": str(run),
    }


def test_closeout_is_monotonic_and_receipt_is_last(tmp_path: Path) -> None:
    run = tmp_path / "run"
    run.mkdir()
    state = _state(run)
    initialize_closeout(run, state, "PENDING_CLOSEOUT")

    with __import__("pytest").raises(LifecycleError, match="cannot skip"):
        advance_closeout(run, state, "BRANCH_REMOVED")

    advance_closeout(run, state, "READY_FOR_CLEANUP")
    advance_closeout(run, state, "WORKTREE_REMOVED")
    advance_closeout(run, state, "BRANCH_REMOVED")
    advance_closeout(run, state, "RECEIPT_PENDING")
    assert read_run_status(run, state)["exit_code"] == 10

    receipt = write_terminal_receipt(run, state, "COMPLETED_RECORDED")
    assert receipt["outcome"] == "COMPLETED_RECORDED"
    assert read_run_status(run, state)["exit_code"] == 2


def test_completed_status_requires_exact_absence_and_rejects_replay(tmp_path: Path) -> None:
    from scripts._terminal_lifecycle import record_absence_observation

    run = tmp_path / "run"; run.mkdir()
    state = _state(run)
    initialize_closeout(run, state, "PENDING_CLOSEOUT")
    for stage in ("READY_FOR_CLEANUP", "WORKTREE_REMOVED", "BRANCH_REMOVED", "RECEIPT_PENDING"):
        advance_closeout(run, state, stage)
    write_terminal_receipt(run, state, "COMPLETED_RECORDED")
    assert read_run_status(run, state)["exit_code"] == 2
    Path(state["BUGSWEEP_WORKTREE"]).mkdir()
    with __import__("pytest").raises(LifecycleError, match="worktree remains"):
        record_absence_observation(run, state)
    Path(state["BUGSWEEP_WORKTREE"]).rmdir()
    Path(state["BUGSWEEP_WORKTREE"]).symlink_to(run / "missing-target")
    with __import__("pytest").raises(LifecycleError, match="worktree remains"):
        record_absence_observation(run, state)
    Path(state["BUGSWEEP_WORKTREE"]).unlink()
    record_absence_observation(run, state)
    assert read_run_status(run, state)["exit_code"] == 0
    block = Path(state["BUGSWEEP_REPO_ROOT"]) / ".bugsweep/state/closeout-blocked"
    block.mkdir(parents=True)
    (block / "run-1.json").write_text("{}", encoding="utf-8")
    assert read_run_status(run, state)["exit_code"] == 10
    (block / "run-1.json").unlink()
    copied = tmp_path / "copied"; copied.mkdir()
    for name in ("closeout-marker.json", "terminal-receipt.json", "absence-observation.json"):
        (copied / name).write_bytes((run / name).read_bytes())
    assert read_run_status(copied, state)["exit_code"] == 2


def test_receipt_pending_recovers_and_bad_utf8_or_schema_is_invalid(tmp_path: Path) -> None:
    run = tmp_path / "run"; run.mkdir()
    state = _state(run)
    initialize_closeout(run, state, "PENDING_CLOSEOUT")
    for stage in ("READY_FOR_CLEANUP", "WORKTREE_REMOVED", "BRANCH_REMOVED", "RECEIPT_PENDING"):
        advance_closeout(run, state, stage)
    receipt = {"schema_version": 1, "outcome": "COMPLETED_RECORDED", "identity": __import__("scripts._terminal_lifecycle", fromlist=["_identity"])._identity(state)}
    (run / "terminal-receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
    write_terminal_receipt(run, state, "COMPLETED_RECORDED")
    assert read_run_status(run, state)["exit_code"] == 2
    (run / "terminal-receipt.json").write_text(json.dumps({**receipt, "schema_version": 999}), encoding="utf-8")
    assert read_run_status(run, state)["exit_code"] == 2
    (run / "state.env").write_bytes(b"\xff")
    assert read_run_status(run)["exit_code"] == 2


def test_missing_worktree_key_is_invalid_but_empty_is_allowed(tmp_path: Path) -> None:
    run = tmp_path / "run"; run.mkdir()
    state = _state(run)
    state["BUGSWEEP_WORKTREE"] = ""
    initialize_closeout(run, state, "PENDING_CLOSEOUT")
    (run / "state.env").write_text(
        "\n".join(f"{key}='{value}'" for key, value in state.items() if key != "BUGSWEEP_WORKTREE"),
        encoding="utf-8",
    )
    assert read_run_status(run)["exit_code"] == 2


def test_run_directory_identity_accepts_an_absolute_symlink_alias(tmp_path: Path) -> None:
    real_run = tmp_path / "real-run"
    real_run.mkdir()
    alias = tmp_path / "run-alias"
    alias.symlink_to(real_run, target_is_directory=True)
    state = _state(real_run)
    state["BUGSWEEP_RUN_DIR"] = str(alias)

    initialize_closeout(real_run, state, "PENDING_CLOSEOUT")
    assert read_run_status(real_run, state)["exit_code"] == 10


def test_complete_source_capture_detects_added_file(tmp_path: Path) -> None:
    from scripts._execution import _capture_source_files

    source = tmp_path / "source"; source.mkdir()
    (source / "known.py").write_text("one", encoding="utf-8")
    frozen = _capture_source_files(source, allow_symlinks=False)
    (source / "added.py").write_text("two", encoding="utf-8")
    assert _capture_source_files(source, allow_symlinks=False) != frozen


def test_state_and_marker_tampering_fails_closed(tmp_path: Path) -> None:
    run = tmp_path / "run"
    run.mkdir()
    state = _state(run)
    initialize_closeout(run, state, "PENDING_CLOSEOUT")
    marker = run / "closeout-marker.json"
    payload = json.loads(marker.read_text())
    payload["stage"] = "BRANCH_REMOVED"
    marker.write_text(json.dumps(payload), encoding="utf-8")

    with __import__("pytest").raises(LifecycleError, match="cannot skip"):
        advance_closeout(run, state, "WORKTREE_REMOVED")

    (run / "state.env").write_text("BUGSWEEP_RUN_ID='run-1'\nBUGSWEEP_RUN_ID='replay'\n", encoding="utf-8")
    invalid = read_run_status(run)
    assert invalid["exit_code"] == 2
    assert "duplicate" in invalid["reason"]
