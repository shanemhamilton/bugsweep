#!/usr/bin/env bats

SKILL_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PREFLIGHT_SH="${SKILL_ROOT}/scripts/preflight.sh"
SYMBOLS_SH="${SKILL_ROOT}/scripts/symbols.sh"
GRAPH_SH="${SKILL_ROOT}/scripts/graph.sh"
REACH_SH="${SKILL_ROOT}/scripts/reachability.sh"
CONCLUSIONS_SH="${SKILL_ROOT}/scripts/conclusions.sh"

setup() {
  BATS_TMP="$(mktemp -d "${BATS_TEST_TMPDIR}/source-identity.XXXXXX")"
  REPO="${BATS_TMP}/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email test@bugsweep
  git -C "$REPO" config user.name bugsweep-test
  git -C "$REPO" checkout -q -b main
  mkdir -p "${REPO}/src"
  printf '%s\n' '@app.route("/")' 'def handler():' '    sink()' 'def helper():' '    return 1' 'def sink():' '    import os' '    os.system("x")' > "${REPO}/src/app.py"
  git -C "$REPO" add src/app.py
  git -C "$REPO" commit -q -m initial
  cd "$REPO"
}

teardown() {
  cd /tmp
  rm -rf "$BATS_TMP"
}

@test "worktree preflight binds indexes to the audited worktree root" {
  printf '%s\n' '# dirty main only' >> "${REPO}/src/app.py"
  run bash "$PREFLIGHT_SH" --worktree
  [ "$status" -eq 0 ]
  local run_dir wt index manifest
  run_dir="$(printf '%s\n' "$output" | sed -n 's/^RUN_DIR=//p')"
  wt="$(printf '%s\n' "$output" | sed -n 's/^WORKTREE=//p')"
  index="${run_dir}/indexes/symbol-index.jsonl"
  manifest="${run_dir}/indexes/symbol-index.manifest.json"
  [ -f "$index" ]
  [ -f "$manifest" ]
  grep -q "BUGSWEEP_TARGET_ROOT='${wt}'" "${run_dir}/state.env"
  python3 - "$index" "$manifest" "$wt" "${REPO}" <<'PY'
import hashlib, json, sys
index, manifest, target, main = sys.argv[1:]
identity = json.load(open(manifest))
assert identity["source_root"] == target, identity
rows = [json.loads(line) for line in open(index) if line.strip()]
app = next(row for row in rows if row.get("symbol_id") == "src/app.py")
target_hash = hashlib.sha256(open(target + "/src/app.py", "rb").read()).hexdigest()[:12]
main_hash = hashlib.sha256(open(main + "/src/app.py", "rb").read()).hexdigest()[:12]
assert app["hash"] == target_hash, (app, target_hash)
assert app["hash"] != main_hash, (app, main_hash)
PY
}

@test "common resolves shared state from a repository subdirectory" {
  run bash -c 'cd "$1/src" && . "$2/scripts/common.sh" && printf "%s\\n" "$BUGSWEEP_REPO_ROOT"' \
    _ "$REPO" "$SKILL_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "common keeps a symlinked checkout's logical shared root while target identity stays physical" {
  local alias="${BATS_TMP}/repo-alias"
  ln -s "$REPO" "$alias"
  run bash -c 'cd "$1/src" && . "$2/scripts/common.sh" && printf "%s\\n%s\\n" "$BUGSWEEP_REPO_ROOT" "$BUGSWEEP_TARGET_ROOT"' \
    _ "$alias" "$SKILL_ROOT"
  [ "$status" -eq 0 ]
  local shared_root target_root
  shared_root="$(printf '%s\n' "$output" | sed -n '1p')"
  target_root="$(printf '%s\n' "$output" | sed -n '2p')"
  [ "$shared_root" = "$alias" ]
  [ "$(cd "$target_root" && pwd -P)" = "$(cd "$REPO" && pwd -P)" ]
}

@test "preflight honors an explicit target when launched elsewhere" {
  run bash -c 'cd "$1" && env BUGSWEEP_TARGET_ROOT="$2" bash "$3" --worktree' \
    _ "$SKILL_ROOT" "$REPO" "$PREFLIGHT_SH"
  [ "$status" -eq 0 ]
  local target
  target="$(printf '%s\n' "$output" | sed -n 's/^TARGET_ROOT=//p')"
  [ -n "$target" ]
  local target_real repo_real
  target_real="$(cd "$target" && pwd -P)"
  repo_real="$(cd "$REPO" && pwd -P)"
  case "$target_real" in
    "$repo_real"/.bugsweep/worktrees/*) ;;
    *) false ;;
  esac
  git -C "$target" rev-parse --show-toplevel >/dev/null
  [ "$(cd "$(git -C "$target" rev-parse --show-toplevel)" && pwd -P)" = "$target_real" ]
}

@test "source manifest is unavailable when a tracked file is missing" {
  rm -f "${REPO}/src/app.py"
  run env BUGSWEEP_TARGET_ROOT="$REPO" bash -c \
    '. "$1/scripts/common.sh"; bugsweep_source_manifest_hash "$2"' \
    _ "$SKILL_ROOT" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env BUGSWEEP_NO_PYTHON=1 BUGSWEEP_TARGET_ROOT="$REPO" bash -c \
    '. "$1/scripts/common.sh"; bugsweep_source_manifest_hash "$2"' \
    _ "$SKILL_ROOT" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "manifest rejects a replaced artifact payload" {
  local run_dir="${REPO}/.bugsweep/run-manifest" index
  index="${run_dir}/indexes"
  mkdir -p "$index"
  printf '%s\n' 'first' > "${index}/sample.jsonl"
  run env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" BUGSWEEP_INDEX_DIR="$index" bash -c \
    '. "$1/scripts/common.sh"; bugsweep_write_index_manifest sample "$1/scripts/common.sh"' \
    _ "$SKILL_ROOT"
  [ "$status" -eq 0 ]
  printf '%s\n' 'replaced' > "${index}/sample.jsonl"
  run env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" BUGSWEEP_INDEX_DIR="$index" bash -c \
    '. "$1/scripts/common.sh"; bugsweep_index_manifest_current sample "$1/scripts/common.sh"' \
    _ "$SKILL_ROOT"
  [ "$status" -ne 0 ]
}

@test "symbol lookup refuses an index after audited source changes" {
  local run_dir="${REPO}/.bugsweep/run-lookup"
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$SYMBOLS_SH" build
  run env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$SYMBOLS_SH" lookup 'src/app.py:sink'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local previous="$output"
  printf '%s\n' '# changed after indexing' >> "${REPO}/src/app.py"
  run env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$SYMBOLS_SH" lookup 'src/app.py:sink'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$SYMBOLS_SH" stale 'src/app.py:sink' "$previous"
  [ "$status" -eq 0 ]
}

@test "reachability manifest rejects changed upstream graph facts" {
  local run_dir="${REPO}/.bugsweep/run-upstream"
  mkdir -p "${run_dir}/indexes"
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$SYMBOLS_SH" build >/dev/null
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$GRAPH_SH" build >/dev/null
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$REACH_SH" build >/dev/null
  printf '%s\n' '{"kind":"call","src":"src/app.py:handler","dst":"src/app.py:sink","resolved":"strong"}' >> \
    "${run_dir}/indexes/graph.jsonl"
  run env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$REACH_SH" rank "$run_dir"
  [ "$status" -eq 0 ]
  python3 - "${run_dir}/exposure.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value.get("degraded") is True, value
assert value.get("files") == [], value
PY
}

@test "stale artifact generation degrades ranking instead of reusing another source" {
  local run_dir="${REPO}/.bugsweep/run-stale"
  mkdir -p "${run_dir}/indexes"
  printf '%s\n' '{"sink":"src/app.py:sink","file":"src/app.py","class":"exec","bucket":"LIVE","path_hash":"old"}' > "${run_dir}/indexes/sink-reachability.jsonl"
  printf '%s\n' '{"schema_version":1,"source_root":"/other/source","tree":"old","source_manifest_sha256":"old","config_sha256":"old","extractor_sha256":"old"}' > "${run_dir}/indexes/sink-reachability.manifest.json"
  run env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$REACH_SH" rank "$run_dir"
  [ "$status" -eq 0 ]
  python3 - "${run_dir}/exposure.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value.get("degraded") is True, value
assert value.get("files") == [], value
PY
}

@test "path hash changes for an edge between existing nodes and entry-only changes" {
  local run_dir="${REPO}/.bugsweep/run-path"
  mkdir -p "${run_dir}/indexes"
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$SYMBOLS_SH" build
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$GRAPH_SH" build
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$REACH_SH" build
  local first
  first="$(python3 - "${run_dir}/indexes/sink-reachability.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    value = json.loads(line)
    if value.get("sink", "").endswith(":sink"):
        print(value["path_hash"])
        break
PY
)"
  [ -n "$first" ]

  awk '{print} /^    sink\(\)$/ {print "    helper()"}' "${REPO}/src/app.py" > "${REPO}/src/app.py.tmp"
  mv "${REPO}/src/app.py.tmp" "${REPO}/src/app.py"
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$SYMBOLS_SH" build
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$GRAPH_SH" build
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$REACH_SH" build
  local second
  second="$(python3 - "${run_dir}/indexes/sink-reachability.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    value = json.loads(line)
    if value.get("sink", "").endswith(":sink"):
        print(value["path_hash"])
        break
PY
)"
  [ "$second" != "$first" ]

  sed -i.bak '/^@app.route/d' "${REPO}/src/app.py"
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$SYMBOLS_SH" build
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$GRAPH_SH" build
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$REACH_SH" build
  local third
  third="$(python3 - "${run_dir}/indexes/sink-reachability.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    value = json.loads(line)
    if value.get("sink", "").endswith(":sink"):
        print(value["path_hash"])
        break
PY
)"
  [ "$third" != "$second" ]

  printf '%s\n' '{"schema":1,"files":[]}' > "${run_dir}/exposure.json"
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$CONCLUSIONS_SH" add 'src/app.py:sink' exec 'safe' >/dev/null
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$CONCLUSIONS_SH" prime "$run_dir" >/dev/null
  [ ! -s "${run_dir}/reopened-conclusions.txt" ]
  # Add a directed edge between existing nodes without changing the sink body.
  # Reopening must follow the path hash rather than the sink's content hash.
  awk '{print} /^def helper\(\):$/ {print "    sink()"}' "${REPO}/src/app.py" > "${REPO}/src/app.py.tmp"
  mv "${REPO}/src/app.py.tmp" "${REPO}/src/app.py"
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$SYMBOLS_SH" build
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$GRAPH_SH" build
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$REACH_SH" build
  env BUGSWEEP_TARGET_ROOT="$REPO" BUGSWEEP_RUN_DIR="$run_dir" bash "$CONCLUSIONS_SH" prime "$run_dir" >/dev/null
  grep -qx 'src/app.py' "${run_dir}/reopened-conclusions.txt"
}
