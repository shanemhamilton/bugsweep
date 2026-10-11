"""Pure coordinator tests for merged-tree integration checks."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import sys
import tarfile
from pathlib import Path
from types import ModuleType

import pytest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "_integration_checks.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bugsweep_integration_checks", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _archive(path: Path, entries: list[tuple[str, bytes, int, str]]) -> None:
    with tarfile.open(path, "w") as archive:
        for name, content, mode, kind in entries:
            item = tarfile.TarInfo(name)
            item.mode = mode
            if kind == "file":
                item.size = len(content)
                archive.addfile(item, io.BytesIO(content))
            elif kind == "directory":
                item.type = tarfile.DIRTYPE
                archive.addfile(item)
            elif kind == "symlink":
                item.type = tarfile.SYMTYPE
                item.linkname = content.decode()
                archive.addfile(item)


def test_extracts_only_bounded_regular_merged_source(tmp_path: Path) -> None:
    module = _load_module()
    source_tar = tmp_path / "source.tar"
    destination = tmp_path / "projection"
    destination.mkdir()
    _archive(
        source_tar,
        [
            ("src", b"", 0o755, "directory"),
            ("src/main.py", b"print('ok')\n", 0o755, "file"),
            ("README.md", b"read me\n", 0o644, "file"),
        ],
    )

    files, modes = module._extract_archive(source_tar, destination)

    assert files == {
        "README.md": hashlib.sha256(b"read me\n").hexdigest(),
        "src/main.py": hashlib.sha256(b"print('ok')\n").hexdigest(),
    }
    assert modes == {"README.md": "100644", "src/main.py": "100755"}
    assert (destination / "src/main.py").stat().st_mode & 0o777 == 0o755
    assert not (destination / ".git").exists()


@pytest.mark.parametrize(
    "entry",
    [
        ("escape", b"../outside", 0o777, "symlink"),
        ("../outside", b"bad", 0o644, "file"),
        (".git/config", b"bad", 0o644, "file"),
    ],
)
def test_rejects_unsafe_archive_members(
    tmp_path: Path, entry: tuple[str, bytes, int, str]
) -> None:
    module = _load_module()
    source_tar = tmp_path / "source.tar"
    destination = tmp_path / "projection"
    destination.mkdir()
    _archive(source_tar, [entry])

    with pytest.raises(ValueError):
        module._extract_archive(source_tar, destination)


def test_semantic_continuity_ignores_source_but_rejects_command_or_policy_change() -> None:
    module = _load_module()
    baseline = {
        "checks": [
            {
                "check": "test",
                "command_sha256": "a" * 64,
                "config_sha256": "b" * 64,
                "environment_sha256": "c" * 64,
                "status": "pass",
            }
        ]
    }
    current = json.loads(json.dumps(baseline["checks"]))

    assert module._semantic_continuity_reasons(baseline, current) == []
    current[0]["config_sha256"] = "d" * 64
    assert module._semantic_continuity_reasons(baseline, current) == [
        "check_semantics_changed:test"
    ]

    command = ["python3", "-m", "pytest"]
    baseline["checks"][0]["command_sha256"] = hashlib.sha256(
        module.canonical_json_bytes(command)
    ).hexdigest()
    baseline["checks"][0]["execution"] = {
        "command": command,
        "execution_policy": {
            "target_root": "/old/source",
            "scratch_root": "/trusted/scratch",
            "source_identity": {"sha256": "1" * 64},
        },
    }
    plan = {
        "checks": [{"name": "test", "command": command}],
        "execution_policy": {
            "target_root": "/new/source",
            "scratch_root": "/trusted/scratch",
            "source_identity": {"sha256": "2" * 64},
        },
    }
    baseline["checks"][0]["config_sha256"] = module.execution_config_sha256(
        plan["execution_policy"], ()
    )
    baseline["checks"][0]["environment_sha256"] = module.execution_environment_sha256({})
    assert module._frozen_plan_reasons(plan, baseline) == []
    plan["execution_policy"]["scratch_root"] = "/different/scratch"
    assert module._frozen_plan_reasons(plan, baseline) == [
        "baseline_not_bound_to_frozen_plan:test"
    ]


def test_integration_receipts_are_scoped_to_immutable_attempt_ids(tmp_path: Path) -> None:
    module = _load_module()
    run_dir = tmp_path / "authority"
    attempt = "a" * 32
    merge_sha = "b" * 40

    path = module._receipt_path(run_dir, attempt, merge_sha, "bugsweep/one")

    branch_digest = hashlib.sha256("bugsweep/one".encode("utf-8")).hexdigest()[:16]
    assert path == run_dir / "integration-check-results" / attempt / f"{merge_sha}-{branch_digest}.json"
    assert path.parent.name == attempt
    with pytest.raises(ValueError):
        module._receipt_path(run_dir, "not-an-attempt", merge_sha, "bugsweep/one")


def test_authority_boundary_allows_ignored_run_sibling_of_frozen_worktree(tmp_path: Path) -> None:
    module = _load_module()
    repo = tmp_path / "repo"
    worktree = repo / ".bugsweep" / "worktrees" / "run-x"
    authority = repo / ".bugsweep" / "run-x"
    repo.mkdir()
    worktree.mkdir(parents=True)
    authority.mkdir(parents=True)
    plan = {
        "target_root": str(worktree),
        "execution_policy": {"target_root": str(worktree)},
    }

    module._validate_authority_boundary(
        authority,
        module._frozen_target_root(plan),
        repo,
        tracked_paths=("src/app.py",),
    )


@pytest.mark.parametrize(
    "tracked_path",
    [
        ".bugsweep/run-x/check-plan.json",
        ".bugsweep/run-x/child.txt",
        ".bugsweep",
    ],
)
def test_authority_boundary_rejects_tracked_authority_or_parent(
    tmp_path: Path, tracked_path: str
) -> None:
    module = _load_module()
    repo = tmp_path / "repo"
    worktree = repo / ".bugsweep" / "worktrees" / "run-x"
    authority = repo / ".bugsweep" / "run-x"
    repo.mkdir()
    worktree.mkdir(parents=True)
    authority.mkdir(parents=True)
    plan = {
        "target_root": str(worktree),
        "execution_policy": {"target_root": str(worktree)},
    }

    with pytest.raises(ValueError, match="tracked authority path"):
        module._validate_authority_boundary(
            authority,
            module._frozen_target_root(plan),
            repo,
            tracked_paths=(tracked_path,),
        )


def test_authority_boundary_rejects_casefold_alias_and_symlink_redirect(tmp_path: Path) -> None:
    module = _load_module()
    repo = tmp_path / "repo"
    worktree = repo / ".bugsweep" / "worktrees" / "run-x"
    authority = repo / ".bugsweep" / "run-x"
    repo.mkdir()
    worktree.mkdir(parents=True)
    authority.mkdir(parents=True)
    (repo / "authority-alias").symlink_to(authority, target_is_directory=True)
    plan = {
        "target_root": str(worktree),
        "execution_policy": {"target_root": str(worktree)},
    }

    for tracked_path in (
        ".BUGSWEEP/RUN-X/check-plan.json",
        "authority-alias/check-plan.json",
    ):
        with pytest.raises(ValueError, match="tracked authority path"):
            module._validate_authority_boundary(
                authority,
                module._frozen_target_root(plan),
                repo,
                tracked_paths=(tracked_path,),
            )


def test_authority_boundary_rejects_target_overlap_and_git_metadata(tmp_path: Path) -> None:
    module = _load_module()
    repo = tmp_path / "repo"
    repo.mkdir()
    target = repo / "target"
    target.mkdir()
    authority = target / "authority"
    authority.mkdir()
    plan = {
        "target_root": str(target),
        "execution_policy": {"target_root": str(target)},
    }

    with pytest.raises(ValueError, match="target and authority overlap"):
        module._validate_authority_boundary(
            authority, module._frozen_target_root(plan), repo, tracked_paths=()
        )

    git_authority = repo / ".git" / "authority"
    git_authority.mkdir(parents=True)
    with pytest.raises(ValueError, match="Git metadata"):
        module._validate_authority_boundary(
            git_authority, module._frozen_target_root(plan), repo, tracked_paths=()
        )


def test_frozen_target_requires_plan_and_policy_roots_to_match(tmp_path: Path) -> None:
    module = _load_module()
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()

    with pytest.raises(ValueError, match="target roots"):
        module._frozen_target_root(
            {"target_root": str(first), "execution_policy": {"target_root": str(second)}}
        )
