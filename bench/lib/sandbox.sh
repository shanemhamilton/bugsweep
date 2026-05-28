#!/usr/bin/env bash
#
# sandbox.sh — hardened clone of a repo at a pinned SHA into a throwaway dir.
#
# Security model (see docs/plans/2026-05-28-bugsweep-bench-design.md security
# row 7 / lines 90,96): the only point at which the harness touches the network
# for a case is a SEPARATE fetch phase that populates a locally-cached, bare
# mirror. The analysis clone is then taken FROM THAT LOCAL MIRROR, so the
# analysis phase never hits the network and runs with transports/hooks/LFS/
# submodules disabled. The resulting clone is checked out onto branch
# `bench-base` at the requested SHA, and we FAIL CLOSED if HEAD != <sha>.
#
# Phases:
#   1. Fetch phase (network-on): create or refresh the bare mirror under
#      ${BENCH_MIRROR_DIR}/<repo-hash>. This is the ONLY network step.
#   2. Analysis-clone phase (no-network): clone from the LOCAL mirror with
#         -c core.hooksPath=/dev/null   (no repo hooks run)
#         --no-recurse-submodules       (no submodule fetch/checkout)
#         GIT_LFS_SKIP_SMUDGE=1         (no LFS smudge/download)
#      then set `protocol.file.allow=never` + `core.hooksPath=/dev/null` as
#      DESTINATION config (see analysis_clone for why this is post-clone, not a
#      `-c` on the clone), then `git checkout -b bench-base <sha>` and assert
#      rev-parse HEAD == <sha> (fail closed). The HEAD==sha assertion is the
#      "hash verification" against a supply-chain SHA swap (design row 7).
#
# Modes:
#   sandbox.sh --print-cmd <mirror> <destdir> <sha>
#       Print (do NOT run) the analysis-phase clone+checkout argv so the Tier-A
#       bats suite can assert the hardening flags without performing a clone.
#   sandbox.sh <repo> <sha> <destdir>
#       Fetch/refresh the mirror for <repo>, then produce the hardened clone of
#       <sha> at <destdir> on branch bench-base.

set -euo pipefail

readonly BENCH_BASE_BRANCH="bench-base"
# Where bare mirrors are cached between runs. Overridable for tests/isolation.
BENCH_MIRROR_ROOT="${BENCH_MIRROR_DIR:-${HOME}/.cache/bugsweep-bench/mirrors}"

die() {
  echo "sandbox.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  sandbox.sh --print-cmd <mirror> <destdir> <sha>
  sandbox.sh <repo> <sha> <destdir>
EOF
  exit 2
}

# Deterministic, filesystem-safe directory name for a repo URL/path.
mirror_dir_for() {
  local repo="$1"
  local hash
  if command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "${repo}" | shasum -a 256 | awk '{print $1}')"
  else
    hash="$(printf '%s' "${repo}" | sha256sum | awk '{print $1}')"
  fi
  echo "${BENCH_MIRROR_ROOT}/${hash}.git"
}

# Print the analysis-phase clone+checkout argv WITHOUT executing it. Used by the
# bats suite to assert the hardening flags are present.
print_cmd() {
  [[ $# -eq 3 ]] || usage
  local mirror="$1" destdir="$2" sha="$3"
  cat <<EOF
GIT_LFS_SKIP_SMUDGE=1 git -c core.hooksPath=/dev/null clone --no-recurse-submodules ${mirror} ${destdir}
git -C ${destdir} config protocol.file.allow never
git -C ${destdir} config core.hooksPath /dev/null
git -C ${destdir} checkout -b ${BENCH_BASE_BRANCH} ${sha}
git -C ${destdir} rev-parse HEAD  # asserted == ${sha}, else fail closed
EOF
}

# Phase 1 (network-on): create or refresh the bare mirror for <repo>.
fetch_mirror() {
  local repo="$1"
  local mirror="$2"
  if [[ -d "${mirror}" ]]; then
    # Refresh an existing mirror (network-on). --no-recurse-submodules keeps the
    # fetch from pulling submodule trees we never analyze.
    git -C "${mirror}" fetch --all --tags --prune --no-recurse-submodules \
      || die "failed to refresh mirror for ${repo}"
  else
    mkdir -p "$(dirname "${mirror}")"
    git clone --mirror --no-recurse-submodules "${repo}" "${mirror}" \
      || die "failed to create mirror for ${repo}"
  fi
}

# Phase 2 (no-network): hardened clone from the LOCAL mirror, then checkout the
# pinned SHA onto bench-base and assert HEAD matches. Fails closed on mismatch.
#
# Deviation from the literal design wording (`-c protocol.file.allow=never` ON
# the clone command): git's `file` transport covers ALL local-path clones, so
# `protocol.file.allow=never` at clone time blocks cloning from our own trusted
# local mirror ("fatal: transport 'file' not allowed"). The security intent —
# preventing any LATER git operation on the clone from following a `file://`
# reference in the analyzed repo's metadata — is preserved by setting
# `protocol.file.allow=never` as DESTINATION repo config immediately after the
# clone. The clone-time code-execution vectors (submodules/hooks/LFS) are still
# shut off at clone time via --no-recurse-submodules, core.hooksPath=/dev/null,
# and GIT_LFS_SKIP_SMUDGE=1. The mirror source is trusted (we created it from a
# known URL, hash-keyed); the threat model is malicious analyzed CONTENT, not
# git's transport stack against our own cache.
analysis_clone() {
  local mirror="$1" sha="$2" destdir="$3"

  [[ -e "${destdir}" ]] && die "destination already exists: ${destdir}"

  GIT_LFS_SKIP_SMUDGE=1 git \
    -c core.hooksPath=/dev/null \
    clone --no-recurse-submodules "${mirror}" "${destdir}" \
    || die "hardened clone from mirror failed"

  # Harden the destination so every subsequent host-side git operation on the
  # clone refuses the file transport and runs no hooks.
  git -C "${destdir}" config protocol.file.allow never \
    || die "could not harden destination protocol config"
  git -C "${destdir}" config core.hooksPath /dev/null \
    || die "could not harden destination hooks config"

  git -C "${destdir}" checkout -b "${BENCH_BASE_BRANCH}" "${sha}" \
    || die "could not check out pinned SHA ${sha} (unknown or malformed ref)"

  local actual
  actual="$(git -C "${destdir}" rev-parse HEAD)" \
    || die "could not resolve HEAD in ${destdir}"
  if [[ "${actual}" != "${sha}" ]]; then
    die "HEAD mismatch: expected ${sha}, got ${actual} — refusing to analyze a wrong checkout"
  fi
}

prepare() {
  [[ $# -eq 3 ]] || usage
  local repo="$1" sha="$2" destdir="$3"

  command -v git >/dev/null 2>&1 || die "git not found on PATH"

  local mirror
  mirror="$(mirror_dir_for "${repo}")"

  fetch_mirror "${repo}" "${mirror}"
  analysis_clone "${mirror}" "${sha}" "${destdir}"

  echo "sandbox.sh: ${destdir} is on branch ${BENCH_BASE_BRANCH} at ${sha}"
}

main() {
  [[ $# -ge 1 ]] || usage
  case "$1" in
    --print-cmd)
      shift
      print_cmd "$@"
      ;;
    -h | --help)
      usage
      ;;
    *)
      prepare "$@"
      ;;
  esac
}

main "$@"
