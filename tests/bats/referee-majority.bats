#!/usr/bin/env bats

# Native-vote capture, blinding, and strict-majority validation are covered by
# bench/tests/unit/test_review_evidence.py. Keep this focused on the operator
# instructions and config consumed by that gate.

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
REFEREE_MD="$ROOT/prompts/referee.md"
CONFIG_JSON="$ROOT/config/bugsweep.config.json"

@test "referee instructions require fresh blind native assessments" {
  grep -q 'configured K fresh Referee first assessments' "$REFEREE_MD"
  grep -q 'before any prior verdict is revealed' "$REFEREE_MD"
  grep -q 'fresh Referee first assessments' "$REFEREE_MD"
}

@test "referee instructions require verified strict-majority eligibility" {
  grep -q 'strict confirmed majority' "$REFEREE_MD"
  grep -q 'Only `eligible: true` makes a finding fix-eligible' "$REFEREE_MD"
  grep -q 'no host-eval, untimed, or textual-vote fallback' "$REFEREE_MD"
}

@test "referee vote configuration remains bounded and explicit" {
  run python3 - "$CONFIG_JSON" <<'PY'
import json, sys
adversarial = json.load(open(sys.argv[1]))['adversarial']
assert 1 <= adversarial['referee_votes'] <= adversarial['referee_votes_cap'] <= 5
PY
  [ "$status" -eq 0 ]
}
