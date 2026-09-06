#!/usr/bin/env python3
"""Prepare coordinator-owned execution requests. Never execute target commands."""
from __future__ import annotations

import argparse
import hashlib
from importlib.metadata import version
import json
import os
import platform
import stat
from pathlib import Path, PurePosixPath
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts._execution import canonical_json_bytes, _capture_source_files
from scripts._analyzer_norm import DEFAULT_LIMITS
from scripts._review_evidence import INSTRUCTIONS, _id, _path, _read, _write_once, _sync_dir

SKILL_ROOT = Path(__file__).resolve().parents[1]


def run_provenance(run_id, config):
    """Inventory the installed runtime payload without consulting Git or login state."""
    files = {}
    for name in ("SKILL.md", "VERSION", "scripts", "references", "schemas", "templates", "assets"):
        entry = SKILL_ROOT / name
        for path in sorted(entry.rglob("*")) if entry.is_dir() else [entry]:
            relative = path.relative_to(SKILL_ROOT)
            if "__pycache__" in relative.parts or path.suffix == ".pyc":
                continue
            if path.is_symlink():
                raise ValueError("installed runtime payload contains a symlink")
            if path.is_file():
                files[relative.as_posix()] = {"sha256": hashlib.sha256(_read(path)).hexdigest(),
                                              "mode": stat.S_IMODE(path.stat().st_mode)}
    if "SKILL.md" not in files or "VERSION" not in files:
        raise ValueError("installed runtime lacks SKILL.md or VERSION")
    return {"schema_version": 1, "run_id": run_id, "skill_root": str(SKILL_ROOT),
            "skill_version": _read(SKILL_ROOT / "VERSION").decode().strip(),
            "skill_files": files, "skill_manifest_sha256": _hash(files),
            "effective_config_sha256": _hash(config),
            "runtime": {"python_version": platform.python_version(),
                        "python_executable": sys.executable, "platform": platform.system(),
                        "architecture": platform.machine(), "jsonschema_version": version("jsonschema")},
            "coordinator_model": None, "coordinator_model_reason": "not_observable_from_preflight"}


def _hash(value):
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def _json(path):
    value = json.loads(_read(path))
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def _publish(path, value):
    """Pointers can move; their referenced history is append-only."""
    path = _path(path)
    record = _write_once(path.parent / "preparation-history" / (uuid.uuid4().hex + ".json"), value)
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    _write_once(temporary, value)
    os.replace(temporary, path)
    _sync_dir(path.parent)
    return record


def _relative(value):
    if (not isinstance(value, str) or not value or "\\" in value or "\x00" in value
            or PurePosixPath(value).is_absolute() or ".." in PurePosixPath(value).parts
            or str(PurePosixPath(value)) != value or value == "."):
        raise ValueError("expected a canonical repository-relative file")
    return value


def snapshot(target, files):
    target = _path(target)
    for relative in files:
        _relative(relative)
    # Share the provider's complete inventory: new files and deletions must be
    # visible, and a checkout containing repository metadata cannot be mounted.
    return _capture_source_files(target, allow_symlinks=False)


def _checks(target, config):
    commands = config.get("commands", {})
    if not isinstance(commands, dict):
        raise ValueError("commands must be an object")
    detected = {}
    if (target / "package.json").is_file():
        scripts = _json(target / "package.json").get("scripts", {})
        if isinstance(scripts, dict):
            detected = {name: ["npm", "run", name, "--silent"]
                        for name in ("test", "build", "typecheck", "lint") if name in scripts}
    elif (target / "go.mod").is_file():
        detected = {"test": ["go", "test", "./..."], "build": ["go", "build", "./..."]}
    elif (target / "Cargo.toml").is_file():
        detected = {"test": ["cargo", "test", "--quiet"], "build": ["cargo", "build", "--quiet"]}
    elif any((target / name).is_file() for name in ("pyproject.toml", "pytest.ini", "setup.cfg")):
        detected = {"test": ["python3", "-B", "-m", "pytest", "-p", "no:cacheprovider",
                             "-q", "--junitxml=/bugsweep-output/suite.xml"]}
    result = []
    for name in ("test", "build", "typecheck", "lint"):
        explicit = commands.get(name)
        if explicit:
            if isinstance(explicit, str):
                entry = {"name": name, "command": ["/bin/sh", "-c", explicit]}
            elif isinstance(explicit, dict) and set(explicit) <= {"command", "junit_path"}:
                entry = {"name": name, **explicit}
            else:
                raise ValueError("command must be text or an argv/JUnit descriptor")
        elif name in detected:
            entry = {"name": name, "command": detected[name]}
            if "--junitxml=/bugsweep-output/suite.xml" in entry["command"]:
                entry["junit_path"] = "suite.xml"
        else:
            continue
        command = entry.get("command")
        if (not isinstance(command, list) or not command
                or any(not isinstance(item, str) or not item or "\x00" in item for item in command)):
            raise ValueError("invalid command argv")
        if "junit_path" in entry:
            _relative(entry["junit_path"])
        result.append(entry)
    return result


def _policy(state, sources):
    policy = state.get("policy")
    if not isinstance(policy, dict):
        raise ValueError("execution unavailable: configure an external required-untrusted policy")
    return {**policy, "target_root": state["target_root"], "source_identity": {
        "kind": "content-manifest-sha256", "sha256": _hash(sources), "source_file_sha256": sources}}


def refresh_checks(run_dir):
    run = _path(run_dir)
    state = _json(run / "execution-preparation.json")
    sources = snapshot(state["target_root"], state["source_files"])
    state["source_files"] = sorted(sources)
    _publish(run / "execution-preparation.json", state)
    plan = {"run_id": state["run_id"], "target_root": state["target_root"],
            "deadline_epoch": state["deadline_epoch"], "checks": state["checks"],
            "source_file_sha256": sources, "execution_policy": _policy(state, sources)}
    _publish(run / "source-digests.json", sources)
    _publish(run / "check-plan.json", plan)
    return {"path": str(run / "check-plan.json"), "source_manifest_sha256": _hash(sources),
            "available": bool(plan["checks"])}


def initialize(run_dir, target_root, run_id, deadline_epoch, config_path, files_path, policy_path=None):
    run, target = _path(run_dir), _path(target_root)
    if run == target or target in run.parents:
        raise ValueError("execution authority must be outside target; use preflight --worktree")
    config_path = _path(config_path)
    if config_path == target or target in config_path.parents:
        raise ValueError("execution configuration must be installed outside target")
    config = _json(config_path)
    raw_files = _path(files_path).read_bytes()
    if len(raw_files) > 16 * 1024 * 1024 or not raw_files.endswith(b"\x00"):
        raise ValueError("expected a bounded NUL-terminated complete file inventory")
    files = [_relative(item.decode("utf-8")) for item in raw_files[:-1].split(b"\x00")]
    if len(set(files)) != len(files) or len(files) > 100_000:
        raise ValueError("duplicate or excessive source inventory")
    policy, reason = None, "external_execution_policy_not_configured"
    if policy_path:
        external = _path(policy_path)
        if target == external or target in external.parents:
            raise ValueError("policy must be outside target")
        policy = _json(external)
        if policy.get("mode") != "required-untrusted" or policy.get("backend") != "docker":
            raise ValueError("automatic checks require the required-untrusted Docker policy")
        if policy.get("target_root", str(target)) != str(target):
            raise ValueError("policy targets a different source tree")
        policy.pop("source_identity", None)
        reason = None
    state = {"schema_version": 1, "run_id": run_id, "target_root": str(target),
             "deadline_epoch": deadline_epoch, "source_files": files,
             "config_sha256": _hash(config), "policy": policy, "checks": _checks(target, config),
             "review_hosts": config.get("adversarial", {}).get("hosts", {}),
             "review_prompt_sha256": hashlib.sha256(INSTRUCTIONS.encode()).hexdigest(),
             "analyzer_configs": config.get("analyzers", {}).get("imports", []),
             "analyzer_enabled": config.get("analyzers", {}).get("enabled") is True,
             "analyzer_timeout_seconds": config.get("analyzers", {}).get("timeout_seconds", 300),
             "analyzer_limits": {key: config.get("analyzers", {}).get(key, default)
                                 for key, default in DEFAULT_LIMITS.items()}}
    sources = snapshot(target, files)
    state["source_files"] = sorted(sources)
    provenance = _write_once(run / "run-provenance.json", run_provenance(run_id, config))
    state["run_provenance_sha256"] = provenance["sha256"]
    _write_once(run / "execution-preparation.json", state)
    _publish(run / "source-digests.json", sources)
    tools = config.get("analyzers", {}).get("imports", [])
    configured = sorted({item if isinstance(item, str) else item.get("tool")
                         for item in tools if isinstance(item, (str, dict))
                         and isinstance(item if isinstance(item, str) else item.get("tool"), str)}
                        & {"codeql", "semgrep"})
    _write_once(run / "analyzer-imports.json", {"schema_version": 1,
                "configured_tools": configured, "imports": []})
    _write_once(run / "execution-availability.json", {"schema_version": 1,
                "configured": policy is not None, "verified": False, "reason": reason})
    return refresh_checks(run) if policy else {"available": False, "reason": reason}


def repro_pre(run_dir, bug_id, spec_path):
    _id(bug_id)
    run = _path(run_dir)
    state, spec = _json(run / "execution-preparation.json"), _json(spec_path)
    if set(spec) != {"command", "test", "intended_source_files", "junit_path", "review_source_file_sha256"}:
        raise ValueError("repro specification must freeze command, test, intended files, JUnit path and review source")
    test = spec["test"]
    if not isinstance(test, dict):
        raise ValueError("invalid test identity")
    test_path = _relative(test.get("path"))
    intended = spec["intended_source_files"]
    if not isinstance(intended, list) or not intended or test_path in intended:
        raise ValueError("intended fix files must exclude the unchanged regression test")
    additions = [test_path, *[_relative(item) for item in intended]]
    state["source_files"] = sorted(set(state["source_files"] + additions))
    sources = snapshot(state["target_root"], state["source_files"])
    state["source_files"] = sorted(sources)
    review_sources = spec["review_source_file_sha256"]
    if not isinstance(review_sources, dict) or not review_sources:
        raise ValueError("missing full pre-fix review source map")
    if any(sources.get(name) != sha for name, sha in review_sources.items() if name != test_path):
        raise ValueError("reviewed production source changed before the regression test")
    # Identity is derived from bytes, never accepted as the model's claimed test hash.
    test = {**test, "sha256": sources[test_path]}
    request = {**spec, "test": test, "bug_id": bug_id, "run_id": state["run_id"],
               "target_root": state["target_root"], "deadline_epoch": state["deadline_epoch"],
               "source_file_sha256": sources, "before_execution_policy": _policy(state, sources),
               "review_source_manifest_sha256": _hash(review_sources)}
    path = run / "repro-requests" / _relative(bug_id) / "pre.json"
    _write_once(path, request)
    _publish(run / "execution-preparation.json", state)
    return {"path": str(path)}


def repro_post(run_dir, bug_id, original_fix_commit=None):
    _id(bug_id)
    run = _path(run_dir)
    state = _json(run / "execution-preparation.json")
    original = _json(run / "repro-requests" / _relative(bug_id) / "pre.json")
    sources = snapshot(state["target_root"], state["source_files"])
    pointer = _json(run / "check-results-verify.json")
    request = {**original, "source_file_sha256": sources,
               "after_execution_policy": _policy(state, sources),
               "suite_receipt": {key: pointer[key] for key in ("immutable_path", "immutable_sha256")}}
    if original_fix_commit is not None:
        import re
        if not re.fullmatch(r"[0-9a-f]{40,64}", original_fix_commit):
            raise ValueError("original fix commit must be an exact object id")
        request["original_fix_commit"] = original_fix_commit
    path = run / "repro-requests" / bug_id / ("post-" + uuid.uuid4().hex + ".json")
    _write_once(path, request)
    return {"path": str(path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    init = commands.add_parser("init")
    init.add_argument("run_dir")
    for field in ("target_root", "run_id", "config_path", "files_path"):
        init.add_argument("--" + field.replace("_", "-"), required=True)
    init.add_argument("--deadline-epoch", type=float, required=True)
    init.add_argument("--policy-path")
    commands.add_parser("checks").add_argument("run_dir")
    for action in ("repro-pre", "repro-post", "reverify"):
        cmd = commands.add_parser(action)
        cmd.add_argument("run_dir")
        cmd.add_argument("bug_id")
        if action == "repro-pre":
            cmd.add_argument("spec_path")
        elif action == "reverify":
            cmd.add_argument("original_fix_commit")
        else:
            cmd.add_argument("--original-fix-commit")
    args = vars(parser.parse_args())
    action = args.pop("action")
    try:
        function = {"init": initialize, "checks": refresh_checks,
                    "repro-pre": repro_pre, "repro-post": repro_post, "reverify": repro_post}[action]
        print(canonical_json_bytes(function(**args)).decode())
        return 0
    except (OSError, ValueError, KeyError, TypeError, UnicodeError) as exc:
        print(canonical_json_bytes({"available": False, "error": str(exc)}).decode())
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
