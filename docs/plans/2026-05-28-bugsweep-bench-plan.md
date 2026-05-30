# bugsweep benchmark harness (bench/) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Metaswarm note: execution method is the user's choice (see CLAUDE.md "Execution Method Choice"); this header is the planning-skill default, not binding.

**Goal:** Build a reproducible pilot harness that measures whether bugsweep detects real, post-training-cutoff bugs and beats a no-skill `claude -p` baseline, with a defensible scoring pipeline.

**Architecture:** A Python scorer package (`bench/scorer/`, the coverage-gated core) + Bash glue (`run.sh`, `runners/`, `lib/`) that drives bugsweep headless inside a key-free, no-network-except-proxy container over throwaway clones of dated known-bug repos, parses the report, and scores findings via a file-overlap gate + cross-model LLM judge + human calibration.

**Tech Stack:** Python 3.12 (pytest, ruff, black, mypy, coverage), Bash + bats + shellcheck, Docker, `git`, `jq`, `claude` CLI (runner), OpenAI/codex (judge), a tiny host egress proxy.

**Source spec:** `docs/plans/2026-05-28-bugsweep-bench-design.md` (Design Review Gate 5/5). Issue: shanemhamilton/bugsweep#3. Epic: `bugsweep-293`.

---

## File structure

| Path | Responsibility |
|---|---|
| `pyproject.toml` (repo root) | Python project + pytest/coverage config; `testpaths=["bench/tests/unit"]`, `[tool.coverage.run] source=["bench/scorer"]`; ruff/black/mypy — at repo root so the fixed repo-root `pytest --cov` command resolves the scope |
| `bench/scorer/parse_report.py` | bugsweep `report.md` (+ baseline output) → normalized `findings.json` list |
| `bench/scorer/localize.py` | file-overlap gate; line/category as evidence |
| `bench/scorer/judge.py` | cross-model (OpenAI) cause-match; injectable client |
| `bench/scorer/score.py` | per-case verdict (DETECTED/NOT_DETECTED/ERROR/SKIPPED), aggregates, Wilson CI, paired delta, calibration.csv |
| `bench/corpus/schema.json` | case JSON schema |
| `bench/corpus/cases/*.json` | the dated cases (≥8 post-cutoff, ≥4 cross-file) |
| `bench/lib/proxy.sh` | start/stop host key-injecting egress proxy (exact-host allow-list, refuse CONNECT, strip client auth) |
| `bench/lib/isolate.sh` | build/run the no-key, no-network-except-proxy container with quantified limits |
| `bench/lib/sandbox.sh` | hardened clone → `checkout -b bench-base <sha>` → assert `rev-parse HEAD == sha` |
| `bench/lib/scrub.sh` | redact secrets from output before `results/` + enforced secret-scan |
| `bench/lib/cost.sh` | extract tokens/wall-clock/$ per arm |
| `bench/runners/runner.sh` | adapter dispatch; RESULT=/exit-code contract |
| `bench/runners/claude_p.sh` | bugsweep arm (real skill, detect-only) |
| `bench/runners/claude_p_baseline.sh` | baseline arm (no skill, same findings contract) |
| `bench/run.sh` | orchestrator + leaderboard renderer |
| `bench/tests/unit/*.py` | pytest for scorer |
| `bench/tests/bats/*.bats` | bats for bash glue |
| `SKILL.md` | MODIFY: structured detect-only report line (prerequisite) |

---

## Work units (→ beads issues under bugsweep-293)

Each WU is a tracked beads issue with its own DoD + file scope, sequenced by dependency. Tier-A tests (pytest scorer + bats glue) are container-free and run in the 80% gate; Tier-B (live container) is integration, out-of-gate.

### WU0 — Python + isolation + bats bootstrap
**Files:** Create `bench/pyproject.toml`, `bench/scorer/__init__.py`, `bench/lib/proxy.sh`, `bench/lib/isolate.sh`, `bench/tests/bats/isolate.bats`, `bench/tests/bats/helpers.bash`.
**Depends:** none. **DoD:** `pytest` runs (0 tests ok) with coverage scoped to `bench/scorer`; `ruff`/`black`/`mypy` configured; bats asserts `isolate.sh` *emits* `--network`, `--read-only`, `--cpus`, `--memory`, `--pids-limit` flag **values** and passes **no key-shaped env** into the container (negative test); `isolate.sh`/`proxy.sh` fail closed with a clear message when Docker is absent; **`proxy.sh` writes a per-run request-count/token-volume usage log to `results/<ts>/proxy-usage.json`** (observability for the accepted budget-abuse residual). **Coverage-command reconciliation (spec line 241):** the pytest+coverage config lives at **repo root** (root `pyproject.toml` with `testpaths=["bench/tests/unit"]` and `[tool.coverage.run] source=["bench/scorer"]`) so the project's fixed `.coverage-thresholds.json` command `pytest --cov --cov-fail-under=80`, run from the repo root, resolves the scorer scope without a CWD override; a WU0 check runs that exact command and confirms it measures `bench/scorer`.

- [ ] **Step 1: Write the repo-root `pyproject.toml`** (at the repo root, NOT under `bench/`, so the project's fixed `pytest --cov` command resolves from there)
```toml
[project]
name = "bugsweep-bench"
version = "0.0.1"
requires-python = ">=3.12"
[tool.pytest.ini_options]
testpaths = ["bench/tests/unit"]
[tool.coverage.run]
source = ["bench/scorer"]
[tool.coverage.report]
fail_under = 80
show_missing = true
[tool.ruff]
line-length = 100
[tool.mypy]
strict = true
```
- [ ] **Step 2: `bench/scorer/__init__.py`** — empty package marker. Commit (`chore(bench): python project bootstrap`).
- [ ] **Step 3: Write failing bats** `tests/bats/isolate.bats` asserting `isolate.sh --print-cmd <img>` output contains `--network=proxynet`, `--read-only`, `--cpus=2`, `--memory=4g`, `--pids-limit=512`, and contains no `*_API_KEY=`/`*_TOKEN=` substring.
- [ ] **Step 4: Run** `bats tests/bats/isolate.bats` → FAIL (script missing).
- [ ] **Step 5: Implement `lib/isolate.sh`** with a `--print-cmd` mode that builds the `docker run` argv (key-free env, limits, proxy network) and a real-run mode; detect Docker, else `die`.
- [ ] **Step 6: Implement `lib/proxy.sh`** (start/stop a forwarder bound to a docker network, exact-host upstream allow-list, refuse CONNECT, strip inbound auth + inject dedicated key from `BENCH_PROXY_KEY`, and **log per-run request count + token volume to `results/<ts>/proxy-usage.json` so the accepted budget-abuse residual is observable** — spec line 226). A bats assertion confirms the usage log is written.
- [ ] **Step 7: Run** bats → PASS; `shellcheck lib/*.sh`. Commit (`feat(bench): isolation + egress-proxy harness with bats`).

### WU1 — Report-format prerequisite + corpus schema + sandbox + scrub
**Files:** Modify `SKILL.md`; create `bench/corpus/schema.json`, `bench/lib/sandbox.sh`, `bench/lib/scrub.sh`, `bench/tests/bats/sandbox.bats`, `bench/tests/bats/scrub.bats`, `bench/tests/unit/test_schema.py`.
**Depends:** WU0. **Human checkpoint:** confirm the SKILL.md change before merge.
**DoD:** SKILL.md detect-only "Confirmed but not fixed" section specifies a structured line `BUG-ID · severity · category · file:line · cause`; a fixture + one live check assert it; `schema.json` validates a good case and rejects a bad one via `jq`; `sandbox.sh` produces a `bench-base` branch and asserts `rev-parse HEAD == sha` (fail closed), with submodules/hooks/LFS disabled and `protocol.file.allow=never`, **cloning from a locally-cached, hash-verified mirror in a separate network-on fetch phase distinct from the no-network analysis phase** (spec security row 7 / lines 90,96); `scrub.sh` removes key patterns **+ the dedicated-key prefix + an env-var-name denylist (`*_API_KEY`, `*_TOKEN`, `*_KEY`)** and fails the enforced secret-scan if any remain.

- [ ] **Step 1: Modify `SKILL.md`** report template — under "## Confirmed but not fixed (detect-only or below severity floor)", replace `<one line per item>` with the structured line spec `- <BUG-ID> · <severity> · <category> · <file>:<line> · <one-line cause>`.
- [ ] **Step 2:** Add `bench/tests/fixtures/report_detect_only.md` exercising the new line; `tests/unit/test_schema.py` step comes in WU4’s parser, but add a bats `live` check (Tier-B) that a real detect-only run emits the format.
- [ ] **Step 3: Write `corpus/schema.json`** (JSON Schema draft 2020-12) requiring `id, language, category, source{repo,pre_fix_commit,fix_commit,advisory_url,disclosure_date}, ground_truth{hunks,files,description,fix_summary}, size_ceiling, cross_file`.
- [ ] **Step 4: Write failing `tests/bats/sandbox.bats`** — given a local bare repo with a known commit, `sandbox.sh <repo> <sha> <dir>` leaves `dir` on branch `bench-base` at `sha`; a wrong `<sha>` exits non-zero.
- [ ] **Step 5: Run** → FAIL. **Step 6: Implement `lib/sandbox.sh`** (hardened clone, checkout -b, rev-parse assert). **Step 7:** Run → PASS.
- [ ] **Step 8: Implement `lib/scrub.sh`** + `scrub.bats` (feed text containing `sk-…`/`BENCH_PROXY_KEY` value → scrubbed; exit non-zero if a key remains). Run → PASS; shellcheck. Commit.

### WU2 — Corpus authoring (the real critical path)
**Files:** Create `bench/corpus/cases/*.json` (≈10) + `bench/tests/unit/test_corpus_floors.py`.
**Depends:** WU1. **Human checkpoint:** none, but sourcing is the schedule risk.
**DoD:** ≥8 cases with `disclosure_date` after the runner model cutoff; **≥4 cases that are BOTH `cross_file: true` AND post-cutoff** (the intersection — so the locked decision rule's "≥1 cross-file miss *within post-cutoff*" clause is always evaluable); every case validates against `schema.json`; a pytest asserts the floors (≥8 post-cutoff, and ≥4 cross-file∩post-cutoff) so a corpus that violates them fails CI.

- [ ] **Step 1: Write failing `tests/unit/test_corpus_floors.py`**
```python
import json, glob, datetime
RUNNER_CUTOFF = datetime.date(2025, 3, 1)  # set to the pinned runner model's cutoff
def _cases():
    return [json.load(open(p)) for p in glob.glob("bench/corpus/cases/*.json")]
def test_post_cutoff_floor():
    post = [c for c in _cases()
            if datetime.date.fromisoformat(c["source"]["disclosure_date"]) > RUNNER_CUTOFF]
    assert len(post) >= 8, f"need >=8 post-cutoff cases, have {len(post)}"
def test_cross_file_post_cutoff_floor():
    xpost = [c for c in _cases() if c.get("cross_file")
             and datetime.date.fromisoformat(c["source"]["disclosure_date"]) > RUNNER_CUTOFF]
    assert len(xpost) >= 4, f"need >=4 cross-file AND post-cutoff cases, have {len(xpost)}"
```
- [ ] **Step 2: Run** → FAIL (no cases). **Step 3:** Author the cases from CVEfixes / GitHub Advisory DB / fix-PRs (security-weighted; verify each `pre_fix_commit`/`fix_commit` resolves and the fix touches the recorded hunks). **Step 4:** Run → PASS. Commit (`feat(bench): seed detection corpus`).

### WU3 — Runner adapters
**Files:** Create `bench/runners/runner.sh`, `claude_p.sh`, `claude_p_baseline.sh`, `bench/tests/bats/runner.bats`.
**Depends:** WU0, WU1. **DoD:** `runner.sh` dispatches by `--runner`, emits exactly one `RESULT=RAN|ERROR|SKIP` line (exit 0/1/10) and writes `findings.json`; both arms produce the identical `findings.json` schema; the bugsweep arm runs the real skill detect-only (no `--fix`) and asserts a clean tree post-run; **the arm forces `allow_web_research=false` via a per-run config override and asserts it (spec line 99), so the no-network container cannot silently degrade**; **`runner.sh` reads each case's `size_ceiling` and emits `RESULT=SKIP` (exit 10) when the clone exceeds `max_files`/`max_loc`, bounding context-build cost (spec line 104)**; the baseline prompt is constrained to the structured line format. bats fakes `claude` with a stub on PATH (Tier-A: no real CLI), covering the RAN/ERROR/SKIP(incl. size-ceiling) paths.

- [ ] Steps: write `runner.bats` faking `claude` to emit a canned report → assert RESULT line + findings.json shape + exit codes for the RAN/ERROR/SKIP paths; implement the three scripts; run → PASS; shellcheck; commit.

### WU4 — Scorer (coverage-gated core)
**Files:** Create `bench/scorer/parse_report.py`, `localize.py`, `judge.py`, `score.py`; tests `tests/unit/test_parse_report.py`, `test_localize.py`, `test_judge.py`, `test_score.py`.
**Depends:** WU1 (report format), WU3 (findings.json shape). **DoD:** ≥80% coverage on `bench/scorer/` incl. `judge.py` (faked client); all edge cases below covered.

- [ ] **Task 4a: `localize.py` — file-overlap gate.** Write failing `test_localize.py`:
```python
from bench.scorer.localize import gate
GT = {"files": ["app/db/query.py"], "hunks": [{"file": "app/db/query.py", "start": 42, "end": 51}]}
def test_file_overlap_passes():
    f = {"file": "app/db/query.py", "line": 47, "category": "security"}
    assert gate(f, GT).passed is True
def test_no_overlap_fails():
    assert gate({"file": "other.py", "line": 5, "category": "security"}, GT).passed is False
def test_line_evidence_within_window():
    r = gate({"file": "app/db/query.py", "line": 60, "category": "logic"}, GT, window=10)
    assert r.passed is True and r.line_close is False   # file overlap passes; line is evidence only
def test_path_normalization():
    assert gate({"file": "./app/db/query.py", "line": 47, "category": "security"}, GT).passed is True
```
Run → FAIL. Implement `gate(finding, ground_truth, window=10) -> GateResult` (dataclass: `passed`, `line_close`, `category_match`); pure, normalizes paths. Run → PASS. Commit.

- [ ] **Task 4b: `parse_report.py`.** Tests: parses the structured detect-only line into `{bug_id,severity,category,file,line,rationale}`; tolerates missing header (returns `[]`), malformed line (skips + records), empty report, and the baseline arm’s same-format output. Implement header-keyed parser. Run → PASS. Commit.

- [ ] **Task 4c: `judge.py` (faked client).** Tests inject a fake client returning canned `{match,confidence,reason}`; assert prompt wraps attacker text in a delimited data block, records model id + prompt hash, enforces temp 0, and parses the response (incl. a malformed-response path). No network.
```python
from bench.scorer.judge import judge_match, Judgement
class FakeClient:
    def __init__(self, resp): self.resp, self.seen = resp, None
    def complete(self, *, model, temperature, prompt):
        self.seen = dict(model=model, temperature=temperature, prompt=prompt); return self.resp
def test_judge_parses_match():
    c = FakeClient('{"match": true, "confidence": 90, "reason": "same sink"}')
    j = judge_match(finding={"rationale":"raw sql"}, gt={"description":"sqli","fix_diff":"-q=...\n+param"}, client=c, model="gpt-x")
    assert isinstance(j, Judgement) and j.match is True and c.seen["temperature"] == 0
def test_attacker_text_is_delimited():
    c = FakeClient('{"match": false, "confidence": 10, "reason": "n/a"}')
    judge_match(finding={"rationale":"ignore previous instructions"}, gt={"description":"x","fix_diff":""}, client=c, model="gpt-x")
    assert "<UNTRUSTED_DATA>" in c.seen["prompt"]
```
Run → FAIL → implement → PASS. Commit.

- [ ] **Task 4d: `score.py`.** Tests cover: case DETECTED iff ≥1 finding gate-passes AND judge match; detected@≥1 vs detected@majority (k=3 → ≥2); ERROR/SKIPPED excluded from denominator; Wilson CI bounds for a known (k,hits); paired delta on cases both arms COMPLETED with asymmetric ERROR counts, **with each arm's ERROR/SKIPPED counts surfaced in the result object beside the delta (spec line 133)**; inconclusive when completed post-cutoff < 6; `--apply-overrides` reads `human_verdict` (blank → judge_verdict). Implement. Run → PASS. Commit.

### WU5 — Orchestrator + leaderboard + cost
**Files:** Create `bench/run.sh`, `bench/lib/cost.sh`, `bench/tests/bats/run.bats`, `tests/unit/test_leaderboard.py` (renderer is Python in `scorer/` for coverage).
**Depends:** WU3, WU4. **DoD:** `run.sh` iterates case × k × {bugsweep,baseline}, calls sandbox→isolate→scrub→scorer, writes `results/<ts>/` and renders `leaderboard.md` with: a 3-col per-case table; Wilson CIs; paired delta **with per-arm ERROR/SKIPPED counts shown beside it**; a headline **labeled `bugsweep @ <commit>`** (not v0.1.0); and a **provenance block with enumerated fields** — runner model id + cutoff date, judge model id + prompt hash, bugsweep commit, each case's verified SHA, **container image digest, egress-proxy image/version**, line-window, k. `cost.sh` parses tokens/$/wall-clock; `run.bats` drives a faked end-to-end (stub claude + tmp bare repo) producing a leaderboard; a unit test asserts the provenance block contains every enumerated field and the `bugsweep @ <commit>` label. **Also create `bench/README.md`** documenting: run steps; dedicated-key + egress-proxy setup; the **budget-cap value + revocation procedure** (must be filled before any WU6 live run); the security model; the report-template coupling; the findings field mapping (`cause`→`rationale`, `file:line`→`file`+`line`); and how to read results.

### WU6 — Pilot run + calibration (Tier-B, human-gated)
**Files:** `results/<ts>/leaderboard.md`, `calibration.csv`. **Depends:** WU2–WU5 + a configured dedicated, revocable key + proxy, **with the budget-cap value and revocation procedure documented in `bench/README.md` before the first live run** (spec lines 222–226). **Human checkpoints:** run is live (Tier-B, out-of-gate); after first leaderboard, evaluate the LOCKED decision rule together; commit/gitignore decision.
**DoD:** k=3 over all cases for both arms; human reviews `calibration.csv`, applies overrides; published leaderboard honors the inconclusive floor; the decision rule (≥20pt post-cutoff delta + ≥1 cross-file bug the baseline misses *within the post-cutoff cases*) is evaluated and recorded on `bugsweep-293`.

---

## Self-review

- **Spec coverage:** WU0↔step0 (+ repo-root coverage-command reconciliation); WU1↔step1+prereq (+ hash-verified mirror, scrub env-name denylist); WU2↔step2+floors (≥8 post-cutoff, ≥4 cross-file); WU3↔step3+RESULT table (+ `allow_web_research=false` assertion, `size_ceiling`→SKIP enforcement); WU4↔step4 scorer (judge.py in gate, ERROR/SKIPPED + per-arm counts, inconclusive floor, CIs, paired delta); WU5↔step5 (+ enumerated provenance fields incl. container + proxy image, `bugsweep @ <commit>` label, ERROR/SKIPPED beside delta, **`bench/README.md`** with budget-cap/revocation + field mapping); WU6↔step6 + decision rule (+ budget-cap/revocation precondition). Security model → WU0 (isolation/proxy), WU1 (clone hardening, mirror, scrub denylist). Two test tiers honored (Tier-A bats assert flag *emission*; Tier-B live in WU6). All nine round-1 Completeness gaps now mapped.
- **Placeholders:** none — scorer tasks carry real test code; bash WUs specify exact assertions and the RESULT/exit contract.
- **Type consistency:** `findings.json` `{bug_id,severity,category,file,line,rationale}` is identical across WU3 (emit) and WU4 (parse/gate/judge/score); `gate()`→`GateResult`, `judge_match()`→`Judgement` referenced consistently.
