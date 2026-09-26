"""Fail-closed durable state for Bugsweep terminal cleanup.

This module deliberately handles files only.  Git/worktree operations remain in
the coordinator; it advances a marker only after that coordinator readback.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import Any


class LifecycleError(ValueError):
    pass


MARKER = "closeout-marker.json"
RECEIPT = "terminal-receipt.json"
ABSENCE = "absence-observation.json"
STAGES = (
    "PENDING_FINALIZATION",
    "PENDING_CLOSEOUT",
    "READY_FOR_CLEANUP",
    "WORKTREE_REMOVED",
    "BRANCH_REMOVED",
    "RECEIPT_PENDING",
    "COMPLETED_LANDED",
    "COMPLETED_RECORDED",
)
_NONTERMINAL = STAGES[:6]
_TERMINAL = STAGES[6:]
_STATE_KEYS = frozenset(
    {
        "BUGSWEEP_TS", "BUGSWEEP_RUN_ID", "BUGSWEEP_RUN_DIR", "BUGSWEEP_REPO_ROOT",
        "BUGSWEEP_BRANCH", "BUGSWEEP_ORIG_BRANCH", "BUGSWEEP_ORIG_HEAD",
        "BUGSWEEP_STASH_REF", "BUGSWEEP_START_EPOCH", "BUGSWEEP_DEADLINE_EPOCH",
        "BUGSWEEP_MAX_RUNTIME_MINUTES", "BUGSWEEP_MODE", "BUGSWEEP_SCOPE",
        "BUGSWEEP_CONCURRENT", "BUGSWEEP_WORKTREE",
    }
)
_IDENTITY_KEYS = ("BUGSWEEP_RUN_ID", "BUGSWEEP_RUN_DIR", "BUGSWEEP_REPO_ROOT", "BUGSWEEP_BRANCH", "BUGSWEEP_ORIG_BRANCH", "BUGSWEEP_ORIG_HEAD", "BUGSWEEP_WORKTREE")
_NONEMPTY_IDENTITY_KEYS = tuple(key for key in _IDENTITY_KEYS if key != "BUGSWEEP_WORKTREE")


def _regular(path: Path, *, required: bool = True) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        if required:
            raise LifecycleError(f"missing {path.name}") from None
        return
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise LifecycleError(f"unsafe path: {path}")


def _run_dir(run_dir: Path) -> Path:
    path = Path(run_dir)
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        raise LifecycleError("missing run directory") from None
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        raise LifecycleError("unsafe run directory")
    return path.resolve(strict=True)


def _unquote(value: str) -> str:
    if value.startswith("'") and value.endswith("'") and len(value) >= 2:
        return value[1:-1].replace("'\\''", "'")
    return value


def load_state(path: Path) -> dict[str, str]:
    """Read state.env as inert data; never source it."""
    path = Path(path)
    _regular(path)
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise LifecycleError("invalid state.env") from error
    for raw in lines:
        if not raw or raw.startswith("#"):
            continue
        key, sep, value = raw.partition("=")
        if not sep or key not in _STATE_KEYS or key in values:
            raise LifecycleError("duplicate, unknown, or malformed state key")
        value = _unquote(value)
        if any(ord(char) < 32 for char in value):
            raise LifecycleError("hostile state value")
        values[key] = value
    missing = [key for key in _NONEMPTY_IDENTITY_KEYS if not values.get(key)]
    if "BUGSWEEP_WORKTREE" not in values:
        missing.append("BUGSWEEP_WORKTREE")
    if missing:
        raise LifecycleError("missing state identity: " + ", ".join(missing))
    if not values["BUGSWEEP_BRANCH"].startswith("bugsweep/"):
        raise LifecycleError("state branch is outside bugsweep namespace")
    for key in ("BUGSWEEP_RUN_DIR", "BUGSWEEP_WORKTREE"):
        value = values.get(key, "")
        if value and not Path(value).is_absolute():
            raise LifecycleError(f"unsafe non-absolute {key}")
    return values


def _identity(state: dict[str, str]) -> dict[str, str]:
    missing = [key for key in _NONEMPTY_IDENTITY_KEYS if not state.get(key)]
    if "BUGSWEEP_WORKTREE" not in state:
        missing.append("BUGSWEEP_WORKTREE")
    if missing:
        raise LifecycleError("missing state identity: " + ", ".join(missing))
    value = {key: state[key] for key in _IDENTITY_KEYS}
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    value["state_sha256"] = hashlib.sha256(encoded).hexdigest()
    return value


def _state_for_run(run_dir: Path, state: dict[str, str]) -> None:
    # Preserve exact run ownership while accepting equivalent absolute paths
    # (for example macOS's /var -> /private/var compatibility alias).
    try:
        recorded_run_dir = Path(state["BUGSWEEP_RUN_DIR"]).resolve(strict=True)
    except (KeyError, OSError):
        raise LifecycleError("run directory identity mismatch") from None
    if recorded_run_dir != run_dir:
        raise LifecycleError("run directory identity mismatch")


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    _regular(path, required=False)
    data = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode()
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        if temp.exists():
            temp.unlink()


def _read_json(path: Path, required: set[str]) -> dict[str, Any]:
    _regular(path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise LifecycleError(f"invalid {path.name}") from error
    if not isinstance(data, dict) or set(data) != required:
        raise LifecycleError(f"invalid {path.name} fields")
    return data


def _marker(run_dir: Path, state: dict[str, str]) -> dict[str, Any]:
    data = _read_json(run_dir / MARKER, {"schema_version", "stage", "identity"})
    if data["schema_version"] != 1 or data["stage"] not in STAGES or data["identity"] != _identity(state):
        raise LifecycleError("invalid, replayed, or foreign closeout marker")
    return data


def initialize_closeout(run_dir: Path, state: dict[str, str], stage: str = "PENDING_CLOSEOUT") -> dict[str, Any]:
    run_dir = _run_dir(run_dir)
    _state_for_run(run_dir, state)
    if stage not in _NONTERMINAL:
        raise LifecycleError("invalid initial lifecycle stage")
    path = run_dir / MARKER
    if path.exists():
        marker = _marker(run_dir, state)
        if STAGES.index(marker["stage"]) < STAGES.index(stage):
            raise LifecycleError("existing closeout marker disagrees")
        return marker
    payload = {"schema_version": 1, "stage": stage, "identity": _identity(state)}
    _write_json(path, payload)
    return payload


def advance_closeout(run_dir: Path, state: dict[str, str], stage: str) -> dict[str, Any]:
    run_dir = _run_dir(run_dir)
    _state_for_run(run_dir, state)
    marker = _marker(run_dir, state)
    current = marker["stage"]
    if current == stage:
        return marker
    if current in _TERMINAL:
        raise LifecycleError("terminal lifecycle cannot advance")
    if stage not in _NONTERMINAL:
        raise LifecycleError("terminal receipt must be written separately")
    expected = _NONTERMINAL[_NONTERMINAL.index(current) + 1] if current != "RECEIPT_PENDING" else None
    if stage != expected:
        raise LifecycleError(f"cannot skip or reverse closeout stage {current} -> {stage}")
    marker["stage"] = stage
    _write_json(run_dir / MARKER, marker)
    return marker


def write_terminal_receipt(run_dir: Path, state: dict[str, str], outcome: str) -> dict[str, Any]:
    run_dir = _run_dir(run_dir)
    _state_for_run(run_dir, state)
    marker = _marker(run_dir, state)
    if marker["stage"] != "RECEIPT_PENDING" or outcome not in _TERMINAL:
        raise LifecycleError("terminal receipt requires RECEIPT_PENDING")
    receipt = {"schema_version": 1, "outcome": outcome, "identity": _identity(state)}
    path = run_dir / RECEIPT
    if path.exists():
        existing = _read_json(path, {"schema_version", "outcome", "identity"})
        if existing != receipt:
            raise LifecycleError("terminal receipt disagrees")
    else:
        _write_json(path, receipt)
    marker["stage"] = outcome
    _write_json(run_dir / MARKER, marker)
    return receipt


def record_absence_observation(run_dir: Path, state: dict[str, str]) -> dict[str, Any]:
    """Persist the coordinator's already-performed exact absence readback."""
    run_dir = _run_dir(run_dir)
    _state_for_run(run_dir, state)
    worktree = state.get("BUGSWEEP_WORKTREE", "")
    if worktree and os.path.lexists(worktree):
        raise LifecycleError("worktree remains; cannot record absence")
    observation = {"schema_version": 1, "identity": _identity(state), "branch_absent": True, "worktree_absent": True}
    path = run_dir / ABSENCE
    if path.exists():
        existing = _read_json(path, {"schema_version", "identity", "branch_absent", "worktree_absent"})
        if existing != observation:
            raise LifecycleError("absence observation disagrees")
    else:
        _write_json(path, observation)
    return observation


def recover_absent_resources(run_dir: Path, state: dict[str, str], *, worktree_absent: bool, branch_absent: bool) -> dict[str, Any]:
    """Replay only already-observed absence after a crash, never guessed state."""
    if not worktree_absent or not branch_absent:
        raise LifecycleError("recovery requires exact worktree and branch absence")
    run_dir = _run_dir(run_dir)
    _state_for_run(run_dir, state)
    marker = _marker(run_dir, state)
    if marker["stage"] in _TERMINAL:
        return marker
    while marker["stage"] in {"PENDING_FINALIZATION", "PENDING_CLOSEOUT", "READY_FOR_CLEANUP", "WORKTREE_REMOVED"}:
        next_stage = _NONTERMINAL[_NONTERMINAL.index(marker["stage"]) + 1]
        marker = advance_closeout(run_dir, state, next_stage)
    return marker


def reconcile_closeout(run_dir: Path, state: dict[str, str]) -> dict[str, Any]:
    run_dir = _run_dir(run_dir)
    _state_for_run(run_dir, state)
    marker = _marker(run_dir, state)
    receipt_path = run_dir / RECEIPT
    if marker["stage"] in _TERMINAL:
        receipt = _read_json(receipt_path, {"schema_version", "outcome", "identity"})
        observation = _read_json(run_dir / ABSENCE, {"schema_version", "identity", "branch_absent", "worktree_absent"})
        worktree = state.get("BUGSWEEP_WORKTREE", "")
        if (worktree and os.path.lexists(worktree)) or (receipt["schema_version"] != 1 or receipt["outcome"] != marker["stage"]
                or receipt["identity"] != _identity(state) or observation.get("schema_version") != 1
                or observation.get("identity") != _identity(state) or observation.get("branch_absent") is not True
                or observation.get("worktree_absent") is not True):
            raise LifecycleError("terminal marker/receipt disagreement")
    elif receipt_path.exists():
        raise LifecycleError("receipt exists before terminal marker")
    return marker


def read_run_status(run_dir: Path, state: dict[str, str] | None = None) -> dict[str, Any]:
    try:
        run_dir = _run_dir(run_dir)
        state = load_state(run_dir / "state.env") if state is None else state
        marker = reconcile_closeout(run_dir, state)
    except (LifecycleError, OSError, UnicodeError) as error:
        return {"status": "invalid", "reason": str(error), "exit_code": 2}
    if marker["stage"] in _TERMINAL:
        block = Path(state["BUGSWEEP_REPO_ROOT"]) / ".bugsweep" / "state" / "closeout-blocked" / f"{state['BUGSWEEP_RUN_ID']}.json"
        if os.path.lexists(block):
            return {"status": "pending", "stage": "RECEIPT_PENDING", "exit_code": 10}
        return {"status": "verified_completed", "outcome": marker["stage"], "exit_code": 0}
    return {"status": "pending", "stage": marker["stage"], "exit_code": 10}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("status", "terminal", "get", "init", "advance", "receipt", "observe-absence", "recover-absent"))
    parser.add_argument("run_dir")
    parser.add_argument("key", nargs="?")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "get":
        if args.key not in _STATE_KEYS:
            return 2
        try:
            print(load_state(Path(args.run_dir) / "state.env").get(args.key, ""))
        except LifecycleError as error:
            print(str(error), file=sys.stderr)
            return 2
        return 0
    if args.command == "terminal":
        try:
            state = load_state(Path(args.run_dir) / "state.env")
            stage = reconcile_closeout(Path(args.run_dir), state)["stage"]
            if stage in _TERMINAL:
                print(stage)
                return 0
            return 10
        except (LifecycleError, OSError, UnicodeError):
            return 2
    if args.command in {"init", "advance", "receipt", "observe-absence", "recover-absent"}:
        if args.key is None:
            return 2
        try:
            state = load_state(Path(args.run_dir) / "state.env")
            if args.command == "init":
                initialize_closeout(Path(args.run_dir), state, args.key)
            elif args.command == "advance":
                advance_closeout(Path(args.run_dir), state, args.key)
            elif args.command == "recover-absent":
                if args.key != "confirmed":
                    raise LifecycleError("recovery requires explicit confirmed absence")
                recover_absent_resources(Path(args.run_dir), state, worktree_absent=True, branch_absent=True)
            elif args.command == "observe-absence":
                if args.key != "confirmed":
                    raise LifecycleError("observation requires explicit confirmed absence")
                record_absence_observation(Path(args.run_dir), state)
            else:
                write_terminal_receipt(Path(args.run_dir), state, args.key)
        except LifecycleError as error:
            print(str(error), file=sys.stderr)
            return 2
        return 0
    result = read_run_status(Path(args.run_dir))
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print(result["status"].upper() + (f": {result.get('outcome') or result.get('stage') or result.get('reason')}" if len(result) > 2 else ""))
    return int(result["exit_code"])


if __name__ == "__main__":
    raise SystemExit(main())
