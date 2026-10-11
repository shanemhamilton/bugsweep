# Test-only authority and provider fixtures for integrate.bats.
# The production path remains scripts._execution; this fixture replaces only
# its run_command boundary in integration-check subprocesses.

INTEGRATION_FIXTURE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

_write_integration_provider_stub() {
  local path="$1" real_python="$2"
  mkdir -p "$path"
  export BUGSWEEP_TEST_PROJECT_ROOT="$INTEGRATION_FIXTURE_ROOT"
  cat >"$path/python3" <<PY
#!${real_python}
import os
import importlib.util
import importlib
from pathlib import Path
import runpy
import sys

args = sys.argv[1:]
script_index = next((index for index, value in enumerate(args) if Path(value).name == "_integration_checks.py"), None)
if script_index is None:
    os.execv("${real_python}", ["${real_python}", *args])
script_path = Path(args[script_index]).resolve()
sys.path.insert(0, str(script_path.parent.parent))
project_root = Path(os.environ["BUGSWEEP_TEST_PROJECT_ROOT"])
sys.path.insert(0, str(project_root))
spec = importlib.util.spec_from_file_location("landed_fixture", project_root / "tests" / "bats" / "landed_fixture.py")
if spec is None or spec.loader is None:
    raise SystemExit("test-only landed receipt fixture is unavailable")
landed_fixture = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = landed_fixture
spec.loader.exec_module(landed_fixture)

def _run_stub(command, cwd, output_dir, deadline_epoch, policy=None, env_allowlist=None, predeclared_outputs=()):
    target = Path(cwd)
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    marker_a = os.environ.get("MARKER_A")
    marker_b = os.environ.get("MARKER_B")
    exit_code = 1 if marker_a and marker_b and (target / Path(marker_a).name).is_file() and (target / Path(marker_b).name).is_file() else 0
    log_path = os.environ.get("CALL_LOG")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write("provider\\n")
    return landed_fixture._receipt(command, target, output, policy, exit_code=exit_code,
                                   predeclared_outputs=predeclared_outputs,
                                   environment=env_allowlist)

real_execution = importlib.import_module("scripts._execution")
real_execution.run_command = _run_stub
sys.argv = [args[script_index], *args[script_index + 1:]]
runpy.run_path(args[script_index], run_name="__main__")
PY
  chmod +x "$path/python3"
}

_write_integration_authority() {
  local run_dir="$1"
  local authority_run_id="${2:-integration-test}"
  # REAL_PYTHON is initialized by the Bats setup hook before this fixture runs.
  # shellcheck disable=SC2153
  local python_bin="${REAL_PYTHON}"
  mkdir -p "$run_dir" "${run_dir}/scratch"
  "$python_bin" - "$REPO" "$run_dir" "$authority_run_id" "$INTEGRATION_FIXTURE_ROOT" <<'PY'
import hashlib
import importlib.util
import json
import shutil
from pathlib import Path
import subprocess
import sys

repo, run, authority_run_id, project_root = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
scratch = run / "scratch"
sys.path.insert(0, str(project_root))

spec = importlib.util.spec_from_file_location("landed_fixture", project_root / "tests" / "bats" / "landed_fixture.py")
if spec is None or spec.loader is None:
    raise SystemExit("test-only landed receipt fixture is unavailable")
landed_fixture = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = landed_fixture
spec.loader.exec_module(landed_fixture)

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
policy = landed_fixture._policy(run, repo, files, approved=False)
baseline_source = run / "baseline-source"
shutil.rmtree(baseline_source, ignore_errors=True)
landed_fixture._copy_source(repo, baseline_source, files)
receipt_policy = {**policy, "target_root": str(baseline_source)}
command = ["/bin/true"]
execution = landed_fixture._receipt(command, baseline_source, run / "baseline-artifacts", receipt_policy)
check = {"check": "integration-test", "status": "pass", "command_sha256": execution["command_sha256"], "config_sha256": execution["config_sha256"], "environment_sha256": execution["environment_sha256"], "execution": execution}
plan = {"run_id": "integration-test", "target_root": str(repo), "deadline_epoch": 4102444800, "source_file_sha256": files, "execution_policy": policy, "checks": [{"name": "integration-test", "command": command}]}
plan["run_id"] = authority_run_id
stable_plan = dict(plan)
stable_plan.pop("source_file_sha256")
stable_plan["execution_policy"] = {key: value for key, value in policy.items() if key != "source_identity"}
baseline = {"schema_version": 1, "run_id": authority_run_id, "phase": "baseline", "plan_sha256": digest(stable_plan), "source_file_sha256": files, "source_manifest_sha256": manifest, "checks": [check], "regressions": [], "proof_error": False, "proof_errors": [], "execution_policy_mode": "required-untrusted"}
(run / "check-plan.json").write_text(json.dumps(plan, sort_keys=True), encoding="utf-8")
(run / "baseline.json").write_text(json.dumps(baseline, sort_keys=True), encoding="utf-8")
PY
}
