#!/usr/bin/env bash
#
# docker-entrypoint.sh — per-run setup for the bench analysis container.
#
# Runs as the non-root runtime uid (isolate.sh pins --user 65534:65534) under a
# read-only root filesystem with a writable tmpfs at /scratch. It performs the
# three setup steps that the hardened container makes necessary, then execs the
# runner from inside the writable repo copy:
#
#   1. Point HOME at the writable tmpfs and create ~/.claude/skills, because the
#      image root is read-only and the `claude` CLI + skill discovery need a
#      writable HOME.
#   2. Stage the baked, read-only bugsweep skill into ~/.claude/skills/bugsweep
#      so `claude -p` can discover and auto-trigger it headless.
#   3. Make a WRITABLE copy of the read-only clone (/work -> /scratch/repo).
#      bugsweep is not detect-passive on disk: preflight.sh cuts a throwaway
#      branch and writes .bugsweep/, and runner.sh writes a config override — so
#      the workdir MUST be writable. The host clone stays mounted :ro and thus
#      pristine; all writes land on the disposable tmpfs copy.
#
# All paths are overridable via BENCH_ENTRY_* so the Tier-A bats suite can drive
# this logic on the host without a container.

set -euo pipefail

HOME_DIR="${BENCH_ENTRY_HOME:-/scratch/home}"
SKILL_SRC="${BENCH_ENTRY_SKILL_SRC:-/opt/bugsweep-skill}"
WORK_RO="${BENCH_ENTRY_WORK:-/work}"
REPO_RW="${BENCH_ENTRY_REPO:-/scratch/repo}"

# 1. Writable HOME on the tmpfs.
export HOME="${HOME_DIR}"
mkdir -p "${HOME}/.claude/skills"

# 2. Stage the skill (read-only in the image) into the discoverable path. Absent
#    skill source is tolerated so the entrypoint stays testable in isolation.
if [[ -d "${SKILL_SRC}" ]]; then
  cp -a "${SKILL_SRC}" "${HOME}/.claude/skills/bugsweep"
fi

# 3. Writable copy of the read-only clone. `cp -a .../.` copies contents
#    (including .git) into a fresh dir so git history + the bench-base branch
#    survive for bugsweep's preflight and the runner's clean-tree assertion.
mkdir -p "${REPO_RW}"
cp -a "${WORK_RO}/." "${REPO_RW}/"

cd "${REPO_RW}"
exec "$@"
