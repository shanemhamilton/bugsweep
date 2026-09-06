#!/usr/bin/env python3
"""Small, side-effect-free helpers shared by the installer and its tests."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


OPEN = "<!-- bugsweep-skill -->"
CLOSE = "<!-- /bugsweep-skill -->"


def _block(skill_root: str) -> str:
    return (
        f"{OPEN}\n"
        "## bugsweep skill\n"
        "When the user types `/bugsweep` (with any flags) or asks to find/fix bugs autonomously,\n"
        "read the full skill instructions from:\n"
        f"  {skill_root}/SKILL.md\n"
        f"All referenced scripts live in {skill_root}/scripts/, prompts in {skill_root}/prompts/,\n"
        f"and config in {skill_root}/config/. Expand relative script paths to absolute ones when running.\n"
        f"{CLOSE}\n"
    )


def _legacy(skill_root: str) -> str:
    return _block(skill_root).replace(f"{CLOSE}\n", "")


def registration_content(existing: str, skill_root: str) -> str:
    """Return an exact owned-block replacement while preserving every other byte."""
    block = _block(skill_root)
    if OPEN not in existing:
        return existing + ("" if not existing or existing.endswith("\n") else "\n") + block
    if existing.count(OPEN) != 1:
        raise ValueError("ambiguous bugsweep registration markers")
    start = existing.index(OPEN)
    close = existing.find(CLOSE, start)
    if close >= 0:
        end = close + len(CLOSE)
        if end < len(existing) and existing[end : end + 1] == "\n":
            end += 1
        if existing[start:end] != block:
            raise ValueError("ambiguous bugsweep registration ownership")
        return existing[:start] + block + existing[end:]
    legacy = _legacy(skill_root)
    if not existing.startswith(legacy, start):
        raise ValueError("ambiguous legacy bugsweep registration ownership")
    return existing[:start] + block + existing[start + len(legacy) :]


def copy_config(source: Path, destination: Path) -> None:
    """Copy the one user-configurable file only after validating its JSON."""
    data = source.read_text(encoding="utf-8")
    json.loads(data)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(data, encoding="utf-8")


def write_transaction(journal: Path, transaction: dict[str, Any]) -> None:
    """Durably record exact transaction paths before any rename occurs."""
    temporary = journal.with_name(f".{journal.name}.tmp")
    temporary.write_text(json.dumps(transaction, sort_keys=True) + "\n", encoding="utf-8")
    with temporary.open("r+", encoding="utf-8") as stream:
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(journal)


def commit_transaction(journal: Path) -> None:
    transaction = json.loads(journal.read_text(encoding="utf-8"))
    transaction["completed"] = True
    write_transaction(journal, transaction)


def failure_payload(
    results: Path,
    recovery: Path,
    *,
    host: str,
    root: str,
    channel: str,
    tag: str,
    commit: str,
    journal: str,
    reason: str,
) -> dict[str, Any]:
    keys = ("host", "root", "channel", "tag", "commit", "version", "status")
    rows = []
    if results.exists():
        rows = [dict(zip(keys, line.rstrip("\n").split("\t"))) for line in results.read_text().splitlines()]
    if host:
        rows.append({"host": host, "root": root, "channel": channel, "tag": tag, "commit": commit, "version": "unknown", "status": "failed"})
    records = [json.loads(line) for line in recovery.read_text().splitlines() if line] if recovery.exists() else []
    if journal:
        records.append({"status": "pending", "journal": journal, "reason": reason})
    return {"schema_version": 1, "installations": rows, "recovery": records}


def _path(value: Any, parent: Path, name: str) -> Path:
    if not isinstance(value, str):
        raise ValueError(f"transaction {name} is invalid")
    path = Path(value)
    if path.parent != parent or not path.name.startswith(".bugsweep."):
        raise ValueError(f"transaction {name} is outside its exact owned parent")
    return path


def _move(source: Path, destination: Path) -> None:
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"recovery destination already exists: {destination}")
    source.rename(destination)


def recover_transaction(journal: Path, expected_destination: Path | None = None) -> dict[str, Any]:
    """Restore the pre-install state without deleting staged or user content."""
    data = json.loads(journal.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError("unsupported transaction schema")
    destination = Path(data["destination"])
    parent = destination.parent
    if expected_destination is not None and destination != expected_destination:
        raise ValueError("transaction destination does not match this installer target")
    if destination.name != "bugsweep":
        raise ValueError("transaction destination is not the Bugsweep target")
    if journal != parent / ".bugsweep.install-recovery.json":
        raise ValueError("transaction journal is not the exact owned journal")
    stage = _path(data.get("stage"), parent, "stage")
    backup = _path(data.get("backup"), parent, "backup")
    original_exists = data.get("original_exists")
    if not isinstance(original_exists, bool):
        raise ValueError("transaction original_exists is invalid")
    if data.get("completed") is True:
        if not destination.is_dir() or not (destination / "install-metadata.json").is_file():
            raise ValueError("completed transaction readback failed")
        return {"status": "committed", "actions": [], "journal": str(journal)}
    actions: list[str] = []
    if original_exists:
        if not destination.exists() and backup.exists():
            _move(backup, destination)
            actions.append("restored-backup")
        elif destination.exists() and backup.exists() and not stage.exists():
            _move(destination, stage)
            _move(backup, destination)
            actions.extend(("preserved-staged-install", "restored-backup"))
        elif not destination.exists() or backup.exists():
            raise ValueError("transaction filesystem state is ambiguous")
    else:
        if destination.exists() and not stage.exists():
            _move(destination, stage)
            actions.append("preserved-staged-install")
        elif destination.exists() and stage.exists():
            raise ValueError("transaction filesystem state is ambiguous")

    instructions = data.get("instructions")
    had_instructions = data.get("instructions_existed")
    registration_backup = data.get("registration_backup")
    if instructions is not None:
        instructions_path = Path(instructions)
        if instructions_path.parent != parent.parent:
            raise ValueError("transaction instructions path is invalid")
        if not isinstance(had_instructions, bool) or not isinstance(registration_backup, str):
            raise ValueError("transaction registration state is invalid")
        backup_path = Path(registration_backup)
        if backup_path.parent != instructions_path.parent or not backup_path.name.startswith(".instructions.bugsweep.backup."):
            raise ValueError("transaction registration backup is invalid")
        if had_instructions and backup_path.exists():
            if instructions_path.exists() or instructions_path.is_symlink():
                interrupted = backup_path.with_name(
                    backup_path.name.replace(".backup.", ".interrupted.", 1)
                )
                _move(instructions_path, interrupted)
                actions.append("preserved-interrupted-instructions")
            _move(backup_path, instructions_path)
            actions.append("restored-instructions")
        elif not had_instructions and instructions_path.exists():
            exact = registration_content("", str(destination))
            if instructions_path.read_text(encoding="utf-8") != exact:
                raise ValueError("new instructions file is no longer exactly owned")
            instructions_path.unlink()
            actions.append("removed-owned-new-instructions")
    if destination.exists() != original_exists or not stage.exists():
        raise ValueError("transaction recovery readback failed")
    return {"status": "recovered", "actions": actions, "journal": str(journal)}


def main(argv: list[str]) -> int:
    if len(argv) == 11 and argv[1] == "failure-json":
        try:
            print(json.dumps(failure_payload(Path(argv[2]), Path(argv[3]), host=argv[4], root=argv[5], channel=argv[6], tag=argv[7], commit=argv[8], journal=argv[9], reason=argv[10]), sort_keys=True))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"bugsweep installer: invalid failure state: {exc}", file=sys.stderr)
            return 1
        return 0
    if len(argv) == 3 and argv[1] == "write-transaction":
        try:
            write_transaction(Path(argv[2]), json.load(sys.stdin))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"bugsweep installer: invalid transaction: {exc}", file=sys.stderr)
            return 1
        return 0
    if len(argv) == 3 and argv[1] == "commit":
        try:
            commit_transaction(Path(argv[2]))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"bugsweep installer: {exc}", file=sys.stderr)
            return 1
        return 0
    if len(argv) in {3, 4} and argv[1] == "recover":
        try:
            expected = Path(argv[3]) if len(argv) == 4 else None
            print(json.dumps(recover_transaction(Path(argv[2]), expected), sort_keys=True))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"bugsweep installer: {exc}", file=sys.stderr)
            return 1
        return 0
    if len(argv) == 4 and argv[1] == "copy-config":
        try:
            copy_config(Path(argv[2]), Path(argv[3]))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"bugsweep installer: invalid user config: {exc}", file=sys.stderr)
            return 1
        return 0
    if len(argv) != 4 or argv[1] != "registration":
        print("usage: installer_helper.py registration INSTRUCTIONS_FILE SKILL_ROOT", file=sys.stderr)
        return 2
    path, root = argv[2:]
    try:
        with open(path, encoding="utf-8") as handle:
            existing = handle.read()
    except FileNotFoundError:
        existing = ""
    try:
        sys.stdout.write(registration_content(existing, root))
    except ValueError as exc:
        print(f"bugsweep installer: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
