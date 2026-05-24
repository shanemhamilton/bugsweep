#!/usr/bin/env bash
# bugsweep variant queries (WU1): turn a CONFIRMED bug into a durable, repo-wide
# detector for its siblings — the Project Zero "variant analysis" multiplier.
#
# Division of responsibility (mirrors bugsweep's safety model): the MODEL proposes
# a Semgrep rule during confirmation (it understands the bug's shape); this SCRIPT
# enforces the deterministic, safety-critical parts the model must not be trusted
# with — validation, over/under-match guards, persistence, replay, false-positive
# tracking, and auto-retirement.
#
#   variants.sh add <bug_id> <rule_file> <origin_relpath> [lang]
#       Validate a model-proposed rule and persist it. Guards:
#         never-match : the rule MUST flag its own origin file (else rejected)
#         over-match  : if it matches > ratio cap of files, stored as confidence=low
#                       (low-confidence rules never auto-requeue — no frontier poisoning)
#   variants.sh replay <RUN_DIR>
#       Run all ACTIVE rules repo-wide; write variant-matches.jsonl to RUN_DIR; update
#       counters; auto-retire dead/noisy rules; print REQUEUE=<file> for high-confidence hits.
#   variants.sh retire <bug_id> --reason <fp|obsolete>
#   variants.sh list
#
# Safety: persisted rules/index are DATA. This script never eval/execs their content;
# scanning is delegated to semgrep (declarative, sandboxed). Rule files are size-capped
# and structurally validated before storage. Degrades (never fails a run): no semgrep ->
# store unvalidated + skip replay (LLM shape-search is the prompt-layer fallback);
# no python3 -> store rule + skip index math with a warning.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Repo root, state dir, have_python, bugsweep_meta_runs come from common.sh.
REPO_ROOT="$BUGSWEEP_REPO_ROOT"
STATE_DIR="$BUGSWEEP_STATE_DIR"
VARIANTS_DIR="${STATE_DIR}/variants"
INDEX="${STATE_DIR}/variants.index.jsonl"
META="${STATE_DIR}/meta.json"
RULE_MAX_BYTES=8192

have_semgrep() { command -v semgrep >/dev/null 2>&1; }

# Numeric guard: config values feed numeric comparisons, so coerce any non-numeric value to
# a safe default. Must reject a lone '.', empty, multi-dot, or anything without a digit.
is_num()  {
  case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac
  case "$1" in *[0-9]*) return 0 ;; *) return 1 ;; esac
}
num_or()  { if is_num "$1"; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# in-progress run ordinal = persisted runs + 1 (consistent with state.sh persist)
current_run() { printf '%s' $(( $(bugsweep_meta_runs) + 1 )); }

# Safe bug_id: alnum, dash, underscore, dot only (used in a filename). Reject anything else.
sanitize_id() {
  case "$1" in
    *[!A-Za-z0-9._-]*|''|.*) return 1 ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
add() {
  local bug_id rule_file origin lang
  bug_id="$(sanitize_id "${1:-}")" || die "add: invalid bug_id (allowed: A-Za-z0-9._- , no leading dot)"
  rule_file="${2:-}"; origin="${3:-}"; lang="${4:-}"
  [ -f "$rule_file" ] || die "add: rule_file not found: $rule_file"
  [ -n "$origin" ] || die "usage: variants.sh add <bug_id> <rule_file> <origin_relpath> [lang]"

  # Size cap (injection / payload guard).
  local bytes; bytes="$(wc -c < "$rule_file" | tr -d ' ')"
  [ "$bytes" -le "$RULE_MAX_BYTES" ] || die "add: rule exceeds ${RULE_MAX_BYTES} bytes (got ${bytes})."

  mkdir -p "$VARIANTS_DIR" 2>/dev/null || { log "variants: cannot create ${VARIANTS_DIR}; skipping add."; return 0; }

  local run; run="$(current_run)"
  local dest="${VARIANTS_DIR}/${bug_id}.yml"

  if ! have_semgrep; then
    cp "$rule_file" "$dest"
    append_index "$bug_id" "$lang" "$origin" "$run" "unvalidated" 0
    log "variants: semgrep absent — stored '${bug_id}' UNVALIDATED (will be validated when semgrep is available)."
    return 0
  fi

  # Structural validation: semgrep must accept the rule.
  if ! semgrep --validate --config "$rule_file" >/dev/null 2>&1; then
    die "add: rule failed 'semgrep --validate' — not stored. Fix the rule and retry."
  fi

  have_python || { cp "$rule_file" "$dest"; append_index "$bug_id" "$lang" "$origin" "$run" "unvalidated" 0; \
    log "variants: python3 absent — stored '${bug_id}' UNVALIDATED."; return 0; }

  # Reject multi-rule files: replay attributes matches per rule_id, and one bug == one
  # detector. Count rule-level list items (`- id:`). NOTE: grep -c exits 1 on zero matches,
  # so use '|| true' (never '|| echo 0', which would emit a second line) + coercion.
  local rule_count
  rule_count="$(grep -cE '^[[:space:]]*-[[:space:]]+id:' "$rule_file" 2>/dev/null || true)"
  case "$rule_count" in ''|*[!0-9]*) rule_count=0 ;; esac
  [ "$rule_count" -le 1 ] || die "add: rule_file defines ${rule_count} rules — exactly one rule per variant is required."

  # Run the candidate rule across the repo to compute guards. Capture JSON to a file —
  # NEVER inline-interpolate it (semgrep output contains '$' metavariables that bash mangles).
  local ratio_cap total sgout sg_ok=1
  ratio_cap="$(num_or "$(cfg_get '.context.variant_max_match_ratio' '0.25')" '0.25')"
  total="$(git -C "$REPO_ROOT" ls-files 2>/dev/null | wc -l | tr -d ' ')"
  sgout="$(mktemp)"
  trap "rm -f -- '$sgout'" EXIT
  semgrep --quiet --config "$rule_file" --json "$REPO_ROOT" > "$sgout" 2>/dev/null || sg_ok=0

  # Returns: "<matched_origin:0|1> <matched_files> <n_distinct_rules> <rule_id>"
  local guard
  guard="$(REPO_ROOT="$REPO_ROOT" SGOUT="$sgout" python3 - "$origin" <<'PY' 2>/dev/null || true
import json, os, sys
origin = sys.argv[1]
root = os.environ["REPO_ROOT"]
try:
    data = json.load(open(os.environ["SGOUT"]))
except Exception:
    data = {"results": []}
files = set(); ids = set(); hit_origin = 0; rule_id = ""
for r in data.get("results", []):
    p = os.path.relpath(r.get("path", ""), root)
    files.add(p)
    cid = str(r.get("check_id", "")).split(".")[-1]
    if cid:
        ids.add(cid)
        if not rule_id:
            rule_id = cid
    if p == origin:
        hit_origin = 1
        if cid:
            rule_id = cid
print("%d %d %d %s" % (hit_origin, len(files), len(ids), rule_id))
PY
)"
  local hit_origin matched_files n_rules rule_id
  hit_origin="$(printf '%s' "$guard" | awk '{print $1+0}')"
  matched_files="$(printf '%s' "$guard" | awk '{print $2+0}')"
  n_rules="$(printf '%s' "$guard" | awk '{print $3+0}')"
  # Sanitize rule_id to a safe charset (it is spliced into JSON / used as a map key).
  rule_id="$(printf '%s' "$guard" | awk '{print $4}' | tr -cd 'A-Za-z0-9._-')"

  # A transient full-repo scan failure must DEGRADE, not fail the run (contract: never abort).
  # Store inactive+unvalidated so it cannot requeue until a clean scan re-adds it.
  if [ "$sg_ok" -ne 1 ]; then
    cp "$rule_file" "$dest"
    append_index "$bug_id" "$lang" "$origin" "$run" "unvalidated" 0 "${rule_id:-$bug_id}"
    log "variants: 'semgrep' run failed on this repo — stored '${bug_id}' UNVALIDATED+inactive (re-add when scans succeed)."
    return 0
  fi

  # never-match guard
  if [ "${hit_origin:-0}" -ne 1 ]; then
    die "add: rule does not match its own origin (${origin}) — rejected. A variant rule must catch the bug it was synthesized from."
  fi
  [ "${n_rules:-0}" -le 1 ] || die "add: rule expands to ${n_rules} distinct ids — exactly one detector per variant is required."

  # rule_id collision guard: two variants sharing a semgrep id would cross-attribute matches.
  if [ -f "$INDEX" ] && have_python && [ -n "$rule_id" ]; then
    local collide
    collide="$(python3 - "$INDEX" "$rule_id" "$bug_id" <<'PY' 2>/dev/null || echo 0
import json, sys
idx, rid, bug_id = sys.argv[1], sys.argv[2], sys.argv[3]
for ln in open(idx):
    ln = ln.strip()
    if not ln: continue
    try: e = json.loads(ln)
    except Exception: continue
    if e.get("rule_id") == rid and e.get("bug_id") != bug_id:
        print(1); break
else:
    print(0)
PY
)"
    [ "${collide:-0}" = "1" ] && die "add: rule_id '${rule_id}' is already used by a different bug — give the rule a unique id."
  fi

  # over-match guard: ratio AND an absolute floor must BOTH hold, so a precise rule matching
  # a few real siblings is not penalized and tiny repos don't misfire. If the file count is
  # unknown (empty/odd repo) we cannot compute the ratio -> fail safe to LOW (never auto-requeue).
  local confidence floor
  floor="$(num_or "$(cfg_get '.context.variant_overmatch_min_files' '2')" '2')"
  if [ "${total:-0}" -gt 0 ]; then
    # Compute over-match in python via ENV (no value interpolated into code). Any conversion
    # error fails SAFE to over-match -> low confidence -> never auto-requeues.
    local over
    over="$(MF="$matched_files" TOT="$total" FLOOR="$floor" CAP="$ratio_cap" python3 - <<'PY' 2>/dev/null || echo 1
import os
try:
    mf = float(os.environ["MF"]); tot = float(os.environ["TOT"])
    floor = float(os.environ["FLOOR"]); cap = float(os.environ["CAP"])
    print(1 if (mf >= floor and tot > 0 and (mf / tot) > cap) else 0)
except Exception:
    print(1)
PY
)"
    if [ "$over" = "1" ]; then confidence="low"; else confidence="high"; fi
  else
    confidence="low"
  fi

  cp "$rule_file" "$dest"
  append_index "$bug_id" "$lang" "$origin" "$run" "$confidence" "$matched_files" "$rule_id"
  if [ "$confidence" = "low" ]; then
    log "variants: stored '${bug_id}' confidence=LOW (matched ${matched_files}/${total} files > ${ratio_cap}); will NOT auto-requeue — flagged for human review."
  else
    log "variants: stored '${bug_id}' confidence=high (matched ${matched_files}/${total} files)."
  fi
}

append_index() {  # bug_id lang origin run confidence match_files [rule_id]
  # An "unvalidated" rule (semgrep/python3 absent or scan failed at add time) was never
  # guard-checked, so it is stored INACTIVE — it can never replay/requeue until re-added under
  # a validating engine. One atomic write builds (kept entries + new entry) and os.replace's
  # once, so a crash can never drop the just-confirmed rule.
  if have_python; then
    # Re-add carries forward the prior false-positive history for this bug_id: a rule a human
    # (or auto-retire) marked noisy must NOT silently reactivate with a clean counter when the
    # same bug recurs and the model re-proposes it. On python failure we log + return (never
    # fall through to a non-dedup append, which would duplicate/cross-attribute the entry).
    if INDEX="$INDEX" python3 - "$1" "$2" "$3" "$4" "$5" "$6" "${7:-$1}" <<'PY' 2>/dev/null
import json, os, sys
idx = os.environ["INDEX"]
bug_id, lang, origin, run, conf, mf, rule_id = sys.argv[1:8]
prior_fp = 0
prior_fp_retired = False
keep = []
if os.path.exists(idx):
    for line in open(idx):
        line = line.strip()
        if not line: continue
        try: e = json.loads(line)
        except Exception: continue
        if e.get("bug_id") == bug_id:
            prior_fp = int(e.get("false_positive", 0))
            if prior_fp > 0 or e.get("retired_reason") == "false_positive":
                prior_fp_retired = True
            continue   # drop the old entry; merged version re-appended below
        keep.append(line)
active = (conf != "unvalidated") and not prior_fp_retired
entry = {"bug_id": bug_id, "rule": "variants/%s.yml" % bug_id, "rule_id": rule_id or bug_id,
         "lang": lang, "origin": origin, "created_run": int(run), "last_matched_run": None,
         "consecutive_nonmatch": 0, "false_positive": prior_fp,
         "confidence": conf, "match_files": int(mf), "active": active}
if prior_fp_retired:
    entry["retired_reason"] = "false_positive"
keep.append(json.dumps(entry))
tmp = idx + ".tmp"
open(tmp, "w").write("\n".join(keep) + "\n")
os.replace(tmp, idx)
PY
    then return 0; else
      log "variants: index update failed (python error); '$1' not persisted this run (no duplicate written)."
      return 0
    fi
  fi
  # No-python fallback only: append a minimal JSON-safe entry. A single sub-PIPE_BUF line append
  # is atomic on POSIX local filesystems, so a crash cannot tear it; dedup is unavailable here.
  local act="true"; [ "$5" = "unvalidated" ] && act="false"
  printf '{"bug_id":"%s","rule":"variants/%s.yml","rule_id":"%s","confidence":"%s","active":%s}\n' \
    "$1" "$1" "${7:-$1}" "$5" "$act" >> "$INDEX"
}

# ---------------------------------------------------------------------------
replay() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || die "usage: variants.sh replay <RUN_DIR>"
  run_dir="$(cd "$run_dir" && pwd)"
  local out="${run_dir}/variant-matches.jsonl"
  : > "$out"

  { [ -d "$VARIANTS_DIR" ] && [ -n "$(ls -A "$VARIANTS_DIR" 2>/dev/null)" ]; } || { log "variants: none stored — nothing to replay."; return 0; }
  if ! have_semgrep || ! have_python; then
    log "variants: semgrep/python3 unavailable — skipping replay (LLM shape-search is the prompt-layer fallback)."
    return 0
  fi

  local run retire_after sg_ok=1
  run="$(current_run)"
  retire_after="$(num_or "$(cfg_get '.context.variant_retire_after_nonmatch_runs' '10')" '10')"

  local sgout; sgout="$(mktemp)"
  trap "rm -f -- '$sgout'" EXIT
  semgrep --quiet --config "$VARIANTS_DIR" --json "$REPO_ROOT" > "$sgout" 2>/dev/null || sg_ok=0

  # Python: write matches, update index counters + auto-retire, print REQUEUE files.
  # JSON is read from a file (quoted heredoc) — never inline-interpolated.
  REPO_ROOT="$REPO_ROOT" INDEX="$INDEX" OUT="$out" RUN="$run" RETIRE_AFTER="$retire_after" SGOUT="$sgout" SG_OK="$sg_ok" \
  python3 - <<'PY' 2>/dev/null || { log "variants: replay parse failed (continuing)."; return 0; }
import json, os
root = os.environ["REPO_ROOT"]; idx = os.environ["INDEX"]; out = os.environ["OUT"]
run = int(os.environ["RUN"]); retire_after = int(os.environ["RETIRE_AFTER"])
parse_failed = False
try:
    data = json.load(open(os.environ["SGOUT"]))
except Exception:
    data = {"results": []}; parse_failed = True

# Inconclusive ONLY when semgrep truly failed to run (exit != 0) or its output was unparseable.
# A successful (exit 0) scan that merely skipped some unparseable target files still carries a
# populated errors[] — that is NOT inconclusive, so a single bad file in the repo cannot freeze
# auto-retirement of genuinely dead rules. On an inconclusive run we still requeue what matched
# (widening is safe) but never increment non-match or stale-retire.
inconclusive = (os.environ.get("SG_OK") == "0") or parse_failed

# rule_id (semgrep check_id basename) -> set(files)
matched = {}
with open(out, "w") as f:
    for r in data.get("results", []):
        cid = str(r.get("check_id", "")).split(".")[-1]
        p = os.path.relpath(r.get("path", ""), root)
        line = r.get("start", {}).get("line")
        matched.setdefault(cid, set()).add(p)
        f.write(json.dumps({"bug_id": cid, "file": p, "line": line, "run": run}) + "\n")

entries = []
if os.path.exists(idx):
    for ln in open(idx):
        ln = ln.strip()
        if not ln: continue
        try: entries.append(json.loads(ln))
        except Exception: pass

requeue = set()
for e in entries:
    bid = e.get("bug_id")
    # Match on the semgrep rule_id (check_id); fall back to filename/bug_id for legacy entries.
    rid = e.get("rule_id") or os.path.splitext(os.path.basename(e.get("rule", "")))[0] or bid
    hits = matched.get(rid) or matched.get(bid)
    if not e.get("active", True):
        continue
    if hits:
        e["last_matched_run"] = run
        e["consecutive_nonmatch"] = 0
        e["match_files"] = len(hits)
        if e.get("confidence") == "high":
            requeue.update(hits)   # low/unvalidated rules never auto-requeue
    elif not inconclusive:
        e["consecutive_nonmatch"] = int(e.get("consecutive_nonmatch", 0)) + 1
    # Retire: a false-positive mark always retires; stale-nonmatch only on a CONCLUSIVE run.
    if int(e.get("false_positive", 0)) > 0:
        e["active"] = False; e["retired_reason"] = "false_positive"
    elif (not inconclusive) and int(e.get("consecutive_nonmatch", 0)) >= retire_after:
        e["active"] = False; e["retired_reason"] = "stale_nonmatch"

tmp = idx + ".tmp"
with open(tmp, "w") as f:
    for e in entries:
        f.write(json.dumps(e) + "\n")
os.replace(tmp, idx)

for p in sorted(requeue):
    print("REQUEUE=%s" % p)
PY
}

# ---------------------------------------------------------------------------
retire() {
  local bug_id reason
  bug_id="$(sanitize_id "${1:-}")" || die "retire: invalid bug_id"
  shift || true
  reason="obsolete"
  while [ $# -gt 0 ]; do case "$1" in --reason) reason="${2:-obsolete}"; shift 2 ;; *) shift ;; esac; done
  [ -f "$INDEX" ] || die "retire: no variant index."
  have_python || die "retire: requires python3."
  INDEX="$INDEX" python3 - "$bug_id" "$reason" <<'PY' 2>/dev/null || die "retire: failed."
import json, os, sys
idx = os.environ["INDEX"]; bug_id, reason = sys.argv[1], sys.argv[2]
out = []
found = False
for ln in open(idx):
    ln = ln.strip()
    if not ln: continue
    try: e = json.loads(ln)
    except Exception: continue
    if e.get("bug_id") == bug_id:
        e["active"] = False
        e["retired_reason"] = reason
        if reason == "fp": e["false_positive"] = int(e.get("false_positive", 0)) + 1
        found = True
    out.append(json.dumps(e))
tmp = idx + ".tmp"
open(tmp, "w").write("\n".join(out) + ("\n" if out else ""))
os.replace(tmp, idx)
print("RETIRED" if found else "NOT_FOUND")
PY
}

list_rules() {
  [ -f "$INDEX" ] || { echo "(no variant rules)"; return 0; }
  if have_python; then
    python3 - "$INDEX" <<'PY' 2>/dev/null || cat "$INDEX"
import json, sys
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if not ln: continue
    try: e = json.loads(ln)
    except Exception: continue
    print("%-16s active=%-5s conf=%-11s nonmatch=%-3s fp=%s origin=%s" % (
        e.get("bug_id"), e.get("active"), e.get("confidence"),
        e.get("consecutive_nonmatch"), e.get("false_positive"), e.get("origin")))
PY
  else
    cat "$INDEX"
  fi
}

# ---------------------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  add)    add "$@" ;;
  replay) replay "$@" ;;
  retire) retire "$@" ;;
  list)   list_rules ;;
  *)      die "usage: variants.sh <add|replay|retire|list> ..." ;;
esac
