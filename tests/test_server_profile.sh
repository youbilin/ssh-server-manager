#!/usr/bin/env bash
# shellcheck disable=SC2034
# Linux-only smoke test for server_profile.sh with a fake OpenRC environment.

. "$(dirname "$0")/lib.sh"

SP="$ROOT_DIR/scripts/server_profile.sh"

new_sandbox
trap cleanup_sandbox EXIT

CURRENT_TEST="server_profile OpenRC"
case "$(uname -s)" in
  Linux) ;;
  *)
    echo "SKIP server_profile OpenRC: requires Linux /proc"
    summary "test_server_profile"
    exit 0
    ;;
esac

OB="$SANDBOX/openrc-bin"
mkdir -p "$OB"
cat > "$OB/systemctl" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$OB/rc-status" <<'EOF'
#!/bin/sh
case " $* " in
  *" --servicelist "*) printf 'Service\tStatus\nnginx\t[  started  ]\nsshd\t[  started  ]\nbroken\t[  crashed  ]\n' ;;
  *" --crashed "*) echo broken ;;
esac
exit 0
EOF
cat > "$OB/rc-update" <<'EOF'
#!/bin/sh
printf 'nginx | default\nsshd | default\n'
EOF
cat > "$OB/rc-service" <<'EOF'
#!/bin/sh
case " $* " in
  *" -l "*) printf 'sshd\nnginx\n' ;;
esac
exit 0
EOF
chmod +x "$OB/"/systemctl "$OB"/rc-status "$OB"/rc-update "$OB"/rc-service 2>/dev/null || true

out="$(PATH="$OB:$PATH" bash "$SP" --sections identity,services 2>&1)"
rc=$?
assert_rc 0 "$rc" "server_profile rc"
assert_contains "init_system=openrc" "$out" "init system"
assert_contains "unit_running=nginx" "$out" "running service"
assert_contains "unit_failed=broken|crashed" "$out" "crashed service"
assert_contains "openrc_enabled=nginx" "$out" "enabled service"
assert_contains "profile_complete=1" "$out" "completeness sentinel"

summary "test_server_profile"
