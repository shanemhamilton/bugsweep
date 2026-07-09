#!/usr/bin/env bash
# bugsweep checks runner. Two modes:
#   run_checks.sh baseline <RUN_DIR>   -> record the starting state
#   run_checks.sh verify   <RUN_DIR>   -> run again and compare to baseline
# Exit code: 0 if checks are GREEN or no worse than baseline; 1 if regressed.
# It auto-detects the project's checks unless overridden in the config.
#
# --- Flaky-aware verify (bugsweep-ml7) ----------------------------------------
# This script has NO per-test granularity: each configured check (test/
# typecheck/build/lint) is one opaque shell command, and baseline/verify only
# ever compare pass/fail PER CHECK, never per individual test. That is a hard
# pre-existing limitation, not something this feature works around:
#   - "Newly failing" is detected at the check level (a check that passed, or
#     wasn't run, at baseline but fails at verify).
#   - When the "test" check newly fails, it is rerun (re-invoking the SAME
#     check command) up to `.verify.flaky_reruns` (default 3) times. If the
#     project's test runner output lets us identify individual failing test
#     names (best-effort regex over common pytest/jest/vitest/go/cargo/bats
#     failure-line formats), those names are recorded for reporting; if not,
#     the whole "test" check is treated as the rerun unit and reported under
#     a synthetic id. Either way the thing that is actually re-EXECUTED is
#     always the check's command — there is no mechanism here to target one
#     test inside a suite without running the rest.
#   - Classification is by MAJORITY of the reruns, NOT pass-once. All N reruns
#     are run and their pass/fail outcomes counted. A STRICT majority of rerun
#     passes (rerun_passes > rerun_fails) reclassifies the check as flaky:
#     excluded from the regression decision, recorded to <RUN_DIR>/flaky.jsonl
#     and appended to <RUN_DIR>/ledger.jsonl as
#     {"event":"flaky_test","test":<id>,"file":<file-or-null>,"reruns":<n>,
#     "failures":<m>}, and surfaced via a stable `FLAKY=<n>` line plus one
#     `FLAKY_TEST=<id>` line. A tie or a majority of rerun FAILURES stays a
#     REGRESSION and reverts (the existing exit-1 contract is UNCHANGED).
#   - Fail-safe: if the rerun MECHANISM itself errors (as opposed to the
#     reran command simply failing) this falls back to the OLD behavior —
#     treat the check as a deterministic failure and revert. A broken rerun
#     path must never become a loophole that lets a red checkpoint through.
#
# WHAT THIS ACTUALLY DISTINGUISHES — DO NOT OVERCLAIM (safety, MAJOR 2):
# This mechanism does NOT prove a failure is "deterministic" vs "flaky" in the
# general sense. Precisely, it distinguishes only "failed the MAJORITY of
# reruns in a SHARED working tree / environment" from "passed the majority".
# Because the reruns SHARE the initial run's working tree and environment (no
# per-rerun isolation), a MONOTONIC state-pollution failure — a broken fix
# whose first run fails but leaves a marker/cache/lock that makes later runs
# pass — CAN be misclassified as flaky. The majority-of-N vote raises the bar
# against this (a single pollution-driven pass no longer wins), but does not
# eliminate it: a fix that pollutes state on its FIRST run and then passes a
# majority of reruns would still be mislabeled flaky. Therefore any fix that
# lands with a flaky classification is LOUDLY surfaced (flaky.jsonl + ledger +
# run-summary + the `FLAKY=<n>`/`FLAKY_TEST=` stdout lines) so a human /
# orchestrator reviews it — a flaky-classified landed fix is never silent.
# Full per-rerun isolation (fresh worktree/env per rerun) is a documented
# FUTURE ENHANCEMENT (a follow-up bead), deliberately deferred here; this
# comment states the delivered guarantee accurately rather than claiming more
# safety than the shared-environment rerun provides.
#
# KNOWN LIMITATION (baseline-flaky, criterion 3): baseline.json records only
# an aggregate pass/fail PER CHECK, with no per-test identity at all. So a
# test that was ALREADY intermittently failing at baseline time — i.e. it
# happened to pass when baseline captured the "test" check as green — cannot
# be distinguished from a genuinely new regression by this mechanism: if it
# fails at verify time and then passes a majority of reruns, it is (correctly,
# by this design) classified as flaky, even though from the project's
# perspective it was flaky all along rather than newly introduced. There is no per-test
# baseline identity to check it against. Fixing this would require baseline
# to also capture and persist individual test outcomes (framework-specific
# parsing baseline does not do today), which is out of scope here; this
# comment exists so that limitation is documented rather than silently
# assumed away.
#
# --- Repro gate (bugsweep-hty) -------------------------------------------------
# Everything above answers ONE question: "did the configured check suite
# regress?" It has no way to prove a SPECIFIC fix resolves the SPECIFIC bug
# it targets — a fix that is a no-op for the real bug can still pass here if
# nothing in the existing suite exercises that code path. scripts/repro.sh is
# a separate, ADDITIVE script (not sourced or called by this file, and not
# calling into it) that closes that gap: prompts/fix.md runs it ALONGSIDE
# (never instead of) this file's verify step, driving a bug-specific repro
# test through a red (pre-fix) -> green (post-fix) cycle. A landed fix must
# satisfy BOTH gates — this file's suite-green/REGRESSION decision (bugsweep-
# gli/ml7/7hw, documented above and completely unmodified by bugsweep-hty)
# AND, only when a repro was independently pre-confirmed red, repro.sh's
# post-fix green check. See scripts/repro.sh's own header for the full
# contract, and prompts/fix.md for exactly how the two signals combine.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

phase="${1:-}"; run_dir="${2:-}"
[ -n "$phase" ] && [ -n "$run_dir" ] || die "usage: run_checks.sh <baseline|verify> <RUN_DIR>"
[ -d "$run_dir" ] || die "run dir not found: $run_dir"

# bugsweep-7hw: read state.env (if present) so BUGSWEEP_WORKTREE is available
# below -- the same idiom scripts/guard.sh and scripts/finalize.sh already use
# to source "${run_dir}/state.env" (neither of those two files is modified by
# this change; this is a THIRD, independent read site). Guarded by an `if`
# (not their bare unconditional `. "${run_dir}/state.env"`) because
# run_checks.sh, unlike those two, is also exercised directly against a
# run_dir that legitimately has no state.env yet -- every pre-existing
# run_checks.sh bats test constructs a bare run_dir with no preflight run at
# all. A malformed/unreadable state.env degrades to "no isolation signal"
# (via the `|| true`) rather than aborting the whole verify.
if [ -f "${run_dir}/state.env" ]; then
  # shellcheck disable=SC1091
  . "${run_dir}/state.env" 2>/dev/null || true
fi

# --- Resolve check commands: config overrides win, else auto-detect -----------
cmd_test="$(cfg_get '.commands.test' '')"
cmd_build="$(cfg_get '.commands.build' '')"
cmd_typecheck="$(cfg_get '.commands.typecheck' '')"
cmd_lint="$(cfg_get '.commands.lint' '')"

detect() {
  # Only fills commands that weren't explicitly configured.
  if [ -f package.json ]; then
    [ -z "$cmd_test" ] && grep -q '"test"' package.json 2>/dev/null && cmd_test="npm test --silent"
    [ -z "$cmd_build" ] && grep -q '"build"' package.json 2>/dev/null && cmd_build="npm run build --silent"
    [ -z "$cmd_typecheck" ] && [ -f tsconfig.json ] && cmd_typecheck="npx --no-install tsc --noEmit"
  fi
  if [ -f pyproject.toml ] || [ -f setup.cfg ] || [ -f pytest.ini ] || ls tests/ >/dev/null 2>&1; then
    [ -z "$cmd_test" ] && command -v pytest >/dev/null 2>&1 && cmd_test="pytest -q"
  fi
  if [ -f go.mod ]; then
    [ -z "$cmd_test" ] && cmd_test="go test ./..."
    [ -z "$cmd_build" ] && cmd_build="go build ./..."
  fi
  if [ -f Cargo.toml ]; then
    [ -z "$cmd_test" ] && cmd_test="cargo test --quiet"
    [ -z "$cmd_build" ] && cmd_build="cargo build --quiet"
  fi
  if ls ./*.xcodeproj >/dev/null 2>&1 || ls ./*.xcworkspace >/dev/null 2>&1; then
    : # iOS/Xcode: leave to config override; xcodebuild invocations are project-specific.
  fi
}
detect

# --- Flaky-rerun helpers (bugsweep-ml7) ---------------------------------------
# Best-effort, language-agnostic extraction of a failing test's identity from
# a check's captured log, purely for the flaky.jsonl/ledger "test" field and
# the human-facing FLAKY_TEST= line. Never used to decide what to re-execute
# (that is always the whole "test" check's command — see header comment).
# Recognizes the common failure-line shapes emitted by pytest, jest/vitest,
# go test, cargo test, and bats; falls back to a generic marker so the field
# is always populated with SOMETHING rather than emitting invalid JSON.
extract_failing_test_id() {
  local log="$1" line=""
  [ -f "$log" ] || { printf '%s' "test-check"; return 0; }
  # pytest: "FAILED path/to/test_x.py::test_name" (optionally "- reason").
  line="$(grep -m1 -oE '^FAILED[[:space:]]+[^[:space:]]+' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "${line#FAILED }"; return 0; fi
  # jest/vitest: "✕ test name" or "FAIL  path" — prefer the ✕ assertion line.
  line="$(grep -m1 -oE '(✕|✗)[[:space:]]+.+' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "$(printf '%s' "$line" | sed -E 's/^(✕|✗)[[:space:]]+//')"; return 0; fi
  # go test: "--- FAIL: TestName (0.00s)"
  line="$(grep -m1 -oE -- '--- FAIL: [^[:space:]]+' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "${line#--- FAIL: }"; return 0; fi
  # cargo test: "test module::test_name ... FAILED"
  line="$(grep -m1 -oE 'test [^[:space:]]+ \.\.\. FAILED' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "$(printf '%s' "$line" | sed -E 's/^test ([^[:space:]]+).*/\1/')"; return 0; fi
  # bats: "not ok N description"
  line="$(grep -m1 -oE 'not ok [0-9]+ .+' "$log" 2>/dev/null || true)"
  if [ -n "$line" ]; then printf '%s' "${line#not ok }"; return 0; fi
  printf '%s' "test-check"
}

# Best-effort file path for the failing test, if the id embeds one
# (pytest's "path::name" shape); null-worthy otherwise per the bead spec
# ("file may be null").
extract_failing_test_file() {
  local id file
  id="$(extract_failing_test_id "$1")"
  case "$id" in
    *"::"*) file="${id%%::*}"; printf '%s' "$file" ;;
    *) printf '' ;;
  esac
}

# Emit a JSON string literal for a possibly-empty value, or the bare word
# null when empty — used for flaky.jsonl's "file" field which may be null.
json_str_or_null() {
  local v="$1"
  if [ -z "$v" ]; then
    printf 'null'
  else
    # Minimal escaping sufficient for the values we ever pass here (test ids
    # and file paths): backslash and double-quote.
    printf '"%s"' "$(printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

# --- Isolated-rerun safety scope (bugsweep-7hw) --------------------------------
# Follow-up to bugsweep-ml7's documented shared-environment residual (see the
# module header above): reruns share the working tree/environment with the
# initial run, so a MONOTONIC state-pollution failure (a broken fix's first
# run fails but leaves a marker/cache that makes every subsequent run pass)
# can be misclassified FLAKY. Where isolation is FEASIBLE and UNAMBIGUOUS -- a
# `preflight.sh --worktree` run, whose linked worktree is bugsweep-controlled
# and disposable -- each rerun is now given a clean slate: tracked-file
# mutations and newly-created untracked files are reset before every rerun.
#
# ISOLATION-ACTIVATION SIGNAL (the ONLY thing that turns this on): state.env's
# BUGSWEEP_WORKTREE, written by preflight.sh -- empty string in the default/
# in-place mode (preflight.sh: `worktree_path=""`, then persisted verbatim as
# `BUGSWEEP_WORKTREE=${worktree_path}`), the linked worktree's absolute path
# in `--worktree` mode. If BUGSWEEP_WORKTREE is unset/empty, OR the path it
# names does not exist, OR it is not itself a distinct LINKED git worktree
# (see _bsw_isolated_worktree), isolation NEVER activates and behavior is
# byte-identical to the pre-bugsweep-7hw script -- the documented shared-
# environment residual persists honestly rather than risking a reset against
# ambiguous state (safety contract: "if there is ANY doubt, do NOT reset").
#
# SCOPE: every reset operation below is explicitly targeted at the confirmed
# worktree directory via `git -C "<worktree>"` / literal "<worktree>/<path>"
# prefixes -- never the current process's cwd, and never any path outside
# that one confirmed directory. Only bugsweep-DISPOSABLE state is ever
# touched: (a) tracked files are restored to a snapshot taken via
# `git stash create` BEFORE the verify pass's very first "test" check
# invocation -- that snapshot already contains any uncommitted fix under test
# (prompts/fix.md's flow applies the fix, THEN calls `run_checks.sh verify`,
# THEN commits -- see SKILL.md Step 4), so restoring to it can never discard
# the fix, only undo mutations the TEST ITSELF made since that snapshot;
# (b) untracked files are removed ONLY if they are NOT present in a
# `git ls-files -z --others --exclude-standard` snapshot taken at that same
# moment -- a file that predates this verify pass is never a removal
# candidate, full stop. No `git clean -fdx` is ever invoked. No `reset --hard`
# or force flag is ever used on the worktree's branch or any ref.
#
# NUL-SAFETY (bugsweep-7hw adversarial review, CONFIRMED BLOCKER): WITHOUT
# `-z`, `git ls-files --others` C-QUOTES any path containing a newline,
# backslash, or double-quote -- it prints the literal `"evil\nname"` (quotes +
# backslash-n), NOT the raw bytes. A newline-delimited compare/remove would
# then target a path that does not exist on disk, the `rm` would no-op, and the
# REAL polluting file would survive every reset -- reopening the exact
# monotonic-state-pollution hole this bead closes (a broken fix whose first-run
# marker has a newline in its name would be misclassified FLAKY and LAND).
# Every untracked listing below therefore uses `git ls-files -z` (NUL-delimited,
# raw byte-accurate names, unaffected by core.quotePath) and is split/compared
# on NUL via `read -r -d ''`, so real names -- newlines, spaces, leading
# dashes, unicode, and all -- are matched and removed exactly. `rm -rf --` plus
# the "${wt}/"* prefix guard keep a leading-dash name from being read as an
# option and keep every removal strictly inside the confirmed worktree.

# _bsw_isolated_worktree: prints the confirmed worktree path and returns 0
# only when the activation signal is unambiguous; returns 1 (prints nothing)
# on any doubt whatsoever, which every call site below treats as "do not
# isolate" (fall back to the pre-existing shared-environment behavior).
_bsw_isolated_worktree() {
  local wt="${BUGSWEEP_WORKTREE:-}" gd cdir
  [ -n "$wt" ] || return 1
  [ -d "$wt" ] || return 1
  # Never the main repo root itself (BUGSWEEP_REPO_ROOT, from common.sh) --
  # this can only legitimately be equal if state.env were somehow corrupted
  # or forged; refuse rather than guess.
  if [ -n "${BUGSWEEP_REPO_ROOT:-}" ] && [ "$wt" = "$BUGSWEEP_REPO_ROOT" ]; then
    return 1
  fi
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  gd="$(_bsw_abs_git_path "$wt" --git-dir)" || return 1
  cdir="$(_bsw_abs_git_path "$wt" --git-common-dir)" || return 1
  [ -n "$gd" ] && [ -n "$cdir" ] || return 1
  # A LINKED worktree's git-dir (.git/worktrees/<id>) always differs from the
  # shared git-common-dir (the main .git); the MAIN worktree's are identical.
  # Equal here means $wt is not actually a linked worktree -- refuse.
  [ "$gd" != "$cdir" ] || return 1
  printf '%s' "$wt"
}

# Resolve a `git rev-parse --git-dir`/`--git-common-dir` style output to an
# absolute path, mirroring common.sh's own relative-path resolution for the
# identical case (see common.sh's BUGSWEEP_GIT_COMMON_DIR derivation) --
# duplicated here (not sourced from common.sh) because common.sh's version is
# hardwired to `git rev-parse` from the CALLING process's own cwd, not an
# arbitrary "-C <dir>" target.
_bsw_abs_git_path() {
  local repo="$1" kind="$2" d
  d="$(git -C "$repo" rev-parse "$kind" 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  case "$d" in
    /*) printf '%s' "$d" ;;
    *) (cd "${repo}/${d}" 2>/dev/null && pwd) || return 1 ;;
  esac
}

# Snapshot the CURRENT tracked working-tree+index state as a dangling commit
# object, without touching the working tree itself (`git stash create` is
# read-only w.r.t. the working tree/index -- unlike `git stash push`). Called
# once, before the verify pass's first "test" check runs, so it already
# includes any uncommitted fix under test. An empty result means the tracked
# state already equals HEAD (nothing uncommitted) -- HEAD is then the correct,
# equivalent snapshot.
_bsw_snapshot_tracked() {
  local wt="$1" sha
  sha="$(git -C "$wt" stash create 2>/dev/null)" || return 1
  if [ -z "$sha" ]; then
    sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
  fi
  printf '%s' "$sha"
}

# Capture the worktree's CURRENT untracked set as a NUL-delimited snapshot
# file (bugsweep-7hw). `-z` is load-bearing: it emits raw byte-accurate paths
# (no C-quoting of newline/backslash/quote names, and unaffected by
# core.quotePath's unicode escaping), so the membership + removal logic below
# operate on the true on-disk names. Returns non-zero if the snapshot cannot
# be written (e.g. the target path is unwritable) so the caller can fail SAFE
# (disable isolation) rather than let an unguarded redirect abort the whole
# script under `set -euo pipefail`.
_bsw_snapshot_untracked() {
  local wt="$1" out="$2"
  git -C "$wt" ls-files -z --others --exclude-standard > "$out" 2>/dev/null || return 1
  return 0
}

# NUL-delimited membership test: is $1 present as a NUL-terminated record in
# the snapshot file $2? Used to tell a NEW untracked file (created during this
# run) apart from one that predates it -- byte-accurately, so a name with an
# embedded newline is compared as one whole record, not split into lines.
_bsw_nul_member() {
  local needle="$1" file="$2" rec
  [ -f "$file" ] || return 1
  while IFS= read -r -d '' rec; do
    [ "$rec" = "$needle" ] && return 0
  done < "$file"
  return 1
}

# Reset the isolated worktree's DISPOSABLE state back to the pre-run
# snapshot: (a) tracked files -> $tracked_sha (every git invocation is
# `-C "$wt"`, never touching anything outside it); (b) untracked files ->
# remove only entries NOT present in $pre_untracked_file, and only ever under
# "$wt/...". Best-effort: every command is guarded so a failure here degrades
# to "this one rerun stays a bit less isolated" rather than aborting
# run_checks.sh.
_bsw_isolate_reset() {
  local wt="$1" scratch_dir="$2" tracked_sha="$3" pre_untracked_file="$4"
  local cur_untracked_file="${scratch_dir}/isolate-cur-untracked.txt"
  local entry target

  if [ -n "$tracked_sha" ]; then
    git -C "$wt" checkout -q "$tracked_sha" -- . >/dev/null 2>&1 || true
  fi

  # NUL-delimited current listing (see _bsw_snapshot_untracked). If it can't be
  # written, skip untracked cleanup for this reset (tracked restore already
  # ran) rather than aborting -- best-effort, fail-safe under set -e.
  _bsw_snapshot_untracked "$wt" "$cur_untracked_file" || return 0

  # Split on NUL, not newlines, so a name containing a newline is one record.
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    _bsw_nul_member "$entry" "$pre_untracked_file" && continue
    target="${wt}/${entry}"
    case "$target" in
      "${wt}/"*) rm -rf -- "$target" 2>/dev/null || true ;;
    esac
  done < "$cur_untracked_file" || true

  return 0
}

# --- Run each available check, capture pass/fail ------------------------------
results_file="${run_dir}/checks-${phase}.json"
overall=0
detail=""
# Set by run_one() for the "test" check only, so the verify-phase flaky-rerun
# logic below can tell whether THIS check just failed without re-parsing
# results_file. Deliberately check-scoped (not a generic per-check map) since
# flaky rerun only ever applies to "test" (see header comment).
test_check_failed=0
# Count of checks OTHER than "test" that failed (0..3: typecheck/build/lint).
# "overall" (bugsweep-gli) is a per-check FAILURE COUNT, not a collapsed 0/1
# flag, so a brand-new failure in ANY check always raises the total even when
# a DIFFERENT check was already failing at baseline -- a flag stuck at 1 on
# both sides would mask that new regression. Tracked separately from
# "overall" so that when "test" is reclassified flaky below, "overall" can be
# recomputed as exactly the other-checks' count instead of blindly zeroing it
# (which would erase a genuine, simultaneous lint/build/typecheck regression).
other_check_failed=0

run_one() {
  local name="$1" cmd="$2"
  [ -z "$cmd" ] && return 0
  log "running ${name}: ${cmd}"
  if ( eval "$cmd" ) >"${run_dir}/${phase}-${name}.log" 2>&1; then
    detail="${detail}{\"check\":\"${name}\",\"status\":\"pass\"},"
  else
    detail="${detail}{\"check\":\"${name}\",\"status\":\"fail\"},"
    overall=$((overall + 1))
    if [ "$name" = "test" ]; then test_check_failed=1; else other_check_failed=$((other_check_failed + 1)); fi
  fi
}

# Resolve isolation ONCE, before the verify pass's very first "test" check
# invocation runs (bugsweep-7hw). This ordering is load-bearing: a state-
# pollution marker created BY that first run must be ABSENT from the
# snapshot, or resetting to the snapshot before each rerun would never
# actually remove it (see the design comment above _bsw_isolated_worktree).
# Gated on phase=="verify" -- baseline never reaches the rerun logic below, so
# there is nothing for the snapshot to serve there.
iso_worktree=""
iso_tracked_sha=""
iso_pre_untracked_file=""
if [ "$phase" = "verify" ] && [ -n "$cmd_test" ]; then
  if candidate_wt="$(_bsw_isolated_worktree)"; then
    candidate_pre_untracked="${run_dir}/isolate-pre-untracked.txt"
    # Both snapshots must succeed to activate isolation. If EITHER the tracked
    # `stash create` snapshot OR the NUL-delimited untracked snapshot fails
    # (e.g. an unwritable snapshot path), fail SAFE: leave iso_worktree empty
    # so no reset is ever attempted and behavior reverts to the documented
    # shared-environment path -- never an uncaught `set -euo pipefail` abort
    # (adversarial review MINOR).
    if candidate_sha="$(_bsw_snapshot_tracked "$candidate_wt")" \
       && _bsw_snapshot_untracked "$candidate_wt" "$candidate_pre_untracked"; then
      iso_worktree="$candidate_wt"
      iso_tracked_sha="$candidate_sha"
      iso_pre_untracked_file="$candidate_pre_untracked"
      log "isolated-rerun scope active: ${iso_worktree} (bugsweep-7hw)."
    else
      log "isolated-rerun snapshot failed; falling back to shared-environment rerun behavior (fail-safe, bugsweep-7hw)."
    fi
  fi
fi

run_one "test" "$cmd_test"
run_one "typecheck" "$cmd_typecheck"
run_one "build" "$cmd_build"
run_one "lint" "$cmd_lint"

has_any_check="yes"
[ -z "${cmd_test}${cmd_build}${cmd_typecheck}${cmd_lint}" ] && has_any_check="no"

detail="[${detail%,}]"
printf '{"phase":"%s","overall":%d,"has_any_check":"%s","checks":%s}\n' \
  "$phase" "$overall" "$has_any_check" "$detail" > "$results_file"

if [ "$has_any_check" = "no" ]; then
  log "No automated checks detected. See references/no-tests.md — fixes will be more conservative."
  echo "NO_CHECKS"
  exit 0
fi

# --- Baseline just records; verify compares -----------------------------------
if [ "$phase" = "baseline" ]; then
  cp "$results_file" "${run_dir}/baseline.json"
  echo "BASELINE_OVERALL=${overall}"
  exit 0
fi

base_overall=0
if [ -f "${run_dir}/baseline.json" ]; then
  base_overall="$(grep -o '"overall":[0-9]*' "${run_dir}/baseline.json" | head -1 | grep -o '[0-9]*' || echo 0)"
fi

# Did the "test" check pass at baseline? (0/1 flag, aggregate-only per the
# documented limitation above — there is no per-test baseline identity.)
base_test_failed=0
if [ -f "${run_dir}/baseline.json" ]; then
  base_test_failed="$(grep -o '{"check":"test","status":"[a-z]*"}' "${run_dir}/baseline.json" \
    | grep -c '"status":"fail"' || true)"
  case "$base_test_failed" in ''|*[!0-9]*) base_test_failed=0 ;; esac
  [ "$base_test_failed" -gt 1 ] 2>/dev/null && base_test_failed=1
fi

# --- Flaky-aware rerun: only the "test" check, only when it NEWLY fails -------
# (test_check_failed=1 now, but it did not fail at baseline). See the header
# comment for the full design and the documented baseline-flaky limitation.
flaky_count=0
flaky_test_ids=""
if [ "$test_check_failed" -eq 1 ] && [ "$base_test_failed" -eq 0 ] && [ -n "$cmd_test" ]; then
  flaky_reruns="$(cfg_get '.verify.flaky_reruns' '3')"
  # clamp-to-default-3 (NOT clamp-to-disabled/0) is INTENTIONAL: a garbled or
  # non-numeric config value must not silently turn OFF flakiness protection,
  # so it falls back to the safe default rather than 0. Do not "fix" toward 0.
  case "$flaky_reruns" in ''|*[!0-9]*) flaky_reruns=3 ;; esac

  if [ "$flaky_reruns" -gt 0 ]; then
    # Best-effort test-id extraction from the failing log, for reporting only
    # (the thing actually re-executed is always the whole "test" check — see
    # header comment on why per-test targeting isn't possible here).
    fail_log="${run_dir}/verify-test.log"
    test_id="$(extract_failing_test_id "$fail_log")"
    test_file="$(extract_failing_test_file "$fail_log")"

    # Majority-of-reruns model (BLOCKER 1): run ALL N reruns (no early break)
    # and count how many pass vs fail. Classify flaky ONLY on a STRICT
    # majority of rerun passes (rerun_passes > rerun_fails). A tie or a
    # majority of rerun failures stays a REGRESSION. This raises the bar
    # against the state-pollution false-pass attack, where a broken fix's
    # first run fails but leaves a marker/cache that makes a MINORITY of the
    # (shared-environment) reruns pass. rerun_infra_ok gates the fail-safe:
    # if the rerun mechanism itself errors, we fall back to the pre-flaky
    # deterministic path and never classify flaky.
    reruns=0
    rerun_passes=0
    rerun_fails=0
    rerun_infra_ok=1

    i=1
    while [ "$i" -le "$flaky_reruns" ]; do
      rerun_log="${run_dir}/verify-test-rerun-${i}.log"
      # BUGSWEEP_RERUN_INJECT_FAILURE is a test-only fault-injection hook (same
      # pattern as common.sh's BUGSWEEP_NO_PYTHON) that simulates the rerun
      # MECHANISM itself erroring — distinct from the reran command simply
      # failing. A real-world equivalent would be: can't write $rerun_log,
      # can't fork the subshell, etc. Fail CLOSED: infra failure -> stop
      # rerunning and fall back to the old (pre-flaky) deterministic path.
      if [ -n "${BUGSWEEP_RERUN_INJECT_FAILURE:-}" ]; then
        rerun_infra_ok=0
        break
      fi
      # bugsweep-7hw: give this rerun a clean slate when isolation is active
      # (see the design comment above _bsw_isolated_worktree) -- this is what
      # turns a monotonic state-pollution false-pass into a correctly-
      # classified REGRESSION. A no-op whenever iso_worktree is empty (the
      # documented fail-safe: any doubt about isolation -> no reset).
      if [ -n "$iso_worktree" ]; then
        _bsw_isolate_reset "$iso_worktree" "$run_dir" "$iso_tracked_sha" "$iso_pre_untracked_file"
      fi
      reruns=$((reruns + 1))
      if ( eval "$cmd_test" ) >"$rerun_log" 2>&1; then
        rerun_passes=$((rerun_passes + 1))
      else
        rerun_fails=$((rerun_fails + 1))
      fi
      i=$((i + 1))
    done

    # bugsweep-7hw: leave the isolated worktree clean of test-induced
    # pollution regardless of the classification outcome below, so a
    # subsequent `git add -A && git commit` (SKILL.md Step 4) never picks up
    # rerun debris, and so tracked/untracked state the test mutated is fully
    # restored even after the LAST rerun. Best-effort/no-op when isolation
    # was never active.
    if [ -n "$iso_worktree" ]; then
      _bsw_isolate_reset "$iso_worktree" "$run_dir" "$iso_tracked_sha" "$iso_pre_untracked_file"
    fi

    if [ "$rerun_infra_ok" -eq 1 ] && [ "$rerun_passes" -gt "$rerun_fails" ]; then
      # STRICT majority of reruns passed -> FLAKY. Exclude ONLY this check's
      # contribution to "overall" — if lint/build/typecheck ALSO regressed
      # independently, that must still trigger REGRESSION.
      overall="$other_check_failed"
      flaky_count=1
      # Total observed failures = the initial run (1) + rerun failures.
      total_failures=$((1 + rerun_fails))
      # test_id (raw) is the SINGLE source of truth for the id: json_str_or_null
      # escapes it for the durable JSONL, and the SAME raw value is carried to
      # the human-facing FLAKY_TEST= line below (MAJOR 4: never re-derive the id
      # with a second fragile regex, so parametrized ids with commas survive).
      flaky_line="$(printf '{"event":"flaky_test","test":%s,"file":%s,"reruns":%d,"failures":%d}' \
        "$(json_str_or_null "$test_id")" "$(json_str_or_null "$test_file")" \
        "$reruns" "$total_failures")"
      printf '%s\n' "$flaky_line" >> "${run_dir}/flaky.jsonl"
      printf '%s\n' "$flaky_line" >> "${run_dir}/ledger.jsonl"
      # Carry the (raw, unescaped) id forward for the human-facing line.
      flaky_test_ids="${test_id}"$'\n'
    fi
    # rerun_infra_ok=0, or reruns did NOT pass by a strict majority -> fall
    # through unchanged: this check's earlier "overall" contribution stands,
    # so the pre-existing deterministic REGRESSION path fires exactly as it
    # did before this feature existed (fail-safe / acceptance criterion 1, 4,
    # and the state-pollution / tie defenses).
  fi
fi

# Regression = checks fail now but passed (or didn't fail) at baseline.
if [ "$overall" -gt "$base_overall" ]; then
  echo "REGRESSION"
  exit 1
fi
# Surface any flaky reclassification LOUDLY (BLOCKER 1c) — but ONLY when one
# actually happened, so a clean all-green verify's stdout stays byte-identical
# to the pre-feature script (MAJOR 5). The FLAKY_TEST= id comes straight from
# the same id already written to the durable JSONL — no second fragile regex
# (MAJOR 4), so parametrized ids with commas/brackets pass through verbatim.
if [ "$flaky_count" -gt 0 ]; then
  printf 'FLAKY=%d\n' "$flaky_count"
  if [ -n "$flaky_test_ids" ]; then
    printf '%s' "$flaky_test_ids" | while IFS= read -r fl_test; do
      [ -n "$fl_test" ] && printf 'FLAKY_TEST=%s\n' "$fl_test"
    done
  fi
fi
echo "OK"
exit 0
