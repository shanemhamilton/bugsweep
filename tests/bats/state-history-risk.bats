#!/usr/bin/env bats
#
# Tests for the git-history-risk signal (bugsweep-t6e): per-file version-control
# risk features (commit frequency, recency, fix-commit density) computed by
# scripts/git-history-risk.sh and folded, with a BOUNDED weight, into
# scripts/state.sh's `prime` risk score -- so files with a history of churn or
# fix commits sort earlier in the coverage frontier, without ever letting
# history alone override a file's existing (sink/finding-derived) risk score.

STATE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/state.sh"
GIT_HISTORY_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/git-history-risk.sh"

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  git -C "$dir" commit --allow-empty -m "init" -q
}

# _commit_file <repo> <file> <message>: append a unique line (so every commit
# is a real content change) and commit exactly that file with <message>.
_commit_file() {
  local dir="$1" file="$2" msg="$3"
  echo "change ${RANDOM}-${BATS_TEST_NUMBER:-0}-$$" >> "${dir}/${file}"
  git -C "$dir" add "$file"
  git -C "$dir" commit -q -m "$msg"
}

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  cd "$REPO"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

# _score_of <prior-coverage.json> <file>: prints the file's high_risk_files
# score, or nothing if the file is not present in the ranked list.
_score_of() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for e in d.get("high_risk_files", []):
    if e.get("file") == sys.argv[2]:
        print(e["score"]); break
' "$1" "$2" 2>/dev/null
}

# _pos_of <prior-coverage.json> <file>: prints the 0-based index of <file> in
# high_risk_files (ordering, not just score), or -1 if absent.
_pos_of() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
files = [e.get("file") for e in d.get("high_risk_files", [])]
try:
    print(files.index(sys.argv[2]))
except ValueError:
    print(-1)
' "$1" "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# scripts/git-history-risk.sh -- the standalone feature helper
# ---------------------------------------------------------------------------

@test "git-history-risk.sh: exists and runs against a plain git repo" {
  [ -f "$GIT_HISTORY_SH" ]
  run bash "$GIT_HISTORY_SH" "$REPO" 50
  [ "$status" -eq 0 ]
}

@test "git-history-risk.sh: reports a fix-commit for a file touched by a fix: commit" {
  mkdir -p "${REPO}/src"
  printf 'a\n' > "${REPO}/src/fileA.py"
  git add src/fileA.py
  git commit -q -m "add fileA"
  _commit_file "$REPO" "src/fileA.py" "fix: correct off-by-one"

  run bash "$GIT_HISTORY_SH" "$REPO" 50
  [ "$status" -eq 0 ]
  local rec
  rec="$(printf '%s\n' "$output" | grep '"file": *"src/fileA.py"' || true)"
  [ -n "$rec" ]
  python3 -c '
import json, sys
e = json.loads(sys.argv[1])
assert e["fix_commits"] >= 1, e
assert 0.0 < e["history_score"] <= 1.0, e
' "$rec"
}

@test "git-history-risk.sh: clamps fix-commit and commit-frequency counts (pathological history guard)" {
  mkdir -p "${REPO}/src"
  printf 'x\n' > "${REPO}/src/many.py"
  git add src/many.py
  git commit -q -m "add file"

  local i
  for i in $(seq 1 30); do
    _commit_file "$REPO" "src/many.py" "fix: issue ${i}"
  done

  run bash "$GIT_HISTORY_SH" "$REPO" 100
  [ "$status" -eq 0 ]
  local rec
  rec="$(printf '%s\n' "$output" | grep '"file": *"src/many.py"' || true)"
  [ -n "$rec" ]
  python3 -c '
import json, sys
e = json.loads(sys.argv[1])
assert e["fix_commits"] <= 10, e
assert e["commits"] <= 20, e
assert 0.0 <= e["history_score"] <= 1.0, e
' "$rec"
}

@test "git-history-risk.sh: depth cap excludes commits older than the capped window" {
  mkdir -p "${REPO}/src"
  printf 'old\n' > "${REPO}/src/old.py"
  git add src/old.py
  git commit -q -m "fix: ancient bug in old.py"

  local i
  for i in $(seq 1 5); do
    printf 'noise %s\n' "$i" > "${REPO}/src/noise.py"
    git -C "$REPO" add src/noise.py
    git -C "$REPO" commit -q -m "noise ${i}"
  done

  run bash "$GIT_HISTORY_SH" "$REPO" 3
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q '"file": *"src/old.py"'
}

@test "git-history-risk.sh: same repo state -> byte-identical output across two invocations" {
  mkdir -p "${REPO}/src"
  printf 'a\n' > "${REPO}/src/fileA.py"
  git add src/fileA.py
  git commit -q -m "add fileA"
  _commit_file "$REPO" "src/fileA.py" "fix: bug"

  run bash "$GIT_HISTORY_SH" "$REPO" 50
  local out1="$output"
  run bash "$GIT_HISTORY_SH" "$REPO" 50
  local out2="$output"
  [ "$out1" = "$out2" ]
}

# ---------------------------------------------------------------------------
# scripts/state.sh prime -- the bounded fold into the risk score
# ---------------------------------------------------------------------------

@test "prime: file with fix-commit history ranks above an otherwise risk-score-equal file" {
  mkdir -p "${REPO}/src"
  printf 'a\n' > "${REPO}/src/fileA.py"
  printf 'b\n' > "${REPO}/src/fileB.py"
  git add src/fileA.py src/fileB.py
  git commit -q -m "add fileA and fileB"
  _commit_file "$REPO" "src/fileA.py" "fix: correct off-by-one in fileA"

  # Identical existing risk_log signal for both files (same event, weight, run) --
  # the ONLY difference is fileA's fix-commit history. Before this feature, these
  # two files' scores were equal/undefined relative to each other.
  mkdir -p "${REPO}/.bugsweep/state"
  cat > "${REPO}/.bugsweep/state/risk.jsonl" <<JSON
{"run":1,"run_id":"r1","ts":"2026-01-01T00:00:00Z","file":"src/fileA.py","event":"confirmed","severity":"medium"}
{"run":1,"run_id":"r1","ts":"2026-01-01T00:00:00Z","file":"src/fileB.py","event":"confirmed","severity":"medium"}
JSON

  local run_dir="${BATS_TMP}/run-1"
  mkdir -p "$run_dir"
  run bash "$STATE_SH" prime "$run_dir"
  [ "$status" -eq 0 ]
  [ -f "${run_dir}/prior-coverage.json" ]

  local score_a score_b
  score_a="$(_score_of "${run_dir}/prior-coverage.json" "src/fileA.py")"
  score_b="$(_score_of "${run_dir}/prior-coverage.json" "src/fileB.py")"
  [ -n "$score_a" ]
  [ -n "$score_b" ]
  python3 -c "import sys; a=float(sys.argv[1]); b=float(sys.argv[2]); sys.exit(0 if a > b else 1)" "$score_a" "$score_b"

  local pos_a pos_b
  pos_a="$(_pos_of "${run_dir}/prior-coverage.json" "src/fileA.py")"
  pos_b="$(_pos_of "${run_dir}/prior-coverage.json" "src/fileB.py")"
  [ "$pos_a" -ge 0 ]
  [ "$pos_b" -ge 0 ]
  [ "$pos_a" -lt "$pos_b" ]
}

@test "prime: a file with zero existing signal gains a ranked score purely from fix-commit history" {
  mkdir -p "${REPO}/src"
  printf 'a\n' > "${REPO}/src/onlyHistory.py"
  git add src/onlyHistory.py
  git commit -q -m "add onlyHistory"
  _commit_file "$REPO" "src/onlyHistory.py" "fix: repair parsing bug"

  # No risk.jsonl at all -- this file has never been flagged by a real hunt.
  local run_dir="${BATS_TMP}/run-1"
  mkdir -p "$run_dir"
  run bash "$STATE_SH" prime "$run_dir"
  [ "$status" -eq 0 ]

  local score
  score="$(_score_of "${run_dir}/prior-coverage.json" "src/onlyHistory.py")"
  [ -n "$score" ]
  python3 -c "import sys; assert float(sys.argv[1]) > 0.0" "$score"
}

@test "prime: bounded history weight -- higher existing risk score still outranks a low-risk/high-churn file" {
  mkdir -p "${REPO}/src"
  printf 'h\n' > "${REPO}/src/highRisk.py"
  printf 'c\n' > "${REPO}/src/churny.py"
  git add src/highRisk.py src/churny.py
  git commit -q -m "add highRisk and churny"

  # Max out churny.py's git-history signal: >= FIX_CAP fix-commits, all recent,
  # so its history contribution saturates at the theoretical ceiling.
  local i
  for i in $(seq 1 12); do
    _commit_file "$REPO" "src/churny.py" "fix: churn ${i}"
  done

  mkdir -p "${REPO}/.bugsweep/state"
  # highRisk.py: one quarantine event (weight 2). churny.py: one confirmed
  # event (weight 1) -- a full one-tier gap below highRisk.py's existing score
  # that the bounded history contribution must never close.
  cat > "${REPO}/.bugsweep/state/risk.jsonl" <<JSON
{"run":1,"run_id":"r1","ts":"2026-01-01T00:00:00Z","file":"src/highRisk.py","event":"quarantine","severity":"high"}
{"run":1,"run_id":"r1","ts":"2026-01-01T00:00:00Z","file":"src/churny.py","event":"confirmed","severity":"low"}
JSON

  local run_dir="${BATS_TMP}/run-1"
  mkdir -p "$run_dir"
  run bash "$STATE_SH" prime "$run_dir"
  [ "$status" -eq 0 ]

  local score_high score_churn
  score_high="$(_score_of "${run_dir}/prior-coverage.json" "src/highRisk.py")"
  score_churn="$(_score_of "${run_dir}/prior-coverage.json" "src/churny.py")"
  [ -n "$score_high" ]
  [ -n "$score_churn" ]
  python3 -c "import sys; h=float(sys.argv[1]); c=float(sys.argv[2]); sys.exit(0 if h > c else 1)" "$score_high" "$score_churn"

  local pos_high pos_churn
  pos_high="$(_pos_of "${run_dir}/prior-coverage.json" "src/highRisk.py")"
  pos_churn="$(_pos_of "${run_dir}/prior-coverage.json" "src/churny.py")"
  [ "$pos_high" -ge 0 ]
  [ "$pos_churn" -ge 0 ]
  [ "$pos_high" -lt "$pos_churn" ]

  # The cap itself: churny's boost above its own existing base (1.0) must never
  # exceed the documented bound, proving history cannot fully override signal.
  python3 -c "import sys; c=float(sys.argv[1]); sys.exit(0 if c <= 1.5 + 1e-6 else 1)" "$score_churn"
}

@test "prime: identical repo state -> byte-identical prior-coverage.json across two runs (determinism)" {
  mkdir -p "${REPO}/src"
  printf 'a\n' > "${REPO}/src/fileA.py"
  printf 'b\n' > "${REPO}/src/fileB.py"
  git add src/fileA.py src/fileB.py
  git commit -q -m "add files"
  _commit_file "$REPO" "src/fileA.py" "fix: bug in fileA"
  _commit_file "$REPO" "src/fileB.py" "fix: bug in fileB"

  mkdir -p "${REPO}/.bugsweep/state"
  cat > "${REPO}/.bugsweep/state/risk.jsonl" <<JSON
{"run":1,"run_id":"r1","ts":"2026-01-01T00:00:00Z","file":"src/fileA.py","event":"confirmed","severity":"medium"}
{"run":1,"run_id":"r1","ts":"2026-01-01T00:00:00Z","file":"src/fileB.py","event":"confirmed","severity":"medium"}
JSON

  local run_dir_1="${BATS_TMP}/run-1"
  local run_dir_2="${BATS_TMP}/run-2"
  mkdir -p "$run_dir_1" "$run_dir_2"
  run bash "$STATE_SH" prime "$run_dir_1"
  [ "$status" -eq 0 ]
  run bash "$STATE_SH" prime "$run_dir_2"
  [ "$status" -eq 0 ]

  diff "${run_dir_1}/prior-coverage.json" "${run_dir_2}/prior-coverage.json"
}

@test "prime: still succeeds with no git-history signal available (non-fatal degrade)" {
  local run_dir="${BATS_TMP}/run-1"
  mkdir -p "$run_dir"
  run bash "$STATE_SH" prime "$run_dir"
  [ "$status" -eq 0 ]
  [ -f "${run_dir}/prior-coverage.json" ]
}
