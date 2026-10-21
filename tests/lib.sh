#!/usr/bin/env bash
# Shared helpers for the offline test suite. No network access is required.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$ROOT_DIR/tests"
FAKE_BIN="$TESTS_DIR/fake-bin"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""

ok()   { PASS_COUNT=$((PASS_COUNT + 1)); }
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL [%s] %s\n' "${CURRENT_TEST:-?}" "$*" >&2
}

assert_eq() { # expected actual message
  if [ "${1:-}" = "${2:-}" ]; then ok; else fail "${3:-expected [$1], got [$2]}"; fi
}

assert_contains() { # needle haystack message
  case "${2:-}" in
    *"${1:-}"*) ok ;;
    *) fail "${3:-expected output to contain [$1]}" ;;
  esac
}

assert_not_contains() {
  case "${2:-}" in
    *"${1:-}"*) fail "${3:-expected output NOT to contain [$1]}" ;;
    *) ok ;;
  esac
}

assert_rc() { # expected actual message
  if [ "${1:-}" -eq "${2:-}" ] 2>/dev/null; then ok; else fail "${3:-expected rc $1, got $2}"; fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sshmgr-test.XXXXXX")"
  export SANDBOX
  export HOME="$SANDBOX/home"
  export SSHMGR_HOME="$SANDBOX/home/.ssh-server-manager"
  export TMPDIR="$SANDBOX/tmp"
  mkdir -p "$HOME" "$TMPDIR" "$SSHMGR_HOME"
  export PATH="$FAKE_BIN:$PATH"
}

cleanup_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

summary() {
  printf '\n%s: %d passed, %d failed\n' "${1:-tests}" "$PASS_COUNT" "$FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ]
}
