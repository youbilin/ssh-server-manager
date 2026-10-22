#!/usr/bin/env bash
# shellcheck disable=SC2034
# Offline tests for batch_run.sh using the fake ssh (no sockets).

. "$(dirname "$0")/lib.sh"

BR="$ROOT_DIR/scripts/batch_run.sh"

new_sandbox
trap cleanup_sandbox EXIT
unset SSHMGR_SSH
export FAKE_SSH_G_HOST="fake-host"
export FAKE_SSH_G_PORT="22"
export FAKE_SSH_G_USER="deploy"
export FAKE_SSH_LOG="$SANDBOX/ssh.log"
: > "$FAKE_SSH_LOG"

printf 'web1\nweb2\n' > "$SANDBOX/hosts.txt"

# 1. Read-only batch: target list, per-host logs, summary.
CURRENT_TEST="read-only batch"
out="$(bash "$BR" --hosts-file "$SANDBOX/hosts.txt" --cmd 'uptime' --parallel 2 2>&1)"
rc=$?
assert_rc 0 "$rc" "read-only batch rc: $out"
assert_contains "目标清单（2 台）" "$out" "target list"
assert_contains "成功 2 / 失败 0" "$out" "summary counts"
assert_contains "完整输出已保存在:" "$out" "output dir line"

# 1b. Machine-readable summary and explicit old-log pruning.
PYEXE=""
if command -v python3 >/dev/null 2>&1; then PYEXE="python3"
elif command -v python >/dev/null 2>&1; then PYEXE="python"; fi
if [ -n "$PYEXE" ]; then
  CURRENT_TEST="json summary"
  out="$(bash "$BR" --hosts-file "$SANDBOX/hosts.txt" --cmd 'uptime' --json-out "$SANDBOX/summary.json" 2>&1)"
  rc=$?
  assert_rc 0 "$rc" "json summary rc: $out"
  "$PYEXE" - "$SANDBOX/summary.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    d = json.load(fh)
assert d['counts']['total'] == 2, d
assert d['counts']['ok'] == 2, d
assert d['tier'] == 0, d
assert len(d['hosts']) == 2, d
PY
  assert_rc 0 $? "json summary shape"
fi

CURRENT_TEST="prune batches"
rm -rf "$SSHMGR_HOME"/batch-*
mkdir -p "$SSHMGR_HOME/batch-old1" "$SSHMGR_HOME/batch-old2" "$SSHMGR_HOME/batch-old3"
bash "$BR" --hosts-file "$SANDBOX/hosts.txt" --cmd 'uptime' --prune-batches 2 >/dev/null 2>&1
assert_eq "2" "$(find "$SSHMGR_HOME" -maxdepth 1 -type d -name 'batch-*' | wc -l | tr -d ' ')" "prune should keep two batch dirs"

# 2. Duplicate targets are collapsed.
CURRENT_TEST="duplicate targets"
printf 'web1\nweb1\n' > "$SANDBOX/dupes.txt"
out="$(bash "$BR" --hosts-file "$SANDBOX/dupes.txt" --cmd 'uptime' 2>&1)"
assert_contains "跳过重复目标" "$out" "duplicate warning"
assert_contains "目标清单（1 台）" "$out" "duplicate target list"

CURRENT_TEST="same host different users"
printf 'web1 22 deploy\nweb1 22 root\n' > "$SANDBOX/users.txt"
out="$(bash "$BR" --hosts-file "$SANDBOX/users.txt" --cmd 'uptime' 2>&1)"
assert_contains "目标清单（2 台）" "$out" "different users must not be deduped"

# 3. Malicious-looking labels cannot escape the output directory.
CURRENT_TEST="label path safety"
printf '../../escape\n' > "$SANDBOX/traversal.txt"
bash "$BR" --hosts-file "$SANDBOX/traversal.txt" --cmd 'uptime' >/dev/null 2>&1
assert_eq "0" "$(find "$SANDBOX" -name 'escape.log' 2>/dev/null | wc -l | tr -d ' ')" "no log outside the batch output dir"

# 4. Mutating batches require --yes even for one host.
CURRENT_TEST="mutating confirmation"
: > "$FAKE_SSH_LOG"
out="$(bash "$BR" --hosts-file "$SANDBOX/hosts.txt" --cmd 'systemctl restart nginx' 2>&1)"
rc=$?
assert_rc 3 "$rc" "mutating without --yes rc"
assert_contains "需要显式加 --yes" "$out" "confirmation message"
assert_eq "0" "$(wc -l < "$FAKE_SSH_LOG" | tr -d ' ')" "no host should be contacted before confirmation"

CURRENT_TEST="mutating with --yes"
out="$(bash "$BR" --hosts-file "$SANDBOX/hosts.txt" --cmd 'systemctl restart nginx' --yes --parallel 1 2>&1)"
rc=$?
assert_rc 0 "$rc" "mutating with --yes rc: $out"

# 5. stop-on-error with parallel 1 stops dispatching after the first failure.
CURRENT_TEST="stop-on-error"
printf 'fail-host\ngood-host\n' > "$SANDBOX/stop.txt"
out="$(bash "$BR" --hosts-file "$SANDBOX/stop.txt" --cmd 'uptime' --parallel 1 --stop-on-error 2>&1)"
rc=$?
assert_rc 1 "$rc" "stop-on-error rc"
assert_contains "SKIPPED" "$out" "later hosts skipped"
assert_contains "跳过 1" "$out" "summary counts skipped"

# 6. inventory per-host auth is honoured (requires PyYAML).
CURRENT_TEST="inventory auth"
if python -c 'import yaml' >/dev/null 2>&1; then
  cat > "$SANDBOX/inv.yaml" <<'EOF'
hosts:
  - alias: pw1
    host: pw1.example
    user: deploy
    auth: password
EOF
  printf 'saved-secret\n' > "$SSHMGR_HOME/credentials"
  : > "$FAKE_SSH_LOG"
  out="$(bash "$BR" --inventory "$SANDBOX/inv.yaml" --cmd 'uptime' --use-saved-credential 2>&1)"
  rc=$?
  assert_rc 0 "$rc" "inventory auth batch rc: $out"
  assert_contains "auth=password" "$out" "per-host auth must be shown/forwarded"
  assert_contains "PubkeyAuthentication=no" "$(cat "$FAKE_SSH_LOG")" "password path must disable pubkey attempts"
  assert_not_contains "saved-secret" "$(cat "$FAKE_SSH_LOG")" "password must not be on argv"
else
  printf 'SKIP inventory auth: PyYAML not installed\n' >&2
fi

summary "test_batch_run"
