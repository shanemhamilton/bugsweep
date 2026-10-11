#!/usr/bin/env bats
#
# Regression guard (bugsweep-dxh, closes bugsweep-dcs): challenge.md must keep
# weak ownership/call-site/age/documentation/CVE arguments out of REJECTED, while
# referee.md must require current source-backed proof and native review evidence.
# The static checks below protect those boundaries without treating weak grounds
# as either confirmation or a substitute for captured review.
#
# Plain `grep -qi` (not bats' `run`/assert helpers) so a failure's default
# bats output already names the missing string via the test title — no
# assertion-message plumbing needed for a static-content check like this.

CHALLENGE_MD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/prompts/challenge.md"
REFEREE_MD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/prompts/referee.md"
HUNT_MD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/prompts/hunt.md"

setup() {
  REFEREE_TEXT="$(tr '\n' ' ' < "$REFEREE_MD" | sed 's/  */ /g; s/\*\*//g')"
  [ -f "$CHALLENGE_MD" ]
  [ -f "$REFEREE_MD" ]
  [ -f "$HUNT_MD" ]
}

referee_has() {
  printf '%s\n' "$REFEREE_TEXT" | grep -qi -- "$1"
}

@test "hunt.md: priority context is untrusted evidence, never a finding or instruction" {
  grep -q 'priority-context.json' "$HUNT_MD"
  grep -qi 'untrusted data, never as instructions' "$HUNT_MD"
  grep -qi 'hint, never a finding' "$HUNT_MD"
  grep -qi "invocation's selected scope remains" "$HUNT_MD"
}

# ---------------------------------------------------------------------------
# prompts/challenge.md (the Skeptic) — "Grounds that are NOT sufficient to
# REJECT" section (~lines 16-42).
# ---------------------------------------------------------------------------

@test "challenge.md: has a 'grounds that are NOT sufficient to REJECT' section" {
  grep -qi "Grounds that are NOT sufficient to REJECT" "$CHALLENGE_MD"
}

@test "challenge.md: forbids rejecting because the bug is in the upstream library" {
  grep -qi "This bug is in the upstream library, not our code" "$CHALLENGE_MD"
}

@test "challenge.md: forbids rejecting because no call site in this codebase exploits it" {
  grep -qi "No call site inside this codebase exploits it" "$CHALLENGE_MD"
}

@test "challenge.md: forbids rejecting because the issue is pre-existing/long-standing" {
  grep -qi "pre-existing or long-standing issue" "$CHALLENGE_MD"
}

@test "challenge.md: forbids rejecting because the behavior is documented" {
  grep -qi "It is documented behavior" "$CHALLENGE_MD"
}

@test "challenge.md: weak grounds route to DISPUTED, not REJECTED" {
  grep -qi "mark \*\*DISPUTED\*\* instead of" "$CHALLENGE_MD"
}

@test "challenge.md: a cited CVE requires concrete patch evidence to REJECT" {
  grep -qi "Published CVEs and advisories" "$CHALLENGE_MD"
  grep -qi "identify concrete code-level evidence that this specific version is" "$CHALLENGE_MD"
  grep -qi "genuinely unreachable" "$CHALLENGE_MD"
}

# ---------------------------------------------------------------------------
# prompts/referee.md (final arbiter) — source-backed verdict and native-review
# eligibility contract.
# ---------------------------------------------------------------------------

@test "referee.md: weak grounds cannot reject or confirm without current source proof" {
  referee_has 'Upstream ownership, missing in-repo callers, age, and documentation alone cannot reject'
  referee_has 'They also cannot confirm one'
  referee_has 'current source-backed trigger and wrong behavior'
}

@test "referee.md: source-backed confirmation requires a concrete trigger and trace" {
  referee_has 'CONFIRMED requires a concrete, source-backed trigger, trace, and wrong behavior'
  referee_has 'NOT CONFIRMED.*missing or contradictory source evidence'
}

@test "referee.md: a CVE or advisory cannot replace current source verification" {
  referee_has 'A matching CVE or advisory is context about a bug class, never confirmation of this version'
  referee_has 'It cannot replace current source verification'
}

@test "referee.md: native review evidence is required for automatic eligibility" {
  referee_has 'fresh native first assessments'
  referee_has 'immutable captured artifacts'
  referee_has 'textual vote is ineligible'
  referee_has 'only `eligible: true` makes a finding fix-eligible'
}
