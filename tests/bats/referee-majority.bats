#!/usr/bin/env bats
# Static contract guards for the native Referee gate.  The executable majority
# math is covered by the Python unit tests; this file protects the prompt and
# configuration boundary that decides when that gate applies.

REFEREE_MD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/prompts/referee.md"
CONFIG_JSON="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/config/bugsweep.config.json"

setup() {
  REFEREE_TEXT="$(tr '\n' ' ' < "$REFEREE_MD" | sed 's/  */ /g; s/\*\*//g')"
  [ -f "$REFEREE_MD" ]
  [ -f "$CONFIG_JSON" ]
}

referee_has() {
  printf '%s\n' "$REFEREE_TEXT" | grep -qi -- "$1"
}

@test "referee.md: defines the K-vote majority gate for high and critical findings" {
  referee_has 'K-vote majority for severity >= high'
  referee_has 'High and critical findings require the configured `K` fresh native first assessments'
}

@test "referee.md: binds K to the configured knob and hard cap" {
  referee_has 'adversarial.referee_votes'
  referee_has 'adversarial.referee_votes_cap'
  referee_has 'caps it at'
}

@test "config: referee vote and cap are bounded validator integers" {
  run python3 -c "
import json
adv = json.load(open('${CONFIG_JSON}'))['adversarial']
for key in ('referee_votes', 'referee_votes_cap'):
    value = adv[key]
    assert isinstance(value, int) and not isinstance(value, bool), (key, value)
    assert 1 <= value <= 5, (key, value)
assert adv['referee_votes'] <= adv['referee_votes_cap'], adv
"
  [ "$status" -eq 0 ]
}

@test "referee.md: medium and low use one verified native first assessment" {
  referee_has 'Medium and low findings require `K=1`'
  referee_has 'one verified native first assessment is sufficient'
}

@test "referee.md: first assessments are blind and use fresh sessions" {
  referee_has 'Blindness and fresh sessions'
  referee_has 'before revealing any prior verdict'
  referee_has 'fresh session'
  referee_has 'Do not reuse a session'
}

@test "referee.md: native capture binds immutable evidence and source identity" {
  referee_has 'Native capture and immutable evidence'
  referee_has 'one source identity'
  referee_has 'immutable captured artifacts'
  referee_has 'request digest'
  referee_has 'execution digest'
}

@test "referee.md: host, untimed, fabricated, and textual votes are ineligible" {
  referee_has 'host evaluation'
  referee_has 'untimed run'
  referee_has 'fabricated receipt'
  referee_has 'textual vote is ineligible'
  referee_has 'Do not manufacture `referee_vote` ledger lines'
}

@test "referee.md: strict majority is required and ties cannot promote" {
  referee_has 'Strict majority'
  referee_has 'strictly greater than every other outcome combined'
  referee_has 'A tie, no strict majority'
  referee_has 'lone CONFIRMED vote'
  referee_has 'minority of CONFIRMED votes'
  referee_has 'must never.*promote a high/critical finding'
}

@test "referee.md: verifier output controls eligibility" {
  referee_has 'verified_votes'
  referee_has 'confirmed_votes'
  referee_has 'only `eligible: true` makes a finding fix-eligible'
}

@test "referee.md: missing or failed native review blocks automatic fixes" {
  referee_has 'Missing, failed, unavailable, or unverified native review blocks the fix'
  referee_has 'routes it to human action'
}

@test "config: adversarial referee controls retain the existing enablement flags" {
  run python3 -c "
import json
adv = json.load(open('${CONFIG_JSON}'))['adversarial']
assert adv['challenge_enabled'] is True
assert adv['referee_enabled'] is True
assert adv['referee_spotchecks_upheld'] is True
"
  [ "$status" -eq 0 ]
}

@test "config: remains valid JSON" {
  run python3 -m json.tool "$CONFIG_JSON"
  [ "$status" -eq 0 ]
}
