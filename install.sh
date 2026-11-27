#!/usr/bin/env bash
# Commit-bound Bugsweep installer. Staging precedes every activation.
set -euo pipefail
REPO_URL="https://github.com/shanemhamilton/bugsweep.git"
SKILL_NAME=bugsweep
INSTALLER_CAPABILITIES="portable-hosts-v1"
CHANNEL="stable"; VERSION_REF=""; DO_CLAUDE=false; DO_CODEX=false; DO_AGY=false; EXPLICIT=false; JSON=false
RESULTS_FILE=""; RECOVERY_FILE=""; FAILED_HOST=""; FAILED_ROOT=""; RECOVERY_HINT=""; SCRIPT_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fail() { if $JSON; then python3 "$SCRIPT_ROOT/scripts/installer_helper.py" failure-json "$RESULTS_FILE" "$RECOVERY_FILE" "$FAILED_HOST" "$FAILED_ROOT" "$CHANNEL" "${SELECTED_TAG:-}" "${EXPECTED_COMMIT:-}" "$RECOVERY_HINT" "$1"; else printf 'bugsweep installer: %s\n' "$1" >&2; fi; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"; }
require_runtime_dependencies() {
  python3 - <<'PY' || fail "required runtime unavailable: Python 3.12+ and jsonschema==4.26.0; install the skill runtime dependencies, then retry"
from importlib.metadata import PackageNotFoundError, version
try:
    assert __import__("sys").version_info >= (3, 12)
    assert version("jsonschema") == "4.26.0"
except (AssertionError, PackageNotFoundError):
    raise SystemExit(1)
PY
}
valid_root() { case "$1" in *$'\n'*|*$'\t'*) fail "configured root contains an unsupported control character";; esac; }

latest_stable_tag() {
  git ls-remote --refs --tags "$REPO_URL" | awk '{sub("refs/tags/","",$2);print $2}' |
    python3 -c 'import re,sys;t=[x.strip() for x in sys.stdin if re.fullmatch(r"v?[0-9]+(?:\.[0-9]+){2}",x.strip())];assert t;print(max(t,key=lambda x:tuple(map(int,x.lstrip("v").split(".")))))'
}
exact_tag() { for tag in "$1" "v${1#v}"; do git ls-remote --refs --tags "$REPO_URL" "refs/tags/$tag" | grep -q . && { printf '%s\n' "$tag"; return; }; done; return 1; }
tag_commit() {
  local commit
  commit="$(git ls-remote "$REPO_URL" "refs/tags/$1^{}" | awk 'NR==1{print $1}')"
  [ -n "$commit" ] || commit="$(git ls-remote --refs --tags "$REPO_URL" "refs/tags/$1" | awk 'NR==1{print $1}')"
  printf '%s\n' "$commit"
}
select_source() {
  if [ "$CHANNEL" = edge ]; then SELECTED_TAG=main; EXPECTED_COMMIT="$(git ls-remote "$REPO_URL" refs/heads/main | awk 'NR==1{print $1}')"
  else
    if [ "$CHANNEL" = exact ]; then
      SELECTED_TAG="$(exact_tag "$VERSION_REF")" || fail "no such release tag: $VERSION_REF"
    else
      SELECTED_TAG="$(latest_stable_tag)"
    fi
    [ -n "${SELECTED_TAG:-}" ] || fail "no matching stable release tag is available"
    EXPECTED_COMMIT="$(tag_commit "$SELECTED_TAG")"
  fi
  case "$EXPECTED_COMMIT" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]* );; *) fail "remote did not provide an expected commit";; esac
}
validate_stage() {
  local stage="$1" host="${2:-}" legacy_root="${3:-}" required actual
  for required in SKILL.md VERSION install.sh scripts scripts/installer_helper.py; do [ -e "$stage/$required" ] || fail "staged install is missing $required"; done
  [ -s "$stage/VERSION" ] || fail "staged install has an empty VERSION"
  if [ "$CHANNEL" != edge ] && [ "$(tr -d '\r\n' < "$stage/VERSION")" != "${SELECTED_TAG#v}" ]; then
    fail "staged VERSION does not match selected release tag"
  fi
  actual="$(git -C "$stage" rev-parse HEAD)"; [ "$actual" = "$EXPECTED_COMMIT" ] || fail "staged commit does not match expected commit"
  [ ! -f "$stage/config/bugsweep.config.json" ] || python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$stage/config/bugsweep.config.json" || fail "staged config is invalid JSON"
  if [ "$host" = agy ] || { [ "$host" = codex ] && [ -z "$legacy_root" ]; }; then
    grep -Fqx "INSTALLER_CAPABILITIES=\"$INSTALLER_CAPABILITIES\"" "$stage/install.sh" || fail "selected release does not support portable host installation; use --edge or a newer release"
  fi
}
stage_source() {
  local parent="$1" host="${2:-}" legacy_root="${3:-}" stage
  stage="$(mktemp -d "$parent/.${SKILL_NAME}.stage.XXXXXX")" || fail "could not create sibling staging directory"
  git clone --quiet --no-checkout "$REPO_URL" "$stage" || fail "could not stage source"
  if [ "$CHANNEL" = edge ]; then git -C "$stage" fetch --quiet --depth=1 origin "$EXPECTED_COMMIT" || fail "could not fetch expected edge commit"
  else git -C "$stage" fetch --quiet --depth=1 origin "refs/tags/$SELECTED_TAG:refs/tags/$SELECTED_TAG" || fail "could not fetch expected release tag"; fi
  git -C "$stage" checkout --quiet --detach "$EXPECTED_COMMIT" || fail "could not check out expected commit"
  git -C "$stage" sparse-checkout init --no-cone || fail "could not initialize sparse staging"
  git -C "$stage" sparse-checkout set '/*' '!/**/AGENTS.md' '!/**/CLAUDE.md' '!/**/GEMINI.md' '!/.claude/' '!/.metaswarm/' || fail "could not exclude development files from staged install"
  validate_stage "$stage" "$host" "$legacy_root"
  printf '\n/install-metadata.json\n' >> "$stage/.git/info/exclude"
  printf '%s\n' "$stage"
}
assert_clean_existing() {
  CONFIG_SOURCE=""; [ ! -e "$1" ] && return
  [ -d "$1/.git" ] || fail "refusing to replace a non-managed install at $1"
  local line path status
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    status="${line:0:2}"; path="${line#?? }"
    case "$status" in ' M'|'M '|'MM') ;; *) fail "refusing to replace a modified install at $1";; esac
    [ "$path" = config/bugsweep.config.json ] || fail "refusing to replace a modified install at $1"
    [ -z "$CONFIG_SOURCE" ] || fail "refusing to replace a modified install at $1"
    CONFIG_SOURCE="$1/$path"
  done <<EOF
$(git -C "$1" status --porcelain --untracked-files=all)
EOF
  [ -z "$CONFIG_SOURCE" ] || [ -f "$CONFIG_SOURCE" ] || fail "custom config is not a regular file"
}
write_metadata() {
  python3 - "$1/install-metadata.json" "$2" "$1" "$3" "$4" "$CHANNEL" "$SELECTED_TAG" "$EXPECTED_COMMIT" "$(tr -d '\r\n' < "$1/VERSION")" <<'PY'
import json,os,sys,tempfile
path,host,root,skills_root,legacy_root,channel,tag,commit,version=sys.argv[1:]
data={"schema_version":1,"host":host,"root":os.path.realpath(root),"canonical_root":os.path.realpath(root),"skills_root":os.path.realpath(skills_root),"legacy_root":os.path.realpath(legacy_root) if legacy_root else None,"selected_channel":channel,"tag":tag,"commit":commit,"version":version}
fd,tmp=tempfile.mkstemp(prefix=".install-metadata.",dir=os.path.dirname(path))
with os.fdopen(fd,"w") as f: json.dump(data,f,sort_keys=True);f.write("\n");f.flush();os.fsync(f.fileno())
os.replace(tmp,path)
PY
}
replace_registration() {
  local root="$1" dest="$2" tmp
  mkdir -p "$root"; tmp="$(mktemp "$root/.instructions.bugsweep.XXXXXX")" || return 1
  python3 "$dest/scripts/installer_helper.py" registration "$root/instructions.md" "$dest" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$root/instructions.md"
}
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\tverified\n' "$1" "$2" "$CHANNEL" "$SELECTED_TAG" "$EXPECTED_COMMIT" "$(tr -d '\r\n' < "$2/VERSION")" >> "$RESULTS_FILE"; }
emit_json() { python3 - "$RESULTS_FILE" "$RECOVERY_FILE" <<'PY'
import csv,json,sys
keys=("host","root","channel","tag","commit","version","status")
with open(sys.argv[1],newline="") as f: rows=[dict(zip(keys,row)) for row in csv.reader(f,delimiter="\t")]
with open(sys.argv[2],encoding="utf-8") as f: recovery=[json.loads(line) for line in f if line.strip()]
print(json.dumps({"schema_version":1,"installations":rows,"recovery":recovery},sort_keys=True))
PY
}
recover_pending() {
  local dest="$1" journal recovery
  journal="$(dirname "$dest")/.${SKILL_NAME}.install-recovery.json"
  [ -f "$journal" ] || return 0
  recovery="$(python3 "$SCRIPT_ROOT/scripts/installer_helper.py" recover "$journal" "$dest")" || fail "existing installer recovery requires manual attention: $journal"
  printf '%s\n' "$recovery" >> "$RECOVERY_FILE"
  rm -f "$journal"
}
write_journal() {
  local journal="$1" dest="$2" stage="$3" backup="$4" original="$5" instructions="$6" existed="$7" registration_backup="$8"
  python3 - "$dest" "$stage" "$backup" "$original" "$instructions" "$existed" "$registration_backup" <<'PY' |
import json,sys
dest,stage,backup,original,instructions,existed,registration_backup=sys.argv[1:]
print(json.dumps({"schema_version":1,"destination":dest,"stage":stage,"backup":backup,"original_exists":original=="true","instructions":instructions or None,"instructions_existed":existed=="true","registration_backup":registration_backup}))
PY
    python3 "$SCRIPT_ROOT/scripts/installer_helper.py" write-transaction "$journal"
}
install_host() {
  local host="$1" dest="$2" skills_root="$3" legacy_root="${4:-}" parent stage backup journal registration_backup="" instructions="" instructions_existed=false original_exists=false registration_root=""
  if [ "$host" = codex ] && [ -n "$legacy_root" ]; then registration_root="$legacy_root"; fi
  parent="$(dirname "$dest")"; mkdir -p "$parent"; parent="$(CDPATH='' cd -- "$parent" && pwd -P)"; dest="$parent/$SKILL_NAME"
  FAILED_HOST="$host"; FAILED_ROOT="$dest"; RECOVERY_HINT=""
  recover_pending "$dest"; assert_clean_existing "$dest"; stage="$(stage_source "$parent" "$host" "$legacy_root")"
  if [ -n "$CONFIG_SOURCE" ]; then python3 "$SCRIPT_ROOT/scripts/installer_helper.py" copy-config "$CONFIG_SOURCE" "$stage/config/bugsweep.config.json" || fail "custom config is invalid"; validate_stage "$stage" "$host" "$legacy_root"; fi
  [ -e "$dest" ] && original_exists=true
  backup="$parent/.${SKILL_NAME}.backup.$$"; journal="$parent/.${SKILL_NAME}.install-recovery.json"; RECOVERY_HINT="$journal"
  if [ "$host" = codex ] && [ -n "$legacy_root" ]; then instructions="$registration_root/instructions.md"; [ -f "$instructions" ] && instructions_existed=true; registration_backup="$registration_root/.instructions.bugsweep.backup.$$"; fi
  [ ! -e "$journal" ] || fail "recovery journal already exists: $journal"
  write_journal "$journal" "$dest" "$stage" "$backup" "$original_exists" "$instructions" "$instructions_existed" "$registration_backup" || fail "could not write recovery journal"
  if $original_exists; then [ ! -e "$backup" ] || fail "recovery backup exists: $backup"; mv "$dest" "$backup"; fi
  if ! mv "$stage" "$dest"; then fail "activation interrupted; recover with the exact journal $journal"; fi
  if [ "$host" = codex ] && [ -n "$legacy_root" ]; then
    if $instructions_existed; then cp "$instructions" "$registration_backup"; fi
    if ! replace_registration "$registration_root" "$dest"; then fail "registration interrupted; recover with the exact journal $journal"; fi
  fi
  if ! write_metadata "$dest" "$host" "$skills_root" "$legacy_root"; then
    fail "metadata write failed; recover with the exact journal $journal"
  fi
  python3 "$SCRIPT_ROOT/scripts/installer_helper.py" commit "$journal" || fail "could not commit transaction journal: $journal"
  $original_exists && rm -rf "$backup"; $instructions_existed && rm -f "$registration_backup"; rm -f "$journal"; record "$host" "$dest"; RECOVERY_HINT=""
}

while [ "$#" -gt 0 ]; do case "$1" in
  --claude) DO_CLAUDE=true;EXPLICIT=true;; --codex) DO_CODEX=true;EXPLICIT=true;; --agy) DO_AGY=true;EXPLICIT=true;; --all) DO_CLAUDE=true;DO_CODEX=true;DO_AGY=true;EXPLICIT=true;;
  --edge) [ -z "$VERSION_REF" ] || fail "--edge cannot be combined with --version"; CHANNEL=edge;;
  --version) shift; [ "$#" -gt 0 ] || fail "--version requires an exact release tag"; [ "$CHANNEL" = stable ] || fail "--version cannot be combined with --edge"; VERSION_REF="$1";CHANNEL=exact;;
  --version=*) [ "$CHANNEL" = stable ] || fail "--version cannot be combined with --edge";VERSION_REF="${1#*=}";[ -n "$VERSION_REF" ]||fail "--version requires an exact release tag";CHANNEL=exact;;
  --json) JSON=true;; --update) :;; --help|-h) printf '%s\n' 'usage: install.sh [--claude|--codex|--agy|--all] [--edge|--version TAG] [--json]' 'requires Python 3.12+ and jsonschema==4.26.0; this installer does not install dependencies';exit 0;; *) fail "unknown flag: $1";; esac; shift; done
require git; require python3; RESULTS_FILE="$(mktemp "${TMPDIR:-/tmp}/bugsweep-install-results.XXXXXX")" || fail "could not create result file"; RECOVERY_FILE="$(mktemp "${TMPDIR:-/tmp}/bugsweep-install-recovery.XXXXXX")" || fail "could not create recovery result file"; trap 'rm -f "$RESULTS_FILE" "$RECOVERY_FILE"' EXIT; require_runtime_dependencies
claude_root="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
if [ -n "${AGY_SKILLS_DIR:-}" ]; then
  agy_root="$AGY_SKILLS_DIR"
elif [ -d "$HOME/.gemini/antigravity-cli" ]; then
  agy_root="$HOME/.gemini/antigravity-cli/skills"
elif [ -d "$HOME/.gemini/config/skills" ]; then
  agy_root="$HOME/.gemini/config/skills"
else
  agy_root="$HOME/.gemini/antigravity-cli/skills"
fi
codex_legacy_root=""; codex_skills_root=""
if [ -n "${CODEX_DIR:-}" ]; then
  codex_legacy_root="$CODEX_DIR"; codex_skills_root="$codex_legacy_root/skills"
elif [ -n "${CODEX_SKILLS_DIR:-}" ]; then
  codex_skills_root="$CODEX_SKILLS_DIR"
elif [ -d "$HOME/.codex/skills/$SKILL_NAME" ] && { [ -f "$HOME/.codex/skills/$SKILL_NAME/install-metadata.json" ] || { [ -f "$HOME/.codex/instructions.md" ] && grep -qF '<!-- bugsweep-skill -->' "$HOME/.codex/instructions.md"; }; }; then
  codex_legacy_root="$HOME/.codex"; codex_skills_root="$codex_legacy_root/skills"
else
  codex_skills_root="$HOME/.agents/skills"
fi
if ! $EXPLICIT; then
  { [ -n "${CLAUDE_SKILLS_DIR:-}" ] || [ -d "$HOME/.claude" ]; } && DO_CLAUDE=true
  { [ -n "${CODEX_DIR:-}" ] || [ -n "${CODEX_SKILLS_DIR:-}" ] || [ -d "$HOME/.codex" ] || [ -d "$HOME/.agents" ]; } && DO_CODEX=true
  { [ -n "${AGY_SKILLS_DIR:-}" ] || [ -d "$HOME/.gemini/antigravity-cli" ] || [ -d "$HOME/.gemini/config/skills" ]; } && DO_AGY=true
fi
if $DO_CODEX; then
  if [ -n "${CODEX_DIR:-}" ] && [ -n "${CODEX_SKILLS_DIR:-}" ]; then fail "CODEX_DIR and CODEX_SKILLS_DIR cannot both be configured"; fi
  valid_root "$codex_skills_root"; [ -z "$codex_legacy_root" ] || valid_root "$codex_legacy_root"
fi
$DO_CLAUDE && valid_root "$claude_root"
$DO_AGY && valid_root "$agy_root"
$DO_CLAUDE || $DO_CODEX || $DO_AGY || fail "no Claude, Codex, or Antigravity root detected; use --claude, --codex, --agy, or --all"
select_source
$DO_CLAUDE && install_host claude "$claude_root/$SKILL_NAME" "$claude_root"
$DO_CODEX && install_host codex "$codex_skills_root/$SKILL_NAME" "$codex_skills_root" "$codex_legacy_root"
$DO_AGY && install_host agy "$agy_root/$SKILL_NAME" "$agy_root"
if $JSON; then emit_json; else printf 'bugsweep installed from %s (%s)\n' "$SELECTED_TAG" "$EXPECTED_COMMIT"; fi
