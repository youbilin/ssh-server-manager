#!/usr/bin/env bash
# Build installable release archives for Claude Code and Codex.
# Usage: tools/package-release.sh [version]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

VERSION="${1:-}"
if [ -z "$VERSION" ] && command -v git >/dev/null 2>&1; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
fi
[ -n "$VERSION" ] || VERSION="v0.0.0-dev"
case "$VERSION" in
  v*) ;;
  *) VERSION="v$VERSION" ;;
esac
case "$VERSION" in
  v[0-9]*) ;;
  *)
    echo "invalid version: $VERSION (expected vX.Y.Z)" >&2
    exit 1
    ;;
esac

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssm-release.XXXXXX")"
cleanup() { rm -rf "$STAGE_DIR"; }
trap cleanup EXIT HUP INT TERM

need_file() {
  [ -f "$1" ] || { echo "missing required file: $1" >&2; exit 1; }
}

need_file "$ROOT_DIR/SKILL.md"
need_file "$ROOT_DIR/codex/SKILL.md"
need_file "$ROOT_DIR/README.md"
need_file "$ROOT_DIR/README.zh-CN.md"
need_file "$ROOT_DIR/LICENSE"

copy_docs() {
  local dest="$1"
  cp "$ROOT_DIR/README.md" "$ROOT_DIR/README.zh-CN.md" "$dest/"
}

# --- Claude Code build -------------------------------------------------------
CLAUDE_STAGE="$STAGE_DIR/claude/ssh-server-manager"
mkdir -p "$CLAUDE_STAGE"
cp "$ROOT_DIR/SKILL.md" "$ROOT_DIR/LICENSE" "$CLAUDE_STAGE/"
copy_docs "$CLAUDE_STAGE"
cp -R "$ROOT_DIR/scripts" "$ROOT_DIR/references" "$ROOT_DIR/assets" "$CLAUDE_STAGE/"

# --- Codex build -------------------------------------------------------------
CODEX_STAGE="$STAGE_DIR/codex/ssh-server-manager"
mkdir -p "$CODEX_STAGE"
cp -R "$ROOT_DIR/codex/." "$CODEX_STAGE/"
copy_docs "$CODEX_STAGE"

# Both archives must be self-contained and free of local runtime state.
for stage in "$CLAUDE_STAGE" "$CODEX_STAGE"; do
  need_file "$stage/SKILL.md"
  find "$stage" \( -name '*.profile' -o -name '*.partial' -o -name 'audit.log' \
    -o -name 'askpass.log' -o -name 'credentials' -o -name 'credentials.d' \) \
    -print0 | while IFS= read -r -d '' stray; do
      echo "refusing to package local runtime state: $stray" >&2
      exit 1
    done
done

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/ssh-server-manager-*.zip "$DIST_DIR"/ssh-server-manager-*.tar.gz \
  "$DIST_DIR/SHA256SUMS"

build_archives() {
  local name="$1" stage="$2"
  tar -czf "$DIST_DIR/$name-$VERSION.tar.gz" -C "$stage/.." ssh-server-manager
  if command -v zip >/dev/null 2>&1; then
    ( cd "$stage/.." && zip -qr "$DIST_DIR/$name-$VERSION.zip" ssh-server-manager )
  else
    echo "zip not found; only .tar.gz was produced" >&2
  fi
}

build_archives "ssh-server-manager-claude" "$CLAUDE_STAGE"
build_archives "ssh-server-manager-codex" "$CODEX_STAGE"

# --- Checksums ---------------------------------------------------------------
(
  cd "$DIST_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum ssh-server-manager-*.zip ssh-server-manager-*.tar.gz > SHA256SUMS
  else
    shasum -a 256 ssh-server-manager-*.zip ssh-server-manager-*.tar.gz > SHA256SUMS
  fi
)

echo "Release assets in $DIST_DIR:"
ls -lh "$DIST_DIR" | sed '1d'
