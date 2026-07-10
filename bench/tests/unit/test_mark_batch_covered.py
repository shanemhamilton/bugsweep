"""Adversarial contracts for the deterministic batch coverage checkpoint."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "_mark_batch_covered.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bugsweep_mark_batch_covered", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


def _seed_repo(tmp_path: Path, files: list[str] | None = None) -> tuple[Path, Path]:
    repo = tmp_path / "repo"
    run_dir = repo / ".bugsweep" / "run-test"
    repo.mkdir()
    _git(repo, "init", "-q")
    _git(repo, "config", "user.email", "test@bugsweep.local")
    _git(repo, "config", "user.name", "Bugsweep Test")
    (repo / "src").mkdir()
    (repo / "src" / "app.py").write_text("VALUE = 1\n", encoding="utf-8")
    secret = tmp_path / "outside-secret.txt"
    secret.write_text("must not be opened by the checkpoint\n", encoding="utf-8")
    (repo / "outside-link").symlink_to(secret)
    _git(repo, "add", "--", "src/app.py", "outside-link")
    _git(repo, "commit", "-q", "-m", "seed")
    run_dir.mkdir(parents=True)
    selected = files if files is not None else ["src/app.py", "outside-link"]
    recon = {
        "schema_version": 1,
        "files_in_scope": len(selected),
        "batch_count": 1,
        "large_repo_mode": False,
        "budget_batches": None,
        "batches": [
            {
                "id": 1,
                "dir": "src",
                "tier": "normal",
                "files": selected,
                "deferred": False,
            }
        ],
        "modeled": [1],
        "covered": [],
    }
    (run_dir / "recon.json").write_text(json.dumps(recon), encoding="utf-8")
    (run_dir / "ledger.jsonl").write_text("", encoding="utf-8")
    return repo, run_dir


def _run(repo: Path, run_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(run_dir), "1", str(repo)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def _verify(repo: Path, run_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "verify", str(run_dir), str(repo)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def _jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def test_checkpoint_records_exact_git_blob_oids_and_is_idempotent(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path)

    first = _run(repo, run_dir)
    assert first.returncode == 0, first.stderr
    snapshots = _jsonl(run_dir / "audit-snapshots.jsonl")
    assert {record["file"] for record in snapshots} == {"src/app.py", "outside-link"}
    for record in snapshots:
        assert record["blob_oid"] == _git(repo, "rev-parse", f"HEAD:{record['file']}")

    second = _run(repo, run_dir)
    assert second.returncode == 0, second.stderr
    assert _jsonl(run_dir / "audit-snapshots.jsonl") == snapshots
    events = [
        event for event in _jsonl(run_dir / "ledger.jsonl") if event["event"] == "batch_covered"
    ]
    assert events == [{"batch": 1, "event": "batch_covered"}]
    assert json.loads((run_dir / "recon.json").read_text(encoding="utf-8"))["covered"] == [1]


def test_checkpoint_records_and_verifies_an_exact_submodule_gitlink(tmp_path: Path) -> None:
    submodule = tmp_path / "submodule"
    submodule.mkdir()
    _git(submodule, "init", "-q")
    _git(submodule, "config", "user.email", "test@bugsweep.local")
    _git(submodule, "config", "user.name", "Bugsweep Test")
    (submodule / "library.py").write_text("VALUE = 1\n", encoding="utf-8")
    _git(submodule, "add", "--", "library.py")
    _git(submodule, "commit", "-q", "-m", "seed submodule")

    repo, run_dir = _seed_repo(tmp_path, ["vendor/library"])
    _git(
        repo,
        "-c",
        "protocol.file.allow=always",
        "submodule",
        "add",
        "-q",
        str(submodule),
        "vendor/library",
    )
    _git(repo, "commit", "-q", "-am", "add library submodule")

    checkpoint = _run(repo, run_dir)

    assert checkpoint.returncode == 0, checkpoint.stderr
    expected_gitlink = _git(repo, "rev-parse", "HEAD:vendor/library")
    assert expected_gitlink == _git(submodule, "rev-parse", "HEAD")
    assert _jsonl(run_dir / "audit-snapshots.jsonl") == [
        {
            "batch": 1,
            "blob_oid": expected_gitlink,
            "file": "vendor/library",
            "head": _git(repo, "rev-parse", "HEAD"),
            "schema": 1,
        }
    ]

    verified = _load_module().verify_run_coverage(run_dir, repo)
    assert [(record["file"], record["blob_oid"]) for record in verified] == [
        ("vendor/library", expected_gitlink)
    ]


def test_checkpoint_rejects_a_dirty_tracked_file_before_writing_coverage(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py"])
    (repo / "src" / "app.py").write_text("VALUE = 2\n", encoding="utf-8")

    result = _run(repo, run_dir)

    assert result.returncode == 1
    assert "not represented by HEAD" in result.stderr
    assert _jsonl(run_dir / "ledger.jsonl") == []
    assert _jsonl(run_dir / "audit-snapshots.jsonl") == []
    assert json.loads((run_dir / "recon.json").read_text(encoding="utf-8"))["covered"] == []


def test_checkpoint_requires_every_selected_path_to_be_a_tracked_head_blob(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py", "src/not-tracked.py"])

    result = _run(repo, run_dir)

    assert result.returncode == 1
    assert "tracked object" in result.stderr
    assert _jsonl(run_dir / "ledger.jsonl") == []
    assert _jsonl(run_dir / "audit-snapshots.jsonl") == []


def test_checkpoint_rejects_any_malformed_batch_before_selecting_one(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py"])
    recon = json.loads((run_dir / "recon.json").read_text(encoding="utf-8"))
    recon["batches"].append("hostile-sentinel")
    recon["batch_count"] = 2
    (run_dir / "recon.json").write_text(json.dumps(recon), encoding="utf-8")

    result = _run(repo, run_dir)

    assert result.returncode == 1
    assert "batch" in result.stderr.lower()
    assert _jsonl(run_dir / "ledger.jsonl") == []


def test_retry_after_ledger_append_repairs_recon_without_duplicate_event(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py"])
    assert _run(repo, run_dir).returncode == 0
    recon = json.loads((run_dir / "recon.json").read_text(encoding="utf-8"))
    recon["covered"] = []
    (run_dir / "recon.json").write_text(json.dumps(recon), encoding="utf-8")

    retry = _run(repo, run_dir)

    assert retry.returncode == 0, retry.stderr
    events = [
        event for event in _jsonl(run_dir / "ledger.jsonl") if event["event"] == "batch_covered"
    ]
    assert len(events) == 1
    assert json.loads((run_dir / "recon.json").read_text(encoding="utf-8"))["covered"] == [1]


def test_covered_receipt_refuses_missing_snapshots_instead_of_blessing_head(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py"])
    assert _run(repo, run_dir).returncode == 0
    (run_dir / "audit-snapshots.jsonl").unlink()

    retry = _run(repo, run_dir)

    assert retry.returncode == 1
    assert "covered receipt" in retry.stderr
    assert len(_jsonl(run_dir / "ledger.jsonl")) == 1


def test_covered_receipt_repairs_a_missing_event_from_exact_snapshots(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py"])
    assert _run(repo, run_dir).returncode == 0
    (run_dir / "ledger.jsonl").write_text("", encoding="utf-8")

    retry = _run(repo, run_dir)

    assert retry.returncode == 0, retry.stderr
    assert _jsonl(run_dir / "ledger.jsonl") == [{"batch": 1, "event": "batch_covered"}]
    assert len(_jsonl(run_dir / "audit-snapshots.jsonl")) == 1


def test_tail_reader_never_calls_path_read_bytes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = _load_module()
    path = tmp_path / "ledger.jsonl"
    path.write_bytes(b"x" * 256 + b'\n{"event":"batch_covered","batch":1}\n')

    def forbidden_read_bytes(_self: Path) -> bytes:
        raise AssertionError("unbounded Path.read_bytes must not be used")

    monkeypatch.setattr(Path, "read_bytes", forbidden_read_bytes)
    records = module._read_jsonl_tail(path, max_bytes=64, max_line_bytes=64)

    assert records == [{"event": "batch_covered", "batch": 1}]


def test_tail_reader_ignores_an_unterminated_final_record(tmp_path: Path) -> None:
    module = _load_module()
    path = tmp_path / "ledger.jsonl"
    path.write_bytes(b'{"event":"batch_covered","batch":1}')

    assert module._read_jsonl_tail(path, max_bytes=128, max_line_bytes=128) == []


def test_git_environment_disables_lazy_fetch_prompts_and_pathspec_magic() -> None:
    env = _load_module()._git_env()

    assert env["GIT_NO_LAZY_FETCH"] == "1"
    assert env["GIT_TERMINAL_PROMPT"] == "0"
    assert env["GIT_LITERAL_PATHSPECS"] == "1"
    assert os.environ.get("GIT_NO_LAZY_FETCH") is None or env["GIT_NO_LAZY_FETCH"] == "1"


def test_public_verifier_returns_exact_records_without_mutating_artifacts(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path)
    assert _run(repo, run_dir).returncode == 0
    artifact_paths = [
        run_dir / "recon.json",
        run_dir / "ledger.jsonl",
        run_dir / "audit-snapshots.jsonl",
    ]
    before = {path: path.read_bytes() for path in artifact_paths}

    module = _load_module()
    records = module.verify_run_coverage(run_dir, repo)

    assert [(record["batch"], record["file"]) for record in records] == [
        (1, "outside-link"),
        (1, "src/app.py"),
    ]
    for record in records:
        assert record["schema"] == 1
        assert record["blob_oid"] == _git(repo, "rev-parse", f"HEAD:{record['file']}")
    assert {path: path.read_bytes() for path in artifact_paths} == before

    cli = _verify(repo, run_dir)
    assert cli.returncode == 0, cli.stderr
    assert [json.loads(line) for line in cli.stdout.splitlines()] == records


def test_public_verifier_rejects_a_forged_but_well_formed_blob_oid(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py"])
    assert _run(repo, run_dir).returncode == 0
    snapshots = _jsonl(run_dir / "audit-snapshots.jsonl")
    snapshots[0]["blob_oid"] = "0" * 40
    (run_dir / "audit-snapshots.jsonl").write_text(
        "".join(json.dumps(value) + "\n" for value in snapshots), encoding="utf-8"
    )

    result = _verify(repo, run_dir)

    assert result.returncode == 1
    assert "exact Git blob" in result.stderr
    assert result.stdout == ""


def test_public_verifier_ignores_recon_coverage_without_a_ledger_event(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py"])
    assert _run(repo, run_dir).returncode == 0
    (run_dir / "ledger.jsonl").write_text("", encoding="utf-8")

    result = _verify(repo, run_dir)

    assert result.returncode == 0, result.stderr
    assert result.stdout == ""
    assert _load_module().verify_run_coverage(run_dir, repo) == []


@pytest.mark.parametrize("bad_oid", ["a" * 39, "a" * 41, "a" * 63])
def test_public_verifier_rejects_invalid_oid_lengths(tmp_path: Path, bad_oid: str) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py"])
    assert _run(repo, run_dir).returncode == 0
    snapshots = _jsonl(run_dir / "audit-snapshots.jsonl")
    snapshots[0]["blob_oid"] = bad_oid
    (run_dir / "audit-snapshots.jsonl").write_text(
        json.dumps(snapshots[0]) + "\n", encoding="utf-8"
    )

    result = _verify(repo, run_dir)

    assert result.returncode == 1
    assert "malformed" in result.stderr


def test_public_verifier_rejects_conflicting_snapshots(tmp_path: Path) -> None:
    repo, run_dir = _seed_repo(tmp_path, ["src/app.py"])
    assert _run(repo, run_dir).returncode == 0
    snapshots = _jsonl(run_dir / "audit-snapshots.jsonl")
    conflict = dict(snapshots[0])
    conflict["blob_oid"] = "0" * 40
    with (run_dir / "audit-snapshots.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(conflict) + "\n")

    result = _verify(repo, run_dir)

    assert result.returncode == 1
    assert "conflicting" in result.stderr


def test_tail_reader_ignores_fifo_without_blocking(tmp_path: Path) -> None:
    module = _load_module()
    fifo = tmp_path / "ledger.fifo"
    os.mkfifo(fifo)

    assert module._read_jsonl_tail(fifo, max_bytes=128, max_line_bytes=128) == []
