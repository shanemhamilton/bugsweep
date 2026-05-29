# bugsweep benchmark harness

A reproducible pilot harness that measures whether bugsweep detects real,
post-training-cutoff bugs and beats a no-skill `claude -p` baseline, with a
defensible scoring pipeline. It drives bugsweep headless inside a hardened
container whose only network path is a CONNECT-allow-list egress proxy (the
container may reach the model API and nothing else), over throwaway clones of
dated known-bug repos, parses the report, and scores findings via a file-overlap
gate, a cross-model LLM judge, and human calibration.

The headline number is labeled **`bugsweep @ <commit>`** (a specific commit,
**not** a release version), because the benchmarked artifact includes the
`SKILL.md` report-format prerequisite that the scorer's parser depends on.

---

## How to run

A live run needs Docker running, the two analysis images built, the dedicated
runner key + judge key exported, and the budget-cap/revocation placeholders
below filled in. Then:

```bash
# 1. Build the analysis image (bakes git+jq+python3+claude CLI + the bugsweep
#    skill) AND the egress-proxy image. Prints the image ids for provenance.
bench/docker/build.sh

# 2. Export the dedicated, revocable keys (see "Dedicated-key … setup" below).
export ANTHROPIC_API_KEY="<dedicated-revocable-runner-key>"   # rides in the container
export OPENAI_API_KEY="<dedicated-revocable-judge-key>"       # host-only (the judge)

# 3. From the repo root. Runs every case k=3 times for BOTH arms. run.sh starts
#    the egress proxy, runs each arm in the hardened container, and tears the
#    proxy down — you do not start/stop the proxy by hand.
bench/run.sh --cases bench/corpus/cases

# Options:
#   --cases <dir-or-file>   a directory of case JSONs, or one case JSON file
#   -k <int>                runs per (case, arm); default 3
#   --results-root <dir>    parent dir for the timestamped run dir; default ./results
#   --arm <bugsweep|baseline>   restrict to one arm (default: both)
```

`run.sh` refuses to start a live run if `ANTHROPIC_API_KEY` is unset or Docker is
absent (the test-only `BENCH_NO_CONTAINER=1` bypass below skips both).

Each invocation writes a timestamped run directory under the results root:

```text
results/<UTC-ts>/
  verdicts.jsonl        one JSON record per (case, run, arm): verdict + post_cutoff
  ground_truths.json    {case_id: {description, files, hunks, ...}}
  provenance.json       the enumerated provenance fields (see below)
  <arm>/<case>/run-<n>/
    clone/              the hardened sandbox clone for that run
    raw/report.md       the runner's captured report (pre-scrub)
    report.md           the scrubbed report (secrets redacted + scanned)
  leaderboard.md        the rendered leaderboard (see "How to read leaderboard.md")
```

> **Cleanup caveat.** The captured report under `<arm>/<case>/run-<n>/raw/` is
> written by the container's non-root user (uid `65534`), so removing a results
> dir may need `sudo` (or `docker run --rm -u 0 -v "$PWD/results:/r" busybox
> chown -R "$(id -u):$(id -g)" /r`). The clone dirs are host-owned.

For each case × `k` × arm, `run.sh` runs the committed pieces in order:
`lib/validate_case.sh` (required-field gate) → `lib/sandbox.sh` (hardened
local-mirror clone onto `bench-base` at the pinned pre-fix SHA, HEAD asserted)
→ `runners/runner.sh` (the arm, inside `lib/isolate.sh`; the clone is mounted
read-only and the entrypoint copies it to a writable `/scratch/repo` so
detect-only bugsweep can write `.bugsweep/` + cut its throwaway branch; the
container reaches the model API only through `lib/proxy.sh`) → `lib/scrub.sh`
(redact + enforced secret-scan) →
the `bench/scorer` pipeline (`parse_report` → file-overlap gate → cross-model
judge → `score_case_run`) → `bench/scorer/leaderboard.py` (render).

### Test-only bypasses (MUST NOT be set for a live WU6 run)

Two clearly-marked **TEST-ONLY** environment variables let the Tier-A `bats`
suite drive a faked end-to-end run with neither a live container nor a real
model API. **Do not set either for a real (WU6) run** — the default/real path
leaves both unset and routes through the container and the cross-model judge.

| Env | Effect | Real path |
| --- | --- | --- |
| `BENCH_NO_CONTAINER=1` | Run the arm directly against the host clone instead of inside the `isolate.sh` container. | Unset — the arm runs inside the hardened container. |
| `BENCH_NO_JUDGE=1` | Treat every gate-passing finding as a judge match (no model API call). | Unset — `run.sh` calls the cross-model judge (`bench.scorer.judge.OpenAIClient`). |

---

## Dedicated-key + egress-proxy setup

> **Isolation model (deliberate, post-Design-Review-Gate decision).** The
> approved design isolated the key in a host-side MITM proxy (a key-free
> container). This build uses the engineering-equivalent **key-in-container +
> CONNECT egress allow-list** model instead: it leaves the **same accepted
> budget-abuse residual** (bounded by the budget cap + revocability below) while
> removing the unverified "does the `claude` CLI work through a TLS-terminating
> MITM proxy" risk and roughly half the build.

The model-API key used by the runner arm is a **harness-dedicated, revocable**
key. It is exported as `ANTHROPIC_API_KEY` and passed **into the container by
name** (`docker run --env ANTHROPIC_API_KEY` — the value is read from the host
env and never appears in any printed argv). Exfiltration is bounded not by
withholding the key but by the network:

- The analysis container sits on `bench-proxynet`, an **`--internal`** Docker
  network with **no route to the internet**.
- Its only neighbour is `lib/proxy.sh`'s forwarder, which **CONNECT-tunnels only
  to an exact-host allow-list** (default `api.anthropic.com:443`) and 403s every
  other host and any non-443 CONNECT.
- TLS is **end-to-end** (the proxy does not terminate it), so the key rides
  inside the encrypted stream and the proxy never sees it.

So untrusted code in the container can *spend* the key against the model API
(bounded by the budget cap), but cannot exfiltrate it to any other host.

1. **Mint a dedicated, revocable key** scoped to the model API only. Do not
   reuse a personal or production key.
2. **Export it** so `run.sh` can pass it into the container:
   ```bash
   export ANTHROPIC_API_KEY="<dedicated-revocable-runner-key>"
   ```
3. **(Optional) Extend the CONNECT allow-list** beyond the default
   `api.anthropic.com` (exact hostnames only; no substring/suffix matching):
   ```bash
   export BENCH_PROXY_ALLOW="api.anthropic.com,extra.host.example"
   ```

`run.sh` starts and stops the proxy itself for each run. It writes a per-run
usage log to `results/<run-id>/proxy-usage.json` recording **CONNECT counts**
(`connect_requests`, `denied_connects`) so anomalous egress is observable — note
the proxy is **blind to token volume** by design (end-to-end TLS); token/$ data
comes from the runner's captured usage via `lib/cost.sh`. The analysis-image and
proxy-image ids are pinned in the leaderboard provenance block.

`lib/scrub.sh` still redacts any `*_API_KEY` / `*_TOKEN` / `*_KEY` env value (and
generic key-shaped strings) from every report before it is persisted, and an
enforced secret-scan fails the run closed if anything key-shaped survives.

The **cross-model judge** (`bench.scorer.judge.OpenAIClient`) runs **host-side**
(it is not part of the container egress) and reads its key from `OPENAI_API_KEY`
on the host running `run.sh`:

```bash
export OPENAI_API_KEY="<dedicated-revocable-judge-key>"   # host only; never in the container
```

Set this for any live run that does not use the `BENCH_NO_JUDGE=1` test-only
bypass. Like the runner key, prefer a dedicated, revocable key with its own
budget cap. The judge key is deliberately **not** passed into the container.

---

## Budget cap + revocation procedure

> **REQUIRED before any live (WU6) run.** The accepted residual risk is that
> untrusted code could consume the dedicated key's budget via the proxy. That
> risk is bounded only by a **budget cap** and **instant revocability**. Fill in
> the two placeholders below with your provider's real values **before** the
> first live run. The harness cannot enforce these for you.

- **Budget cap:** `<FILL_BEFORE_LIVE_RUN: e.g. $50 hard monthly cap on the dedicated key>`
  Set this in the provider console as a hard cap on the dedicated key, not a
  soft alert. The cap is the upper bound on the accepted budget-abuse residual.
- **Revocation procedure:** `<FILL_BEFORE_LIVE_RUN: provider console path / API call to revoke the dedicated key>`
  Document the exact steps (console path or API call) to revoke the dedicated
  key instantly. The key rides in the container, but the container can only
  reach the allow-listed model API (no other egress), so the worst case is
  spend up to the cap — revoking the key immediately severs all model access for
  in-flight and future runs.

If a run shows anomalous `proxy-usage.json` volume, revoke the key first, then
investigate.

---

## Security model

| Concern | Mitigation |
| --- | --- |
| Arbitrary code execution from analyzed repos | A short-lived, non-root, read-only-root container (`lib/isolate.sh`): `--user 65534:65534`, `--read-only` + tmpfs scratch, host clone mounted **read-only** (a writable copy lives on tmpfs), `--cap-drop=ALL`, `--security-opt=no-new-privileges`, quantified cpu/memory/pids limits. |
| Network egress / data exfiltration | Container is on the **`--internal`** `bench-proxynet` (no internet). Its only path out is `lib/proxy.sh`, a forwarder that **CONNECT-tunnels only to an exact-host allow-list** (default `api.anthropic.com:443`) and 403s everything else and any non-443 CONNECT. Verified live: allowed host tunnels through, denied host is refused. |
| Key theft by untrusted code | The dedicated runner key **is in the container** (key-in-container model) but can only reach the allow-listed model API — it cannot be exfiltrated elsewhere. TLS is end-to-end, so the proxy never sees the key. The **judge** key (`OPENAI_API_KEY`) is **host-only** and never enters the container. |
| Budget abuse via the model API (accepted residual) | Bounded by the **budget cap** + **instant revocation** above; CONNECT volume observable via `results/<run-id>/proxy-usage.json`. |
| Supply-chain SHA swap | `lib/sandbox.sh` clones from a **local hash-keyed mirror**, checks out the pinned pre-fix SHA, and **fails closed** if `HEAD != <sha>`. Clone hardening disables hooks (`core.hooksPath=/dev/null`), submodules (`--no-recurse-submodules`), LFS smudge (`GIT_LFS_SKIP_SMUDGE=1`), and the `file` protocol on the destination repo. |
| Secret leakage into persisted reports | `lib/scrub.sh` redacts denylisted env values + key-shaped strings, then runs an **enforced** secret-scan that fails the run closed if any secret survives. |
| Silent capability degradation | The bugsweep arm forces `research.allow_web_research=false` via a per-run config override and **asserts** it, so a no-network container cannot silently downgrade. |
| Prompt injection via finding text | The judge wraps all attacker-controlled text (finding rationale, ground-truth description, fix diff) inside an `<UNTRUSTED_DATA>` region and instructs the model to treat it as data. |

---

## Report-template coupling

The scorer's parser (`bench/scorer/parse_report.py`) is keyed on the bugsweep
`SKILL.md` **detect-only** report contract:

- It reads only the section under the fixed header
  `## Confirmed but not fixed (detect-only or below severity floor)`.
- Each detection in that section MUST be a single structured line:
  ```text
  - <BUG-ID> · <severity> · <category> · <file>:<line> · <one-line cause>
  ```
  (`·` is U+00B7 MIDDLE DOT.) The baseline arm's prompt constrains it to emit
  the **same** line shape, so one parser reads both arms identically.

Because the headline is labeled `bugsweep @ <commit>`, the commit MUST include
the `SKILL.md` report-format prerequisite above; a future change to the report
template that breaks this contract requires re-pinning the commit.

---

## Findings field mapping

The structured report line maps to the scorer's `Finding` fields as follows:

| Report line position | `Finding` field | Notes |
| --- | --- | --- |
| `<BUG-ID>` | `bug_id` | |
| `<severity>` | `severity` | |
| `<category>` | `category` | Evidence only; the gate does not gate on it. |
| `<file>` (of `<file>:<line>`) | `file` | The **hard** file-overlap gate runs on this. |
| `<line>` (of `<file>:<line>`) | `line` | Evidence: line within ±window of a ground-truth hunk. |
| `<one-line cause>` | `rationale` | Fed to the judge as the detection's cause. |

So the report's `cause` → the scorer's `rationale`, and `file:line` →
`file` + `line`.

---

## How to read `leaderboard.md`

Top to bottom:

1. **Headline** — `# Leaderboard — bugsweep @ <commit>`. The benchmarked
   artifact is that commit, not a release version.
2. **Per-case verdicts** — a 3-column table
   (`bugsweep | baseline | ground-truth`) so baseline-only detections and ties
   are visible. A case cell shows `DETECTED` if any of its `k` runs detected;
   otherwise the worst observed verdict (`NOT_DETECTED` / `ERROR` / `SKIPPED`).
3. **Detection rate (95% Wilson CI)** — per arm: `detected@>=1`,
   `detected@majority` (k=3 → ≥2/3), flat hit-rate, completed count, the Wilson
   confidence interval, and the status.
4. **Paired delta (bugsweep − baseline)** — the `detected@>=1` delta computed
   **only over cases both arms completed**, with each arm's **ERROR** and
   **SKIPPED** counts shown beside it (so an arm that errored cannot inflate the
   delta unnoticed).
5. **Contamination split** — post-cutoff vs pre-cutoff, derived from each case's
   `disclosure_date` vs the runner model's published cutoff. The post-cutoff
   block carries the **inconclusive floor**: if fewer than 6 post-cutoff cases
   completed, the status is `inconclusive` rather than a rate.
6. **Provenance** — an enumerated block with: `runner_model_id`,
   `runner_cutoff_date`, `judge_model_id`, `judge_prompt_hash`,
   `bugsweep_commit`, `case_verified_shas` (per-case pinned pre-fix SHA),
   `container_image_digest`, `egress_proxy_image`, `line_window`, and `k`. Any
   field the run did not supply renders as `(unknown)`.

### Human calibration

After a live run, a human reviews `calibration.csv` (columns
`case_id, run, arm, judge_verdict, judge_confidence, human_verdict,
override_reason`), edits `human_verdict` in place where the judge was wrong, and
re-runs the scorer with overrides applied (a non-blank `human_verdict`
supersedes the judge's). The published number is the human-adjudicated one.

### Cost

`bench/lib/cost.sh sum <arm-dir>` aggregates the per-run `usage.json` records
(`{tokens, wall_clock_seconds, cost_usd}`) into a per-arm total, so cost per arm
and per detected bug can be reported alongside the leaderboard.
