#!/usr/bin/env python3
"""Durable, idempotent hunt checkpoint for ``mark-batch-covered.sh``.

The write order is deliberate: exact Git-blob snapshots are made durable
first, the append-only ``batch_covered`` event is emitted second, and
``recon.json.covered`` is atomically updated last.  The final recon update is a
receipt for the preceding writes.  If the process stops between the event and
the receipt, a retry validates the bounded snapshot tail, sees the recent
event, and finishes the recon update without duplicating either surface.

``verify_run_coverage`` is the public read-only counterpart. It returns only
records proven by all three run artifacts and exact local Git objects; it never
repairs or rewrites the run.
"""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any, Mapping, Sequence, cast


MAX_RECON_BYTES = 16 * 1024 * 1024
MAX_LEDGER_TAIL_BYTES = 4 * 1024 * 1024
MAX_SNAPSHOT_TAIL_BYTES = 32 * 1024 * 1024
MAX_JSONL_LINE_BYTES = 64 * 1024
MAX_BATCHES = 100_000
MAX_TOTAL_FILES = 500_000
MAX_BATCH_FILES = 50_000
MAX_BATCH_PATH_BYTES = 8 * 1024 * 1024
MAX_PATH_BYTES = 4096
MAX_GIT_OUTPUT_BYTES = 2 * 1024 * 1024
GIT_TIMEOUT_SECONDS = 30
_OID_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
_CLI_BATCH_RE = re.compile(r"^[1-9][0-9]{0,6}$")


class CheckpointError(RuntimeError):
    """A safe checkpoint could not be proven from the available local state."""


class NonRegularArtifact(CheckpointError):
    """A candidate artifact is a FIFO, device, socket, or directory."""


def _git_env() -> dict[str, str]:
    env = os.environ.copy()
    env["GIT_NO_LAZY_FETCH"] = "1"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_LITERAL_PATHSPECS"] = "1"
    env["LC_ALL"] = "C"
    return env


def _open_regular_read(path: Path) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        # Opening a FIFO read-only blocks before fstat can reject it unless the
        # non-blocking flag is present. It is inert for ordinary regular files.
        flags |= os.O_NONBLOCK
    fd = os.open(path, flags)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise NonRegularArtifact(f"{path.name} is not a regular file")
    return fd


def _read_bounded(path: Path, max_bytes: int) -> bytes:
    try:
        fd = _open_regular_read(path)
    except OSError as exc:
        raise CheckpointError(f"cannot safely open {path.name}") from exc
    try:
        data = bytearray()
        while len(data) <= max_bytes:
            chunk = os.read(fd, min(64 * 1024, max_bytes + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > max_bytes:
            raise CheckpointError(f"{path.name} exceeds its {max_bytes}-byte limit")
        return bytes(data)
    finally:
        os.close(fd)


def _load_json_object(path: Path, max_bytes: int) -> dict[str, Any]:
    try:
        value = json.loads(_read_bounded(path, max_bytes).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CheckpointError(f"{path.name} is not valid bounded JSON") from exc
    if not isinstance(value, dict):
        raise CheckpointError(f"{path.name} must contain a JSON object")
    return cast(dict[str, Any], value)


def _read_jsonl_tail(
    path: Path, *, max_bytes: int, max_line_bytes: int = MAX_JSONL_LINE_BYTES
) -> list[dict[str, Any]]:
    """Read at most ``max_bytes`` from the newest suffix of a regular JSONL file."""

    try:
        fd = _open_regular_read(path)
    except NonRegularArtifact:
        return []
    except FileNotFoundError:
        return []
    except OSError as exc:
        raise CheckpointError(f"cannot safely open {path.name}") from exc
    try:
        size = os.fstat(fd).st_size
        offset = max(0, size - max_bytes)
        os.lseek(fd, offset, os.SEEK_SET)
        data = bytearray()
        while len(data) < max_bytes:
            chunk = os.read(fd, min(64 * 1024, max_bytes - len(data)))
            if not chunk:
                break
            data.extend(chunk)
    finally:
        os.close(fd)

    raw_data = bytes(data)
    if offset:
        newline = raw_data.find(b"\n")
        raw_data = b"" if newline < 0 else raw_data[newline + 1 :]
    if raw_data and not raw_data.endswith(b"\n"):
        # An append interrupted before its newline is not a committed JSONL
        # record, even when the partial bytes happen to parse as valid JSON.
        final_newline = raw_data.rfind(b"\n")
        raw_data = b"" if final_newline < 0 else raw_data[: final_newline + 1]

    records: list[dict[str, Any]] = []
    for raw_line in raw_data.splitlines():
        if not raw_line or len(raw_line) > max_line_bytes:
            continue
        try:
            value = json.loads(raw_line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(value, dict):
            records.append(cast(dict[str, Any], value))
    return records


def _git_bytes(
    repo: Path,
    args: Sequence[str],
    *,
    max_bytes: int = MAX_GIT_OUTPUT_BYTES,
) -> bytes:
    """Run one local Git read while bounding stdout before allocation."""

    try:
        process: subprocess.Popen[bytes] = subprocess.Popen(
            ["git", "-C", str(repo), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_git_env(),
        )
    except OSError as exc:
        raise CheckpointError("could not start local Git") from exc

    output = bytearray()
    overflow = False
    read_errors: list[BaseException] = []

    def drain_stdout() -> None:
        nonlocal overflow
        try:
            assert process.stdout is not None
            while True:
                chunk = process.stdout.read(64 * 1024)
                if not chunk:
                    return
                if len(output) + len(chunk) <= max_bytes:
                    output.extend(chunk)
                else:
                    overflow = True
        except BaseException as exc:  # pragma: no cover - defensive pipe failure
            read_errors.append(exc)

    reader = threading.Thread(target=drain_stdout, daemon=True)
    reader.start()
    timed_out = False
    try:
        return_code = process.wait(timeout=GIT_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
        try:
            return_code = process.wait(timeout=5)
        except subprocess.TimeoutExpired as exc:  # pragma: no cover - OS-level failure
            raise CheckpointError("local Git did not terminate after timeout") from exc
    reader.join(timeout=5)
    if reader.is_alive():  # pragma: no cover - pipe should close with the child
        process.kill()
        raise CheckpointError("local Git output reader did not terminate")
    if timed_out:
        raise CheckpointError("local Git read timed out")
    if read_errors:
        raise CheckpointError("local Git output could not be read")
    if overflow:
        raise CheckpointError(f"local Git output exceeded its {max_bytes}-byte limit")
    if return_code != 0:
        raise CheckpointError("required local Git object is unavailable")
    return bytes(output)


def _decode_one_line(raw: bytes, label: str) -> str:
    try:
        text = raw.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise CheckpointError(f"local Git returned an invalid {label}") from exc
    if not text or "\n" in text or "\x00" in text:
        raise CheckpointError(f"local Git returned an invalid {label}")
    return text


def _validate_repo(repo: Path) -> None:
    if not repo.is_dir():
        raise CheckpointError("repository path is not a directory")
    root = _decode_one_line(
        _git_bytes(repo, ["rev-parse", "--show-toplevel"], max_bytes=16 * 1024),
        "repository root",
    )
    try:
        resolved_root = Path(root).resolve(strict=True)
    except OSError as exc:
        raise CheckpointError("local Git returned an unreadable repository root") from exc
    if resolved_root != repo:
        raise CheckpointError("repository argument is not the exact Git worktree root")


def _resolve_commit(repo: Path, revision: str = "HEAD") -> str:
    if revision != "HEAD" and not _OID_RE.fullmatch(revision):
        raise CheckpointError("snapshot head is not a full Git object ID")
    oid = _decode_one_line(
        _git_bytes(
            repo,
            ["rev-parse", "--verify", f"{revision}^{{commit}}"],
            max_bytes=256,
        ),
        "commit object ID",
    )
    if not _OID_RE.fullmatch(oid):
        raise CheckpointError("local Git returned a malformed commit object ID")
    return oid


def _batch_id(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise CheckpointError("batch IDs must be positive integers")
    return value


def _repo_path(value: object) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise CheckpointError("batch file paths must be non-empty strings")
    if value.startswith("/"):
        raise CheckpointError("batch file paths must be repository-relative")
    parts = value.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise CheckpointError("batch file paths may not traverse or contain empty components")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise CheckpointError("batch file paths may not contain control characters")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise CheckpointError("batch file paths must be valid UTF-8") from exc
    if len(encoded) > MAX_PATH_BYTES:
        raise CheckpointError("batch file path exceeds the safe path-length limit")
    return value


def _validate_recon_plan(
    recon: Mapping[str, Any],
) -> tuple[dict[int, list[str]], list[int]]:
    raw_batches = recon.get("batches")
    if not isinstance(raw_batches, list) or not raw_batches or len(raw_batches) > MAX_BATCHES:
        raise CheckpointError("recon batches are missing, empty, or over the hard limit")

    seen_ids: set[int] = set()
    seen_files: set[str] = set()
    batch_files: dict[int, list[str]] = {}
    total_path_bytes = 0
    for raw_batch in raw_batches:
        if not isinstance(raw_batch, dict):
            raise CheckpointError("every recon batch must be a JSON object")
        batch = cast(dict[str, Any], raw_batch)
        current_id = _batch_id(batch.get("id"))
        if current_id in seen_ids:
            raise CheckpointError("recon batch IDs must be unique")
        seen_ids.add(current_id)

        raw_files = batch.get("files")
        if not isinstance(raw_files, list) or not raw_files or len(raw_files) > MAX_BATCH_FILES:
            raise CheckpointError("every recon batch needs a bounded non-empty files list")
        files = [_repo_path(path) for path in raw_files]
        if len(files) != len(set(files)):
            raise CheckpointError("a recon batch may not contain duplicate files")
        overlap = seen_files.intersection(files)
        if overlap:
            raise CheckpointError("a tracked file may appear in only one recon batch")
        seen_files.update(files)
        total_path_bytes += sum(len(path.encode("utf-8")) for path in files)
        if len(seen_files) > MAX_TOTAL_FILES or total_path_bytes > MAX_BATCH_PATH_BYTES:
            raise CheckpointError("recon file scope exceeds the bounded checkpoint limits")

        if "dir" in batch and not isinstance(batch["dir"], str):
            raise CheckpointError("recon batch dir must be a string")
        if "tier" in batch and batch["tier"] not in {"critical", "normal", "low"}:
            raise CheckpointError("recon batch tier is invalid")
        if "deferred" in batch and not isinstance(batch["deferred"], bool):
            raise CheckpointError("recon batch deferred must be boolean")
        batch_files[current_id] = sorted(files)

    if "batch_count" in recon and (
        isinstance(recon["batch_count"], bool)
        or not isinstance(recon["batch_count"], int)
        or recon["batch_count"] != len(raw_batches)
    ):
        raise CheckpointError("recon batch_count does not match its batches")
    if "files_in_scope" in recon and (
        isinstance(recon["files_in_scope"], bool)
        or not isinstance(recon["files_in_scope"], int)
        or recon["files_in_scope"] != len(seen_files)
    ):
        raise CheckpointError("recon files_in_scope does not match its unique files")

    raw_covered = recon.get("covered", [])
    if not isinstance(raw_covered, list):
        raise CheckpointError("recon covered must be a list")
    covered = [_batch_id(value) for value in raw_covered]
    if len(covered) != len(set(covered)) or not set(covered).issubset(seen_ids):
        raise CheckpointError("recon covered contains duplicate or unknown batch IDs")
    return batch_files, covered


def _validate_recon(recon: Mapping[str, Any], requested_id: int) -> tuple[list[str], list[int]]:
    batch_files, covered = _validate_recon_plan(recon)
    selected_files = batch_files.get(requested_id)
    if selected_files is None:
        raise CheckpointError("requested batch ID is not present in recon")
    return selected_files, covered


def _path_chunks(files: Sequence[str]) -> list[list[str]]:
    chunks: list[list[str]] = []
    current: list[str] = []
    current_bytes = 0
    for path in files:
        path_bytes = len(path.encode("utf-8"))
        if current and (len(current) >= 200 or current_bytes + path_bytes > 32_000):
            chunks.append(current)
            current = []
            current_bytes = 0
        current.append(path)
        current_bytes += path_bytes
    if current:
        chunks.append(current)
    return chunks


def _blob_oids(repo: Path, head: str, files: Sequence[str]) -> dict[str, str]:
    requested = set(files)
    result: dict[str, str] = {}
    for chunk in _path_chunks(files):
        raw = _git_bytes(repo, ["ls-tree", "-z", head, "--", *chunk])
        for record in raw.split(b"\x00"):
            if not record:
                continue
            if b"\t" not in record:
                raise CheckpointError("local Git returned a malformed tree record")
            metadata, raw_path = record.split(b"\t", 1)
            parts = metadata.split()
            if len(parts) != 3 or parts[1] not in {b"blob", b"commit"}:
                raise CheckpointError("every selected path must resolve to a tracked Git object")
            try:
                path = raw_path.decode("utf-8")
                oid = parts[2].decode("ascii")
            except (UnicodeDecodeError, UnicodeEncodeError) as exc:
                raise CheckpointError("local Git returned a non-UTF-8 path or object ID") from exc
            if path not in requested or path in result or not _OID_RE.fullmatch(oid):
                raise CheckpointError("local Git returned an unexpected tree record")
            result[path] = oid
    if set(result) != requested:
        missing = len(requested - set(result))
        raise CheckpointError(
            f"selected batch has {missing} path(s) that are not an exact tracked object at HEAD"
        )
    return result


def _require_head_clean(repo: Path, files: Sequence[str]) -> None:
    for chunk in _path_chunks(files):
        changed = _git_bytes(
            repo,
            ["status", "--porcelain=v1", "-z", "--untracked-files=no", "--", *chunk],
        )
        if changed:
            raise CheckpointError(
                "selected batch has tracked worktree or index changes not represented by HEAD"
            )


def _jsonl_bytes(value: Mapping[str, Any]) -> bytes:
    try:
        data = (
            json.dumps(
                dict(value),
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, UnicodeEncodeError) as exc:
        raise CheckpointError("checkpoint record is not safely serializable") from exc
    if len(data) > MAX_JSONL_LINE_BYTES:
        raise CheckpointError("checkpoint record exceeds the JSONL line limit")
    return data


def _append_jsonl(path: Path, values: Sequence[Mapping[str, Any]]) -> None:
    if not values:
        return
    payloads = [_jsonl_bytes(value) for value in values]
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
    except OSError as exc:
        raise CheckpointError(f"cannot safely append {path.name}") from exc
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise CheckpointError(f"{path.name} is not a regular file")
        for data in payloads:
            written = os.write(fd, data)
            if written != len(data):
                raise CheckpointError(f"short append while writing {path.name}")
        os.fsync(fd)
    finally:
        os.close(fd)


def _atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    temp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            prefix=f".{path.name}.tmp-",
            dir=path.parent,
            delete=False,
        ) as handle:
            temp_name = handle.name
            os.fchmod(handle.fileno(), 0o600)
            json.dump(dict(value), handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            if handle.tell() > MAX_RECON_BYTES:
                raise CheckpointError("updated recon.json exceeds its bounded size")
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        directory_flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            directory_flags |= os.O_DIRECTORY
        directory_fd = os.open(path.parent, directory_flags)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as exc:
        raise CheckpointError("could not atomically persist recon.json") from exc
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass


def _event_exists(path: Path, batch_id: int) -> bool:
    for value in _read_jsonl_tail(path, max_bytes=MAX_LEDGER_TAIL_BYTES):
        if value.get("event") != "batch_covered":
            continue
        try:
            event_batch = _batch_id(value.get("batch", value.get("id")))
        except CheckpointError:
            continue
        if event_batch == batch_id:
            return True
    return False


def _snapshot_records_from_values(
    values: Sequence[Mapping[str, Any]], batch_id: int, files: Sequence[str]
) -> dict[str, tuple[str, str]]:
    allowed = set(files)
    records: dict[str, tuple[str, str]] = {}
    for value in values:
        try:
            record_batch = _batch_id(value.get("batch"))
        except CheckpointError:
            continue
        if record_batch != batch_id:
            continue
        file = value.get("file")
        head = value.get("head")
        blob_oid = value.get("blob_oid")
        if (
            value.get("schema") != 1
            or not isinstance(file, str)
            or file not in allowed
            or not isinstance(head, str)
            or not _OID_RE.fullmatch(head)
            or not isinstance(blob_oid, str)
            or not _OID_RE.fullmatch(blob_oid)
            or len(head) != len(blob_oid)
        ):
            raise CheckpointError("selected batch has a malformed audit snapshot record")
        prior = records.get(file)
        current = (head, blob_oid)
        if prior is not None and prior != current:
            raise CheckpointError("selected batch has conflicting audit snapshot records")
        records[file] = current
    return records


def _snapshot_records(
    path: Path, batch_id: int, files: Sequence[str]
) -> dict[str, tuple[str, str]]:
    values = _read_jsonl_tail(path, max_bytes=MAX_SNAPSHOT_TAIL_BYTES)
    return _snapshot_records_from_values(values, batch_id, files)


def _verify_or_prepare_snapshots(
    repo: Path,
    files: Sequence[str],
    existing: Mapping[str, tuple[str, str]],
) -> tuple[str, dict[str, str]]:
    if existing:
        heads = {head for head, _ in existing.values()}
        if len(heads) != 1:
            raise CheckpointError("selected batch snapshots do not share one exact HEAD")
        recorded_head = next(iter(heads))
        head = _resolve_commit(repo, recorded_head)
        if head != recorded_head:
            raise CheckpointError("selected batch snapshot HEAD did not resolve exactly")
    else:
        head = _resolve_commit(repo)
        _require_head_clean(repo, files)

    expected = _blob_oids(repo, head, files)
    for file, (recorded_head, recorded_oid) in existing.items():
        if recorded_head != head or expected.get(file) != recorded_oid:
            raise CheckpointError("selected batch snapshot does not match its exact Git blob")
    return head, expected


def verify_run_coverage(run_dir: Path, repo: Path) -> list[dict[str, Any]]:
    """Return exact snapshot records for the recon/ledger coverage intersection.

    All artifacts are bounded and parsed once. A recon-only or ledger-only
    claim is ignored. Once a batch is present on both progress surfaces, its
    snapshot set must be complete, non-conflicting, schema 1, and byte-exact
    with the recorded commit's local Git blobs or verification fails closed.
    """

    try:
        resolved_run_dir = run_dir.resolve(strict=True)
        resolved_repo = repo.resolve(strict=True)
    except OSError as exc:
        raise CheckpointError("run directory or repository is unreadable") from exc
    if not resolved_run_dir.is_dir():
        raise CheckpointError("run directory is not a directory")
    _validate_repo(resolved_repo)

    recon = _load_json_object(resolved_run_dir / "recon.json", MAX_RECON_BYTES)
    batch_files, recon_covered = _validate_recon_plan(recon)
    ledger_values = _read_jsonl_tail(
        resolved_run_dir / "ledger.jsonl", max_bytes=MAX_LEDGER_TAIL_BYTES
    )
    snapshots_values = _read_jsonl_tail(
        resolved_run_dir / "audit-snapshots.jsonl", max_bytes=MAX_SNAPSHOT_TAIL_BYTES
    )

    ledger_covered: set[int] = set()
    for value in ledger_values:
        if value.get("event") != "batch_covered":
            continue
        try:
            event_batch = _batch_id(value.get("batch", value.get("id")))
        except CheckpointError:
            continue
        if event_batch in batch_files:
            ledger_covered.add(event_batch)

    covered_batches = sorted(set(recon_covered).intersection(ledger_covered))
    if not covered_batches:
        return []

    snapshots_by_batch: dict[int, dict[str, tuple[str, str]]] = {}
    head_by_batch: dict[int, str] = {}
    files_by_head: dict[str, list[str]] = {}
    for batch_id in covered_batches:
        files = batch_files[batch_id]
        snapshots = _snapshot_records_from_values(snapshots_values, batch_id, files)
        if set(snapshots) != set(files):
            raise CheckpointError(
                f"covered batch {batch_id} is missing its complete exact snapshot set"
            )
        heads = {head for head, _ in snapshots.values()}
        if len(heads) != 1:
            raise CheckpointError(f"covered batch {batch_id} snapshots conflict on HEAD")
        head = next(iter(heads))
        snapshots_by_batch[batch_id] = snapshots
        head_by_batch[batch_id] = head
        files_by_head.setdefault(head, []).extend(files)

    expected_by_head: dict[str, dict[str, str]] = {}
    for recorded_head, files in sorted(files_by_head.items()):
        resolved_head = _resolve_commit(resolved_repo, recorded_head)
        if resolved_head != recorded_head:
            raise CheckpointError("covered snapshot HEAD did not resolve exactly")
        expected_by_head[recorded_head] = _blob_oids(resolved_repo, recorded_head, files)

    verified: list[dict[str, Any]] = []
    for batch_id in covered_batches:
        head = head_by_batch[batch_id]
        expected = expected_by_head[head]
        for file in batch_files[batch_id]:
            recorded_head, recorded_oid = snapshots_by_batch[batch_id][file]
            if recorded_head != head or expected.get(file) != recorded_oid:
                raise CheckpointError(
                    f"covered snapshot for {file} does not match its exact Git blob"
                )
            verified.append(
                {
                    "schema": 1,
                    "batch": batch_id,
                    "file": file,
                    "head": head,
                    "blob_oid": recorded_oid,
                }
            )
    return verified


def _checkpoint(run_dir: Path, batch_id: int, repo: Path) -> int:
    _validate_repo(repo)
    recon_path = run_dir / "recon.json"
    ledger_path = run_dir / "ledger.jsonl"
    snapshots_path = run_dir / "audit-snapshots.jsonl"
    recon = _load_json_object(recon_path, MAX_RECON_BYTES)
    files, covered = _validate_recon(recon, batch_id)
    existing = _snapshot_records(snapshots_path, batch_id, files)
    event_already_written = _event_exists(ledger_path, batch_id)

    if batch_id in covered:
        # ``covered`` is written last, but still verify both prerequisite
        # surfaces rather than trusting a forged or partially-restored receipt.
        # Never reconstruct missing snapshots from today's HEAD: that would
        # bless code that was not necessarily the code actually audited.
        if set(existing) != set(files):
            raise CheckpointError(
                "covered receipt is missing its complete exact snapshot set; re-hunt required"
            )
        _verify_or_prepare_snapshots(repo, files, existing)
        if not event_already_written:
            _append_jsonl(ledger_path, [{"event": "batch_covered", "batch": batch_id}])
        print(f"BATCH_COVERED={batch_id} SNAPSHOTS=0")
        return 0

    head, expected = _verify_or_prepare_snapshots(repo, files, existing)

    if event_already_written and set(existing) != set(files):
        raise CheckpointError(
            "batch_covered event exists without a complete exact snapshot set; refusing coverage"
        )

    missing = [file for file in files if file not in existing]
    snapshot_values: list[Mapping[str, Any]] = [
        {
            "schema": 1,
            "batch": batch_id,
            "file": file,
            "head": head,
            "blob_oid": expected[file],
        }
        for file in missing
    ]
    # Recovery after an event-before-recon crash relies only on the bounded
    # snapshot tail. Prove the complete selected batch (not just today's
    # missing suffix) fits in that recovery window before publishing anything.
    full_snapshot_bytes = sum(
        len(
            _jsonl_bytes(
                {
                    "schema": 1,
                    "batch": batch_id,
                    "file": file,
                    "head": head,
                    "blob_oid": expected[file],
                }
            )
        )
        for file in files
    )
    if full_snapshot_bytes > MAX_SNAPSHOT_TAIL_BYTES - MAX_JSONL_LINE_BYTES:
        raise CheckpointError("selected batch snapshot set exceeds the bounded recovery tail")
    _append_jsonl(snapshots_path, snapshot_values)

    if not event_already_written:
        _append_jsonl(ledger_path, [{"event": "batch_covered", "batch": batch_id}])

    recon["covered"] = [*covered, batch_id]
    _atomic_json(recon_path, recon)
    print(f"BATCH_COVERED={batch_id} SNAPSHOTS={len(snapshot_values)}")
    return 0


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "verify":
        try:
            records = verify_run_coverage(Path(sys.argv[2]), Path(sys.argv[3]))
            for record in records:
                print(json.dumps(record, sort_keys=True, separators=(",", ":")))
            return 0
        except (CheckpointError, OSError) as exc:
            print(f"verify-run-coverage: {exc}", file=sys.stderr)
            return 1
    if len(sys.argv) != 4:
        print(
            "usage: _mark_batch_covered.py <RUN_DIR> <BATCH_ID> <REPO>\n"
            "   or: _mark_batch_covered.py verify <RUN_DIR> <REPO>",
            file=sys.stderr,
        )
        return 2
    raw_batch_id = sys.argv[2]
    if not _CLI_BATCH_RE.fullmatch(raw_batch_id):
        print("mark-batch-covered: batch ID must be a positive integer", file=sys.stderr)
        return 1
    try:
        run_dir = Path(sys.argv[1]).resolve(strict=True)
        repo = Path(sys.argv[3]).resolve(strict=True)
        if not run_dir.is_dir():
            raise CheckpointError("run directory is not a directory")
        return _checkpoint(run_dir, int(raw_batch_id), repo)
    except (CheckpointError, OSError) as exc:
        print(f"mark-batch-covered: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
