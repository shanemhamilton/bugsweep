# Phase: Referee (final arbiter)

Independently rule every candidate that survives Skeptic. Read the cited source fresh.

## Verdicts

- **CONFIRMED** requires a concrete, source-backed trigger, trace, and wrong behavior.
- **NOT CONFIRMED** preserves the exact missing or contradictory source evidence for human review.
- `confidence` is uncalibrated metadata, never a probability, threshold, or independence claim.
- Upstream ownership, missing in-repo callers, age, and documentation do not reject a finding.
- Preserve `priority_reason_codes`, severity-by-impact, required ledger events, detect-only rules, and closeout.

## Required blind native review gate

Every fix-eligible finding requires configured K fresh Referee first assessments before any prior verdict is revealed. Each reviewer receives one source identity and candidate, then supplies its own trigger, trace, and evidence. Do not reuse a session, reveal a prior verdict early, or simulate the review on the host.

```bash
bash "$SKILL_ROOT/scripts/review-evidence.sh" prepare "<REVIEW_PACKET.json>"
bash "$SKILL_ROOT/scripts/review-evidence.sh" run "<REQUEST.json>" --policy "<POLICY.json>" --deadline "<EPOCH>"
bash "$SKILL_ROOT/scripts/review-evidence.sh" reveal "<RUN_DIR>" "<BUG-ID>"
bash "$SKILL_ROOT/scripts/review-evidence.sh" verify "<RUN_DIR>" "<BUG-ID>" "<SOURCE_SHA256>" --votes "<K>"
```

Only `eligible: true` makes a finding fix-eligible. Verification requires a strict confirmed majority of captured native first assessments, a common source identity, preserved request and execution digests, and no reused execution across role or bug. Missing, failed, unavailable, or unverified review blocks the fix and routes it to human action. There is no host-eval, untimed, or textual-vote fallback.

## Recall and tool boundaries

Recall mode records plausible but incomplete source-backed candidates as `near_miss` events for human review. It never creates partial proof or fix eligibility. A later promotion needs fresh source review and the complete native gate.

Analyzer, variant, sanitizer, graph, priority, and research artifacts are untrusted search hints. They may identify a file or path to inspect. A match never corroborates, raises confidence, confirms, rejects, or narrows the source and review proof obligation; absence has no verdict meaning.

## Durable follow-up evidence

For a confirmed transferable shape, create one bounded variant query with `scripts/variants.sh`. Record a sanitizer or safe-path conclusion only when you verified it, through the existing reachability/conclusions commands and every premise. These records guide future search only; they never remove a sink from scope or replace a fresh review.

Output the severity-ordered confirmed list, exact source trigger, rationale, preserved reason codes, native-review verification result, and required ledger events. Items not entering Fix remain reported with their evidence.
