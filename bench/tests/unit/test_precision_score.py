"""Tests for bench.scorer.precision_score."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from bench.scorer.precision import PrecisionCaseResult, PrecisionJudgement, SampledFinding
from bench.scorer.precision_score import score_results_dir, write_precision_track

MODEL = "test-model"


class MultiResponseClient:
    """Returns responses from a list; repeats the last entry when exhausted."""

    def __init__(self, responses: list[str]) -> None:
        self._responses = responses
        self._idx = 0
        self.calls: list[str] = []

    def complete(self, *, model: str, temperature: float, prompt: str) -> str:
        self.calls.append(prompt)
        resp = self._responses[min(self._idx, len(self._responses) - 1)]
        self._idx += 1
        return resp


def _write_ground_truths(results_dir: Path, data: dict) -> None:
    (results_dir / "ground_truths.json").write_text(json.dumps(data), encoding="utf-8")


def _write_provenance(results_dir: Path, line_window: int = 10) -> None:
    (results_dir / "provenance.json").write_text(
        json.dumps({"line_window": line_window}), encoding="utf-8"
    )


def _write_report(run_dir: Path, content: str) -> None:
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "report.md").write_text(content, encoding="utf-8")


# ── score_results_dir ───────────────────────────────────────────────────────────

def test_score_results_dir_empty_when_no_arm_dir(tmp_path) -> None:
    _write_ground_truths(tmp_path, {})
    _write_provenance(tmp_path)
    client = MultiResponseClient(["[]"])
    assert score_results_dir(tmp_path, client, MODEL) == []


def test_score_results_dir_skips_missing_report(tmp_path) -> None:
    run_dir = tmp_path / "bugsweep" / "case-1" / "run-1"
    run_dir.mkdir(parents=True)
    _write_ground_truths(tmp_path, {"case-1": {"description": "sql", "files": ["a.py"]}})
    _write_provenance(tmp_path)
    client = MultiResponseClient(["[]"])
    assert score_results_dir(tmp_path, client, MODEL) == []


def test_score_results_dir_processes_non_gt_finding(tmp_path) -> None:
    run_dir = tmp_path / "bugsweep" / "case-1" / "run-1"
    _write_report(run_dir, "## Confirmed but not fixed\n- B1 · high · sec · a.py:10 · SQLi\n")
    _write_ground_truths(tmp_path, {"case-1": {"description": "XSS", "files": ["other.py"]}})
    _write_provenance(tmp_path)
    # extract LLM → B1; GT judge for B1 → no match; precision judge for B1 → real
    client = MultiResponseClient([
        '[{"bug_id": "B1", "file": "a.py", "line": 10, "rationale": "SQLi"}]',
        '{"match": false, "confidence": 10, "reason": "different"}',
        '{"is_real": true, "confidence": 80, "reason": "confirmed"}',
    ])
    results = score_results_dir(tmp_path, client, MODEL)
    assert len(results) == 1
    r = results[0]
    assert isinstance(r, PrecisionCaseResult)
    assert r.case_id == "case-1"
    assert r.run == 1
    assert r.arm == "bugsweep"
    assert r.total_confirmed == 1
    assert r.sampled == 1
    assert r.real == 1
    assert r.precision == 1.0


def test_score_results_dir_excludes_gt_matched_from_precision(tmp_path) -> None:
    run_dir = tmp_path / "bugsweep" / "case-1" / "run-1"
    _write_report(run_dir, "## Confirmed but not fixed\n- B1 · high · sec · a.py:10 · SQLi\n")
    _write_ground_truths(tmp_path, {"case-1": {"description": "SQLi", "files": ["a.py"]}})
    _write_provenance(tmp_path)
    # B1 matches GT → excluded from precision → sampled=0
    client = MultiResponseClient([
        '[{"bug_id": "B1", "file": "a.py", "line": 10, "rationale": "SQLi"}]',
        '{"match": true, "confidence": 90, "reason": "same"}',
    ])
    results = score_results_dir(tmp_path, client, MODEL)
    assert len(results) == 1
    r = results[0]
    assert r.total_confirmed == 1
    assert r.sampled == 0
    assert r.real == 0
    assert r.precision == 0.0


def test_score_results_dir_multiple_runs(tmp_path) -> None:
    for n in (1, 2):
        run_dir = tmp_path / "bugsweep" / "case-1" / f"run-{n}"
        _write_report(run_dir, "## Confirmed but not fixed\n- B1 · high · sec · a.py:10 · r\n")
    _write_ground_truths(tmp_path, {"case-1": {"description": "XSS", "files": ["z.py"]}})
    _write_provenance(tmp_path)
    client = MultiResponseClient([
        '[{"bug_id": "B1", "file": "a.py", "line": 10, "rationale": "r"}]',
        '{"match": false, "confidence": 0, "reason": "no"}',
        '{"is_real": true, "confidence": 80, "reason": "ok"}',
        '[{"bug_id": "B1", "file": "a.py", "line": 10, "rationale": "r"}]',
        '{"match": false, "confidence": 0, "reason": "no"}',
        '{"is_real": false, "confidence": 20, "reason": "vague"}',
    ])
    results = score_results_dir(tmp_path, client, MODEL)
    assert len(results) == 2
    assert results[0].run == 1 and results[1].run == 2
    assert results[0].real == 1
    assert results[1].real == 0


def test_score_results_dir_processes_empty_confirmed_section(tmp_path) -> None:
    run_dir = tmp_path / "bugsweep" / "c1" / "run-1"
    _write_report(run_dir, "## Confirmed but not fixed\n")
    _write_ground_truths(tmp_path, {"c1": {"description": "d", "files": ["a.py"]}})
    # extract returns [] for empty section → total_confirmed=0, sampled=0
    client = MultiResponseClient(["[]"])
    results = score_results_dir(tmp_path, client, MODEL)
    assert len(results) == 1
    r = results[0]
    assert r.total_confirmed == 0
    assert r.sampled == 0


# ── write_precision_track ───────────────────────────────────────────────────────

def _make_result(case_id: str = "c1", run: int = 1) -> PrecisionCaseResult:
    jdg = PrecisionJudgement(
        is_real=True, confidence=80, reason="ok", model="m", prompt_hash="ph"
    )
    sf = SampledFinding(bug_id="B1", file="a.py", rationale="r", judgement=jdg)
    return PrecisionCaseResult(
        case_id=case_id, run=run, arm="bugsweep",
        total_confirmed=3, sampled=1, real=1, precision=1.0,
        findings=(sf,),
    )


def test_write_precision_track_creates_file(tmp_path) -> None:
    out = tmp_path / "precision_track.jsonl"
    write_precision_track([_make_result()], out)
    assert out.is_file()


def test_write_precision_track_jsonl_one_line_per_result(tmp_path) -> None:
    out = tmp_path / "precision_track.jsonl"
    write_precision_track([_make_result("c1", 1), _make_result("c2", 2)], out)
    lines = [l for l in out.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 2


def test_write_precision_track_aggregate_fields(tmp_path) -> None:
    out = tmp_path / "precision_track.jsonl"
    write_precision_track([_make_result()], out)
    rec = json.loads(out.read_text(encoding="utf-8").strip())
    assert rec["case_id"] == "c1"
    assert rec["run"] == 1
    assert rec["arm"] == "bugsweep"
    assert rec["total_confirmed"] == 3
    assert rec["sampled"] == 1
    assert rec["real"] == 1
    assert abs(rec["precision"] - 1.0) < 1e-9


def test_write_precision_track_finding_detail(tmp_path) -> None:
    out = tmp_path / "precision_track.jsonl"
    write_precision_track([_make_result()], out)
    rec = json.loads(out.read_text(encoding="utf-8").strip())
    assert len(rec["findings"]) == 1
    f = rec["findings"][0]
    assert f["bug_id"] == "B1"
    assert f["file"] == "a.py"
    assert f["rationale"] == "r"
    assert f["is_real"] is True
    assert f["confidence"] == 80
    assert f["reason"] == "ok"


def test_write_precision_track_empty(tmp_path) -> None:
    out = tmp_path / "precision_track.jsonl"
    write_precision_track([], out)
    assert out.read_text(encoding="utf-8") == ""
