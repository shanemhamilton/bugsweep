# bugsweep effectiveness benchmark harness (`bench/`) — design (rev 3)

- **Status:** design — rev 3, addressing Design Review Gate rounds 1–2
- **Date:** 2026-05-28
- **Epic:** bugsweep-293
- **Author:** Shane Hamilton

## Context

bugsweep claims to find real runtime bugs across a whole repo; there is no evidence yet, and
its differentiating bug classes have no external benchmark. This harness is a **directional
pilot**: an honest, reproducible, confidence-bounded read on whether bugsweep detects real bugs
it could not have memorized, and whether it beats a no-skill baseline — enough to decide
whether to keep investing. It is **not** "proof"; with N≈10 the rate carries a wide CI, so the
primary deliverable is a **per-case detected/missed table** + a **bugsweep-vs-baseline delta**,
rate-with-CI secondary.

## Goals / Non-goals

- **Goals:** honest pilot read (per-case table + rate with CIs + baseline delta),
  contamination-controlled; defensible scoring; all untrusted-code execution isolated; no key
  exfiltration.
- **Non-goals:** recall on live code; Tracks 2–4 (precision, ablations, fix-safety) — deferred;
  a public "proof" launch.

## Pre-committed decision rule (LOCKED — frozen before any run)

> bugsweep's `detected@majority` exceeds the baseline by **≥ 20 percentage points on the
> post-cutoff cases** AND bugsweep detects **≥ 1 cross-file bug the baseline misses**. Met →
> keep investing. Not met → redesign the hunter before further distribution work.

To give the rule a real denominator, the corpus **guarantees floors**: **≥ 8 post-cutoff cases**
and **≥ 3 cross-file cases** (see Corpus). These numbers are fixed in this doc; they are not
tunable after results are seen.

> Note on rigor: at this N the 20pt rule is a **pragmatic go/no-go heuristic, not a significance
> test**. The leaderboard reports Wilson CIs alongside it so the reader sees the uncertainty;
> the rule is the author's pre-committed action trigger, nothing more.

## Scope

Track 1 (retrospective known-bug detection) **+ a naive as-shipped baseline arm**. No Track 2–4.

## Locked decisions

| Axis | Decision |
|---|---|
| Runner | `claude -p` headless behind a runner-adapter seam. The harness runs the **real bugsweep skill** (Step 0 `preflight.sh` included); detect-only is enforced by a **detect-only invocation (no `--fix`) + a post-run assertion** that the working tree is clean and no fix commits exist. The container makes any stray write moot (discarded). |
| Baseline | Second arm: `claude -p`, **no bugsweep skill**, a fixed prompt that must emit findings in the **same structured line format** the scorer parses. This measures **as-shipped value** ("does installing bugsweep beat not having it"). It deliberately conflates bugsweep's bug-knowledge with its orchestration; **decomposing that is a deferred Track-3 ablation**, out of scope here. |
| Judge | Cross-model (OpenAI via codex), temp 0; attacker-controlled text delimited as data; model id + prompt hash recorded. |
| Scoring | File-overlap gate (hard) → cross-model judge cause-match → human calibration. |
| Corpus | Mixed, security-weighted (~6 security + ~4 logic/data-integrity), JS/TS+Python+Go, **with floors: ≥8 post-cutoff, ≥3 cross-file**. |
| Contamination | `post_training_cutoff` derived at score time from the runner model's published cutoff (recorded in provenance), not a case boolean. |
| Isolation | **Pragmatic, key-free container.** A short-lived, minimally-scoped, **harness-dedicated, revocable** API key lives ONLY in a host-side **egress proxy**. The container runs clone + `run_checks.sh` + `claude -p` with **no key in its environment** and **no network except to the proxy**, which forwards only to the model API endpoints and injects auth. Residual risk (accepted + documented): untrusted code could consume the dedicated key's budget via the proxy — bounded by a budget cap and instant revocability; it **cannot exfiltrate the key (never in the container) or reach arbitrary hosts**. |
| Benchmarked artifact | The headline number is labeled **"bugsweep @ `<commit>`"**, where `<commit>` includes the SKILL.md report-format prerequisite below — NOT v0.1.0. |

## bugsweep prerequisite (must land first, part of the benchmarked commit)

Detect-only findings land only in the report's "Confirmed but not fixed" section, whose
template (SKILL.md:196) is `<one line per item>` — unparseable. A small SKILL.md change makes
that section emit a structured line (`BUG-ID · severity · category · file:line · cause`),
matching the existing Fixed/Quarantined line style. The benchmark measures bugsweep *with* this
change; the provenance block records the exact commit, and the leaderboard labels it so no one
mistakes the number for the released v0.1.0. A pytest fixture + one live check assert the real
SKILL.md emits the format the parser expects.

## Architecture & directory layout

```
bench/
  README.md                 # run steps, security model, egress-proxy + dedicated-key setup, report-template coupling, how to read results
  run.sh                    # orchestrator: case × k × {bugsweep,baseline} → sandbox → isolate → scrub → score → report
  pyproject.toml            # Python project; [tool.coverage.run] source = ["bench/scorer"] (scopes the gate)
  corpus/{schema.json, cases/}
  runners/{runner.sh, claude_p.sh, claude_p_baseline.sh}   # adapters; RESULT=/exit-code contract (table below)
  scorer/{__init__.py, parse_report.py, localize.py, judge.py, score.py}   # coverage target (incl. judge.py via faked client)
  lib/{proxy.sh, isolate.sh, sandbox.sh, scrub.sh, cost.sh}
  tests/{unit (pytest), bats}
  results/<UTC-ts>/ + leaderboard.md   # written through scrub.sh; secret-scanned before commit
```

**Data flow:** `run.sh` → validate case vs `schema.json` (jq) → `lib/proxy.sh` starts the
host-side key-injecting egress proxy → `lib/sandbox.sh` clones (hardened, see below) + `git
checkout -b bench-base <sha>` → `lib/isolate.sh` runs the arm in a **no-key, no-network-except-
proxy** container (the real skill, incl. `preflight.sh`) → `scrub.sh` redacts → `parse_report.py`
→ `localize.py` + `judge.py` → `score.py` → reporter.

## Sandbox & clone hardening

`git -c protocol.file.allow=never -c core.hooksPath=/dev/null clone --no-recurse-submodules`
with `GIT_LFS_SKIP_SMUDGE=1`, preferably from a **locally cached, hash-verified mirror**; then
`git checkout -b bench-base <sha>`; then **assert `git rev-parse HEAD` == `<sha>`** (fail closed).
Because the harness runs the real skill, `preflight.sh` will cut its own `bugsweep/<ts>` branch
off `bench-base` (same commit), so the assertion is on `rev-parse HEAD`, not a branch name, and
`finalize.sh` returns to `bench-base`. The clone runs **inside the no-key sandbox**; only the
mirror-fetch phase touches the network (separately, before analysis). Container: non-root,
dropped caps, read-only root + tmpfs scratch, clone mounted read-only for analysis, and
quantified limits (`--cpus`, `--memory`, `--pids-limit`, wall-clock timeout). `allow_web_research`
is **forced false** and asserted (a no-network container would otherwise silently degrade).

## Case schema (clarified)

`hunks` are authoritative; `files` is derived from `hunks` and validated to match. `size_ceiling`
(`max_files`, `max_loc`) is enforced to bound context-build cost. `expected_severity` and
`scope_hint` are dropped (never consumed). `disclosure_date` drives the post/pre-cutoff split at
score time. Each case is tagged `cross_file: true|false` so the ≥3 floor and the decision rule's
cross-file clause are checkable.

## Runner contract (explicit)

| Per-case outcome | RESULT token | exit |
|---|---|---|
| ran, findings parsed | `RESULT=RAN` | 0 |
| ran, zero findings | `RESULT=RAN` (empty findings.json) | 0 |
| infra failure (clone/parse/judge/container) | `RESULT=ERROR` | 1 |
| skipped (size ceiling, unsupported) | `RESULT=SKIP` | 10 |

The adapter writes findings to `findings.json` and prints only the `RESULT=` status line on
stdout (matching `scripts/` convention). Detection (DETECTED/NOT_DETECTED) is a **scorer**
verdict derived from findings + ground truth — not a runner token. **Both arms emit the same
`findings.json` schema** (`{bug_id, severity, category, file, line, rationale}`); the baseline
prompt is constrained to the same structured line format so a single `parse_report.py` reads
both (no second parser, no asymmetry).

## Scorer

- `localize.py` — file-overlap gate (hard); line ±10 + category as evidence. Pure, unit-tested.
- `judge.py` — cross-model (OpenAI) cause-match; injectable client (faked in CI) → **in the 80%
  gate**; delimits attacker text as data; records model id + prompt hash.
- `score.py` — per-case verdict ∈ **DETECTED / NOT_DETECTED / ERROR / SKIPPED**. ERROR/SKIPPED
  are reported separately and **excluded from the rate denominator**. Aggregates per arm: k/N,
  detected@≥1, **detected@majority** (k=3 → ≥2/3); **Wilson CIs**. The bugsweep−baseline delta is
  **paired on cases both arms COMPLETED**, with per-arm ERROR/SKIPPED counts shown beside it.
  **Inconclusive floor:** if completed post-cutoff cases < 6, the pilot is declared
  **inconclusive** rather than reporting a rate. `calibration.csv` columns:
  `case_id, run, arm, judge_verdict, judge_confidence, human_verdict, override_reason`; the human
  edits `human_verdict` in place and re-runs `score.py --apply-overrides`; the published number
  is the human-adjudicated one, with judge/human agreement reported.

## Metrics & `leaderboard.md`

**Primary:** a **three-column per-case table** (bugsweep verdict | baseline verdict |
ground-truth) so baseline-only detections and ties are visible. Plus: rate with Wilson CIs;
bugsweep−baseline delta (paired); post/pre-cutoff split; cost per arm and per detected bug;
**provenance** (runner model id+cutoff, judge model id+prompt hash, bugsweep commit, each case's
verified SHA, container image digest, line-window, k). Written through `scrub.sh`;
secret-scanned (key patterns + an env-var-name denylist) as an enforced gate before commit.

## Security model

| Threat | Mitigation |
|---|---|
| Arbitrary code execution from untrusted/vulnerable repos | Rootless container: non-root, dropped caps, read-only root + tmpfs, clone mounted read-only, quantified cpu/mem/pids/wall-clock limits |
| Key theft by untrusted code | **As built (deliberate post-Design-Review deviation):** key-in-container, but egress is restricted to a single hardcoded model-API upstream, so the key cannot be exfiltrated elsewhere; the judge key stays host-only. The claude→proxy leg is plaintext on the private internal network so the proxy sees the dedicated key (no new exposure — key already in the container; nginx omits the `Authorization` header from its log). *(Evolution: original key-free MITM design → key-in-container CONNECT allow-list → key-in-container nginx **reverse proxy**, because live testing showed the Bun-based `claude` CLI ignores `HTTP(S)_PROXY` and only honors `ANTHROPIC_BASE_URL`. Same accepted residual throughout. See bench/README.md.)* |
| Exfiltration to attacker host | Container is on an **`--internal`** network (no internet); its only path out is an nginx reverse proxy (claude reaches it via `ANTHROPIC_BASE_URL`) that forwards **only** to `https://api.anthropic.com`; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` keeps claude off other hosts |
| Key-budget abuse via the model API (accepted residual) | **Dedicated, minimally-scoped, revocable** key + budget cap; not the user's main credentials. Unchanged residual under either isolation model. |
| Clone-time code execution (submodules/hooks/LFS) | Disabled before clone; `protocol.file.allow=never`; clone in the no-key sandbox; HEAD asserted after |
| Secret leak into committed `results/` | `scrub.sh` redaction + enforced secret-scan gate (patterns + env-name denylist) |
| Supply-chain SHA swap on re-run | Hash-verified local mirror; assert `rev-parse HEAD == sha`, fail closed |
| Prompt injection (judge / bugsweep) | Delimit attacker text as data; human calibration + judge/human agreement as backstop; prompt hash recorded |
| `--fix` blast radius | Track 4 deferred; this build is detect-only |

## Dependencies

`python3` + pytest/ruff/black/mypy, `git`, `claude` CLI (runner), **codex/OpenAI key (judge)**,
**Docker** (supported default; `isolate.sh` detects runtime and **fails closed** with a clear
message if absent — Podman optional), `jq`, `bats`, a tiny egress proxy (e.g. `tinyproxy`/a
small Go/Python forwarder). Node.js not required.

## Verification & TDD plan — two tiers

- **Tier A — blocking 80% gate (container-free, no network):** pytest on `bench/scorer/`
  (coverage source pinned to `bench/scorer` in `pyproject.toml`, matching the
  `.coverage-thresholds.json` command) + bats on the bash glue. Boundaries faked: runner →
  injected fake adapter + recorded `report.md` fixtures; judge → in-process fake client; git →
  local bare repos in tmpdirs. **bats asserts `isolate.sh` *emits* `--network`/`--read-only`/
  limit flags and the proxy wiring** (argument construction + control flow), NOT a live
  container. Plus a `shellcheck` pass on `lib/`, `runners/`.
- **Tier B — integration (live container + real clone), manual/nightly, NOT in the gate:**
  end-to-end on one seeded fixture (known bug on a named branch) exercising the full pipeline
  **including the contamination split and majority aggregation**, plus an assertion that
  `claude -p` actually completes through the proxy inside the no-network container.
- Per-function edge cases enumerated: `localize.py` (path normalization, empty/multi-file,
  exact ±window boundary, no overlap); `score.py` (all-fail/all-pass, exact-tie majority,
  cutoff-boundary date, ERROR/SKIPPED excluded, paired-delta with asymmetric errors, inconclusive
  floor); `parse_report.py` (missing header, malformed line, empty, template drift, baseline
  format); `judge.py` (prompt construction, response parse, delimiting, model-id/temp pin).

## Implementation order

0. Python bootstrap (`pyproject.toml` + coverage scoping) + `lib/proxy.sh` + `lib/isolate.sh` +
   bats setup.
1. bugsweep SKILL.md detect-only report-format prerequisite (+ its fixture/live test);
   `corpus/schema.json` + jq validation; `lib/sandbox.sh` (hardened clone, HEAD assert) +
   `lib/scrub.sh`.
2. Source + write the cases (security-weighted; ≥8 post-cutoff, ≥3 cross-file).
3. `runners/`: `claude_p.sh` + `claude_p_baseline.sh` (shared findings contract) + `runner.sh`.
4. `scorer/`: `parse_report.py` → `localize.py` → `judge.py` (OpenAI) → `score.py`.
5. `run.sh` + leaderboard renderer (3-col table, CIs, paired delta) + `cost.sh`.
6. Run k=3 over both arms → human-calibrate → publish the pilot `leaderboard.md` + evaluate the
   locked decision rule.

## Definition of Done

- Track 1 + baseline implemented (schema; ≥8 post-cutoff + ≥3 cross-file cases; both arms with
  shared findings contract; parser; localize/judge/score with ERROR/SKIPPED + inconclusive floor;
  3-column leaderboard with CIs + paired delta).
- SKILL.md detect-only report-format change landed; benchmarked commit recorded + labeled.
- Untrusted execution runs key-free in the no-network-except-proxy container; dedicated revocable
  key; `results/` scrubbed + secret-scan gate passes.
- Judge on a non-Claude model; provenance complete (both model ids + prompt hash + verified SHAs
  + image digest).
- Tier-A gate is container-free and green at ≥80% on `bench/scorer/` (incl. `judge.py`); bats +
  shellcheck pass; Tier-B integration documented as out-of-gate.
- First pilot `leaderboard.md` from a k=3 run (both arms) with the post/pre-cutoff split; the
  locked decision rule evaluated; inconclusive-floor honored.
- `bench/README.md` documents running it, the dedicated-key + proxy setup, the security model,
  the report-template coupling, and how to read results.

## Review refinements (folded from gate round-3 suggestions; non-blocking)

- **Egress proxy hardening (security/architect):** the proxy enforces an **exact-hostname** upstream
  allow-list (no substring/suffix match), **refuses CONNECT/tunneling** to any other host, and
  **strips client-supplied auth headers**, injecting only the dedicated key. Budget cap value +
  revocation procedure must be operational and in `bench/README.md` **before the first live run**;
  the proxy logs per-run request count/token volume so the accepted residual (budget abuse) is
  observable. The proxy image/version is pinned in the provenance block alongside the analysis
  image digest.
- **Decision-rule clarity (PM):** the "≥1 cross-file bug the baseline misses" clause counts a
  miss **within the post-cutoff cases**; the cross-file floor is raised to **≥4** to stay robust
  against a single lucky baseline catch; the inconclusive floor (<6 completed post-cutoff) sits
  below the ≥8 corpus floor deliberately, as a 2-case attrition buffer (noted inline so it isn't
  "fixed").
- **Findings field mapping (designer):** the report line `BUG-ID · severity · category ·
  file:line · cause` maps to `findings.json` `{bug_id, severity, category, file, line, rationale}`
  (`cause`→`rationale`, `file:line`→`file`+`line`); the mapping is documented once in
  `bench/README.md`. `score.py --apply-overrides` treats a blank `human_verdict` as fall-through
  to `judge_verdict`; the `run` column domain is `1..k`; the adapter emits exactly one terminal
  `RESULT=` line (exit code authoritative).
- **Coverage resolution (CTO):** the Tier-A gate runs with **CWD=`bench/`** so bare
  `pytest --cov` resolves `[tool.coverage.run] source=["bench/scorer"]`; a judge edge case
  exercises the **attacker-text delimiting** path under the fake client; bats assertions check
  isolation **flag *values*** (e.g. `--memory <n>`), not just presence, plus a **negative test**
  that no key-shaped env var is passed into the container.
