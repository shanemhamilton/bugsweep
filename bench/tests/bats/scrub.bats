#!/usr/bin/env bats
#
# Tier-A tests for scrub.sh — redact key-shaped strings + denylisted env values
# from text (file or stdin), then run an enforced secret-scan that exits
# non-zero if anything key-shaped survives.

load helpers

SCRUB_SH="${BENCH_LIB_DIR}/scrub.sh"

setup() {
  BATS_TMP="$(mktemp -d)"
  export BATS_TMP
}

teardown() {
  [[ -n "${BATS_TMP:-}" && -d "$BATS_TMP" ]] && rm -rf "$BATS_TMP"
}

# ---------------------------------------------------------------------------
# Redaction: generic key patterns (sk-...)
# ---------------------------------------------------------------------------

@test "scrub redacts a generic sk- key from stdin and passes the scan" {
  run bash -c "printf 'leak sk-LIVEKEY123abcDEF456 here\n' | '$SCRUB_SH'"
  [ "$status" -eq 0 ]
  refute_contains "$output" "sk-LIVEKEY123abcDEF456"
}

@test "scrub redacts a generic sk- key from a file" {
  printf 'token=sk-LIVEKEY123abcDEF456\n' >"${BATS_TMP}/in.txt"
  run "$SCRUB_SH" "${BATS_TMP}/in.txt"
  [ "$status" -eq 0 ]
  refute_contains "$output" "sk-LIVEKEY123abcDEF456"
}

# ---------------------------------------------------------------------------
# Redaction: the dedicated-key prefix (BENCH_PROXY_KEY value + configurable
# BENCH_KEY_PREFIX)
# ---------------------------------------------------------------------------

@test "scrub redacts a BENCH_PROXY_KEY value present in the input" {
  export BENCH_PROXY_KEY="dedicated-secret-value-zzz"
  run bash -c "printf 'using dedicated-secret-value-zzz now\n' | '$SCRUB_SH'"
  [ "$status" -eq 0 ]
  refute_contains "$output" "dedicated-secret-value-zzz"
}

@test "scrub redacts strings carrying the configurable BENCH_KEY_PREFIX" {
  export BENCH_KEY_PREFIX="bws-"
  run bash -c "printf 'key bws-CUSTOMPREFIXKEY9999 inline\n' | '$SCRUB_SH'"
  [ "$status" -eq 0 ]
  refute_contains "$output" "bws-CUSTOMPREFIXKEY9999"
}

# ---------------------------------------------------------------------------
# Redaction: env-var-NAME denylist (*_API_KEY, *_TOKEN, *_KEY) — the VALUE of
# any matching env var is redacted from the input.
# ---------------------------------------------------------------------------

@test "scrub redacts the value of an env var matching *_API_KEY" {
  export ACME_API_KEY="acme-api-key-value-7777"
  run bash -c "printf 'config ACME=acme-api-key-value-7777 done\n' | '$SCRUB_SH'"
  [ "$status" -eq 0 ]
  refute_contains "$output" "acme-api-key-value-7777"
}

@test "scrub redacts the value of an env var matching *_TOKEN" {
  export CI_TOKEN="ci-token-value-8888"
  run bash -c "printf 'auth CI_TOKEN=ci-token-value-8888 ok\n' | '$SCRUB_SH'"
  [ "$status" -eq 0 ]
  refute_contains "$output" "ci-token-value-8888"
}

@test "scrub redacts the value of an env var matching *_KEY" {
  export SIGNING_KEY="signing-key-value-9999"
  run bash -c "printf 'sign with signing-key-value-9999 here\n' | '$SCRUB_SH'"
  [ "$status" -eq 0 ]
  refute_contains "$output" "signing-key-value-9999"
}

# ---------------------------------------------------------------------------
# Non-secret text is preserved
# ---------------------------------------------------------------------------

@test "scrub leaves ordinary text intact" {
  run bash -c "printf 'a finding in app/db/users.py:88\n' | '$SCRUB_SH'"
  [ "$status" -eq 0 ]
  assert_contains "$output" "app/db/users.py:88"
}

# ---------------------------------------------------------------------------
# Enforced scan: a key that survives makes the scan exit non-zero.
# --scan-only runs the secret-scan on raw input WITHOUT redacting, so a planted
# key reaches the scan and must trip it (the "deliberately-broken path").
# ---------------------------------------------------------------------------

@test "scrub --scan-only exits non-zero when a key-shaped string is present" {
  run bash -c "printf 'oops sk-LIVEKEY123abcDEF456 leaked\n' | '$SCRUB_SH' --scan-only"
  [ "$status" -ne 0 ]
}

@test "scrub --scan-only exits non-zero when a denylisted env value is present" {
  export ACME_API_KEY="acme-api-key-value-7777"
  run bash -c "printf 'leaked acme-api-key-value-7777 here\n' | '$SCRUB_SH' --scan-only"
  [ "$status" -ne 0 ]
}

@test "scrub --scan-only exits zero on clean text" {
  run bash -c "printf 'totally clean line\n' | '$SCRUB_SH' --scan-only"
  [ "$status" -eq 0 ]
}

@test "scrub fails closed when given a nonexistent file" {
  run "$SCRUB_SH" "${BATS_TMP}/nope.txt"
  [ "$status" -ne 0 ]
}
