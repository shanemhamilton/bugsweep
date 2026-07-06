#!/usr/bin/env bats
#
# Tests for scripts/analyzers.sh (bugsweep-042) — the optional pre-hunt step that
# runs off-the-shelf static analyzers (semgrep, gosec, bandit, ...) to seed the
# Hunter with candidate locations and give the Referee an independent
# corroboration signal. Config-gated (.analyzers.enabled, default false — a
# reproducibility default, see analyzers.sh header) and always best-effort:
# an absent tool is a clean skip, never a failure.

ANALYZERS_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/analyzers.sh"
BUGSWEEP_ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  printf 'print("hi")\n' > "${dir}/app.py"
  git -C "$dir" add app.py
  git -C "$dir" commit -m "init" -q
}

# A minimal PATH containing only the core POSIX tools bash/git/analyzers.sh need,
# so "no analyzers installed" can be simulated deterministically regardless of
# what's on the host machine's real PATH (mirrors summarize.bats's fakebin pattern).
_make_bare_fakebin() {
  local fakebin="$1"
  mkdir -p "$fakebin"
  for tool in bash git grep sed cat mkdir date tr wc head cut basename dirname \
              mktemp rm cp mv find true false printf test env sh awk sleep kill python3 jq; do
    local real; real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "${fakebin}/${tool}"
  done
}

# A fakebin that deliberately EXCLUDES timeout(1)/gtimeout so analyzers.sh is
# forced onto its manual-watchdog fallback path (the path stock macOS bash 3.2
# actually takes — neither binary ships by default). This is where the
# orphaned-watchdog-sleep FD leak lives, so the no-orphan test must exercise it.
_make_fakebin_no_timeout() {
  local fakebin="$1"
  _make_bare_fakebin "$fakebin"
  # _make_bare_fakebin already omits timeout/gtimeout; assert that invariant so
  # a future edit to the shared helper can't silently route this test away from
  # the fallback path it is meant to guard.
  [ ! -e "${fakebin}/timeout" ] && [ ! -e "${fakebin}/gtimeout" ]
}

# Writes a fake `semgrep` executable to $1/semgrep that emits a fixed, known
# semgrep --json payload (one hit in app.py) regardless of its arguments, and
# accepts --validate as a no-op success (some tests invoke analyzers.sh, not
# variants.sh, so we don't need real semgrep validation semantics here).
_stub_semgrep_with_hit() {
  local bindir="$1"
  cat > "${bindir}/semgrep" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "--json" ]; then
    cat <<'JSON'
{
  "results": [
    {
      "check_id": "python.lang.security.audit.dangerous-eval-use",
      "path": "app.py",
      "start": {"line": 1},
      "end": {"line": 1},
      "extra": {"message": "Detected a stubbed known hit.", "severity": "ERROR"}
    }
  ]
}
JSON
    exit 0
  fi
done
exit 0
STUB
  chmod +x "${bindir}/semgrep"
}

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  REPO="${BATS_TMP}/repo"
  _make_git_repo "$REPO"
  RUN_DIR="${BATS_TMP}/run-dir"
  mkdir -p "$RUN_DIR"
  cd "$REPO"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

# ---------------------------------------------------------------------------
# Disabled by default (reproducibility default) — byte-for-byte no-op
# ---------------------------------------------------------------------------

@test "analyzers.sh: disabled by default (no config) exits 0 and writes no hits file" {
  run bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "${RUN_DIR}/analyzer-hits.json" ]
}

@test "analyzers.sh: .analyzers.enabled=false in config exits 0 and writes no hits file" {
  mkdir -p "${REPO}/config"
  cat > "${REPO}/config/bugsweep.config.json" <<'JSON'
{"analyzers": {"enabled": false}}
JSON
  _ANALYZERS_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" run bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "${RUN_DIR}/analyzer-hits.json" ]
  echo "$output" | grep -qi "skip"
}

@test "analyzers.sh: enabled=true but no analyzers on PATH exits 0, writes no hits file, logs SKIPPED" {
  mkdir -p "${REPO}/config"
  cat > "${REPO}/config/bugsweep.config.json" <<'JSON'
{"analyzers": {"enabled": true}}
JSON
  local fakebin="${BATS_TMP}/fakebin-none"
  _make_bare_fakebin "$fakebin"

  _ANALYZERS_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" PATH="$fakebin" \
    run bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "${RUN_DIR}/analyzer-hits.json" ]
  echo "$output" | grep -qi "SKIPPED"
}

# ---------------------------------------------------------------------------
# Enabled + a stubbed analyzer present -> writes hits + ledger event
# ---------------------------------------------------------------------------

@test "analyzers.sh: enabled with a stubbed semgrep on PATH writes analyzer-hits.json containing the known hit" {
  mkdir -p "${REPO}/config"
  cat > "${REPO}/config/bugsweep.config.json" <<'JSON'
{"analyzers": {"enabled": true}}
JSON
  local fakebin="${BATS_TMP}/fakebin-semgrep"
  _make_bare_fakebin "$fakebin"
  _stub_semgrep_with_hit "$fakebin"

  _ANALYZERS_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" PATH="$fakebin" \
    run bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local hits="${RUN_DIR}/analyzer-hits.json"
  [ -f "$hits" ]
  grep -q "dangerous-eval-use" "$hits"
  grep -q '"tool": *"semgrep"' "$hits" || grep -q '"tool":"semgrep"' "$hits"
  grep -q "app.py" "$hits"
}

@test "analyzers.sh: appends an 'analyzers' ledger event with tools + hit count" {
  mkdir -p "${REPO}/config"
  cat > "${REPO}/config/bugsweep.config.json" <<'JSON'
{"analyzers": {"enabled": true}}
JSON
  local fakebin="${BATS_TMP}/fakebin-ledger"
  _make_bare_fakebin "$fakebin"
  _stub_semgrep_with_hit "$fakebin"

  _ANALYZERS_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" PATH="$fakebin" \
    run bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  local ledger="${RUN_DIR}/ledger.jsonl"
  [ -f "$ledger" ]
  grep -q '"event":"analyzers"' "$ledger" || grep -q '"event": *"analyzers"' "$ledger"
  grep -q '"semgrep"' "$ledger"
  grep -q '"hits":1' "$ledger" || grep -q '"hits": *1' "$ledger"
}

@test "analyzers.sh: absent tools (gosec, bandit) are skipped cleanly alongside a present one" {
  mkdir -p "${REPO}/config"
  cat > "${REPO}/config/bugsweep.config.json" <<'JSON'
{"analyzers": {"enabled": true}}
JSON
  local fakebin="${BATS_TMP}/fakebin-mixed"
  _make_bare_fakebin "$fakebin"
  _stub_semgrep_with_hit "$fakebin"
  # Deliberately do NOT add gosec/bandit stubs.

  _ANALYZERS_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" PATH="$fakebin" \
    run bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "gosec.*SKIPPED\|SKIPPED.*gosec"
  echo "$output" | grep -qi "bandit.*SKIPPED\|SKIPPED.*bandit"
}

# ---------------------------------------------------------------------------
# Never fails the run — a misbehaving analyzer degrades, doesn't abort
# ---------------------------------------------------------------------------

@test "analyzers.sh: a non-zero-exit analyzer never fails the overall run" {
  mkdir -p "${REPO}/config"
  cat > "${REPO}/config/bugsweep.config.json" <<'JSON'
{"analyzers": {"enabled": true}}
JSON
  local fakebin="${BATS_TMP}/fakebin-fail"
  _make_bare_fakebin "$fakebin"
  cat > "${fakebin}/semgrep" <<'STUB'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
STUB
  chmod +x "${fakebin}/semgrep"

  _ANALYZERS_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" PATH="$fakebin" \
    run bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
}

@test "analyzers.sh: a hanging analyzer is bounded by the per-tool timeout and does not hang the run" {
  mkdir -p "${REPO}/config"
  cat > "${REPO}/config/bugsweep.config.json" <<'JSON'
{"analyzers": {"enabled": true, "timeout_seconds": 1}}
JSON
  local fakebin="${BATS_TMP}/fakebin-hang"
  _make_bare_fakebin "$fakebin"
  cat > "${fakebin}/semgrep" <<'STUB'
#!/usr/bin/env bash
sleep 60
STUB
  chmod +x "${fakebin}/semgrep"

  local outer_timeout; outer_timeout="$(command -v timeout || command -v gtimeout)"
  _ANALYZERS_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" PATH="$fakebin" \
    "$outer_timeout" 20 bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$?" -eq 0 ]
}

@test "analyzers.sh: fast-exiting analyzer leaves NO orphaned watchdog sleep (fallback path, no timeout binary)" {
  # BLOCKER regression guard (bugsweep-042 review): on the manual-watchdog
  # fallback path (no timeout/gtimeout on PATH), a FAST-exiting tool must not
  # leave the watchdog's own `sleep <timeout_seconds>` alive. An orphaned sleep
  # reparents to PID 1 and keeps the run's inherited stdout/stderr pipe FDs
  # open, which is what hung bats for ~5 minutes at ~0% CPU.
  #
  # A distinctive, unlikely-to-collide timeout value makes the orphan check
  # unambiguous even when sibling worktrees run their own suites concurrently.
  local uniq_timeout=31771
  mkdir -p "${REPO}/config"
  cat > "${REPO}/config/bugsweep.config.json" <<JSON
{"analyzers": {"enabled": true, "timeout_seconds": ${uniq_timeout}}}
JSON
  local fakebin="${BATS_TMP}/fakebin-fastexit"
  _make_fakebin_no_timeout "$fakebin"
  # Clean, immediate exit — exercises the watchdog-still-sleeping teardown path.
  cat > "${fakebin}/semgrep" <<'STUB'
#!/usr/bin/env bash
echo '{"results":[]}'
exit 0
STUB
  chmod +x "${fakebin}/semgrep"

  _ANALYZERS_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" PATH="$fakebin" \
    run bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]

  # No process anywhere should still be sleeping for our distinctive interval.
  # (grep on the full ps listing; the value is unique enough that a match is
  # unambiguously our leaked watchdog sleep.)
  run pgrep -f "sleep ${uniq_timeout}"
  [ "$status" -ne 0 ]
}

@test "analyzers.sh: usage error (no RUN_DIR) exits non-zero without writing hits" {
  run bash "$ANALYZERS_SH"
  [ "$status" -ne 0 ]
}

@test "analyzers.sh: results are untrusted data — never executed, only parsed (no eval of message field)" {
  mkdir -p "${REPO}/config"
  cat > "${REPO}/config/bugsweep.config.json" <<'JSON'
{"analyzers": {"enabled": true}}
JSON
  local fakebin="${BATS_TMP}/fakebin-inject"
  _make_bare_fakebin "$fakebin"
  local marker="${BATS_TMP}/PWNED"
  cat > "${fakebin}/semgrep" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "--json" ]; then
    cat <<JSON
{
  "results": [
    {
      "check_id": "x",
      "path": "app.py",
      "start": {"line": 1},
      "extra": {"message": "\$(touch ${marker})", "severity": "ERROR"}
    }
  ]
}
JSON
    exit 0
  fi
done
exit 0
STUB
  chmod +x "${fakebin}/semgrep"

  _ANALYZERS_TEST_CONFIG_OVERRIDE="${REPO}/config/bugsweep.config.json" PATH="$fakebin" \
    run bash "$ANALYZERS_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$marker" ]
}

# ---------------------------------------------------------------------------
# Adjudication safety (bugsweep-042 core safety property): analyzer hits are
# SEEDS, never pre-confirmed findings, and never bypass the Hunter -> Skeptic
# -> Referee gauntlet. These are grep-level contract guards on the prompt
# text itself, in the same spirit as bench/tests/unit/test_skill_report_format.py
# (which guards SKILL.md's report template against drift).
# ---------------------------------------------------------------------------

@test "prompts/hunt.md: documents analyzer-hits.json as seeds requiring full independent verification" {
  local hunt_md="${BUGSWEEP_ROOT_DIR}/prompts/hunt.md"
  [ -f "$hunt_md" ]
  grep -qi "analyzer-hits.json" "$hunt_md"
  grep -qi "seed" "$hunt_md"
  grep -qi "not.*pre-confirmed\|never.*pre-confirmed" "$hunt_md"
  grep -qi "independent verification\|independently verif" "$hunt_md"
}

@test "prompts/referee.md: documents corroborated_by and that an analyzer hit alone never confirms a finding" {
  local referee_md="${BUGSWEEP_ROOT_DIR}/prompts/referee.md"
  [ -f "$referee_md" ]
  grep -q "corroborated_by" "$referee_md"
  grep -qi "raise.*confidence\|raises confidence" "$referee_md"
  grep -qi "absence.*must.*not lower\|must.*not lower.*confidence" "$referee_md"
  grep -qi "never confirms\|never confirm a finding\|alone never" "$referee_md"
}

@test "SKILL.md: hunt step mentions the optional analyzers.sh pre-hunt step" {
  local skill_md="${BUGSWEEP_ROOT_DIR}/SKILL.md"
  [ -f "$skill_md" ]
  grep -q "scripts/analyzers.sh" "$skill_md"
}
