# Bugsweep evaluation harness

The development harness compares Claude and Codex separately across current-skill,
previous-release and no-skill arms. It freezes the schedule and seeded execution order,
records every attempted slot, and retains missing results, errors and unknown costs.

**Current evidence status:** local contract tests pass. Fresh native corpus oracles,
actual host and Docker runs, calibrated human labels and final independent review are
not complete. The 20 held-out and five pilot case records are unverified inventory;
several oracle tests failed review because they did not exercise the stated defect.
Historical results under `results/` do not validate this new protocol.

## What this experiment measures

`evaluation_mode: reduced_detect_only_prompt_methodology` means a read-only source
investigation with bounded text from the selected immutable `SKILL.md` inserted into
the native prompt. It excludes operational Git, tracker, fix and closeout work. Receipts
record the effective prompt hash. This mode does not measure the complete operational
skill. `core_arms` names the skill comparison; `ablation_blocks` independently declares
`full_pipeline`, `without_skeptic`, `without_referee` and `hunter_only`. Each declared
Hunter, Skeptic or Referee assessment uses a separate native call. Referee first
assessments receive only Hunter claims with status/confidence withheld. A separate
synthesis call then reconciles the recorded assessments; it is not counted as another
independent first assessment. Native session IDs must be distinct across all stages.
Non-Hunter stages retain every candidate with an explicit confirmed/rejected outcome. All stages within a
slot share one deadline and one proxy budget. Actual stage-effect measurements remain
unavailable until the frozen experiments and human reviews run.

Freeze at least three repetitions per case and host before collecting evidence. With
20 cases, two hosts and three core arms, three repetitions schedule 360 pipeline slots
per stage block (1,440 across the four example blocks). Each pipeline slot may contain
several native calls; its cap applies to the whole pipeline.
The five pilot cases must remain separate from the held-out set and from threshold tuning.
A valid case needs an independently checked native assertion that fails for the defect,
passes for the fixed source, and meaningful controls. Counts and metadata are insufficient.

## Prepare a frozen experiment

Use Python 3.12+ and the dependencies in the root `pyproject.toml`. These preparation
commands do not invoke Docker, a model, an installer or target repository code:

```bash
bash bench/run.sh evaluation \
  --protocol /absolute/operator/draft-protocol.json \
  --cases /absolute/operator/redacted-cases.json -k 3 \
  --freeze-dir /absolute/authority/new-experiment
```

The draft follows `bench/evaluation-protocol.json`; its replacement values and zero/null
caps are placeholders, not permission to spend. Supply exact host/model versions,
current/previous whole-snapshot `skill_content_sha256` and individual
`SKILL.md` `skill_entrypoint_sha256` identities (null for the baseline),
adapter/prompt/configuration identities and the version/hash of the rate table,
approved caps and the approval record. The freeze command writes:

- `evaluation-protocol.json`: identities, caps, repetitions and both document digests.
- `schedule.json`: one expected case/host/repetition row covering the core arms and stage blocks,
  including the hash of that case's redacted prompt manifest.
- `execution-order.json`: seeded arm/block order with unique ordinals and slot hashes.

The coordinator case manifest includes opaque `id`, language, generic `task_description`,
category/repository accounting fields and `source_manifest_sha256`. Only the generic
redacted task fields reach the model. Gold descriptions, expected locations, mutations,
test oracles, private labels and evaluator files stay outside all analysis mounts.
The source digest is SHA-256 over the canonical direct map of relative file paths to
file-content hashes, shared with the execution provider.

## Native execution prerequisites

`bench/docker/build.sh` accepts digest-pinned base images and existing verified local
Claude/Codex binaries plus frozen current/previous skill snapshots. Its required
`BENCH_*` variables are declared at the top of that script. It never downloads a CLI or
runs an installer. Image build and live execution require a prepared runtime and an
approved experiment budget; they have not been run for this development change.

Every invocation uses the shared provider in `scripts/_execution.py` and an external
operator-owned policy. That policy requires `source_mount_mode: archive-ro`: a complete
source snapshot with no Git metadata, symlinks, hardlinks or special files. The effective
source mount is read-only. Declared outputs are imported from a separate writable scratch
mount into coordinator storage, where actual bytes and hashes are checked.

The standard-library proxy in `bench/provider_proxy.py` fixes the upstream provider,
model and native POST path. Only its external secret mount contains the dedicated real
key; analysis receives an inert credential. Operator configuration supplies request and
response byte limits, in-flight limit, turn/token/spend caps, a conservative spend
reservation and rate-card values. Rate-derived costs are labeled `rate_estimated`.
Do not treat local proxy tests as proof of live caps or provider billing.

For a prepared single slot, `bench/lib/proxy.sh start` takes the invocation ID, host,
absolute 0600 secret file and approved cap document. The emitted proxy receipt supplies
exact network/container identities for the external execution profile. Run the slot with
`BENCH_TRUSTED_BENCHMARK_PROFILE` naming that profile:

```bash
bash bench/run.sh evaluation \
  --protocol /absolute/authority/new-experiment/evaluation-protocol.json \
  --cases /absolute/operator/redacted-cases.json \
  --invoke-slot /absolute/authority/slot.json \
  --source-root /absolute/source/archive \
  --output-dir /absolute/authority/invocation-output
```

Stop that exact owned proxy after the invocation. Do not prestart hundreds of proxies
or reuse a proxy between arms. The managed coordinator starts and stops one proxy per
ordinal, preserves partial-start and interrupted slots, and stops starting work when
owned cleanup remains uncertain:

```bash
python3 -B -m bench.harness \
  --protocol /absolute/authority/new-experiment/evaluation-protocol.json \
  --cases /absolute/operator/redacted-cases.json --invoke-all \
  --trusted-source-map /absolute/operator/source-roots.json \
  --host-policy-templates /absolute/operator/host-templates.json \
  --proxy-secret-files /absolute/operator/secret-paths.json \
  --approved-cap-documents /absolute/operator/cap-paths.json \
  --proxy-results-dir /absolute/authority/proxy-results \
  --proxy-receipts-dir /absolute/authority/proxy-receipts \
  --materialized-profile-dir /absolute/authority/profiles \
  --output-root /absolute/authority/new-results
```

Create the three proxy/profile directories first. The source map maps case IDs to
archive paths; each other map uses host names as keys and absolute file paths as values.
Host templates contain `execution_policy` and `benchmark_static` (`analysis`, `client`,
`arms`); the coordinator fills actual proxy identities from the startup receipt.
Lifecycle contract tests pass locally; actual Docker execution and final cap/drain
verification remain unavailable. Post-stop evidence preserves that limitation explicitly.

## Evidence and scoring

Invocation receipts bind the frozen order, source before/after hashes, actual execution,
raw response, effective prompt, configured/applied caps, usage and lifecycle. Per-stage
artifacts live under `invocation-N/stages/NN-role/`; the importer verifies the complete
stage chain. Pipeline accounting includes every stage and paid failure, spans the full
execution interval, and retains the earliest observed finding time. Missing
native accounting stays unknown. Failed and skipped slots remain in attrition and cost
accounting. A finding's source excerpt must come from the trusted source snapshot.

The native prompt declares a final `{"candidates": [...]}` response, including confirmed
and rejected candidates. Import it without invoking a judge or model:

```bash
python3 -B -m bench.scorer.precision_score /absolute/authority/new-review-export \
  --harness-results /absolute/authority/new-results \
  --frozen-dir /absolute/authority/new-experiment
```

The export defaults to `full_pipeline`. Repeat with `--stage-block without_skeptic`
(or another frozen block) and a separate output directory for each experiment. Each
export contains `calibration-records.json` and separate `blinded-packets.json`. Give
reviewers only the blinded packets. Record their actual labels and adjudications in
separate JSON arrays; retain the frozen frame and unblinding map. Verification rebuilds
the frame from native artifacts before using it. Malformed output remains unverified,
while a valid empty candidate array records zero findings. Every candidate keeps its
host, arm, case and repetition identity. No human labels are generated automatically.

`bench/scorer/calibration.py` freezes candidate sampling and blinded packets, requires
two actual human labels and adjudication of disagreements, preserves sampling weights,
and produces per-host/per-arm metrics and paired case-cluster uncertainty. Labels created
by a model or a test fixture cannot count as human calibration. Rejected candidates are
audited separately; their audit does not automatically reopen or fix a finding.
Release metrics use high/critical confirmed candidates, weighted review time and yield,
and complete actual costs including failed invocations. Review-time comparisons use
inclusion-weighted medians. Rate estimates remain descriptive. Paired inference requires
complete shared censuses; independent marginal samples do not establish pair
probabilities. A completely resolved census has exact precision for that finite corpus,
without population inference. Degenerate intervals from sampled data cannot establish
release confidence. Missing uncertainty leaves the decision inconclusive.

Finalize completed human records without a model call:

```bash
python3 -B -m bench.scorer.calibration_finalize \
  --records /absolute/authority/new-review-export/calibration-records.json \
  --labels /absolute/authority/primary-labels.json \
  --adjudications /absolute/authority/adjudications.json \
  --output-dir /absolute/authority/new-human-evidence \
  --source-manifest-sha256 SHA256_OF_TESTED_SKILL_SNAPSHOT \
  --tested-revision EXACT_REVISION --invocation-id EXPERIMENT_ID
```

This writes `completed-calibration-records.json`, `human-calibration.json` and a summary.
The evidence binds every candidate, reviewer, label, review duration and reason to the
calculated metrics. Fewer than 60 reviewed candidates or incomplete native/human evidence
produces a `blocked` artifact with empty label arrays and null metrics. The completed
records and summary preserve partial observations. Exit zero means files were produced;
read the artifact result for evidence completeness.

`reduce_evaluation` in `bench/scorer/evaluation.py` combines the frozen protocol, schedule,
execution order, receipts, calibration and required evidence. It distinguishes evaluation
execution, a proceed/redesign/inconclusive decision, and release eligibility. To verify
a published reducer result, the quality gate recomputes it from the same actual inputs:

```bash
bash scripts/quality-check.sh \
  --evaluation /absolute/authority/evaluation-result.json \
  --protocol /absolute/authority/new-experiment/evaluation-protocol.json \
  --schedule /absolute/authority/new-experiment/schedule.json \
  --execution-order /absolute/authority/new-experiment/execution-order.json \
  --receipts /absolute/authority/benchmark-receipts.json \
  --calibration /absolute/authority/new-human-evidence/completed-calibration-records.json \
  --stage-calibration /absolute/authority/without-skeptic/completed-calibration-records.json \
  --required-evidence /absolute/operator/required-evidence.json \
  --evidence-root /absolute/authority/evidence
```

Repeat `--stage-calibration` for each remaining stage block. The reducer keeps their
human frames and metrics separate from the `full_pipeline` comparison. Missing stage
evidence prevents release eligibility.

The detection adoption thresholds remain a 0.20 point improvement, a paired 95% lower
bound above zero and at least one additional cross-file detection. The native importer
currently verifies candidate provenance, not matches against independently validated
held-out truth. Detection metrics therefore remain explicitly unverified; a receipt's
`detected` field cannot establish this missing measurement.

Capture evidence from an already completed GitHub Actions run with read-only API calls:

```bash
python3 -B -m bench.scorer.ci_evidence capture \
  --repository OWNER/REPO --workflow-path .github/workflows/quality.yml \
  --source-commit EXACT_40_HEX_COMMIT --run-id RUN_ID --run-attempt ATTEMPT \
  --source-manifest-sha256 SHA256_OF_TESTED_SKILL_SNAPSHOT \
  --output /absolute/authority/evidence/new-ci-evidence.json
```

The frozen CI requirement must bind `subject` with `repository`, `workflow_path`,
`source_commit`, `run_id` and `run_attempt`, plus its usual artifact path/digest,
producer (`ci_evidence.py`), schema version and source manifest. The verifier requires
all four pinned Linux/macOS and Python jobs, each with a successful full Git-backed gate.
Capture does not start CI or publish changes.

Missing evidence and caller-written success flags cannot establish a release result.
The verifier supports native CI and canonical human-calibration artifacts. Host-invocation,
sandbox-negative, analyzer-compatibility, installer-recovery and independent-final-review
release artifact kinds remain unsupported. These gaps and unverified detection evidence
prevent release eligibility in this development build.
The legacy two-arm `bench/run.sh` path and its test-only bypasses are retained for old
fixtures; their outputs are not accepted as this evaluation's native receipts.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the pure local gate and separate Git-backed CI.
