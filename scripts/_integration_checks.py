#!/usr/bin/env python3
"""Run frozen quality checks against an exact, disposable merged-tree export."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import time
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence, cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts._check_results import compare_check_results
from scripts._execution import (
    canonical_json_bytes,
    execution_config_sha256,
    execution_environment_sha256,
    _mount_inventory,
    _read_bounded_bytes,
)
from scripts._proof import _check_record, validate_suite_receipt


MAX_FILES = 100_000
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_INDEX_BYTES = 32 * 1024 * 1024
_SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")


def _digest(value: object) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def _sha256_file(path: Path, maximum: int = MAX_FILE_BYTES) -> tuple[str, int]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    digest = hashlib.sha256()
    size = 0
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError("expected one private regular file")
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > maximum:
                raise ValueError("file exceeds its byte limit")
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            raise ValueError("file changed while read")
    finally:
        os.close(descriptor)
    return digest.hexdigest(), size


def _read_json_with_sha(
    path: Path, maximum: int = 16 * 1024 * 1024
) -> tuple[dict[str, Any], str]:
    raw = _read_bounded_bytes(path, maximum)
    try:
        value = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid JSON: {path.name}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path.name}")
    return value, hashlib.sha256(raw).hexdigest()
def _relative_path(value: object) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        raise ValueError("archive path is invalid")
    path = PurePosixPath(value.rstrip("/"))
    if (
        path.is_absolute()
        or str(path) != value.rstrip("/")
        or any(part in {"", ".", ".."} for part in path.parts)
        or path.parts[0] == ".git"
        or len(value.encode("utf-8")) > 4096
    ):
        raise ValueError("archive path escapes or contains metadata")
    return path.as_posix()


def _extract_archive(archive_path: Path, destination: Path) -> tuple[dict[str, str], dict[str, str]]:
    """Extract regular Git archive members without tarfile's filesystem extractor."""

    files: dict[str, str] = {}
    modes: dict[str, str] = {}
    seen: set[str] = set()
    total = 0
    with tarfile.open(archive_path, mode="r:") as archive:
        for member in archive:
            relative = _relative_path(member.name)
            if relative in seen or len(seen) >= MAX_FILES:
                raise ValueError("archive contains duplicate or excessive members")
            seen.add(relative)
            target = destination.joinpath(*PurePosixPath(relative).parts)
            if member.isdir():
                if member.mode & 0o777 != 0o755:
                    raise ValueError("archive directory mode is invalid")
                target.mkdir(mode=0o755, parents=True, exist_ok=False)
                continue
            if not member.isreg() or member.size < 0 or member.size > MAX_FILE_BYTES:
                raise ValueError("archive contains a link or special member")
            permission = member.mode & 0o777
            if permission not in {0o644, 0o755}:
                raise ValueError("archive file mode is invalid")
            total += member.size
            if total > MAX_TOTAL_BYTES:
                raise ValueError("archive exceeds its total byte limit")
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise ValueError("archive regular member has no bytes")
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, permission)
            digest = hashlib.sha256()
            copied = 0
            complete = False
            try:
                while True:
                    chunk = source.read(64 * 1024)
                    if not chunk:
                        break
                    copied += len(chunk)
                    if copied > member.size:
                        raise ValueError("archive member exceeded its declared size")
                    os.write(descriptor, chunk)
                    digest.update(chunk)
                if copied != member.size:
                    raise ValueError("archive member was truncated")
                os.fchmod(descriptor, permission)
                os.fsync(descriptor)
                complete = True
            finally:
                source.close()
                os.close(descriptor)
                if not complete:
                    target.unlink(missing_ok=True)
            files[relative] = digest.hexdigest()
            modes[relative] = "100755" if permission == 0o755 else "100644"
    if not files:
        raise ValueError("merged source export is empty")
    return dict(sorted(files.items())), dict(sorted(modes.items()))


def _parse_index(path: Path) -> dict[str, tuple[str, str]]:
    raw = _read_bounded_bytes(path, MAX_INDEX_BYTES)
    if raw and not raw.endswith(b"\x00"):
        raise ValueError("Git index inventory is unbounded or truncated")
    result: dict[str, tuple[str, str]] = {}
    for record in raw[:-1].split(b"\x00") if raw else []:
        try:
            metadata, raw_name = record.split(b"\t", 1)
            mode, object_id, stage = metadata.decode("ascii").split(" ")
            name = _relative_path(raw_name.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise ValueError("Git index inventory is malformed") from exc
        if (
            stage != "0"
            or mode not in {"100644", "100755"}
            or not _SHA_RE.fullmatch(object_id)
            or name in result
            or len(result) >= MAX_FILES
        ):
            raise ValueError("Git index contains an unsupported entry")
        result[name] = (mode, object_id)
    if not result:
        raise ValueError("Git index inventory is empty")
    return result


def _git_blob_id(content: bytes, hexadecimal_length: int) -> str:
    algorithm = hashlib.sha1 if hexadecimal_length == 40 else hashlib.sha256
    return algorithm(b"blob " + str(len(content)).encode("ascii") + b"\x00" + content).hexdigest()


def _verify_index(
    projection: Path,
    files: Mapping[str, str],
    modes: Mapping[str, str],
    index: Mapping[str, tuple[str, str]],
) -> None:
    if set(files) != set(index) or set(modes) != set(index):
        raise ValueError("Git archive does not contain the complete tracked index")
    for relative, (expected_mode, expected_object) in index.items():
        path = projection.joinpath(*PurePosixPath(relative).parts)
        content = _read_bounded_bytes(path, MAX_FILE_BYTES)
        if (
            modes[relative] != expected_mode
            or hashlib.sha256(content).hexdigest() != files[relative]
            or _git_blob_id(content, len(expected_object)) != expected_object
        ):
            raise ValueError("Git archive bytes or modes differ from the merged index")


def _control(git_path: Path, argv: Sequence[str], output: Path) -> None:
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        process = subprocess.Popen(
            [str(git_path), *argv],
            stdin=subprocess.DEVNULL,
            stdout=descriptor,
            stderr=subprocess.DEVNULL,
            env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": "/var/empty", "LANG": "C", "LC_ALL": "C"},
            start_new_session=True,
        )
        try:
            status = process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            raise ValueError("Git source export timed out") from None
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=0.2)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            raise
    finally:
        os.close(descriptor)
    if status != 0:
        raise ValueError("Git source export failed")


def _export_source(
    repo: Path, run_dir: Path, scratch_root: Path, merge_sha: str, git_path: Path
) -> tuple[Path, dict[str, str], dict[str, str], str]:
    parent = repo.parent.resolve(strict=True)
    token = uuid.uuid4().hex
    projection = parent / f".bugsweep-integration-source-{token}"
    archive = parent / f".bugsweep-integration-archive-{token}.tar"
    archive_log = parent / f".bugsweep-integration-archive-{token}.log"
    index = parent / f".bugsweep-integration-index-{token}.nul"
    for candidate in (projection, archive, archive_log, index):
        if run_dir == candidate or run_dir in candidate.parents or candidate in run_dir.parents:
            raise ValueError("integration source workspace overlaps authority")
        if scratch_root == candidate or scratch_root in candidate.parents or candidate in scratch_root.parents:
            raise ValueError("integration source workspace overlaps execution scratch")
        if repo == candidate or repo in candidate.parents:
            raise ValueError("integration source workspace overlaps repository")
    projection.mkdir(mode=0o700)
    try:
        _control(
            git_path,
            [
                "-C",
                str(repo),
                "-c",
                "tar.umask=0022",
                "archive",
                "--format=tar",
                f"--output={archive}",
                merge_sha,
            ],
            archive_log,
        )
        # git archive writes its own output; the control log must be empty.
        archive_log.unlink(missing_ok=True)
        _control(
            git_path,
            ["-C", str(repo), "ls-files", "--stage", "-z"],
            index,
        )
        files, modes = _extract_archive(archive, projection)
        _verify_index(projection, files, modes, _parse_index(index))
        inventory = _mount_inventory(projection)
        return projection, files, modes, inventory
    except Exception:
        shutil.rmtree(projection, ignore_errors=True)
        raise
    finally:
        archive.unlink(missing_ok=True)
        archive_log.unlink(missing_ok=True)
        index.unlink(missing_ok=True)


def _semantic_continuity_reasons(
    baseline: Mapping[str, object], current: Sequence[Mapping[str, object]]
) -> list[str]:
    baseline_checks = baseline.get("checks")
    if not isinstance(baseline_checks, list):
        return ["baseline_checks_missing"]
    before = {
        item.get("check"): item
        for item in baseline_checks
        if isinstance(item, Mapping) and isinstance(item.get("check"), str)
    }
    reasons: list[str] = []
    for item in current:
        name = item.get("check")
        old = before.get(name)
        if not isinstance(name, str) or old is None:
            reasons.append("check_set_changed")
            continue
        if any(
            item.get(field) != old.get(field)
            for field in ("command_sha256", "config_sha256", "environment_sha256")
        ):
            reasons.append(f"check_semantics_changed:{name}")
    if set(before) != {item.get("check") for item in current}:
        reasons.append("check_set_changed")
    return list(dict.fromkeys(reasons))


def _frozen_plan_reasons(
    plan: Mapping[str, object], baseline: Mapping[str, object]
) -> list[str]:
    plan_checks, baseline_checks = plan.get("checks"), baseline.get("checks")
    policy = plan.get("execution_policy")
    if not isinstance(plan_checks, list) or not isinstance(baseline_checks, list) or not isinstance(policy, Mapping):
        return ["frozen_plan_invalid"]
    before = {
        item.get("check"): item
        for item in baseline_checks
        if isinstance(item, Mapping) and isinstance(item.get("check"), str)
    }
    reasons: list[str] = []
    names: set[str] = set()
    for raw in plan_checks:
        if not isinstance(raw, Mapping):
            reasons.append("frozen_plan_invalid")
            continue
        name, command = raw.get("name"), raw.get("command")
        if not isinstance(name, str) or not isinstance(command, list) or name in names:
            reasons.append("frozen_plan_invalid")
            continue
        names.add(name)
        old = before.get(name)
        execution = old.get("execution") if isinstance(old, Mapping) else None
        old_policy = execution.get("execution_policy") if isinstance(execution, Mapping) else None
        report_path = raw.get("junit_path")
        declared = (
            ()
            if not isinstance(report_path, str)
            else ({"path": report_path, "kind": "junit", "max_bytes": 10_000_000},)
        )
        if (
            old is None
            or old.get("command_sha256") != _digest(command)
            or old.get("config_sha256") != execution_config_sha256(policy, declared)
            or old.get("environment_sha256") != execution_environment_sha256({})
            or not isinstance(execution, Mapping)
            or execution.get("command") != command
            or not isinstance(old_policy, Mapping)
            or old_policy.get("scratch_root") != policy.get("scratch_root")
        ):
            reasons.append(f"baseline_not_bound_to_frozen_plan:{name}")
    if names != set(before):
        reasons.append("frozen_check_set_mismatch")
    return list(dict.fromkeys(reasons))


def _receipt_name(merge_sha: str, branch: str) -> str:
    branch_digest = hashlib.sha256(branch.encode("utf-8")).hexdigest()[:16]
    return f"{merge_sha}-{branch_digest}.json"


def run_integration_checks(
    run_dir: Path, repo: Path, merge_sha: str, branch: str, git_path: Path
) -> dict[str, object]:
    run = run_dir.resolve(strict=True)
    source_repo = repo.resolve(strict=True)
    executable = git_path.resolve(strict=True)
    if (
        not _SHA_RE.fullmatch(merge_sha)
        or not branch
        or "\x00" in branch
        or len(branch.encode("utf-8")) > 1024
        or git_path.is_symlink()
        or executable != git_path
        or not executable.is_file()
        or not os.access(executable, os.X_OK)
    ):
        raise ValueError("integration source identity is invalid")
    if run == source_repo or run in source_repo.parents or source_repo in run.parents:
        raise ValueError("integration authority must be outside the repository")
    plan_path, baseline_path = run / "check-plan.json", run / "baseline.json"
    plan, plan_sha256 = _read_json_with_sha(plan_path)
    baseline, baseline_sha256 = _read_json_with_sha(baseline_path)
    policy = plan.get("execution_policy")
    baseline_sources = baseline.get("source_file_sha256")
    if (
        plan.get("run_id") != baseline.get("run_id")
        or not isinstance(plan.get("checks"), list)
        or not plan["checks"]
        or not isinstance(policy, Mapping)
        or policy.get("mode") != "required-untrusted"
        or policy.get("backend") != "docker"
        or not isinstance(baseline_sources, Mapping)
    ):
        raise ValueError("frozen integration plan or baseline is invalid")
    baseline_validation = validate_suite_receipt(
        baseline, cast(str, plan["run_id"]), cast(Mapping[str, str], baseline_sources)
    )
    if baseline_validation.get("complete") is not True:
        raise ValueError("baseline execution evidence is invalid")
    frozen_reasons = _frozen_plan_reasons(plan, baseline)
    if frozen_reasons:
        raise ValueError(";".join(frozen_reasons))
    scratch_value = policy.get("scratch_root")
    if not isinstance(scratch_value, str):
        raise ValueError("frozen execution policy lacks scratch_root")
    scratch_root = Path(scratch_value).resolve(strict=True)
    projection: Path | None = None
    destination = run / "integration-check-results" / _receipt_name(merge_sha, branch)
    if destination.exists() or destination.is_symlink():
        raise ValueError("integration suite receipt already exists")
    destination.parent.mkdir(mode=0o700, exist_ok=True)
    try:
        projection, sources, modes, inventory = _export_source(
            source_repo, run, scratch_root, merge_sha, executable
        )
        identity = {
            "kind": "content-manifest-sha256",
            "sha256": _digest(sources),
            "source_file_sha256": sources,
        }
        integration_policy = {
            **policy,
            "target_root": str(projection),
            "source_identity": identity,
        }
        request = {
            **plan,
            "target_root": str(projection),
            "source_file_sha256": sources,
            "execution_policy": integration_policy,
        }
        records: list[dict[str, Any]] = []
        for index, entry in enumerate(cast(list[object], plan["checks"])):
            if not isinstance(entry, Mapping):
                records.append({"check": str(index), "status": "proof_error", "reason": "malformed_check_plan"})
                continue
            records.append(_check_record(run, request, entry, index))
        reasons = _semantic_continuity_reasons(baseline, records)
        regressions: list[str] = []
        before = {
            item.get("check"): item
            for item in cast(list[object], baseline.get("checks", []))
            if isinstance(item, Mapping)
        }
        for record in records:
            old = before.get(record.get("check"))
            if isinstance(old, Mapping):
                compared = compare_check_results(old, record)
                regressions.extend(cast(list[str], compared.get("regressions", [])))
                if compared.get("status") == "proof_error":
                    reasons.append(f"structured_result_error:{record.get('check')}")
            if record.get("status") == "proof_error":
                reasons.append(f"execution_proof_error:{record.get('check')}")
        suite: dict[str, object] = {
            "schema_version": 1,
            "kind": "integration-suite",
            "run_id": plan["run_id"],
            "branch": branch,
            "merge_sha": merge_sha,
            "source_file_sha256": sources,
            "source_manifest_sha256": _digest(sources),
            "source_mode_by_path": modes,
            "projection_manifest_sha256": _digest({"files": sources, "modes": modes}),
            "mount_inventory_sha256": inventory,
            "check_plan_path": str(plan_path),
            "check_plan_sha256": plan_sha256,
            "baseline_path": str(baseline_path),
            "baseline_sha256": baseline_sha256,
            "checks": records,
            "regressions": sorted(set(regressions)),
            "proof_error": bool(reasons),
            "proof_errors": list(dict.fromkeys(reasons)),
            "execution_policy_mode": integration_policy.get("mode"),
            "created_at_epoch": time.time(),
            "status": "verified" if not reasons and not regressions else "proof_error",
        }
        proof_shape = {
            **suite,
            "phase": "verify",
            "plan_sha256": _digest({"integration": merge_sha, "branch": branch}),
        }
        validated = validate_suite_receipt(proof_shape, cast(str, plan["run_id"]), sources)
        if validated.get("complete") is not True:
            suite["proof_error"] = True
            suite["proof_errors"] = list(
                dict.fromkeys([*cast(list[str], suite["proof_errors"]), *cast(list[str], validated.get("reasons", []))])
            )
            suite["status"] = "proof_error"
        payload = canonical_json_bytes(suite)
        temporary = destination.with_name("." + destination.name + "." + uuid.uuid4().hex)
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(descriptor, payload)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            os.link(temporary, destination, follow_symlinks=False)
        finally:
            temporary.unlink(missing_ok=True)
        return {
            "status": suite["status"],
            "receipt_path": str(destination),
            "receipt_sha256": hashlib.sha256(payload).hexdigest(),
            "merge_sha": merge_sha,
            "source_manifest_sha256": suite["source_manifest_sha256"],
        }
    finally:
        if projection is not None:
            shutil.rmtree(projection, ignore_errors=True)


def _main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run frozen integration checks on a merged-tree export")
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--merge-sha", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--git-path", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        result = run_integration_checks(
            arguments.run_dir,
            arguments.repo_root,
            arguments.merge_sha,
            arguments.branch,
            arguments.git_path,
        )
    except (OSError, RuntimeError, TypeError, ValueError, subprocess.SubprocessError, tarfile.TarError) as exc:
        print(f"integration-checks: {exc}", file=sys.stderr)
        return 1
    print(canonical_json_bytes(result).decode("utf-8"))
    return 0 if result["status"] == "verified" else 1


if __name__ == "__main__":
    raise SystemExit(_main())
