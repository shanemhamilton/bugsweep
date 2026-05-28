#!/usr/bin/env bats
#
# Tier-A (container-free) tests for the isolation + egress-proxy bash glue.
# These assert ARGUMENT CONSTRUCTION and fail-closed control flow only — they
# never launch a container or a live proxy.

load helpers

setup() {
  BATS_TMP="$(mktemp -d)"
  export BATS_TMP
}

teardown() {
  [[ -n "${BATS_TMP:-}" && -d "$BATS_TMP" ]] && rm -rf "$BATS_TMP"
}

# ---------------------------------------------------------------------------
# isolate.sh --print-cmd : flag VALUES (not just presence)
# ---------------------------------------------------------------------------

@test "isolate --print-cmd emits the proxy network by exact value" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" "--network=bench-proxynet"
}

@test "isolate --print-cmd emits read-only root filesystem" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" "--read-only"
}

@test "isolate --print-cmd emits the cpu limit value" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" "--cpus=2"
}

@test "isolate --print-cmd emits the memory limit value" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" "--memory=4g"
}

@test "isolate --print-cmd emits the pids limit value" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" "--pids-limit=512"
}

@test "isolate --print-cmd runs as a non-root user" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" "--user 65534:65534"
}

@test "isolate --print-cmd mounts a tmpfs scratch dir" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" "--tmpfs /scratch"
}

@test "isolate --print-cmd mounts the clone read-only at /work" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" ":/work:ro"
}

# ---------------------------------------------------------------------------
# isolate.sh --print-cmd : key-free container (negative tests)
# ---------------------------------------------------------------------------

@test "isolate --print-cmd passes NO *_API_KEY env into the container" {
  # Seed key-shaped env vars; the printed argv must not leak any of them.
  ANTHROPIC_API_KEY="sk-should-not-appear" \
  OPENAI_API_KEY="sk-also-not" \
    run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  refute_contains "$output" "_API_KEY="
  refute_contains "$output" "sk-should-not-appear"
}

@test "isolate --print-cmd passes NO *_TOKEN env into the container" {
  GITHUB_TOKEN="ghp_should_not_appear" \
    run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  refute_contains "$output" "_TOKEN="
  refute_contains "$output" "ghp_should_not_appear"
}

@test "isolate --print-cmd passes NO *_KEY env into the container" {
  SOME_SECRET_KEY="topsecret-not-here" \
    run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  refute_contains "$output" "_KEY="
  refute_contains "$output" "topsecret-not-here"
}

# ---------------------------------------------------------------------------
# isolate.sh : fail closed when docker is absent
# ---------------------------------------------------------------------------

@test "isolate fails closed (exit 1) when docker is absent" {
  BENCH_FAKE_NO_DOCKER=1 run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 1 ]
  assert_contains "$output" "docker"
}

# ---------------------------------------------------------------------------
# proxy.sh --print-cmd : egress-proxy wiring
# ---------------------------------------------------------------------------

@test "proxy --print-cmd binds the bench proxy network" {
  run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "network=bench-proxynet"
}

@test "proxy --print-cmd shows the exact-host upstream allow-list" {
  run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "allow_hosts=api.anthropic.com"
}

@test "proxy --print-cmd honors BENCH_PROXY_ALLOW extension" {
  BENCH_PROXY_ALLOW="api.openai.com" run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "api.openai.com"
}

@test "proxy --print-cmd refuses CONNECT tunneling" {
  run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "refuse_connect=true"
}

@test "proxy --print-cmd strips inbound client auth headers" {
  run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "strip_client_auth=true"
}

@test "proxy --print-cmd injects the dedicated key from BENCH_PROXY_KEY" {
  run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "inject_key_from=BENCH_PROXY_KEY"
}

@test "proxy --print-cmd does not leak the BENCH_PROXY_KEY value" {
  BENCH_PROXY_KEY="sk-dedicated-secret" run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  refute_contains "$output" "sk-dedicated-secret"
}

# ---------------------------------------------------------------------------
# proxy.sh start : per-run usage log
# ---------------------------------------------------------------------------

@test "proxy start writes an initialized proxy-usage.json under results/<run-id>" {
  cd "$BATS_TMP"
  run "$PROXY_SH" start run-test-123
  [ "$status" -eq 0 ]
  [ -f "$BATS_TMP/results/run-test-123/proxy-usage.json" ]
  run cat "$BATS_TMP/results/run-test-123/proxy-usage.json"
  assert_contains "$output" "\"requests\""
  assert_contains "$output" "\"tokens\""
}

@test "proxy stop succeeds for a started run" {
  cd "$BATS_TMP"
  "$PROXY_SH" start run-stop-456 >/dev/null
  run "$PROXY_SH" stop run-stop-456
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# proxy.sh : fail closed when docker is absent
# ---------------------------------------------------------------------------

@test "proxy fails closed (exit 1) when docker is absent" {
  cd "$BATS_TMP"
  BENCH_FAKE_NO_DOCKER=1 run "$PROXY_SH" start run-nodock-789
  [ "$status" -eq 1 ]
  assert_contains "$output" "docker"
}
