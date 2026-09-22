"""Static WU6 image-contract checks; no Docker build, CLI, or network use."""

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


def test_analysis_image_requires_local_verified_binaries_and_provider_labels() -> None:
    dockerfile = (ROOT / "bench/docker/Dockerfile").read_text()
    assert "ARG BENCH_BASE_IMAGE" in dockerfile
    assert "COPY bin/claude" in dockerfile and "COPY bin/codex" in dockerfile
    assert "org.bugsweep.adapter.sha256" in dockerfile
    assert "org.bugsweep.arms.sha256" in dockerfile
    assert "curl" not in dockerfile and "apt-get" not in dockerfile


def test_build_stages_distinct_arm_snapshots_without_git_or_installer() -> None:
    build = (ROOT / "bench/docker/build.sh").read_text()
    assert "BENCH_CURRENT_SKILL_SRC" in build and "BENCH_PREVIOUS_SKILL_SRC" in build
    assert "arms/current_skill" in build and "arms/previous_release" in build
    assert "BENCH_CLAUDE_CLI_BIN" in build and "BENCH_CODEX_CLI_BIN" in build
    assert "git -C" not in build and "install.sh" not in build
    assert "copy_snapshot" in build and "dirs if d != '.git'" in build


def test_proxy_image_uses_the_source_verified_stdlib_provider_proxy() -> None:
    dockerfile = (ROOT / "bench/docker/Dockerfile.proxy").read_text()
    assert "ARG BENCH_PROXY_BASE_IMAGE" in dockerfile
    assert "COPY provider_proxy.py" in dockerfile
    assert "COPY provider_proxy_entrypoint.sh" in dockerfile
    assert 'ENTRYPOINT ["/usr/local/bin/bugsweep-provider-proxy"]' in dockerfile
    assert "PROXY_SOURCE_SHA256" in dockerfile
    assert "FROM nginx" not in dockerfile


def test_proxy_launch_has_the_provider_readback_confinement_contract() -> None:
    proxy = (ROOT / "bench/lib/proxy.sh").read_text()
    for required in ("--read-only", "--cap-drop ALL", "--security-opt no-new-privileges",
                     "--pids-limit 64", "--memory 134217728", "--memory-swap 134217728",
                     "--cpus 1.0", "--ipc none", "--tmpfs /tmp:rw,noexec,nosuid,nodev,size=16777216",
                     "--mount \"type=bind,src=${cfg_dir}/proxy-policy.json,dst=/etc/bugsweep/proxy-policy.json,readonly\"",
                     "--mount \"type=bind,src=${secret_file},dst=/run/secrets/provider-key,readonly\""):
        assert required in proxy


def test_review_entrypoint_uses_the_fixed_no_arm_read_only_path() -> None:
    adapter = (ROOT / "bench/docker/bench-host-adapter").read_text()
    claude = (ROOT / "bench/runners/claude_json.sh").read_text()
    codex = (ROOT / "bench/runners/codex_json.sh").read_text()

    assert '[[ "$1" == "review" ]]' in adapter
    assert "review host model prompt" in adapter
    assert 'mode="review"' in adapter
    assert 'selected_arm="review"' in adapter
    assert 'review)' in claude and 'allowed_tools="Read"' in claude
    assert 'review)' in codex and 'readonly_sandbox=(--sandbox read-only)' in codex
    assert "--ignore-user-config --ignore-rules" in codex


def test_benchmark_arms_are_prompt_bound_to_detect_only_skill_excerpts() -> None:
    claude = (ROOT / "bench/runners/claude_json.sh").read_text()
    codex = (ROOT / "bench/runners/codex_json.sh").read_text()
    for runner in (claude, codex):
        assert '"${skill_root}/SKILL.md"' in runner
        assert "IMMUTABLE BENCHMARK SKILL EXCERPT" in runner
        assert "first-finding-unix-seconds.txt" in runner
        assert "adapter-metadata.json" in runner
        assert "--sandbox read-only" in runner or 'allowed_tools="Read"' in runner


def test_review_adapter_streams_fake_native_json_without_scratch_artifacts(tmp_path: Path) -> None:
    """Review is stdout-only, so R3 can consume native JSON directly."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    output = tmp_path / "output"
    output.mkdir()
    for host, endpoint, binary in (("claude", "ANTHROPIC_BASE_URL", "claude"), ("codex", "CODEX_BENCH_BASE_URL", "codex")):
        executable = fake_bin / binary
        executable.write_text("#!/bin/sh\nprintf '{\\\"type\\\":\\\"safe-event\\\"}\\n'\n")
        executable.chmod(0o755)
        env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}", endpoint: "http://owned-proxy:8888",
               "BENCH_INERT_CLIENT_ID": "benchmark-inert-client-credential", "BUGSWEEP_OUTPUT_DIR": str(output)}
        result = subprocess.run(["bash", str(ROOT / "bench/runners" / f"{host}_json.sh"), "pinned", "review prompt", "review"], env=env, check=True, text=True, capture_output=True)
        assert result.stdout == '{"type":"safe-event"}\n'
        assert not list(output.iterdir())


def test_benchmark_adapter_imports_fake_native_json_and_metadata(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"; fake_bin.mkdir()
    output = tmp_path / "output"; output.mkdir()
    for host, endpoint, binary in (("claude", "ANTHROPIC_BASE_URL", "claude"), ("codex", "CODEX_BENCH_BASE_URL", "codex")):
        executable = fake_bin / binary
        executable.write_text("#!/bin/sh\nprintf '{\\\"text\\\":\\\"FINDING: app.py:1\\\"}\\n'\n")
        executable.chmod(0o755)
        env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}", endpoint: "http://owned-proxy:8888",
               "BENCH_INERT_CLIENT_ID": "benchmark-inert-client-credential", "BUGSWEEP_OUTPUT_DIR": str(output)}
        result = subprocess.run(["bash", str(ROOT / "bench/runners" / f"{host}_json.sh"), "pinned", "benchmark prompt", "no_skill_baseline"], env=env, check=True, text=True, capture_output=True)
        assert "FINDING:" in result.stdout
        metadata = (output / "adapter-metadata.json").read_text()
        assert '"loaded_skill_sha256":null' in metadata
        (output / "response.jsonl").unlink(); (output / "adapter-metadata.json").unlink()
