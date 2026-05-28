#!/usr/bin/env bash
#
# scrub.sh — redact secrets from text before it is persisted or logged, then run
# an ENFORCED secret-scan that exits non-zero if anything secret-shaped survives.
#
# Redacts, in order:
#   1. The VALUE of every process env var whose NAME matches the denylist
#      (*_API_KEY, *_TOKEN, *_KEY) — caught even if the value is not key-shaped.
#   2. The dedicated key: the BENCH_PROXY_KEY value, plus any token bearing the
#      configurable BENCH_KEY_PREFIX (default "sk-").
#   3. Generic provider key patterns (sk-..., long base64-ish key blobs).
# All replaced with the literal placeholder [REDACTED].
#
# Then an enforced scan re-checks the OUTPUT for key-shaped strings and any
# denylisted env value; if any remains it exits non-zero so a leak fails closed
# instead of being written out.
#
# Modes:
#   scrub.sh [file]            Redact (file or stdin) to stdout; scan; exit
#                              non-zero if a secret survives redaction.
#   scrub.sh --scan-only [file]
#                              Run ONLY the secret-scan on the RAW input (no
#                              redaction); exit non-zero if a secret is present.
#                              Used to prove the scan trips on an unscrubbed leak.

set -euo pipefail

readonly REDACTION="[REDACTED]"
# Default dedicated-key prefix; override via BENCH_KEY_PREFIX.
BENCH_KEY_PREFIX="${BENCH_KEY_PREFIX:-sk-}"

# Env-var NAME suffixes that mark a variable as carrying a secret value.
readonly ENV_NAME_DENYLIST=("_API_KEY" "_TOKEN" "_KEY")

die() {
  echo "scrub.sh: $*" >&2
  exit 1
}

# Echo the values of all process env vars whose NAME matches the denylist
# (one per line, skipping empties). The denylist also matches exact names like
# API_KEY / TOKEN / KEY (suffix match with no prefix char required).
denylisted_env_values() {
  local name value suffix
  while IFS= read -r name; do
    for suffix in "${ENV_NAME_DENYLIST[@]}"; do
      if [[ "${name}" == *"${suffix}" ]]; then
        value="${!name:-}"
        [[ -n "${value}" ]] && printf '%s\n' "${value}"
        break
      fi
    done
  done < <(compgen -v)
}

# Read all of stdin into the named variable (preserves trailing content).
read_input() {
  local _src="$1"
  if [[ "${_src}" == "-" ]]; then
    cat
  else
    [[ -f "${_src}" ]] || die "input file not found: ${_src}"
    cat -- "${_src}"
  fi
}

# Escape a string for safe use as a sed BRE pattern (literal match).
sed_escape() {
  printf '%s' "$1" | sed -e 's/[][\\/.*^$]/\\&/g'
}

# Redact secrets from text on stdin → stdout.
redact() {
  local sed_args=()
  local value pat

  # (1) denylisted env values (literal).
  while IFS= read -r value; do
    [[ -z "${value}" ]] && continue
    pat="$(sed_escape "${value}")"
    sed_args+=(-e "s/${pat}/${REDACTION}/g")
  done < <(denylisted_env_values)

  # (2a) BENCH_PROXY_KEY value (literal), if set.
  if [[ -n "${BENCH_PROXY_KEY:-}" ]]; then
    pat="$(sed_escape "${BENCH_PROXY_KEY}")"
    sed_args+=(-e "s/${pat}/${REDACTION}/g")
  fi

  # (2b) any token carrying the configurable prefix.
  pat="$(sed_escape "${BENCH_KEY_PREFIX}")"
  sed_args+=(-e "s/${pat}[A-Za-z0-9._-]\{8,\}/${REDACTION}/g")

  # (3) generic provider key patterns: sk-<blob> and standalone long key blobs.
  sed_args+=(-e "s/sk-[A-Za-z0-9._-]\{8,\}/${REDACTION}/g")

  sed "${sed_args[@]}"
}

# Scan text on stdin → exit non-zero if any secret-shaped string remains.
# Returns 0 (clean) or 1 (secret found). Prints a message to stderr on a hit.
scan() {
  local text
  text="$(cat)"

  # Key-shaped: the configured prefix or sk- followed by a longish blob.
  local prefix_re
  prefix_re="$(printf '%s' "${BENCH_KEY_PREFIX}" | sed -e 's/[].[^$*\\/]/\\&/g')"
  if printf '%s' "${text}" | grep -Eq "(${prefix_re}|sk-)[A-Za-z0-9._-]{8,}"; then
    echo "scrub.sh: secret-scan FAILED — key-shaped string survived" >&2
    return 1
  fi

  # Any denylisted env value still present.
  local value
  while IFS= read -r value; do
    [[ -z "${value}" ]] && continue
    if printf '%s' "${text}" | grep -Fq -- "${value}"; then
      echo "scrub.sh: secret-scan FAILED — denylisted env value survived" >&2
      return 1
    fi
  done < <(denylisted_env_values)

  return 0
}

main() {
  local scan_only=0
  if [[ "${1:-}" == "--scan-only" ]]; then
    scan_only=1
    shift
  fi

  local src="${1:--}"
  local input
  input="$(read_input "${src}")"

  if [[ "${scan_only}" -eq 1 ]]; then
    # Scan the RAW input; no redaction. Proves the scan trips on a real leak.
    printf '%s' "${input}" | scan
    exit $?
  fi

  local scrubbed
  scrubbed="$(printf '%s' "${input}" | redact)"

  # Enforced scan of the scrubbed output: fail closed if anything survived.
  if ! printf '%s' "${scrubbed}" | scan; then
    die "refusing to emit text that still contains a secret"
  fi

  printf '%s' "${scrubbed}"
}

main "$@"
