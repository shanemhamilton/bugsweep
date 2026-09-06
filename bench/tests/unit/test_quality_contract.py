"""Static contracts for the Git-free and reproducible quality partitions."""

import io
import json
import subprocess
from pathlib import Path

from scripts import installer_helper


ROOT = Path(__file__).resolve().parents[3]


def test_default_quality_excludes_the_only_git_unit_test() -> None:
    text = (ROOT / "scripts" / "quality-check.sh").read_text(encoding="utf-8")

    assert "--ignore=bench/tests/unit/test_mark_batch_covered.py" in text
    assert "python3 -B -m pytest -p no:cacheprovider bench/tests/unit/test_mark_batch_covered.py" in text


def test_installer_helper_has_its_own_measured_coverage_gate() -> None:
    text = (ROOT / "scripts" / "quality-check.sh").read_text(encoding="utf-8")

    assert "--source=scripts.installer_helper" in text
    assert "bench/tests/unit/test_install_contract.py" in text
    assert text.count("coverage report --fail-under=80") == 2


def test_evaluation_gate_refuses_forged_summary_without_frozen_inputs(tmp_path: Path) -> None:
    """A caller's release flag cannot bypass reducer inputs at the shell gate."""
    forged = tmp_path / "evaluation.json"
    forged.write_text(
        json.dumps({"release_eligibility": True, "verification": {"complete": True}}),
        encoding="utf-8",
    )
    result = subprocess.run(
        ["bash", str(ROOT / "scripts" / "quality-check.sh"), "--evaluation", str(forged)],
        text=True,
        capture_output=True,
        check=False,
        cwd=ROOT,
    )
    assert result.returncode == 2
    assert "requires --protocol" in result.stderr


def test_workflow_verifies_pinned_tool_archives_without_package_managers() -> None:
    text = (ROOT / ".github" / "workflows" / "quality.yml").read_text(encoding="utf-8")

    assert "bats-core/archive/v1.10.0.tar.gz" in text
    assert "a1a9f7875aa4b6a9480ca384d5865f1ccf1b0b1faead6b47aa47d79709a5c5fd" in text
    assert "shellcheck/releases/download/v0.10.0" in text
    assert "6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87" in text
    assert 'test -x "$tools/shellcheck-v0.10.0/shellcheck"' in text
    assert 'echo "$tools/shellcheck-v0.10.0" >> "$GITHUB_PATH"' in text
    assert "Full Git-backed CI contract" in text
    assert "runs-on: ubuntu-24.04\n    steps:" not in text
    assert "run: bash scripts/quality-check.sh --full-git-ci" in text
    assert "apt-get install" not in text
    assert "brew install" not in text


def test_registration_rejects_ambiguous_owned_markers() -> None:
    root = "/tmp/bugsweep"
    for existing in (
        "<!-- bugsweep-skill -->\n<!-- bugsweep-skill -->\n",
        "<!-- bugsweep-skill -->\nuser-owned text\n<!-- /bugsweep-skill -->\n",
    ):
        try:
            installer_helper.registration_content(existing, root)
        except ValueError:
            pass
        else:  # pragma: no cover - both malformed ownership shapes must reject
            raise AssertionError("ambiguous registration ownership was accepted")


def test_installer_helper_cli_dispatch_stays_local_and_testable(tmp_path: Path, monkeypatch, capsys) -> None:
    """Exercise every non-destructive helper command without an installer or Git."""
    destination = tmp_path / "skills" / "bugsweep"
    destination.parent.mkdir()
    stage = destination.parent / ".bugsweep.stage.next"
    backup = destination.parent / ".bugsweep.backup.next"
    journal = destination.parent / ".bugsweep.install-recovery.json"
    transaction = {
        "schema_version": 1,
        "destination": str(destination),
        "stage": str(stage),
        "backup": str(backup),
        "original_exists": False,
        "instructions": None,
        "instructions_existed": False,
        "registration_backup": "",
    }

    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(transaction)))
    assert installer_helper.main(["helper", "write-transaction", str(journal)]) == 0
    stage.mkdir()
    assert installer_helper.main(["helper", "recover", str(journal), str(destination)]) == 0
    capsys.readouterr()

    destination.mkdir()
    (destination / "install-metadata.json").write_text("{}", encoding="utf-8")
    assert installer_helper.main(["helper", "commit", str(journal)]) == 0

    source = tmp_path / "source.json"
    copied = tmp_path / "copied.json"
    source.write_text('{"safe": true}', encoding="utf-8")
    assert installer_helper.main(["helper", "copy-config", str(source), str(copied)]) == 0
    assert copied.read_text(encoding="utf-8") == '{"safe": true}'

    instructions = tmp_path / "instructions.md"
    assert installer_helper.main(["helper", "registration", str(instructions), str(destination)]) == 0
    assert capsys.readouterr().out == installer_helper.registration_content(
        "", str(destination)
    )

    results = tmp_path / "results.tsv"
    recovery = tmp_path / "recovery.jsonl"
    assert installer_helper.main(
        [
            "helper",
            "failure-json",
            str(results),
            str(recovery),
            "codex",
            str(destination),
            "stable",
            "v1.2.3",
            "abc",
            str(journal),
            "failed locally",
        ]
    ) == 0
    assert installer_helper.main(["helper", "unknown"]) == 2
