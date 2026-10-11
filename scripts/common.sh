#!/usr/bin/env bash
# bugsweep common helpers. Sourced by the other scripts.
# Kept POSIX/bash-3.2 friendly so it runs on stock macOS bash.

set -euo pipefail

# Resolve the skill root (directory that contains this scripts/ folder).
BUGSWEEP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUGSWEEP_ROOT="$(cd "${BUGSWEEP_SCRIPT_DIR}/.." && pwd)"
BUGSWEEP_CONFIG="${BUGSWEEP_ROOT}/config/bugsweep.config.json"

log()  { printf '[bugsweep] %s\n' "$*" >&2; }
die()  { printf '[bugsweep][FATAL] %s\n' "$*" >&2; exit 1; }

# Read a value from the JSON config. Works with jq, else python3, else a grep
# fallback for simple scalars — so the config is honored even on a bare machine.
# Usage: cfg_get '.caps.max_iterations' 'default'
cfg_get() {
  local path="$1" default="${2:-}"
  [ -f "$BUGSWEEP_CONFIG" ] || { printf '%s' "$default"; return 0; }

  # Tier 1: jq (handles everything, including '| join(" ")').
  if command -v jq >/dev/null 2>&1; then
    local v; v="$(jq -r "$path // empty" "$BUGSWEEP_CONFIG" 2>/dev/null || true)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    printf '%s' "$default"; return 0
  fi

  # Tier 2: python3. Translate the limited dotted-path dialect we use.
  if command -v python3 >/dev/null 2>&1; then
    local v
    v="$(BSW_PATH="$path" python3 - "$BUGSWEEP_CONFIG" <<'PY' 2>/dev/null || true
import json,os,sys
p=os.environ["BSW_PATH"].strip()
data=json.load(open(sys.argv[1]))
join=False
if p.endswith('| join(" ")'):
    join=True; p=p.split("|")[0].strip()
cur=data
for part in [s for s in p.lstrip(".").split(".") if s]:
    if isinstance(cur,dict) and part in cur: cur=cur[part]
    else: cur=None; break
if cur is None: print("",end="")
elif join and isinstance(cur,list): print(" ".join(str(x) for x in cur),end="")
elif isinstance(cur,(list,dict)): print(json.dumps(cur),end="")
else: print(cur,end="")
PY
)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    printf '%s' "$default"; return 0
  fi

  # Tier 3: grep fallback for a flat scalar leaf (e.g. .caps.max_iterations -> max_iterations).
  local leaf v
  leaf="$(printf '%s' "$path" | sed 's/.*\.//')"
  v="$(grep -o "\"${leaf}\"[[:space:]]*:[[:space:]]*[^,}]*" "$BUGSWEEP_CONFIG" 2>/dev/null \
        | head -1 | sed 's/.*:[[:space:]]*//; s/^"//; s/"$//')"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  printf '%s' "$default"
}

require_git_repo() {
  command -v git >/dev/null 2>&1 || die "git is not installed."
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "Not inside a git repository. bugsweep only runs in a git repo so it can quarantine all changes safely."
}

current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "DETACHED"
}

# Count ledger events matching an event name. ALWAYS prints exactly one integer,
# even on zero matches or a missing file. (grep -c prints 0 AND exits non-zero on
# no match, so a naive '|| echo 0' double-counts and breaks integer comparisons.)
count_event() {
  local file="$1" name="$2" n
  n="$(grep -c "\"event\":\"${name}\"" "$file" 2>/dev/null || true)"
  case "$n" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$n" ;;
  esac
}

# Line count of a file, or 0 if missing/empty/unreadable. Always prints exactly one integer
# (the JSONL state files end every record with a newline, so this counts records).
bugsweep_count_lines() {
  local file="${1:-}" n
  [ -f "$file" ] || { printf '0'; return 0; }
  n="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
  case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

# Count lines of <file> matching extended-regex <pattern>, or 0. Always prints one integer
# (grep -c exits non-zero AND prints 0 on no match, which a naive '|| echo 0' double-counts).
bugsweep_grep_count() {
  local pattern="${1:-}" file="${2:-}" n
  { [ -n "$pattern" ] && [ -f "$file" ]; } || { printf '0'; return 0; }
  n="$(grep -cE "$pattern" "$file" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

# Refuse any operation that would touch a remote. Defense in depth: the scripts
# never call push/fetch, but this makes the intent explicit and greppable.
assert_no_remote_op() { :; }

# --- Cross-run state location + shared helpers --------------------------------
# Used by state.sh / variants.sh / symbols.sh. Anchored to the audited repo's root
# so cross-run state is ALWAYS project-scoped and stable across CWD/branch changes.
# There is deliberately NO pwd fallback: outside a git repo the state dir is left
# empty and every writer no-ops (see bugsweep_state_dir_ready). A pwd fallback would
# write one project's state into whatever directory happened to be the CWD, so two
# projects swept from a shared parent would collide on the same state files.
#
# bugsweep-p74: resolved via `git rev-parse --git-common-dir` rather than
# `--show-toplevel`. In a normal checkout these agree (git-common-dir is
# "<root>/.git", so its dirname is <root> — byte-identical to show-toplevel).
# Inside a LINKED WORKTREE (concurrent metaswarm subagents, `preflight.sh
# --worktree`), --show-toplevel would return the worktree's own path, which
# would fragment cross-run state per-worktree; --git-common-dir always points
# back at the ONE main repository's .git dir, so all concurrent subagents
# share a single .bugsweep/state/ (this is why the meta.json lock below exists
# — many processes legitimately target the same files at once).
_bugsweep_target_root="${BUGSWEEP_TARGET_ROOT:-}"
if [ -n "$_bugsweep_target_root" ]; then
  case "$_bugsweep_target_root" in
    /*) : ;;
    *) _bugsweep_target_root="$(cd "$_bugsweep_target_root" 2>/dev/null && pwd || true)" ;;
  esac
  # Explicit target roots are the source of truth for helper invocations launched from a
  # different checkout (or outside Git). Their common dir still owns shared learning/state.
  _bugsweep_git_common_dir="$(git -C "$_bugsweep_target_root" rev-parse --git-common-dir 2>/dev/null || true)"
else
  _bugsweep_target_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  # Git reports a relative common-dir relative to the caller's CWD (for example
  # `../.git` from a repository subdirectory). Resolve it through the canonical
  # target root so state never lands in the parent of the audited repository.
  _bugsweep_git_common_dir="$(git -C "$_bugsweep_target_root" rev-parse --git-common-dir 2>/dev/null || true)"
fi
if [ -n "$_bugsweep_git_common_dir" ]; then
  case "$_bugsweep_git_common_dir" in
    /*) : ;;                                            # already absolute
    *)  _bugsweep_git_common_dir="$(cd "$_bugsweep_target_root" 2>/dev/null \
          && cd "$_bugsweep_git_common_dir" 2>/dev/null && pwd || true)" ;;
  esac
fi
# The absolute common git dir itself is also exported: preflight.sh writes the
# .bugsweep/ exclude entry into "${BUGSWEEP_GIT_COMMON_DIR}/info/exclude" — git
# reads info/exclude ONLY from the shared .git, never from a per-worktree
# gitdir, and .bugsweep/ lands under the MAIN repo root, so anchoring the
# exclude anywhere else leaves bugsweep state untracked-and-unexcluded in the
# main checkout (review blocker C, bugsweep-p74).
# shellcheck disable=SC2034  # consumed by preflight.sh after sourcing common.sh
BUGSWEEP_GIT_COMMON_DIR="$_bugsweep_git_common_dir"
BUGSWEEP_REPO_ROOT="${_bugsweep_git_common_dir:+$(dirname "$_bugsweep_git_common_dir")}"
unset _bugsweep_git_common_dir
BUGSWEEP_STATE_DIR="${BUGSWEEP_REPO_ROOT:+${BUGSWEEP_REPO_ROOT}/.bugsweep/state}"
# Where linked worktrees for `preflight.sh --worktree` are created. Anchored the
# same way as BUGSWEEP_STATE_DIR so every concurrent subagent creates its own
# worktree in one shared, discoverable location under the main repo.
# shellcheck disable=SC2034  # consumed by preflight.sh after sourcing common.sh
BUGSWEEP_WORKTREES_DIR="${BUGSWEEP_REPO_ROOT:+${BUGSWEEP_REPO_ROOT}/.bugsweep/worktrees}"

BUGSWEEP_TARGET_ROOT="$_bugsweep_target_root"
# shellcheck disable=SC2034  # exported for helpers and recorded run state
BUGSWEEP_SOURCE_ROOT="$BUGSWEEP_TARGET_ROOT"
BUGSWEEP_RUN_DIR="${BUGSWEEP_RUN_DIR:-}"
# Run-local indexes are immutable evidence for one audited checkout. Manual helper invocations
# without RUN_DIR retain the historical shared-state paths for compatibility, but shared
# manifests are deliberately not published because no producer lock can bind payload+manifest.
BUGSWEEP_INDEX_DIR="${BUGSWEEP_INDEX_DIR:-${BUGSWEEP_RUN_DIR:+${BUGSWEEP_RUN_DIR}/indexes}}"
[ -n "$BUGSWEEP_INDEX_DIR" ] || BUGSWEEP_INDEX_DIR="${BUGSWEEP_STATE_DIR:-}"

# True only when a project-scoped state dir is known (i.e. a git repo root resolved).
# Writers MUST gate on this before touching cross-run state, so a stray invocation
# outside a repo can never create a shared state directory.
bugsweep_state_dir_ready() { [ -n "${BUGSWEEP_STATE_DIR:-}" ]; }

# BUGSWEEP_NO_PYTHON=1 forces the degraded shell fallback paths everywhere —
# a deterministic test hook (and operator escape hatch) so the no-python
# behavior can be exercised on machines that DO have python3 installed.
have_python() { [ -z "${BUGSWEEP_NO_PYTHON:-}" ] && command -v python3 >/dev/null 2>&1; }

# --- Source-bound extractor artifacts -----------------------------------------
# Every generated index carries the exact checkout, Git tree, content manifest, config, and
# extractor bytes that produced it.  Consumers compare this binding before reading an index;
# a missing or mismatched binding is degraded/reopened rather than trusted.
bugsweep_file_sha256() {
  local path="${1:-}"
  [ -f "$path" ] || { printf ''; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
  else
    printf ''
  fi
}

# Extractors all source this file, so its behavior is part of their identity.  Keep the
# combined digest in the existing extractor_sha256 field for compatibility with the manifest
# shape; old manifests naturally fail closed because the digest no longer matches.
bugsweep_extractor_identity() {
  local extractor="${1:-}" extractor_hash common_hash payload
  extractor_hash="$(bugsweep_file_sha256 "$extractor")"
  common_hash="$(bugsweep_file_sha256 "${BUGSWEEP_SCRIPT_DIR}/common.sh")"
  [ -n "$extractor_hash" ] && [ -n "$common_hash" ] || { printf ''; return 0; }
  payload="${extractor_hash}
${common_hash}
"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$payload" | shasum -a 256 2>/dev/null | awk '{print $1}'
  else
    printf ''
  fi
}

bugsweep_source_manifest_prepare() {
  local root="${1:-$BUGSWEEP_TARGET_ROOT}"
  if [ -z "$root" ]; then
    _BSW_SOURCE_MANIFEST_ROOT=""
    _BSW_SOURCE_MANIFEST_HASH=""
    return 0
  fi
  if [ "${_BSW_SOURCE_MANIFEST_ROOT:-}" = "$root" ] && [ -n "${_BSW_SOURCE_MANIFEST_HASH:-}" ]; then
    return 0
  fi
  if have_python; then
    local value
    value="$(BSW_ROOT="$root" python3 - <<'PY' 2>/dev/null || true
import hashlib, json, os, subprocess
root = os.environ["BSW_ROOT"]
try:
    raw = subprocess.check_output(["git", "-C", root, "ls-files", "-z"])
except Exception:
    print("", end="")
    raise SystemExit
files = {}
for path in raw.decode("utf-8", "surrogateescape").split("\x00"):
    if not path:
        continue
    try:
        with open(os.path.join(root, path), "rb") as handle:
            digest = hashlib.sha256()
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            files[path] = digest.hexdigest()
    except OSError:
        # A tracked file that is absent or unreadable means this is not a complete
        # source snapshot.  Do not publish a valid-looking partial identity: every
        # consumer must degrade to unknown and widen its work.
        print("", end="")
        raise SystemExit
payload = json.dumps(files, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8", "surrogateescape")
print(hashlib.sha256(payload).hexdigest())
PY
    )"
    _BSW_SOURCE_MANIFEST_ROOT="$root"
    _BSW_SOURCE_MANIFEST_HASH="$value"
    return 0
  fi
  # The no-Python path cannot safely hash arbitrary filenames/content portably; retain the
  # historical Git-tree identity only when every tracked path is present.  A missing path still
  # makes the snapshot unavailable, so a partial checkout cannot look current.
  local value files path missing=0
  files="$(git -C "$root" ls-files 2>/dev/null || true)"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -f "${root}/${path}" ]; then
      missing=1
      break
    fi
  done <<EOF
$files
EOF
  if [ "$missing" -ne 0 ]; then
    value=""
  else
    value="$(git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
  fi
  _BSW_SOURCE_MANIFEST_ROOT="$root"
  _BSW_SOURCE_MANIFEST_HASH="$value"
}

bugsweep_source_manifest_hash() {
  bugsweep_source_manifest_prepare "${1:-$BUGSWEEP_TARGET_ROOT}"
  printf '%s' "${_BSW_SOURCE_MANIFEST_HASH:-}"
}

bugsweep_tree_prepare() {
  local root="${1:-$BUGSWEEP_TARGET_ROOT}" value
  if [ -z "$root" ]; then
    _BSW_TREE_ROOT=""
    _BSW_TREE_ID=""
    return 0
  fi
  if [ "${_BSW_TREE_ROOT:-}" = "$root" ] && [ -n "${_BSW_TREE_ID:-}" ]; then
    return 0
  fi
  value="$(git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
  _BSW_TREE_ROOT="$root"
  _BSW_TREE_ID="$value"
}

bugsweep_tree_id() {
  bugsweep_tree_prepare "${1:-$BUGSWEEP_TARGET_ROOT}"
  printf '%s' "${_BSW_TREE_ID:-}"
}

bugsweep_manifest_path() {
  local name="${1:-}" dir="${BUGSWEEP_INDEX_DIR:-${BUGSWEEP_STATE_DIR:-}}"
  [ -n "$name" ] && [ -n "$dir" ] && printf '%s/%s.manifest.json' "$dir" "$name"
}

# Return the payload path for an index. Variant replay intentionally keeps its payload in the
# run root for compatibility; all other indexes live beside their manifest.
bugsweep_index_artifact_path() {
  local name="${1:-}" dir="${2:-${BUGSWEEP_INDEX_DIR:-${BUGSWEEP_STATE_DIR:-}}}"
  if [ "$name" = "variant-matches" ] && [ -n "${BUGSWEEP_INDEX_ARTIFACT_PATH:-}" ]; then
    printf '%s' "$BUGSWEEP_INDEX_ARTIFACT_PATH"
  elif [ "$name" = "variant-matches" ] && [ -n "${BUGSWEEP_RUN_DIR:-}" ] &&
       [ -f "${BUGSWEEP_RUN_DIR}/variant-matches.jsonl" ]; then
    printf '%s' "${BUGSWEEP_RUN_DIR}/variant-matches.jsonl"
  else
    printf '%s/%s.jsonl' "$dir" "$name"
  fi
}

# Return a digest of upstream artifact payloads plus their source bindings. A dependency's
# current manifest is also validated, so changing an upstream extractor invalidates downstream
# facts before that upstream artifact is rebuilt. This is a small acyclic graph:
# symbol-index -> graph/entry-points -> sinks/sink-reachability.
bugsweep_index_dependency_hash() {
  local name="${1:-}" dir="${2:-${BUGSWEEP_INDEX_DIR:-${BUGSWEEP_STATE_DIR:-}}}"
  local deps="" dep artifact manifest artifact_hash manifest_hash payload san_path san_hash producer producer_hash
  case "$name" in
    graph|entry-points) deps="symbol-index" ;;
    sinks|sink-reachability) deps="graph entry-points" ;;
  esac
  payload=""
  for dep in $deps; do
    artifact="$(bugsweep_index_artifact_path "$dep" "$dir")"
    manifest="${dir}/${dep}.manifest.json"
    [ -f "$artifact" ] && [ -f "$manifest" ] || { printf ''; return 0; }
    artifact_hash="$(bugsweep_file_sha256 "$artifact")"
    manifest_hash="$(bugsweep_file_sha256 "$manifest")"
    [ -n "$artifact_hash" ] && [ -n "$manifest_hash" ] || { printf ''; return 0; }
    case "$dep" in
      symbol-index) producer="${BUGSWEEP_SCRIPT_DIR}/symbols.sh" ;;
      graph|entry-points) producer="${BUGSWEEP_SCRIPT_DIR}/graph.sh" ;;
      *) producer="" ;;
    esac
    producer_hash="$(bugsweep_extractor_identity "$producer")"
    [ -n "$producer_hash" ] || { printf ''; return 0; }
    # Python consumers fail closed on stale upstream manifests. The shell fallback keeps
    # portability; its callers already treat missing validation as degraded.
    if have_python && [ -n "$producer" ]; then
      bugsweep_index_manifest_current "$dep" "$producer" || { printf ''; return 0; }
    fi
    payload="${payload}${dep}|${artifact_hash}|${manifest_hash}|${producer_hash}
"
  done
  case "$name" in
    sinks|sink-reachability)
      san_path="${BUGSWEEP_STATE_DIR:+${BUGSWEEP_STATE_DIR}/sanitizers.jsonl}"
      if [ -n "$san_path" ] && [ -f "$san_path" ]; then
        san_hash="$(bugsweep_file_sha256 "$san_path")"
        [ -n "$san_hash" ] || { printf ''; return 0; }
        payload="${payload}sanitizers|${san_hash}
"
      else
        payload="${payload}sanitizers|missing
"
      fi
      ;;
  esac
  [ -n "$payload" ] || payload="none
"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$payload" | shasum -a 256 2>/dev/null | awk '{print $1}'
  else
    printf ''
  fi
}

bugsweep_write_index_manifest() {
  local name="${1:-}" extractor="${2:-}" dir="${BUGSWEEP_INDEX_DIR:-${BUGSWEEP_STATE_DIR:-}}" out
  [ -n "$name" ] && [ -n "$dir" ] || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  out="$(bugsweep_manifest_path "$name")"
  local root tree source_hash config_hash extractor_hash artifact_hash dependency_hash artifact_path
  root="${BUGSWEEP_TARGET_ROOT:-}"
  bugsweep_tree_prepare "$root"
  tree="${_BSW_TREE_ID:-}"
  bugsweep_source_manifest_prepare "$root"
  source_hash="${_BSW_SOURCE_MANIFEST_HASH:-}"
  config_hash="$(bugsweep_file_sha256 "${BUGSWEEP_CONFIG:-}")"
  extractor_hash="$(bugsweep_extractor_identity "$extractor")"
  # Shared state has no producer lock and can pair another invocation's payload with this
  # manifest. Run-local indexes are immutable evidence and are the only paths allowed to carry
  # a reusable binding; shared manual helpers still write facts but deliberately degrade their
  # manifest consumers until a run-local build publishes a coherent pair.
  [ -n "${BUGSWEEP_RUN_DIR:-}" ] || return 1
  artifact_path="$(bugsweep_index_artifact_path "$name" "$dir")"
  artifact_hash="$(bugsweep_file_sha256 "$artifact_path")"
  dependency_hash="$(bugsweep_index_dependency_hash "$name" "$dir")"
  [ -n "$root" ] && [ -n "$tree" ] && [ -n "$source_hash" ] && [ -n "$config_hash" ] && \
    [ -n "$extractor_hash" ] && [ -n "$artifact_hash" ] && [ -n "$dependency_hash" ] || return 1
  if have_python; then
    BSW_OUT="$out" BSW_NAME="$name" BSW_ROOT="$root" BSW_TREE="$tree" \
    BSW_SOURCE="$source_hash" BSW_CONFIG="$config_hash" BSW_EXTRACTOR="$extractor_hash" \
    BSW_ARTIFACT="$artifact_hash" BSW_DEPENDENCY="$dependency_hash" \
    python3 - <<'PY' 2>/dev/null || return 1
import hashlib, json, os
value = {
    "schema_version": 1,
    "artifact": os.environ["BSW_NAME"],
    "source_root": os.environ["BSW_ROOT"],
    "tree": os.environ["BSW_TREE"],
    "source_manifest_sha256": os.environ["BSW_SOURCE"],
    "config_sha256": os.environ["BSW_CONFIG"],
    "extractor_sha256": os.environ["BSW_EXTRACTOR"],
    "artifact_sha256": os.environ["BSW_ARTIFACT"],
    "dependency_sha256": os.environ["BSW_DEPENDENCY"],
}
binding = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
value["generation"] = hashlib.sha256(binding).hexdigest()
tmp = os.environ["BSW_OUT"] + ".tmp"
with open(tmp, "w") as handle:
    json.dump(value, handle, sort_keys=True)
    handle.write("\n")
os.replace(tmp, os.environ["BSW_OUT"])
PY
  else
    printf '%s\n' "{\"schema_version\":1,\"artifact\":\"$(_bsw_json_escape "$name")\",\"source_root\":\"$(_bsw_json_escape "$root")\",\"tree\":\"$(_bsw_json_escape "$tree")\",\"source_manifest_sha256\":\"$(_bsw_json_escape "$source_hash")\",\"config_sha256\":\"$(_bsw_json_escape "$config_hash")\",\"extractor_sha256\":\"$(_bsw_json_escape "$extractor_hash")\",\"artifact_sha256\":\"$(_bsw_json_escape "$artifact_hash")\",\"dependency_sha256\":\"$(_bsw_json_escape "$dependency_hash")\"}" > "$out"
  fi
}

bugsweep_index_manifest_current() {
  local name="${1:-}" extractor="${2:-}" manifest root tree source_hash config_hash extractor_hash artifact_hash dependency_hash artifact_path dir
  manifest="$(bugsweep_manifest_path "$name")"
  [ -f "$manifest" ] && have_python || return 1
  root="${BUGSWEEP_TARGET_ROOT:-}"
  bugsweep_tree_prepare "$root"
  tree="${_BSW_TREE_ID:-}"
  bugsweep_source_manifest_prepare "$root"
  source_hash="${_BSW_SOURCE_MANIFEST_HASH:-}"
  config_hash="$(bugsweep_file_sha256 "${BUGSWEEP_CONFIG:-}")"
  extractor_hash="$(bugsweep_extractor_identity "$extractor")"
  dir="${BUGSWEEP_INDEX_DIR:-${BUGSWEEP_STATE_DIR:-}}"
  [ -n "${BUGSWEEP_RUN_DIR:-}" ] || return 1
  artifact_path="$(bugsweep_index_artifact_path "$name" "$dir")"
  artifact_hash="$(bugsweep_file_sha256 "$artifact_path")"
  dependency_hash="$(bugsweep_index_dependency_hash "$name" "$dir")"
  BSW_MANIFEST="$manifest" BSW_ROOT="$root" BSW_TREE="$tree" BSW_SOURCE="$source_hash" \
  BSW_CONFIG="$config_hash" BSW_EXTRACTOR="$extractor_hash" BSW_NAME="$name" \
  BSW_ARTIFACT="$artifact_hash" BSW_DEPENDENCY="$dependency_hash" \
  python3 - <<'PY' 2>/dev/null
import hashlib, json, os
try:
    with open(os.environ["BSW_MANIFEST"]) as handle:
        value = json.load(handle)
except Exception:
    raise SystemExit(1)
expected = {
    "schema_version": 1,
    "artifact": os.environ["BSW_NAME"],
    "source_root": os.environ["BSW_ROOT"],
    "tree": os.environ["BSW_TREE"],
    "source_manifest_sha256": os.environ["BSW_SOURCE"],
    "config_sha256": os.environ["BSW_CONFIG"],
    "extractor_sha256": os.environ["BSW_EXTRACTOR"],
    "artifact_sha256": os.environ["BSW_ARTIFACT"],
    "dependency_sha256": os.environ["BSW_DEPENDENCY"],
}
if not all(isinstance(expected[k], str) and expected[k] for k in expected if k != "schema_version"):
    raise SystemExit(1)
binding = json.dumps(expected, sort_keys=True, separators=(",", ":")).encode("utf-8")
raise SystemExit(0 if all(value.get(k) == v for k, v in expected.items()) and
                  value.get("generation") == hashlib.sha256(binding).hexdigest() else 1)
PY
}

# --- mkdir-based mutual exclusion (bugsweep-p74) -------------------------------
# `mkdir` is atomic on every POSIX filesystem bugsweep runs on, and unlike
# flock(1) it needs no extra binary — stock macOS bash 3.2 ships neither
# flock(1) nor bash's own /dev/tcp-style file descriptor locking. This is a
# short, narrowly-scoped mutex for the few genuinely-shared read-modify-write
# sections (meta.json's run counter) and each run's producer sequence — NOT a
# cross-run index mutex. Concurrent bugsweep runs use separate index directories;
# every caller uses a short timeout and degrades gracefully (skip / proceed
# unlocked) rather than blocking a sibling subagent indefinitely.
#
# bugsweep-re9: a release-on-EXIT trap fired ALONGSIDE an unconditional
# explicit release (as an earlier revision of this comment showed) is
# hazardous and must not be reintroduced. bugsweep_lock_release force-clears
# whatever CURRENTLY holds lockdir/pid — it has no notion of "is this still
# my lock" — so if the explicit release below runs and the trap ALSO fires
# later on some other exit path (a subshell quirk, a signal after the
# explicit release, or a future edit that adds another exit route), the trap
# can force-clear a lock some UNRELATED subsequent holder has since
# legitimately acquired. A trap must therefore be guarded so it no-ops once
# the explicit release has already run.
#
# Usage:
#   if bugsweep_lock_acquire "$lockdir" 10; then
#     released=0
#     trap '[ "$released" = 1 ] || { bugsweep_lock_release "$lockdir"; released=1; }' EXIT
#     ...critical section...
#     bugsweep_lock_release "$lockdir"
#     released=1
#   fi
# Simpler still (preferred when the critical section has no early-return
# paths that would otherwise skip the explicit release): skip the trap
# entirely and rely solely on the explicit release.
bugsweep_lock_acquire() {
  local lockdir="$1" timeout="${2:-10}" waited=0 holder_pid marker_pid current_pid marker
  marker="${lockdir}/takeover"
  while ! mkdir "$lockdir" 2>/dev/null; do
    # Stale-lock reclaim (review fix D, bugsweep-p74): a lock dir left behind by
    # a process that died holds a pidfile; if that pid is no longer alive, the
    # lock is dead weight. Reclaim must be SINGLE-WINNER — the original
    # rm-pidfile-then-rmdir sequence let several waiters interleave their
    # deletions with a new winner's mkdir + pid-write, so 6+ of 12 waiters could
    # all believe they held the lock at once (TOCTOU).
    #
    # The winner is elected via an O_EXCL "takeover" marker (bash noclobber)
    # and adopts the lock IN PLACE rather than deleting/renaming the dir.
    # Rename-based reclaim was tried and rejected: rename(2) binds to the PATH,
    # not the observed generation of the lock, so a fresh LIVE holder that
    # re-acquired between a waiter's liveness check and its mv gets stolen
    # (reproduced under a 10-waiter storm). In-place adoption closes that hole
    # structurally: the dir is never removed or renamed during reclaim, so the
    # path cannot be re-bound to a new generation mid-reclaim, and the winner
    # re-verifies — under marker exclusion — that the pidfile still names the
    # SAME dead holder before writing its own pid. Nothing a live holder owns
    # can ever be adopted or destroyed:
    #   - claim requires the observed pid to be dead;
    #   - only one claimant can hold the marker per lock generation;
    #   - pid re-verification under the marker is race-free (mkdir-holders
    #     can't exist while the dir exists; other claimants are excluded;
    #     release implies a live holder, and a live holder precludes claiming).
    # An orphaned marker (claimant died mid-takeover) is itself reclaimed by
    # the same dead-pid rule; an unreadable marker fails CLOSED (wait), so a
    # half-written marker can never be stolen from a live claimant.
    #
    # bugsweep-re9 (verify-after-write): the orphaned-marker CLEANUP above
    # ("Clear it only if it is provably dead") is itself check-then-act — a
    # claimant can observe $marker, read its pid, confirm it's dead, and then
    # be PREEMPTED before its `rm -f "$marker"` runs. If a NEW claimant's
    # noclobber-write races into that same window (marker now briefly absent
    # again after the preempted claimant's stale-check but not yet removed),
    # a schedule replay showed the preempted claimant's `rm -f` can go on to
    # delete that NEW claimant's fresh, live marker after it already won its
    # noclobber-write — reopening the marker slot while the new claimant
    # still believes it holds exclusivity, letting a THIRD claimant's
    # noclobber-write also succeed. Both would then pass the
    # current_pid==holder_pid re-verify (neither has adopted yet) and both
    # would write "$$" into lockdir/pid, with only the last writer's pid
    # surviving — the loser believes it holds the lock but does not.
    # Closing this requires a verify AFTER the adoption write, not just
    # before: immediately after writing "$$", re-read lockdir/pid. If it does
    # not read back as "$$", some other claimant's write landed after ours —
    # we lost the generation race and must back off and re-loop rather than
    # return 0 believing we hold the lock.
    if [ -f "${lockdir}/pid" ]; then
      holder_pid="$(cat "${lockdir}/pid" 2>/dev/null || true)"
      case "$holder_pid" in
        ''|*[!0-9]*) : ;;
        *)
          if ! kill -0 "$holder_pid" 2>/dev/null; then
            if [ -f "$marker" ]; then
              # A claimant exists. Clear it only if it is provably dead.
              marker_pid="$(cat "$marker" 2>/dev/null || true)"
              case "$marker_pid" in
                ''|*[!0-9]*) : ;;  # unreadable/half-written -> fail closed, wait
                *) kill -0 "$marker_pid" 2>/dev/null || rm -f "$marker" 2>/dev/null || true ;;
              esac
            elif ( set -o noclobber; printf '%s' "$$" > "$marker" ) 2>/dev/null; then
              # We hold the exclusive claim: re-verify, then adopt in place.
              current_pid="$(cat "${lockdir}/pid" 2>/dev/null || true)"
              if [ "$current_pid" = "$holder_pid" ]; then
                printf '%s' "$$" > "${lockdir}/pid" 2>/dev/null || true
                # Verify-after-write: confirm OUR write is still the one on
                # disk before declaring victory. If another claimant's write
                # landed after ours (the preemption race above), back off —
                # do NOT remove the marker (it may be the winner's) and do
                # NOT return 0.
                if [ "$(cat "${lockdir}/pid" 2>/dev/null || true)" = "$$" ]; then
                  rm -f "$marker" 2>/dev/null || true
                  return 0
                fi
              else
                # The generation changed under us (live holder) — abort the claim.
                rm -f "$marker" 2>/dev/null || true
              fi
            fi
          fi
          ;;
      esac
    fi
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 0.2 2>/dev/null || sleep 1
    waited=$((waited + 1))
  done
  printf '%s' "$$" > "${lockdir}/pid" 2>/dev/null || true
  return 0
}

bugsweep_lock_release() {
  local lockdir="$1" _
  rm -f "${lockdir}/pid" 2>/dev/null || true
  # A takeover claimant that observed a stale pid may hold its marker for a few
  # microseconds before its re-verification aborts (it sees the pid gone and
  # removes the marker itself). Retry the rmdir briefly so release still
  # converges; force-clearing the marker here is safe — any claimant that
  # loses its marker mid-claim simply fails re-verification and re-waits.
  for _ in 1 2 3; do
    rmdir "$lockdir" 2>/dev/null && return 0
    rm -f "${lockdir}/pid" "${lockdir}/takeover" 2>/dev/null || true
    sleep 0.05 2>/dev/null || sleep 1
  done
  rmdir "$lockdir" 2>/dev/null || true
}

# --- Anti-pattern catalog versioning -----------------------------------------
# Source of truth is references/antipatterns/versions.json (a per-detector-class integer map);
# the legacy single-integer references/antipatterns/VERSION is the fallback when the map is
# unreadable (no python3, or file missing). Two views:
#   catalog_class_version <class>   -> that class's version (for WU2 per-class invalidation)
#   catalog_aggregate_version       -> sum of all class versions (advances on ANY bump; used by
#                                      state.sh coverage so any catalog change re-audits broadly)
BUGSWEEP_CATALOG_VERSIONS="${BUGSWEEP_ROOT}/references/antipatterns/versions.json"
BUGSWEEP_CATALOG_VERSION_LEGACY="${BUGSWEEP_ROOT}/references/antipatterns/VERSION"

_catalog_legacy() {
  if [ -f "$BUGSWEEP_CATALOG_VERSION_LEGACY" ]; then
    tr -d '[:space:]' < "$BUGSWEEP_CATALOG_VERSION_LEGACY"
  else
    printf '0'
  fi
}

catalog_class_version() {
  local cls="${1:-}"
  [ -n "$cls" ] || { printf '0'; return 0; }
  if [ -f "$BUGSWEEP_CATALOG_VERSIONS" ] && have_python; then
    # class name passed via env (never interpolated into -c); file path is a controlled arg.
    BSW_CLS="$cls" python3 -c 'import json,os,sys
try:
    d=json.load(open(sys.argv[1])); print(int(d.get(os.environ["BSW_CLS"],0)))
except Exception:
    print("__FAIL__")' "$BUGSWEEP_CATALOG_VERSIONS" 2>/dev/null | {
      read -r v
      case "$v" in ''|__FAIL__|*[!0-9]*) _catalog_legacy ;; *) printf '%s' "$v" ;; esac
    }
    return 0
  fi
  _catalog_legacy
}

catalog_aggregate_version() {
  if [ -f "$BUGSWEEP_CATALOG_VERSIONS" ] && have_python; then
    python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(sum(int(v) for k,v in d.items() if not str(k).startswith("_")))
except Exception:
    print("__FAIL__")' "$BUGSWEEP_CATALOG_VERSIONS" 2>/dev/null | {
      read -r v
      case "$v" in ''|__FAIL__|*[!0-9]*) _catalog_legacy ;; *) printf '%s' "$v" ;; esac
    }
    return 0
  fi
  _catalog_legacy
}

# Emit the raw per-class versions JSON (or empty if unreadable) — for passing to a python
# evaluator that needs the whole map (conclusions.sh prime).
catalog_versions_json() {
  [ -f "$BUGSWEEP_CATALOG_VERSIONS" ] && cat "$BUGSWEEP_CATALOG_VERSIONS" 2>/dev/null || printf ''
}

# Resolve the exclude-glob list for the file-level shell fallbacks (graph.sh / reachability.sh),
# one glob per line. Parses .exclude_globs from config (quote chars built via printf so no
# literals are needed); `**`->`*` because bash `case` globbing already spans '/'. When neither
# jq nor python3 can parse the JSON array, falls back to a hardcoded floor of the documented
# defaults so the degrade path never indexes vendored/generated code.
bugsweep_exclude_globs() {
  local q exg
  q="$(printf '%b' '\042\047')"
  exg="$(cfg_get '.exclude_globs' '' | grep -oE "[${q}][^${q}]+[${q}]" 2>/dev/null | tr -d "$q" | sed 's#\*\*#*#g' || true)"
  if [ -z "$exg" ]; then
    exg="$(printf '%s\n' 'node_modules/*' 'dist/*' 'build/*' '.git/*' 'vendor/*' \
      'Pods/*' '.next/*' 'coverage/*' '*.lock' '*.min.js' '*/__generated__/*')"
  fi
  printf '%s\n' "$exg"
}

# bugsweep_excluded <path> <newline-glob-list>: exit 0 if <path> matches any glob (skip it),
# 1 otherwise. Used by the shell fallbacks to honor exclude_globs the same way the python paths do.
bugsweep_excluded() {
  local path="$1" globs="$2" glob
  [ -n "$globs" ] || return 1
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    case "$path" in $glob) return 0 ;; esac
  done <<EOF
$globs
EOF
  return 1
}

# Count of completed runs recorded in the cross-run meta file (0 if none/unreadable).
bugsweep_meta_runs() {
  local meta="${BUGSWEEP_STATE_DIR}/meta.json"
  [ -f "$meta" ] || { printf '0'; return 0; }
  if have_python; then
    python3 -c 'import json,sys
try:
    print(int(json.load(open(sys.argv[1])).get("runs",0)))
except Exception:
    print(0)' "$meta" 2>/dev/null || printf '0'
  else
    grep -o '"runs"[[:space:]]*:[[:space:]]*[0-9]*' "$meta" 2>/dev/null | grep -o '[0-9]*' | head -1 || printf '0'
  fi
}

# --- Safe state.env emission (bugsweep-06y) ------------------------------------
# state.env is SOURCED (not merely read) by five call sites (guard.sh,
# finalize.sh, session.sh, run_checks.sh, state.sh), so every value written into
# it MUST be safe to `source` regardless of content. BUGSWEEP_ORIG_BRANCH in
# particular comes straight from the user's git branch NAME, which may legally
# contain shell metacharacters ($(...), backticks, ;, quotes) — writing it
# unquoted into a heredoc let any of those five sourcing sites execute arbitrary
# shell the moment they sourced the file (command injection via the source
# boundary). This is the fix: the canonical shell-safe-quoting idiom. Escape
# every embedded single quote to '\'' (close quote, escaped literal quote,
# reopen quote), then wrap the WHOLE value in single quotes. Single quotes
# preserve everything else verbatim — $, `, ;, ", newlines — so no other
# character needs special-casing, and every caller MUST use this for every
# KEY=value line regardless of whether the value "looks safe": reasoning about
# which values could carry attacker-influenced content is exactly the mistake
# that created this bug.
#
# Usage: _bsw_env_kv KEY "value" >> file   ->   emits KEY='value'\n (source-safe)
_bsw_env_kv() {
  local _k="$1" _v
  _v=$(printf '%s' "${2-}" | sed "s/'/'\\\\''/g")
  printf "%s='%s'\n" "$_k" "$_v"
}

# Minimal JSON string escaper, matching the established repo-wide pattern (see
# scripts/finalize.sh's _json_escape / scripts/summarize.sh's _json_escape /
# scripts/run_checks.sh's json_str_or_null / scripts/recon-plan.sh's
# _json_escape_deg) but placed in common.sh so any caller that already sources
# common.sh (e.g. preflight.sh's ledger.jsonl line) can reuse it instead of
# re-deriving its own local copy. JSON forbids raw control characters in
# strings and this path never needs them, so strip 0x00-0x1F (including
# newlines/tabs) first, THEN escape backslash BEFORE double-quote — reversing
# that order would re-escape the backslashes the quote escaping just
# introduced.
_bsw_json_escape() {
  printf '%s' "${1:-}" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Read a SINGLE key's value from a state.env file, correctly and safely
# (bugsweep-06y). This MUST decode as pure TEXT and MUST NOT source/eval the
# file: bugsweep-cleanup.sh --reap-worktrees globs
# `.bugsweep/run-*/state.env` across EVERY run dir — including pre-patch runs
# (old unquoted format), concurrent runs, and leftover/foreign/tampered files
# of untrusted provenance. Sourcing any of those would EXECUTE a hostile value
# like `BUGSWEEP_ORIG_BRANCH=x$(touch M)` (a real RCE). The prior `sed -n
# 's/^KEY=//p'` reader was inert for any content because sed never executes;
# this getter preserves that "safe for arbitrary content" property while ALSO
# decoding the new single-quote-wrapped _bsw_env_kv format correctly.
#
# Decode (all pure string ops — no `.`, no `source`, no `eval`, no glob/word
# expansion of the value):
#   1. Extract the raw value line by prefix (sed only strips text, never runs).
#   2. If it is single-quote-wrapped ('...') — the _bsw_env_kv format — strip
#      the outer quotes and reverse the escaping: every emitted `'\''` sequence
#      becomes one `'`. This is the exact inverse of _bsw_env_kv (which turns
#      each `'` in the value into `'\''` then wraps in single quotes), so a
#      value like `o'brien/feature` round-trips byte-exact.
#   3. Otherwise (old unquoted / double-quoted / legacy / hostile-unwrapped) —
#      take the raw text as a LITERAL string. This is what keeps a hostile
#      legacy `KEY=x$(touch M)` file INERT: it is returned verbatim as data,
#      never executed, exactly as the old sed reader behaved.
# Key names are caller-supplied literals, never file/user content. Prints the
# value (empty if the file/key is absent).
#   Usage: v="$(_bsw_state_env_get "${run_dir}/state.env" BUGSWEEP_WORKTREE)"
_bsw_state_env_get() {
  local _file="$1" _key="$2" _raw
  [ -f "$_file" ] || return 0
  _raw="$(sed -n "s/^${_key}=//p" "$_file" 2>/dev/null | head -1)"
  case "$_raw" in
    "'"*"'")
      # Strip the outer single quotes, then collapse every 4-char '\'' back to
      # a single ' via sed BRE (\\ matches a literal backslash) — portable,
      # and never executes the value.
      _raw="${_raw#\'}"
      _raw="${_raw%\'}"
      printf '%s' "$_raw" | sed "s/'\\\\''/'/g"
      ;;
    *)
      printf '%s' "$_raw"
      ;;
  esac
}
