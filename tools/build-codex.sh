#!/usr/bin/env bash
# Regenerate the shared parts of the Codex build from the Claude Code build.
#
# scripts/, references/, assets/ and LICENSE are kept byte-identical between the
# two builds. Only codex/SKILL.md (and agents/openai.yaml) are Codex-specific.
#
# Usage:
#   tools/build-codex.sh          # rewrite codex/{scripts,references,assets}
#   tools/build-codex.sh --check  # fail if the generated copy is stale

set -uo pipefail
LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEX="$ROOT/codex"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

if [ "$CHECK" -eq 1 ]; then
  fail=0
  for d in scripts references assets; do
    if ! diff -rq "$ROOT/$d" "$CODEX/$d" >/dev/null 2>&1; then
      printf 'codex/%s is out of sync. Run tools/build-codex.sh\n' "$d" >&2
      diff -rq "$ROOT/$d" "$CODEX/$d" >&2 || true
      fail=1
    fi
  done
  if ! cmp -s "$ROOT/LICENSE" "$CODEX/LICENSE.txt"; then
    printf 'codex/LICENSE.txt is out of sync. Run tools/build-codex.sh\n' >&2
    fail=1
  fi
  [ "$fail" -eq 0 ] && echo "codex build is in sync"
  exit "$fail"
fi

for d in scripts references assets; do
  rm -rf "${CODEX:?}/${d:?}"
  cp -R "$ROOT/$d" "$CODEX/$d"
done
cp "$ROOT/LICENSE" "$CODEX/LICENSE.txt"
echo "Regenerated codex/scripts, codex/references, codex/assets, codex/LICENSE.txt"
echo "Remember: codex/SKILL.md is maintained separately."
