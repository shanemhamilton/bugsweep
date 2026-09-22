"""Focused no-runtime tests for coordinator analyzer receipt production."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

from scripts import _prepare_analyzers as subject


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_producer_uses_frozen_config_and_emits_receipt_bound_pointer(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path / "source"; root.mkdir(); (root / "app.py").write_text("pass\n")
    run = tmp_path / "authority" / "run"; run.mkdir(parents=True)
    sources = {"app.py": _sha(root / "app.py")}
    state = {"schema_version": 1, "run_id": "run-1", "target_root": str(root), "deadline_epoch": 9999999999,
             "source_files": ["app.py"], "policy": {"mode": "required-untrusted"}, "analyzer_enabled": True,
             "analyzer_configs": [{"tool": "semgrep", "tool_version": "1.0", "command": ["installed-semgrep", "--sarif"], "sarif_path": "result.sarif", "uri_base_ids": {"SRC": "."}}]}
    (run / "execution-preparation.json").write_text(json.dumps(state))
    (run / "source-digests.json").write_text(json.dumps(sources))
    (run / "analyzer-imports.json").write_text(json.dumps({"schema_version": 1, "configured_tools": ["semgrep"], "imports": []}))

    def fake_run(command, cwd, output_dir, deadline, policy, predeclared_outputs):
        assert deadline == 1300
        output_dir.mkdir(parents=True)
        artifact = output_dir / "result.sarif"; artifact.write_text('{"version":"2.1.0","runs":[]}')
        receipt = {"command": list(command), "command_sha256": subject._digest(list(command)),
                   "outputs": [{"kind": "sarif", "path": str(artifact), "sha256": _sha(artifact), "bytes": artifact.stat().st_size}]}
        (output_dir / "execution-receipt.json").write_text(json.dumps(receipt))
        return receipt

    monkeypatch.setattr(subject, "run_command", fake_run)
    monkeypatch.setattr(subject.time, "time", lambda: 1000)
    monkeypatch.setattr(subject, "validate_execution_receipt", lambda *_args, **_kwargs: [])
    manifest = subject.produce(run)
    assert manifest["configured_tools"] == ["semgrep"] and len(manifest["imports"]) == 1
    pointer = manifest["imports"][0]
    analysis = Path(pointer["analysis_receipt_path"])
    assert analysis.is_file() and not analysis.is_symlink()
    receipt = json.loads(analysis.read_text())
    assert receipt["command"] == ["installed-semgrep", "--sarif"]
    assert receipt["source_file_sha256"] == sources
    assert (run / "analyzer-imports.json").read_bytes() == subject.canonical_json_bytes(manifest)
    state["analyzer_enabled"] = False
    (run / "execution-preparation.json").write_text(json.dumps(state))
    assert subject.produce(run) == {"available": False, "reason": "analyzers_disabled"}


def test_installed_entrypoint_loads_outside_repository(tmp_path):
    completed = subprocess.run([sys.executable, "-I", "-B", subject.__file__, "--help"],
                               cwd=tmp_path, text=True, capture_output=True)
    assert completed.returncode == 0, completed.stderr
    assert "run_dir" in completed.stdout


def test_importer_uses_frozen_worktree_and_settings(tmp_path):
    from scripts._prepare_execution import initialize
    root = Path(subject.__file__).resolve().parents[1]
    main, worktree, run = (tmp_path / name for name in ("main", "worktree", "run"))
    for directory in (main, worktree, run):
        directory.mkdir()
    (worktree / "app.py").write_text("pass\n")
    inventory, config = tmp_path / "files.nul", tmp_path / "config.json"
    inventory.write_bytes(b"app.py\x00")
    config.write_text(json.dumps({"analyzers": {"enabled": True, "max_hits": 7,
        "imports": [{"tool": "semgrep", "tool_version": "1", "command": ["unused"],
                     "sarif_path": "out.sarif", "uri_base_ids": {}}]}}))
    initialize(run, worktree, "r1", 9999999999, config, inventory)
    config.write_text(json.dumps({"analyzers": {"enabled": False}}))
    result = subprocess.run(["/bin/bash", str(root / "scripts/analyzers.sh"), str(run)],
                            cwd=main, env={**os.environ, "SOURCE_ROOT": str(main)},
                            text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    hits = json.loads((run / "analyzer-hits.json").read_text())
    assert hits["availability"]["semgrep"]["state"] == "unavailable"
    assert hits["analysis_ran"] is False
    assert hits["count"] == 0
