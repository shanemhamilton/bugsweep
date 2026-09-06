import hashlib
import json
from pathlib import Path

import pytest

from bench import corpus_tools
from bench import harness


def _case(digest: str) -> dict:
    return {"id": "unit-case", "suite": "pilot-v1", "repository": "example/repo", "language": "python", "category": "logic", "source": {"repo": "example/repo", "commit": "a" * 40, "archive_url": "https://codeload.github.com/example/repo/tar.gz/" + "a" * 40, "archive_sha256": "b" * 64, "license": "MIT"}, "mutation": {"kind": "seeded", "edits": [{"path": "app.py", "before": "return True\\n", "after": "return False\\n", "source_file_sha256": digest}]}, "gold": {"storage": "external-private-gold-root", "locator": "pilot-v1/unit-case", "runtime_status": "UNVERIFIED_PENDING_SANDBOX_RUN", "native": {"argv": ["pytest", "-q", "test_unit.py::test_unit"], "test_file": "test_unit.py", "test_sha256": "c" * 64, "native_test_id": "test_unit.py::test_unit"}, "expected": {"buggy": "fail", "patched": "pass", "assertion": "unit behavior"}, "controls": {"negative": "private negative control", "patched": "private patched control"}, "source_bindings": [{"path": "app.py", "sha256": digest}]}, "size_ceiling": {"max_files": 10, "max_loc": 100}, "task_description": "private metadata"}


def test_apply_mutation_is_source_bound_and_unique(tmp_path: Path) -> None:
    path = tmp_path / "app.py"
    path.write_text("return True\\n", encoding="utf-8")
    case = _case(hashlib.sha256(path.read_bytes()).hexdigest())
    corpus_tools.apply_mutation(tmp_path, case)
    assert path.read_text(encoding="utf-8") == "return False\\n"
    with pytest.raises(corpus_tools.CorpusError, match="source digest mismatch"):
        corpus_tools.apply_mutation(tmp_path, case)


def test_freeze_emits_only_redacted_manifest(tmp_path: Path) -> None:
    source = tmp_path / "source"
    source.mkdir()
    (source / "app.py").write_text("return True\\n", encoding="utf-8")
    case = _case(hashlib.sha256((source / "app.py").read_bytes()).hexdigest())
    case_path = tmp_path / "case.json"
    case_path.write_text(json.dumps(case), encoding="utf-8")
    archive = tmp_path / "archive"
    archive.write_bytes(b"archive")
    case["source"]["archive_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    case_path.write_text(json.dumps(case), encoding="utf-8")
    mounted = corpus_tools.freeze(case_path, source, tmp_path / "mounted", archive)
    assert set(mounted) == {"id", "language", "size_ceiling", "task_description", "source_manifest_sha256"}
    assert mounted["id"].startswith("review-") and mounted["task_description"] == "Review the mounted source and report findings with evidence."
    assert (tmp_path / "mounted" / mounted["id"] / "app.py").read_text(encoding="utf-8") == "return False\\n"


def test_archive_digest_must_match_case_pin(tmp_path: Path) -> None:
    source = tmp_path / "app.py"
    source.write_text("return True\\n", encoding="utf-8")
    case = _case(hashlib.sha256(source.read_bytes()).hexdigest())
    archive = tmp_path / "source.tar.gz"
    archive.write_bytes(b"official archive")
    case["source"]["archive_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert corpus_tools.verify_archive(archive, case) == case["source"]["archive_sha256"]
    archive.write_bytes(b"different bytes")
    with pytest.raises(corpus_tools.CorpusError, match="archive digest mismatch"):
        corpus_tools.verify_archive(archive, case)


def test_private_gold_locator_and_test_bytes_are_bound(tmp_path: Path) -> None:
    source = tmp_path / "app.py"
    source.write_text("return True\\n", encoding="utf-8")
    case = _case(hashlib.sha256(source.read_bytes()).hexdigest())
    test = b"def test_unit(): assert True\\n"
    case["gold"]["native"]["test_sha256"] = hashlib.sha256(test).hexdigest()
    oracle = tmp_path / "gold" / "pilot-v1" / "unit-case" / "test_unit.py"
    oracle.parent.mkdir(parents=True)
    oracle.write_bytes(test)
    assert corpus_tools.verify_private_gold(case, tmp_path / "gold") == oracle
    oracle.write_bytes(b"tampered")
    with pytest.raises(corpus_tools.CorpusError, match="private gold test"):
        corpus_tools.verify_private_gold(case, tmp_path / "gold")


def test_source_identity_matches_harness_and_inventory_binds_modes(tmp_path: Path) -> None:
    source = tmp_path / "source"
    source.mkdir()
    path = source / "app.py"
    path.write_text("x = 1\\n", encoding="utf-8")
    frozen = corpus_tools.source_manifest(source)
    scheduled = harness.source_manifest(source)
    assert frozen["sha256"] == scheduled["sha256"]
    path.chmod(0o700)
    changed = corpus_tools.source_manifest(source)
    assert changed["sha256"] == frozen["sha256"]
    assert changed["inventory_sha256"] != frozen["inventory_sha256"]
