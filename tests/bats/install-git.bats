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
  printf 'development-only\n' > "$REMOTE/AGENTS.md"
  printf 'development-only\n' > "$REMOTE/CLAUDE.md"
  printf 'development-only\n' > "$REMOTE/GEMINI.md"
  mkdir -p "$REMOTE/.claude" "$REMOTE/.metaswarm"
  printf 'development-only\n' > "$REMOTE/.claude/settings.json"
  printf 'development-only\n' > "$REMOTE/.metaswarm/config.json"
  git init -q "$REMOTE"
  git -C "$REMOTE" config user.name fixture
  git -C "$REMOTE" config user.email fixture@example.invalid
  git -C "$REMOTE" add .
  git -C "$REMOTE" commit -qm fixture
  git -C "$REMOTE" -c tag.gpgSign=false tag v0.7.0
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="url.file://$REMOTE.insteadOf"
  export GIT_CONFIG_VALUE_0=https://github.com/shanemhamilton/bugsweep.git
  export CLAUDE_SKILLS_DIR="$FIXTURE/claude/skills"
  export CODEX_DIR="$FIXTURE/codex"
  export AGY_SKILLS_DIR="$FIXTURE/agy/skills"
  mkdir -p "$CODEX_DIR"
  printf 'User instructions\n' > "$CODEX_DIR/instructions.md"
}

teardown() {
  [ -n "${FIXTURE:-}" ] && rm -rf "$FIXTURE"
}

@test "real installer repeats all three hosts preserving config and unrelated registration" {
  run bash "$ROOT/install.sh" --all --version v0.7.0 --json
  [ "$status" -eq 0 ]
  printf '{"custom":true}\n' > "$CODEX_DIR/skills/bugsweep/config/bugsweep.config.json"
  run bash "$ROOT/install.sh" --all --version v0.7.0 --json
  [ "$status" -eq 0 ]
  grep -q '"custom":true' "$CODEX_DIR/skills/bugsweep/config/bugsweep.config.json"
  [ "$(grep -c '^User instructions$' "$CODEX_DIR/instructions.md")" -eq 1 ]
  [ "$(grep -c '^<!-- bugsweep-skill -->$' "$CODEX_DIR/instructions.md")" -eq 1 ]
  [ -z "$(git -C "$CLAUDE_SKILLS_DIR/bugsweep" status --porcelain)" ]
  [ -f "$AGY_SKILLS_DIR/bugsweep/install-metadata.json" ]
  grep -q '"host": "agy"' "$AGY_SKILLS_DIR/bugsweep/install-metadata.json"
  for destination in "$CLAUDE_SKILLS_DIR/bugsweep" "$CODEX_DIR/skills/bugsweep" "$AGY_SKILLS_DIR/bugsweep"; do
    for development_path in AGENTS.md CLAUDE.md GEMINI.md .claude .metaswarm; do
      [ ! -e "$destination/$development_path" ]
    done
    [ -z "$(git -C "$destination" status --porcelain)" ]
    [ -n "$(git -C "$destination" rev-parse HEAD)" ]
  done
  [ -z "$(find "$FIXTURE/claude" "$CODEX_DIR" "$FIXTURE/agy" -name '.bugsweep.stage.*' -o -name '.bugsweep.backup.*' -o -name '.bugsweep.install-recovery.json')" ]
}

@test "active updater works without executable installer bits and keeps its custom root" {
  run bash "$ROOT/install.sh" --codex --version v0.7.0
  [ "$status" -eq 0 ]
  python3 - "$CODEX_DIR/skills/bugsweep/install-metadata.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.loads(open(path, encoding="utf-8").read())
data.pop("skills_root", None)
data.pop("legacy_root", None)
open(path, "w", encoding="utf-8").write(json.dumps(data) + "\n")
PY
  run bash "$CODEX_DIR/skills/bugsweep/scripts/update-install.sh"
  [ "$status" -eq 0 ]
  [ -f "$CODEX_DIR/skills/bugsweep/install-metadata.json" ]
  [ ! -e "$CLAUDE_SKILLS_DIR/bugsweep" ]
}

@test "modern Codex and Antigravity updater use their exact configurable roots" {
  unset CODEX_DIR
  export CODEX_SKILLS_DIR="$FIXTURE/modern-codex/skills"
  run bash "$ROOT/install.sh" --codex --version v0.7.0
  [ "$status" -eq 0 ]
  [ -f "$CODEX_SKILLS_DIR/bugsweep/install-metadata.json" ]
  [ ! -e "$FIXTURE/modern-codex/instructions.md" ]
  grep -q '"host": "codex"' "$CODEX_SKILLS_DIR/bugsweep/install-metadata.json"
  export CODEX_DIR="$FIXTURE/conflicting-legacy-codex"
  run bash "$CODEX_SKILLS_DIR/bugsweep/scripts/update-install.sh"
  [ "$status" -eq 0 ]
  [ -f "$CODEX_SKILLS_DIR/bugsweep/install-metadata.json" ]

  run bash "$ROOT/install.sh" --agy --version v0.7.0
  [ "$status" -eq 0 ]
  run bash "$AGY_SKILLS_DIR/bugsweep/scripts/update-install.sh"
  [ "$status" -eq 0 ]
  [ -f "$AGY_SKILLS_DIR/bugsweep/install-metadata.json" ]
}

@test "Codex defaults to modern agents skills unless a managed legacy install exists" {
  unset CODEX_DIR CODEX_SKILLS_DIR
  export HOME="$FIXTURE/home"
  mkdir -p "$HOME"
  run bash "$ROOT/install.sh" --codex --version v0.7.0
  [ "$status" -eq 0 ]
  [ -f "$HOME/.agents/skills/bugsweep/install-metadata.json" ]
  [ ! -e "$HOME/.codex/skills/bugsweep" ]
}

@test "unmanaged legacy Codex instructions do not redirect modern installation" {
  unset CODEX_DIR CODEX_SKILLS_DIR
  export HOME="$FIXTURE/unmanaged-home"
  mkdir -p "$HOME/.codex"
  printf 'unrelated instructions\n' > "$HOME/.codex/instructions.md"
  run bash "$ROOT/install.sh" --codex --version v0.7.0
  [ "$status" -eq 0 ]
  [ -f "$HOME/.agents/skills/bugsweep/install-metadata.json" ]
  [ ! -e "$HOME/.codex/skills/bugsweep" ]
}

@test "Antigravity auto-detects the IDE2 skills root when the CLI root is absent" {
  unset AGY_SKILLS_DIR
  export HOME="$FIXTURE/agy-home"
  mkdir -p "$HOME/.gemini/config/skills"
  run bash "$ROOT/install.sh" --agy --version v0.7.0
  [ "$status" -eq 0 ]
  [ -f "$HOME/.gemini/config/skills/bugsweep/install-metadata.json" ]
  [ ! -e "$HOME/.gemini/antigravity-cli/skills/bugsweep" ]
}

@test "modern host installation rejects a source payload without its capability marker" {
  python3 - "$REMOTE/install.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
marker = 'INSTALLER_CAPABILITIES="portable-hosts-v1"'
assert marker in text
open(path, "w", encoding="utf-8").write(text.replace(marker, "INSTALLER_CAPABILITIES=legacy", 1))
PY
  git -C "$REMOTE" add install.sh
  git -C "$REMOTE" commit -qm 'fixture old installer payload'
  git -C "$REMOTE" tag -f v0.7.0 >/dev/null
  run bash "$ROOT/install.sh" --agy --version v0.7.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"selected release does not support portable host installation"* ]]
  [ ! -e "$AGY_SKILLS_DIR/bugsweep" ]
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
