#!/usr/bin/env bats
# Real Git/installer integration, entirely inside a local fixture.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  FIXTURE="$(mktemp -d)"
  FIXTURE="$(cd "$FIXTURE" && pwd -P)"
  REMOTE="$FIXTURE/source"
  mkdir -p "$REMOTE/scripts" "$REMOTE/config"
  cp "$ROOT/install.sh" "$REMOTE/install.sh"
  cp "$ROOT/scripts/installer_helper.py" "$ROOT/scripts/update-install.sh" "$REMOTE/scripts/"
  printf 'fixture skill\n' > "$REMOTE/SKILL.md"
  printf '0.7.0\n' > "$REMOTE/VERSION"
  printf '{}\n' > "$REMOTE/config/bugsweep.config.json"
  git init -q "$REMOTE"
  git -C "$REMOTE" config user.name fixture
  git -C "$REMOTE" config user.email fixture@example.invalid
  git -C "$REMOTE" add .
  git -C "$REMOTE" commit -qm fixture
  git -C "$REMOTE" tag v0.7.0
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="url.file://$REMOTE.insteadOf"
  export GIT_CONFIG_VALUE_0=https://github.com/shanemhamilton/bugsweep.git
  export CLAUDE_SKILLS_DIR="$FIXTURE/claude/skills"
  export CODEX_DIR="$FIXTURE/codex"
  mkdir -p "$CODEX_DIR"
  printf 'User instructions\n' > "$CODEX_DIR/instructions.md"
}

teardown() {
  [ -n "${FIXTURE:-}" ] && rm -rf "$FIXTURE"
}

@test "real installer repeats both hosts preserving config and unrelated registration" {
  run bash "$ROOT/install.sh" --all --version v0.7.0 --json
  [ "$status" -eq 0 ]
  printf '{"custom":true}\n' > "$CODEX_DIR/skills/bugsweep/config/bugsweep.config.json"
  run bash "$ROOT/install.sh" --all --version v0.7.0 --json
  [ "$status" -eq 0 ]
  grep -q '"custom":true' "$CODEX_DIR/skills/bugsweep/config/bugsweep.config.json"
  [ "$(grep -c '^User instructions$' "$CODEX_DIR/instructions.md")" -eq 1 ]
  [ "$(grep -c '^<!-- bugsweep-skill -->$' "$CODEX_DIR/instructions.md")" -eq 1 ]
  [ -z "$(git -C "$CLAUDE_SKILLS_DIR/bugsweep" status --porcelain)" ]
  [ -z "$(find "$FIXTURE/claude" "$CODEX_DIR" -name '.bugsweep.stage.*' -o -name '.bugsweep.backup.*' -o -name '.bugsweep.install-recovery.json')" ]
}

@test "active updater works without executable installer bits and keeps its custom root" {
  run bash "$ROOT/install.sh" --codex --version v0.7.0
  [ "$status" -eq 0 ]
  run bash "$CODEX_DIR/skills/bugsweep/scripts/update-install.sh"
  [ "$status" -eq 0 ]
  [ -f "$CODEX_DIR/skills/bugsweep/install-metadata.json" ]
  [ ! -e "$CLAUDE_SKILLS_DIR/bugsweep" ]
}

@test "real installer refuses unrelated edits without overwriting them" {
  run bash "$ROOT/install.sh" --codex --version v0.7.0
  [ "$status" -eq 0 ]
  original_head="$(git -C "$CODEX_DIR/skills/bugsweep" rev-parse HEAD)"
  printf 'User-edited skill\n' > "$CODEX_DIR/skills/bugsweep/SKILL.md"
  run bash "$ROOT/install.sh" --codex --version v0.7.0
  [ "$status" -ne 0 ]
  grep -q '^User-edited skill$' "$CODEX_DIR/skills/bugsweep/SKILL.md"
  [ "$(git -C "$CODEX_DIR/skills/bugsweep" rev-parse HEAD)" = "$original_head" ]
  [[ "$output" == *"refusing to replace a modified install"* ]]
}

@test "installer resumes after an interrupted activation without losing the old tree" {
  run bash "$ROOT/install.sh" --claude --version v0.7.0
  [ "$status" -eq 0 ]
  dest="$CLAUDE_SKILLS_DIR/bugsweep"
  stage="$CLAUDE_SKILLS_DIR/.bugsweep.stage.interrupted"
  backup="$CLAUDE_SKILLS_DIR/.bugsweep.backup.interrupted"
  journal="$CLAUDE_SKILLS_DIR/.bugsweep.install-recovery.json"
  git clone -q "$REMOTE" "$stage"
  python3 - "$dest" "$stage" "$backup" <<'PY' | python3 "$ROOT/scripts/installer_helper.py" write-transaction "$journal"
import json, sys
print(json.dumps(dict(schema_version=1, destination=sys.argv[1], stage=sys.argv[2],
                      backup=sys.argv[3], original_exists=True, instructions=None,
                      instructions_existed=False, registration_backup="")))
PY
  mv "$dest" "$backup"
  run bash "$ROOT/install.sh" --claude --version v0.7.0 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'restored-backup'* ]]
  [ -f "$dest/SKILL.md" ]
  [ -f "$stage/SKILL.md" ]
  [ ! -e "$backup" ]
  [ ! -e "$journal" ]
}
