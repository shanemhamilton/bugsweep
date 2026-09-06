#!/usr/bin/env bats

@test "a recovered check cannot hide another check regressing" {
  run env PYTHONDONTWRITEBYTECODE=1 python3 -B - "${BATS_TEST_DIRNAME}/../.." <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
from scripts import _proof

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    target, run = root / "source", root / "run"
    target.mkdir(); run.mkdir()
    (target / "app.py").write_text("pass\n")
    plan = {"run_id": "swap", "target_root": str(target), "deadline_epoch": 9999999999,
            "source_file_sha256": {"app.py": hashlib.sha256(b"pass\n").hexdigest()},
            "execution_policy": {"mode": "required-untrusted"},
            "checks": [{"name": name, "command": ["synthetic", name]} for name in ("test", "build")]}
    (run / "check-plan.json").write_text(json.dumps(plan))
    for phase, statuses, expected in (("baseline", {"test": "fail", "build": "pass"}, 0),
                                      ("verify", {"test": "pass", "build": "fail"}, 1)):
        def record(_run, _request, entry, _index):
            return {"check": entry["name"], "status": statuses[entry["name"]]}
        # Synthetic results exercise the real gate; no target command runs.
        with patch.object(_proof, "_check_record", side_effect=record):
            assert _proof._run_checks(phase, run) == expected
    receipt = json.loads((run / "check-results-verify.json").read_text())
    assert receipt["regressions"] == ["check:build"]
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *REGRESSION* ]]
}
