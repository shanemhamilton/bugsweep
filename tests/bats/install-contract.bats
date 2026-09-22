#!/usr/bin/env bats

@test "installer keeps stable, edge, exact and root override contracts explicit" {
  local installer="${BATS_TEST_DIRNAME}/../../install.sh"
  run grep -F 'CHANNEL="stable"' "$installer"
  [ "$status" -eq 0 ]
  run grep -F -- '--edge' "$installer"
  [ "$status" -eq 0 ]
  run grep -F 'CLAUDE_SKILLS_DIR' "$installer"
  [ "$status" -eq 0 ]
  run grep -F 'CODEX_DIR' "$installer"
  [ "$status" -eq 0 ]
  run grep -F 'CODEX_SKILLS_DIR' "$installer"
  [ "$status" -ne 0 ]
}

@test "quality workflow pins actions and does not expose pull request secrets" {
  local workflow="${BATS_TEST_DIRNAME}/../../.github/workflows/quality.yml"
  run grep -E 'uses: actions/(checkout|setup-python|upload-artifact)@[0-9a-f]{40}$' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'pull_request_target' "$workflow"
  [ "$status" -ne 0 ]
}
