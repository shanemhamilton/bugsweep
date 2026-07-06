#!/usr/bin/env bash
# bugsweep static-analyzer seeding (bugsweep-042): an OPTIONAL pre-hunt step that
# runs off-the-shelf static analyzers against the repo to (a) seed the Hunter
# with candidate locations to prioritize and (b) give the Referee an
# independent corroboration signal. bugsweep already WRITES Semgrep rules for
# CONFIRMED bugs (scripts/variants.sh) — this is the complementary direction:
# running third-party tools BEFORE the hunt even starts.
#
#   analyzers.sh <RUN_DIR>
#
# Config (config/bugsweep.config.json, `.analyzers`):
#   enabled          default false. A REPRODUCIBILITY DEFAULT, not a safety
#                    default: which analyzers happen to be installed on a
#                    given machine is environment-specific, so auto-running
#                    them would make two runs of the identical repo diverge
#                    depending on local tooling. Opt in explicitly.
#   timeout_seconds  default 300. Per-tool wall-clock budget (not a total
#                    budget) — one slow/hanging analyzer must never stall the
#                    whole run.
#   max_hits         default 200. Cap passed through to the normalizer.
#
# Detection table (easily extensible — add a "tool_name:cli_binary" entry to
# ANALYZER_TOOLS and a case arm in _run_one_tool to support a new analyzer):
#   semgrep  -> semgrep --config auto --json --timeout <n> <repo>
#   gosec    -> gosec -fmt json ./...   (run from repo root)
#   bandit   -> bandit -f json -r <repo>
#
# Safety / trust contract:
#   - Detection is `command -v` only; nothing is installed by this script.
#   - Every tool invocation is BEST-EFFORT: a missing binary is a clean
#     SKIPPED line (never an error); a non-zero exit or a timeout is caught
#     and logged, never propagated as a run failure (SKILL.md trust contract:
#     "never fail the run" is table stakes for an optional enhancement step).
#   - Raw tool JSON is UNTRUSTED INPUT. It is only ever passed to the python3
#     json parser (scripts/_analyzer_norm.py -> bench/scorer/analyzer_norm.py)
#     — never eval'd, never sourced, never interpolated into a shell command.
#   - Degraded no-python path: if python3 is unavailable, raw per-tool JSON is
#     still collected (so nothing already computed is thrown away) but
#     normalization is skipped and analyzer-hits.json is NOT written — analyzer
#     seeding is an enhancement, not a contract (per the bead), so a bare
#     machine just gets a clearly logged skip rather than a broken partial file.
#
# Writes (only when enabled AND at least one tool ran AND python3 is present):
#   <RUN_DIR>/analyzer-hits.json   {"hits": [...normalized hits...], "count": N}
# Always appends (only when enabled and at least one tool actually ran):
#   {"event":"analyzers","tools":[...],"hits":<N>}  to <RUN_DIR>/ledger.jsonl

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# TEST-ONLY config redirection. common.sh unconditionally sets BUGSWEEP_CONFIG
# to "${BUGSWEEP_ROOT}/config/bugsweep.config.json" (a plain assignment, not
# `:=`), so the test harness cannot point this script at a temp config via the
# public BUGSWEEP_CONFIG. This underscore-prefixed, _TEST_-marked hook lets
# tests/bats/analyzers.bats do so WITHOUT introducing any production-path
# config-redirection env var (no unprefixed override exists — the production
# path always trusts common.sh's single BUGSWEEP_CONFIG, exactly like every
# other cfg_get-using script in the repo). A stray CI export of this internal
# name is the caller's own doing, not a supported knob.
if [ -n "${_ANALYZERS_TEST_CONFIG_OVERRIDE:-}" ]; then
  # shellcheck disable=SC2034  # consumed by common.sh's cfg_get, sourced above
  BUGSWEEP_CONFIG="$_ANALYZERS_TEST_CONFIG_OVERRIDE"
fi

run_dir="${1:-}"
[ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: analyzers.sh <RUN_DIR>"
run_dir="$(cd "$run_dir" && pwd)"

REPO_ROOT="$BUGSWEEP_REPO_ROOT"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(pwd)"

# ---------------------------------------------------------------------------
# Numeric config guard (same pattern as variants.sh's num_or/is_num).
# ---------------------------------------------------------------------------
is_num() {
  case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac
  case "$1" in *[0-9]*) return 0 ;; *) return 1 ;; esac
}
num_or() { if is_num "$1"; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# ---------------------------------------------------------------------------
# Config gate. Disabled is the reproducibility default (see header) — this is
# an early, silent, zero-side-effect exit, byte-for-byte identical to a run
# where analyzers.sh was never called at all.
# ---------------------------------------------------------------------------
_analyzers_enabled="$(cfg_get '.analyzers.enabled' 'false')"
case "$_analyzers_enabled" in
  true) : ;;
  *)
    log "analyzers: disabled (.analyzers.enabled=false, the default) — skipping analyzer seeding."
    exit 0
    ;;
esac

TIMEOUT_SECONDS="$(num_or "$(cfg_get '.analyzers.timeout_seconds' '300')" '300')"
MAX_HITS="$(num_or "$(cfg_get '.analyzers.max_hits' '200')" '200')"

# ---------------------------------------------------------------------------
# Portable per-tool wall-clock timeout (bash 3.2 / POSIX; stock macOS ships
# neither GNU coreutils' timeout(1) nor gtimeout by default).
#
# The fallback runs both the tool AND the watchdog as backgrounded jobs under
# `set -m` (job control), so EACH gets its own process group. Cleanup then
# signals the NEGATIVE pid (the whole process group) for BOTH:
#   - the tool's group, so a tool that forks subprocesses can't leave them
#     running past the timeout; and
#   - the WATCHDOG's group, so on a fast tool exit the watchdog's own
#     `sleep <seconds>` child is killed too. Killing only the watchdog
#     SUBSHELL's pid does NOT reap its `sleep` grandchild — the sleep reparents
#     to PID 1 and keeps the run's inherited stdout/stderr pipe FDs open, which
#     hangs any harness (e.g. bats) that blocks reading those pipes until EOF.
#     This is the bug the no-orphan regression test in tests/bats/analyzers.bats
#     guards: a fast-exiting stub tool, on the fallback path, must leave no
#     lingering `sleep`.
#
# Falls back to running the tool untimed only if neither `timeout` nor
# `gtimeout` is present AND job control is unavailable — this repo's target
# shells (bash 3.2+) always have it, so the untimed fallback is a defensive
# floor, not the expected path.
# ---------------------------------------------------------------------------
_run_with_timeout() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 "${seconds}s" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 1 "${seconds}s" "$@"
    return $?
  fi

  local old_monitor_state pid rc watchdog_pid
  old_monitor_state="$(set +o | grep monitor || true)"
  set -m 2>/dev/null || true   # each background job gets its own process group

  "$@" &
  pid=$!
  (
    sleep "$seconds" 2>/dev/null || sleep "$seconds"
    # Negative pid = signal the whole tool process group, reaching any
    # subprocesses the tool itself spawned, not just the direct child.
    kill -TERM "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!

  set +e
  wait "$pid"
  rc=$?
  set -e

  # Teardown. Kill BOTH process groups by negative pid: the tool's (in case it
  # spawned subprocesses) and the watchdog's (so its still-running `sleep`
  # child is reaped, not orphaned to PID 1 holding our pipe fds open). The
  # negative-pid kill is what reaches the watchdog's `sleep` grandchild;
  # killing "$watchdog_pid" alone would leave that sleep alive.
  kill -TERM "-${pid}"          2>/dev/null || true
  kill -TERM "-${watchdog_pid}" 2>/dev/null || kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  eval "$old_monitor_state" 2>/dev/null || true
  return "$rc"
}

# ---------------------------------------------------------------------------
# Detection table: "tool_name cli_binary" pairs, one per line. Extend here to
# support a new analyzer — add the pair below and a case arm in _run_one_tool.
# ---------------------------------------------------------------------------
ANALYZER_TOOLS='semgrep semgrep
gosec gosec
bandit bandit'

# Runs one tool's CLI with safe, non-mutating, machine-readable-output flags.
# Writes raw JSON to $2 (a file). Returns the tool's own exit code; the caller
# treats any non-zero exit as "no hits from this tool", never a run failure.
_run_one_tool() {
  local tool="$1" out="$2"
  case "$tool" in
    semgrep)
      _run_with_timeout "$TIMEOUT_SECONDS" \
        semgrep --config auto --json --timeout "$TIMEOUT_SECONDS" "$REPO_ROOT" > "$out" 2>/dev/null
      ;;
    gosec)
      ( cd "$REPO_ROOT" && _run_with_timeout "$TIMEOUT_SECONDS" gosec -fmt json ./... ) > "$out" 2>/dev/null
      ;;
    bandit)
      _run_with_timeout "$TIMEOUT_SECONDS" bandit -f json -r "$REPO_ROOT" > "$out" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Run each installed tool, best-effort. Collect raw output paths into a
# manifest (tool -> raw file) for the normalizer; anything that produced no
# usable output is simply absent from the manifest, never invented.
# ---------------------------------------------------------------------------
raw_dir="$(mktemp -d "${TMPDIR:-/tmp}/bugsweep-analyzers.XXXXXX")"
trap 'rm -rf "$raw_dir"' EXIT

ran_tools=""
manifest_entries=""

while IFS=' ' read -r tool_name cli_bin; do
  [ -n "$tool_name" ] || continue
  if ! command -v "$cli_bin" >/dev/null 2>&1; then
    log "analyzers: ${tool_name} SKIPPED (not installed)."
    continue
  fi

  raw_out="${raw_dir}/${tool_name}.raw.json"
  if _run_one_tool "$tool_name" "$raw_out"; then
    if [ -s "$raw_out" ]; then
      ran_tools="${ran_tools}${ran_tools:+ }${tool_name}"
      manifest_entries="${manifest_entries}${manifest_entries:+,}\"${tool_name}\":\"${raw_out}\""
      log "analyzers: ${tool_name} completed."
    else
      log "analyzers: ${tool_name} produced no output — treating as zero hits."
    fi
  else
    log "analyzers: ${tool_name} exited non-zero or timed out after ${TIMEOUT_SECONDS}s — treating as zero hits (best-effort, never fails the run)."
  fi
done <<EOF
$ANALYZER_TOOLS
EOF

if [ -z "$ran_tools" ]; then
  log "analyzers: no analyzers available or all skipped — nothing to normalize."
  exit 0
fi

# ---------------------------------------------------------------------------
# Normalization (coverage-gated pure function, invoked via the thin shim).
# Degraded no-python path: skip normalization, write nothing, log clearly —
# analyzer seeding is an enhancement, not a contract (per the bead).
# ---------------------------------------------------------------------------
if ! have_python; then
  log "analyzers: python3 unavailable — skipping normalization (analyzer seeding is an enhancement, not a contract). Ran: ${ran_tools}."
  exit 0
fi

manifest_path="${raw_dir}/manifest.json"
printf '{%s}' "$manifest_entries" > "$manifest_path"

hits_path="${run_dir}/analyzer-hits.json"
_norm_py="${BUGSWEEP_SCRIPT_DIR}/_analyzer_norm.py"

if [ ! -f "$_norm_py" ]; then
  log "analyzers: normalizer entrypoint missing (${_norm_py}) — skipping normalization."
  exit 0
fi

if ! RAW_MANIFEST="$manifest_path" MAX_HITS="$MAX_HITS" BUGSWEEP_ROOT="$BUGSWEEP_ROOT" \
     python3 "$_norm_py" "$hits_path" 2>/dev/null; then
  log "analyzers: normalization failed — skipping (analyzer seeding is an enhancement, not a contract). Ran: ${ran_tools}."
  exit 0
fi

hit_count="$(grep -o '"count": *[0-9]*' "$hits_path" 2>/dev/null | grep -o '[0-9]*' | head -1)"
case "$hit_count" in ''|*[!0-9]*) hit_count=0 ;; esac

# Ledger event: tools is a JSON array of the tool names that actually ran.
tools_json=""
for t in $ran_tools; do
  tools_json="${tools_json}${tools_json:+,}\"${t}\""
done
printf '{"event":"analyzers","tools":[%s],"hits":%s}\n' "$tools_json" "$hit_count" \
  >> "${run_dir}/ledger.jsonl"

log "analyzers: wrote ${hits_path} (${hit_count} hits from: ${ran_tools})."
