#!/usr/bin/env python3
"""Fail-closed trusted command execution for Bugsweep coordinators.

The reviewed repository supplies only target argv. Backend policy is trusted
host configuration, and authoritative receipts never enter a target mount.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import resource
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence, cast


SCHEMA_VERSION = 1
FIXED_HOST_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
MAX_ARGV = 256
MAX_ARG_BYTES = 16 * 1024
MAX_ENV = 64
MAX_OUTPUTS = 32
MAX_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_SOURCE_FILE_BYTES = 64 * 1024 * 1024
MAX_SOURCE_FILES = 100_000
MAX_MOUNT_ENTRIES = 200_000
MAX_PATH_BYTES = 4096
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$")
_IMAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:+-]{0,511}@sha256:([0-9a-f]{64})$")
_UID_RE = re.compile(r"^[1-9][0-9]{0,9}:[1-9][0-9]{0,9}$")
_SECRET_RE = re.compile(
    r"(?:TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_KEY|ACCESS_KEY|AUTH|COOKIE|SESSION|SSH|DOCKER_HOST)",
    re.IGNORECASE,
)
_OUTPUT_KINDS = {"junit", "sarif", "host-adapter-json"}
_COMMON_POLICY_FIELDS = {
    "schema_version",
    "mode",
    "backend",
    "canonical_engine_path",
    "engine_sha256",
    "target_root",
    "scratch_root",
    "source_identity",
    "term_grace_seconds",
}
_DOCKER_POLICY_FIELDS = _COMMON_POLICY_FIELDS | {
    "image",
    "uid",
    "pids_limit",
    "memory_bytes",
    "cpus",
    "network_mode",
    "image_env_allowlist",
    "benchmark_profile",
    "source_mount_mode",
}


class ExecutionError(RuntimeError):
    """Trusted execution setup or artifact validation failed."""


def canonical_json_bytes(value: object) -> bytes:
    """Return the canonical bytes used by every receipt digest."""

    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
    ).encode("utf-8")


def _digest(value: object) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def _timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _is_within(path: Path, parent: Path) -> bool:
    return path == parent or parent in path.parents


def _existing_dir(value: object, label: str) -> Path:
    if not isinstance(value, (str, os.PathLike)):
        raise ValueError(f"{label} must be a path")
    raw = Path(value)
    if not raw.is_absolute() or len(os.fsencode(raw)) > MAX_PATH_BYTES:
        raise ValueError(f"{label} must be a bounded absolute path")
    try:
        resolved = raw.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"{label} is unavailable") from exc
    if not resolved.is_dir():
        raise ValueError(f"{label} must be a directory")
    return resolved


def _fresh_output_dir(value: object, cwd: Path, scratch_root: Path | None) -> Path:
    if not isinstance(value, (str, os.PathLike)):
        raise ValueError("output_dir must be a path")
    raw = Path(value)
    if not raw.is_absolute() or len(os.fsencode(raw)) > MAX_PATH_BYTES:
        raise ValueError("output_dir must be a bounded absolute path")
    if raw.exists() or raw.is_symlink():
        raise ValueError("output_dir must be fresh")
    parent = raw.parent.resolve(strict=True)
    candidate = parent / raw.name
    if _is_within(candidate, cwd):
        raise ValueError("output_dir must be outside the target")
    if scratch_root is not None and _is_within(candidate, scratch_root):
        raise ValueError("output_dir must be outside invocation scratch")
    candidate.mkdir(mode=0o700)
    return candidate


def _validate_command(command: Sequence[str]) -> list[str]:
    if isinstance(command, (str, bytes)) or not isinstance(command, Sequence):
        raise ValueError("command must be argv containing non-empty strings")
    argv = list(command)
    if not argv or len(argv) > MAX_ARGV:
        raise ValueError("command must be argv containing non-empty strings")
    if any(
        not isinstance(arg, str)
        or not arg
        or "\x00" in arg
        or len(arg.encode("utf-8")) > MAX_ARG_BYTES
        for arg in argv
    ):
        raise ValueError("command must be argv containing non-empty strings")
    return argv


def _validate_environment(env_allowlist: Mapping[str, str] | None) -> dict[str, str]:
    if env_allowlist is None:
        return {}
    if not isinstance(env_allowlist, Mapping) or len(env_allowlist) > MAX_ENV:
        raise ValueError("env_allowlist must be a bounded mapping")
    result: dict[str, str] = {}
    for key, value in env_allowlist.items():
        if not isinstance(key, str) or not _ENV_RE.fullmatch(key):
            raise ValueError("environment key is invalid")
        if _SECRET_RE.search(key):
            raise ValueError(f"credential-like environment key is forbidden: {key}")
        if not isinstance(value, str) or "\x00" in value or len(value.encode("utf-8")) > MAX_ARG_BYTES:
            raise ValueError(f"environment value is invalid: {key}")
        if key in {"PATH", "HOME", "TMPDIR", "BUGSWEEP_OUTPUT_DIR"}:
            raise ValueError(f"reserved environment key is forbidden: {key}")
        result[key] = value
    return dict(sorted(result.items()))


def _target_environment(
    env: Mapping[str, str], image_env: Mapping[str, str], output_path: str
) -> dict[str, str]:
    fixed = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/tmp/bugsweep-home",
        "TMPDIR": "/tmp",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "BUGSWEEP_OUTPUT_DIR": output_path,
    }
    return {**image_env, **fixed, **env}


def _validate_source_identity(value: object) -> dict[str, object]:
    if not isinstance(value, Mapping) or set(value) != {
        "kind",
        "sha256",
        "source_file_sha256",
    }:
        raise ValueError("source_identity must bind one content manifest")
    kind, digest, raw_files = (
        value.get("kind"),
        value.get("sha256"),
        value.get("source_file_sha256"),
    )
    if (
        kind != "content-manifest-sha256"
        or not isinstance(digest, str)
        or not _SHA256_RE.fullmatch(digest)
        or not isinstance(raw_files, Mapping)
        or not raw_files
        or len(raw_files) > MAX_SOURCE_FILES
    ):
        raise ValueError("source_identity must bind one content manifest")
    files: dict[str, str] = {}
    for raw_path, raw_digest in raw_files.items():
        path = _relative_output_path(raw_path)
        if not isinstance(raw_digest, str) or not _SHA256_RE.fullmatch(raw_digest):
            raise ValueError("source_identity contains an invalid file digest")
        files[path] = raw_digest
    files = dict(sorted(files.items()))
    if _digest(files) != digest:
        raise ValueError("source_identity manifest digest does not match its file map")
    return {"kind": kind, "sha256": digest, "source_file_sha256": files}


def _capture_source_files(
    cwd: Path, *, allow_git_pointer: bool = True, allow_symlinks: bool = True
) -> dict[str, str]:
    """Hash every mounted regular source file, excluding only exact .git metadata."""

    files: dict[str, str] = {}
    pending = [cwd]
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(iterator, key=lambda entry: entry.name)
        except OSError as exc:
            raise ValueError("source tree cannot be read safely") from exc
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(cwd).as_posix()
            if PurePosixPath(relative).parts[0] == ".git":
                if not allow_git_pointer:
                    raise ValueError("archive source must not contain .git metadata")
                try:
                    git_info = entry.stat(follow_symlinks=False)
                except OSError as exc:
                    raise ValueError(".git metadata cannot be inspected") from exc
                if relative != ".git" or not stat.S_ISREG(git_info.st_mode) or git_info.st_nlink != 1:
                    raise ValueError("target must use an isolated worktree .git pointer")
                continue
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise ValueError(f"source entry cannot be inspected: {relative}") from exc
            if stat.S_ISDIR(info.st_mode):
                pending.append(path)
            elif stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1 or len(files) >= MAX_SOURCE_FILES:
                    raise ValueError("source tree has hard links or too many regular files")
                try:
                    digest, _ = _sha256_relative(cwd, relative, MAX_SOURCE_FILE_BYTES)
                except (OSError, ExecutionError) as exc:
                    raise ValueError(
                        f"source identity path is not a bounded regular file: {relative}"
                    ) from exc
                files[relative] = digest
            elif stat.S_ISLNK(info.st_mode):
                if not allow_symlinks:
                    raise ValueError(f"archive source contains a symbolic link: {relative}")
            else:
                raise ValueError(f"source tree contains a special file: {relative}")
    if not files:
        raise ValueError("source tree contains no regular files")
    return dict(sorted(files.items()))


def _verify_source_identity(
    cwd: Path,
    identity: Mapping[str, object],
    *,
    source_mount_mode: str = "worktree-rw",
) -> None:
    expected = cast(Mapping[str, str], identity["source_file_sha256"])
    archive = source_mount_mode == "archive-ro"
    actual = _capture_source_files(
        cwd, allow_git_pointer=not archive, allow_symlinks=not archive
    )
    if actual != expected:
        missing = sorted(set(actual) - set(expected))
        extra = sorted(set(expected) - set(actual))
        changed = sorted(
            path for path in set(actual) & set(expected) if actual[path] != expected[path]
        )
        detail = (missing or extra or changed or ["unknown"])[0]
        raise ValueError(f"source identity is incomplete or mismatched: {detail}")


def _mount_inventory(root: Path) -> str:
    """Reject special files and bind a stable pre-start view of the full mount."""

    root = root.resolve(strict=True)
    records: list[list[object]] = []
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            if directory != root and directory.is_symlink():
                raise ValueError("target mount directory changed to a symlink")
            if not _is_within(directory.resolve(strict=True), root):
                raise ValueError("target mount directory escaped its root")
        except OSError as exc:
            raise ValueError("target mount directory cannot be resolved") from exc
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(iterator, key=lambda entry: entry.name)
        except OSError as exc:
            raise ValueError("target mount cannot be read safely") from exc
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            if len(records) >= MAX_MOUNT_ENTRIES:
                raise ValueError("target mount exceeds its entry limit")
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise ValueError(f"target mount entry cannot be inspected: {relative}") from exc
            base = [
                relative,
                info.st_mode,
                info.st_dev,
                info.st_ino,
                info.st_nlink,
                info.st_size,
                info.st_mtime_ns,
            ]
            if stat.S_ISDIR(info.st_mode):
                records.append([*base, "directory"])
                pending.append(path)
            elif stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1:
                    raise ValueError(f"target mount contains a hard-linked file: {relative}")
                records.append([*base, "regular"])
            elif stat.S_ISLNK(info.st_mode):
                try:
                    resolved = path.resolve(strict=True)
                except OSError as exc:
                    raise ValueError(f"target mount contains a broken symlink: {relative}") from exc
                if not _is_within(resolved, root):
                    raise ValueError(f"target mount symlink escapes allowed root: {relative}")
                records.append([*base, "symlink", os.readlink(path)])
            else:
                raise ValueError(f"target mount contains a special file: {relative}")
    return _digest(sorted(records))


def _relative_output_path(value: object) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError("output path must be a relative POSIX path")
    path = PurePosixPath(value)
    if path.is_absolute() or value != path.as_posix() or any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError("output path must be a relative POSIX path")
    if len(value.encode("utf-8")) > MAX_PATH_BYTES:
        raise ValueError("output path is too long")
    return value


def _validate_outputs(outputs: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
    if isinstance(outputs, (str, bytes)) or not isinstance(outputs, Sequence) or len(outputs) > MAX_OUTPUTS:
        raise ValueError("predeclared_outputs must be a bounded sequence")
    normalized: list[dict[str, object]] = []
    seen: set[str] = set()
    for item in outputs:
        if not isinstance(item, Mapping) or set(item) != {"path", "kind", "max_bytes"}:
            raise ValueError("each output requires path, kind, and max_bytes")
        path = _relative_output_path(item["path"])
        kind, max_bytes = item["kind"], item["max_bytes"]
        if kind not in _OUTPUT_KINDS:
            raise ValueError("output kind is not supported")
        if not isinstance(max_bytes, int) or isinstance(max_bytes, bool) or not 0 < max_bytes <= MAX_OUTPUT_BYTES:
            raise ValueError("output max_bytes is invalid")
        if path in seen or path in {"stdout.log", "stderr.log"}:
            raise ValueError("output path is duplicated or reserved")
        seen.add(path)
        normalized.append({"path": path, "kind": kind, "max_bytes": max_bytes})
    return sorted(normalized, key=lambda item: cast(str, item["path"]))


def _sha256_file(path: Path, *, max_bytes: int | None = None) -> tuple[str, int]:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        return _sha256_fd(fd, max_bytes)
    finally:
        os.close(fd)


def _sha256_fd(fd: int, max_bytes: int | None) -> tuple[str, int]:
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode):
        raise ExecutionError("artifact is not a regular file")
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = os.read(fd, 64 * 1024)
        if not chunk:
            break
        size += len(chunk)
        if max_bytes is not None and size > max_bytes:
            raise ExecutionError("artifact exceeds its declared byte limit")
        digest.update(chunk)
    after = os.fstat(fd)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ):
        raise ExecutionError("artifact changed while it was read")
    return digest.hexdigest(), size


def _sha256_relative(root: Path, relative: str, max_bytes: int) -> tuple[str, int]:
    parts = PurePosixPath(relative).parts
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    directory_flags = flags | getattr(os, "O_DIRECTORY", 0)
    descriptors = [os.open(root, directory_flags)]
    try:
        for part in parts[:-1]:
            descriptors.append(os.open(part, directory_flags, dir_fd=descriptors[-1]))
        file_fd = os.open(parts[-1], flags, dir_fd=descriptors[-1])
        try:
            return _sha256_fd(file_fd, max_bytes)
        finally:
            os.close(file_fd)
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _engine_identity(policy: Mapping[str, object]) -> tuple[Path | None, str | None]:
    raw_path, expected = policy.get("canonical_engine_path"), policy.get("engine_sha256")
    if not isinstance(raw_path, str) or not isinstance(expected, str) or not _SHA256_RE.fullmatch(expected):
        raise ValueError("engine path and sha256 are required")
    path = Path(raw_path)
    if not path.is_absolute() or path.is_symlink():
        return None, "engine_path_not_canonical"
    try:
        resolved = path.resolve(strict=True)
        file_stat = path.stat()
        actual, _ = _sha256_file(path)
    except (OSError, ExecutionError):
        return None, "engine_unavailable"
    if resolved != path or not stat.S_ISREG(file_stat.st_mode):
        return None, "engine_path_not_canonical"
    if actual != expected:
        return None, "engine_identity_mismatch"
    return path, None


def _bounded_json_file(path_value: object, cwd: Path, scratch_root: Path) -> tuple[dict[str, object], str]:
    if not isinstance(path_value, str):
        raise ValueError("trusted receipt path must be absolute")
    path = Path(path_value)
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("trusted receipt path must be an absolute regular file")
    resolved = path.resolve(strict=True)
    if _is_within(resolved, cwd) or _is_within(resolved, scratch_root):
        raise ValueError("trusted receipt must be outside target and scratch")
    raw = _read_bounded_bytes(resolved, 64 * 1024)
    digest = hashlib.sha256(raw).hexdigest()
    try:
        value = json.loads(raw)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValueError("trusted receipt is not bounded UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise ValueError("trusted receipt must contain one JSON object")
    return cast(dict[str, object], value), digest


def _identity_pair(value: object, label: str) -> dict[str, str]:
    if not isinstance(value, Mapping) or set(value) != {"name", "id"}:
        raise ValueError(f"{label} requires exact name and id")
    name, identity = value.get("name"), value.get("id")
    if (
        not isinstance(name, str)
        or not re.fullmatch(r"bugsweep-[A-Za-z0-9_.-]{1,100}", name)
        or not isinstance(identity, str)
        or not _SHA256_RE.fullmatch(identity)
    ):
        raise ValueError(f"{label} identity is invalid")
    return {"name": name, "id": identity}


def _validate_benchmark_profile(
    value: object, cwd: Path, scratch_root: Path
) -> dict[str, object]:
    required = {
        "host",
        "proxy_receipt",
        "internal_network",
        "egress_network",
        "proxy",
        "upstream",
        "analysis",
        "client",
        "arms",
        "limits",
    }
    if not isinstance(value, Mapping) or set(value) != required:
        raise ValueError("benchmark_profile has invalid fields")
    host = value.get("host")
    if host not in {"claude", "codex"}:
        raise ValueError("benchmark host must be claude or codex")
    internal = _identity_pair(value.get("internal_network"), "internal network")
    egress = _identity_pair(value.get("egress_network"), "egress network")
    if internal == egress:
        raise ValueError("benchmark networks must be distinct")
    proxy = value.get("proxy")
    if not isinstance(proxy, Mapping) or set(proxy) != {"container_name", "container_id", "image_digest"}:
        raise ValueError("benchmark proxy identity is invalid")
    proxy_name, proxy_id, proxy_image = (
        proxy.get("container_name"),
        proxy.get("container_id"),
        proxy.get("image_digest"),
    )
    if (
        not isinstance(proxy_name, str)
        or not re.fullmatch(r"bugsweep-[A-Za-z0-9_.-]{1,100}", proxy_name)
        or not isinstance(proxy_id, str)
        or not _SHA256_RE.fullmatch(proxy_id)
        or not isinstance(proxy_image, str)
        or not _SHA256_RE.fullmatch(proxy_image)
    ):
        raise ValueError("benchmark proxy identity is invalid")
    expected_upstream = {
        "claude": ("api.anthropic.com", ["/v1/messages"]),
        "codex": ("api.openai.com", ["/v1/responses"]),
    }
    upstream = value.get("upstream")
    if not isinstance(upstream, Mapping) or set(upstream) != {"host", "allowed_paths"}:
        raise ValueError("benchmark upstream is invalid")
    if (upstream.get("host"), upstream.get("allowed_paths")) != expected_upstream[cast(str, host)]:
        raise ValueError("benchmark upstream does not match its host")
    analysis = value.get("analysis")
    if not isinstance(analysis, Mapping) or set(analysis) != {"entrypoint", "entrypoint_sha256"}:
        raise ValueError("benchmark analysis adapter is invalid")
    if (
        analysis.get("entrypoint") != "/usr/local/bin/bench-host-adapter"
        or not isinstance(analysis.get("entrypoint_sha256"), str)
        or not _SHA256_RE.fullmatch(cast(str, analysis["entrypoint_sha256"]))
    ):
        raise ValueError("benchmark analysis adapter is invalid")
    client = value.get("client")
    if client != {"inert_credential_literal": "benchmark-inert-client-credential"}:
        raise ValueError("benchmark client credential must be the fixed inert literal")
    arms = value.get("arms")
    if not isinstance(arms, Mapping) or set(arms) != {"current", "previous", "baseline"}:
        raise ValueError("benchmark profile must bind all three arm snapshots")
    normalized_arms: dict[str, dict[str, str]] = {}
    for arm, identity in arms.items():
        if not isinstance(identity, Mapping) or set(identity) != {"skill_revision", "skill_content_sha256"}:
            raise ValueError("benchmark arm identity is invalid")
        revision, digest = identity.get("skill_revision"), identity.get("skill_content_sha256")
        if (
            not isinstance(revision, str)
            or not revision
            or len(revision) > 128
            or not isinstance(digest, str)
            or not _SHA256_RE.fullmatch(digest)
        ):
            raise ValueError("benchmark arm identity is invalid")
        normalized_arms[cast(str, arm)] = {"skill_revision": revision, "skill_content_sha256": digest}
    limits = value.get("limits")
    limit_keys = {
        "wall_clock_seconds",
        "max_turns",
        "max_input_tokens",
        "max_output_tokens",
        "max_spend_usd",
        "enforcement",
    }
    if not isinstance(limits, Mapping) or set(limits) != limit_keys:
        raise ValueError("benchmark limits are invalid")
    if any(
        not isinstance(limits[key], (int, float))
        or isinstance(limits[key], bool)
        or not math.isfinite(cast(float, limits[key]))
        or cast(float, limits[key]) <= 0
        for key in limit_keys - {"enforcement"}
    ):
        raise ValueError("benchmark numeric limits are invalid")
    enforcement = limits.get("enforcement")
    if not isinstance(enforcement, Mapping) or set(enforcement) != limit_keys - {"enforcement"}:
        raise ValueError("benchmark limit enforcement map is invalid")
    if any(not isinstance(item, str) or not item or len(item) > 256 for item in enforcement.values()):
        raise ValueError("benchmark limit enforcement description is invalid")
    receipt_ref = value.get("proxy_receipt")
    if not isinstance(receipt_ref, Mapping) or set(receipt_ref) != {"path", "sha256", "schema_version", "owner"}:
        raise ValueError("benchmark proxy receipt reference is invalid")
    if receipt_ref.get("schema_version") != 1 or receipt_ref.get("owner") != "bench/lib/proxy.sh":
        raise ValueError("benchmark proxy receipt producer is invalid")
    receipt, actual_receipt_sha = _bounded_json_file(receipt_ref.get("path"), cwd, scratch_root)
    if receipt_ref.get("sha256") != actual_receipt_sha:
        raise ValueError("benchmark proxy receipt digest mismatch")
    expected_receipt = {
        "schema_version": 1,
        "owner": "bench/lib/proxy.sh",
        "host": host,
        "internal_network": internal,
        "egress_network": egress,
        "proxy": {
            "container_name": proxy_name,
            "container_id": proxy_id,
        },
        "upstream": {
            "host": upstream["host"],
            "allowed_paths": upstream["allowed_paths"],
        },
    }
    for key, expected in expected_receipt.items():
        if key == "proxy":
            actual_proxy = receipt.get("proxy")
            if not isinstance(actual_proxy, Mapping) or any(actual_proxy.get(k) != v for k, v in expected.items()):
                raise ValueError("benchmark proxy receipt identity mismatch")
        elif receipt.get(key) != expected:
            raise ValueError("benchmark proxy receipt identity mismatch")
    secret = receipt.get("secret")
    if secret != {
        "mount": "/run/secrets/provider-key",
        "mode": "0600",
        "outside_target_and_results": True,
    }:
        raise ValueError("benchmark proxy secret boundary is invalid")
    proxy_policy = receipt.get("policy")
    if (
        not isinstance(proxy_policy, Mapping)
        or set(proxy_policy) != {"mount", "sha256", "nonsecret"}
        or proxy_policy.get("mount") != "/etc/bugsweep/proxy-policy.json"
        or not isinstance(proxy_policy.get("sha256"), str)
        or not _SHA256_RE.fullmatch(cast(str, proxy_policy["sha256"]))
        or proxy_policy.get("nonsecret") is not True
    ):
        raise ValueError("benchmark proxy policy boundary is invalid")
    actual_image_id = cast(Mapping[str, object], receipt["proxy"]).get("image_digest")
    if actual_image_id != f"sha256:{proxy_image}":
        raise ValueError("benchmark proxy image digest mismatch")
    if receipt.get("limits") != limits:
        raise ValueError("benchmark proxy limit binding mismatch")
    return {
        "host": host,
        "proxy_receipt": dict(receipt_ref),
        "internal_network": internal,
        "egress_network": egress,
        "proxy": dict(proxy),
        "proxy_image_id": actual_image_id,
        "upstream": dict(upstream),
        "analysis": dict(analysis),
        "client": dict(client),
        "arms": normalized_arms,
        "limits": dict(limits),
        "proxy_policy": dict(proxy_policy),
    }


def _validate_policy(
    policy: Mapping[str, object], cwd: Path
) -> tuple[dict[str, object], Path, Path | None, str | None]:
    if not isinstance(policy, Mapping):
        raise ValueError("policy must be trusted external configuration")
    mode, backend = policy.get("mode"), policy.get("backend")
    if policy.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("policy schema_version must be 1")
    if (mode, backend) not in {("required-untrusted", "docker"), ("trusted-worktree", "native")}:
        raise ValueError("unsupported execution policy")
    allowed = _DOCKER_POLICY_FIELDS if backend == "docker" else _COMMON_POLICY_FIELDS
    if set(policy) - allowed:
        raise ValueError("policy contains unsupported fields")
    target_root = _existing_dir(policy.get("target_root"), "target_root")
    if target_root != cwd:
        raise ValueError("target_root must equal canonical cwd")
    scratch_root = _existing_dir(policy.get("scratch_root"), "scratch_root")
    if _is_within(scratch_root, cwd) or _is_within(cwd, scratch_root):
        raise ValueError("scratch_root must be isolated from the target")
    source_identity = _validate_source_identity(policy.get("source_identity"))
    grace = policy.get("term_grace_seconds")
    if not isinstance(grace, (int, float)) or isinstance(grace, bool) or not math.isfinite(grace) or not 0 <= grace <= 30:
        raise ValueError("term_grace_seconds is invalid")
    normalized = dict(policy)
    normalized["target_root"] = str(target_root)
    normalized["scratch_root"] = str(scratch_root)
    normalized["source_identity"] = source_identity
    if backend == "docker":
        source_mount_mode = policy.get("source_mount_mode", "worktree-rw")
        if source_mount_mode not in {"worktree-rw", "archive-ro"}:
            raise ValueError("source_mount_mode must be worktree-rw or archive-ro")
        normalized["source_mount_mode"] = source_mount_mode
        _verify_source_identity(cwd, source_identity, source_mount_mode=source_mount_mode)
        image = policy.get("image")
        match = _IMAGE_RE.fullmatch(image) if isinstance(image, str) else None
        if match is None:
            raise ValueError("container image must be pinned by sha256 digest")
        uid = policy.get("uid")
        if not isinstance(uid, str) or not _UID_RE.fullmatch(uid):
            raise ValueError("container uid must be a non-root uid:gid")
        pids = policy.get("pids_limit")
        memory = policy.get("memory_bytes")
        cpus = policy.get("cpus")
        if not isinstance(pids, int) or isinstance(pids, bool) or not 2 <= pids <= 4096:
            raise ValueError("pids_limit is invalid")
        if not isinstance(memory, int) or isinstance(memory, bool) or not 16 * 1024 * 1024 <= memory <= 64 * 1024**3:
            raise ValueError("memory_bytes is invalid")
        if not isinstance(cpus, (int, float)) or isinstance(cpus, bool) or not math.isfinite(cpus) or not 0.1 <= cpus <= 64:
            raise ValueError("cpus is invalid")
        normalized["image_env_allowlist"] = _validate_environment(
            cast(Mapping[str, str] | None, policy.get("image_env_allowlist"))
        )
        network_mode = policy.get("network_mode")
        if network_mode not in {"none", "approved-proxy-only"}:
            raise ValueError("network_mode must be none or approved-proxy-only")
        if network_mode == "none" and policy.get("benchmark_profile") is not None:
            raise ValueError("standard network policy cannot include a benchmark profile")
        if network_mode == "approved-proxy-only":
            if source_mount_mode != "archive-ro":
                raise ValueError("approved proxy execution requires an archive-ro source mount")
            normalized["benchmark_profile"] = _validate_benchmark_profile(
                policy.get("benchmark_profile"), cwd, scratch_root
            )
    else:
        _verify_source_identity(cwd, source_identity)
    engine, unavailable_reason = _engine_identity(normalized)
    return normalized, scratch_root, engine, unavailable_reason


def execution_config_sha256(
    policy: Mapping[str, object], outputs: Sequence[Mapping[str, object]]
) -> str:
    """Hash stable semantics; source and invocation resource IDs are separate receipt fields."""

    stable_policy = {
        key: value
        for key, value in policy.items()
        if key not in {"source_identity", "target_root", "scratch_root"}
    }
    profile = stable_policy.get("benchmark_profile")
    if isinstance(profile, Mapping):
        proxy = cast(Mapping[str, object], profile["proxy"])
        stable_policy["benchmark_profile"] = {
            key: value
            for key, value in profile.items()
            if key not in {"proxy_receipt", "internal_network", "egress_network", "proxy"}
        } | {"proxy_image_digest": proxy["image_digest"]}
    return _digest({"policy": stable_policy, "outputs": list(outputs)})


def execution_environment_sha256(env: Mapping[str, str]) -> str:
    return _digest(
        {
            "allowlist": dict(sorted(env.items())),
            "fixed_path": FIXED_HOST_PATH,
            "home": "ephemeral",
            "scratch_mount": "/bugsweep-output",
        }
    )


def build_backend_argv(
    command: Sequence[str],
    cwd: Path | str,
    invocation_scratch: Path | str,
    policy: Mapping[str, object],
    container_name: str,
    env_allowlist: Mapping[str, str] | None = None,
) -> list[str]:
    """Build argv only; this function does not probe or launch the backend."""

    argv = _validate_command(command)
    target = _existing_dir(cwd, "cwd")
    scratch = _existing_dir(invocation_scratch, "invocation_scratch")
    normalized, scratch_root, engine, unavailable = _validate_policy(policy, target)
    if unavailable or engine is None:
        raise ExecutionError(unavailable or "engine_unavailable")
    if not _is_within(scratch, scratch_root) or scratch == scratch_root:
        raise ValueError("invocation_scratch must be fresh under scratch_root")
    env = _validate_environment(env_allowlist)
    if normalized["backend"] == "native":
        command_engine = Path(argv[0])
        if not command_engine.is_absolute() or command_engine.is_symlink() or command_engine.resolve(strict=True) != engine:
            raise ValueError("native command must use the configured canonical engine")
        return argv
    if not re.fullmatch(r"bugsweep-[0-9a-f]{32}", container_name):
        raise ValueError("container name is invalid")
    if any(character in str(target) + str(scratch) for character in {",", "\n", "\r"}):
        raise ValueError("Docker mount source contains an unsupported delimiter")
    target_env = _target_environment(
        env,
        cast(Mapping[str, str], normalized["image_env_allowlist"]),
        "/bugsweep-output",
    )
    network = "none"
    if normalized["network_mode"] == "approved-proxy-only":
        benchmark = cast(Mapping[str, object], normalized["benchmark_profile"])
        internal = cast(Mapping[str, str], benchmark["internal_network"])
        network = internal["name"]
        credential_key = "ANTHROPIC_API_KEY" if benchmark["host"] == "claude" else "OPENAI_API_KEY"
        target_env[credential_key] = "benchmark-inert-client-credential"
        target_env["BUGSWEEP_PROXY_URL"] = (
            "http://" + cast(Mapping[str, str], benchmark["proxy"])["container_name"] + ":8888"
        )
    result = [
        str(engine),
        "create",
        "--name",
        container_name,
        "--label",
        f"org.bugsweep.invocation={container_name.removeprefix('bugsweep-')}",
        "--network",
        network,
        "--ipc",
        "none",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges:true",
        "--pids-limit",
        str(normalized["pids_limit"]),
        "--memory",
        str(normalized["memory_bytes"]),
        "--memory-swap",
        str(normalized["memory_bytes"]),
        "--cpus",
        str(normalized["cpus"]),
        "--user",
        cast(str, normalized["uid"]),
        "--read-only",
        "--tmpfs",
        "/tmp:rw,noexec,nosuid,nodev,size=67108864",
        "--mount",
        (
            f"type=bind,src={target},dst=/workspace,readonly"
            if normalized["source_mount_mode"] == "archive-ro"
            else f"type=bind,src={target},dst=/workspace,rw"
        ),
        "--mount",
        f"type=bind,src={scratch},dst=/bugsweep-output,rw",
        "--workdir",
        "/workspace",
        "--entrypoint",
        argv[0],
    ]
    for key, value in sorted(target_env.items()):
        result.extend(["--env", f"{key}={value}"])
    result.extend([cast(str, normalized["image"]), *argv[1:]])
    return result


def _env_from_inspect(value: object) -> dict[str, str]:
    if not isinstance(value, list):
        raise ExecutionError("Docker readback environment is invalid")
    result: dict[str, str] = {}
    for item in value:
        if not isinstance(item, str) or "=" not in item:
            raise ExecutionError("Docker readback environment is invalid")
        key, content = item.split("=", 1)
        if key in result:
            raise ExecutionError("Docker readback environment contains duplicates")
        result[key] = content
    return result


def _analysis_network(
    policy: Mapping[str, object], target_env: dict[str, str]
) -> tuple[str, str | None]:
    if policy["network_mode"] == "none":
        return "none", None
    profile = cast(Mapping[str, object], policy["benchmark_profile"])
    internal = cast(Mapping[str, str], profile["internal_network"])
    credential_key = "ANTHROPIC_API_KEY" if profile["host"] == "claude" else "OPENAI_API_KEY"
    target_env[credential_key] = "benchmark-inert-client-credential"
    target_env["BUGSWEEP_PROXY_URL"] = (
        "http://" + cast(Mapping[str, str], profile["proxy"])["container_name"] + ":8888"
    )
    return internal["name"], internal["id"]


def _verify_analysis_inspect(
    inspect: Mapping[str, object],
    policy: Mapping[str, object],
    cwd: Path,
    scratch: Path,
    container_id: str,
    container_name: str,
    command: Sequence[str],
    env: Mapping[str, str],
) -> str:
    if (
        policy.get("network_mode") == "approved-proxy-only"
        and policy.get("source_mount_mode") != "archive-ro"
    ):
        raise ExecutionError("approved proxy execution requires an archive-ro source mount")
    if inspect.get("Id") != container_id or inspect.get("Name") != f"/{container_name}":
        raise ExecutionError("Docker readback container identity mismatch")
    config = inspect.get("Config")
    host = inspect.get("HostConfig")
    network_settings = inspect.get("NetworkSettings")
    mounts = inspect.get("Mounts")
    if not all(isinstance(item, Mapping) for item in (config, host, network_settings)):
        raise ExecutionError("Docker readback is missing required objects")
    config = cast(Mapping[str, object], config)
    host = cast(Mapping[str, object], host)
    network_settings = cast(Mapping[str, object], network_settings)
    if config.get("Image") != policy["image"]:
        raise ExecutionError("Docker readback image mismatch")
    if config.get("User") != policy["uid"] or config.get("WorkingDir") != "/workspace":
        raise ExecutionError("Docker readback user or workdir mismatch")
    if config.get("Entrypoint") != [command[0]] or config.get("Cmd") != list(command[1:]):
        raise ExecutionError("Docker readback command mismatch")
    labels = config.get("Labels")
    if (
        not isinstance(labels, Mapping)
        or labels.get("org.bugsweep.invocation") != container_name.removeprefix("bugsweep-")
    ):
        raise ExecutionError("Docker readback invocation ownership mismatch")
    expected_env = _target_environment(
        env,
        cast(Mapping[str, str], policy["image_env_allowlist"]),
        "/bugsweep-output",
    )
    network_name, network_id = _analysis_network(policy, expected_env)
    if _env_from_inspect(config.get("Env")) != expected_env:
        raise ExecutionError("Docker readback environment mismatch")
    if policy["network_mode"] == "approved-proxy-only":
        profile = cast(Mapping[str, object], policy["benchmark_profile"])
        analysis = cast(Mapping[str, str], profile["analysis"])
        if command[0] != analysis["entrypoint"]:
            raise ExecutionError("benchmark adapter entrypoint mismatch")
        if labels.get("org.bugsweep.adapter.sha256") != analysis["entrypoint_sha256"]:
            raise ExecutionError("benchmark adapter digest label mismatch")
        if labels.get("org.bugsweep.arms.sha256") != _digest(profile["arms"]):
            raise ExecutionError("benchmark arm snapshot label mismatch")
    expected_host_values = {
        "NetworkMode": network_name,
        "IpcMode": "none",
        "Privileged": False,
        "ReadonlyRootfs": True,
        "PidsLimit": policy["pids_limit"],
        "Memory": policy["memory_bytes"],
        "MemorySwap": policy["memory_bytes"],
        "NanoCpus": int(cast(float, policy["cpus"]) * 1_000_000_000),
    }
    if any(host.get(key) != value for key, value in expected_host_values.items()):
        raise ExecutionError("Docker readback host limits mismatch")
    if set(cast(list[object], host.get("CapDrop") or [])) != {"ALL"} or host.get("CapAdd") not in (None, []):
        raise ExecutionError("Docker readback capabilities mismatch")
    if set(cast(list[object], host.get("SecurityOpt") or [])) not in (
        {"no-new-privileges"},
        {"no-new-privileges:true"},
    ):
        raise ExecutionError("Docker readback security options mismatch")
    if any(
        host.get(key) not in (None, [], "", {})
        for key in (
            "Binds",
            "Devices",
            "DeviceRequests",
            "PidMode",
            "PortBindings",
            "Links",
            "VolumesFrom",
        )
    ) or host.get("PublishAllPorts") not in (None, False):
        raise ExecutionError("Docker readback exposes an unsupported host surface")
    tmpfs = host.get("Tmpfs")
    if not isinstance(tmpfs, Mapping) or set(tmpfs) != {"/tmp"}:
        raise ExecutionError("Docker readback tmpfs mismatch")
    tmpfs_options = set(str(tmpfs["/tmp"]).split(","))
    if tmpfs_options != {"rw", "noexec", "nosuid", "nodev", "size=67108864"}:
        raise ExecutionError("Docker readback tmpfs mismatch")
    if not isinstance(mounts, list) or len(mounts) != 2:
        raise ExecutionError("Docker readback mount count mismatch")
    configured_mounts = host.get("Mounts")
    if not isinstance(configured_mounts, list) or len(configured_mounts) != 2:
        raise ExecutionError("Docker HostConfig mount count mismatch")
    source_read_only = policy.get("source_mount_mode") == "archive-ro"
    configured = {
        mount.get("Target"): (mount.get("Source"), mount.get("ReadOnly"))
        for mount in configured_mounts
        if isinstance(mount, Mapping) and mount.get("Type") == "bind"
    }
    if configured != {
        "/workspace": (str(cwd), source_read_only),
        "/bugsweep-output": (str(scratch), False),
    }:
        raise ExecutionError("Docker HostConfig mount mismatch")
    observed_mounts: dict[str, tuple[str, bool]] = {}
    for mount in mounts:
        if not isinstance(mount, Mapping) or mount.get("Type") != "bind":
            raise ExecutionError("Docker readback contains a non-bind mount")
        destination, source, writable = mount.get("Destination"), mount.get("Source"), mount.get("RW")
        if not isinstance(destination, str) or not isinstance(source, str) or not isinstance(writable, bool):
            raise ExecutionError("Docker readback mount is malformed")
        observed_mounts[destination] = (source, writable)
    if observed_mounts != {
        "/workspace": (str(cwd), not source_read_only),
        "/bugsweep-output": (str(scratch), True),
    }:
        raise ExecutionError("Docker readback mount mismatch")
    networks = network_settings.get("Networks")
    if policy["network_mode"] == "none":
        if networks not in ({}, None):
            if not isinstance(networks, Mapping) or set(networks) != {"none"}:
                raise ExecutionError("Docker readback unexpectedly attaches a network")
            none_attachment = networks["none"]
            if not isinstance(none_attachment, Mapping) or any(
                none_attachment.get(field) not in (None, "")
                for field in ("Gateway", "IPAddress", "GlobalIPv6Address")
            ):
                raise ExecutionError("Docker none network exposes an address or gateway")
        return "verified_denied"
    if not isinstance(networks, Mapping) or set(networks) != {network_name}:
        raise ExecutionError("analysis container has an ambient network attachment")
    attachment = networks[network_name]
    if not isinstance(attachment, Mapping) or attachment.get("NetworkID") != network_id:
        raise ExecutionError("analysis internal network identity mismatch")
    return "approved_proxy_only_verified"


def _verify_benchmark_dependencies(
    readback: Mapping[str, object], policy: Mapping[str, object], analysis_id: str
) -> None:
    profile = cast(Mapping[str, object], policy["benchmark_profile"])
    proxy_expected = cast(Mapping[str, str], profile["proxy"])
    internal = cast(Mapping[str, str], profile["internal_network"])
    egress = cast(Mapping[str, str], profile["egress_network"])
    proxy = readback.get("proxy")
    networks = readback.get("networks")
    if not isinstance(proxy, Mapping) or proxy.get("Id") != proxy_expected["container_id"]:
        raise ExecutionError("benchmark proxy container identity mismatch")
    if proxy.get("Name") != "/" + proxy_expected["container_name"]:
        raise ExecutionError("benchmark proxy container name mismatch")
    proxy_config = proxy.get("Config")
    proxy_host = proxy.get("HostConfig")
    proxy_settings = proxy.get("NetworkSettings")
    if not all(isinstance(item, Mapping) for item in (proxy_config, proxy_host, proxy_settings)):
        raise ExecutionError("benchmark proxy readback is incomplete")
    proxy_config = cast(Mapping[str, object], proxy_config)
    proxy_host = cast(Mapping[str, object], proxy_host)
    proxy_settings = cast(Mapping[str, object], proxy_settings)
    if proxy.get("Image") != profile["proxy_image_id"]:
        raise ExecutionError("benchmark proxy image readback mismatch")
    configured_image = proxy_config.get("Image")
    configured_match = (
        _IMAGE_RE.fullmatch(configured_image) if isinstance(configured_image, str) else None
    )
    if (
        configured_match is None
        or configured_match.group(1)
        != cast(Mapping[str, str], profile["proxy"])["image_digest"]
    ):
        raise ExecutionError("benchmark proxy configured image is not digest pinned")
    if (
        proxy_config.get("Entrypoint") != ["/usr/local/bin/bugsweep-provider-proxy"]
        or proxy_config.get("Cmd") not in (None, [])
        or proxy_config.get("User") != "65534:65534"
        or proxy_config.get("WorkingDir") != "/"
    ):
        raise ExecutionError("benchmark proxy process identity mismatch")
    expected_proxy_host = {
        "NetworkMode": egress["name"],
        "IpcMode": "none",
        "PidMode": "",
        "Privileged": False,
        "ReadonlyRootfs": True,
        "PidsLimit": 64,
        "Memory": 134217728,
        "MemorySwap": 134217728,
        "NanoCpus": 1_000_000_000,
    }
    if any(proxy_host.get(key) != expected for key, expected in expected_proxy_host.items()):
        raise ExecutionError("benchmark proxy confinement or limits mismatch")
    if (
        set(cast(list[object], proxy_host.get("CapDrop") or [])) != {"ALL"}
        or proxy_host.get("CapAdd") not in (None, [])
        or set(cast(list[object], proxy_host.get("SecurityOpt") or []))
        not in ({"no-new-privileges"}, {"no-new-privileges:true"})
        or any(
            proxy_host.get(key) not in (None, [], "", {})
            for key in (
                "Binds",
                "Devices",
                "DeviceRequests",
                "PortBindings",
                "Links",
                "VolumesFrom",
                "ExtraHosts",
            )
        )
        or proxy_host.get("PublishAllPorts") not in (None, False)
    ):
        raise ExecutionError("benchmark proxy exposes an unsupported host surface")
    restart = proxy_host.get("RestartPolicy")
    if restart not in (None, {}) and (
        not isinstance(restart, Mapping) or restart.get("Name") not in (None, "", "no")
    ):
        raise ExecutionError("benchmark proxy restart policy is unsafe")
    proxy_tmpfs = proxy_host.get("Tmpfs")
    if not isinstance(proxy_tmpfs, Mapping) or set(proxy_tmpfs) != {"/tmp"}:
        raise ExecutionError("benchmark proxy tmpfs mismatch")
    if set(str(proxy_tmpfs["/tmp"]).split(",")) != {
        "rw",
        "noexec",
        "nosuid",
        "nodev",
        "size=16777216",
    }:
        raise ExecutionError("benchmark proxy tmpfs mismatch")
    proxy_networks = proxy_settings.get("Networks")
    if not isinstance(proxy_networks, Mapping):
        raise ExecutionError("benchmark proxy network readback is incomplete")
    if set(proxy_networks) != {internal["name"], egress["name"]}:
        raise ExecutionError("benchmark proxy has an ambient network attachment")
    for expected in (internal, egress):
        attachment = proxy_networks.get(expected["name"])
        if not isinstance(attachment, Mapping) or attachment.get("NetworkID") != expected["id"]:
            raise ExecutionError("benchmark proxy network identity mismatch")
    proxy_environment = _env_from_inspect(proxy_config.get("Env"))
    if proxy_environment.get("BUGSWEEP_PROXY_POLICY") != "/etc/bugsweep/proxy-policy.json":
        raise ExecutionError("benchmark proxy policy environment is invalid")
    if any(_SECRET_RE.search(key) for key in proxy_environment):
        raise ExecutionError("benchmark proxy has an ambient credential environment")
    proxy_mounts = proxy.get("Mounts")
    configured_mounts = proxy_host.get("Mounts")
    if (
        not isinstance(proxy_mounts, list)
        or len(proxy_mounts) != 2
        or not isinstance(configured_mounts, list)
        or len(configured_mounts) != 2
    ):
        raise ExecutionError("benchmark proxy mount readback is invalid")
    observed: dict[str, tuple[str, bool]] = {}
    for mount in proxy_mounts:
        if not isinstance(mount, Mapping) or mount.get("Type") != "bind":
            raise ExecutionError("benchmark proxy mount readback is invalid")
        destination, source, writable = mount.get("Destination"), mount.get("Source"), mount.get("RW")
        if not isinstance(destination, str) or not isinstance(source, str) or writable is not False:
            raise ExecutionError("benchmark proxy mount readback is invalid")
        observed[destination] = (source, writable)
    if set(observed) != {"/run/secrets/provider-key", "/etc/bugsweep/proxy-policy.json"}:
        raise ExecutionError("benchmark proxy mount destinations are invalid")
    configured: dict[str, tuple[str, bool]] = {}
    for mount in configured_mounts:
        if not isinstance(mount, Mapping) or mount.get("Type") != "bind":
            raise ExecutionError("benchmark proxy configured mount is invalid")
        destination, source, read_only = mount.get("Target"), mount.get("Source"), mount.get("ReadOnly")
        if not isinstance(destination, str) or not isinstance(source, str) or read_only is not True:
            raise ExecutionError("benchmark proxy configured mount is invalid")
        configured[destination] = (source, read_only)
    expected_configured = {
        destination: (source, True) for destination, (source, _) in observed.items()
    }
    if configured != expected_configured:
        raise ExecutionError("benchmark proxy configured mount differs from readback")
    target_root = Path(cast(str, policy["target_root"]))
    scratch_root = Path(cast(str, policy["scratch_root"]))
    for destination, (source_value, _) in observed.items():
        source = Path(source_value)
        if not source.is_absolute() or source.is_symlink():
            raise ExecutionError("benchmark proxy mount source crosses a trust boundary")
        resolved = source.resolve(strict=True)
        if _is_within(resolved, target_root) or _is_within(resolved, scratch_root):
            raise ExecutionError("benchmark proxy mount source crosses a trust boundary")
        source_stat = source.stat()
        if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_nlink != 1:
            raise ExecutionError("benchmark proxy mount source is not a private regular file")
        if destination == "/run/secrets/provider-key" and stat.S_IMODE(source_stat.st_mode) != 0o600:
            raise ExecutionError("benchmark proxy secret source mode is invalid")
    proxy_policy = cast(Mapping[str, object], profile["proxy_policy"])
    policy_source = Path(observed["/etc/bugsweep/proxy-policy.json"][0])
    policy_digest, _ = _sha256_file(policy_source, max_bytes=64 * 1024)
    if policy_digest != proxy_policy["sha256"]:
        raise ExecutionError("benchmark proxy policy mount digest mismatch")
    if not isinstance(networks, list) or len(networks) != 2:
        raise ExecutionError("benchmark network readback is incomplete")
    by_id = {item.get("Id"): item for item in networks if isinstance(item, Mapping)}
    if set(by_id) != {internal["id"], egress["id"]}:
        raise ExecutionError("benchmark network ids mismatch")
    for expected, is_internal, members in (
        (internal, True, {analysis_id, proxy_expected["container_id"]}),
        (egress, False, {proxy_expected["container_id"]}),
    ):
        network = by_id[expected["id"]]
        if network.get("Name") != expected["name"] or network.get("Internal") is not is_internal:
            raise ExecutionError("benchmark network property mismatch")
        containers = network.get("Containers")
        if not isinstance(containers, Mapping) or set(containers) != members:
            raise ExecutionError("benchmark network contains a foreign container")


def verify_backend_readback(
    readback: Mapping[str, object],
    policy: Mapping[str, object],
    cwd: Path,
    scratch: Path,
    container_id: str,
    container_name: str,
    command: Sequence[str],
    env: Mapping[str, str],
) -> str:
    expected_fields = {"schema_version", "kind", "analysis"}
    if policy["network_mode"] == "approved-proxy-only":
        expected_fields.update({"proxy", "networks"})
    if (
        set(readback) != expected_fields
        or readback.get("schema_version") != SCHEMA_VERSION
        or readback.get("kind") != "docker-inspect-readback"
    ):
        raise ExecutionError("Docker readback envelope mismatch")
    analysis = readback.get("analysis")
    if not isinstance(analysis, Mapping):
        raise ExecutionError("Docker analysis readback is missing")
    network_capability = _verify_analysis_inspect(
        analysis, policy, cwd, scratch, container_id, container_name, command, env
    )
    if policy["network_mode"] == "approved-proxy-only":
        _verify_benchmark_dependencies(readback, policy, container_id)
    return network_capability


def _validate_receipt_artifacts(
    receipt: Mapping[str, object],
    authority: Path,
    declared_outputs: Sequence[Mapping[str, object]],
) -> list[str]:
    raw_records = receipt.get("outputs")
    if not isinstance(raw_records, list) or len(raw_records) > MAX_OUTPUTS + 3:
        return ["output_records_invalid"]
    expected: dict[str, tuple[str, int]] = {
        str(authority / "stdout.log"): ("stdout", MAX_OUTPUT_BYTES),
        str(authority / "stderr.log"): ("stderr", MAX_OUTPUT_BYTES),
        str(authority / "backend-readback.json"): ("backend-readback", 4 * 1024 * 1024),
    }
    for declaration in declared_outputs:
        relative = cast(str, declaration["path"])
        expected[str(authority.joinpath(*PurePosixPath(relative).parts))] = (
            cast(str, declaration["kind"]),
            cast(int, declaration["max_bytes"]),
        )
    records: dict[str, Mapping[str, object]] = {}
    reasons: list[str] = []
    for raw_record in raw_records:
        if not isinstance(raw_record, Mapping) or set(raw_record) != {
            "kind",
            "path",
            "sha256",
            "bytes",
        }:
            reasons.append("output_record_invalid")
            continue
        path_value = raw_record.get("path")
        if not isinstance(path_value, str) or path_value in records:
            reasons.append("output_record_duplicate_or_invalid_path")
            continue
        records[path_value] = raw_record
    for required_name in ("stdout.log", "stderr.log", "backend-readback.json"):
        if str(authority / required_name) not in records:
            reasons.append(f"{required_name.replace('.', '_')}_record_missing")
    for path_value, record in records.items():
        specification = expected.get(path_value)
        if specification is None:
            reasons.append("unexpected_output_record")
            continue
        expected_kind, max_bytes = specification
        path = Path(path_value)
        try:
            resolved = path.resolve(strict=True)
            if (
                not path.is_absolute()
                or path.is_symlink()
                or not _is_within(resolved, authority)
                or record.get("kind") != expected_kind
            ):
                raise ExecutionError("artifact path or kind mismatch")
            raw = _read_bounded_bytes(path, max_bytes)
        except (ExecutionError, OSError):
            reasons.append("output_artifact_invalid")
            continue
        digest = hashlib.sha256(raw).hexdigest()
        if record.get("sha256") != digest or record.get("bytes") != len(raw):
            reasons.append("output_artifact_digest_mismatch")
        if expected_kind == "stdout" and receipt.get("stdout_sha256") != digest:
            reasons.append("stdout_digest_mismatch")
        if expected_kind == "stderr" and receipt.get("stderr_sha256") != digest:
            reasons.append("stderr_digest_mismatch")
        if expected_kind == "backend-readback" and receipt.get("backend_readback_sha256") != digest:
            reasons.append("backend_readback_digest_mismatch")
    return list(dict.fromkeys(reasons))


def validate_execution_receipt(
    receipt: Mapping[str, object],
    expected_source_map: Mapping[str, str],
    required_network: str = "denied",
) -> list[str]:
    """Validate trusted-side bytes and Docker readback; return all eligibility reasons."""

    reasons: list[str] = []
    if required_network not in {"denied", "approved-proxy-only"}:
        return ["required_network_invalid"]
    try:
        from jsonschema import Draft202012Validator  # type: ignore[import-untyped]

        schema_path = Path(__file__).resolve().parents[1] / "schemas" / "execution-receipt.schema.json"
        schema_raw = _read_bounded_bytes(schema_path, 256 * 1024)
        schema = json.loads(schema_raw)
        if not isinstance(schema, Mapping):
            raise ValueError("receipt schema is not an object")
        schema_errors = list(Draft202012Validator(schema).iter_errors(receipt))
    except (ImportError, OSError, ExecutionError, TypeError, ValueError, json.JSONDecodeError):
        return ["receipt_schema_validation_unavailable"]
    if schema_errors:
        return ["receipt_schema_invalid"]
    try:
        started = dt.datetime.strptime(cast(str, receipt["started_at"]), "%Y-%m-%dT%H:%M:%S.%fZ")
        finished = dt.datetime.strptime(cast(str, receipt["finished_at"]), "%Y-%m-%dT%H:%M:%S.%fZ")
    except (KeyError, TypeError, ValueError):
        return ["receipt_time_invalid"]
    if finished < started:
        reasons.append("receipt_time_order_invalid")
    if (
        receipt.get("termination") != "exited"
        or not isinstance(receipt.get("exit_code"), int)
        or isinstance(receipt.get("exit_code"), bool)
        or receipt.get("reason") is not None
    ):
        reasons.append("execution_result_invalid")
    if not isinstance(receipt.get("mount_inventory_sha256"), str) or not _SHA256_RE.fullmatch(
        cast(str, receipt.get("mount_inventory_sha256"))
    ):
        reasons.append("mount_inventory_missing")
    try:
        normalized_source = {
            _relative_output_path(path): digest for path, digest in expected_source_map.items()
        }
        if (
            not normalized_source
            or any(not isinstance(digest, str) or not _SHA256_RE.fullmatch(digest) for digest in normalized_source.values())
        ):
            raise ValueError("invalid expected source map")
        normalized_source = dict(sorted(normalized_source.items()))
    except (AttributeError, TypeError, ValueError):
        return ["expected_source_map_invalid"]
    source = receipt.get("source_identity")
    if not isinstance(source, Mapping):
        return ["source_identity_missing"]
    manifest_sha = _digest(normalized_source)
    if source.get("source_file_sha256") != normalized_source:
        reasons.append("source_file_map_mismatch")
    if source.get("sha256") != manifest_sha or receipt.get("source_manifest_sha256") != manifest_sha:
        reasons.append("source_manifest_mismatch")
    command = receipt.get("command")
    try:
        argv = _validate_command(cast(Sequence[str], command))
    except (TypeError, ValueError):
        return [*reasons, "command_invalid"]
    if receipt.get("command_sha256") != _digest(argv):
        reasons.append("command_digest_mismatch")
    policy = receipt.get("execution_policy")
    declared_outputs = receipt.get("declared_outputs")
    environment = receipt.get("environment_allowlist")
    if not isinstance(policy, Mapping):
        return [*reasons, "execution_policy_missing"]
    if policy.get("source_identity") != source:
        reasons.append("policy_source_identity_mismatch")
    if required_network == "denied":
        if policy.get("network_mode") != "none" or receipt.get("applied_limits") is not None:
            reasons.append("standard_policy_semantics_invalid")
    else:
        profile = policy.get("benchmark_profile")
        limits = profile.get("limits") if isinstance(profile, Mapping) else None
        applied = receipt.get("applied_limits")
        if (
            policy.get("source_mount_mode") != "archive-ro"
            or
            not isinstance(limits, Mapping)
            or not isinstance(applied, Mapping)
            or {key: applied.get(key) for key in limits} != dict(limits)
            or applied.get("enforced") is not False
            or applied.get("reason") != "limit_enforcement_unverified"
        ):
            reasons.append("benchmark_limit_binding_invalid")
    try:
        outputs = _validate_outputs(cast(Sequence[Mapping[str, object]], declared_outputs))
        env = _validate_environment(cast(Mapping[str, str], environment))
    except (TypeError, ValueError):
        return [*reasons, "execution_config_invalid"]
    if receipt.get("config_sha256") != execution_config_sha256(policy, outputs):
        reasons.append("config_digest_mismatch")
    if receipt.get("environment_sha256") != execution_environment_sha256(env):
        reasons.append("environment_digest_mismatch")
    backend = receipt.get("backend")
    capabilities = receipt.get("capabilities")
    if not isinstance(backend, Mapping) or backend.get("name") != "docker":
        return [*reasons, "verified_docker_backend_required"]
    if not isinstance(capabilities, Mapping):
        return [*reasons, "capabilities_missing"]
    readback_value = receipt.get("backend_readback_path")
    if not isinstance(readback_value, str):
        return [*reasons, "backend_readback_missing"]
    readback_path = Path(readback_value)
    stdout_path = receipt.get("stdout_path")
    stderr_path = receipt.get("stderr_path")
    cwd_value = receipt.get("cwd")
    scratch_root_value = policy.get("scratch_root")
    if (
        not readback_path.is_absolute()
        or readback_path.name != "backend-readback.json"
        or readback_path.is_symlink()
        or not isinstance(stdout_path, str)
        or not isinstance(stderr_path, str)
        or Path(stdout_path).name != "stdout.log"
        or Path(stderr_path).name != "stderr.log"
        or Path(stdout_path).parent != readback_path.parent
        or Path(stderr_path).parent != readback_path.parent
        or not isinstance(cwd_value, str)
        or not Path(cwd_value).is_absolute()
        or not isinstance(scratch_root_value, str)
        or not Path(scratch_root_value).is_absolute()
    ):
        return [*reasons, "backend_readback_authority_path_invalid"]
    try:
        authority = readback_path.parent.resolve(strict=True)
        target_identity = Path(cwd_value).resolve(strict=False)
        scratch_root_identity = Path(scratch_root_value).resolve(strict=False)
    except OSError:
        return [*reasons, "backend_readback_authority_path_invalid"]
    if (
        readback_path.parent != authority
        or Path(cwd_value) != target_identity
        or Path(scratch_root_value) != scratch_root_identity
        or _is_within(authority, target_identity)
        or _is_within(authority, scratch_root_identity)
    ):
        return [*reasons, "backend_readback_authority_path_invalid"]
    reasons.extend(_validate_receipt_artifacts(receipt, authority, outputs))
    try:
        raw = _read_bounded_bytes(readback_path, 4 * 1024 * 1024)
        readback = json.loads(raw)
    except (ExecutionError, OSError, json.JSONDecodeError, UnicodeDecodeError):
        return [*reasons, "backend_readback_invalid"]
    if not isinstance(readback, dict) or raw != canonical_json_bytes(readback):
        return [*reasons, "backend_readback_noncanonical"]
    readback_sha = hashlib.sha256(raw).hexdigest()
    if receipt.get("backend_readback_sha256") != readback_sha:
        reasons.append("backend_readback_digest_mismatch")
    output_record = next(
        (
            item
            for item in cast(Sequence[object], receipt.get("outputs") or [])
            if isinstance(item, Mapping) and item.get("kind") == "backend-readback"
        ),
        None,
    )
    if (
        not isinstance(output_record, Mapping)
        or output_record.get("path") != str(readback_path)
        or output_record.get("sha256") != readback_sha
        or output_record.get("bytes") != len(raw)
    ):
        reasons.append("backend_readback_output_record_mismatch")
    container_id, container_name = backend.get("container_id"), backend.get("container_name")
    if (
        not isinstance(cwd_value, str)
        or not isinstance(container_id, str)
        or not isinstance(container_name, str)
    ):
        return [*reasons, "backend_identity_missing"]
    analysis = readback.get("analysis")
    if not isinstance(analysis, Mapping) or not isinstance(analysis.get("Mounts"), list):
        return [*reasons, "backend_readback_mounts_missing"]
    scratch_source = next(
        (
            mount.get("Source")
            for mount in analysis["Mounts"]
            if isinstance(mount, Mapping) and mount.get("Destination") == "/bugsweep-output"
        ),
        None,
    )
    if not isinstance(scratch_source, str):
        return [*reasons, "backend_readback_scratch_missing"]
    scratch_identity = Path(scratch_source).resolve(strict=False)
    if (
        not Path(scratch_source).is_absolute()
        or Path(scratch_source) != scratch_identity
        or _is_within(authority, scratch_identity)
    ):
        return [*reasons, "backend_readback_authority_path_invalid"]
    try:
        observed_network = verify_backend_readback(
            readback,
            policy,
            Path(cwd_value),
            Path(scratch_source),
            container_id,
            container_name,
            argv,
            env,
        )
    except (ExecutionError, KeyError, TypeError, ValueError):
        reasons.append("backend_readback_policy_mismatch")
        observed_network = None
    expected_network = (
        "verified_denied" if required_network == "denied" else "approved_proxy_only_verified"
    )
    if observed_network != expected_network or capabilities.get("network") != expected_network:
        reasons.append("required_network_unverified")
    if (
        receipt.get("backend_readback_verified") is not True
        or capabilities.get("isolation") != "verified"
        or capabilities.get("evidence_tier") != "verified_backend"
    ):
        reasons.append("backend_verification_incomplete")
    if capabilities.get("deadline") != "process_group_term_kill_reap":
        reasons.append("deadline_enforcement_unverified")
    if capabilities.get("output_import") != "trusted_side":
        reasons.append("output_import_unverified")
    if receipt.get("termination") != "exited":
        reasons.append("execution_not_exited")
    return list(dict.fromkeys(reasons))


def validate_benchmark_limit_evidence(
    evidence_ref: Mapping[str, object],
    execution_receipt: Mapping[str, object],
    expected_source_map: Mapping[str, str],
    expected_proxy_source_sha256: str,
    expected_limits: Mapping[str, object],
) -> list[str]:
    """Validate sealed post-stop evidence without upgrading unproven live caps."""

    execution_reasons = validate_execution_receipt(
        execution_receipt, expected_source_map, "approved-proxy-only"
    )
    reasons = [f"execution:{reason}" for reason in execution_reasons]
    if (
        not isinstance(evidence_ref, Mapping)
        or set(evidence_ref) != {"path", "sha256", "schema_version", "owner"}
        or evidence_ref.get("schema_version") != SCHEMA_VERSION
        or evidence_ref.get("owner") != "bench/harness.py"
        or not isinstance(evidence_ref.get("path"), str)
        or not isinstance(evidence_ref.get("sha256"), str)
        or not _SHA256_RE.fullmatch(cast(str, evidence_ref.get("sha256")))
    ):
        return [*reasons, "limit_evidence_reference_invalid"]
    policy = execution_receipt.get("execution_policy")
    cwd_value = execution_receipt.get("cwd")
    if not isinstance(policy, Mapping) or not isinstance(cwd_value, str):
        return [*reasons, "limit_evidence_execution_binding_invalid"]
    profile = policy.get("benchmark_profile")
    scratch_value = policy.get("scratch_root")
    if not isinstance(profile, Mapping) or not isinstance(scratch_value, str):
        return [*reasons, "limit_evidence_execution_binding_invalid"]
    evidence_path = Path(cast(str, evidence_ref["path"]))
    try:
        if not evidence_path.is_absolute() or evidence_path.is_symlink():
            raise OSError("invalid evidence path")
        evidence_identity = evidence_path.resolve(strict=True)
        target_identity = Path(cwd_value).resolve(strict=False)
        scratch_identity = Path(scratch_value).resolve(strict=False)
        if (
            evidence_path != evidence_identity
            or _is_within(evidence_identity, target_identity)
            or _is_within(evidence_identity, scratch_identity)
        ):
            raise OSError("evidence crosses authority boundary")
        raw = _read_bounded_bytes(evidence_identity, 1024 * 1024)
        evidence = json.loads(raw)
    except (ExecutionError, OSError, UnicodeDecodeError, json.JSONDecodeError):
        return [*reasons, "limit_evidence_artifact_invalid"]
    if not isinstance(evidence, Mapping) or raw != canonical_json_bytes(evidence):
        return [*reasons, "limit_evidence_noncanonical"]
    if hashlib.sha256(raw).hexdigest() != evidence_ref["sha256"]:
        reasons.append("limit_evidence_digest_mismatch")
    try:
        from jsonschema import Draft202012Validator

        schema_path = (
            Path(__file__).resolve().parents[1]
            / "schemas"
            / "benchmark-limit-evidence.schema.json"
        )
        schema = json.loads(_read_bounded_bytes(schema_path, 128 * 1024))
        if not isinstance(schema, Mapping):
            raise ValueError("limit evidence schema is not an object")
        schema_errors = list(Draft202012Validator(schema).iter_errors(evidence))
    except (ImportError, OSError, ExecutionError, TypeError, ValueError, json.JSONDecodeError):
        return [*reasons, "limit_evidence_schema_validation_unavailable"]
    if schema_errors:
        return [*reasons, "limit_evidence_schema_invalid"]

    proxy_receipt = profile.get("proxy_receipt")
    proxy_policy = profile.get("proxy_policy")
    if (
        evidence.get("execution_receipt_sha256") != _digest(execution_receipt)
        or not isinstance(proxy_receipt, Mapping)
        or evidence.get("proxy_receipt_sha256") != proxy_receipt.get("sha256")
        or not isinstance(proxy_policy, Mapping)
        or evidence.get("proxy_policy_sha256") != proxy_policy.get("sha256")
        or evidence.get("configured_limits") != dict(expected_limits)
        or not isinstance(profile.get("limits"), Mapping)
        or {key: profile["limits"].get(key) for key in expected_limits} != dict(expected_limits)
    ):
        reasons.append("limit_evidence_binding_mismatch")

    readback_path_value = execution_receipt.get("backend_readback_path")
    source = evidence.get("source_evidence")
    try:
        if not isinstance(readback_path_value, str) or not isinstance(source, Mapping):
            raise ValueError("source evidence is absent")
        readback = json.loads(_read_bounded_bytes(Path(readback_path_value), 4 * 1024 * 1024))
        proxy_readback = readback.get("proxy") if isinstance(readback, Mapping) else None
        config = proxy_readback.get("Config") if isinstance(proxy_readback, Mapping) else None
        labels = config.get("Labels") if isinstance(config, Mapping) else None
        image = proxy_readback.get("Image") if isinstance(proxy_readback, Mapping) else None
        label_sha = (
            labels.get("org.bugsweep.proxy.source.sha256")
            if isinstance(labels, Mapping)
            else None
        )
        if (
            not _SHA256_RE.fullmatch(expected_proxy_source_sha256)
            or source.get("provider_proxy_sha256") != expected_proxy_source_sha256
            or label_sha != expected_proxy_source_sha256
            or source.get("proxy_image_digest") != image
            or source.get("proxy_image_digest") != profile.get("proxy_image_id")
            or source.get("image_label_matches") is not True
        ):
            reasons.append("proxy_source_evidence_mismatch")
    except (ExecutionError, OSError, TypeError, ValueError, json.JSONDecodeError):
        reasons.append("proxy_source_evidence_invalid")

    usage = cast(Mapping[str, object], evidence["usage"])
    event_path = Path(cast(str, usage["event_log_path"]))
    try:
        if (
            not event_path.is_absolute()
            or event_path.is_symlink()
            or event_path.parent.resolve(strict=True) != evidence_identity.parent
        ):
            raise OSError("event log crosses authority boundary")
        event_identity = event_path.resolve(strict=True)
        if event_path != event_identity:
            raise OSError("event log path is not canonical")
        event_raw = _read_bounded_bytes(event_identity, 4 * 1024 * 1024)
        if hashlib.sha256(event_raw).hexdigest() != usage["event_log_sha256"]:
            reasons.append("proxy_event_log_digest_mismatch")
        if event_raw and not event_raw.endswith(b"\n"):
            raise ValueError("event log is not line terminated")
        events: list[Mapping[str, object]] = []
        for line in event_raw.splitlines():
            event = json.loads(line)
            if (
                not isinstance(event, Mapping)
                or event.get("kind") != "bugsweep-proxy-usage"
                or line != canonical_json_bytes(event)
            ):
                raise ValueError("event log contains an invalid event")
            events.append(event)
    except (ExecutionError, OSError, UnicodeDecodeError, ValueError, json.JSONDecodeError):
        return [*reasons, "proxy_event_log_invalid"]

    admitted = [event for event in events if event.get("status") in {"forwarded", "upstream_error"}]
    rejected = [event for event in events if event.get("status") == "rejected"]

    def complete_int_total(name: str) -> int | None:
        values = [event.get(name) for event in admitted]
        if any(not isinstance(value, int) or isinstance(value, bool) or value < 0 for value in values):
            return None
        return sum(cast(list[int], values))

    charged_values = [event.get("budget_charged_usd") for event in admitted]
    overshoot_values = [event.get("budget_overshoot_usd") for event in admitted]
    def nonnegative_number(value: object) -> bool:
        return (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(float(value))
            and value >= 0
        )

    charged = (
        sum(cast(Sequence[float], charged_values))
        if all(nonnegative_number(value) for value in charged_values)
        else None
    )
    overshoot = (
        max(cast(Sequence[float], overshoot_values), default=0.0)
        if all(nonnegative_number(value) for value in overshoot_values)
        else None
    )
    input_tokens = complete_int_total("input_tokens")
    output_tokens = complete_int_total("output_tokens")
    if (
        usage.get("event_count") != len(events)
        or usage.get("admitted_turns") != len(admitted)
        or usage.get("rejected_requests") != len(rejected)
        or usage.get("input_tokens") != input_tokens
        or usage.get("output_tokens") != output_tokens
        or usage.get("budget_charged_usd") != charged
        or usage.get("budget_overshoot_usd") != overshoot
        or usage.get("accounting_complete")
        is not (input_tokens is not None and output_tokens is not None and charged is not None)
    ):
        reasons.append("proxy_usage_aggregate_mismatch")
    lifecycle = cast(Mapping[str, object], evidence["lifecycle"])
    if any(lifecycle.get(key) is not True for key in lifecycle) or usage.get(
        "inflight_requests_at_stop"
    ) != 0:
        reasons.append("proxy_lifecycle_incomplete")
    if (
        input_tokens is not None
        and expected_limits["max_input_tokens"] is not None
        and input_tokens > cast(float, expected_limits["max_input_tokens"])
    ) or (
        output_tokens is not None
        and expected_limits["max_output_tokens"] is not None
        and output_tokens > cast(float, expected_limits["max_output_tokens"])
    ) or (expected_limits["max_turns"] is not None and len(admitted) > cast(float, expected_limits["max_turns"])):
        reasons.append("observed_limit_exceeded")
    if overshoot is not None and overshoot > 0:
        reasons.append("observed_budget_overshoot")
    try:
        started = dt.datetime.strptime(
            cast(str, execution_receipt["started_at"]), "%Y-%m-%dT%H:%M:%S.%fZ"
        )
        finished = dt.datetime.strptime(
            cast(str, execution_receipt["finished_at"]), "%Y-%m-%dT%H:%M:%S.%fZ"
        )
        if (finished - started).total_seconds() > cast(float, expected_limits["wall_clock_seconds"]):
            reasons.append("observed_wall_clock_exceeded")
    except (KeyError, TypeError, ValueError):
        reasons.append("observed_wall_clock_invalid")
    if evidence.get("live_cap_verified") is True:
        reasons.append("live_cap_claim_unsupported")
    elif evidence.get("reason") != "live_cap_verification_unavailable":
        reasons.append("live_cap_reason_invalid")
    else:
        reasons.append("live_cap_unverified")
    return list(dict.fromkeys(reasons))


def _fixed_host_environment() -> dict[str, str]:
    return {"PATH": FIXED_HOST_PATH, "HOME": "/var/empty", "LANG": "C", "LC_ALL": "C"}


def _limit_capture_files() -> None:
    _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    limit = MAX_OUTPUT_BYTES if hard == resource.RLIM_INFINITY else min(MAX_OUTPUT_BYTES, hard)
    resource.setrlimit(resource.RLIMIT_FSIZE, (limit, hard))


def _terminate_and_reap(process: subprocess.Popen[bytes], grace: float) -> int:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        return process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return process.wait()


def _control_engine(engine: Path, expected_sha256: str, args: Sequence[str]) -> bool:
    verified, reason = _engine_identity(
        {"canonical_engine_path": str(engine), "engine_sha256": expected_sha256}
    )
    if reason or verified != engine:
        return False
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            [str(engine), *args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=_fixed_host_environment(),
            start_new_session=True,
        )
        process.wait(timeout=10)
    except (OSError, subprocess.SubprocessError):
        if process is not None:
            try:
                _terminate_and_reap(process, 0.2)
            except (OSError, subprocess.SubprocessError):
                pass
        return False
    assert process is not None
    return process.returncode == 0


def _read_bounded_bytes(path: Path, max_bytes: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ExecutionError("control output is not a regular file")
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(fd, 64 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > max_bytes:
                raise ExecutionError("control output exceeds its limit")
            chunks.append(chunk)
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            raise ExecutionError("control output changed while it was read")
        return b"".join(chunks)
    finally:
        os.close(fd)


def _control_capture(
    engine: Path,
    expected_sha256: str,
    argv: Sequence[str],
    stdout_path: Path,
    stderr_path: Path,
    timeout: float,
) -> int:
    verified, reason = _engine_identity(
        {"canonical_engine_path": str(engine), "engine_sha256": expected_sha256}
    )
    if reason or verified != engine:
        raise ExecutionError(reason or "engine identity changed")
    with _open_capture(stdout_path) as stdout, _open_capture(stderr_path) as stderr:
        process = subprocess.Popen(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            env=_fixed_host_environment(),
            start_new_session=True,
            preexec_fn=_limit_capture_files,
        )
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            _terminate_and_reap(process, 0.2)
            raise ExecutionError("Docker control command timed out") from exc
        except BaseException:
            _terminate_and_reap(process, 0.2)
            raise


def _docker_json(
    engine: Path,
    engine_sha256: str,
    args: Sequence[str],
    authority: Path,
    stem: str,
    timeout: float,
) -> object:
    stdout_path = authority / f".{stem}.stdout"
    stderr_path = authority / f".{stem}.stderr"
    try:
        status = _control_capture(
            engine,
            engine_sha256,
            [str(engine), *args],
            stdout_path,
            stderr_path,
            timeout,
        )
        if status != 0:
            raise ExecutionError(f"Docker {stem} failed")
        raw = _read_bounded_bytes(stdout_path, 4 * 1024 * 1024)
        try:
            return json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ExecutionError(f"Docker {stem} returned invalid JSON") from exc
    finally:
        stdout_path.unlink(missing_ok=True)
        stderr_path.unlink(missing_ok=True)


def _remove_owned_container(
    engine: Path,
    engine_sha256: str,
    container_name: str,
    authority: Path,
) -> bool:
    """Remove only the deterministic container carrying this invocation's label."""

    try:
        inspected = _docker_json(
            engine,
            engine_sha256,
            ["inspect", "--type", "container", container_name],
            authority,
            "cleanup-inspect",
            10,
        )
    except (ExecutionError, OSError):
        return False
    invocation_id = container_name.removeprefix("bugsweep-")
    if not isinstance(inspected, list) or len(inspected) != 1:
        return False
    container = inspected[0]
    config = container.get("Config") if isinstance(container, Mapping) else None
    labels = config.get("Labels") if isinstance(config, Mapping) else None
    if (
        not isinstance(container, Mapping)
        or container.get("Name") != "/" + container_name
        or not isinstance(labels, Mapping)
        or labels.get("org.bugsweep.invocation") != invocation_id
    ):
        return False
    return _control_engine(engine, engine_sha256, ["rm", "-f", container_name])


def _remaining_timeout(deadline_epoch: float, maximum: float = 10.0) -> float:
    remaining = deadline_epoch - time.time()
    if remaining <= 0:
        raise ExecutionError("deadline_exceeded")
    return min(maximum, remaining)


def _write_authority_artifact(path: Path, data: bytes) -> None:
    temporary = path.with_name(path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    if path.exists() or path.is_symlink():
        raise ExecutionError("authority artifact destination already exists")
    os.replace(temporary, path)


def _write_receipt(output_dir: Path, receipt: Mapping[str, object]) -> None:
    path = output_dir / "execution-receipt.json"
    temporary = output_dir / "execution-receipt.json.tmp"
    data = canonical_json_bytes(receipt)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    if path.exists() or path.is_symlink():
        raise ExecutionError("execution receipt destination already exists")
    os.replace(temporary, path)
    directory_fd = os.open(output_dir, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def _open_capture(path: Path) -> Any:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    return os.fdopen(fd, "wb", buffering=0)


def _artifact_record(path: Path, kind: str) -> dict[str, object]:
    digest, size = _sha256_file(path, max_bytes=MAX_OUTPUT_BYTES)
    return {"kind": kind, "path": str(path), "sha256": digest, "bytes": size}


def _scratch_inventory_is_expected(scratch: Path, outputs: Sequence[Mapping[str, object]]) -> bool:
    expected_files = {cast(str, item["path"]) for item in outputs}
    expected_dirs = {
        str(parent)
        for item in expected_files
        for parent in PurePosixPath(item).parents
        if str(parent) != "."
    }
    try:
        for root, dirs, files in os.walk(scratch, topdown=True, followlinks=False):
            root_path = Path(root)
            for name in [*dirs, *files]:
                candidate = root_path / name
                relative = candidate.relative_to(scratch).as_posix()
                mode = candidate.lstat().st_mode
                if stat.S_ISLNK(mode):
                    return False
                if stat.S_ISDIR(mode):
                    if relative not in expected_dirs:
                        return False
                elif stat.S_ISREG(mode):
                    if relative not in expected_files:
                        return False
                else:
                    return False
    except OSError:
        return False
    return True


def _copy_exclusive(source: Path, destination: Path, max_bytes: int) -> dict[str, object]:
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    source_digest, source_size = _sha256_file(source, max_bytes=max_bytes)
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    digest = hashlib.sha256()
    size = 0
    complete = False
    try:
        while True:
            chunk = os.read(source_fd, 64 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > max_bytes:
                raise ExecutionError("artifact exceeds its declared byte limit")
            os.write(destination_fd, chunk)
            digest.update(chunk)
        os.fsync(destination_fd)
        complete = True
    finally:
        os.close(source_fd)
        os.close(destination_fd)
        if not complete:
            destination.unlink(missing_ok=True)
    if size != source_size or digest.hexdigest() != source_digest:
        raise ExecutionError("artifact changed during import")
    return {"path": str(destination), "sha256": source_digest, "bytes": size}


def _import_outputs(
    scratch: Path, output_dir: Path, outputs: Sequence[Mapping[str, object]]
) -> list[dict[str, object]]:
    if not _scratch_inventory_is_expected(scratch, outputs):
        raise ExecutionError("scratch contains a symlink, special, or unexpected entry")
    imported: list[dict[str, object]] = []
    for item in outputs:
        relative = cast(str, item["path"])
        source = scratch.joinpath(*PurePosixPath(relative).parts)
        if not source.exists():
            continue
        record = _copy_exclusive(source, output_dir.joinpath(*PurePosixPath(relative).parts), cast(int, item["max_bytes"]))
        imported.append({"kind": item["kind"], **record})
    return imported


def _unavailable_receipt(
    invocation_id: str,
    command: Sequence[str],
    cwd: Path,
    output_dir: Path,
    started_at: str,
    reason: str,
    *,
    config: Mapping[str, object] | None = None,
    source_identity: Mapping[str, object] | None = None,
) -> dict[str, object]:
    receipt: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "invocation_id": invocation_id,
        "command": list(command),
        "command_sha256": _digest(list(command)),
        "config_sha256": (
            execution_config_sha256(config, ())
            if config is not None
            else _digest({"mode": "required-untrusted", "backend": "unconfigured"})
        ),
        "environment_sha256": execution_environment_sha256({}),
        "cwd": str(cwd),
        "source_identity": source_identity
        or {"kind": "unavailable", "sha256": None, "source_file_sha256": {}},
        "source_manifest_sha256": (
            source_identity.get("sha256") if source_identity is not None else None
        ),
        "execution_policy": dict(config) if config is not None else None,
        "environment_allowlist": {},
        "declared_outputs": [],
        "backend": {
            "name": "unconfigured",
            "engine_path": None,
            "engine_sha256": None,
            "image_digest": None,
            "container_id": None,
            "container_name": None,
        },
        "backend_readback_path": None,
        "backend_readback_sha256": None,
        "backend_readback_verified": False,
        "mount_inventory_sha256": None,
        "applied_limits": None,
        "capabilities": {
            "isolation": "unsupported",
            "network": "unsupported",
            "deadline": "unsupported",
            "output_import": "not_run",
            "evidence_tier": "unverified",
        },
        "started_at": started_at,
        "finished_at": _timestamp(),
        "exit_code": None,
        "termination": "backend_unavailable",
        "reason": reason,
        "outputs": [],
        "stdout_path": None,
        "stdout_sha256": None,
        "stderr_path": None,
        "stderr_sha256": None,
    }
    _write_receipt(output_dir, receipt)
    return receipt


def run_command(
    command: Sequence[str],
    cwd: Path | str,
    output_dir: Path | str,
    deadline_epoch: float,
    policy: Mapping[str, object] | None = None,
    env_allowlist: Mapping[str, str] | None = None,
    predeclared_outputs: Sequence[Mapping[str, object]] = (),
) -> dict[str, object]:
    """Execute one argv under trusted external policy and write one immutable receipt."""

    argv = _validate_command(command)
    target = _existing_dir(cwd, "cwd")
    if not isinstance(deadline_epoch, (int, float)) or isinstance(deadline_epoch, bool) or not math.isfinite(deadline_epoch):
        raise ValueError("deadline_epoch must be finite")
    env = _validate_environment(env_allowlist)
    outputs = _validate_outputs(predeclared_outputs)
    invocation_id = uuid.uuid4().hex
    started_at = _timestamp()

    if policy is None:
        authority = _fresh_output_dir(output_dir, target, None)
        return _unavailable_receipt(
            invocation_id,
            argv,
            target,
            authority,
            started_at,
            "required_untrusted_backend_not_configured",
        )

    normalized, scratch_root, engine, unavailable_reason = _validate_policy(policy, target)
    mount_inventory_sha256 = (
        _mount_inventory(target) if normalized["backend"] == "docker" else None
    )
    authority = _fresh_output_dir(output_dir, target, scratch_root)
    if unavailable_reason or engine is None:
        return _unavailable_receipt(
            invocation_id,
            argv,
            target,
            authority,
            started_at,
            unavailable_reason or "engine_unavailable",
            config=normalized,
            source_identity=cast(dict[str, object], normalized["source_identity"]),
        )
    if deadline_epoch <= time.time():
        return _unavailable_receipt(
            invocation_id,
            argv,
            target,
            authority,
            started_at,
            "deadline_already_expired",
            config=normalized,
            source_identity=cast(dict[str, object], normalized["source_identity"]),
        )

    scratch = Path(tempfile.mkdtemp(prefix=f"invocation-{invocation_id}-", dir=scratch_root))
    os.chmod(scratch, 0o733 if normalized["backend"] == "docker" else 0o700)
    container_name = f"bugsweep-{invocation_id}"
    backend_argv = build_backend_argv(argv, target, scratch, normalized, container_name, env)
    stdout_path, stderr_path = authority / "stdout.log", authority / "stderr.log"
    readback_path = authority / "backend-readback.json"
    readback_sha256: str | None = None
    readback_verified = False
    network_capability = (
        "configured_proxy_unverified"
        if normalized.get("network_mode") == "approved-proxy-only"
        else "configured_denied_unverified"
    )
    termination = "exited"
    reason: str | None = None
    exit_code: int | None = None
    process: subprocess.Popen[bytes] | None = None
    backend_removed = normalized["backend"] == "native"
    container_created = False
    container_create_attempted = False
    try:
        launch_engine, launch_error = _engine_identity(normalized)
        if launch_error or launch_engine != engine:
            raise ExecutionError(launch_error or "engine_identity_changed")
        launch_argv = backend_argv
        child_cwd: str | None = None
        child_env = _fixed_host_environment()
        if normalized["backend"] == "docker":
            container_create_attempted = True
            create_stdout = authority / ".create.stdout"
            create_stderr = authority / ".create.stderr"
            try:
                create_status = _control_capture(
                    engine,
                    cast(str, normalized["engine_sha256"]),
                    backend_argv,
                    create_stdout,
                    create_stderr,
                    _remaining_timeout(deadline_epoch),
                )
                if create_status != 0:
                    raise ExecutionError("Docker create failed")
                container_created = True
                container_id = _read_bounded_bytes(create_stdout, 1024).decode("ascii").strip()
                if not _SHA256_RE.fullmatch(container_id):
                    raise ExecutionError("Docker create returned an invalid container id")
            finally:
                create_stdout.unlink(missing_ok=True)
                create_stderr.unlink(missing_ok=True)
            analysis_json = _docker_json(
                engine,
                cast(str, normalized["engine_sha256"]),
                ["inspect", "--type", "container", container_id],
                authority,
                "analysis-inspect",
                _remaining_timeout(deadline_epoch),
            )
            if not isinstance(analysis_json, list) or len(analysis_json) != 1:
                raise ExecutionError("Docker analysis inspect returned the wrong cardinality")
            readback: dict[str, object] = {
                "schema_version": 1,
                "kind": "docker-inspect-readback",
                "analysis": analysis_json[0],
            }
            if normalized["network_mode"] == "approved-proxy-only":
                profile = cast(Mapping[str, object], normalized["benchmark_profile"])
                proxy = cast(Mapping[str, str], profile["proxy"])
                internal = cast(Mapping[str, str], profile["internal_network"])
                egress = cast(Mapping[str, str], profile["egress_network"])
                proxy_json = _docker_json(
                    engine,
                    cast(str, normalized["engine_sha256"]),
                    ["inspect", "--type", "container", proxy["container_id"]],
                    authority,
                    "proxy-inspect",
                    _remaining_timeout(deadline_epoch),
                )
                networks_json = _docker_json(
                    engine,
                    cast(str, normalized["engine_sha256"]),
                    ["network", "inspect", internal["id"], egress["id"]],
                    authority,
                    "network-inspect",
                    _remaining_timeout(deadline_epoch),
                )
                if not isinstance(proxy_json, list) or len(proxy_json) != 1:
                    raise ExecutionError("Docker proxy inspect returned the wrong cardinality")
                readback.update(proxy=proxy_json[0], networks=networks_json)
            readback_bytes = canonical_json_bytes(readback)
            if len(readback_bytes) > 4 * 1024 * 1024:
                raise ExecutionError("Docker readback exceeds its byte limit")
            _write_authority_artifact(readback_path, readback_bytes)
            readback_sha256 = hashlib.sha256(readback_bytes).hexdigest()
            network_capability = verify_backend_readback(
                readback,
                normalized,
                target,
                scratch,
                container_id,
                container_name,
                argv,
                env,
            )
            _verify_source_identity(
                target,
                cast(Mapping[str, object], normalized["source_identity"]),
                source_mount_mode=cast(str, normalized["source_mount_mode"]),
            )
            if _mount_inventory(target) != mount_inventory_sha256:
                raise ExecutionError("target mount changed between validation and start")
            readback_verified = True
            launch_argv = [str(engine), "start", "--attach", container_id]
        else:
            child_env.update(env)
            child_env["BUGSWEEP_OUTPUT_DIR"] = str(scratch)
            child_cwd = str(target)
        launch_engine, launch_error = _engine_identity(normalized)
        if launch_error or launch_engine != engine:
            raise ExecutionError(launch_error or "engine_identity_changed")
        with _open_capture(stdout_path) as stdout, _open_capture(stderr_path) as stderr:
            process = subprocess.Popen(
                launch_argv,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                cwd=child_cwd,
                env=child_env,
                start_new_session=True,
                preexec_fn=_limit_capture_files,
            )
            try:
                exit_code = process.wait(timeout=max(0.0, deadline_epoch - time.time()))
            except subprocess.TimeoutExpired:
                termination = "timeout"
                reason = "deadline_exceeded"
                exit_code = _terminate_and_reap(process, cast(float, normalized["term_grace_seconds"]))
            except KeyboardInterrupt:
                termination = "cancelled"
                reason = "coordinator_cancelled"
                exit_code = _terminate_and_reap(process, cast(float, normalized["term_grace_seconds"]))
        if container_created:
            backend_removed = _remove_owned_container(
                engine,
                cast(str, normalized["engine_sha256"]),
                container_name,
                authority,
            )
            if not backend_removed:
                reason = "backend_removal_failed"
    except KeyboardInterrupt:
        termination = "cancelled"
        reason = "coordinator_cancelled"
        if process is not None and process.poll() is None:
            exit_code = _terminate_and_reap(
                process, cast(float, normalized["term_grace_seconds"])
            )
    except (ExecutionError, OSError) as exc:
        deadline_exceeded = isinstance(exc, ExecutionError) and str(exc) == "deadline_exceeded"
        termination = "timeout" if deadline_exceeded else "backend_unavailable"
        reason = (
            "deadline_exceeded"
            if deadline_exceeded
            else "backend_readback_rejected"
            if readback_path.exists() and not readback_verified
            else "backend_launch_failed"
        )
        if process is not None and process.poll() is None:
            exit_code = _terminate_and_reap(process, cast(float, normalized["term_grace_seconds"]))
    finally:
        if container_create_attempted and not backend_removed:
            backend_removed = _remove_owned_container(
                engine,
                cast(str, normalized["engine_sha256"]),
                container_name,
                authority,
            )

    if (
        termination == "exited"
        and exit_code is not None
        and hasattr(signal, "SIGXFSZ")
        and exit_code == -signal.SIGXFSZ
    ):
        reason = "stdout_stderr_limit_exceeded"

    imported: list[dict[str, object]] = []
    captures: list[dict[str, object]] = []
    if stdout_path.exists():
        captures.append(_artifact_record(stdout_path, "stdout"))
    if stderr_path.exists():
        captures.append(_artifact_record(stderr_path, "stderr"))
    if readback_path.exists():
        captures.append(_artifact_record(readback_path, "backend-readback"))
    output_import = "not_run"
    if process is not None and backend_removed:
        try:
            imported = _import_outputs(scratch, authority, outputs)
            output_import = "trusted_side"
        except (OSError, ExecutionError):
            reason = "output_import_rejected"
            output_import = "rejected"
    elif process is not None:
        output_import = "rejected"

    image = normalized.get("image")
    image_match = _IMAGE_RE.fullmatch(image) if isinstance(image, str) else None
    receipt = {
        "schema_version": SCHEMA_VERSION,
        "invocation_id": invocation_id,
        "command": argv,
        "command_sha256": _digest(argv),
        "config_sha256": execution_config_sha256(normalized, outputs),
        "environment_sha256": execution_environment_sha256(env),
        "cwd": str(target),
        "source_identity": normalized["source_identity"],
        "source_manifest_sha256": cast(dict[str, object], normalized["source_identity"])[
            "sha256"
        ],
        "execution_policy": normalized,
        "environment_allowlist": env,
        "declared_outputs": outputs,
        "backend": {
            "name": normalized["backend"],
            "engine_path": str(engine),
            "engine_sha256": normalized["engine_sha256"],
            "image_digest": image_match.group(1) if image_match else None,
            "container_id": container_id if container_created else None,
            "container_name": container_name if container_created else None,
        },
        "backend_readback_path": str(readback_path) if readback_path.exists() else None,
        "backend_readback_sha256": readback_sha256,
        "backend_readback_verified": readback_verified,
        "mount_inventory_sha256": mount_inventory_sha256,
        "applied_limits": (
            {
                **cast(Mapping[str, object], cast(Mapping[str, object], normalized["benchmark_profile"])["limits"]),
                "enforced": False,
                "reason": "limit_enforcement_unverified",
            }
            if normalized.get("network_mode") == "approved-proxy-only"
            else None
        ),
        "capabilities": {
            "isolation": (
                "verified"
                if readback_verified
                else "configured_unverified"
                if normalized["backend"] == "docker"
                else "none"
            ),
            "network": network_capability if normalized["backend"] == "docker" else "host",
            "deadline": "process_group_term_kill_reap",
            "output_import": output_import,
            "evidence_tier": (
                "verified_backend"
                if readback_verified
                else "configuration_only"
                if normalized["backend"] == "docker"
                else "host_execution"
            ),
        },
        "started_at": started_at,
        "finished_at": _timestamp(),
        "exit_code": exit_code,
        "termination": termination,
        "reason": reason,
        "outputs": [*captures, *imported],
        "stdout_path": str(stdout_path) if stdout_path.exists() else None,
        "stdout_sha256": next(
            (item["sha256"] for item in captures if item["kind"] == "stdout"), None
        ),
        "stderr_path": str(stderr_path) if stderr_path.exists() else None,
        "stderr_sha256": next(
            (item["sha256"] for item in captures if item["kind"] == "stderr"), None
        ),
    }
    _write_receipt(authority, receipt)
    shutil.rmtree(scratch)
    return receipt


def _read_policy(path: Path, cwd: Path) -> dict[str, object]:
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("policy path must be an absolute regular file")
    resolved = path.resolve(strict=True)
    if _is_within(resolved, cwd):
        raise ValueError("policy must be outside the target repository")
    raw = _read_bounded_bytes(resolved, 64 * 1024)
    try:
        value = json.loads(raw)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValueError("policy must contain bounded UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise ValueError("policy must contain one JSON object")
    return cast(dict[str, object], value)


def _cli(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run one Bugsweep target argv under external policy")
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--deadline-epoch", type=float, required=True)
    parser.add_argument("--policy")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--output", action="append", nargs=3, default=[], metavar=("KIND", "PATH", "MAX_BYTES"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    try:
        cwd = _existing_dir(args.cwd, "cwd")
        policy = _read_policy(Path(args.policy), cwd) if args.policy else None
        environment: dict[str, str] = {}
        for item in args.env:
            key, separator, value = item.partition("=")
            if not separator or key in environment:
                raise ValueError("--env requires unique KEY=VALUE entries")
            environment[key] = value
        outputs = [
            {"kind": kind, "path": path, "max_bytes": int(max_bytes)}
            for kind, path, max_bytes in args.output
        ]
        receipt = run_command(
            command,
            cwd,
            args.output_dir,
            args.deadline_epoch,
            policy,
            environment,
            outputs,
        )
    except (ExecutionError, OSError, ValueError) as exc:
        print(f"execution: {exc}", file=sys.stderr)
        return 2
    print(canonical_json_bytes(receipt).decode("utf-8"))
    capabilities = cast(Mapping[str, object], receipt["capabilities"])
    if receipt["termination"] != "exited" or capabilities["output_import"] == "rejected":
        return 10
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
