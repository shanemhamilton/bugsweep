#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
# Current source-bound integration contract. These fixtures use real Git only;
# provider execution is exercised in bench/tests/unit/test_integration_checks.py.

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
INTEGRATE_SH="${ROOT}/scripts/integrate.sh"

setup() {
  TMP="$(mktemp -d)"; REPO="${TMP}/repo"; RUN_DIR="${TMP}/run"
  HELPER="${TMP}/helper"; mkdir -p "$HELPER" "$RUN_DIR"; cp "${ROOT}/scripts/integrate.sh" "${HELPER}/integrate.sh"
  cat >"${HELPER}/_integration_checks.py" <<'PY'
import argparse, hashlib, json, pathlib, sys
p=argparse.ArgumentParser(); p.add_argument('--run-dir'); p.add_argument('--repo-root'); p.add_argument('--merge-sha'); p.add_argument('--branch'); p.add_argument('--git-path'); a=p.parse_args()
if pathlib.Path(a.git_path).is_symlink(): sys.exit(2)
if a.branch.endswith('/bad'): sys.exit(1)
d=pathlib.Path(a.run_dir)/'integration-check-results'; d.mkdir(exist_ok=True)
n=f'{a.merge_sha}-{hashlib.sha256(a.branch.encode()).hexdigest()[:16]}.json'
(d/n).write_text(json.dumps({'status':'verified','merge_sha':a.merge_sha,'branch':a.branch,'source_manifest_sha256':'0'*64}))
PY
  git init -q "$REPO"; git -C "$REPO" config user.email test@bugsweep; git -C "$REPO" config user.name bugsweep-test
  printf 'base\n' >"${REPO}/app.txt"; git -C "$REPO" add app.txt; git -C "$REPO" commit -qm init; git -C "$REPO" branch -M main
  git -C "$REPO" checkout -qb bugsweep/fix
  printf 'fixed\n' >"${REPO}/fix.txt"; git -C "$REPO" add fix.txt; git -C "$REPO" commit -qm fix
  git -C "$REPO" checkout -q main; printf '{}' >"${RUN_DIR}/check-plan.json"; printf '{}' >"${RUN_DIR}/baseline.json"
}

_branch() { git -C "$REPO" checkout -qb "$1" main; printf '%s\n' "$2" >"${REPO}/$3"; git -C "$REPO" add "$3"; git -C "$REPO" commit -qm "$1"; git -C "$REPO" checkout -q main; }

teardown() { rm -rf "$TMP"; }

@test "integrate: requires a run directory with frozen source-bound evidence" {
  run bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/fix' _ "$REPO" "$INTEGRATE_SH" "${TMP}/missing"
  [ "$status" -eq 2 ]
  [[ "$output" == *"lacks frozen check-plan.json"* ]]
}

@test "integrate: refusal preserves target, source, and checked-out head" {
  target="$(git -C "$REPO" rev-parse main)"; source="$(git -C "$REPO" rev-parse bugsweep/fix)"
  run bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/fix' _ "$REPO" "$INTEGRATE_SH" "$RUN_DIR"
  [ "$status" -ne 0 ]
  [ "$(git -C "$REPO" rev-parse main)" = "$target" ]
  [ "$(git -C "$REPO" rev-parse bugsweep/fix)" = "$source" ]
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = main ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}

@test "integrate: legacy host override cannot bypass the frozen provider plan" {
  # shellcheck disable=SC2016 # $1..$3 expand in bash -c, not this test shell.
  run env BUGSWEEP_QUALITY_GATE_COMMAND=true bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/fix' _ "$REPO" "$INTEGRATE_SH" "${TMP}/missing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lacks frozen check-plan.json"* ]]
}

@test "integrate: source declares the frozen provider gate and no legacy evaluation" {
  grep -Fq 'QUALITY_GATE_COMMAND="provider:frozen-check-plan"' "$INTEGRATE_SH"
  grep -Fq 'ignoring legacy BUGSWEEP_QUALITY_GATE_COMMAND' "$INTEGRATE_SH"
}

@test "integrate: explicit target and branch remain required" {
  run bash -c 'cd "$1" && bash "$2"' _ "$REPO" "$INTEGRATE_SH"
  [ "$status" -eq 2 ]
  run bash -c 'cd "$1" && bash "$2" main' _ "$REPO" "$INTEGRATE_SH"
  [ "$status" -eq 2 ]
}

@test "integrate: ordered real-Git merges advance the target only after provider success" {
  _branch bugsweep/one one one.txt; _branch bugsweep/two two two.txt
  run bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/one bugsweep/two' _ "$REPO" "${HELPER}/integrate.sh" "$RUN_DIR"
  [ "$status" -eq 0 ]; [[ "$output" == *'MERGED_COUNT=2'* ]]; [ -f "${REPO}/one.txt" ]; [ -f "${REPO}/two.txt" ]
}

@test "integrate: a PATH git symlink is canonicalized for the trusted provider" {
  mkdir "${TMP}/git-bin"; ln -s "$(command -v git)" "${TMP}/git-bin/git"
  run env PATH="${TMP}/git-bin:${PATH}" bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/fix' _ "$REPO" "${HELPER}/integrate.sh" "$RUN_DIR"
  [ "$status" -eq 0 ]; [[ "$output" == *'bugsweep/fix:merged'* ]]
}

@test "integrate: provider failure preserves the bad and remaining branches after prior success" {
  _branch bugsweep/good good good.txt; _branch bugsweep/bad bad bad.txt; _branch bugsweep/later later later.txt
  run bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/good bugsweep/bad bugsweep/later' _ "$REPO" "${HELPER}/integrate.sh" "$RUN_DIR"
  [ "$status" -eq 1 ]; [[ "$output" == *'bugsweep/good:merged'* ]]; [[ "$output" == *'bugsweep/bad:gate_failed'* ]]; [ -f "${REPO}/good.txt" ]; [ ! -f "${REPO}/bad.txt" ]; git -C "$REPO" show-ref --verify --quiet refs/heads/bugsweep/later
}

@test "integrate: textual conflict after a good sibling preserves the last good target and later refs" {
  _branch bugsweep/good good good.txt
  git -C "$REPO" checkout -qb bugsweep/conflict main; printf 'branch\n' >"${REPO}/app.txt"; git -C "$REPO" add app.txt; git -C "$REPO" commit -qm conflict; git -C "$REPO" checkout -q main
  printf 'target\n' >"${REPO}/app.txt"; git -C "$REPO" add app.txt; git -C "$REPO" commit -qm target
  _branch bugsweep/later later later.txt
  run bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/good bugsweep/conflict bugsweep/later' _ "$REPO" "${HELPER}/integrate.sh" "$RUN_DIR"
  [ "$status" -eq 1 ]; [[ "$output" == *'bugsweep/good:merged'* ]]; [[ "$output" == *'bugsweep/conflict:conflict'* ]]; [[ "$output" == *'bugsweep/later:skipped_after_stop'* ]]; [[ "$output" == *'MERGED_COUNT=1'* ]]; [[ "$output" == *'PRESERVED_COUNT=2'* ]]
  [ -f "${REPO}/good.txt" ]; [ ! -f "${REPO}/later.txt" ]; git -C "$REPO" show-ref --verify --quiet refs/heads/bugsweep/conflict; git -C "$REPO" show-ref --verify --quiet refs/heads/bugsweep/later
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = main ]; [ ! -f "${REPO}/.git/MERGE_HEAD" ]
}

@test "integrate: already-contained branch is re-gated without another merge" {
  _branch bugsweep/one one one.txt
  bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/one' _ "$REPO" "${HELPER}/integrate.sh" "$RUN_DIR"
  RUN_DIR="${TMP}/run-two"; mkdir "$RUN_DIR"; printf '{}' >"${RUN_DIR}/check-plan.json"; printf '{}' >"${RUN_DIR}/baseline.json"
  run bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/one' _ "$REPO" "${HELPER}/integrate.sh" "$RUN_DIR"
  [ "$status" -eq 0 ]; [[ "$output" == *'already_contained'* ]]; [[ "$output" == *'ALREADY_CONTAINED_COUNT=1'* ]]
}

@test "integrate: dirty-tree refusal preserves the source branch" {
  printf 'dirty\n' >"${REPO}/dirty.txt"; source="$(git -C "$REPO" rev-parse bugsweep/fix)"
  run bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/fix' _ "$REPO" "${HELPER}/integrate.sh" "$RUN_DIR"
  [ "$status" -eq 2 ]; [ "$(git -C "$REPO" rev-parse bugsweep/fix)" = "$source" ]
}

@test "integrate: update-ref CAS failure is reported without advancing the target" {
  _branch bugsweep/cas cas cas.txt; before="$(git -C "$REPO" rev-parse main)"; mkdir "${TMP}/bin"
  real="$(command -v git)"; printf '#!/usr/bin/env bash\n[ "$1" = update-ref ] && exit 1\nexec "%s" "$@"\n' "$real" >"${TMP}/bin/git"; chmod +x "${TMP}/bin/git"
  run env PATH="${TMP}/bin:${PATH}" bash -c 'cd "$1" && bash "$2" --run-dir "$3" main bugsweep/cas' _ "$REPO" "${HELPER}/integrate.sh" "$RUN_DIR"
  [ "$status" -eq 1 ]; [[ "$output" == *'update_failed'* ]]; [ "$(git -C "$REPO" rev-parse main)" = "$before" ]
}
