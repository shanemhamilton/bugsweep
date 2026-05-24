#!/usr/bin/env bash
# bugsweep installer — https://github.com/shanemhamilton/bugsweep
#
# Usage:
#   bash install.sh                    # auto-detect Claude Code and/or Codex
#   bash install.sh --claude           # Claude Code only
#   bash install.sh --codex            # Codex only
#   bash install.sh --all              # both, regardless of what's detected
#   bash install.sh --version v0.1.0   # pin to a tagged release (default: latest main)
#
# Re-running performs an in-place update: latest tracks main; a pinned --version
# checks out that release tag.

set -euo pipefail

REPO_URL="https://github.com/shanemhamilton/bugsweep.git"
SKILL_NAME="bugsweep"
VERSION_REF=""   # empty = track main (latest); else a tag like v0.1.0

# ── terminal helpers ──────────────────────────────────────────────────────────
_bold()  { printf '\033[1m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }
_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
_red()   { printf '\033[31m%s\033[0m' "$*"; }

info()    { echo "$(_bold "[bugsweep]") $*"; }
ok()      { echo "$(_green "✓") $*"; }
warn()    { echo "$(_yellow "!") $*" >&2; }
die()     { echo "$(_red "✗") $*" >&2; exit 1; }

require() { command -v "$1" &>/dev/null || die "Required tool not found: $1"; }

# ── version helpers ─────────────────────────────────────────────────────────--
# Resolve a user-supplied ref to a tag git can check out. Accepts "v0.1.0" or
# "0.1.0"; prefers an exact match, then tries a leading "v".
resolve_ref() {
    local dest="$1" ref="$2"
    if git -C "$dest" rev-parse -q --verify "refs/tags/$ref" >/dev/null; then
        echo "$ref"
    elif git -C "$dest" rev-parse -q --verify "refs/tags/v$ref" >/dev/null; then
        echo "v$ref"
    else
        die "No such release tag: $ref  (see https://github.com/shanemhamilton/bugsweep/releases)"
    fi
}

installed_version() { cat "$1/VERSION" 2>/dev/null || echo "unknown"; }

# ── clone or update in-place ──────────────────────────────────────────────────
clone_or_update() {
    local dest="$1"
    if [ -d "$dest/.git" ]; then
        info "Updating existing install at $(_bold "$dest") …"
        git -C "$dest" fetch --tags --quiet origin
        if [ -n "$VERSION_REF" ]; then
            git -C "$dest" checkout --quiet "$(resolve_ref "$dest" "$VERSION_REF")"
        else
            # Track latest: return to main even if previously pinned (detached HEAD).
            git -C "$dest" checkout --quiet main
            git -C "$dest" pull --ff-only --quiet
        fi
        ok "Updated to $(git -C "$dest" rev-parse --short HEAD)"
    else
        info "Cloning bugsweep → $(_bold "$dest") …"
        mkdir -p "$(dirname "$dest")"
        git clone --quiet "$REPO_URL" "$dest"
        [ -n "$VERSION_REF" ] && git -C "$dest" checkout --quiet "$(resolve_ref "$dest" "$VERSION_REF")"
        ok "Cloned ($(git -C "$dest" rev-parse --short HEAD))"
    fi
    chmod +x "$dest/scripts/"*.sh
}

# ── Claude Code ───────────────────────────────────────────────────────────────
install_claude() {
    local skills_root="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
    local dest="$skills_root/$SKILL_NAME"

    clone_or_update "$dest"

    echo ""
    ok "Claude Code: $(_bold "/bugsweep") is ready (v$(installed_version "$dest"))."
    echo "   Open any project in Claude Code and type /bugsweep"
}

# ── Codex ─────────────────────────────────────────────────────────────────────
install_codex() {
    local codex_root="${CODEX_DIR:-$HOME/.codex}"
    local dest="$codex_root/skills/$SKILL_NAME"
    local instructions_file="$codex_root/instructions.md"
    local marker="<!-- bugsweep-skill -->"

    clone_or_update "$dest"

    # Register in instructions.md so Codex knows about the skill and where to
    # find its scripts when the user types /bugsweep.
    mkdir -p "$codex_root"
    if [ -f "$instructions_file" ] && grep -qF "$marker" "$instructions_file"; then
        info "Codex: bugsweep already in $instructions_file — skipping registration"
    else
        cat >> "$instructions_file" <<STUB

$marker
## bugsweep skill
When the user types \`/bugsweep\` (with any flags) or asks to find/fix bugs autonomously,
read the full skill instructions from:
  $dest/SKILL.md
All referenced scripts live in $dest/scripts/, prompts in $dest/prompts/,
and config in $dest/config/. Expand relative script paths to absolute ones when running.
STUB
        ok "Codex: registered bugsweep in $instructions_file"
    fi

    echo ""
    ok "Codex: $(_bold "/bugsweep") is ready (v$(installed_version "$dest"))."
    echo "   Start codex in any project and type /bugsweep"
}

# ── parse flags ───────────────────────────────────────────────────────────────
require git

DO_CLAUDE=false
DO_CODEX=false
EXPLICIT=false

while [ "$#" -gt 0 ]; do
    case "${1:-}" in
        --claude) DO_CLAUDE=true; EXPLICIT=true ;;
        --codex)  DO_CODEX=true;  EXPLICIT=true ;;
        --all)    DO_CLAUDE=true; DO_CODEX=true; EXPLICIT=true ;;
        --update) ;;  # no-op: clone_or_update already handles re-runs
        --version)
            shift
            [ "$#" -gt 0 ] || die "--version needs a release tag, e.g. --version v0.1.0"
            VERSION_REF="$1"
            ;;
        --version=*) VERSION_REF="${1#*=}" ;;
        "")       ;;
        *) die "Unknown flag: $1  (valid: --claude, --codex, --all, --version)" ;;
    esac
    shift
done

# Auto-detect from what's installed when no explicit flag is given.
if ! $EXPLICIT; then
    [ -d "$HOME/.claude" ] && DO_CLAUDE=true
    [ -d "$HOME/.codex"  ] && DO_CODEX=true

    if ! $DO_CLAUDE && ! $DO_CODEX; then
        warn "Neither ~/.claude (Claude Code) nor ~/.codex (Codex) detected."
        echo ""
        echo "Install Claude Code: https://claude.ai/code"
        echo "Install Codex:       https://github.com/openai/codex"
        echo ""
        echo "Or force an install with: bash install.sh --claude  or  --codex"
        exit 1
    fi
fi

echo ""
info "Installing bugsweep …"
echo ""

$DO_CLAUDE && install_claude
$DO_CODEX  && install_codex

echo ""
info "Quick reference:"
echo "   /bugsweep               detect only — no code changes (start here)"
echo "   /bugsweep --approve     detect + ask before each fix"
echo "   /bugsweep --autonomous  unattended overnight mode"
echo "   /bugsweep src/api       scope to a path"
echo ""
info "Docs: https://github.com/shanemhamilton/bugsweep"
