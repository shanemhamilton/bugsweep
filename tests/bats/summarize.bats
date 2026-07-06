#!/usr/bin/env bats
#
# Tests for scripts/summarize.sh and its wiring into scripts/finalize.sh
# (bugsweep-mu3). summarize.sh reduces <RUN_DIR>/ledger.jsonl + recon.json into
# <RUN_DIR>/run-summary.json — a deterministic, schema-valid contract a headless
# scheduler (nightshift) can branch on. finalize.sh must call it UNCONDITIONALLY,
# on both the real-report path and the stub/partial path, so run-summary.json
# ALWAYS exists after finalize.

FINALIZE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/finalize.sh"
SUMMARIZE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/summarize.sh"
AGGREGATE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/aggregate-summaries.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  git -C "$dir" commit --allow-empty -m "init" -q
}

_make_run_dir() {
  # Minimal run directory with required state.env + ledger.jsonl.
  local repo="$1" run_dir="$2" orig_branch="$3"
  mkdir -p "$run_dir"

  local ts="20991231T000000Z"
  local branch="bugsweep/${ts}"
  git -C "$repo" checkout -b "$branch" -q 2>/dev/null || true

  cat > "${run_dir}/state.env" <<ENV
BUGSWEEP_TS="${ts}"
BUGSWEEP_BRANCH="${branch}"
BUGSWEEP_ORIG_BRANCH="${orig_branch}"
BUGSWEEP_STASH_REF="none"
BUGSWEEP_START_EPOCH="$(date +%s)"
BUGSWEEP_SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"
BUGSWEEP_MODE="detect-only"
ENV

  touch "${run_dir}/ledger.jsonl"
}

_make_recon_json() {
  local run_dir="$1" covered="$2" total="$3"
  local covered_arr="[]"
  if [ "$covered" -gt 0 ]; then
    local items=""
    for i in $(seq 1 "$covered"); do
      items="${items}${items:+,}$i"
    done
    covered_arr="[${items}]"
  fi

  cat > "${run_dir}/recon.json" <<JSON
{
  "files_in_scope": 42,
  "batch_count": ${total},
  "batches": [],
  "architectural_targets": [],
  "covered": ${covered_arr}
}
JSON
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  ORIG_BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD)"
  RUN_DIR="${BATS_TMP}/run-dir"
  cd "$REPO"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

# ---------------------------------------------------------------------------
# scripts/summarize.sh direct tests
# ---------------------------------------------------------------------------

@test "summarize.sh: emits schema-valid run-summary.json for a complete run" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 3 3
  printf '{"event":"fix_committed","file":"a.py","bug_id":"BUG-1","severity":"high","category":"security","line":1,"rationale":"r"}\n' \
    >> "${RUN_DIR}/ledger.jsonl"

  run bash "$SUMMARIZE_SH" "$RUN_DIR" "false" "fix"
  [ "$status" -eq 0 ]

  local summary="${RUN_DIR}/run-summary.json"
  [ -f "$summary" ]
  echo "$output" | grep -q "RUN_SUMMARY=${summary}"

  python3 -c "
import json
d = json.load(open('${summary}'))
assert d['status'] == 'complete', d['status']
assert d['coverage'] == {'covered': 3, 'total': 3}, d['coverage']
assert d['mode'] == 'fix'
assert d['schema_version'] >= 1
"
}

@test "summarize.sh: emits run-summary.json even when report.md is absent (stalled)" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 0 10

  run bash "$SUMMARIZE_SH" "$RUN_DIR" "true" "detect-only"
  [ "$status" -eq 0 ]

  local summary="${RUN_DIR}/run-summary.json"
  [ -f "$summary" ]

  python3 -c "
import json
d = json.load(open('${summary}'))
assert d['status'] == 'stalled', d['status']
assert d['coverage'] == {'covered': 0, 'total': 10}, d['coverage']
"
}

@test "summarize.sh: emits degraded minimal summary when python3 is unavailable" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 2 5

  # Simulate a bare machine: shadow python3 with a PATH that doesn't have it.
  local fakebin="${BATS_TMP}/fakebin"
  mkdir -p "$fakebin"
  for tool in bash git grep sed cat mkdir date tr wc head cut basename dirname mktemp rm cp mv find true false printf test env sh; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "${fakebin}/${tool}"
  done

  PATH="$fakebin" run bash "$SUMMARIZE_SH" "$RUN_DIR" "true" "detect-only"
  [ "$status" -eq 0 ]

  local summary="${RUN_DIR}/run-summary.json"
  [ -f "$summary" ]
  grep -q '"degraded": *true' "$summary" || grep -q '"degraded":true' "$summary"
  grep -q '"findings": *\[\]' "$summary" || grep -q '"findings":\[\]' "$summary"
}

# ---------------------------------------------------------------------------
# finalize.sh wiring: run-summary.json ALWAYS exists after finalize.
# ---------------------------------------------------------------------------

@test "finalize.sh: emits run-summary.json on the stub/partial report path" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 0 10

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local summary="${RUN_DIR}/run-summary.json"
  [ -f "$summary" ]
  echo "$output" | grep -q "RUN_SUMMARY=${summary}"

  python3 -c "
import json
d = json.load(open('${summary}'))
assert d['status'] == 'stalled'
"
}

@test "finalize.sh: emits run-summary.json on the real-report path" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 5 5
  cat > "${RUN_DIR}/report.md" <<'REPORT'
# bugsweep report — 2099
**Branch:** bugsweep/x   **Mode:** fix   **Iterations:** 1

## Summary
- Confirmed bugs: 0

## Confirmed but not fixed (detect-only or below severity floor)
REPORT

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local summary="${RUN_DIR}/run-summary.json"
  [ -f "$summary" ]

  python3 -c "
import json
d = json.load(open('${summary}'))
assert d['status'] == 'complete', d['status']
"
}

@test "finalize.sh: report.md machine-readable block is generated from run-summary.json" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 1 1
  printf '{"event":"fix_committed","file":"a.py","bug_id":"BUG-1","severity":"high","category":"security","line":7,"rationale":"unsanitized input"}\n' \
    >> "${RUN_DIR}/ledger.jsonl"

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local report="${RUN_DIR}/report.md"
  local summary="${RUN_DIR}/run-summary.json"
  [ -f "$report" ]
  grep -q "## Findings (machine-readable)" "$report"

  python3 -c "
import json, re

report = open('${report}').read()
summary = json.load(open('${summary}'))

m = re.search(r'## Findings \(machine-readable\)\n\`\`\`json\n(.*?)\n\`\`\`', report, re.S)
assert m, 'machine-readable fenced JSON block not found in report.md'
block = json.loads(m.group(1))
assert block == summary['findings'], (block, summary['findings'])
"
}

@test "summarize.sh: is idempotent (running twice produces the same status)" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 2 2

  run bash "$SUMMARIZE_SH" "$RUN_DIR" "false" "fix"
  [ "$status" -eq 0 ]
  run bash "$SUMMARIZE_SH" "$RUN_DIR" "false" "fix"
  [ "$status" -eq 0 ]

  local summary="${RUN_DIR}/run-summary.json"
  python3 -c "
import json
d = json.load(open('${summary}'))
assert d['status'] == 'complete'
"
}

# The REAL re-entry path: nightshift schedulers call finalize.sh defensively, so a
# second finalize on the same run_dir (where the first call emitted the stub) must
# NOT reclassify a stalled run as "complete". Stub-ness must be detected from the
# report's CONTENT (the stub's 'WARNING: INCOMPLETE RUN' marker), not from whether
# THIS invocation happened to write the stub.
@test "finalize.sh: retried finalize keeps stalled status (stub detected by content)" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 0 10

  # First finalize: no report.md ever written by a model -> stub emitted.
  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local summary="${RUN_DIR}/run-summary.json"
  [ -f "$summary" ]
  python3 -c "
import json
d = json.load(open('${summary}'))
assert d['status'] == 'stalled', 'first finalize: expected stalled, got %s' % d['status']
"

  # Second finalize on the same run_dir: report.md now exists (the stub from the
  # first call), so a naive this-invocation-wrote-the-stub flag would stay false
  # and misclassify the run as complete.
  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  python3 -c "
import json
d = json.load(open('${summary}'))
assert d['status'] == 'stalled', 'retried finalize: expected stalled, got %s' % d['status']
"

  # And the machine-readable block must not be duplicated by the retry.
  [ "$(grep -c '^## Findings (machine-readable)$' "${RUN_DIR}/report.md")" -eq 1 ]
}

# A REAL model-authored report that merely QUOTES the stub's warning text in prose
# (routine on bugsweep-on-bugsweep runs, where finding writeups cite finalize.sh
# strings) must never be classified as a stub. Stub detection must be
# sentinel-based (.report-is-stub), with any content fallback anchored to the
# stub's exact line form — not a bare substring grep.
@test "finalize.sh: real report quoting the stub marker in prose stays complete" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 5 5
  cat > "${RUN_DIR}/report.md" <<'REPORT'
# bugsweep report — 2099
**Branch:** bugsweep/x   **Mode:** detect-only   **Iterations:** 1

## Summary
- Confirmed bugs: 1 (high 1)
- Coverage: 5/5 batches COMPLETE

## Confirmed but not fixed (detect-only or below severity floor)
- BUG-1 · high · logic · scripts/finalize.sh:75 · stub path prints "WARNING: INCOMPLETE RUN" even when coverage is full

## How to review
git diff main..bugsweep/x
REPORT

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  python3 -c "
import json
d = json.load(open('${RUN_DIR}/run-summary.json'))
assert d['status'] == 'complete', 'expected complete, got %s' % d['status']
"
}

# A REAL report whose script-appended machine block embeds a marker-quoting
# rationale (from the ledger) must stay complete across a RETRIED finalize:
# the retry's stub detection must never match our own appended block (the
# region after the '## Findings (machine-readable)' heading).
@test "finalize.sh: retried finalize stays complete when machine block quotes the marker" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 3 3
  printf '{"event":"fix_committed","file":"scripts/finalize.sh","bug_id":"BUG-2","severity":"medium","category":"logic","line":75,"rationale":"stub emits **WARNING: INCOMPLETE RUN** banner text spuriously"}\n' \
    >> "${RUN_DIR}/ledger.jsonl"
  cat > "${RUN_DIR}/report.md" <<'REPORT'
# bugsweep report — 2099
**Branch:** bugsweep/x   **Mode:** fix   **Iterations:** 1

## Summary
- Confirmed bugs: 1 (medium 1)
- Coverage: 3/3 batches COMPLETE

## Fixed
BUG-2 · medium · logic · scripts/finalize.sh:75 · banner text bug · abc123

## How to review
git diff main..bugsweep/x
REPORT

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  python3 -c "
import json
d = json.load(open('${RUN_DIR}/run-summary.json'))
assert d['status'] == 'complete', 'first finalize: expected complete, got %s' % d['status']
"

  # Setup validity check: finalize #1's appended machine block really does embed
  # the marker text (via the ledger rationale) into report.md.
  grep -q 'WARNING: INCOMPLETE RUN' "${RUN_DIR}/report.md"

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  python3 -c "
import json
d = json.load(open('${RUN_DIR}/run-summary.json'))
assert d['status'] == 'complete', 'retried finalize: expected complete, got %s' % d['status']
"
}

# Pre-sentinel compatibility: a run dir whose stub was written by an OLDER
# finalize (no .report-is-stub sentinel) must still be classified via the
# anchored content fallback — the stub's exact '**WARNING: INCOMPLETE RUN**'
# line form at line start, before any machine-readable heading.
@test "finalize.sh: pre-sentinel stub report (no sentinel file) still classifies stalled" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 0 10
  cat > "${RUN_DIR}/report.md" <<'REPORT'
# bugsweep report — 2099-01-01T00:00:00Z
**Branch:** bugsweep/20991231T000000Z   **Mode:** detect-only (partial)
**WARNING: INCOMPLETE RUN** — the model did not produce a full report. The run likely
stalled during context-build or the architectural hunt before reaching the report step.

## Summary
- Coverage: 0/10 batches — PARTIAL RUN (stalled before report)
- Fixes committed: 0
- See ledger.jsonl for the full event log

## How to review
git diff main..bugsweep/20991231T000000Z
REPORT
  [ ! -f "${RUN_DIR}/.report-is-stub" ]  # setup: no sentinel, as an old finalize left it

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  python3 -c "
import json
d = json.load(open('${RUN_DIR}/run-summary.json'))
assert d['status'] == 'stalled', 'expected stalled via anchored fallback, got %s' % d['status']
"
}

# Degraded-path JSON must stay parseable for ANY mode string: `tr '"' "'"` alone
# does not escape backslashes or control chars, so MODE='back\slash"quote' used to
# produce invalid JSON (Invalid \escape) on the no-python3 path.
@test "summarize.sh: degraded summary escapes backslash and quote in mode" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  _make_recon_json "$RUN_DIR" 2 5

  # Simulate a bare machine: shadow python3 with a PATH that doesn't have it
  # (same mechanism as the existing degraded-path test).
  local fakebin="${BATS_TMP}/fakebin"
  mkdir -p "$fakebin"
  for tool in bash git grep sed cat mkdir date tr wc head cut basename dirname mktemp rm cp mv find true false printf test env sh; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "${fakebin}/${tool}"
  done

  PATH="$fakebin" run bash "$SUMMARIZE_SH" "$RUN_DIR" "true" 'back\slash"quote'
  [ "$status" -eq 0 ]

  local summary="${RUN_DIR}/run-summary.json"
  [ -f "$summary" ]

  # python3 is available in the TEST environment (the fake PATH only applied to
  # the summarize.sh invocation above) — the output must parse as valid JSON and
  # round-trip the mode string exactly.
  python3 - "$summary" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["degraded"] is True, d
expected = 'back\\slash"quote'  # one literal backslash, one literal double-quote
assert d["mode"] == expected, (d["mode"], expected)
assert d["status"] == "partial", d["status"]
PY
}

# ---------------------------------------------------------------------------
# bugsweep-xdw: root_cause_clusters / follow_up / flaky end-to-end via
# finalize.sh on a fixture run dir with a recon.json that has an uncovered
# batch, a prior-coverage.json with a stale file + high-risk file, and a
# ledger with two same-category fixes (a cluster) plus a quarantine and a
# flaky_test event.
# ---------------------------------------------------------------------------

@test "finalize.sh: run-summary.json contains root_cause_clusters/follow_up/flaky (bugsweep-xdw)" {
  _make_run_dir "$REPO" "$RUN_DIR" "$ORIG_BRANCH"
  cat > "${RUN_DIR}/recon.json" <<'JSON'
{
  "files_in_scope": 10,
  "batch_count": 2,
  "batches": [
    {"id": 1, "tier": "critical", "files": ["a.py"]},
    {"id": 2, "tier": "high", "files": ["b.py"]}
  ],
  "architectural_targets": [],
  "covered": [1]
}
JSON
  cat > "${RUN_DIR}/prior-coverage.json" <<'JSON'
{
  "schema": 1,
  "catalog_version": "1",
  "prior_runs": 2,
  "files_audited_current_catalog": [],
  "files_audited_current_catalog_count": 0,
  "files_audited_stale_catalog": ["stale.py"],
  "files_audited_stale_catalog_count": 1,
  "high_risk_files": [{"file": "risky.py", "score": 3.5}]
}
JSON
  {
    printf '{"event":"fix_committed","file":"a.py","bug_id":"BUG-1","severity":"high","category":"sql-injection","line":1,"rationale":"r1"}\n'
    printf '{"event":"fix_committed","file":"b.py","bug_id":"BUG-2","severity":"high","category":"sql-injection","line":2,"rationale":"r2"}\n'
    printf '{"event":"quarantine","file":"legacy.py","bug_id":"BUG-3","severity":"medium","category":"logic","line":3,"rationale":"r3"}\n'
    printf '{"event":"flaky_test","test":"test_flaky_thing","file":"tests/test_x.py","reruns":3,"failures":1}\n'
  } >> "${RUN_DIR}/ledger.jsonl"

  run bash "$FINALIZE_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local summary="${RUN_DIR}/run-summary.json"
  [ -f "$summary" ]

  python3 -c "
import json
d = json.load(open('${summary}'))

clusters = d['root_cause_clusters']
assert len(clusters) == 1, clusters
assert clusters[0]['cluster'] == 'sql-injection', clusters[0]
assert clusters[0]['size'] == 2, clusters[0]
assert sorted(clusters[0]['files']) == ['a.py', 'b.py'], clusters[0]

follow_up = d['follow_up']
kinds = {(f['kind'], f['ref']) for f in follow_up}
assert ('uncovered_batch', '2') in kinds, follow_up
assert ('high_risk_file', 'risky.py') in kinds, follow_up
assert ('stale_file', 'stale.py') in kinds, follow_up
assert ('quarantined', 'BUG-3') in kinds, follow_up

flaky = d['flaky']
assert flaky == [{'test': 'test_flaky_thing', 'file': 'tests/test_x.py', 'reruns': 3, 'failures': 1}], flaky
"
}

# ---------------------------------------------------------------------------
# bugsweep-xdw: scripts/aggregate-summaries.sh — session aggregate. The
# zero-run case must be distinguishable from a clean all-complete session
# (adversarial review BLOCKER 1), and a real cross-run singleton must fold into
# a session cluster (BLOCKER 2).
# ---------------------------------------------------------------------------

@test "aggregate-summaries.sh: zero-run aggregate is not a clean success (bugsweep-xdw)" {
  run bash "$AGGREGATE_SH" "${BATS_TMP}/session.json"
  [ "$status" -eq 0 ]

  local out="${BATS_TMP}/session.json"
  [ -f "$out" ]
  echo "$output" | grep -q "SESSION_SUMMARY=${out}"

  python3 -c "
import json
d = json.load(open('${out}'))
assert d['run_count'] == 0, d['run_count']
assert d['worst_status'] == 'no_runs', d['worst_status']
assert d['worst_status'] != 'complete'
"
}

@test "aggregate-summaries.sh: folds cross-run singleton findings into a session cluster (bugsweep-xdw)" {
  local a="${BATS_TMP}/a.json" b="${BATS_TMP}/b.json" out="${BATS_TMP}/session.json"
  cat > "$a" <<'JSON'
{"schema_version":1,"mode":"fix","status":"complete","stop_reason":null,"coverage":{"covered":1,"total":1},"counts":{"critical":0,"high":1,"medium":0,"low":0,"architectural":0},"fixed":["X1"],"quarantined":[],"confirmed_unfixed":[],"findings":[{"bug_id":"X1","severity":"high","category":"xss","file":"a.py","line":1,"fixed":true,"rationale":"r"}],"root_cause_clusters":[],"follow_up":[],"flaky":[]}
JSON
  cat > "$b" <<'JSON'
{"schema_version":1,"mode":"fix","status":"stalled","stop_reason":"x","coverage":{"covered":0,"total":5},"counts":{"critical":0,"high":1,"medium":0,"low":0,"architectural":0},"fixed":["X2"],"quarantined":[],"confirmed_unfixed":[],"findings":[{"bug_id":"X2","severity":"high","category":"xss","file":"b.py","line":1,"fixed":true,"rationale":"r"}],"root_cause_clusters":[],"follow_up":[],"flaky":[]}
JSON

  run bash "$AGGREGATE_SH" "$out" "$a" "$b"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  python3 -c "
import json
d = json.load(open('${out}'))
assert d['run_count'] == 2, d['run_count']
assert d['worst_status'] == 'partial', d['worst_status']  # complete + stalled -> partial
clusters = d['root_cause_clusters']
assert len(clusters) == 1, clusters
assert clusters[0]['cluster'] == 'xss', clusters[0]
assert clusters[0]['size'] == 2, clusters[0]
assert sorted(clusters[0]['files']) == ['a.py', 'b.py'], clusters[0]
"
}
