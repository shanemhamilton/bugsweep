#!/usr/bin/env bash
# bugsweep recon-plan (bugsweep-e1r): deterministic batch-planner that computes
# a hunt plan from a bare file list BEFORE any modeling happens.
#
# Why this exists: prompts/context-build.md used to build repo-context.md +
# recon.json in a single, un-checkpointed pass. On a 1474-file repo that pass
# stalled before recon.json was ever written, leaving nothing to resume,
# reprioritize, or report (bead 2e5, "large repos fail silently"). This script
# lets context-build.md initialize recon.json from the plan FIRST, so even a
# run that dies immediately after initialization leaves a resumable artifact.
#
# Usage:
#   recon-plan.sh <RUN_DIR> [FILE_LIST_PATH]
#     FILE_LIST_PATH: a file with one repo-relative path per line (the caller
#     produces this via `git ls-files`, per the existing exclude_globs
#     convention). If omitted, reads the file list from stdin.
# Writes: <RUN_DIR>/recon-plan.json
# Prints: RECON_PLAN=<path>
#
# Tiered degradation (see common.sh's cfg_get / catalog_class_version for the
# established pattern):
#   Tier 1: python3 available -> bench/scorer/recon_plan.py does the real,
#           tier-ranked, large-repo-aware planning.
#   Tier 2: python3 unavailable -> emit a plan with one batch per top-level
#           directory (files directly under root form a "." batch), ordered
#           by the SAME critical/normal/low heuristic as the python path
#           (SINK_DIR_HINTS / LOW_PRIORITY_DIR_HINTS ported below, review
#           MAJOR 3), with large_repo_mode/deferred computed via pure shell
#           integer comparison against the same thresholds. Never blocks the run.
#
# exclude_globs compatibility (review MINOR 4): the two paths use DIFFERENT glob
# engines and cannot share code across the python/no-python boundary --
#   * Tier 1 uses Python fnmatch (recon_plan.py's _is_excluded);
#   * Tier 2 uses common.sh's bugsweep_excluded (bash `case` globbing, which
#     also squashes `**` -> `*`).
# They agree on the 11 shipped default globs and on the common metacharacters
# (`*`, `?`, `/`). They can DIVERGE on POSIX bracket classes (e.g.
# `[[:digit:]]`), which fnmatch supports but bash `case` treats differently.
# So a project adding CUSTOM .exclude_globs should stick to the portable subset
# (`*`, `?`, literal path segments, `dir/**`) to get a python-independent
# in-scope set; anything fancier makes the plan's scope depend on whether
# python3 is present.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="${1:-}"
file_list_path="${2:-}"
[ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: recon-plan.sh <RUN_DIR> [FILE_LIST_PATH]"
run_dir="$(cd "$run_dir" && pwd)"

plan_path="${run_dir}/recon-plan.json"
# Size reads must come from the audited checkout, not the installed skill
# directory (BUGSWEEP_ROOT). The run's state.env is the frozen source of truth;
# read it as data through common.sh's inert getter before considering ambient
# variables. This keeps a context-build resume tied to the preflight worktree
# even when the caller's current shell points at the skill checkout.
state_target_root="$(_bsw_state_env_get "${run_dir}/state.env" BUGSWEEP_TARGET_ROOT)"
state_worktree="$(_bsw_state_env_get "${run_dir}/state.env" BUGSWEEP_WORKTREE)"
state_audited_root="$state_target_root"
[ -d "$state_audited_root" ] || state_audited_root="$state_worktree"
audited_root="${state_audited_root:-${BUGSWEEP_AUDIT_ROOT:-${BUGSWEEP_TARGET_ROOT:-${BUGSWEEP_REPO_ROOT:-$PWD}}}}"

# --- Resolve the input file list (file arg, else stdin) ------------------------
files_raw=""
if [ -n "$file_list_path" ]; then
  [ -f "$file_list_path" ] || die "recon-plan.sh: file list not found: ${file_list_path}"
  files_raw="$(cat "$file_list_path")"
else
  files_raw="$(cat)"
fi

# --- Config-driven thresholds (same cfg_get tiering everywhere else uses) -----
file_threshold="$(cfg_get '.context.large_repo_file_threshold' '800')"
first_pass_cap="$(cfg_get '.context.large_repo_first_pass_batches' '40')"
max_batch_files="$(cfg_get '.context.max_batch_files' '25')"
max_batch_bytes="$(cfg_get '.context.max_batch_bytes' '131072')"
case "$file_threshold" in ''|*[!0-9]*) file_threshold=800 ;; esac
case "$first_pass_cap"  in ''|*[!0-9]*) first_pass_cap=40 ;; esac
case "$max_batch_files"  in ''|*[!0-9]*) max_batch_files=25 ;; esac
case "$max_batch_bytes"  in ''|*[!0-9]*) max_batch_bytes=131072 ;; esac
[ "$max_batch_files" -gt 0 ] || max_batch_files=25
[ "$max_batch_bytes" -gt 0 ] || max_batch_bytes=131072

excludes_json="$(cfg_get '.exclude_globs' '[]')"
case "$excludes_json" in
  \[*) : ;;              # looks like a JSON array already
  *) excludes_json='[]' ;;
esac

# --- Tier 1: python3 -> bench/scorer/recon_plan.py -----------------------------
if have_python; then
  if BUGSWEEP_ROOT="$BUGSWEEP_ROOT" FILES_RAW="$files_raw" EXCLUDES_JSON="$excludes_json" \
     FILE_THRESHOLD="$file_threshold" FIRST_PASS_CAP="$first_pass_cap" \
     MAX_BATCH_FILES="$max_batch_files" MAX_BATCH_BYTES="$max_batch_bytes" \
     AUDITED_ROOT="$audited_root" OUT_PATH="$plan_path" \
     python3 - <<'PY' 2>/dev/null
import json
import os
import stat
import sys

sys.path.insert(0, os.environ["BUGSWEEP_ROOT"])
from bench.scorer.recon_plan import build_plan  # noqa: E402

files = [f for f in os.environ.get("FILES_RAW", "").splitlines() if f.strip()]
try:
    excludes = json.loads(os.environ.get("EXCLUDES_JSON") or "[]")
    if not isinstance(excludes, list):
        excludes = []
except Exception:
    excludes = []

sizes = {}
repo_root = os.environ.get("AUDITED_ROOT") or os.getcwd()
for path in files:
    try:
        audited_path = os.path.join(repo_root, path)
        info = os.lstat(audited_path)
        if stat.S_ISREG(info.st_mode):
            sizes[path] = info.st_size
    except (OSError, ValueError):
        # Missing/unreadable audited-tree entries stay explicit in the plan;
        # guessing a size could violate the byte bound.
        pass

plan = build_plan(
    files=files,
    exclude_globs=excludes,
    file_threshold=int(os.environ["FILE_THRESHOLD"]),
    first_pass_batch_cap=int(os.environ["FIRST_PASS_CAP"]),
    file_sizes=sizes,
    max_batch_files=int(os.environ["MAX_BATCH_FILES"]),
    max_batch_bytes=int(os.environ["MAX_BATCH_BYTES"]),
)

with open(os.environ["OUT_PATH"], "w", encoding="utf-8") as f:
    # sort_keys=True: recon_plan.py's docstring names byte-identical output as
    # the determinism contract (verified via json.dumps(..., sort_keys=True) in
    # tests). Setting it here too makes the on-disk file robust to any future
    # dict-construction reordering in build_plan (review MINOR).
    json.dump(plan, f, indent=2, sort_keys=True)
    f.write("\n")
PY
  then
    [ -f "$plan_path" ] && { echo "RECON_PLAN=${plan_path}"; exit 0; }
  fi
  log "recon-plan: python3 reduction failed; falling back to degraded single-batch-per-dir plan."
fi

# --- Tier 2: degraded shell fallback -------------------------------------------
# One batch per top-level directory, ordered critical -> normal -> low then by
# dir name, deterministic via `sort`. Honors exclude_globs using the same
# bugsweep_excluded() helper the other shell fallbacks use.
excludes_lines="$(bugsweep_exclude_globs)"

# Tier heuristic ported from bench/scorer/recon_plan.py's SINK_DIR_HINTS /
# LOW_PRIORITY_DIR_HINTS so the degraded (no-python3) path tiers identically to
# the python path (review MAJOR 3): a python3-less cold-start box must still sort
# payments/ ahead of docs/, since on a first run there's no prior-coverage.json
# sink backstop either. KEEP THESE TWO LISTS IN SYNC with recon_plan.py -- they
# are the same flat, documented sets. Space-delimited for a bash word-membership
# test. Match is on the top-level dir name only (the batch key), lowercased.
_DEG_SINK_HINTS=" auth authz authn api handlers handler middleware controllers controller routes router security payment payments billing db database crypto webhooks webhook "
_DEG_LOW_HINTS=" docs doc documentation assets static public images img "

# _deg_classify_tier <dir> -> prints critical|normal|low. "." (root files) is
# always normal, matching _classify_tier() in recon_plan.py.
_deg_classify_tier() {
  local dir="$1" lc
  [ "$dir" = "." ] && { printf 'normal'; return 0; }
  lc="$(printf '%s' "$dir" | tr '[:upper:]' '[:lower:]')"
  case "$_DEG_SINK_HINTS" in *" $lc "*) printf 'critical'; return 0 ;; esac
  case "$_DEG_LOW_HINTS"  in *" $lc "*) printf 'low'; return 0 ;; esac
  printf 'normal'
}

# _deg_tier_rank <tier> -> integer sort key (critical<normal<low), matching
# recon_plan.py's _TIER_ORDER.
_deg_tier_rank() {
  case "$1" in
    critical) printf '0' ;;
    normal)   printf '1' ;;
    *)        printf '2' ;;
  esac
}

# JSON-escape a single value for the degraded-path emitter (backslash then
# quote, matching common.sh's _json_escape-style ordering elsewhere in the repo).
_json_escape_deg() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

_degraded_plan() {
  local tmp_pairs tmp_dirs tmp_ordered_pairs tmp_meta tmp_batch_dir tab unknown_size
  tab="$(printf '\t')"
  # Never emit an empty tab-separated field: Bash treats tab as IFS whitespace
  # and collapses adjacent/trailing separators while reading the records.
  unknown_size="__BUGSWEEP_UNKNOWN_SIZE__"
  tmp_pairs="$(mktemp)"  # one line per in-scope file: "<dir>\t<path>\t<size>"
  tmp_dirs="$(mktemp)"   # ordered batch keys: "<tier>\t<dir>" (already tier-sorted)
  tmp_ordered_pairs="$(mktemp)"  # pairs reordered by the tiered dir list
  tmp_meta="$(mktemp)"    # bounded batch metadata plus a path-file per batch
  tmp_batch_dir="$(mktemp -d)"
  trap 'rm -f "$tmp_pairs" "$tmp_dirs" "$tmp_ordered_pairs" "$tmp_meta"; rm -rf "$tmp_batch_dir"' RETURN

  # LC_ALL=C on EVERY degraded-path sort (review MAJOR, retry 2): `sort`
  # collates string keys by the ambient LC_COLLATE, which under a UTF-8 locale
  # (common macOS/CI default) is case-folding -- so mixed-case dirs (Zebra,
  # apple, Banana, alpha) order as alpha,apple,Banana,Zebra instead of the
  # codepoint order Banana,Zebra,alpha,apple. Python's build_plan sorts by
  # codepoint (sorted()) regardless of locale, so without pinning, the degraded
  # order (a) diverges from the python path and (b) is non-deterministic across
  # machines with different locales. LC_ALL=C forces byte/codepoint collation on
  # both the file (-k2,2) and dir (-k3,3) tie-break keys, matching python.
  printf '%s\n' "$files_raw" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    bugsweep_excluded "$path" "$excludes_lines" && continue
    local size=""
    local audited_path="${audited_root}/${path}"
    if [ -f "$audited_path" ] && [ ! -L "$audited_path" ]; then
      size="$(wc -c < "$audited_path" | tr -d ' ' | tr -d '\n')"
      case "$size" in ''|*[!0-9]*) size="" ;; esac
    fi
    [ -n "$size" ] || size="$unknown_size"
    case "$path" in
      */*) printf '%s\t%s\t%s\n' "${path%%/*}" "$path" "$size" ;;
      *)   printf '%s\t%s\t%s\n' "." "$path" "$size" ;;
    esac
  done | LC_ALL=C sort -u -t "$tab" -k1,1 -k2,2 > "$tmp_pairs"

  # Build the ordered dir list: for each unique dir, classify its tier, then
  # sort by (tier_rank, dir) so criticals lead, normals next, lows last, with
  # dir-name ascending within a tier -- byte-identical to the python planner's
  # ordered_dirs sort. Emit as "<tier>\t<dir>" (rank stripped after sorting).
  cut -f1 "$tmp_pairs" | LC_ALL=C sort -u | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    local tier rank
    tier="$(_deg_classify_tier "$dir")"
    rank="$(_deg_tier_rank "$tier")"
    printf '%s\t%s\t%s\n' "$rank" "$tier" "$dir"
  done | LC_ALL=C sort -t "$tab" -k1,1n -k3,3 | cut -f2- > "$tmp_dirs"

  # tmp_pairs is directory-sorted for deterministic grouping, while the
  # planner's public order is tier-sorted. Reassemble the pairs using the
  # already ordered directory list without requiring awk or Bash arrays (both
  # unavailable or undesirable on the stock Bash 3.2 fallback path). Compare
  # the parsed directory field, rather than relying on a prefix grep, so a
  # directory such as "foo" can never select "afoo".
  : > "$tmp_ordered_pairs"
  while IFS="$tab" read -r _ordered_tier ordered_dir; do
    [ -n "$ordered_dir" ] || continue
    while IFS="$tab" read -r pair_dir pair_path pair_size; do
      [ "$pair_dir" = "$ordered_dir" ] || continue
      printf '%s\t%s\t%s\n' "$pair_dir" "$pair_path" "$pair_size" >> "$tmp_ordered_pairs"
    done < "$tmp_pairs"
  done < "$tmp_dirs"

  local files_in_scope batch_count large_repo_mode budget_batches_json
  files_in_scope="$(wc -l < "$tmp_pairs" | tr -d ' ')"

  # Split each top-level directory with the same conservative policy as the
  # Python planner. Missing sizes and known oversize files are isolated, making
  # the byte-bound status explicit even on Bash 3.2 machines.
  : > "$tmp_meta"
  local current_dir="" current_count=0 current_bytes=0 current_status="known"
  local current_oversized=false current_paths_file="" batch_seq=0
  _deg_flush_batch() {
    [ -n "$current_paths_file" ] || return 0
    local byte_value="$current_bytes"
    [ "$current_status" = "missing" ] && byte_value="unknown"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$current_dir" "$current_count" "$byte_value" "$current_status" \
      "$current_oversized" "$current_paths_file" "$(_deg_classify_tier "$current_dir")" >> "$tmp_meta"
    current_count=0
    current_bytes=0
    current_status="known"
    current_oversized=false
    current_paths_file=""
  }

  while IFS="$tab" read -r pdir path psize; do
    [ -n "$path" ] || continue
    if [ -n "$current_dir" ] && [ "$pdir" != "$current_dir" ]; then
      _deg_flush_batch
    fi
    current_dir="$pdir"

    if [ "$psize" = "$unknown_size" ]; then
      _deg_flush_batch
      batch_seq=$((batch_seq + 1))
      current_paths_file="${tmp_batch_dir}/${batch_seq}"
      printf '%s\n' "$path" > "$current_paths_file"
      current_count=1
      current_status="missing"
      _deg_flush_batch
      continue
    fi
    if [ "$psize" -gt "$max_batch_bytes" ]; then
      _deg_flush_batch
      batch_seq=$((batch_seq + 1))
      current_paths_file="${tmp_batch_dir}/${batch_seq}"
      printf '%s\n' "$path" > "$current_paths_file"
      current_count=1
      current_bytes="$psize"
      current_status="oversized"
      current_oversized=true
      _deg_flush_batch
      continue
    fi
    if [ -n "$current_paths_file" ] && {
      [ "$current_status" != "known" ] ||
      [ "$current_count" -ge "$max_batch_files" ] ||
      [ $((current_bytes + psize)) -gt "$max_batch_bytes" ];
    }; then
      _deg_flush_batch
    fi
    if [ -z "$current_paths_file" ]; then
      batch_seq=$((batch_seq + 1))
      current_paths_file="${tmp_batch_dir}/${batch_seq}"
      : > "$current_paths_file"
    fi
    printf '%s\n' "$path" >> "$current_paths_file"
    current_count=$((current_count + 1))
    current_bytes=$((current_bytes + psize))
  done < "$tmp_ordered_pairs"
  _deg_flush_batch

  batch_count="$(wc -l < "$tmp_meta" | tr -d ' ')"
  if [ "$files_in_scope" -gt "$file_threshold" ]; then
    large_repo_mode=true
    budget_batches_json="$first_pass_cap"
  else
    large_repo_mode=false
    budget_batches_json="null"
  fi

  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "files_in_scope": %s,\n' "$files_in_scope"
    printf '  "batch_count": %s,\n' "$batch_count"
    printf '  "large_repo_mode": %s,\n' "$large_repo_mode"
    printf '  "budget_batches": %s,\n' "$budget_batches_json"
    printf '  "max_batch_files": %s,\n' "$max_batch_files"
    printf '  "max_batch_bytes": %s,\n' "$max_batch_bytes"
    printf '  "missing_size_files": ['
    local first_missing=true
    while IFS="$tab" read -r _pdir _path _psize; do
      [ -n "$_path" ] && [ "$_psize" = "$unknown_size" ] || continue
      [ "$first_missing" = true ] || printf ','
      first_missing=false
      printf '"%s"' "$(_json_escape_deg "$_path")"
    done < "$tmp_pairs"
    printf '],\n'
    printf '  "oversized_files": ['
    local first_oversized=true
    while IFS="$tab" read -r _pdir _path _psize; do
      [ -n "$_path" ] && [ "$_psize" != "$unknown_size" ] && [ -n "$_psize" ] && [ "$_psize" -gt "$max_batch_bytes" ] || continue
      [ "$first_oversized" = true ] || printf ','
      first_oversized=false
      printf '"%s"' "$(_json_escape_deg "$_path")"
    done < "$tmp_pairs"
    printf '],\n'
    printf '  "batches": [\n'
    local idx=0 total_dirs="$batch_count"
    while IFS="$tab" read -r dir bcount bbytes bstatus bov paths_file tier; do
      [ -n "$dir" ] || continue
      idx=$((idx + 1))
      local deferred=false
      if [ "$large_repo_mode" = "true" ] && [ "$idx" -gt "$first_pass_cap" ]; then
        deferred=true
      fi
      local dir_json; dir_json="$(_json_escape_deg "$dir")"
      local byte_json="$bbytes"
      if [ "$byte_json" = "unknown" ]; then byte_json="null"; fi
      printf '    {"id": %s, "dir": "%s", "tier": "%s", "deferred": %s, "files": [' \
        "$idx" "$dir_json" "$tier" "$deferred"
      local first=true
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        local path_json; path_json="$(_json_escape_deg "$path")"
        if [ "$first" = "true" ]; then first=false; else printf ','; fi
        printf '"%s"' "$path_json"
      done < "$paths_file"
      printf '], "file_count": %s, "byte_count": %s, "size_status": "%s", "oversized": %s, "missing_size_files": [' "$bcount" "$byte_json" "$bstatus" "$bov"
      if [ "$bstatus" = "missing" ]; then
        local first_batch_missing=true
        while IFS= read -r path; do
          [ "$first_batch_missing" = true ] || printf ','
          first_batch_missing=false
          printf '"%s"' "$(_json_escape_deg "$path")"
        done < "$paths_file"
      fi
      printf ']}'
      [ "$idx" -lt "$total_dirs" ] && printf ',\n' || printf '\n'
      done < "$tmp_meta"
    printf '  ],\n'
    printf '  "covered": []\n'
    printf '}\n'
  } > "$plan_path"
}

_degraded_plan
[ -f "$plan_path" ] || die "recon-plan.sh: failed to write ${plan_path}"
echo "RECON_PLAN=${plan_path}"
