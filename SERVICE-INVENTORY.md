# Shared implementation map

| Responsibility | Existing implementation | Consumers |
| --- | --- | --- |
| Canonical source/command/config hashes; isolated execution; actual backend readback and artifact validation | `scripts/_execution.py` | Proof, reviews, analyzers, benchmark |
| Frozen project commands and phase-specific source requests | `scripts/_prepare_execution.py`, `scripts/preflight.sh` | Checks and repro |
| Native test identities and regression comparison | `scripts/_check_results.py` | `scripts/_proof.py` |
| Immutable red/green and final combined-tree proof | `scripts/_proof.py`, `scripts/repro.sh`, `scripts/run_checks.sh` | Fix and closeout |
| Native first-assessment lineage and withheld prior verdicts | `scripts/_review_evidence.py` | Review and closeout |
| Configured SARIF capture and bounded receipt/source-verified import | `scripts/_prepare_analyzers.py`, `bench/scorer/analyzer_norm.py` | Hunter hints |
| Exact operational identity, transitions and retryable closeout | `scripts/_terminal_lifecycle.py`, `scripts/closeout.sh` | Status and recovery |
| Audit and session summaries | `bench/scorer/run_summary.py`, `session_summary.py` | Reports and schedulers |
| Installer replacement, registration ownership and recovery | `scripts/installer_helper.py`, `install.sh` | Active-install updater |
| Frozen evaluation schedule and native host invocation | `bench/harness.py`, `bench/_stages.py`, `bench/runners/`, `bench/docker/bench-host-adapter` | Benchmark |
| Source evidence, precision, human calibration and evaluation | `bench/scorer/evidence.py`, `precision.py`, `calibration.py`, `evaluation.py` | Quality/release evidence |
| Native result import and canonical human review artifacts | `bench/scorer/harness_results.py`, `calibration_finalize.py` | Blinded reviews and release checks |
| Pinned GitHub Actions run evidence | `bench/scorer/ci_evidence.py` | Quality/release evidence |
| Real-project seeded corpus preparation with separate private gold | `bench/corpus_tools.py` | Held-out/pilot preparation |

Run authority is outside target mounts. Validators read and hash actual artifact bytes;
a field named `verified` is not authority. Source identity uses the canonical direct
path-to-content-hash map; permissions and other inventory evidence are separate hashes.
Retain unknowns, failed attempts and rejected candidates in their denominators.
