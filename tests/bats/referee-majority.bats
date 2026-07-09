#!/usr/bin/env bats
#
# Regression guard (bugsweep-hcj): a single Referee adjudication is not enough
# independent evidence to decide whether a HIGH/CRITICAL finding becomes
# fix-eligible (and therefore gets auto-edited). prompts/referee.md must
# instruct K independent adjudications with varied framing and a STRICT
# MAJORITY requirement for severity >= high, while leaving the medium/low
# single-pass path unchanged. config/bugsweep.config.json must carry the K
# knob (adversarial.referee_votes) and its hard cap (adversarial.referee_votes_cap).
#
# The majority-gate MATH itself (2/3 eligible, 1/3 / ties not eligible) is
# unit-tested directly against mocked verdict lists in
# bench/tests/unit/test_run_summary.py::test_majority_gate_* — this file only
# guards the prompt content and config shape, the same static-content pattern
# as tests/bats/prompts-guardrails.bats.

REFEREE_MD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/prompts/referee.md"
CONFIG_JSON="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/config/bugsweep.config.json"

setup() {
  [ -f "$REFEREE_MD" ]
  [ -f "$CONFIG_JSON" ]
}

# ---------------------------------------------------------------------------
# prompts/referee.md — "K-vote majority for severity >= high" section.
# ---------------------------------------------------------------------------

@test "referee.md: has a 'K-vote majority for severity >= high' section" {
  grep -qi "K-vote majority for severity >= high" "$REFEREE_MD"
}

@test "referee.md: references the referee_votes config knob and its cap" {
  grep -q "adversarial.referee_votes" "$REFEREE_MD"
  grep -q "adversarial.referee_votes_cap" "$REFEREE_MD"
}

@test "referee.md: requires a strict majority of CONFIRMED votes to promote a finding" {
  grep -qi "strict majority" "$REFEREE_MD"
  grep -qi "more CONFIRMED votes than every other outcome combined" "$REFEREE_MD"
}

@test "referee.md: a tie is explicitly NOT eligible (conservative default)" {
  grep -qi "A tie" "$REFEREE_MD"
  grep -qi "NOT CONFIRMED\*\* — conservative by design" "$REFEREE_MD"
}

@test "referee.md: a lone or minority CONFIRMED vote must never promote a finding" {
  grep -qi "single lone CONFIRMED vote, or a minority of CONFIRMED" "$REFEREE_MD"
  grep -qi "must never promote a high/critical finding" "$REFEREE_MD"
}

@test "referee.md: instructs recording each vote to the ledger as referee_vote" {
  grep -q '"event":"referee_vote"' "$REFEREE_MD"
  grep -q '"bug_id":"<BUG-ID>"' "$REFEREE_MD"
}

@test "referee.md: votes must use varied framing, not a repeated rubber-stamp" {
  grep -qi "vary the framing" "$REFEREE_MD"
  grep -qi "not a repeated rubber-stamp" "$REFEREE_MD"
}

@test "referee.md: low/medium severity is explicitly unchanged by the K-vote rule" {
  grep -qi "Severity \*\*below\*\* high (medium/low) is entirely unaffected" "$REFEREE_MD"
  grep -qi "adjudication, no K-vote, no \`referee_vote\` ledger events" "$REFEREE_MD"
}

@test "referee.md: the K-vote rule is documented as strictly MORE conservative, never less" {
  grep -qi "conservative than the prior single-pass rule, never less" "$REFEREE_MD"
}

@test "referee.md: references run-summary.json's vote_split field and majority_gate" {
  grep -q "vote_split" "$REFEREE_MD"
  grep -q "majority_gate" "$REFEREE_MD"
}

# ---------------------------------------------------------------------------
# config/bugsweep.config.json — .adversarial.referee_votes / referee_votes_cap
# ---------------------------------------------------------------------------

@test "config: is valid JSON" {
  run python3 -m json.tool "$CONFIG_JSON"
  [ "$status" -eq 0 ]
}

@test "config: .adversarial.referee_votes is a small positive integer" {
  run python3 -c "
import json
d = json.load(open('${CONFIG_JSON}'))
k = d['adversarial']['referee_votes']
assert isinstance(k, int) and not isinstance(k, bool), k
assert 1 <= k <= 10, k
"
  [ "$status" -eq 0 ]
}

@test "config: .adversarial.referee_votes_cap is >= referee_votes (a real ceiling)" {
  run python3 -c "
import json
d = json.load(open('${CONFIG_JSON}'))
adv = d['adversarial']
assert adv['referee_votes_cap'] >= adv['referee_votes'], adv
assert adv['referee_votes_cap'] <= 20, adv  # a 'cap' that isn't small isn't a cap
"
  [ "$status" -eq 0 ]
}

@test "config: .adversarial block still has the pre-existing referee/challenge flags" {
  run python3 -c "
import json
d = json.load(open('${CONFIG_JSON}'))
adv = d['adversarial']
assert adv['challenge_enabled'] is True
assert adv['referee_enabled'] is True
assert adv['referee_spotchecks_upheld'] is True
"
  [ "$status" -eq 0 ]
}
