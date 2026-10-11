# Test-only authority and provider fixtures for integrate.bats.
# The production path remains scripts._execution; this fixture replaces only
# its run_command/receipt-validation boundary in the test process.

_write_integration_provider_stub() {
  local path="$1" real_python="$2"
  mkdir -p "$path"
  cat >"$path/python3" <<PY
#!${real_python}
import hashlib
import importlib
import json
import os
from pathlib import Path
import runpy
import sys

def _digest(value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()

def _source_files(root):
    files = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or ".git" in path.relative_to(root).parts:
            continue
        files[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return dict(sorted(files.items()))

def _run_stub(command, cwd, output_dir, deadline_epoch, policy=None, env_allowlist=None, predeclared_outputs=()):
    target = Path(cwd)
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    source = _source_files(target)
    marker_a = os.environ.get("MARKER_A")
    marker_b = os.environ.get("MARKER_B")
    exit_code = 1 if marker_a and marker_b and (target / Path(marker_a).name).is_file() and (target / Path(marker_b).name).is_file() else 0
    log_path = os.environ.get("CALL_LOG")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write("provider\\n")
    return {
        "schema_version": 1, "invocation_id": "a" * 32, "termination": "exited", "exit_code": exit_code, "reason": None,
        "provider_metadata": {"kind": "synthetic-test-only", "execution": "stubbed"},
        "backend": {"name": "docker", "engine_sha256": "b" * 64, "image_digest": "c" * 64},
        "backend_readback_path": "/tmp/test-only-backend-readback.json", "backend_readback_sha256": "d" * 64, "backend_readback_verified": True,
        "capabilities": {"isolation": "verified", "network": "verified_denied", "deadline": "process_group_term_kill_reap", "output_import": "trusted_side", "evidence_tier": "verified_backend"},
        "source_identity": {"kind": "content-manifest-sha256", "sha256": _digest(source), "source_file_sha256": source},
        "source_manifest_sha256": _digest(source), "command": list(command), "command_sha256": _digest(list(command)),
        "config_sha256": real_execution.execution_config_sha256(policy or {}, predeclared_outputs),
        "environment_sha256": real_execution.execution_environment_sha256(env_allowlist or {}),
    }

args = sys.argv[1:]
script_index = next((index for index, value in enumerate(args) if Path(value).name == "_integration_checks.py"), None)
if script_index is None:
    os.execv("${real_python}", ["${real_python}", *args])
script_path = Path(args[script_index]).resolve()
sys.path.insert(0, str(script_path.parent.parent))
real_execution = importlib.import_module("scripts._execution")
real_execution.run_command = _run_stub
real_execution.validate_execution_receipt = lambda receipt, expected_source_map, required_network="denied": []
sys.argv = [args[script_index], *args[script_index + 1:]]
runpy.run_path(args[script_index], run_name="__main__")
PY
  chmod +x "$path/python3"
}

_write_integration_authority() {
  local run_dir="$1"
  # REAL_PYTHON is initialized by the Bats setup hook before this fixture runs.
  # shellcheck disable=SC2153
  local python_bin="${REAL_PYTHON}"
  mkdir -p "$run_dir" "${run_dir}/scratch"
  "$python_bin" - "$REPO" "$run_dir" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

repo, run = Path(sys.argv[1]), Path(sys.argv[2])
scratch = run / "scratch"

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()

tracked = subprocess.run(
    ["git", "-C", str(repo), "ls-files", "-z"],
    check=True,
    stdout=subprocess.PIPE,
).stdout.split(b"\x00")
files = {}
for raw_path in tracked:
    if not raw_path:
        continue
    relative = raw_path.decode("utf-8")
    path = repo.joinpath(*relative.split("/"))
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"tracked fixture path is not a regular file: {relative}")
    files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
files = dict(sorted(files.items()))
manifest = digest(files)
policy = {"mode": "required-untrusted", "backend": "docker", "target_root": str(repo), "scratch_root": str(scratch), "source_identity": {"kind": "content-manifest-sha256", "sha256": manifest, "source_file_sha256": files}}
command = ["/bin/true"]
stable_policy = {key: value for key, value in policy.items() if key not in {"source_identity", "target_root", "scratch_root"}}
config_sha = digest({"policy": stable_policy, "outputs": []})
environment_sha = digest({"allowlist": {}, "fixed_path": "/usr/bin:/bin:/usr/sbin:/sbin", "home": "ephemeral", "scratch_mount": "/bugsweep-output"})
execution = {"schema_version": 1, "invocation_id": "e" * 32, "termination": "exited", "exit_code": 0, "reason": None, "provider_metadata": {"kind": "synthetic-test-only", "execution": "stubbed"}, "backend": {"name": "docker", "engine_sha256": "b" * 64, "image_digest": "c" * 64}, "backend_readback_path": "/tmp/test-only-backend-readback.json", "backend_readback_sha256": "d" * 64, "backend_readback_verified": True, "capabilities": {"isolation": "verified", "network": "verified_denied", "deadline": "process_group_term_kill_reap", "output_import": "trusted_side", "evidence_tier": "verified_backend"}, "source_identity": {"kind": "content-manifest-sha256", "sha256": manifest, "source_file_sha256": files}, "source_manifest_sha256": manifest, "command": command, "command_sha256": digest(command), "config_sha256": config_sha, "environment_sha256": environment_sha, "execution_policy": policy}
check = {"check": "integration-test", "status": "pass", "command_sha256": digest(command), "config_sha256": config_sha, "environment_sha256": environment_sha, "execution": execution}
plan = {"run_id": "integration-test", "target_root": str(repo), "deadline_epoch": 4102444800, "source_file_sha256": files, "execution_policy": policy, "checks": [{"name": "integration-test", "command": command}]}
stable_plan = dict(plan)
stable_plan.pop("source_file_sha256")
stable_plan["execution_policy"] = {key: value for key, value in policy.items() if key != "source_identity"}
baseline = {"schema_version": 1, "run_id": "integration-test", "phase": "baseline", "plan_sha256": digest(stable_plan), "source_file_sha256": files, "source_manifest_sha256": manifest, "checks": [check], "regressions": [], "proof_error": False, "proof_errors": [], "execution_policy_mode": "required-untrusted"}
(run / "check-plan.json").write_text(json.dumps(plan, sort_keys=True), encoding="utf-8")
(run / "baseline.json").write_text(json.dumps(baseline, sort_keys=True), encoding="utf-8")
PY
}
