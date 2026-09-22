"""Coordinator preparation uses real files but never runs repository code."""
import hashlib
import json

import pytest

from scripts._prepare_execution import initialize, refresh_checks, repro_pre, repro_post


def test_prepare_before_after_preserves_commands_test_and_review(tmp_path):
    target, run = tmp_path / "target", tmp_path / "authority"
    target.mkdir()
    run.mkdir()
    (target / "app.py").write_text("answer = 0\n")
    (target / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    inventory, config, policy = (tmp_path / name for name in ("files.nul", "config.json", "policy.json"))
    inventory.write_bytes(b"app.py\x00pyproject.toml\x00")
    config.write_text(json.dumps({"commands": {}, "analyzers": {"imports": ["semgrep"]}}))
    policy.write_text(json.dumps({"mode": "required-untrusted", "backend": "docker"}))
    initialize(run, target, "run-1", 9999999999, config, inventory, policy)
    baseline = json.loads((run / "check-plan.json").read_text())
    assert baseline["checks"][0]["command"] == [
        "python3", "-B", "-m", "pytest", "-p", "no:cacheprovider", "-q",
        "--junitxml=/bugsweep-output/suite.xml"]
    reviewed = baseline["source_file_sha256"]
    (target / "test_app.py").write_text("def test_answer():\n    assert answer == 1\n")
    spec = tmp_path / "repro.json"
    spec.write_text(json.dumps({"command": ["python3", "-m", "pytest", "test_app.py",
                                           "--junitxml=/bugsweep-output/repro.xml"],
         "test": {"path": "test_app.py", "native_id": "test_app::test_answer",
                  "expected_failure_type": "assertion", "expected_failure_message": "assert 0 == 1"},
         "intended_source_files": ["app.py"], "junit_path": "repro.xml",
         "review_source_file_sha256": reviewed}))
    pre_path = repro_pre(run, "BUG-1", spec)["path"]
    before = json.loads(open(pre_path).read())
    (target / "app.py").write_text("answer = 1\n")
    refresh_checks(run)
    after_plan = json.loads((run / "check-plan.json").read_text())
    assert baseline["checks"] == after_plan["checks"]
    assert before["source_file_sha256"] != after_plan["source_file_sha256"]
    (run / "check-results-verify.json").write_text(json.dumps({"immutable_path": "checks/result.json",
                                                            "immutable_sha256": "a" * 64}))
    first = repro_post(run, "BUG-1")["path"]
    second = repro_post(run, "BUG-1")["path"]
    post = json.loads(open(first).read())
    assert first != second
    assert post["test"] == before["test"]
    assert post["command"] == before["command"]
    assert post["review_source_file_sha256"] == reviewed
    assert post["source_file_sha256"]["app.py"] == hashlib.sha256(b"answer = 1\n").hexdigest()
    assert json.loads(open(pre_path).read()) == before


def test_unavailable_is_explicit_and_authority_cannot_be_mounted(tmp_path):
    target, run = tmp_path / "target", tmp_path / "run"
    target.mkdir()
    run.mkdir()
    (target / "app.py").write_text("pass\n")
    config, inventory = tmp_path / "config.json", tmp_path / "files.nul"
    config.write_text("{}")
    inventory.write_bytes(b"app.py\x00")
    result = initialize(run, target, "run-1", 9999999999, config, inventory)
    assert result["available"] is False
    assert not (run / "check-plan.json").exists()
    with pytest.raises(ValueError, match="outside target"):
        initialize(target / "run", target, "run-2", 9999999999, config, inventory)


def test_source_symlink_and_inventory_traversal_refused(tmp_path):
    from scripts._prepare_execution import snapshot
    target = tmp_path / "target"
    target.mkdir()
    (tmp_path / "secret").write_text("secret")
    (target / "alias").symlink_to(tmp_path / "secret")
    for source in ("alias", "../secret", "./alias"):
        with pytest.raises(ValueError):
            snapshot(target, [source])


def test_snapshot_includes_untracked_executable_source(tmp_path):
    from scripts._prepare_execution import snapshot
    (tmp_path / "listed.py").write_text("pass\n")
    (tmp_path / "unlisted.sh").write_text("exit 1\n")
    (tmp_path / ".git").write_text("gitdir: /metadata\n")
    assert set(snapshot(tmp_path, ["listed.py"])) == {"listed.py", "unlisted.sh"}


def test_snapshot_rejects_checkout_metadata_directory(tmp_path):
    from scripts._prepare_execution import snapshot
    (tmp_path / ".git").mkdir()
    (tmp_path / "app.py").write_text("pass\n")
    with pytest.raises(ValueError, match="isolated worktree"):
        snapshot(tmp_path, ["app.py"])


def test_run_provenance_freezes_installed_helpers_and_effective_config(tmp_path, monkeypatch):
    from scripts import _prepare_execution as preparation
    skill, target, run = (tmp_path / name for name in ("skill", "target", "run"))
    for directory in (skill, target, run):
        directory.mkdir()
    (skill / "scripts").mkdir()
    (skill / "SKILL.md").write_text("instructions\n")
    (skill / "VERSION").write_text("0.6.0\n")
    helper = skill / "scripts/helper.py"
    helper.write_text("pass\n")
    (target / "app.py").write_text("pass\n")
    inventory, config = tmp_path / "files.nul", tmp_path / "config.json"
    inventory.write_bytes(b"app.py\x00"); config.write_text("{}")
    monkeypatch.setattr(preparation, "SKILL_ROOT", skill)
    preparation.initialize(run, target, "run-1", 9999999999, config, inventory)
    raw = (run / "run-provenance.json").read_bytes()
    provenance = json.loads(raw)
    assert provenance["skill_version"] == "0.6.0"
    assert provenance["skill_files"]["scripts/helper.py"]["sha256"] == hashlib.sha256(b"pass\n").hexdigest()
    assert provenance["coordinator_model"] is None
    assert provenance["runtime"]["jsonschema_version"]
    state = json.loads((run / "execution-preparation.json").read_text())
    assert state["run_provenance_sha256"] == hashlib.sha256(raw).hexdigest()
    helper.write_text("changed\n"); config.write_text('{"changed":true}')
    assert (run / "run-provenance.json").read_bytes() == raw
