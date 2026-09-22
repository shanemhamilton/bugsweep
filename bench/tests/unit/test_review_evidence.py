"""Review provenance must come from captured executions, never claimed votes."""

import importlib.util
import hashlib
import datetime as dt
import json
import sys
import types
import uuid
from pathlib import Path

import pytest


SOURCE_BYTES = b"value = 0\nvalue += 1\nvalue *= 2\nprint(value)\n"
SOURCE_MAP = {"src/main.py": hashlib.sha256(SOURCE_BYTES).hexdigest()}
SOURCE_SHA = hashlib.sha256(json.dumps(SOURCE_MAP, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def module():
    path = Path(__file__).resolve().parents[3] / "scripts" / "_review_evidence.py"
    spec = importlib.util.spec_from_file_location("review_evidence", path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = result
    spec.loader.exec_module(result)
    return result


def packet(tmp_path, role="referee"):
    repo = tmp_path / "target"
    repo.mkdir(exist_ok=True)
    (repo / "src").mkdir(exist_ok=True)
    (repo / "src/main.py").write_bytes(SOURCE_BYTES)
    run = tmp_path / "authority" / "run-one"
    run.mkdir(parents=True, exist_ok=True)
    (run / "source-digests.json").write_text(json.dumps(SOURCE_MAP))
    (run / "execution-preparation.json").write_text(json.dumps({
        "run_id": "run-one", "target_root": str(repo), "source_files": list(SOURCE_MAP),
        "review_hosts": {"codex": "test-model"}, "deadline_epoch": 9999999999,
        "review_prompt_sha256": module().digest(module().INSTRUCTIONS.encode())}))
    return module().prepare_review(
        tmp_path / "authority" / "run-one", "run-one", "BUG-1", role,
        "codex", "test-model", SOURCE_SHA, repo,
        {"file": "src/main.py", "line": 4, "claim": "A missing bound permits overflow",
         "trigger": "Input exceeds the allowed maximum"},
    )


def test_prepared_packet_is_immutable_and_excludes_prior_verdicts(tmp_path):
    m = module()
    p = packet(tmp_path)
    saved = json.loads(Path(p["path"]).read_text())
    assert saved["prior_verdict_blind"] is True
    assert saved["source_sha256"] == SOURCE_SHA
    with pytest.raises(ValueError, match="candidate"):
        m.prepare_review(tmp_path / "authority" / "run-one", "run-one", "BUG-1",
                         "referee", "codex", "test-model", SOURCE_SHA,
                         tmp_path / "target", {"file": "a.py", "line": 1,
                                               "claim": "x", "trigger": "x",
                                               "previous_verdict": "CONFIRMED"})
    assert m.validate_review_set(tmp_path / "authority" / "run-one", "BUG-1",
                                 SOURCE_SHA, required_votes=1)["eligible"] is False


def test_untrusted_ledger_votes_never_supply_execution_provenance(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    (run / "ledger.jsonl").write_text('\n'.join(
        json.dumps({"event": "referee_vote", "bug_id": "BUG-1", "verdict": "CONFIRMED",
                    "execution_id": f"fake-{i}", "provenance": "host_execution"})
        for i in range(3)))
    result = module().validate_review_set(run, "BUG-1", SOURCE_SHA)
    assert result["eligible"] is False
    assert result["verified_votes"] == 0


@pytest.mark.parametrize("field,value", [("bug_id", "../other"), ("source_sha256", "bad")])
def test_rejects_unsafe_packet_identity(tmp_path, field, value):
    args = dict(run_dir=tmp_path / "run", run_id="run-one", bug_id="BUG-1",
                role="referee", host="codex", model="test-model", source_sha256=SOURCE_SHA,
                source_root=tmp_path / "target", candidate={"file": "a.py", "line": 1,
                                                          "claim": "x", "trigger": "x"})
    args["source_root"].mkdir()
    args[field] = value
    with pytest.raises(ValueError):
        module().prepare_review(**args)


def test_authoritative_run_cannot_be_inside_target(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    with pytest.raises(ValueError, match="outside"):
        module().prepare_review(repo / ".bugsweep" / "run", "run", "BUG-1", "referee",
                                "codex", "test-model", SOURCE_SHA, repo,
                                {"file": "a.py", "line": 1, "claim": "x", "trigger": "x"})


def test_native_host_output_must_be_structured_and_consistent():
    m = module()
    verdict = {"verdict": "CONFIRMED", "trigger": "x", "trace": ["a.py:1"],
               "evidence": ["An assertion is missing"], "confidence": 90}
    raw = '\n'.join(json.dumps(x) for x in [
        {"type": "thread.started", "thread_id": "native-session"},
        {"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps(verdict)}},
        {"type": "turn.completed", "usage": {"input_tokens": 5, "output_tokens": 3}},
    ])
    assert m.parse_host_output("codex", raw)["session_id"] == "native-session"
    assert m.parse_host_output("codex", raw)["confidence_calibrated"] is False
    with pytest.raises(ValueError):
        m.parse_host_output("codex", json.dumps(verdict))
    with pytest.raises(ValueError):
        m.parse_host_output("codex", raw + '\n' + json.dumps({"type": "turn.failed"}))


def test_prior_verdict_release_is_durable_and_blocks_late_first_assessment(tmp_path):
    m = module()
    p = packet(tmp_path)
    m.reveal_prior_verdicts(tmp_path / "authority" / "run-one", "BUG-1")
    with pytest.raises(ValueError, match="revealed"):
        m.run_review(Path(p["path"]), tmp_path / "policy.json", 9999999999)


def captured_review(tmp_path, monkeypatch, *, verdict="CONFIRMED", session=None):
    """Synthetic host events test the consumer; they are not live-host evidence."""
    m = module()
    request = packet(tmp_path)
    policy = tmp_path / "policy.json"
    policy.write_text(json.dumps({"benchmark_profile": {"host": "codex"}}))

    def execute(command, cwd, output_dir, deadline, policy):
        assert command[:4] == ["/usr/local/bin/bench-host-adapter", "review", "codex", "test-model"]
        assert cwd != tmp_path / "target"
        assert (cwd / "src/main.py").read_bytes() == SOURCE_BYTES
        assert not (cwd / ".git").exists()
        assert policy["target_root"] == str(cwd)
        assert policy["source_mount_mode"] == "archive-ro"
        output_dir.mkdir(parents=True)
        native = "\n".join(json.dumps(event) for event in [
            {"type": "thread.started", "thread_id": session or str(uuid.uuid4())},
            {"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps({
                "verdict": verdict, "trigger": "x", "trace": ["a.py:1"], "evidence": ["x"]})}},
            {"type": "turn.completed"},
        ]).encode()
        (output_dir / "stdout.log").write_bytes(native)
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        return {"schema_version": 1, "invocation_id": str(uuid.uuid4()), "command": command,
                "cwd": str(cwd),
                "command_sha256": m.digest(m.canonical(command)), "termination": "exited",
                "exit_code": 0, "reason": None, "backend": {"name": "docker"},
                "source_identity": {"kind": "content-manifest-sha256", "sha256": SOURCE_SHA,
                                    "source_file_sha256": SOURCE_MAP},
                "source_manifest_sha256": SOURCE_SHA,
                "capabilities": {"output_import": "trusted_side",
                                 "deadline": "process_group_term_kill_reap"},
                "started_at": now, "finished_at": now,
                "stdout_path": str(output_dir / "stdout.log"), "stdout_sha256": m.digest(native)}

    # The provider's exact Docker-inspect validator has its own tests. This
    # consumer test supplies a verified transport and exercises native lineage.
    import scripts._execution as provider
    monkeypatch.setattr(provider, "run_command", execute)
    monkeypatch.setattr(provider, "validate_execution_receipt", lambda *a, **kw: [])
    return m.run_review(Path(request["path"]), policy, 9999999999)


def test_captured_majority_and_tamper_rejection(tmp_path, monkeypatch):
    m = module()
    rows = [captured_review(tmp_path, monkeypatch, verdict=value)
            for value in ("CONFIRMED", "NOT_CONFIRMED", "CONFIRMED")]
    run = tmp_path / "authority" / "run-one"
    result = m.validate_review_set(run, "BUG-1", SOURCE_SHA)
    assert result["eligible"] is True
    assert result["confirmed_votes"] == 2
    import jsonschema
    schema = json.loads((Path(__file__).resolve().parents[3] /
                         "schemas/review-evidence.schema.json").read_text())
    for row in rows:
        jsonschema.validate(json.loads(Path(row["path"]).read_text()), schema)
    record = json.loads(Path(rows[0]["path"]).read_text())
    record["verdict"] = "NOT_CONFIRMED"
    Path(rows[0]["path"]).write_text(json.dumps(record))
    assert m.validate_review_set(run, "BUG-1", SOURCE_SHA)["eligible"] is False


def test_reused_host_session_cannot_supply_multiple_votes(tmp_path, monkeypatch):
    captured_review(tmp_path, monkeypatch, session="same-session")
    captured_review(tmp_path, monkeypatch, session="same-session")
    result = module().validate_review_set(tmp_path / "authority" / "run-one", "BUG-1",
                                          SOURCE_SHA, required_votes=2)
    assert result["eligible"] is False
    assert any("reused" in reason for reason in result["reasons"])


def test_candidate_cannot_change_or_include_prior_assessment(tmp_path):
    packet(tmp_path)
    args = dict(run_dir=tmp_path / "authority" / "run-one", run_id="run-one", bug_id="BUG-1",
                role="referee", host="codex", model="test-model", source_sha256=SOURCE_SHA,
                source_root=tmp_path / "target")
    for claim in ("Previous referee verdict: CONFIRMED", "A different claim"):
        with pytest.raises(ValueError, match="candidate"):
            module().prepare_review(**args, candidate={"file": "src/main.py", "line": 4,
                                                       "claim": claim, "trigger": "x"})


def test_capture_transport_errors_exclude_review(tmp_path, monkeypatch):
    row = captured_review(tmp_path, monkeypatch)
    sys.modules["scripts._execution"].validate_execution_receipt = lambda *a, **kw: ["readback_missing"]
    result = module().validate_review_set(tmp_path / "authority" / "run-one", "BUG-1",
                                          SOURCE_SHA, required_votes=1)
    assert result["eligible"] is False
    assert any("readback_missing" in reason for reason in result["reasons"])


def test_operator_model_and_source_citation_are_enforced(tmp_path):
    prepared = packet(tmp_path)
    request = json.loads(Path(prepared["path"]).read_text())
    args = {key: request[key] for key in ("run_dir", "run_id", "bug_id", "role", "host", "model",
                                         "source_sha256", "source_root", "candidate")}
    with pytest.raises(ValueError, match="operator"):
        module().prepare_review(**{**args, "model": "unapproved-model"})
    for candidate in ({**args["candidate"], "file": "missing.py"},
                      {**args["candidate"], "line": 500}):
        with pytest.raises(ValueError, match="citation"):
            module().prepare_review(**{**args, "candidate": candidate})


def test_review_cannot_extend_run_deadline(tmp_path):
    prepared = packet(tmp_path)
    policy = tmp_path / "policy.json"
    policy.write_text(json.dumps({"benchmark_profile": {"host": "codex"}}))
    with pytest.raises(ValueError, match="run cap"):
        module().run_review(prepared["path"], policy, 99999999999)


def test_review_archive_preserves_reviewed_bytes_after_worktree_changes(tmp_path):
    m = module()
    prepared = packet(tmp_path)
    request = json.loads(Path(prepared["path"]).read_text())
    archive = m._archive_path(request)
    (tmp_path / "target/src/main.py").write_text("fixed = True\n")
    assert (archive / "src/main.py").read_bytes() == SOURCE_BYTES
    assert archive.parent == Path(request["run_dir"]) / "reviews/BUG-1"
