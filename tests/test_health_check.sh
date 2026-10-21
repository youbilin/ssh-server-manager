#!/usr/bin/env bash
# shellcheck disable=SC2034
# Offline tests for health_check.sh. Runs the script locally with a fake docker.

. "$(dirname "$0")/lib.sh"

HC="$ROOT_DIR/scripts/health_check.sh"

new_sandbox
trap cleanup_sandbox EXIT

CURRENT_TEST="docker status classification"
out="$(bash "$HC" --sections docker 2>&1)"
rc=$?
assert_rc 0 "$rc" "health_check rc"
assert_contains "job" "$out" "exited container should be reported"
assert_not_contains "web" "$out" "plain Up container must not be flagged"
assert_contains "SSHMGR_VERDICT=WARN" "$out" "exited container should produce WARN"

CURRENT_TEST="sections validation"
out="$(bash "$HC" --sections nope 2>&1)"
rc=$?
assert_rc 1 "$rc" "unknown section rc"
assert_contains "未知段落" "$out" "unknown section message"

CURRENT_TEST="threshold validation"
out="$(bash "$HC" --sections docker --disk-warn abc 2>&1)"
rc=$?
assert_rc 1 "$rc" "bad threshold rc"
assert_contains "不是数字" "$out" "bad threshold message"

CURRENT_TEST="quick docker note"
out="$(bash "$HC" --sections docker --quick 2>&1)"
assert_contains "跳过 Docker" "$out" "quick should say docker was skipped"

summary "test_health_check"
