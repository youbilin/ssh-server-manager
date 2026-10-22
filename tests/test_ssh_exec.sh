#!/usr/bin/env bash
# shellcheck disable=SC2034
# Offline tests for ssh_exec.sh. The fake ssh logs argv and never opens a socket.

. "$(dirname "$0")/lib.sh"

SSH_EXEC="$ROOT_DIR/scripts/ssh_exec.sh"

new_sandbox
trap cleanup_sandbox EXIT
unset SSHMGR_SSH
export FAKE_SSH_LOG="$SANDBOX/ssh.log"
export FAKE_SSH_G_HOST="fake-host"
export FAKE_SSH_G_PORT="22"
export FAKE_SSH_G_USER="deploy"
export FAKE_SSH_G_KH="$HOME/.ssh/known_hosts"
: > "$FAKE_SSH_LOG"

sv() { bash "$SSH_EXEC" "$@" 2>&1; }

# 1. dry-run must not connect, prompt, or save credentials.
CURRENT_TEST="dry-run side effects"
rm -f "$SSHMGR_HOME/credentials"
: > "$FAKE_SSH_LOG"
out="$(sv -H example.invalid --auth password --password-env TEST_PW --save-credential --dry-run -c 'df -h')"
rc=$?
assert_rc 0 "$rc" "dry-run rc"
assert_contains "风险等级" "$out" "dry-run output"
assert_eq "0" "$(wc -l < "$FAKE_SSH_LOG" | tr -d ' ')" "dry-run must not invoke ssh"
assert_eq "0" "$([ -f "$SSHMGR_HOME/credentials" ] && echo 1 || echo 0)" "dry-run must not save credentials"
assert_eq "0" "$(find "$TMPDIR" -maxdepth 1 -name 'sshmgr-*' 2>/dev/null | wc -l | tr -d ' ')" "dry-run must not leave temp files"

# 2. --print-tier is a stable machine interface and needs no host or connection.
CURRENT_TEST="print-tier"
: > "$FAKE_SSH_LOG"
assert_eq "1" "$(sv --print-tier -c 'systemctl restart nginx')" "mutating tier"
assert_eq "2" "$(sv --print-tier -c 'rm --recursive --force /tmp/x')" "dangerous tier"
assert_eq "0" "$(wc -l < "$FAKE_SSH_LOG" | tr -d ' ')" "print-tier must not invoke ssh"

# 3. Tier 2 is refused before any authentication or network activity.
CURRENT_TEST="danger refused before auth"
: > "$FAKE_SSH_LOG"
out="$(sv -H example.invalid --auth password --password-env TEST_PW -c 'rm -rf /tmp/sshmgr-test')"
rc=$?
assert_rc 4 "$rc" "tier2 refusal rc"
assert_contains "已拒绝执行" "$out" "tier2 message"
assert_eq "0" "$(wc -l < "$FAKE_SSH_LOG" | tr -d ' ')" "tier2 refusal must not invoke ssh"
assert_eq "0" "$(find "$TMPDIR" -maxdepth 1 -name 'sshmgr-*' 2>/dev/null | wc -l | tr -d ' ')" "tier2 refusal must not leave temp files"

# 4. --selftest does not read or persist credentials, and leaves no temp files.
CURRENT_TEST="selftest leak"
out="$(sv --selftest --auth password)"
rc=$?
assert_rc 0 "$rc" "selftest rc"
assert_contains "askpass 端到端" "$out" "selftest should test askpass"
assert_eq "0" "$(find "$TMPDIR" -maxdepth 1 -name 'sshmgr-*' 2>/dev/null | wc -l | tr -d ' ')" "selftest must not leave password temp files"
assert_eq "0" "$([ -f "$SSHMGR_HOME/credentials" ] && echo 1 || echo 0)" "selftest must not save credentials"

# 5. Host-key acceptance: exact fingerprint only, one key line only.
CURRENT_TEST="host key exact match"
KEY="$SANDBOX/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$KEY" >/dev/null 2>&1
PUB="$(cut -d' ' -f1-2 "$KEY.pub")"
FP="$(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')"
printf '[fake-host]:2222 %s\n' "$PUB" > "$SANDBOX/keyscan.out"
export FAKE_KEYSCAN_OUTPUT="$SANDBOX/keyscan.out"
export FAKE_SSH_G_PORT="2222"
rm -rf "$HOME/.ssh"; mkdir -p "$HOME/.ssh"
out="$(sv -H web-alias -p 2222 --accept-host-key --fingerprint "$FP")"
rc=$?
assert_rc 0 "$rc" "exact fingerprint should be accepted: $out"
assert_contains "已写入" "$out" "write confirmation"
assert_eq "1" "$(grep -c '^\[fake-host\]:2222 ' "$HOME/.ssh/known_hosts" 2>/dev/null)" "exactly one key line"

# Show-only prints candidates and writes nothing.
CURRENT_TEST="host key show only"
rm -rf "$HOME/.ssh"; mkdir -p "$HOME/.ssh"
out="$(sv -H web-alias -p 2222 --show-host-key)"
rc=$?
assert_rc 0 "$rc" "show-host-key rc"
assert_contains "只查看模式" "$out" "show-only message"
assert_eq "0" "$([ -f "$HOME/.ssh/known_hosts" ] && echo 1 || echo 0)" "show must not create known_hosts"

# Accept without a fingerprint is refused (no silent trust).
CURRENT_TEST="accept without fingerprint"
out="$(sv -H web-alias -p 2222 --accept-host-key)"
rc=$?
assert_rc 2 "$rc" "accept without fingerprint rc"
assert_contains "没有提供 --fingerprint" "$out" "missing fingerprint message"
assert_eq "0" "$([ -f "$HOME/.ssh/known_hosts" ] && echo 1 || echo 0)" "no write without a fingerprint"

# A prefix of a valid fingerprint must be refused.
CURRENT_TEST="host key prefix refused"
rm -rf "$HOME/.ssh"; mkdir -p "$HOME/.ssh"
partial="${FP:0:20}"
out="$(sv -H web-alias -p 2222 --accept-host-key --fingerprint "$partial")"
rc=$?
assert_rc 2 "$rc" "partial fingerprint must be refused"
assert_eq "0" "$([ -s "$HOME/.ssh/known_hosts" ] && echo 1 || echo 0)" "nothing should be written for a partial fingerprint"

# A different fingerprint must not overwrite an existing entry.
CURRENT_TEST="host key mismatch"
printf '[fake-host]:2222 %s\n' "$PUB" > "$HOME/.ssh/known_hosts"
out="$(sv -H web-alias -p 2222 --accept-host-key --fingerprint 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')"
rc=$?
assert_rc 2 "$rc" "wrong fingerprint rc"
assert_contains "指纹不匹配" "$out" "mismatch message"

# A different existing key must not be overwritten, even when the new key's FP is valid.
CURRENT_TEST="host key existing changed"
KEY2="$SANDBOX/hostkey2"
ssh-keygen -q -t ed25519 -N '' -f "$KEY2" >/dev/null 2>&1
PUB2="$(cut -d' ' -f1-2 "$KEY2.pub")"
printf '[fake-host]:2222 %s\n' "$PUB2" > "$HOME/.ssh/known_hosts"
out="$(sv -H web-alias -p 2222 --accept-host-key --fingerprint "$FP")"
rc=$?
assert_rc 2 "$rc" "existing different key rc"
assert_contains "已存在" "$out" "existing key message"
assert_contains "$PUB2" "$(cat "$HOME/.ssh/known_hosts")" "old entry must be preserved"

CURRENT_TEST="host key already present"
printf '[fake-host]:2222 %s\n' "$PUB" > "$HOME/.ssh/known_hosts"
out="$(sv -H web-alias -p 2222 --accept-host-key --fingerprint "$FP")"
rc=$?
assert_rc 0 "$rc" "same existing key should be idempotent"
assert_contains "已有相同指纹" "$out" "idempotent message"

# 6. Saving a credential writes the private file and still keeps it out of argv.
CURRENT_TEST="save credential"
export SAVE_PW='save-me-please'
: > "$FAKE_SSH_LOG"
out="$(sv -H example.invalid --auth password --password-env SAVE_PW --save-credential --no-preflight -c 'true')"
rc=$?
assert_rc 0 "$rc" "save-credential execution: $out"
assert_eq "save-me-please" "$(head -1 "$SSHMGR_HOME/credentials" 2>/dev/null)" "saved credential content"
assert_not_contains "save-me-please" "$(cat "$FAKE_SSH_LOG")" "password must not be on argv"
assert_eq "0" "$(find "$TMPDIR" -maxdepth 1 -name 'sshmgr-*' 2>/dev/null | wc -l | tr -d ' ')" "no temp files after saving"

# 7. Saved credential is reused, and never appears in ssh argv.
CURRENT_TEST="saved credential"
printf 'saved-secret\n' > "$SSHMGR_HOME/credentials"
export FAKE_SSH_G_PORT="22"
: > "$FAKE_SSH_LOG"
out="$(sv -H example.invalid --auth password --use-saved-credential --no-preflight -c 'true')"
rc=$?
assert_rc 0 "$rc" "saved credential execution: $out"
assert_not_contains "saved-secret" "$(cat "$FAKE_SSH_LOG")" "password must not appear in argv"
assert_eq "0" "$(find "$TMPDIR" -maxdepth 1 -name 'sshmgr-*' 2>/dev/null | wc -l | tr -d ' ')" "no temp files after execution"

# 8. Without GNU timeout, the built-in watchdog still bounds execution time.
CURRENT_TEST="watchdog fallback"
start="$(date +%s)"
out="$(SSHMGR_NO_TIMEOUT=1 bash "$SSH_EXEC" -H slow-host --auth key --no-preflight -t 1 -c 'true' 2>&1)"
rc=$?
elapsed=$(( $(date +%s) - start ))
assert_rc 124 "$rc" "watchdog timeout rc: $out"
assert_contains "执行超时" "$out" "timeout message"
assert_eq "1" "$([ "$elapsed" -le 6 ] && echo 1 || echo 0)" "watchdog should stop within a few seconds (took ${elapsed}s)"

# 9. Audit log keeps one parseable line and escapes pipes.
CURRENT_TEST="audit log escaping"
: > "$FAKE_SSH_LOG"
out="$(sv -H example.invalid --auth key --no-preflight -c 'echo a|b')"
rc=$?
assert_rc 0 "$rc" "audit-log command rc: $out"
line="$(tail -1 "$SSHMGR_HOME/audit.log" 2>/dev/null)"
assert_contains "tier0" "$line" "audit line tier"
assert_contains 'echo a\|b' "$line" "audit line must escape pipes"

# 10. Script mode preflights bash and gives an Alpine-specific message.
CURRENT_TEST="missing remote bash"
out="$(FAKE_SSH_NO_BASH=1 bash "$SSH_EXEC" -H example.invalid --auth key \
  -f "$ROOT_DIR/scripts/health_check.sh" 2>&1)"
rc=$?
assert_rc 2 "$rc" "missing bash rc"
assert_contains "apk add bash" "$out" "Alpine guidance"
assert_contains "没有 bash" "$out" "missing bash message"

# 11. Usage guards.
CURRENT_TEST="usage guards"
out="$(sv --fingerprint 'SHA256:x' -H h -c true)"
assert_contains "只能配合" "$out" "fingerprint without accept/show should be rejected"
out="$(sv -H user1@host -u user2 -c true)"
assert_contains "不一致" "$out" "conflicting users should be rejected"

summary "test_ssh_exec"
