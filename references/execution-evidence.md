# Execution and review evidence

The installed Python coordinator treats project commands as data. It mounts a disposable
target tree and fresh output scratch, creates a container from a digest-pinned image,
reads back Docker's effective configuration before start, then captures bounded outputs
outside both mounts. Check, repro, analyzer and native-review consumers reuse
`validate_execution_receipt`; flags or filenames alone never confer verified status.

## Configure a target-check policy

Store the policy outside the target and name its absolute path through preflight's
`--execution-policy` or installed `execution.policy_file`. The operator supplies:

- `schema_version: 1`, `mode: required-untrusted`, `backend: docker`.
- Canonical `canonical_engine_path` and SHA-256 of that exact Docker executable.
- Digest-pinned `image`, non-root `uid` as `uid:gid`, `pids_limit`, `memory_bytes`, `cpus`.
- Existing external `scratch_root`, `term_grace_seconds`, `network_mode: none`.
- `source_mount_mode: worktree-rw` for checks. A linked worktree's regular `.git`
  pointer is omitted from the source hash; a `.git` directory is rejected.
- Exact nonsecret `image_env_allowlist`; undeclared image environment fails readback.

The preparation helper supplies the exact `target_root` and complete `source_identity`
from source bytes. The policy must match that target if it already names one. The
provider validates engine/image identity, security settings, mounts, network, resources,
and environment. It rejects sockets, device nodes, unsafe links and authority paths
inside mounted trees. Commands must send declared artifacts to `/bugsweep-output`.
No native or host-shell fallback is eligible for an automatic fix.

`canonical_json_bytes` is the shared SHA-256 serialization: sorted keys, compact UTF-8,
no nonfinite values. The source manifest hashes the direct map of relative paths to
content hashes. Command/config/environment hashes are independent of that changing map.
Execution receipts also bind the actual mount inventory and readback bytes.

## Checks and reproduction

Preflight writes `source-files.nul`, `execution-preparation.json`, and `check-plan.json`.
For isolated-worktree runs, `run-provenance.json` freezes the installed `SKILL.md`,
version, helper/reference/schema/template hashes and modes, effective configuration
hash, and observed Python/platform/jsonschema versions. Preparation binds this immutable
record by its byte hash. The coordinator model remains explicitly unknown when the
shell cannot observe it; native review receipts record their configured host/model.
The full source inventory is separate from `scope-files.txt`, which limits the hunt.
It includes every regular file the execution can see, including new untracked tests;
the provider and preparation helper share the same inventory implementation.
`_prepare_execution.py checks RUN_DIR` refreshes source hashes while preserving the
frozen commands/settings. Check results use unique paths under `check-results/`;
`baseline.json` and `check-results-verify.json` identify their immutable artifacts.

A repro specification has exactly these fields:

- `command`: argv array, including the native reporter's output argument.
- `test`: `path`, `native_id`, `expected_failure_type: assertion`, and
  `expected_failure_message`. The coordinator derives `sha256` from test bytes.
- `intended_source_files`: production files allowed to change, excluding the test.
- `junit_path`: relative output path, for example `repro.xml` when the command writes
  `/bugsweep-output/repro.xml`.
- `review_source_file_sha256`: the complete source map used by first assessments.

Prepare/run `repro-pre`, apply the intended fix, refresh/run the suite, then prepare/run
`repro-post`. Both phases must identify the same test, expected assertion, command,
settings and environment. `proofs/BUG.prestate.json` preserves the original request;
`proofs/BUG.json` is the immutable original red/green proof.

For the final combined tree, use:

```bash
python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" checks "$RUN_DIR"
bash "$SKILL_ROOT/scripts/run_checks.sh" verify "$RUN_DIR"
python3 -B "$SKILL_ROOT/scripts/_prepare_execution.py" reverify "$RUN_DIR" "$BUG_ID" "$ORIGINAL_FIX_COMMIT"
bash "$SKILL_ROOT/scripts/repro.sh" reverify "$RUN_DIR" "$BUG_ID" "$RETURNED_REQUEST_PATH"
```

Each `fix_reverified` receipt proves the unchanged regression test remains green on the
final source. It binds the original commit/proof and current suite without replacing
the original red/green record. Preserve earlier revalidation attempts too.

## Native first assessments

Configure installed `adversarial.hosts` as a map from `claude` and/or `codex` to explicit
approved model IDs. Preflight freezes those IDs and the installed review prompt hash.
The request must match that contract and stay within the run deadline. Candidate file
and line must exist in the complete captured source snapshot.

`review-evidence.sh prepare PACKET.json` takes `run_dir`, `run_id`, `bug_id`, `role`
(`skeptic` or `referee`), `host`, `model`, `source_sha256`, `source_root`, and `candidate`
with exactly `file`, `line`, `claim`, `trigger`. The coordinator freezes one candidate
before dispatch and withholds prior assessment records. It rejects explicit prior-verdict
metadata; arbitrary source prose still remains untrusted input, not a proven blind study.

`run REQUEST --policy EXTERNAL_POLICY --deadline EPOCH` invokes the pinned image adapter
with a fresh native session. Native reviews require the verified `approved-proxy-only`
profile: exact internal/egress network identities, proxy container/image, approved caps,
pinned adapter/arm image labels and proxy receipt. The real key stays in the proxy's
external secret mount; the model client receives only an inert credential. A claimed
proxy approval or readback flag is insufficient. Tests and analyzers use denied network.

Preparation preserves the reviewed file bytes under `reviews/BUG/source-SHA256` outside
the worktree. Native execution uses that copy with `source_mount_mode: archive-ro`;
no Git metadata is included, and Docker must report the source mount read-only.
Later fixes can change the worktree without changing the original review evidence.

Only captured native terminal events and immutable request/execution/output hashes
count as review evidence. The verifier rejects reused sessions and invented ledger
votes. Call `reveal` after all first assessments; `verify` decides majority eligibility.
This proves execution lineage and withheld coordinator verdicts, not independence or
calibrated model probabilities.

## Validation limits

Pure tests cover parsing, counterexamples and simulated backend contracts. They do not
prove Docker compatibility, outside-write/network denial, actual model-host behavior,
cap enforcement, human calibration or benchmark superiority. Release evaluation must
supply those real artifacts under the frozen protocol; unknown evidence blocks release.
