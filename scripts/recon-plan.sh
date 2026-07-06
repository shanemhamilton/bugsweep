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
case "$file_threshold" in ''|*[!0-9]*) file_threshold=800 ;; esac
case "$first_pass_cap"  in ''|*[!0-9]*) first_pass_cap=40 ;; esac

excludes_json="$(cfg_get '.exclude_globs' '[]')"
case "$excludes_json" in
  \[*) : ;;              # looks like a JSON array already
  *) excludes_json='[]' ;;
esac

# --- Tier 1: python3 -> bench/scorer/recon_plan.py -----------------------------
if have_python; then
  if FILES_RAW="$files_raw" EXCLUDES_JSON="$excludes_json" \
     FILE_THRESHOLD="$file_threshold" FIRST_PASS_CAP="$first_pass_cap" \
     BUGSWEEP_ROOT="$BUGSWEEP_ROOT" OUT_PATH="$plan_path" \
     python3 - <<'PY' 2>/dev/null
import json
import os
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

plan = build_plan(
    files=files,
    exclude_globs=excludes,
    file_threshold=int(os.environ["FILE_THRESHOLD"]),
    first_pass_batch_cap=int(os.environ["FIRST_PASS_CAP"]),
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
  local tmp_pairs tmp_dirs tab
  tab="$(printf '\t')"
  tmp_pairs="$(mktemp)"  # one line per in-scope file: "<dir>\t<path>"
  tmp_dirs="$(mktemp)"   # ordered batch keys: "<tier>\t<dir>" (already tier-sorted)
  trap 'rm -f "$tmp_pairs" "$tmp_dirs"' RETURN

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
    case "$path" in
      */*) printf '%s\t%s\n' "${path%%/*}" "$path" ;;
      *)   printf '%s\t%s\n' "." "$path" ;;
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

  local files_in_scope batch_count large_repo_mode budget_batches_json
  files_in_scope="$(wc -l < "$tmp_pairs" | tr -d ' ')"
  batch_count="$(wc -l < "$tmp_dirs" | tr -d ' ')"
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
    printf '  "batches": [\n'
    local idx=0 total_dirs="$batch_count"
    while IFS="$tab" read -r tier dir; do
      [ -n "$dir" ] || continue
      idx=$((idx + 1))
      local deferred=false
      if [ "$large_repo_mode" = "true" ] && [ "$idx" -gt "$first_pass_cap" ]; then
        deferred=true
      fi
      local dir_json; dir_json="$(_json_escape_deg "$dir")"
      printf '    {"id": %s, "dir": "%s", "tier": "%s", "deferred": %s, "files": [' \
        "$idx" "$dir_json" "$tier" "$deferred"
      local first=true
      while IFS="$tab" read -r pdir path; do
        [ "$pdir" = "$dir" ] || continue
        local path_json; path_json="$(_json_escape_deg "$path")"
        if [ "$first" = "true" ]; then first=false; else printf ','; fi
        printf '"%s"' "$path_json"
      done < "$tmp_pairs"
      printf ']}'
      [ "$idx" -lt "$total_dirs" ] && printf ',\n' || printf '\n'
    done < "$tmp_dirs"
    printf '  ],\n'
    printf '  "covered": []\n'
    printf '}\n'
  } > "$plan_path"
}

_degraded_plan
[ -f "$plan_path" ] || die "recon-plan.sh: failed to write ${plan_path}"
echo "RECON_PLAN=${plan_path}"
