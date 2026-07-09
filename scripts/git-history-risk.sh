#!/usr/bin/env bash
# bugsweep-t6e: per-file version-control risk features for state.sh's `prime`
# risk score.
#
# Why: recon.json's batch ordering and .bugsweep/state's risk scores never
# used version-control signal. Files with high commit churn, recent changes,
# or a history of fix-typed commits are statistically higher-risk and should
# sort earlier in the coverage frontier (reinforces the cross-file moat, see
# bugsweep-q5f). This script computes that signal in isolation so
# scripts/state.sh can fold it into its EXISTING risk score with a bounded
# weight (see state.sh's `prime` for the fold and HISTORY_MAX_WEIGHT).
#
# Usage:
#   git-history-risk.sh <REPO_ROOT> [DEPTH_CAP]
#     DEPTH_CAP: max number of commits (reachable from HEAD, most-recent-first)
#     to consider. Defaults to cfg_get '.context.history_depth_commits' '500'.
#     A commit-COUNT cap (not a `--since` time window) is deliberate: bounding
#     by commit count keeps this DETERMINISTIC for a fixed repo state and
#     bounds runtime on huge repos regardless of how old the repo is, whereas
#     a wall-clock window's boundary silently shifts as real time passes even
#     when the repo itself never changes.
#
# Prints one JSON line per file touched within the capped window to stdout:
#   {"file": "<path>", "commits": <int>, "fix_commits": <int>, "history_score": <float>}
# `commits` / `fix_commits` are the CLAMPED counts (see FREQ_CAP/FIX_CAP below)
# -- a pathological history (a file touched by every commit in the window)
# cannot make its own signal outweigh any other file's by more than the clamp
# allows. `history_score` is a single composite in [0, 1]; it is the ONLY
# value scripts/state.sh reads back for its bounded fold.
#
# Degrades to NO output (never fails the caller) when: git is unavailable,
# the path is not a git repo, there is no HEAD commit yet, or python3 is
# unavailable (this script uses python3 to parse `git log` output; state.sh's
# `prime` already only folds history under `have_python`, so this mirrors
# that gating rather than adding a parallel shell implementation).

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

repo_root="${1:-}"
[ -n "$repo_root" ] && [ -d "$repo_root" ] || die "usage: git-history-risk.sh <REPO_ROOT> [DEPTH_CAP]"
repo_root="$(cd "$repo_root" && pwd)"

depth_cap="${2:-$(cfg_get '.context.history_depth_commits' '500')}"
case "$depth_cap" in ''|*[!0-9]*) depth_cap=500 ;; esac
[ "$depth_cap" -gt 0 ] || depth_cap=500

# Guard rails: no git, not a repo, no commits yet, or no python3 -> zero
# signal, not a failure. history is a pure enrichment on top of the existing
# risk score, never a run-blocking dependency.
command -v git >/dev/null 2>&1 || exit 0
git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git -C "$repo_root" rev-parse --verify -q HEAD >/dev/null 2>&1 || exit 0
have_python || exit 0

# One bounded `git log` call: -n <depth_cap> caps the commit window itself, so
# runtime and memory stay bounded regardless of total repo history size. The
# `@@BSW@@` marker is a delimiter unlikely to collide with a real commit
# subject; per-commit file lists follow each marker line until the next one.
#
# Captured into a variable and handed to python via an env var (the same
# FILES_RAW pattern recon-plan.sh uses), NOT piped directly into `python3 -
# <<PY`: a heredoc redirect on a command overrides that command's stdin, so a
# pipe feeding the SAME command would be silently discarded (its writer gets
# SIGPIPE) rather than reaching the script -- there is no way to combine an
# input pipe with a heredoc-supplied program on one command.
git_log_output="$(git -C "$repo_root" log -n "$depth_cap" --name-only --no-color \
  --pretty=format:'@@BSW@@%x09%s' -- . 2>/dev/null || true)"

DEPTH_CAP="$depth_cap" GIT_LOG_OUTPUT="$git_log_output" python3 - <<'PY'
from __future__ import annotations

import json
import os
import re

depth_cap = int(os.environ["DEPTH_CAP"])

# Clamps (pathological-history guard): no single file's counted frequency or
# fix-commit density can exceed these, no matter how many real commits touch
# it. This is what keeps history_score bounded to [0, 1] for every file.
FREQ_CAP = 20
FIX_CAP = 10

# Conventional-commit `fix:` plus common free-text fix/bug/patch language,
# case-insensitive. Deliberately simple/documented over clever, matching the
# rest of this codebase's sink/tier heuristics (see bench/scorer/recon_plan.py).
FIX_RE = re.compile(r"\b(fix(es|ed)?|bug(fix)?|patch(es|ed)?)\b", re.IGNORECASE)

MARKER = "@@BSW@@\t"

commits = []  # [(subject, [files touched]), ...], HEAD-most first (git log order)
subject = None
files: list[str] = []
for line in os.environ.get("GIT_LOG_OUTPUT", "").split("\n"):
    if line.startswith(MARKER):
        if subject is not None:
            commits.append((subject, files))
        subject = line[len(MARKER):]
        files = []
    elif line.strip():
        files.append(line)
if subject is not None:
    commits.append((subject, files))

# Per-file raw features. `rank` is the ORDINAL position of a file's most
# recent touch within the capped window (0 = the newest commit in the
# window). This is derived purely from git's own commit-graph order, never
# from wall-clock "now", so it is stable for a fixed repo state.
commit_count: dict[str, int] = {}
fix_count: dict[str, int] = {}
best_rank: dict[str, int] = {}
for rank, (subj, touched) in enumerate(commits):
    is_fix = bool(FIX_RE.search(subj))
    for f in set(touched):
        commit_count[f] = commit_count.get(f, 0) + 1
        if is_fix:
            fix_count[f] = fix_count.get(f, 0) + 1
        if f not in best_rank or rank < best_rank[f]:
            best_rank[f] = rank

window = max(1, len(commits))  # guard divide-by-zero when the window is empty

for f in sorted(commit_count):
    raw_commits = commit_count.get(f, 0)
    raw_fix = fix_count.get(f, 0)
    clamped_commits = min(raw_commits, FREQ_CAP)
    clamped_fix = min(raw_fix, FIX_CAP)

    freq_norm = clamped_commits / float(FREQ_CAP)
    fix_norm = clamped_fix / float(FIX_CAP)
    rank = best_rank.get(f, window - 1)
    recency_norm = (window - rank) / float(window)  # 1.0 == touched at HEAD

    # Fix-commit density is the strongest signal (a file with a history of
    # fix commits is statistically the riskiest), frequency and recency are
    # secondary. Weights sum to 1.0, so history_score is always in [0, 1]
    # regardless of input -- this single number is the only thing state.sh
    # reads back for its bounded fold.
    history_score = (0.5 * fix_norm) + (0.2 * freq_norm) + (0.3 * recency_norm)
    history_score = max(0.0, min(1.0, history_score))

    print(json.dumps({
        "file": f,
        "commits": clamped_commits,
        "fix_commits": clamped_fix,
        "history_score": round(history_score, 6),
    }))
PY
