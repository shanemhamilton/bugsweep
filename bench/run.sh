#!/usr/bin/env bash
#
# run.sh — the benchmark orchestrator.
#
# Ties the committed pieces into one end-to-end run. For each case × k runs ×
# arm ∈ {bugsweep, baseline} it:
#   1. validates the case        (lib/validate_case.sh — fail-fast required-field gate),
#   2. prepares a hardened clone  (lib/sandbox.sh — local-mirror clone onto bench-base
#                                  at the pinned pre-fix SHA, HEAD asserted == SHA),
#   3. runs the arm               (runners/runner.sh — which, in the real path, executes
#                                  inside the lib/isolate.sh container reaching the model
#                                  API only through the lib/proxy.sh egress proxy),
#   4. scrubs the captured report (lib/scrub.sh — secrets redacted + enforced scan)
#                                  into results/<ts>/<arm>/<case>/run-<n>/report.md,
#   5. scores it                  (bench/scorer: parse_report → file-overlap gate →
#                                  cross-model judge → DETECTED/NOT_DETECTED verdict),
#  then writes per-run verdicts (verdicts.jsonl), the ground-truth + provenance
#  inputs, and renders results/<ts>/leaderboard.md (bench/scorer/leaderboard.py).
#
# Default k=3. Both arms run unless --arm restricts to one.
#
# === Container & judge: real path vs TEST-ONLY bypasses ======================
# The DEFAULT/real path runs each arm inside the hardened container (isolate.sh)
# behind the egress proxy (proxy.sh), and scores with the real cross-model judge.
# Two clearly-marked TEST-ONLY environment bypasses exist so the Tier-A bats
# suite can drive a faked end-to-end with neither a live container nor a real
# model API — they MUST NOT be set for a real WU6 run:
#   BENCH_NO_CONTAINER=1  TEST-ONLY. Run the arm directly via runner.sh against
#                         the host clone instead of inside the isolate.sh
#                         container. The real path leaves this unset and routes
#                         the arm through the container.
#   BENCH_NO_JUDGE=1      TEST-ONLY. Treat every gate-passing finding as a judge
#                         match (no model API call). The real path leaves this
#                         unset and calls the cross-model judge.
#
# Judge backend (real path): BENCH_JUDGE_BACKEND selects the cross-model judge
# adapter — "openai" (default; needs OPENAI_API_KEY) or "codex" (host-side Codex
# OAuth via `codex exec`, no key). With "codex", the judge model defaults to
# gpt-5.3-codex unless BENCH_JUDGE_MODEL_ID overrides it.
# =============================================================================
#
# usage:
#   run.sh --cases <dir-or-file> [-k <int>] [--results-root <dir>] [--arm <arm>]
#     --cases         a directory of case JSONs, or a single case JSON file
#     -k              runs per (case, arm); default 3
#     --results-root  parent dir for the timestamped run dir; default ./results
#     --arm           restrict to one arm: bugsweep | baseline (default: both)

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BENCH_DIR
REPO_ROOT="$(cd "${BENCH_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly LIB_DIR="${BENCH_DIR}/lib"
readonly RUNNERS_DIR="${BENCH_DIR}/runners"

readonly DEFAULT_K=3
readonly ARM_BUGSWEEP="bugsweep"
readonly ARM_BASELINE="baseline"
# runner.sh's --runner value for each arm.
readonly RUNNER_BUGSWEEP="claude_p"
readonly RUNNER_BASELINE="claude_p_baseline"
# runner.sh exit codes (mirrors its RESULT= contract).
readonly RUNNER_EXIT_SKIP=10

# Provenance defaults (overridable via env; real values supplied for a live run).
readonly DEFAULT_RUNNER_MODEL_ID="claude-opus-4-8"
readonly DEFAULT_RUNNER_CUTOFF="2026-01-31"
readonly DEFAULT_JUDGE_MODEL_ID="gpt-4o-judge"
# Judge backend + its codex-specific default model (used when backend=codex and
# the user does not override BENCH_JUDGE_MODEL_ID).
readonly DEFAULT_JUDGE_BACKEND="openai"
readonly DEFAULT_CODEX_JUDGE_MODEL_ID="gpt-5.3-codex"
readonly DEFAULT_LINE_WINDOW=10
readonly DEFAULT_CONTAINER_IMAGE_DIGEST="(unknown)"
readonly DEFAULT_EGRESS_PROXY_IMAGE="(unknown)"
# Image tags built by bench/docker/build.sh. Their local image ids are resolved
# into provenance on a real (non-BENCH_NO_CONTAINER) run.
readonly DEFAULT_CONTAINER_IMAGE="bugsweep-bench:latest"
readonly DEFAULT_PROXY_IMAGE="bugsweep-bench-proxy:latest"

die() {
  echo "run.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  run.sh --cases <dir-or-file> [-k <int>] [--results-root <dir>] [--arm <arm>]
EOF
  exit 2
}

# Collect the case JSON files from --cases (a dir or a single file).
collect_cases() {
  local cases_arg="$1"
  if [[ -d "${cases_arg}" ]]; then
    find "${cases_arg}" -maxdepth 1 -type f -name '*.json' | sort
  elif [[ -f "${cases_arg}" ]]; then
    echo "${cases_arg}"
  else
    die "--cases not found (not a dir or file): ${cases_arg}"
  fi
}

# Whether a case is post-cutoff: disclosure_date strictly after the runner model
# cutoff. Pure string comparison works because both are ISO YYYY-MM-DD.
case_is_post_cutoff() {
  local disclosure="$1"
  [[ "${disclosure}" > "${RUNNER_CUTOFF}" ]]
}

# Prepare a hardened sandbox clone for a case; echo the clone dir. Fails closed.
prepare_clone() {
  local case_file="$1" dest="$2"
  local repo sha
  repo="$(jq -r '.source.repo' "${case_file}")"
  sha="$(jq -r '.source.pre_fix_commit' "${case_file}")"
  "${LIB_DIR}/sandbox.sh" "${repo}" "${sha}" "${dest}" >/dev/null \
    || die "sandbox clone failed for ${case_file}"
  echo "${dest}"
}

# True on the real path; false under the TEST-ONLY BENCH_NO_CONTAINER bypass.
real_path() { [[ "${BENCH_NO_CONTAINER:-0}" != "1" ]]; }

# Map a host case-JSON path to its in-container path under the read-only /bench
# mount (isolate.sh mounts BENCH_DIR -> /bench). The case must live under bench/.
case_container_path() {
  local case_file="$1" abs
  abs="$(cd "$(dirname "${case_file}")" && pwd)/$(basename "${case_file}")"
  case "${abs}" in
    "${BENCH_DIR}/"*) echo "/bench/${abs#"${BENCH_DIR}"/}" ;;
    *) die "case file must live under ${BENCH_DIR} for a container run: ${case_file}" ;;
  esac
}

# Egress-proxy teardown (set up as an EXIT trap once the proxy is started, so it
# is torn down even if the run aborts mid-loop).
_PROXY_RUN_ID=""
_PROXY_RESULTS_DIR=""
stop_proxy() {
  [[ -n "${_PROXY_RUN_ID}" ]] || return 0
  BENCH_RESULTS_DIR="${_PROXY_RESULTS_DIR}" \
    "${LIB_DIR}/proxy.sh" stop "${_PROXY_RUN_ID}" >/dev/null 2>&1 || true
  _PROXY_RUN_ID=""
}

# Run one arm over a prepared clone, capturing + scrubbing its report into
# <run_out>/report.md. Echoes the runner RESULT token (RAN|SKIP|ERROR).
#
# Real path: execute the runner INSIDE the hardened container (lib/isolate.sh).
# The host clone is mounted read-only at /work; the entrypoint copies it to a
# writable /scratch/repo so detect-only bugsweep can write .bugsweep/ + cut its
# throwaway branch. The captured report lands on the writable /out mount (the
# host <run_out>/raw dir, passed via BENCH_OUT). The container reaches the model
# API only through the egress proxy. The TEST-ONLY BENCH_NO_CONTAINER bypass
# runs the runner directly against the host clone (Tier-A; no container/proxy).
run_arm() {
  local runner="$1" case_file="$2" clone="$3" run_out="$4"
  mkdir -p "${run_out}"

  local raw_out="${run_out}/raw"
  mkdir -p "${raw_out}"

  local result status=0
  if ! real_path; then
    result="$(
      "${RUNNERS_DIR}/runner.sh" \
        --runner "${runner}" --case "${case_file}" \
        --workdir "${clone}" --out "${raw_out}"
    )" || status=$?
  else
    local case_in_container
    case_in_container="$(case_container_path "${case_file}")"
    # The report is written by the container's uid 65534; make the host out dir
    # writable by it (on native Linux a host-uid-owned dir would otherwise be
    # unwritable — see bench/README.md cleanup caveat).
    chmod 0777 "${raw_out}"
    result="$(
      BENCH_OUT="${raw_out}" \
        "${LIB_DIR}/isolate.sh" "${CONTAINER_IMAGE}" "${clone}" -- \
        "/bench/runners/runner.sh" \
        --runner "${runner}" --case "${case_in_container}" \
        --workdir "/scratch/repo" --out "/out"
    )" || status=$?
  fi

  # SKIP (exit 10) is a clean non-error outcome; any other non-zero is ERROR.
  if [[ "${status}" -eq "${RUNNER_EXIT_SKIP}" ]]; then
    echo "SKIP"
    return 0
  fi
  if [[ "${status}" -ne 0 ]]; then
    echo "ERROR"
    return 0
  fi

  # Scrub the captured report into the persisted location (fail closed if the
  # scrub's enforced secret-scan trips).
  if [[ -f "${raw_out}/report.md" ]]; then
    "${LIB_DIR}/scrub.sh" "${raw_out}/report.md" >"${run_out}/report.md" \
      || die "scrub failed for ${runner} ${case_file}"
  else
    echo "ERROR"
    return 0
  fi

  echo "RAN"
}

# Score a captured report against a case's ground truth → a verdict string in
# {DETECTED, NOT_DETECTED}. Uses the committed scorer (parse_report → file-overlap
# gate → cross-model judge → score_case_run). Run from REPO_ROOT so the
# bench.scorer imports resolve. The TEST-ONLY BENCH_NO_JUDGE bypass treats every
# gate-passing finding as a judge match (no model API call); the real path calls
# the cross-model judge via bench.scorer.judge.OpenAIClient.
#
# The scorer modules are imported, NOT reimplemented here; the inline Python is
# only the per-run glue (and stays out of bench/scorer/ so it is not in the
# coverage source tree).
score_report() {
  local report="$1" case_file="$2"
  (
    cd "${REPO_ROOT}" &&
      BENCH_NO_JUDGE="${BENCH_NO_JUDGE:-0}" \
      BENCH_JUDGE_MODEL="${JUDGE_MODEL_ID}" \
      BENCH_JUDGE_BACKEND="${JUDGE_BACKEND}" \
      BENCH_LINE_WINDOW="${LINE_WINDOW}" \
      python3 -c '
import os
import sys
import json

from bench.scorer.parse_report import parse_report
from bench.scorer.localize import gate
from bench.scorer.score import score_case_run, DETECTED, NOT_DETECTED
from bench.scorer.judge import judge_match, Judgement, OpenAIClient, CodexClient

report_path, case_path = sys.argv[1], sys.argv[2]
with open(case_path, encoding="utf-8") as fh:
    case = json.load(fh)
ground_truth = dict(case["ground_truth"])
ground_truth.setdefault("category", case.get("category", ""))

window = int(os.environ.get("BENCH_LINE_WINDOW", "10"))
no_judge = os.environ.get("BENCH_NO_JUDGE", "0") == "1"
judge_model = os.environ.get("BENCH_JUDGE_MODEL", "")

findings = parse_report(report_path)
pairs = []
for finding in findings:
    finding_map = {
        "file": finding.file,
        "line": finding.line,
        "category": finding.category,
        "rationale": finding.rationale,
    }
    gate_result = gate(finding_map, ground_truth, window=window)
    if no_judge:
        # TEST-ONLY: a gate-pass is treated as a judge match.
        judgement = Judgement(
            match=gate_result.passed, confidence=100,
            reason="judge-bypass", model="(none)", prompt_hash="(none)",
        )
    else:
        backend = os.environ.get("BENCH_JUDGE_BACKEND", "openai")
        if backend == "codex":
            client = CodexClient()
        else:
            client = OpenAIClient(api_key=os.environ.get("OPENAI_API_KEY", ""))
        judgement = judge_match(finding_map, ground_truth, client, judge_model)
    pairs.append((gate_result, judgement))

sys.stdout.write(score_case_run(pairs) if pairs else NOT_DETECTED)
' "${report}" "${case_file}"
  )
}

# Emit a verdicts.jsonl record for one (case, run, arm).
emit_verdict() {
  local verdicts="$1" case_id="$2" run="$3" arm="$4" verdict="$5" post_cutoff="$6"
  jq -n -c \
    --arg case_id "${case_id}" \
    --argjson run "${run}" \
    --arg arm "${arm}" \
    --arg verdict "${verdict}" \
    --argjson post_cutoff "${post_cutoff}" \
    '{case_id: $case_id, run: $run, arm: $arm, verdict: $verdict, post_cutoff: $post_cutoff}' \
    >>"${verdicts}"
}

# Write the ground_truths.json the leaderboard reads (case_id → {description,...}).
write_ground_truths() {
  local out="$1"; shift
  local cases=("$@")
  local tmp; tmp="$(mktemp)"
  echo '{}' >"${tmp}"
  local case_file case_id
  for case_file in "${cases[@]}"; do
    case_id="$(jq -r '.id' "${case_file}")"
    jq --arg id "${case_id}" --slurpfile gt <(jq '.ground_truth' "${case_file}") \
      '.[$id] = $gt[0]' "${tmp}" >"${tmp}.next"
    mv "${tmp}.next" "${tmp}"
  done
  mv "${tmp}" "${out}"
}

# Write the provenance.json the leaderboard enumerates. Per-case verified SHAs
# are the pinned pre-fix commits (sandbox.sh asserts the clone HEAD matches).
write_provenance() {
  local out="$1"; shift
  local cases=("$@")
  local shas; shas="$(mktemp)"
  echo '{}' >"${shas}"
  local case_file case_id sha
  for case_file in "${cases[@]}"; do
    case_id="$(jq -r '.id' "${case_file}")"
    sha="$(jq -r '.source.pre_fix_commit' "${case_file}")"
    jq --arg id "${case_id}" --arg sha "${sha}" '.[$id] = $sha' "${shas}" >"${shas}.next"
    mv "${shas}.next" "${shas}"
  done

  jq -n \
    --arg runner_model_id "${RUNNER_MODEL_ID}" \
    --arg runner_cutoff_date "${RUNNER_CUTOFF}" \
    --arg judge_model_id "${JUDGE_MODEL_ID}" \
    --arg judge_prompt_hash "${JUDGE_PROMPT_HASH}" \
    --arg bugsweep_commit "${BUGSWEEP_COMMIT}" \
    --slurpfile case_verified_shas "${shas}" \
    --arg container_image_digest "${CONTAINER_IMAGE_DIGEST}" \
    --arg egress_proxy_image "${EGRESS_PROXY_IMAGE}" \
    --argjson line_window "${LINE_WINDOW}" \
    --argjson k "${K}" \
    '{
      runner_model_id: $runner_model_id,
      runner_cutoff_date: $runner_cutoff_date,
      judge_model_id: $judge_model_id,
      judge_prompt_hash: $judge_prompt_hash,
      bugsweep_commit: $bugsweep_commit,
      case_verified_shas: $case_verified_shas[0],
      container_image_digest: $container_image_digest,
      egress_proxy_image: $egress_proxy_image,
      line_window: $line_window,
      k: $k
    }' >"${out}"
  rm -f "${shas}"
}

# The bugsweep commit being benchmarked (design row 55: labeled, not v0.1.0).
resolve_bugsweep_commit() {
  if [[ -n "${BENCH_BUGSWEEP_COMMIT:-}" ]]; then
    echo "${BENCH_BUGSWEEP_COMMIT}"
    return 0
  fi
  git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "(unknown)"
}

main() {
  local cases_arg="" results_root="${BENCH_RESULTS_DIR:-${REPO_ROOT}/results}"
  local arm_filter=""
  K="${DEFAULT_K}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cases) cases_arg="${2:-}"; shift 2 ;;
      -k | --k) K="${2:-}"; shift 2 ;;
      --results-root) results_root="${2:-}"; shift 2 ;;
      --arm) arm_filter="${2:-}"; shift 2 ;;
      -h | --help) usage ;;
      *) usage ;;
    esac
  done

  [[ -n "${cases_arg}" ]] || usage
  case "${K}" in '' | *[!0-9]*) die "-k must be a positive integer" ;; esac
  [[ "${K}" -ge 1 ]] || die "-k must be >= 1"

  command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
  command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"

  # Provenance / scoring config (env-overridable).
  RUNNER_MODEL_ID="${BENCH_RUNNER_MODEL_ID:-${DEFAULT_RUNNER_MODEL_ID}}"
  # Pin the model claude actually runs to the SAME id recorded in provenance, so
  # the leaderboard's runner_model_id is the model that ran, not a guess. Both
  # arms inherit this via isolate.sh's --env (and runner.sh on the test path).
  export BENCH_RUNNER_MODEL="${RUNNER_MODEL_ID}"
  RUNNER_CUTOFF="${BENCH_RUNNER_CUTOFF:-${DEFAULT_RUNNER_CUTOFF}}"
  JUDGE_BACKEND="${BENCH_JUDGE_BACKEND:-${DEFAULT_JUDGE_BACKEND}}"
  case "${JUDGE_BACKEND}" in
    openai | codex) ;;
    *) die "BENCH_JUDGE_BACKEND must be 'openai' or 'codex' (got '${JUDGE_BACKEND}')" ;;
  esac
  # codex backend pins gpt-5.3-codex by default; an explicit override still wins.
  if [[ "${JUDGE_BACKEND}" == "codex" && -z "${BENCH_JUDGE_MODEL_ID:-}" ]]; then
    JUDGE_MODEL_ID="${DEFAULT_CODEX_JUDGE_MODEL_ID}"
  else
    JUDGE_MODEL_ID="${BENCH_JUDGE_MODEL_ID:-${DEFAULT_JUDGE_MODEL_ID}}"
  fi
  LINE_WINDOW="${BENCH_LINE_WINDOW:-${DEFAULT_LINE_WINDOW}}"
  CONTAINER_IMAGE_DIGEST="${BENCH_CONTAINER_IMAGE_DIGEST:-${DEFAULT_CONTAINER_IMAGE_DIGEST}}"
  EGRESS_PROXY_IMAGE="${BENCH_EGRESS_PROXY_IMAGE:-${DEFAULT_EGRESS_PROXY_IMAGE}}"
  CONTAINER_IMAGE="${BENCH_CONTAINER_IMAGE:-${DEFAULT_CONTAINER_IMAGE}}"
  BUGSWEEP_COMMIT="$(resolve_bugsweep_commit)"

  # Real-run preconditions + provenance image-id resolution. On the TEST-ONLY
  # BENCH_NO_CONTAINER path none of this applies (no container, no proxy, no key).
  if real_path; then
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH; required for a live run (or set BENCH_NO_CONTAINER=1 for the test bypass)"
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY is not set; a live run needs the dedicated, revocable key exported (see bench/README.md). Refusing to run."
    # A locally-built image has no registry digest; record its image id. Env
    # overrides win; otherwise resolve from the built image (best-effort).
    if [[ "${CONTAINER_IMAGE_DIGEST}" == "${DEFAULT_CONTAINER_IMAGE_DIGEST}" ]]; then
      CONTAINER_IMAGE_DIGEST="$(docker image inspect --format '{{.Id}}' "${CONTAINER_IMAGE}" 2>/dev/null || echo "${DEFAULT_CONTAINER_IMAGE_DIGEST}")"
    fi
    if [[ "${EGRESS_PROXY_IMAGE}" == "${DEFAULT_EGRESS_PROXY_IMAGE}" ]]; then
      local _proxy_img="${BENCH_PROXY_IMAGE:-${DEFAULT_PROXY_IMAGE}}"
      local _proxy_id; _proxy_id="$(docker image inspect --format '{{.Id}}' "${_proxy_img}" 2>/dev/null || echo unknown)"
      EGRESS_PROXY_IMAGE="${_proxy_img}@${_proxy_id}"
    fi
  fi
  # The judge prompt hash is per-finding at score time; the provenance records
  # the judge prompt TEMPLATE hash (the committed judge instructions) so the
  # leaderboard always carries the field, run from REPO_ROOT for the import.
  JUDGE_PROMPT_HASH="$(
    cd "${REPO_ROOT}" && python3 -c '
import hashlib
from bench.scorer.judge import _INSTRUCTIONS
print(hashlib.sha256(_INSTRUCTIONS.encode("utf-8")).hexdigest())
'
  )"

  local arms=()
  case "${arm_filter}" in
    "") arms=("${ARM_BUGSWEEP}" "${ARM_BASELINE}") ;;
    "${ARM_BUGSWEEP}") arms=("${ARM_BUGSWEEP}") ;;
    "${ARM_BASELINE}") arms=("${ARM_BASELINE}") ;;
    *) die "--arm must be ${ARM_BUGSWEEP} or ${ARM_BASELINE}" ;;
  esac

  local cases=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && cases+=("${line}")
  done < <(collect_cases "${cases_arg}")
  [[ "${#cases[@]}" -ge 1 ]] || die "no case JSONs found under ${cases_arg}"

  # Timestamped run dir.
  local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local run_dir="${results_root}/${ts}"
  mkdir -p "${run_dir}"
  local verdicts="${run_dir}/verdicts.jsonl"
  : >"${verdicts}"

  # Start the egress proxy for the whole run (real path only) and arrange for it
  # to be torn down on any exit. proxy.sh writes proxy-usage.json into the same
  # run dir (BENCH_RESULTS_DIR=results_root, run-id=ts).
  if real_path; then
    _PROXY_RESULTS_DIR="${results_root}"
    BENCH_RESULTS_DIR="${results_root}" "${LIB_DIR}/proxy.sh" start "${ts}" \
      || die "could not start egress proxy"
    _PROXY_RUN_ID="${ts}"
    trap stop_proxy EXIT
  fi

  local case_file case_id disclosure post_cutoff arm runner run n
  for case_file in "${cases[@]}"; do
    "${LIB_DIR}/validate_case.sh" "${case_file}" \
      || die "case failed validation: ${case_file}"
    case_id="$(jq -r '.id' "${case_file}")"
    disclosure="$(jq -r '.source.disclosure_date' "${case_file}")"
    if case_is_post_cutoff "${disclosure}"; then post_cutoff=true; else post_cutoff=false; fi

    for arm in "${arms[@]}"; do
      if [[ "${arm}" == "${ARM_BUGSWEEP}" ]]; then runner="${RUNNER_BUGSWEEP}"; else runner="${RUNNER_BASELINE}"; fi

      for ((n = 1; n <= K; n++)); do
        local run_out="${run_dir}/${arm}/${case_id}/run-${n}"
        # Create the run dir up front so sandbox.sh's clone has an existing
        # parent (it refuses a pre-existing clone dir, so we do NOT create that).
        mkdir -p "${run_out}"
        # Each run gets a fresh hardened clone (a run must not see another run's
        # config override / scratch).
        local clone="${run_out}/clone"
        prepare_clone "${case_file}" "${clone}" >/dev/null

        local result verdict
        result="$(run_arm "${runner}" "${case_file}" "${clone}" "${run_out}")"

        case "${result}" in
          RAN)
            verdict="$(score_report "${run_out}/report.md" "${case_file}")"
            ;;
          SKIP) verdict="SKIPPED" ;;
          *) verdict="ERROR" ;;
        esac

        emit_verdict "${verdicts}" "${case_id}" "${n}" "${arm}" "${verdict}" "${post_cutoff}"
      done
    done
  done

  # Tear down the egress proxy now: scoring's cross-model judge runs HOST-side
  # and needs no container egress. (The EXIT trap remains as a safety net.)
  stop_proxy

  write_ground_truths "${run_dir}/ground_truths.json" "${cases[@]}"
  write_provenance "${run_dir}/provenance.json" "${cases[@]}"

  # Render the leaderboard from the run artifacts.
  ( cd "${REPO_ROOT}" && python3 -m bench.scorer.leaderboard "${run_dir}" ) \
    || die "leaderboard render failed"

  echo "run.sh: wrote ${run_dir}/leaderboard.md"
}

main "$@"
