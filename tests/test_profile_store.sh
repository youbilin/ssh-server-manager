#!/usr/bin/env bash
# shellcheck disable=SC2034
# Offline tests for profile_store.sh using tests/fake-bin/ssh.
# No network and no real credentials are used.

. "$(dirname "$0")/lib.sh"

PS="$ROOT_DIR/scripts/profile_store.sh"
FIXTURE=""

run_ps() {
  bash "$PS" "$@" 2>&1
}

setup_fake_ssh() {
  export FAKE_SSH_G_HOST="${1:-fake-host}"
  export FAKE_SSH_G_PORT="${2:-22}"
  export FAKE_SSH_G_USER="${3:-deploy}"
  export FAKE_SSH_G_KH="${4:-$HOME/.ssh/known_hosts}"
  export FAKE_SSH_OUTPUT="$FIXTURE"
  export FAKE_SSH_RC=0
  unset SSHMGR_SSH
}

new_sandbox
trap cleanup_sandbox EXIT
FIXTURE="$SANDBOX/profile.ok"
cat > "$FIXTURE" <<'EOF'
profile_schema=1
hostname=web1.example
machine_id=abc123
boot_id=boot-1
ip_primary=203.0.113.10
ip_all=203.0.113.10
cpu_model=Test CPU
mem_total_mb=8192
docker=present
docker_container.0=web|nginx:latest|running|Up 2 hours|
unit_running.0=nginx.service
profile_complete=1
EOF
setup_fake_ssh fake-host 2222 deploy

# 1. Port goes into the filename.
CURRENT_TEST="port filename"
out="$(run_ps collect -H web1.example -p 2222 --skip-tcping)"
assert_contains "档案已写入" "$out" "collect should succeed: $out"
assert_eq "1" "$(ls "$SSHMGR_HOME/profiles" | wc -l | tr -d ' ')" "one profile expected"
assert_eq "1" "$([ -f "$SSHMGR_HOME/profiles/web1.example_2222.profile" ] && echo 1 || echo 0)" "expected _2222 filename"

# 2. Partial refresh keeps stale sections it did not refresh.
CURRENT_TEST="stale merge"
run_ps mark-stale -H web1.example -p 2222 --sections services --reason restart >/dev/null
run_ps collect -H web1.example -p 2222 --sections docker --skip-tcping >/dev/null
grep -q '^stale_sections=services$' "$SSHMGR_HOME/profiles/web1.example_2222.profile"
assert_rc 0 $? "services should remain stale after refreshing only docker"

# 2b. A refresh without a latency probe keeps the previous latency values.
CURRENT_TEST="latency preservation"
printf 'latency_min_ms=10\nlatency_avg_ms=12\nlatency_reliable=1\n' >> "$SSHMGR_HOME/profiles/web1.example_2222.profile"
run_ps collect -H web1.example -p 2222 --sections docker --skip-tcping >/dev/null
grep -q '^latency_avg_ms=12$' "$SSHMGR_HOME/profiles/web1.example_2222.profile"
assert_rc 0 $? "latency should survive a skip-tcping refresh"

# 3. Collecting by alias without -p reuses the stored port/profile.
CURRENT_TEST="alias reuse"
setup_fake_ssh fake-host 2222 deploy
run_ps collect -H web1.example --skip-tcping >/dev/null
assert_eq "1" "$(ls "$SSHMGR_HOME/profiles" | wc -l | tr -d ' ')" "alias collect must update, not duplicate"

# 3b. Stored connection metadata (port/user/jump) is reused by later collect/check.
CURRENT_TEST="connection metadata reuse"
setup_fake_ssh fake-host 2222 deploy
: > "$SANDBOX/ssh.log"
export FAKE_SSH_LOG="$SANDBOX/ssh.log"
run_ps collect -H jumphost.example -u deploy -p 2222 -J bastion --skip-tcping >/dev/null
run_ps collect -H jumphost.example -u deploy -p 2222 -J bastion --sections docker --skip-tcping >/dev/null
: > "$SANDBOX/ssh.log"
run_ps collect -H jumphost.example --sections docker --skip-tcping >/dev/null
log="$(cat "$SANDBOX/ssh.log")"
assert_contains "-p 2222" "$log" "stored port should be reused"
assert_contains "-J bastion" "$log" "stored jump should be reused"
assert_contains "deploy@jumphost.example" "$log" "stored user should be reused"
grep -q '^latency_reliable=skip$' "$SSHMGR_HOME/profiles/jumphost.example_2222.profile"
assert_rc 0 $? "jump latency should be marked skip"
printf 'diskstat.0=sda|read=1000|written=2000\n' >> "$SSHMGR_HOME/profiles/jumphost.example_2222.profile"
printf 'boot-1\n123\n__SSHMGR_DISKSTATS__\n8 0 sda 10 0 3048 0 20 0 4048 0 0 0 0\n' > "$SANDBOX/check.out"
export FAKE_SSH_OUTPUT="$SANDBOX/check.out"
out="$(run_ps check -H jumphost.example)"
assert_contains "未重启" "$out" "check should reuse stored connection metadata: $out"
assert_contains "磁盘 IO" "$out" "check should report disk IO"
assert_contains "1.0 MB" "$out" "check should compute sector delta"
export FAKE_SSH_OUTPUT="$FIXTURE"

# 4. An explicit different port creates a separate profile.
CURRENT_TEST="port separation"
setup_fake_ssh fake-host 22 deploy
run_ps collect -H web1.example -p 22 --skip-tcping >/dev/null
_n=0
for _f in "$SSHMGR_HOME/profiles"/web1.example*; do [ -e "$_f" ] && _n=$((_n + 1)); done
assert_eq "2" "$_n" "port 22 should be a separate profile"
run_ps find -H web1.example -p 2222 >/dev/null
assert_rc 0 $? "find with -p 2222 should pick the suffixed profile"
run_ps find -H web1.example >/dev/null
assert_rc 2 $? "find without -p should refuse two candidates"

# 5. set --note works and protected keys are refused.
CURRENT_TEST="set --note"
run_ps set -H web1.example -p 2222 --note "prod db" >/dev/null
grep -q '^note=prod db$' "$SSHMGR_HOME/profiles/web1.example_2222.profile"
assert_rc 0 $? "set --note should write the note"
out="$(run_ps set -H web1.example -p 2222 machine_id=evil)"
assert_contains "由采集器维护" "$out" "protected keys must be refused"

# 6. Exact matching: find -H web1 must not match web10.
CURRENT_TEST="exact lookup"
printf 'alias=web10\nhostname=web10.example\nip_primary=203.0.113.100\nssh_port=22\nprofile_complete=1\n' \
  > "$SSHMGR_HOME/profiles/web10.profile"
setup_fake_ssh fake-host 22 deploy
run_ps find -H web1 >/dev/null
assert_rc 2 $? "prefix web1 must not match web10"
printf 'collector_sha256=deadbeef\n' >> "$SSHMGR_HOME/profiles/web10.profile"
out="$(run_ps hint -H web10)"
assert_contains "采集器已更新" "$out" "collector change should be hinted"

# 7. compare renders local profiles without a network call.
CURRENT_TEST="compare"
setup_fake_ssh fake-host 22 deploy
run_ps collect -H 203.0.113.20 --skip-tcping >/dev/null
run_ps collect -H 203.0.113.21 --skip-tcping >/dev/null
out="$(run_ps compare -H 203.0.113.20,203.0.113.21)"
assert_contains "档案对比" "$out" "compare should print a table"
assert_contains "Test CPU" "$out" "compare should include CPU values"

# 8. Saved credential is actually reused when explicitly requested.
CURRENT_TEST="saved credential"
printf 'saved-secret\n' > "$SSHMGR_HOME/credentials"
setup_fake_ssh fake-host 22 deploy
out="$(run_ps collect -H 203.0.113.30 --auth password --use-saved-credential --skip-tcping)"
assert_contains "档案已写入" "$out" "saved credential collect should succeed: $out"
assert_eq "0" "$(find "$TMPDIR" -maxdepth 1 -name 'sshmgr-*' 2>/dev/null | wc -l | tr -d ' ')" "no askpass temp files should remain"

# 9. A changed host-key fingerprint is an identity change even with the same machine_id.
CURRENT_TEST="fingerprint identity"
K1="$SANDBOX/hk1"; K2="$SANDBOX/hk2"
ssh-keygen -q -t ed25519 -N '' -f "$K1" >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f "$K2" >/dev/null 2>&1
PUB1="$(cut -d' ' -f1-2 "$K1.pub")"; PUB2="$(cut -d' ' -f1-2 "$K2.pub")"
KH="$SANDBOX/known_hosts"
printf '[fake-host]:2222 %s\n' "$PUB1" > "$KH"
setup_fake_ssh fake-host 2222 deploy "$KH"
run_ps collect -H fp.example -p 2222 --skip-tcping >/dev/null
FP1="$(ssh-keygen -lf "$K1.pub" | awk '{print $2}')"
grep -q "^host_key_fp=$FP1$" "$SSHMGR_HOME/profiles/fp.example_2222.profile"
assert_rc 0 $? "fingerprint should be recorded"
printf '[fake-host]:2222 %s\n' "$PUB2" > "$KH"
out="$(run_ps collect -H fp.example -p 2222 --skip-tcping)"
assert_contains "主机密钥指纹变了" "$out" "changed fingerprint should be refused"
assert_eq "1" "$([ -f "$SSHMGR_HOME/profiles/fp.example_2222.m2.profile" ] && echo 1 || echo 0)" "m2 profile for fingerprint change"
export FAKE_SSH_G_KH="$HOME/.ssh/nonexistent"

# 10. Identity conflict is refused and saved as .m2.profile.
CURRENT_TEST="identity conflict"
cat > "$FIXTURE" <<'EOF'
profile_schema=1
hostname=other.example
machine_id=DIFFERENT
boot_id=boot-2
ip_primary=203.0.113.99
ip_all=203.0.113.99
cpu_model=Other CPU
mem_total_mb=4096
profile_complete=1
EOF
setup_fake_ssh fake-host 22 deploy
out="$(run_ps collect -H 203.0.113.20 --skip-tcping)"
assert_contains "另存为" "$out" "machine_id conflict should be reported"
assert_eq "1" "$([ -f "$SSHMGR_HOME/profiles/203.0.113.20.m2.profile" ] && echo 1 || echo 0)" "m2 profile expected"

# 10. Profile permissions (skip on mounts that do not implement POSIX modes).
CURRENT_TEST="permissions"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) : ;;
  *)
    if stat -c '%a' "$SSHMGR_HOME/profiles" >/dev/null 2>&1; then
      _mode() { stat -c '%a' "$1"; }
    else
      _mode() { stat -f '%Lp' "$1"; }
    fi
    assert_eq "600" "$(_mode "$SSHMGR_HOME/profiles/web1.example_2222.profile")" "profile mode"
    assert_eq "700" "$(_mode "$SSHMGR_HOME/profiles")" "profile dir mode"
    ;;
esac

summary "test_profile_store"
