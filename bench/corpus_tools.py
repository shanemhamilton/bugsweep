#!/usr/bin/env python3
"""Freeze seeded corpus cases without exposing oracle material to reviewers."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import stat
from pathlib import Path
from typing import Any


class CorpusError(ValueError):
    pass


REQUIRED = {"id", "suite", "repository", "language", "category", "source", "mutation", "gold", "size_ceiling", "task_description"}
SUITES = {"heldout-v1", "pilot-v1"}
CATEGORIES = {"security", "logic", "concurrency", "lifecycle", "data-integrity"}


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def source_manifest(root: Path) -> dict[str, Any]:
    if root.is_symlink():
        raise CorpusError("source root is a symlink")
    if not root.is_dir():
        raise CorpusError("source root is not a directory")
    files: dict[str, str] = {}
    modes: dict[str, int] = {}
    total_bytes = 0
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if relative == ".git" or relative.startswith(".git/"):
            continue
        if path.is_symlink():
            raise CorpusError(f"symlink in source scope: {relative}")
        if path.is_file():
            data = path.read_bytes()
            files[relative] = sha256_bytes(data)
            modes[relative] = stat.S_IMODE(path.stat().st_mode)
            total_bytes += len(data)
    if not files:
        raise CorpusError("source scope is empty")
    # `sha256` deliberately matches bench.harness.source_manifest: it is the
    # canonical direct file map used by the scheduler. Permission/size proof is
    # separately bound so it cannot silently change that cross-producer ID.
    inventory = {"source_file_mode": modes, "file_count": len(files), "total_bytes": total_bytes}
    return {"kind": "content-manifest-sha256", "sha256": sha256_bytes(canonical(files)), "source_file_sha256": files, **inventory, "inventory_sha256": sha256_bytes(canonical(inventory))}


def validate_case(case: dict[str, Any]) -> None:
    if set(case) != REQUIRED:
        raise CorpusError(f"case keys must be exactly {sorted(REQUIRED)}")
    if case["suite"] not in SUITES or case["category"] not in CATEGORIES:
        raise CorpusError("invalid suite or category")
    if not all(isinstance(case[key], str) and case[key] for key in ("id", "repository", "language", "task_description")):
        raise CorpusError("case identity fields must be non-empty strings")
    source = case["source"]
    if not isinstance(source, dict) or set(source) != {"repo", "commit", "archive_url", "archive_sha256", "license"}:
        raise CorpusError("source must pin repo, commit, official archive, digest, and license")
    if source["repo"] != case["repository"] or len(source["commit"]) != 40 or len(source["archive_sha256"]) != 64:
        raise CorpusError("source identity is not pinned")
    if not source["archive_url"].startswith("https://codeload.github.com/"):
        raise CorpusError("source archive must be official GitHub codeload")
    mutation = case["mutation"]
    if not isinstance(mutation, dict) or mutation.get("kind") != "seeded" or not isinstance(mutation.get("edits"), list) or not mutation["edits"]:
        raise CorpusError("case needs explicit seeded edits")
    for edit in mutation["edits"]:
        if not isinstance(edit, dict) or set(edit) != {"path", "before", "after", "source_file_sha256"}:
            raise CorpusError("each edit must be a source-bound replacement")
        if not all(isinstance(edit[key], str) and edit[key] for key in edit):
            raise CorpusError("empty edit field")
        if edit["before"] == edit["after"] or len(edit["source_file_sha256"]) != 64 or Path(edit["path"]).is_absolute() or ".." in Path(edit["path"]).parts:
            raise CorpusError("invalid edit")
    gold = case["gold"]
    native = gold.get("native") if isinstance(gold, dict) else None
    expected = gold.get("expected") if isinstance(gold, dict) else None
    if not isinstance(gold, dict) or gold.get("storage") != "external-private-gold-root" or gold.get("runtime_status") != "UNVERIFIED_PENDING_SANDBOX_RUN" or not isinstance(native, dict) or not isinstance(expected, dict):
        raise CorpusError("gold must remain external and runtime-unverified")
    if not isinstance(native.get("argv"), list) or not native["argv"] or not all(isinstance(v, str) and v for v in native["argv"]) or not all(isinstance(native.get(k), str) and native[k] for k in ("test_file", "test_sha256", "native_test_id")) or len(native["test_sha256"]) != 64:
        raise CorpusError("gold needs a bounded native test identity")
    if expected.get("buggy") != "fail" or expected.get("patched") != "pass" or not isinstance(expected.get("assertion"), str):
        raise CorpusError("gold must describe red/green behavior without claiming execution")
    if not isinstance(gold.get("controls"), dict) or set(gold["controls"]) != {"negative", "patched"} or not isinstance(gold.get("source_bindings"), list) or not gold["source_bindings"]:
        raise CorpusError("gold needs controls and source bindings")
    for binding in gold["source_bindings"]:
        if not isinstance(binding, dict) or set(binding) != {"path", "sha256"} or not isinstance(binding["path"], str) or Path(binding["path"]).is_absolute() or ".." in Path(binding["path"]).parts or not isinstance(binding["sha256"], str) or len(binding["sha256"]) != 64:
            raise CorpusError("invalid gold source binding")
    if not isinstance(case["size_ceiling"], dict) or set(case["size_ceiling"]) != {"max_files", "max_loc"} or any(not isinstance(case["size_ceiling"][key], int) or case["size_ceiling"][key] < 1 for key in ("max_files", "max_loc")):
        raise CorpusError("invalid size ceiling")


def apply_mutation(source_root: Path, case: dict[str, Any]) -> None:
    """Apply exactly one source-bound replacement per edit, or fail closed."""
    validate_case(case)
    for edit in case["mutation"]["edits"]:
        path = source_root / edit["path"]
        if not path.is_file() or path.is_symlink():
            raise CorpusError(f"missing source file: {edit['path']}")
        original = path.read_bytes()
        if sha256_bytes(original) != edit["source_file_sha256"]:
            raise CorpusError(f"source digest mismatch: {edit['path']}")
        before, after = edit["before"].encode(), edit["after"].encode()
        if original.count(before) != 1:
            raise CorpusError(f"replacement is not unique: {edit['path']}")
        path.write_bytes(original.replace(before, after, 1))


def verify_archive(archive: Path, case: dict[str, Any]) -> str:
    """Bind an extracted source to the exact downloaded official archive."""
    validate_case(case)
    if not archive.is_file() or archive.is_symlink():
        raise CorpusError("archive is not a regular file")
    observed = sha256_bytes(archive.read_bytes())
    if observed != case["source"]["archive_sha256"]:
        raise CorpusError("official source archive digest mismatch")
    return observed


def verify_private_gold(case: dict[str, Any], gold_root: Path, source_root: Path | None = None) -> Path:
    """Verify private oracle content without ever placing it in the mount."""
    validate_case(case)
    path = gold_root / case["gold"]["locator"] / case["gold"]["native"]["test_file"]
    if not path.is_file() or path.is_symlink() or sha256_bytes(path.read_bytes()) != case["gold"]["native"]["test_sha256"]:
        raise CorpusError("private gold test missing or digest mismatch")
    if source_root is not None:
        for binding in case["gold"]["source_bindings"]:
            source = source_root / binding["path"]
            if not source.is_file() or source.is_symlink() or sha256_bytes(source.read_bytes()) != binding.get("sha256"):
                raise CorpusError("private gold source binding mismatch")
    return path


def public_id(case: dict[str, Any]) -> str:
    return "review-" + sha256_bytes(case["id"].encode())[:16]


def redacted(case: dict[str, Any], manifest_sha256: str) -> dict[str, Any]:
    return {"id": public_id(case), "language": case["language"], "size_ceiling": case["size_ceiling"], "task_description": "Review the mounted source and report findings with evidence.", "source_manifest_sha256": manifest_sha256}


def freeze(case_path: Path, source_root: Path, output_root: Path, archive: Path) -> dict[str, Any]:
    case = json.loads(case_path.read_text(encoding="utf-8"))
    validate_case(case)
    archive_sha256 = verify_archive(archive, case)
    before = source_manifest(source_root)
    if before["file_count"] > case["size_ceiling"]["max_files"]:
        raise CorpusError("source exceeds file ceiling")
    if sum(data.count(b"\n") + 1 for path in before["source_file_sha256"] for data in [(source_root / path).read_bytes()]) > case["size_ceiling"]["max_loc"]:
        raise CorpusError("source exceeds LOC ceiling")
    target = output_root / public_id(case)
    if target.exists():
        raise CorpusError(f"output exists: {target}")
    shutil.copytree(source_root, target, symlinks=False, ignore=shutil.ignore_patterns(".git"))
    apply_mutation(target, case)
    manifest = source_manifest(target)
    frozen = {"private_case_id": case["id"], "public_case_id": public_id(case), "source": case["source"], "archive_sha256_verified": archive_sha256, "source_before_manifest": before, "mutation_kind": "seeded", "source_manifest": manifest, "runtime_status": "UNVERIFIED_PENDING_SANDBOX_RUN"}
    # Evidence stays beside the mount: the source manifest must cover every
    # mounted path and the mount itself must not reveal corpus metadata.
    (output_root / f"{case['id']}.freeze.json").write_bytes(canonical(frozen))
    return redacted(case, manifest["sha256"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("case", type=Path)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("output_root", type=Path)
    parser.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(freeze(args.case, args.source_root, args.output_root, args.archive), sort_keys=True))


if __name__ == "__main__":
    main()
