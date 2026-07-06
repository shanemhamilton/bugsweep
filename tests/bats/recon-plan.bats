#!/usr/bin/env bats
#
# Tests for scripts/recon-plan.sh (bugsweep-e1r): the deterministic batch
# planner that lets prompts/context-build.md initialize recon.json from a
# file list BEFORE any modeling happens. Root cause under test (bead 2e5,
# "large repos fail silently"): context-build used to build repo-context.md
# + recon.json in one un-checkpointed pass, so a stall on a large repo left
# nothing on disk to resume, reprioritize, or report from. This script
# (bench/scorer/recon_plan.py's shell shim) must ALWAYS produce a valid
# recon-plan.json -- even simulating a process killed the instant after
# initialization -- so that artifact alone is enough to resume.

RECON_PLAN_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/recon-plan.sh"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  START_CWD="$(pwd)"
  BATS_TMP="$(mktemp -d)"
  RUN_DIR="${BATS_TMP}/run-dir"
  mkdir -p "$RUN_DIR"
}

teardown() {
  cd "$START_CWD"
  rm -rf "$BATS_TMP"
}

# Synthesize a "large" tree file list: N small files, each in its OWN
# top-level directory (recon-plan.sh's batches are per-top-level-dir, so this
# is what drives batch_count up alongside file_count), plus one documented
# sink-ish dir and one documented low-priority dir -- so the same fixture also
# exercises tier heuristics end-to-end through the shell entrypoint.
_make_large_file_list() {
  local out="$1" count="${2:-850}"
  : > "$out"
  local i=0
  while [ "$i" -lt "$count" ]; do
    printf 'module%s/file.py\n' "$i" >> "$out"
    i=$((i + 1))
  done
  printf 'auth/login.py\n' >> "$out"
  printf 'docs/readme.md\n' >> "$out"
}

# ---------------------------------------------------------------------------
# Acceptance criterion 1: interrupted-after-init still yields a resumable,
# valid recon.json (simulated: we just don't do any modeling after this step).
# ---------------------------------------------------------------------------

@test "recon-plan.sh: writes a valid recon-plan.json with >=1 batch from a file arg" {
  local file_list="${BATS_TMP}/files.txt"
  _make_large_file_list "$file_list" 850

  run bash "$RECON_PLAN_SH" "$RUN_DIR" "$file_list"
  [ "$status" -eq 0 ]

  local plan="${RUN_DIR}/recon-plan.json"
  [ -f "$plan" ]
  echo "$output" | grep -q "RECON_PLAN=${plan}"

  python3 -c "
import json
d = json.load(open('${plan}'))
assert d['batch_count'] >= 1, d['batch_count']
assert len(d['batches']) == d['batch_count']
assert d['covered'] == []
assert d['schema_version'] == 1
"
}

@test "recon-plan.sh: accepts the file list on stdin (no FILE_LIST_PATH arg)" {
  local file_list="${BATS_TMP}/files.txt"
  _make_large_file_list "$file_list" 10

  run bash -c "cat '${file_list}' | bash '${RECON_PLAN_SH}' '${RUN_DIR}'"
  [ "$status" -eq 0 ]

  local plan="${RUN_DIR}/recon-plan.json"
  [ -f "$plan" ]
  python3 -c "
import json
d = json.load(open('${plan}'))
assert d['files_in_scope'] == 12, d['files_in_scope']
"
}

# This is the literal acceptance criterion: "simulate interruption: just don't
# do any modeling" -- i.e. after this ONE step runs, the artifact already
# exists and is valid, with no further steps required for it to be usable.
@test "recon-plan.sh: artifact exists and is valid immediately after the init step (simulated interruption)" {
  local file_list="${BATS_TMP}/files.txt"
  _make_large_file_list "$file_list" 850

  bash "$RECON_PLAN_SH" "$RUN_DIR" "$file_list" >/dev/null

  # Simulate "the process was killed right after initialization" by doing
  # nothing further and just inspecting what's on disk.
  local plan="${RUN_DIR}/recon-plan.json"
  [ -f "$plan" ]
  [ -s "$plan" ]

  python3 -c "
import json
d = json.load(open('${plan}'))
assert d['batch_count'] >= 1
assert all('id' in b and 'dir' in b and 'tier' in b and 'files' in b and 'deferred' in b for b in d['batches'])
"
}

# ---------------------------------------------------------------------------
# large_repo_mode + deferred cap wiring, exercised end-to-end via the shell entrypoint
# ---------------------------------------------------------------------------

@test "recon-plan.sh: activates large_repo_mode above the configured file threshold" {
  local file_list="${BATS_TMP}/files.txt"
  _make_large_file_list "$file_list" 850  # > default threshold of 800

  run bash "$RECON_PLAN_SH" "$RUN_DIR" "$file_list"
  [ "$status" -eq 0 ]

  python3 -c "
import json
d = json.load(open('${RUN_DIR}/recon-plan.json'))
assert d['large_repo_mode'] is True, d['large_repo_mode']
assert d['budget_batches'] is not None
assert any(b['deferred'] for b in d['batches']), 'expected at least one deferred batch'
"
}

@test "recon-plan.sh: no large_repo_mode below the configured file threshold" {
  local file_list="${BATS_TMP}/files.txt"
  _make_large_file_list "$file_list" 5

  run bash "$RECON_PLAN_SH" "$RUN_DIR" "$file_list"
  [ "$status" -eq 0 ]

  python3 -c "
import json
d = json.load(open('${RUN_DIR}/recon-plan.json'))
assert d['large_repo_mode'] is False, d['large_repo_mode']
assert d['budget_batches'] is None
assert all(not b['deferred'] for b in d['batches'])
"
}

# ---------------------------------------------------------------------------
# Determinism through the shell entrypoint (not just the pure python function)
# ---------------------------------------------------------------------------

@test "recon-plan.sh: produces a byte-identical plan across repeated runs" {
  local file_list="${BATS_TMP}/files.txt"
  _make_large_file_list "$file_list" 30

  local run_dir_2="${BATS_TMP}/run-dir-2"
  mkdir -p "$run_dir_2"

  bash "$RECON_PLAN_SH" "$RUN_DIR" "$file_list" >/dev/null
  bash "$RECON_PLAN_SH" "$run_dir_2" "$file_list" >/dev/null

  diff "${RUN_DIR}/recon-plan.json" "${run_dir_2}/recon-plan.json"
}

# ---------------------------------------------------------------------------
# Tier 2 degraded path: no python3 -> still produces a valid, non-empty plan.
# ---------------------------------------------------------------------------

@test "recon-plan.sh: degraded (no python3) path still writes a valid single-batch-per-dir plan" {
  local file_list="${BATS_TMP}/files.txt"
  _make_large_file_list "$file_list" 20

  # Simulate a bare machine: shadow python3 with a PATH that doesn't have it
  # (same mechanism tests/bats/summarize.bats already uses).
  local fakebin="${BATS_TMP}/fakebin"
  mkdir -p "$fakebin"
  for tool in bash git grep sed cat mkdir date tr wc head cut basename dirname mktemp rm cp mv find true false printf test env sh sort; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "${fakebin}/${tool}"
  done

  PATH="$fakebin" run bash "$RECON_PLAN_SH" "$RUN_DIR" "$file_list"
  [ "$status" -eq 0 ]

  local plan="${RUN_DIR}/recon-plan.json"
  [ -f "$plan" ]

  # python3 IS available in the test environment itself (only the invocation
  # above ran under the fake PATH), so validate the output here.
  python3 -c "
import json
d = json.load(open('${plan}'))
assert d['schema_version'] == 1
assert d['batch_count'] >= 1
assert d['covered'] == []
# degraded plan is one batch per top-level dir, and tiers must be a valid enum
# (the degraded path now ports the same critical/normal/low heuristic as the
# python planner -- see the dedicated ordering test below).
assert all(b['tier'] in ('critical', 'normal', 'low') for b in d['batches'])
total_files = sum(len(b['files']) for b in d['batches'])
assert total_files == d['files_in_scope'] == 22, (total_files, d['files_in_scope'])
"
}

# MAJOR 3 (bugsweep-e1r review): the degraded (no-python3) fallback must ALSO
# tier -- a python3-less cold-start box previously sorted payments/ alongside
# zzz-legacy/ with no signal, and on a first run there's no prior-coverage.json
# sink backstop either. The shell fallback ports the same SINK_DIR_HINTS /
# LOW_PRIORITY_DIR_HINTS heuristic, so auth/api sort critical (ahead of) docs/assets.
@test "recon-plan.sh: degraded (no python3) path tiers auth/api ahead of docs/assets" {
  local file_list="${BATS_TMP}/files.txt"
  cat > "$file_list" <<'FILES'
auth/login.py
api/routes.py
docs/readme.md
assets/logo.png
src/util.py
FILES

  local fakebin="${BATS_TMP}/fakebin"
  mkdir -p "$fakebin"
  for tool in bash git grep sed cat mkdir date tr wc head cut basename dirname mktemp rm cp mv find true false printf test env sh sort; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "${fakebin}/${tool}"
  done

  PATH="$fakebin" run bash "$RECON_PLAN_SH" "$RUN_DIR" "$file_list"
  [ "$status" -eq 0 ]

  python3 -c "
import json
d = json.load(open('${RUN_DIR}/recon-plan.json'))
by_dir = {b['dir']: b['tier'] for b in d['batches']}
assert by_dir['auth'] == 'critical', by_dir
assert by_dir['api'] == 'critical', by_dir
assert by_dir['docs'] == 'low', by_dir
assert by_dir['assets'] == 'low', by_dir
assert by_dir['src'] == 'normal', by_dir
# ordering: critical batches before normal before low (deterministic total order)
rank = {'critical': 0, 'normal': 1, 'low': 2}
tiers = [b['tier'] for b in d['batches']]
assert tiers == sorted(tiers, key=lambda t: rank[t]), tiers
# and within a tier, dir-name ascending (auth before api)
crit_dirs = [b['dir'] for b in d['batches'] if b['tier'] == 'critical']
assert crit_dirs == sorted(crit_dirs), crit_dirs
"
}

# ---------------------------------------------------------------------------
# exclude_globs are honored (config-driven, matching the rest of bugsweep)
# ---------------------------------------------------------------------------

@test "recon-plan.sh: respects exclude_globs from config/bugsweep.config.json" {
  local file_list="${BATS_TMP}/files.txt"
  cat > "$file_list" <<'FILES'
src/app.py
node_modules/pkg/index.js
dist/bundle.js
.git/HEAD
src/x.min.js
FILES

  run bash "$RECON_PLAN_SH" "$RUN_DIR" "$file_list"
  [ "$status" -eq 0 ]

  python3 -c "
import json
d = json.load(open('${RUN_DIR}/recon-plan.json'))
all_files = [f for b in d['batches'] for f in b['files']]
assert 'node_modules/pkg/index.js' not in all_files
assert 'dist/bundle.js' not in all_files
assert '.git/HEAD' not in all_files
assert 'src/x.min.js' not in all_files
assert 'src/app.py' in all_files
assert d['files_in_scope'] == 1, d['files_in_scope']
"
}

# MAJOR (bugsweep-e1r review, retry 2): the degraded-path `sort` collates the
# dir-name tie-break key by the ambient LC_COLLATE. Under a UTF-8 locale (common
# macOS/CI default) that is CASE-INSENSITIVE-ish, diverging from Python's always-
# codepoint sorted(): mixed-case dirs order differently, breaking both the
# "identical tiering to python" claim (on ORDER) and cross-machine determinism.
# The fix pins LC_ALL=C on the degraded sorts so bash collation == codepoint.
# This test forces a UTF-8 locale and asserts degraded batch order == python order.
@test "recon-plan.sh: degraded path batch order matches python under a UTF-8 locale (mixed-case dirs)" {
  local file_list="${BATS_TMP}/files.txt"
  # Mixed-case, same-tier (all 'normal') top-level dirs: codepoint order is
  # Banana, Zebra, alpha, apple (uppercase < lowercase); a UTF-8 locale would
  # instead give alpha, apple, Banana, Zebra.
  cat > "$file_list" <<'FILES'
Zebra/a.py
apple/b.py
Banana/c.py
alpha/d.py
FILES

  # Reference: the python (Tier 1) path, in the SAME (UTF-8) locale. Python's
  # sorted() is codepoint-based regardless of locale, so this is the ground truth.
  local run_py="${BATS_TMP}/run-py"
  mkdir -p "$run_py"
  LC_ALL=en_US.UTF-8 run bash "$RECON_PLAN_SH" "$run_py" "$file_list"
  [ "$status" -eq 0 ]

  # Degraded (no-python3) path, under the SAME UTF-8 locale. Must still match.
  local fakebin="${BATS_TMP}/fakebin"
  mkdir -p "$fakebin"
  for tool in bash git grep sed cat mkdir date tr wc head cut basename dirname mktemp rm cp mv find true false printf test env sh sort; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "${fakebin}/${tool}"
  done

  LC_ALL=en_US.UTF-8 PATH="$fakebin" run bash "$RECON_PLAN_SH" "$RUN_DIR" "$file_list"
  [ "$status" -eq 0 ]

  # python3 IS available in the test env itself; compare the ordered dir lists.
  python3 -c "
import json
py = json.load(open('${run_py}/recon-plan.json'))
deg = json.load(open('${RUN_DIR}/recon-plan.json'))
py_dirs = [b['dir'] for b in py['batches']]
deg_dirs = [b['dir'] for b in deg['batches']]
# Ground-truth codepoint order for these same-tier dirs.
assert py_dirs == ['Banana', 'Zebra', 'alpha', 'apple'], py_dirs
assert deg_dirs == py_dirs, ('degraded order diverges from python under UTF-8 locale', deg_dirs, py_dirs)
"
}

# Cross-machine determinism: the degraded path must produce the SAME order under
# C and UTF-8 locales (i.e. the sort is locale-pinned, not ambient).
@test "recon-plan.sh: degraded path order is locale-invariant (C == UTF-8)" {
  local file_list="${BATS_TMP}/files.txt"
  cat > "$file_list" <<'FILES'
Zebra/a.py
apple/b.py
Banana/c.py
alpha/d.py
FILES

  local fakebin="${BATS_TMP}/fakebin"
  mkdir -p "$fakebin"
  for tool in bash git grep sed cat mkdir date tr wc head cut basename dirname mktemp rm cp mv find true false printf test env sh sort; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "${fakebin}/${tool}"
  done

  local run_c="${BATS_TMP}/run-c" run_utf="${BATS_TMP}/run-utf"
  mkdir -p "$run_c" "$run_utf"
  LC_ALL=C          PATH="$fakebin" bash "$RECON_PLAN_SH" "$run_c"   "$file_list" >/dev/null
  LC_ALL=en_US.UTF-8 PATH="$fakebin" bash "$RECON_PLAN_SH" "$run_utf" "$file_list" >/dev/null

  diff "${run_c}/recon-plan.json" "${run_utf}/recon-plan.json"
}
