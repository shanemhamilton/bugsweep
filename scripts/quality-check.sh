#!/usr/bin/env bash
# Session gates are intentionally pure: they never invoke Git.  Git-backed CI
# must opt in with --full-git-ci and is a separate workflow concern.
set -euo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
EVALUATION=""; EVALUATION_PROTOCOL=""; EVALUATION_SCHEDULE=""; EVALUATION_EXECUTION_ORDER=""; EVALUATION_RECEIPTS=""; EVALUATION_REQUIRED_EVIDENCE=""; EVIDENCE_ROOT=""; EVALUATION_CALIBRATION=""; FULL_GIT_CI=false
evaluation_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --evaluation) shift; [ "$#" -gt 0 ] || { echo '--evaluation needs a file' >&2; exit 2; }; EVALUATION="$1" ;;
    --protocol) shift; [ "$#" -gt 0 ] || { echo '--protocol needs a frozen protocol file' >&2; exit 2; }; EVALUATION_PROTOCOL="$1" ;;
    --schedule) shift; [ "$#" -gt 0 ] || { echo '--schedule needs a frozen schedule file' >&2; exit 2; }; EVALUATION_SCHEDULE="$1" ;;
    --execution-order) shift; [ "$#" -gt 0 ] || { echo '--execution-order needs a frozen order file' >&2; exit 2; }; EVALUATION_EXECUTION_ORDER="$1" ;;
    --receipts) shift; [ "$#" -gt 0 ] || { echo '--receipts needs a frozen receipt file' >&2; exit 2; }; EVALUATION_RECEIPTS="$1" ;;
    --required-evidence) shift; [ "$#" -gt 0 ] || { echo '--required-evidence needs a frozen requirement file' >&2; exit 2; }; EVALUATION_REQUIRED_EVIDENCE="$1" ;;
    --evidence-root) shift; [ "$#" -gt 0 ] || { echo '--evidence-root needs an absolute artifact root' >&2; exit 2; }; EVIDENCE_ROOT="$1" ;;
    --calibration) shift; [ "$#" -gt 0 ] || { echo '--calibration needs a frozen calibration file' >&2; exit 2; }; EVALUATION_CALIBRATION="$1" ;;
    --stage-calibration) shift; [ "$#" -gt 0 ] || { echo '--stage-calibration needs a frozen calibration file' >&2; exit 2; }; evaluation_args+=(--stage-calibration "$1") ;;
    --full-git-ci) FULL_GIT_CI=true ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$EVALUATION" ]; then
  [ -n "$EVALUATION_PROTOCOL" ] || { echo '--evaluation requires --protocol' >&2; exit 2; }
  [ -n "$EVALUATION_SCHEDULE" ] || { echo '--evaluation requires --schedule' >&2; exit 2; }
  [ -n "$EVALUATION_EXECUTION_ORDER" ] || { echo '--evaluation requires --execution-order' >&2; exit 2; }
  [ -n "$EVALUATION_RECEIPTS" ] || { echo '--evaluation requires --receipts' >&2; exit 2; }
  [ -n "$EVALUATION_REQUIRED_EVIDENCE" ] || { echo '--evaluation requires --required-evidence' >&2; exit 2; }
  [ -n "$EVIDENCE_ROOT" ] || { echo '--evaluation requires --evidence-root' >&2; exit 2; }
  evaluation_args+=(
    --published-summary "$EVALUATION"
    --protocol "$EVALUATION_PROTOCOL"
    --schedule "$EVALUATION_SCHEDULE"
    --execution-order "$EVALUATION_EXECUTION_ORDER"
    --receipts "$EVALUATION_RECEIPTS"
    --required-evidence "$EVALUATION_REQUIRED_EVIDENCE"
    --evidence-root "$EVIDENCE_ROOT"
  )
  if [ -n "$EVALUATION_CALIBRATION" ]; then evaluation_args+=(--calibration "$EVALUATION_CALIBRATION"); fi
  cd "$ROOT"
  # Recompute from frozen inputs. Never accept a caller-provided decision,
  # verification flag, path, or digest as release evidence.
  PYTHONDONTWRITEBYTECODE=1 python3 -B -m bench.scorer.evaluation "${evaluation_args[@]}" >/dev/null
fi

cd "$ROOT"
coverage_file="$(mktemp "${TMPDIR:-/tmp}/bugsweep-quality-coverage.XXXXXX")"
installer_coverage_file="$(mktemp "${TMPDIR:-/tmp}/bugsweep-installer-coverage.XXXXXX")"
trap 'rm -f "$coverage_file" "$installer_coverage_file"' EXIT
# This is the only unit module that starts Git. Keep the default session gate
# process-free; full Git CI runs it below.
session_unit_args=(bench/tests/unit --ignore=bench/tests/unit/test_mark_batch_covered.py)
COVERAGE_FILE="$coverage_file" PYTHONDONTWRITEBYTECODE=1 python3 -B -m coverage run --branch -m pytest -p no:cacheprovider "${session_unit_args[@]}"
COVERAGE_FILE="$coverage_file" python3 -B -m coverage report --fail-under=80
COVERAGE_FILE="$installer_coverage_file" PYTHONDONTWRITEBYTECODE=1 python3 -B -m coverage run --branch --source=scripts.installer_helper -m pytest -p no:cacheprovider bench/tests/unit/test_install_contract.py bench/tests/unit/test_quality_contract.py
COVERAGE_FILE="$installer_coverage_file" python3 -B -m coverage report --fail-under=80
[ "$(bats --version)" = "Bats ${BUGSWEEP_BATS_VERSION:?BUGSWEEP_BATS_VERSION is required}" ]
[ "$(shellcheck --version | awk '/^version:/ {print $2}')" = "${BUGSWEEP_SHELLCHECK_VERSION:?BUGSWEEP_SHELLCHECK_VERSION is required}" ]
bats tests/bats/install-contract.bats tests/bats/run-checks-contract.bats
shellcheck install.sh scripts/update-install.sh scripts/quality-check.sh
if $FULL_GIT_CI; then
  [ "${BUGSWEEP_FULL_GIT_CI:-}" = 1 ] || { echo 'full Git CI requires BUGSWEEP_FULL_GIT_CI=1' >&2; exit 2; }
  python3 -B -m pytest -p no:cacheprovider bench/tests/unit/test_mark_batch_covered.py
  bats tests/bats bench/tests/bats
fi
