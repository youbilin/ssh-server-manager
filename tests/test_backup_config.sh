#!/usr/bin/env bash
# shellcheck disable=SC2034
# Offline tests for backup_config.sh. The fake ssh executes the piped remote script
# locally inside the sandbox when FAKE_SSH_EXEC_STDIN=1.

. "$(dirname "$0")/lib.sh"

BC="$ROOT_DIR/scripts/backup_config.sh"

new_sandbox
trap cleanup_sandbox EXIT
unset SSHMGR_SSH
export FAKE_SSH_G_HOST="fake-host"
export FAKE_SSH_G_PORT="22"
export FAKE_SSH_G_USER="deploy"
export FAKE_SSH_EXEC_STDIN=1
export FAKE_SSH_RC=0

mkdir -p "$SANDBOX/etc/nginx"
printf 'server { listen 80; }\n' > "$SANDBOX/etc/nginx/nginx.conf"

CURRENT_TEST="backup and restore command"
out="$(bash "$BC" -H example.invalid -f "$SANDBOX/etc/nginx/nginx.conf" 2>&1)"
rc=$?
assert_rc 0 "$rc" "backup should succeed: $out"
assert_contains "备份成功" "$out" "backup confirmation"
assert_contains "还原命令" "$out" "restore section"
assert_contains "cp -p --" "$out" "restore must copy on the remote side"
assert_contains "ssh" "$out" "restore must include an ssh prefix"
assert_contains "example.invalid" "$out" "restore must name the target host"
assert_contains "nginx -t" "$out" "restore should print the syntax check"
assert_eq "1" "$(find "$HOME/.config-backups" -name 'nginx.conf.*.bak' 2>/dev/null | wc -l | tr -d ' ')" "one backup file expected"

CURRENT_TEST="restore command carries port and jump"
out="$(bash "$BC" -H example.invalid -p 2222 -J bastion -f "$SANDBOX/etc/nginx/nginx.conf" 2>&1)"
rc=$?
assert_rc 0 "$rc" "port/jump backup: $out"
assert_contains "-p 2222" "$out" "restore should carry the port"
assert_contains "-J bastion" "$out" "restore should carry the jump host"

CURRENT_TEST="list and prune"
rm -rf "$HOME/.config-backups"
bash "$BC" -H example.invalid -f "$SANDBOX/etc/nginx/nginx.conf" >/dev/null 2>&1
bash "$BC" -H example.invalid -f "$SANDBOX/etc/nginx/nginx.conf" >/dev/null 2>&1
out="$(bash "$BC" -H example.invalid -f "$SANDBOX/etc/nginx/nginx.conf" --list 2>&1)"
assert_contains "nginx.conf" "$out" "list should show backups"
assert_eq "2" "$(find "$HOME/.config-backups" -name 'nginx.conf.*.bak' | wc -l | tr -d ' ')" "same-second backups must not overwrite"
bash "$BC" -H example.invalid -f "$SANDBOX/etc/nginx/nginx.conf" --keep 1 >/dev/null 2>&1
assert_eq "1" "$(find "$HOME/.config-backups" -name 'nginx.conf.*.bak' | wc -l | tr -d ' ')" "--keep 1 should leave one backup"

CURRENT_TEST="keep 0 rejected"
out="$(bash "$BC" -H example.invalid -f "$SANDBOX/etc/nginx/nginx.conf" --keep 0 2>&1)"
rc=$?
assert_rc 2 "$rc" "keep 0 rc"
assert_contains "至少为 1" "$out" "keep 0 message"

CURRENT_TEST="no password on argv"
: > "$SANDBOX/ssh.log"
export FAKE_SSH_LOG="$SANDBOX/ssh.log"
export BC_PW='backup-secret'
out="$(bash "$BC" -H example.invalid -f "$SANDBOX/etc/nginx/nginx.conf" --auth password --password-env BC_PW 2>&1)"
rc=$?
assert_rc 0 "$rc" "password-auth backup: $out"
assert_not_contains "backup-secret" "$(cat "$SANDBOX/ssh.log")" "password must not be on ssh argv"
assert_not_contains "backup-secret" "$out" "password must not be in output"
assert_contains "cp -p --" "$out" "restore command still present"

summary "test_backup_config"
