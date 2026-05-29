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

@test "isolate --print-cmd mounts a WRITABLE /out for the captured report" {
  BENCH_OUT="$BATS_TMP/out" run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" ":/out"
  refute_contains "$output" ":/out:ro"
}

@test "isolate --print-cmd mounts the bench harness read-only at /bench" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" ":/bench:ro"
}

@test "isolate --print-cmd routes egress through the proxy" {
  run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" "HTTPS_PROXY=http://bench-proxy:8888"
}

# ---------------------------------------------------------------------------
# isolate.sh --print-cmd : key handling (key-in-container model)
# ---------------------------------------------------------------------------
# The dedicated, revocable ANTHROPIC_API_KEY is the ONE permitted passthrough,
# injected BY NAME (docker reads the value from the host env; the value never
# appears in the argv). Every other key-shaped env stays out — most importantly
# the OpenAI judge key, which is host-only.

@test "isolate --print-cmd passes ANTHROPIC_API_KEY by name, never its value" {
  ANTHROPIC_API_KEY="sk-dedicated-should-not-appear" \
    run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  assert_contains "$output" "--env ANTHROPIC_API_KEY"
  refute_contains "$output" "sk-dedicated-should-not-appear"
  refute_contains "$output" "ANTHROPIC_API_KEY="
}

@test "isolate --print-cmd refuses the OpenAI judge key (host-only)" {
  OPENAI_API_KEY="sk-judge-host-only" \
    run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  refute_contains "$output" "OPENAI_API_KEY"
  refute_contains "$output" "sk-judge-host-only"
}

@test "isolate --print-cmd refuses other key/token-shaped env" {
  GITHUB_TOKEN="ghp_should_not_appear" \
  SOME_SECRET_KEY="topsecret-not-here" \
    run "$ISOLATE_SH" --print-cmd bench/img:latest
  [ "$status" -eq 0 ]
  refute_contains "$output" "GITHUB_TOKEN"
  refute_contains "$output" "ghp_should_not_appear"
  refute_contains "$output" "SOME_SECRET_KEY"
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

@test "proxy --print-cmd shows the exact-host CONNECT allow-list" {
  run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "allow_hosts=api.anthropic.com"
  assert_contains "$output" "connect_allow=api.anthropic.com:443"
  assert_contains "$output" "match_mode=exact_host"
}

@test "proxy --print-cmd honors BENCH_PROXY_ALLOW extension" {
  BENCH_PROXY_ALLOW="api.openai.com" run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "api.openai.com:443"
}

@test "proxy --print-cmd marks the analysis network internal (no internet)" {
  run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "network_internal=true"
}

@test "proxy --print-cmd ALLOWS CONNECT (it is the tunnel mechanism now)" {
  # The chosen model is a CONNECT-only allow-list (end-to-end TLS), NOT the old
  # MITM key-injecting proxy. CONNECT must be permitted (to allowed hosts).
  run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "refuse_connect=false"
}

@test "proxy --print-cmd marks the key as living in the container" {
  # End-to-end TLS: the key rides inside the encrypted CONNECT stream; the proxy
  # neither sees nor injects it. So NO inject_key_from / strip_client_auth.
  run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  assert_contains "$output" "key_in_container=true"
  refute_contains "$output" "inject_key_from"
  refute_contains "$output" "strip_client_auth"
}

@test "proxy --print-cmd does not leak any key-shaped env value" {
  ANTHROPIC_API_KEY="sk-dedicated-secret" \
  BENCH_PROXY_KEY="sk-legacy-secret" run "$PROXY_SH" --print-cmd
  [ "$status" -eq 0 ]
  refute_contains "$output" "sk-dedicated-secret"
  refute_contains "$output" "sk-legacy-secret"
}

# ---------------------------------------------------------------------------
# proxy.sh start : per-run usage log (wiring-only via BENCH_PROXY_NO_LAUNCH)
# ---------------------------------------------------------------------------

@test "proxy start (no-launch) writes an initialized proxy-usage.json" {
  cd "$BATS_TMP"
  # BENCH_PROXY_NO_LAUNCH keeps Tier-A container-free: init the log + wiring,
  # do not launch the forwarder (mirrors run.sh's BENCH_NO_CONTAINER bypass).
  BENCH_PROXY_NO_LAUNCH=1 run "$PROXY_SH" start run-test-123
  [ "$status" -eq 0 ]
  [ -f "$BATS_TMP/results/run-test-123/proxy-usage.json" ]
  run cat "$BATS_TMP/results/run-test-123/proxy-usage.json"
  # End-to-end TLS = the proxy is blind to tokens; it records CONNECT counts.
  assert_contains "$output" "\"connect_requests\""
  assert_contains "$output" "\"denied_connects\""
}

@test "proxy stop succeeds for a started run" {
  cd "$BATS_TMP"
  BENCH_PROXY_NO_LAUNCH=1 "$PROXY_SH" start run-stop-456 >/dev/null
  BENCH_PROXY_NO_LAUNCH=1 run "$PROXY_SH" stop run-stop-456
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
