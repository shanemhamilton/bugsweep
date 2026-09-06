"""Pure contract tests for receipt-bound SARIF imports (R4)."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import jsonschema
import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from bench.scorer.analyzer_norm import import_sarif_results  # noqa: E402


def _sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _identity(files: dict[str, Path]) -> tuple[dict[str, str], dict[str, object]]:
    mapped = {name: _sha(path.read_bytes()) for name, path in files.items()}
    return mapped, {"kind": "content-manifest-sha256", "sha256": _sha(json.dumps(mapped, sort_keys=True, separators=(",", ":")).encode()), "source_file_sha256": mapped}


def _sarif(uri: str = "app.py", base: str | None = "SRC") -> dict[str, object]:
    location = {"physicalLocation": {"artifactLocation": {"uri": uri, **({"uriBaseId": base} if base else {})}, "region": {"startLine": 1}}}
    return {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "Semgrep"}}, "results": [{"ruleId": "rule", "level": "error", "message": {"text": "candidate"}, "locations": [location]}]}]}


def _bound_descriptor(tmp_path: Path, root: Path, sarif: dict[str, object], *, sources: dict[str, Path] | None = None, tool: str = "semgrep") -> tuple[dict[str, object], dict[str, object]]:
    artifacts = tmp_path / "authority" / "analyzer-artifacts" / tool
    artifacts.mkdir(parents=True)
    artifact = artifacts / "result.sarif"
    artifact.write_text(json.dumps(sarif), encoding="utf-8")
    files, identity = _identity(sources or {"app.py": root / "app.py"})
    execution = artifacts / "execution-receipt.json"
    execution_value = {"command": ["installed-tool", "--sarif"], "command_sha256": _sha(json.dumps(["installed-tool", "--sarif"], sort_keys=True, separators=(",", ":")).encode()), "outputs": [{"kind": "sarif", "path": str(artifact), "sha256": _sha(artifact.read_bytes()), "bytes": artifact.stat().st_size}]}
    execution.write_text(json.dumps(execution_value), encoding="utf-8")
    analysis = artifacts / "analysis-receipt.json"
    analysis_value = {"schema_version": 1, "run_id": "run-1", "target_root": str(root), "tool": tool, "tool_version": "1.0", "command": ["installed-tool", "--sarif"], "command_sha256": execution_value["command_sha256"], "source_identity": identity, "source_file_sha256": files, "source_manifest_sha256": identity["sha256"], "uri_base_ids": {"SRC": "."}, "execution_receipt_path": str(execution), "execution_receipt_sha256": _sha(execution.read_bytes()), "artifact_path": str(artifact), "artifact_sha256": _sha(artifact.read_bytes()), "artifact_bytes": artifact.stat().st_size}
    analysis.write_text(json.dumps(analysis_value), encoding="utf-8")
    context = {"run_id": "run-1", "target_root": str(root), "source_file_sha256": files, "source_manifest_sha256": identity["sha256"], "artifact_root": str(tmp_path / "authority" / "analyzer-artifacts"), "receipt_root": str(tmp_path / "authority" / "analyzer-artifacts")}
    return {"tool": tool, "analysis_receipt_path": str(analysis), "analysis_receipt_sha256": _sha(analysis.read_bytes())}, context


@pytest.fixture(autouse=True)
def _verified_provider(monkeypatch: pytest.MonkeyPatch) -> None:
    import scripts._execution
    monkeypatch.setattr(scripts._execution, "validate_execution_receipt", lambda *_args, **_kwargs: [])


def test_imports_receipt_bound_sarif_and_preserves_data_only_claim(tmp_path: Path) -> None:
    root = tmp_path / "source"; root.mkdir(); (root / "app.py").write_text("pass\n")
    descriptor, context = _bound_descriptor(tmp_path, root, _sarif())
    report = import_sarif_results([descriptor], root, configured_tools=("semgrep", "codeql"), trusted_context=context)
    assert report["analysis_ran"] is False and report["ranking_hints_only"] is True
    assert report["count"] == 1 and report["availability"]["semgrep"]["state"] == "imported"
    assert report["availability"]["codeql"]["state"] == "unavailable"
    assert report["hits"][0]["evidence_status"] == "verified"
    jsonschema.validate(report, json.loads((ROOT / "schemas" / "analyzer-import.schema.json").read_text()))


def test_descriptor_cannot_enable_unconfigured_tool_or_choose_root(tmp_path: Path) -> None:
    root = tmp_path / "source"; root.mkdir(); (root / "app.py").write_text("pass\n")
    descriptor, context = _bound_descriptor(tmp_path, root, _sarif())
    report = import_sarif_results([descriptor], root, configured_tools=("codeql",), trusted_context=context)
    assert report["hits"] == [] and report["availability"]["codeql"]["state"] == "unavailable"
    descriptor["artifact_root"] = str(tmp_path)  # ignored; only analysis receipt roots count
    report = import_sarif_results([descriptor], root, configured_tools=("semgrep",), trusted_context={**context, "artifact_root": str(tmp_path / "elsewhere")})
    assert report["availability"]["semgrep"]["state"] == "unavailable"


def test_partial_source_map_is_rejected_against_frozen_full_snapshot(tmp_path: Path) -> None:
    root = tmp_path / "source"; root.mkdir(); (root / "app.py").write_text("pass\n"); (root / "other.py").write_text("pass\n")
    descriptor, context = _bound_descriptor(tmp_path, root, _sarif())
    full_files, full_identity = _identity({"app.py": root / "app.py", "other.py": root / "other.py"})
    context.update(source_file_sha256=full_files, source_manifest_sha256=full_identity["sha256"])
    report = import_sarif_results([descriptor], root, configured_tools=("semgrep",), trusted_context=context)
    assert report["availability"]["semgrep"]["state"] == "rejected"


def test_base_alias_symlink_is_rejected(tmp_path: Path) -> None:
    root = tmp_path / "source"; root.mkdir(); real = root / "real"; real.mkdir(); (real / "app.py").write_text("pass\n"); (root / "alias").symlink_to(real, target_is_directory=True)
    descriptor, context = _bound_descriptor(tmp_path, root, _sarif("app.py", "LIB"), sources={"real/app.py": real / "app.py"})
    analysis = Path(descriptor["analysis_receipt_path"]); data = json.loads(analysis.read_text()); data["uri_base_ids"] = {"LIB": "alias"}; analysis.write_text(json.dumps(data)); descriptor["analysis_receipt_sha256"] = _sha(analysis.read_bytes())
    report = import_sarif_results([descriptor], root, configured_tools=("semgrep",), trusted_context=context)
    assert report["availability"]["semgrep"]["state"] == "rejected"


def test_over_limit_results_are_rejected_never_imported_as_zero(tmp_path: Path) -> None:
    root = tmp_path / "source"; root.mkdir(); (root / "app.py").write_text("pass\n")
    payload = _sarif(); payload["runs"][0]["results"] *= 1001
    descriptor, context = _bound_descriptor(tmp_path, root, payload)
    report = import_sarif_results([descriptor], root, configured_tools=("semgrep",), max_results_per_import=1000, trusted_context=context)
    assert report["count"] == 0 and report["availability"]["semgrep"]["state"] == "rejected"
    assert report["availability"]["semgrep"]["reason"] == "result_count_exceeded"


def test_multiple_descriptors_aggregate_deterministically(tmp_path: Path) -> None:
    root = tmp_path / "source"; root.mkdir(); (root / "app.py").write_text("pass\n")
    good, context = _bound_descriptor(tmp_path, root, _sarif())
    bad = dict(good); bad["analysis_receipt_sha256"] = "0" * 64
    first = import_sarif_results([good, bad], root, configured_tools=("semgrep",), trusted_context=context)
    second = import_sarif_results([bad, good], root, configured_tools=("semgrep",), trusted_context=context)
    assert first["availability"]["semgrep"] == second["availability"]["semgrep"]
    assert first["availability"]["semgrep"]["state"] == "rejected"
    assert first["hits"] == second["hits"] == []


def test_import_count_is_bounded_before_materializing(tmp_path: Path) -> None:
    root = tmp_path / "source"; root.mkdir(); (root / "app.py").write_text("pass\n")
    descriptor, context = _bound_descriptor(tmp_path, root, _sarif())
    report = import_sarif_results((descriptor for _ in range(17)), root, configured_tools=("semgrep",), trusted_context=context)
    assert report["availability"]["semgrep"]["reason"] == "import_count_exceeded"


def test_entrypoint_refuses_symlink_output(tmp_path: Path) -> None:
    victim = tmp_path / "victim"; victim.write_text("sentinel")
    output = tmp_path / "analyzer-hits.json"; output.symlink_to(victim)
    env = {**os.environ, "BUGSWEEP_ROOT": str(ROOT), "RAW_MANIFEST": str(tmp_path / "missing.json"), "PYTHONDONTWRITEBYTECODE": "1"}
    completed = subprocess.run([sys.executable, "-B", str(ROOT / "scripts" / "_analyzer_norm.py"), str(output)], env=env, capture_output=True, text=True)
    assert completed.returncode != 0 and victim.read_text() == "sentinel"


def test_schema_is_valid() -> None:
    schema = json.loads((ROOT / "schemas" / "analyzer-import.schema.json").read_text())
    jsonschema.Draft202012Validator.check_schema(schema)
