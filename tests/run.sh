#!/usr/bin/env bash
# Run the offline test suite. No network, no real SSH host, no real credentials.
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

fail=0

echo "== bash -n =="
for f in scripts/*.sh scripts/lib/*.sh tests/*.sh tools/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f"; then :; else
    echo "SYNTAX FAIL: $f" >&2
    fail=1
  fi
done

echo
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning scripts/*.sh scripts/lib/*.sh tests/*.sh tools/*.sh; then
    echo "shellcheck: OK"
  else
    fail=1
  fi
else
  echo "shellcheck: not installed (skipped)"
fi

echo
echo "== offline tests =="
for t in tests/test_*.sh; do
  [ -f "$t" ] || continue
  echo
  echo "--- $t ---"
  if bash "$t"; then :; else
    fail=1
  fi
done

exit "$fail"
