"""Installer source contracts that do not execute an installer or real Git."""

import json
from pathlib import Path

import pytest

from scripts.installer_helper import (
    copy_config,
    failure_payload,
    recover_transaction,
    registration_content,
    write_transaction,
)


ROOT = Path(__file__).resolve().parents[3]


def test_registration_replaces_only_the_owned_block() -> None:
    root = "/tmp/codex/skills/bugsweep"
    owned = registration_content("", root)
    old = "before\n" + owned + "after\n"
    updated = registration_content(old, root)

    assert updated.startswith("before\n<!-- bugsweep-skill -->")
    assert updated.endswith("<!-- /bugsweep-skill -->\nafter\n")
    assert updated.count("<!-- bugsweep-skill -->") == 1


def test_registration_migrates_only_the_exact_legacy_stanza() -> None:
    root = "/tmp/codex/skills/bugsweep"
    legacy = (
        "<!-- bugsweep-skill -->\n"
        "## bugsweep skill\n"
        "When the user types `/bugsweep` (with any flags) or asks to find/fix bugs autonomously,\n"
        "read the full skill instructions from:\n"
        f"  {root}/SKILL.md\n"
        f"All referenced scripts live in {root}/scripts/, prompts in {root}/prompts/,\n"
        f"and config in {root}/config/. Expand relative script paths to absolute ones when running.\n"
    )

    assert registration_content(legacy + "my notes\n", root).endswith(
        "<!-- /bugsweep-skill -->\nmy notes\n"
    )


def test_registration_refuses_an_ambiguous_legacy_marker() -> None:
    try:
        registration_content("<!-- bugsweep-skill -->\nmy notes\n", "/tmp/codex/skills/bugsweep")
    except ValueError as exc:
        assert "ambiguous" in str(exc)
    else:  # pragma: no cover - a regression produces the assertion below
        raise AssertionError("ambiguous legacy ownership must fail closed")


def _transaction(tmp_path: Path, *, original_exists: bool, instructions_existed: bool = False) -> tuple[Path, Path, Path, Path]:
    parent = tmp_path / "skills"
    parent.mkdir()
    destination = parent / "bugsweep"
    stage = parent / ".bugsweep.stage.next"
    backup = parent / ".bugsweep.backup.next"
    journal = parent / ".bugsweep.install-recovery.json"
    write_transaction(
        journal,
        {
            "schema_version": 1,
            "destination": str(destination),
            "stage": str(stage),
            "backup": str(backup),
            "original_exists": original_exists,
            "instructions": str(tmp_path / "instructions.md"),
            "instructions_existed": instructions_existed,
            "registration_backup": str(tmp_path / ".instructions.bugsweep.backup.next"),
        },
    )
    return destination, stage, backup, journal


def test_recovery_restores_active_install_after_kill_between_renames(tmp_path: Path) -> None:
    destination, stage, backup, journal = _transaction(tmp_path, original_exists=True)
    destination.mkdir()
    (destination / "old").write_text("old", encoding="utf-8")
    stage.mkdir()
    (stage / "new").write_text("new", encoding="utf-8")
    destination.rename(backup)  # interrupted after destination -> backup

    result = recover_transaction(journal)

    assert result["actions"] == ["restored-backup"]
    assert (destination / "old").read_text(encoding="utf-8") == "old"
    assert (stage / "new").read_text(encoding="utf-8") == "new"


def test_recovery_refuses_journal_for_a_sibling_target_before_any_rename(tmp_path: Path) -> None:
    destination, stage, backup, journal = _transaction(tmp_path, original_exists=True)
    sibling = destination.with_name("other-skill")
    data = json.loads(journal.read_text(encoding="utf-8"))
    data["destination"] = str(sibling)
    journal.write_text(json.dumps(data), encoding="utf-8")
    sibling.mkdir()
    (sibling / "must-stay").write_text("user", encoding="utf-8")
    stage.mkdir()
    backup.mkdir()

    with pytest.raises(ValueError, match="does not match"):
        recover_transaction(journal, destination)

    assert (sibling / "must-stay").read_text(encoding="utf-8") == "user"
    assert stage.is_dir() and backup.is_dir()


def test_recovery_preserves_new_stage_before_restoring_old_active_install(tmp_path: Path) -> None:
    destination, stage, backup, journal = _transaction(tmp_path, original_exists=True)
    destination.mkdir()
    (destination / "old").write_text("old", encoding="utf-8")
    stage.mkdir()
    (stage / "new").write_text("new", encoding="utf-8")
    destination.rename(backup)
    stage.rename(destination)  # interrupted after stage -> destination

    recover_transaction(journal)

    assert (destination / "old").read_text(encoding="utf-8") == "old"
    assert (stage / "new").read_text(encoding="utf-8") == "new"


def test_recovery_removes_only_exact_owned_new_instructions_file(tmp_path: Path) -> None:
    destination, stage, _, journal = _transaction(tmp_path, original_exists=False)
    destination.mkdir()
    (destination / "install-metadata.json").write_text("{}", encoding="utf-8")
    instructions = tmp_path / "instructions.md"
    instructions.write_text(registration_content("", str(destination)), encoding="utf-8")

    recover_transaction(journal)

    assert not destination.exists()
    assert stage.exists()
    assert not instructions.exists()


def test_recovery_refuses_to_delete_user_owned_new_instructions_file(tmp_path: Path) -> None:
    destination, _, _, journal = _transaction(tmp_path, original_exists=False)
    destination.mkdir()
    (tmp_path / "instructions.md").write_text("user notes\n", encoding="utf-8")

    with pytest.raises(ValueError, match="exactly owned"):
        recover_transaction(journal)


@pytest.mark.parametrize("original_exists", [True, False])
def test_recovery_leaves_ambiguous_interrupted_installs_untouched(
    tmp_path: Path, original_exists: bool
) -> None:
    """Recovery must not guess which of several surviving installs is owned."""
    destination, stage, backup, journal = _transaction(tmp_path, original_exists=original_exists)
    destination.mkdir()
    (destination / "active").write_text("new", encoding="utf-8")
    stage.mkdir()
    (stage / "staged").write_text("candidate", encoding="utf-8")
    if original_exists:
        backup.mkdir()
        (backup / "backup").write_text("old", encoding="utf-8")

    with pytest.raises(ValueError, match="ambiguous"):
        recover_transaction(journal)

    assert (destination / "active").read_text(encoding="utf-8") == "new"
    assert (stage / "staged").read_text(encoding="utf-8") == "candidate"
    if original_exists:
        assert (backup / "backup").read_text(encoding="utf-8") == "old"


def test_recovery_restores_prior_instructions_from_exact_backup(tmp_path: Path) -> None:
    destination, stage, backup, journal = _transaction(
        tmp_path, original_exists=True, instructions_existed=True
    )
    destination.mkdir()
    (destination / "old").write_text("old", encoding="utf-8")
    stage.mkdir()
    (stage / "new").write_text("new", encoding="utf-8")
    destination.rename(backup)
    stage.rename(destination)
    instructions = tmp_path / "instructions.md"
    instructions.write_text(registration_content("", str(destination)), encoding="utf-8")
    prior = tmp_path / ".instructions.bugsweep.backup.next"
    prior.write_text("user instructions\n", encoding="utf-8")

    result = recover_transaction(journal)

    assert "restored-instructions" in result["actions"]
    assert instructions.read_text(encoding="utf-8") == "user instructions\n"
    assert (tmp_path / ".instructions.bugsweep.interrupted.next").is_file()
    assert (destination / "old").exists()
    assert (stage / "new").exists()


def test_copy_config_preserves_valid_user_config_and_rejects_invalid_json(tmp_path: Path) -> None:
    source = tmp_path / "user-config.json"
    destination = tmp_path / "stage" / "config.json"
    source.write_text('{"keep": true}\n', encoding="utf-8")
    copy_config(source, destination)
    assert json.loads(destination.read_text(encoding="utf-8")) == {"keep": True}
    source.write_text("not json", encoding="utf-8")
    with pytest.raises(json.JSONDecodeError):
        copy_config(source, destination)


def test_json_failure_keeps_prior_success_and_exact_pending_recovery(tmp_path: Path) -> None:
    results = tmp_path / "results.tsv"
    results.write_text("claude\t/tmp/claude/bugsweep\tstable\tv1.2.3\tabc\t1.2.3\tverified\n", encoding="utf-8")
    recovery = tmp_path / "recovery.jsonl"
    payload = failure_payload(
        results,
        recovery,
        host="codex",
        root="/tmp/codex/skills/bugsweep",
        channel="stable",
        tag="v1.2.3",
        commit="abc",
        journal="/tmp/codex/skills/.bugsweep.install-recovery.json",
        reason="metadata write failed",
    )

    assert [item["status"] for item in payload["installations"]] == ["verified", "failed"]
    assert payload["installations"][1]["root"] == "/tmp/codex/skills/bugsweep"
    assert payload["recovery"] == [{"status": "pending", "journal": "/tmp/codex/skills/.bugsweep.install-recovery.json", "reason": "metadata write failed"}]


def test_installer_defaults_to_stable_and_uses_commit_bound_staging() -> None:
    text = (ROOT / "install.sh").read_text(encoding="utf-8")

    assert 'CHANNEL="stable"' in text
    assert '--edge' in text
    assert 'refs/heads/main' in text
    assert 'refs/tags/' in text
    assert 'expected commit' in text
    assert 'mktemp -d "$parent/.${SKILL_NAME}.stage.' in text
    assert 'install-metadata.json' in text
    assert 'CLAUDE_SKILLS_DIR' in text
    assert 'CODEX_DIR' in text
    assert 'CODEX_SKILLS_DIR' not in text


def test_runtime_dependency_is_declared_and_checked_before_staging() -> None:
    project = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")

    assert '"jsonschema==4.26.0"' in project
    assert "require_runtime_dependencies" in installer
    assert 'version("jsonschema") == "4.26.0"' in installer
    assert "require_runtime_dependencies; RESULTS_FILE" not in installer
    assert "trap 'rm -f \"$RESULTS_FILE\" \"$RECOVERY_FILE\"' EXIT; require_runtime_dependencies" in installer


def test_installer_never_uses_reset_stash_or_forced_checkout() -> None:
    text = (ROOT / "install.sh").read_text(encoding="utf-8")
    assert "git reset" not in text
    assert "git stash" not in text
    assert "checkout -f" not in text


def test_updater_is_bound_to_its_own_metadata_root() -> None:
    text = (ROOT / "scripts" / "update-install.sh").read_text(encoding="utf-8")
    assert "ACTIVE_ROOT" in text
    assert "canonical_root" in text
    assert "--all" in text


def test_quality_gate_is_session_pure_and_requires_real_evidence() -> None:
    text = (ROOT / "scripts" / "quality-check.sh").read_text(encoding="utf-8")
    # The shell delegates evidence verification to the reducer; it must not
    # inspect caller-supplied release flags or digest strings itself.
    assert "python3 -B -m bench.scorer.evaluation" in text
    assert "--published-summary" in text
    assert "--protocol" in text
    assert "--schedule" in text
    assert "--execution-order" in text
    assert "--receipts" in text
    assert "--evidence-root" in text
    assert "BUGSWEEP_FULL_GIT_CI" in text
    assert "coverage report --fail-under=80" in text
    assert "BUGSWEEP_BATS_VERSION" in text
    assert "BUGSWEEP_SHELLCHECK_VERSION" in text
    assert "bats tests/bats bench/tests/bats" in text
    assert "git -" not in text.lower()


def test_quality_workflow_uses_fixed_runner_and_tool_versions() -> None:
    text = (ROOT / ".github" / "workflows" / "quality.yml").read_text(encoding="utf-8")
    assert "ubuntu-24.04" in text
    assert "macos-14" in text
    assert "pytest==9.0.3" in text
    assert "jsonschema==4.26.0" in text
