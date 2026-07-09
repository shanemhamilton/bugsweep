#!/usr/bin/env bats
#
# bugsweep-4yu: regression guards that lock in the nightshift contract so it
# cannot silently regress across future changes to preflight.sh / finalize.sh /
# state.sh / bugsweep-cleanup.sh. Each test drives the REAL, shipped scripts
# end-to-end (never re-derives their logic) and asserts a previously-shipped
# guarantee:
#
#   (a) Partial-output contract (bugsweep-mu3): a run killed mid-context-build
#       still yields BOTH a stub report.md and a run-summary.json that
#       VALIDATES against schemas/run-summary.schema.json.
#   (c) Concurrency contract (bugsweep-p74/re9): N `preflight.sh --worktree`
#       runs started together each get a distinct worktree + branch, the
#       user's tree is byte-for-byte untouched, and N concurrent
#       `state.sh persist` calls against those runs keep a correct meta.json
#       run count with zero lost audit/risk lines.
#   (d) Cleanup invariant (bugsweep-8d0): after a full worktree run, and after
#       a killed-then-next run, `git worktree list` shows no leftover
#       bugsweep worktrees and `git worktree prune` is a genuine no-op.
#
# (b) — the js-cookie prototype-pollution no-reject guard — is intentionally
# NOT duplicated here: tests/bats/prompts-guardrails.bats (bugsweep-dxh)
# already locks in the prompt-level rule that prevents that false negative.
# This bead's (b) obligation is instead satisfied by
# bench/tests/unit/test_js_cookie_corpus_guard.py, which pins the corpus case
# (file/hunk ground truth) that guard exists to protect.

PREFLIGHT_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/preflight.sh"
FINALIZE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/finalize.sh"
STATE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/state.sh"
SCHEMA_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/schemas/run-summary.schema.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_git_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "test@bugsweep"
  git -C "$dir" config user.name  "bugsweep-test"
  git -C "$dir" checkout -b main -q
  printf 'base\n' > "${dir}/app.txt"
  git -C "$dir" add app.txt
  git -C "$dir" commit -m "init" -q
}

# Content hash of the user's tracked+untracked working-tree files (excluding
# .git and bugsweep's own .bugsweep/ bookkeeping dir) — same idiom as
# tests/bats/preflight-worktree.bats's _tree_hash, duplicated here because
# bats gives each file its own process (no cross-file function sharing).
_tree_hash() {
  local dir="$1"
  ( cd "$dir" && \
    find . -path ./.git -prune -o -path ./.bugsweep -prune -o -type f -print0 2>/dev/null \
      | sort -z \
      | xargs -0 shasum 2>/dev/null \
      | shasum | awk '{print $1}' )
}

# Seeds a distinct, single-batch/single-file recon.json + a fix_committed
# ledger event into an existing (preflight-produced) run dir, so a later
# `state.sh persist` call has something concrete to harvest into
# audit-log.jsonl / risk.jsonl. Same fixture shape as
# tests/bats/state-concurrency.bats's _make_run_dir.
_seed_recon_and_finding() {
  local run_dir="$1" file="$2"
  cat > "${run_dir}/recon.json" <<JSON
{"batches":[{"id":1,"files":["${file}"]}],"covered":[1]}
JSON
  printf '{"event":"fix_committed","file":"%s","severity":"high"}\n' "$file" >> "${run_dir}/ledger.jsonl"
}

# Asserts `git worktree list` has zero entries under the bugsweep worktrees
# dir, AND that `git worktree prune` is a genuine no-op (nothing left for it
# to clean up — i.e. every reap already deregistered its worktree with a real
# `git worktree remove`, not just an out-of-band `rm -rf`).
_assert_no_leftover_bugsweep_worktrees() {
  local listing
  listing="$(git -C "$REPO" worktree list --porcelain)"
  ! printf '%s' "$listing" | grep -q "${REPO}/.bugsweep/worktrees/"

  local prune_output
  prune_output="$(git -C "$REPO" worktree prune -v 2>&1)"
  [ -z "$prune_output" ]
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
  # Best-effort: prune any leftover linked worktrees before removing the repo dir.
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  rm -rf "$BATS_TMP"
}

# ---------------------------------------------------------------------------
# (a) Partial-output contract
# ---------------------------------------------------------------------------

@test "(a) a run killed mid-context-build yields a stub report.md AND a schema-valid run-summary.json" {
  run bash "$PREFLIGHT_SH"
  [ "$status" -eq 0 ]
  local run_dir
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  [ -n "$run_dir" ]

  # Simulate a kill mid-context-build: preflight completed (state.env + the
  # initial "preflight" ledger event exist), but nothing else ever ran — no
  # recon.json (context-build never wrote a plan) and no report.md (the model
  # never reached the report step).
  [ ! -f "${run_dir}/recon.json" ]
  [ ! -f "${run_dir}/report.md" ]

  run bash "$FINALIZE_SH" "$run_dir"
  [ "$status" -eq 0 ]

  # A stub report.md must exist with the INCOMPLETE warning (finalize.sh's
  # silent-failure backstop, bugsweep-je8).
  [ -f "${run_dir}/report.md" ]
  grep -qi "INCOMPLETE" "${run_dir}/report.md"

  # run-summary.json must exist AND validate against the authoritative schema
  # a headless scheduler (nightshift) branches on (bugsweep-mu3).
  local summary="${run_dir}/run-summary.json"
  [ -f "$summary" ]

  python3 - "$summary" "$SCHEMA_PATH" <<'PY'
import json
import sys

summary_path, schema_path = sys.argv[1], sys.argv[2]
data = json.load(open(summary_path, encoding="utf-8"))
schema = json.load(open(schema_path, encoding="utf-8"))

try:
    import jsonschema
    from jsonschema.validators import Draft202012Validator
except ImportError:
    # Bare-machine fallback: jsonschema itself is unavailable, so fall back to
    # a structural check of the schema's own declared required fields.
    required = set(schema.get("required", []))
    missing = required - set(data)
    assert not missing, f"missing required top-level fields: {sorted(missing)}"
    assert data["status"] in {"complete", "partial", "stalled"}, data["status"]
else:
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
    assert not errors, "; ".join(e.message for e in errors)

# A mid-context-build kill has zero coverage and no findings -> "stalled".
assert data["status"] == "stalled", data["status"]
PY
}

# ---------------------------------------------------------------------------
# (c) Concurrency contract
# ---------------------------------------------------------------------------

@test "(c) N concurrent preflight --worktree runs get distinct worktrees/branches, leave the user's tree untouched, and N concurrent state.sh persist calls keep a correct run count with no lost lines" {
  local before_branch before_hash before_status
  before_branch="$(git -C "$REPO" symbolic-ref --short HEAD)"
  before_hash="$(_tree_hash "$REPO")"
  before_status="$(git -C "$REPO" status --porcelain)"

  local outdir="${BATS_TMP}/pf-outs"
  mkdir -p "$outdir"
  local n=5

  # --- Step 1: N preflight --worktree runs, started together. ---------------
  local pids="" i
  for i in $(seq 1 "$n"); do
    ( cd "$REPO" && bash "$PREFLIGHT_SH" --worktree > "${outdir}/out.${i}" 2>"${outdir}/err.${i}" ) &
    pids="$pids $!"
  done
  local rc=0
  for p in $pids; do
    wait "$p" || rc=1
  done
  [ "$rc" -eq 0 ]

  local run_dirs="" worktrees="" branches=""
  for i in $(seq 1 "$n"); do
    cat "${outdir}/out.${i}" >&2  # surfaced on failure via bats output capture
    grep -q "PREFLIGHT_OK" "${outdir}/out.${i}"
    local rd wt br
    rd="$(sed -n 's/^RUN_DIR=//p' "${outdir}/out.${i}")"
    wt="$(sed -n 's/^WORKTREE=//p' "${outdir}/out.${i}")"
    br="$(sed -n 's/^BRANCH=//p' "${outdir}/out.${i}")"
    [ -n "$rd" ]
    [ -n "$wt" ]
    [ -n "$br" ]
    [ -d "$wt" ]
    run_dirs="${run_dirs}${rd}"$'\n'
    worktrees="${worktrees}${wt}"$'\n'
    branches="${branches}${br}"$'\n'

    # Give each run's persist something concrete (and distinct) to harvest.
    _seed_recon_and_finding "$rd" "concurrency-file-${i}.txt"
  done

  local uniq_rd uniq_wt uniq_br
  uniq_rd="$(printf '%s' "$run_dirs"  | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  uniq_wt="$(printf '%s' "$worktrees" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  uniq_br="$(printf '%s' "$branches"  | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  [ "$uniq_rd" -eq "$n" ]
  [ "$uniq_wt" -eq "$n" ]
  [ "$uniq_br" -eq "$n" ]

  # The user's tree/branch must be exactly as it was — none of the N
  # concurrent worktree-mode runs touched it.
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = "$before_branch" ]
  [ "$(_tree_hash "$REPO")" = "$before_hash" ]
  [ "$(git -C "$REPO" status --porcelain)" = "$before_status" ]

  # --- Step 2: N concurrent `state.sh persist` calls against those N ---------
  # worktree-isolated run dirs (bugsweep-p74's mkdir-lock critical section
  # around meta.json's run counter).
  local persist_pids=""
  for i in $(seq 1 "$n"); do
    local rd
    rd="$(sed -n 's/^RUN_DIR=//p' "${outdir}/out.${i}")"
    ( bash "$STATE_SH" persist "$rd" > "${outdir}/persist.${i}.log" 2>&1 ) &
    persist_pids="$persist_pids $!"
  done
  local prc=0
  for p in $persist_pids; do
    wait "$p" || prc=1
  done
  [ "$prc" -eq 0 ]

  local meta="${REPO}/.bugsweep/state/meta.json"
  [ -f "$meta" ]
  local runs
  runs="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("runs",0))' "$meta")"
  [ "$runs" -eq "$n" ]

  local audit_log="${REPO}/.bugsweep/state/audit-log.jsonl"
  local risk_log="${REPO}/.bugsweep/state/risk.jsonl"
  [ -f "$audit_log" ]
  [ -f "$risk_log" ]

  # Every one of the N distinct files must show up in both logs — none lost.
  for i in $(seq 1 "$n"); do
    grep -q "\"concurrency-file-${i}.txt\"" "$audit_log"
    grep -q "\"concurrency-file-${i}.txt\"" "$risk_log"
  done

  # No torn/interleaved writes: every non-empty line in both logs parses as JSON.
  python3 - "$audit_log" "$risk_log" <<'PY'
import json
import sys

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            json.loads(line)  # raises if a line got torn/interleaved
PY

  local audit_lines risk_lines
  audit_lines="$(wc -l < "$audit_log" | tr -d ' ')"
  risk_lines="$(wc -l < "$risk_log" | tr -d ' ')"
  [ "$audit_lines" -eq "$n" ]
  [ "$risk_lines" -eq "$n" ]
}

# ---------------------------------------------------------------------------
# (d) Cleanup invariant
# ---------------------------------------------------------------------------

@test "(d) after a full worktree run, git worktree list has no leftover bugsweep worktrees and git worktree prune is a no-op" {
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir wt
  run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  wt="$(echo "$output" | sed -n 's/^WORKTREE=//p')"
  [ -n "$run_dir" ]
  [ -n "$wt" ]
  [ -d "$wt" ]

  # The ordinary shape of a "full run": some fix work landed on the run's own
  # branch inside the isolated worktree.
  printf 'fix\n' > "${wt}/fix.txt"
  git -C "$wt" add fix.txt
  git -C "$wt" commit -q -m "fix(bugsweep): full-run test commit"

  run bash "$FINALIZE_SH" "$run_dir"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]

  _assert_no_leftover_bugsweep_worktrees
}

@test "(d) after a killed run followed by the next run's preflight+finalize, git worktree list has no leftover bugsweep worktrees and git worktree prune is a no-op" {
  # Model a genuinely KILLED run: a worktree + branch exist (as
  # `preflight.sh --worktree` would have created), but the run then crashed —
  # its lease is stale-past-grace AND its ledger is quiescent (the same
  # "positive dead evidence" fixture idiom as tests/bats/cleanup.bats's
  # "stale dirty worktree" / "preflight --worktree reaps stale orphan" tests).
  git -C "$REPO" checkout -q -b "bugsweep/killed-run" main
  printf 'partial fix\n' > "${REPO}/killed.txt"
  git -C "$REPO" add killed.txt
  git -C "$REPO" commit -q -m "fix(bugsweep): killed run, never finalized"
  git -C "$REPO" checkout -q main

  local killed_wt="${REPO}/.bugsweep/worktrees/killed-run"
  mkdir -p "${REPO}/.bugsweep/worktrees"
  git -C "$REPO" worktree add -q "$killed_wt" "bugsweep/killed-run"

  local killed_run_dir="${REPO}/.bugsweep/run-killed-run"
  mkdir -p "$killed_run_dir"
  cat > "${killed_run_dir}/state.env" <<ENV
BUGSWEEP_TS=killed-run
BUGSWEEP_RUN_DIR=${killed_run_dir}
BUGSWEEP_BRANCH=bugsweep/killed-run
BUGSWEEP_ORIG_BRANCH=main
BUGSWEEP_STASH_REF=none
BUGSWEEP_START_EPOCH=1
BUGSWEEP_MODE=detect-only
BUGSWEEP_WORKTREE=${killed_wt}
BUGSWEEP_SCRIPT_DIR=$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts
ENV
  touch "${killed_run_dir}/ledger.jsonl"

  local leases="${REPO}/.bugsweep/state/leases"
  mkdir -p "$leases"
  printf '{"pid":999999,"run_dir":"%s","started":1}\n' "$killed_run_dir" > "${leases}/run-killed-run.json"
  touch -t 202001010000 "${leases}/run-killed-run.json" "${killed_run_dir}/ledger.jsonl"

  # The NEXT run: its own preflight --worktree call reaps the killed sibling
  # BEFORE creating its own worktree (bugsweep-8d0's documented three-wiring-
  # point contract: preflight, finalize, session-end sweep).
  # BUGSWEEP_REAP_MIN_AGE_SECONDS=0 waives only the worktree-dir age floor —
  # the stale-lease + quiescent-ledger evidence above is what actually
  # authorizes the reap (same override cleanup.bats's own "preflight
  # --worktree reaps stale orphan" test uses).
  run env BUGSWEEP_REAP_MIN_AGE_SECONDS=0 bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PREFLIGHT_OK"

  local next_run_dir next_wt
  next_run_dir="$(echo "$output" | sed -n 's/^RUN_DIR=//p')"
  next_wt="$(echo "$output" | sed -n 's/^WORKTREE=//p')"
  [ -n "$next_run_dir" ]
  [ -n "$next_wt" ]

  # The killed sibling is already gone — reaped during THIS preflight call,
  # before its own worktree was even created.
  [ ! -d "$killed_wt" ]

  # Complete the next run normally (a full run on top of the killed one).
  printf 'next fix\n' > "${next_wt}/next-fix.txt"
  git -C "$next_wt" add next-fix.txt
  git -C "$next_wt" commit -q -m "fix(bugsweep): next run after killed sibling"

  run bash "$FINALIZE_SH" "$next_run_dir"
  [ "$status" -eq 0 ]
  [ ! -d "$next_wt" ]

  _assert_no_leftover_bugsweep_worktrees
}
