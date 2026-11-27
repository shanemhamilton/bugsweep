#!/usr/bin/env bats
# Regression tests for scripts/session.sh checkpoint handling (trippro-k09sa).

SESSION_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/session.sh"

setup() {
  TMP="$(mktemp -d)"
  REPO="${TMP}/repo"
  RUN_DIR="${REPO}/.bugsweep/run-test"
  mkdir -p "$RUN_DIR"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@bugsweep"
  git -C "$REPO" config user.name "bugsweep-test"
  git -C "$REPO" checkout -q -b main
  git -C "$REPO" commit --allow-empty -m "init" -q

  cat > "${RUN_DIR}/state.env" <<EOF
BUGSWEEP_RUN_DIR=${RUN_DIR}
BUGSWEEP_REPO_ROOT=${REPO}
BUGSWEEP_TARGET_ROOT=${REPO}
BUGSWEEP_BRANCH=bugsweep/session-test
BUGSWEEP_ORIG_BRANCH=main
EOF
  : > "${RUN_DIR}/ledger.jsonl"
}

teardown() {
  chmod -R u+rwx "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}

@test "session.sh checkpoint succeeds with confirmed=0 on empty ledger and writes SESSION.md" {
  run bash "$SESSION_SH" checkpoint "$RUN_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK iters=0 fixes=0"* ]]
  [ -f "${RUN_DIR}/SESSION.md" ]
  grep -qF "confirmed total 0" "${RUN_DIR}/SESSION.md"
  grep -qF '"event":"checkpoint"' "${RUN_DIR}/ledger.jsonl"
}

@test "session.sh checkpoint succeeds with confirmed=0 when ledger has only non-confirmed events" {
  cat > "${RUN_DIR}/ledger.jsonl" <<'EOF'
{"event":"preflight","scope":"src"}
{"event":"iteration","batch":"batch-001"}
{"event":"batch_covered","batch_id":"batch-001"}
{"event":"fix_committed","bug_id":"BUG-1"}
EOF

  run bash "$SESSION_SH" checkpoint "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/SESSION.md" ]
  grep -qF "iteration 1" "${RUN_DIR}/SESSION.md"
  grep -qF "fixes committed 1" "${RUN_DIR}/SESSION.md"
  grep -qF "confirmed total 0" "${RUN_DIR}/SESSION.md"
}

@test "session.sh checkpoint sums numeric confirmed counts across ledger entries" {
  cat > "${RUN_DIR}/ledger.jsonl" <<'EOF'
{"event":"iteration","confirmed":2}
{"event":"batch_covered","batch_id":"batch-001"}
{"event":"iteration","confirmed":3}
EOF

  run bash "$SESSION_SH" checkpoint "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/SESSION.md" ]
  grep -qF "confirmed total 5" "${RUN_DIR}/SESSION.md"
}

@test "session.sh checkpoint fails closed on malformed JSON line without writing SESSION.md" {
  cat > "${RUN_DIR}/ledger.jsonl" <<'EOF'
{"event":"preflight"}
{not valid json
EOF

  run bash "$SESSION_SH" checkpoint "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/SESSION.md" ]
}

@test "session.sh checkpoint fails closed on non-object JSON line without writing SESSION.md" {
  printf '["not","an","object"]\n' > "${RUN_DIR}/ledger.jsonl"

  run bash "$SESSION_SH" checkpoint "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/SESSION.md" ]
}

@test "session.sh checkpoint fails closed on missing, symlinked, or unreadable ledger" {
  rm -f "${RUN_DIR}/ledger.jsonl"
  run bash "$SESSION_SH" checkpoint "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/SESSION.md" ]

  printf '{"event":"preflight"}\n' > "${TMP}/real-ledger.jsonl"
  ln -s "${TMP}/real-ledger.jsonl" "${RUN_DIR}/ledger.jsonl"
  run bash "$SESSION_SH" checkpoint "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/SESSION.md" ]

  rm -f "${RUN_DIR}/ledger.jsonl"
  printf '{"event":"preflight"}\n' > "${RUN_DIR}/ledger.jsonl"
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "${RUN_DIR}/ledger.jsonl"
    run bash "$SESSION_SH" checkpoint "$RUN_DIR"
    [ "$status" -ne 0 ]
    [ ! -e "${RUN_DIR}/SESSION.md" ]
  fi
}

@test "session.sh checkpoint jq fallback sums confirmed ints and rejects floats/negatives/malformed JSON" {
  local jq_bin
  jq_bin="$(command -v jq)"
  local fakebin="${TMP}/jq-only-bin"
  mkdir -p "$fakebin"
  ln -s "$jq_bin" "${fakebin}/jq"
  for cmd in awk bash cat date dirname grep mkdir mv printf rm sed tr wc; do
    if command -v "$cmd" >/dev/null 2>&1; then
      ln -s "$(command -v "$cmd")" "${fakebin}/${cmd}"
    fi
  done

  cat > "${RUN_DIR}/ledger.jsonl" <<'EOF'
{"event":"preflight"}
{"event":"batch_covered","batch_id":"batch-001"}
{"event":"iteration","confirmed": 2}
EOF

  PATH="$fakebin" BUGSWEEP_NO_PYTHON=1 run bash "$SESSION_SH" checkpoint "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ -f "${RUN_DIR}/SESSION.md" ]
  grep -qF "confirmed total 2" "${RUN_DIR}/SESSION.md"

  for bad in \
    '{"event":"iteration","confirmed": 1.0}' \
    '{"event":"iteration","confirmed": 1e2}' \
    '{"event":"iteration","confirmed": -1}' \
    '{"event":"iteration","confirmed": "bad"}' \
    '{not valid json'
  do
    rm -f "${RUN_DIR}/SESSION.md"
    printf '%s\n' "$bad" > "${RUN_DIR}/ledger.jsonl"
    PATH="$fakebin" BUGSWEEP_NO_PYTHON=1 run bash "$SESSION_SH" checkpoint "$RUN_DIR"
    [ "$status" -ne 0 ]
    [ ! -e "${RUN_DIR}/SESSION.md" ]
  done
}

@test "session.sh checkpoint fails closed when neither python3 nor jq is available" {
  local fakebin="${TMP}/no-python-no-jq"
  mkdir -p "$fakebin"
  for cmd in awk bash cat date dirname grep mkdir mv printf rm sed tr wc; do
    if command -v "$cmd" >/dev/null 2>&1; then
      ln -s "$(command -v "$cmd")" "${fakebin}/${cmd}"
    fi
  done

  printf '{"event":"preflight"}\n' > "${RUN_DIR}/ledger.jsonl"
  PATH="$fakebin" BUGSWEEP_NO_PYTHON=1 run bash "$SESSION_SH" checkpoint "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "${RUN_DIR}/SESSION.md" ]
}
