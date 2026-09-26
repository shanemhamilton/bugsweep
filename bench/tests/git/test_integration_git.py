"""Git-backed integration coordinator tests; run only under --full-git-ci."""

import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "_integration_checks.py"


def _module():
    spec = importlib.util.spec_from_file_location("integration_git", SCRIPT)
    assert spec and spec.loader
    value = importlib.util.module_from_spec(spec); sys.modules[spec.name] = value; spec.loader.exec_module(value)
    return value


def test_real_git_merge_export_accepts_a_trusted_provider_result(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Uses a real Git export; only the trusted provider boundary is mocked."""
    module = _module(); repo, run, scratch = tmp_path / "repo", tmp_path / "run", tmp_path / "scratch"
    repo.mkdir(); run.mkdir(); scratch.mkdir()
    def git(*args: str) -> str: return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()
    subprocess.run(["git", "init", "-q", str(repo)], check=True); git("config", "user.email", "test@example.com"); git("config", "user.name", "test")
    (repo / "app.txt").write_text("base\n"); git("add", "app.txt"); git("commit", "-qm", "base"); git("branch", "-M", "main"); git("checkout", "-qb", "bugsweep/fix")
    (repo / "fix.txt").write_text("fixed\n"); git("add", "fix.txt"); git("commit", "-qm", "fix")
    git("checkout", "-q", "main")
    (repo / "target.txt").write_text("target\n"); git("add", "target.txt"); git("commit", "-qm", "target")
    git("merge", "--no-ff", "-qm", "merged", "bugsweep/fix"); merge_sha = git("rev-parse", "HEAD")
    command = ["synthetic", "check"]; policy = {"mode": "required-untrusted", "backend": "docker", "scratch_root": str(scratch)}
    def record(request, source):
        manifest = hashlib.sha256(module.canonical_json_bytes(source)).hexdigest()
        execution = {"termination": "exited", "exit_code": 0, "command": command, "command_sha256": hashlib.sha256(module.canonical_json_bytes(command)).hexdigest(), "config_sha256": module.execution_config_sha256(request["execution_policy"], ()), "environment_sha256": module.execution_environment_sha256({}), "backend": {"name": "docker", "engine_sha256": "a" * 64, "image_digest": "b" * 64}, "backend_readback_path": "mock", "backend_readback_sha256": "c" * 64, "backend_readback_verified": True, "capabilities": {"isolation": "verified", "network": "verified_denied", "deadline": "process_group_term_kill_reap", "output_import": "trusted_side", "evidence_tier": "verified_backend"}, "execution_policy": request["execution_policy"], "source_identity": {"kind": "content-manifest-sha256", "sha256": manifest, "source_file_sha256": source}, "source_manifest_sha256": manifest}
        return {"check": "check", "status": "pass", **{key: execution[key] for key in ("command_sha256", "config_sha256", "environment_sha256")}, "execution": execution}
    initial = {"app.txt": hashlib.sha256(b"base\n").hexdigest()}; baseline = {"schema_version": 1, "run_id": "run", "phase": "verify", "source_file_sha256": initial, "source_manifest_sha256": hashlib.sha256(module.canonical_json_bytes(initial)).hexdigest(), "checks": [record({"execution_policy": policy}, initial)], "regressions": [], "proof_error": False, "execution_policy_mode": "required-untrusted"}
    (run / "check-plan.json").write_text(json.dumps({"run_id": "run", "checks": [{"name": "check", "command": command}], "execution_policy": policy})); (run / "baseline.json").write_text(json.dumps(baseline))
    monkeypatch.setattr(module, "_check_record", lambda _run, request, _entry, _index: record(request, request["source_file_sha256"]))
    import scripts._execution as execution
    monkeypatch.setattr(execution, "validate_execution_receipt", lambda *_args: [])
    result = module.run_integration_checks(run, repo, merge_sha, "bugsweep/fix", Path(shutil.which("git") or "git").resolve())
    assert result["status"] == "verified"
    receipt = json.loads(Path(result["receipt_path"]).read_text())
    assert receipt["merge_sha"] == merge_sha
    assert {"fix.txt", "target.txt"} <= set(receipt["source_file_sha256"])
