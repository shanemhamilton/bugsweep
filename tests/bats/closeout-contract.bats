#!/usr/bin/env bats

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SKILL_MD="${ROOT}/SKILL.md"
TRACKER_MD="${ROOT}/references/tracker-closeout.md"

@test "skill: finalize is not terminal and only closed outcomes are success" {
  grep -q "artifact checkpoint, not the terminal success signal" "$SKILL_MD"
  grep -q "COMPLETED_LANDED" "$SKILL_MD"
  grep -q "COMPLETED_RECORDED" "$SKILL_MD"
  grep -q "Never claim \"done\" while the exact branch or worktree remains" "$SKILL_MD"
  ! grep -q 'finalize\.sh.*exit 0' "$SKILL_MD"
  ! grep -q 'finalize\.sh.*exit 0' "${ROOT}/prompts/context-build.md"
}

@test "skill: mutation cap continues in detect-and-record mode" {
  grep -q "fix_cap_reached.*DETECT_ONLY_REMAINDER=1" "$SKILL_MD"
  grep -qi "fix cap stops" "$SKILL_MD"
  grep -qi "mutation, not discovery" "$SKILL_MD"
}

@test "tracker closeout: requires one documented tracker and verified readback" {
  grep -q "Resolve one system of record before preflight" "$TRACKER_MD"
  grep -q "Hosting is not evidence of tracker use" "$TRACKER_MD"
  grep -q "readback_verified: true" "$TRACKER_MD"
  grep -q "stable key" "$TRACKER_MD"
}

@test "tracker closeout: exact ownership and recovery precede uncontained deletion" {
  grep -q "never select a branch by" "$TRACKER_MD"
  grep -q "git bundle verify" "$TRACKER_MD"
  grep -q "fresh independent review" "$TRACKER_MD"
  grep -qi "remove a dirty worktree" "$TRACKER_MD"
}

@test "skill: recall, vote, and repro evidence are visible without changing fix eligibility" {
  grep -q '/bugsweep --recall' "$SKILL_MD"
  grep -q 'Near misses (review, never auto-fixed)' "$SKILL_MD"
  grep -q 'vote split for high/critical' "$SKILL_MD"
  grep -q 'repro status' "$SKILL_MD"
}

@test "low-level cleanup cannot force-discard a branch" {
  ! grep -q 'git branch -D' "${ROOT}/scripts/bugsweep-cleanup.sh"
  grep -q 'policy=discard is forbidden' "${ROOT}/scripts/bugsweep-cleanup.sh"
}
