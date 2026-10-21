#!/usr/bin/env bash
# shellcheck disable=SC2034
# Offline-ish tests for tcping.sh. Uses 127.0.0.1 and never sends traffic beyond loopback
# (the transparent-proxy control probe is allowed to fail or succeed).

. "$(dirname "$0")/lib.sh"

TCP="$ROOT_DIR/scripts/tcping.sh"

new_sandbox
trap cleanup_sandbox EXIT

CURRENT_TEST="closed port result"
out="$(bash "$TCP" -H 127.0.0.1 -p 1 -n 1 -q 2>&1)"
rc=$?
assert_rc 2 "$rc" "closed port rc"
assert_contains "SSHMGR_TCPING=127.0.0.1:1" "$out" "result line"
assert_contains "clock=" "$out" "clock should be reported"
assert_contains "loss=1/1" "$out" "one probe should be lost"

CURRENT_TEST="port validation"
out="$(bash "$TCP" -H 127.0.0.1 -p 0 -n 1 -q 2>&1)"
rc=$?
assert_rc 1 "$rc" "port 0 rc"
assert_contains "1-65535" "$out" "port range message"

CURRENT_TEST="count validation"
out="$(bash "$TCP" -H 127.0.0.1 -p 22 -n 0 -q 2>&1)"
rc=$?
assert_rc 1 "$rc" "count 0 rc"
assert_contains "至少为 1" "$out" "count message"

summary "test_tcping"
