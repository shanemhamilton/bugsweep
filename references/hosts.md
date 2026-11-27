# Host adaptation

Bugsweep uses the same `SKILL.md`, phase prompts, coordinator scripts, and evidence
rules on Codex, Claude Code, and Google Antigravity (AGY). Metaswarm is not needed.
Host-specific installation and invocation do not change what qualifies as a bug,
a verified fix, or a completed run.

## Install and invoke

| Host | Installer selector | Discovery and invocation |
| --- | --- | --- |
| Claude Code | `--claude` | Personal skills in `~/.claude/skills`; invoke `/bugsweep` or ask to use Bugsweep. |
| Codex | `--codex` | Personal skills in `~/.agents/skills`; select Bugsweep, mention `$bugsweep`, or ask to use it. Existing managed legacy installations remain supported. |
| AGY CLI | `--agy` | Personal skills in `~/.gemini/antigravity-cli/skills`; invoke `/bugsweep` or ask to use Bugsweep. |
| Antigravity IDE / 2.0 | `--agy` with `AGY_SKILLS_DIR` | Set the root to `~/.gemini/config/skills` for the current IDE/2.0 global location. |

`--all` selects all three hosts. When only the Antigravity IDE skills root exists,
the installer selects it automatically; when both roots exist, choose explicitly to
install for the intended surface. Use the installer result's exact destination, not
an assumed default. `CLAUDE_SKILLS_DIR`, `CODEX_SKILLS_DIR`, and `AGY_SKILLS_DIR` can
select alternate skill roots; `CODEX_DIR` retains legacy root/registration support.
Always derive `SKILL_ROOT` from the `SKILL.md` actually loaded for this invocation.
Never substitute another host's installed copy. The active updater preserves that
installation's canonical root and host identity.

These installer capabilities are in development for the next release; v0.8.0 does
not contain them. New host layouts reject older payloads without the updater contract.
Use a reviewed development installer with `--edge` once the change is on main, or a
release that includes this support.

Examples (after inspecting a compatible release installer):

```bash
bash install.sh --claude
bash install.sh --codex
bash install.sh --agy
AGY_SKILLS_DIR="$HOME/.gemini/config/skills" bash install.sh --agy
```

For a host without skill discovery, explicitly load the trusted installed `SKILL.md`
and follow it. Do not install a workflow plugin to compensate for missing discovery.
Older clients may use different paths; choose an explicit skills root documented by
that client rather than copying to several guessed locations.

## Capability mapping

Use the current host's available tools for reading files, searching, editing, asking
for approval, and running trusted coordinator helpers. Tool names are not portable.
A Claude `Agent` call, a Codex subagent, and an AGY task are orchestration mechanisms,
not interchangeable evidence of independent native review.

All three hosts can coordinate the same modes: detect, approve, fix, and autonomous.
Every mode retains the same scope, checkpoint, worktree, approval, and closeout rules.
If subagents are unavailable, investigate sequentially with the same source packets.
Do not count a role played by the current session as a fresh external review. If a
required tracker, execution policy, or review provider is unavailable, record that
limitation and follow the shared blocked/partial path; never invent a successful
receipt or reduce the number of required reviews.

The host driving the skill is separate from the providers configured in
`adversarial.hosts`. The bundled isolated native-review and benchmark adapters support
Claude and Codex. An AGY coordinator can use those approved providers with the same
external policy as either other coordinator. AGY is not yet a bundled isolated review
or benchmark provider: its CLI alone does not establish proxy routing, immutable
session evidence, or enforced budget accounting. Do not add `agy` to provider settings
or replace the approved proxy with ambient login credentials. Live three-host audit
parity must be measured separately from installer and contract tests.

## Headless and scheduled use

Use a natural-language request that names Bugsweep, its trusted installed path, target,
mode, and budgets. Do not rely on slash-command expansion in print mode. Use the host's
supported noninteractive entrypoint (`claude --print`, `codex exec`, or `agy --print`)
and its own approved permission configuration. Check that version's CLI help first.
Never copy permission-bypass flags between hosts or assume a native sandbox replaces
Bugsweep's external target-execution policy. Missing headless permissions must stop the
run with a recorded limitation rather than hang indefinitely or execute unrestricted.

Use the scheduler already available to the operator, with one active invocation per
target unless explicitly partitioned. Metaswarm and any particular scheduling service
are optional. Persist source identity and the run directory across continuations;
resuming a session must not create a replacement audit.

## Upstream contracts

Verified against the official skill documentation on 2026-10-11:

- [Codex skill discovery](https://developers.openai.com/codex/skills/)
- [Claude Code skill discovery](https://code.claude.com/docs/en/skills)
- [Antigravity skill locations and invocation](https://antigravity.google/docs/skills)

These establish discovery conventions, not evidence that every host/version has passed
an end-to-end Bugsweep audit. Keep that distinction in compatibility and release claims.
