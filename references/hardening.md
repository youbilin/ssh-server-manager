# Server Security Hardening Checklist

## The First Rule of Hardening: Don't Lock Yourself Out

Hardening is a set of operations that **raises security and the risk of locking yourself out at the same time**. Doing it all in one go is the most common way beginners crash and burn:
after you've changed `PermitRootLogin no` + turned off password login + set the firewall default policy to DROP,
you discover that your only entry point is gone and you have to go open a console.

So:

1. **Proceed from low risk to high risk**, verifying each step separately — don't merge them into one "big overhaul"
2. **Before every SSH or firewall change**: back up → syntax check → attach an auto-rollback timer → keep the current session → verify in a new session
3. **Confirm the second entry point works first** (cloud console VNC, out-of-band management, a spare account), then touch the entry configuration
4. Before doing it in production, walk the whole thing through once in a staging environment

Each section below is marked with a risk level; proceed in the order 🔵 low risk → 🟡 medium risk → 🔴 high risk.

---

## Table of Contents

- [1. SSH Hardening](#1-ssh-hardening)
- [2. Accounts and sudo](#2-accounts-and-sudo)
- [3. Firewall](#3-firewall)
- [4. Intrusion Prevention (fail2ban)](#4-intrusion-prevention-fail2ban)
- [5. Updates and Patching](#5-updates-and-patching)
- [6. Kernel Parameters and Resource Limits](#6-kernel-parameters-and-resource-limits)
- [7. Logging and Auditing](#7-logging-and-auditing)
- [8. Service and Port Minimization](#8-service-and-port-minimization)
- [9. Files and Permissions](#9-files-and-permissions)
- [10. Post-Hardening Verification](#10-post-hardening-verification)
- [11. Checklist](#11-checklist)

---

## 1. SSH Hardening

First see clearly what configuration is currently in effect, then decide what to change. Use `sshd -T` to read the **actually effective** values (it has already folded in `Include` and the defaults), which is more reliable than grepping the config files:

```bash
sudo sshd -T | grep -iE '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|x11forwarding|maxauthtries|logingracetime|allowusers|allowgroups|clientaliveinterval)'
```

### 🔵 Low Risk (Can Be Done Directly)

```bash
# Write it in /etc/ssh/sshd_config.d/99-hardening.conf (don't edit the main file directly -- easier to roll back)
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sudo sshd -t && sudo systemctl reload sshd
```

These only affect new connections and don't change how you're currently logged in, so the risk is low.

### 🟡 Medium Risk: Restricting Login Sources and Accounts

```bash
# allow only specific network ranges
AllowUsers deploy@203.0.113.0/24 ops@198.51.100.0/24
# or by group
AllowGroups ssh-users

# forbid direct root login (use an ordinary account + sudo instead)
PermitRootLogin prohibit-password     # root can still log in with a key
# PermitRootLogin no                  # stricter: forbid root login entirely
```

⚠ Before changing anything, **first confirm your own account really is in the allow list** and really does have sudo privileges (`sudo -l`). Excluding yourself is the most classic way to lock yourself out.
⚠ Add only `AllowUsers` first, verify you can still log in, and only then consider `PermitRootLogin`.

### 🔴 High Risk: Turning Off Password Login

**Prerequisites (all of them are mandatory):**

1. Your key-based login is already verified working (not "it should work")
2. At least two accounts can log in with keys (if one has a problem, the other is still there)
3. You have confirmed the cloud console VNC is available
4. An auto-rollback timer is already attached

```bash
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes                            # keep this yes, or sudo and friends may stop working
```

```bash
# backup + syntax check + rollback insurance
scripts/backup_config.sh -H web1 -f /etc/ssh/sshd_config --sudo
sudo sshd -t
sudo systemd-run --on-active=10min --unit=sshd-rollback \
  /bin/sh -c 'cp /etc/ssh/sshd_config.bak.<timestamp> /etc/ssh/sshd_config && systemctl reload sshd'

sudo systemctl reload sshd            # reload does not drop existing connections
# -- open a new terminal and verify you can log in --
sudo systemctl stop sshd-rollback.timer   # cancel the rollback once verified
```

⚠ Before turning off password login, confirm that every automation task that depends on password login (CI, monitoring, backup scripts) has already been switched to keys. Otherwise you'll think you've been locked out when it's actually some task raising an alert.
⚠ `systemctl reload sshd` doesn't work on some distributions (the sshd unit on older systemd doesn't support reload); in that case use `systemctl restart sshd` — but **only while keeping your current session open**, because restart cuts off every existing connection.

### Other SSH Items

```bash
# Changing the port has limited benefit (scanners sweep whole ranges), but if you do it,
# always "add first, remove later":
# 1) Add Port 2222 while keeping Port 22
# 2) Allow 2222 in the firewall and verify you can log in
# 3) Then remove Port 22 and drop 22 from the firewall
```

- Host key types: confirm `HostKey` includes ed25519 and disable the outdated `ssh-dss`
- `~/.ssh` permissions (700 / 600) and the home directory must not be group-writable — when these aren't satisfied, key login fails silently
- Use `Match` blocks to apply differentiated policy per source (e.g. relaxed on the internal network, strict from the public internet)

---

## 2. Accounts and sudo

### 🔵 Low Risk: Inventory

```bash
# who can log in
awk -F: '$7 !~ /(nologin|false)$/ {print $1, $3, $7}' /etc/passwd
# UID 0 accounts (there should only be root)
awk -F: '$3 == 0 {print}' /etc/passwd
# who has sudo
getent group sudo wheel
sudo -l -U <user>                     # actual privileges, per user
# accounts with an empty password
sudo awk -F: '$2 == "" {print $1}' /etc/shadow
# long-dormant accounts
lastlog | grep -v 'Never' | head -20
```

### 🟡 Medium Risk: Convergence

```bash
# lock system accounts that shouldn't be able to log in
sudo usermod -L -s /usr/sbin/nologin <svc-account>

# delete or lock departed/dormant accounts
sudo usermod -L <user>                # lock first, watch for a while, then delete
# sudo userdel -r <user>              # delete only after confirming nothing still depends on it

# password policy
sudo chage -M 90 -W 7 <user>
sudo chage -l <user>
```

### 🔴 High Risk: sudo Rules

```bash
# Use visudo (it syntax-checks); one wrong character in /etc/sudoers can cost you sudo permanently
sudo visudo -f /etc/sudoers.d/<user>
# Example content: authorize specific commands rather than ALL
# deploy ALL=(root) NOPASSWD: /bin/systemctl restart nginx, /bin/systemctl status nginx
sudo visudo -c                        # validate every sudoers file's syntax
```

⚠ **Prefer `NOPASSWD` scoped precisely to specific commands** rather than `ALL=(ALL) NOPASSWD: ALL`. The latter is equivalent to handing out passwordless root.
⚠ Immediately after changing it, verify `sudo -l` and an actual command execution in **another session**. Keep the current session until you've confirmed.
⚠ Don't give business accounts sudo. If the business needs to restart a service, write one precise rule for it.

---

## 3. Firewall

### The Iron Rule of Ordering

**Add the allow rule first → verify with a new connection → then delete the old rule.** Never "turn it off first and allow it afterwards" in your only session.

### 🔵 Low Risk: Taking Stock of the Current State

```bash
sudo ufw status verbose                  # Ubuntu/Debian
sudo firewall-cmd --list-all             # RHEL family
sudo iptables -S                         # the truth in the kernel (-S is more rollback-friendly than -L)
sudo nft list ruleset
ss -lntp                                 # what is actually listening -- allow only these
```

⚠ Three layers of firewall may exist at the same time: the **cloud security group** (in the console), `firewalld`/`ufw` (management layer), and `iptables`/`nftables` (kernel layer). Take the actual contents of `iptables -S` / `nft list ruleset` as authoritative.

### 🟡 Medium Risk: Minimal Allow Rules

```bash
# Back up the rules first, so you can restore them in one step if something goes wrong
sudo iptables-save > /root/iptables.$(date -u +%Y%m%dT%H%M%SZ).rules

# ufw: deny inbound by default, allow only the necessary ports
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80,443/tcp
sudo ufw --dry-run enable                # see what it would execute first
sudo ufw enable

# firewalld
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

⚠ **Before** enabling the default-deny policy, you must first allow the SSH port you're currently using. Get the order wrong and you're disconnected immediately.
⚠ Docker writes its own iptables rules and bypasses `ufw` (the `DOCKER-USER` chain), so published ports may be open to the public internet while ufw shows "blocked". To restrict container ports you have to do it in the `DOCKER-USER` chain or by binding to `127.0.0.1`.

### 🔴 High Risk

- Changing the default policy (`iptables -P`)
- Deleting existing allow rules
- `iptables -F` (flushing the rules; it does **not** change the default policy, so if the default is DROP you're disconnected immediately)
- `ufw disable` / `ufw reset`

All of these must be paired with an auto-rollback timer and a second entry point.

---

## 4. Intrusion Prevention (fail2ban)

### 🔵 Low Risk: Install and Observe

```bash
sudo apt-get install -y fail2ban        # or dnf install -y fail2ban
# Use jail.local, don't edit jail.conf (an upgrade would overwrite it)
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = 127.0.0.1/8 ::1 203.0.113.0/24    # add your office network and jump host

[sshd]
enabled = true
port    = ssh
EOF
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

⚠ **You absolutely must put the jump host and the office network into `ignoreip`**, otherwise one mistake shuts the whole team out.
⚠ First observe for a few days with a short `bantime` to confirm no legitimate business traffic is being falsely banned, then relax it.

### Day-to-Day

```bash
sudo fail2ban-client status sshd              # current bans
sudo fail2ban-client set sshd unbanip <ip>    # unban
sudo tail -f /var/log/fail2ban.log
```

How to unban yourself: if the banned IP is yours, log in from another IP (phone hotspot, jump host) and unban it.

---

## 5. Updates and Patching

### 🔵 Low Risk: Inventory

```bash
apt list --upgradable                          # Debian family
dnf check-update                                # RHEL family
apt-get -s upgrade | grep -c '^Inst'           # simulate; see how many packages would move
```

### 🟡 Medium Risk: Routine Upgrades

```bash
# Debian family: non-interactively you must handle conffiles explicitly, or it stalls on a
# prompt until it times out
sudo apt-get -y -o Dpkg::Options::=--force-confold upgrade
sudo apt-get -y --purge autoremove

# RHEL family
sudo dnf -y --best upgrade
sudo dnf -y autoremove
```

### Automating Security Updates

```bash
# Debian family
sudo dpkg-reconfigure -plow unattended-upgrades
sudo systemctl status unattended-upgrades

# RHEL family
sudo dnf install -y dnf-automatic
sudo systemctl enable --now dnf-automatic.timer
```

⚠ Automatic security updates only cover security patches, but **kernel updates require a reboot to take effect**. Either schedule reboot windows, or use a scheme like `livepatch`/`kpatch`, and monitor the "reboot required" state (`/var/run/reboot-required`, `needs-restarting -r`).

### Patch Rollout Discipline

- **In batches**: staging first → one production host → one batch of the same role → everything. Rolling it all out at once is the same as losing every node at the same time
- Take a snapshot before updating (cloud disk snapshot or application-level backup)
- Pin critical package versions so they aren't accidentally overwritten by an upgrade (`apt-mark hold` / `dnf versionlock`)
- After a kernel update, confirm the boot entries are intact and don't delete all the old kernels

---

## 6. Kernel Parameters and Resource Limits

### Resource Limits (a Common Bottleneck Affecting Stability)

```bash
# System-wide
sudo tee /etc/security/limits.d/99-app.conf >/dev/null <<'EOF'
*    soft nofile 65535
*    hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

# systemd service level (overrides limits.conf)
sudo systemctl edit <svc>
# [Service]
# LimitNOFILE=65535
```

⚠ `limits.conf` does **not** apply to systemd services (systemd doesn't read it). For services you must use `LimitNOFILE`.
⚠ After the change you must log in again (or restart the service) for it to take effect.

### Kernel Parameters

```bash
# Show current values
sysctl net.ipv4.tcp_max_syn_backlog net.core.somaxconn net.ipv4.ip_local_port_range

# Persist them under /etc/sysctl.d/
sudo tee /etc/sysctl.d/99-tuning.conf >/dev/null <<'EOF'
# High-concurrency connection scenarios
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_tw_reuse = 1
# Security-related
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv6.conf.all.accept_ra = 0
kernel.randomize_va_space = 2
EOF
sudo sysctl --system
```

⚠ Don't blindly copy "optimized parameter packs" from the internet. `tcp_tw_recycle` causes connection failures in NAT environments and has been removed from newer kernels; `ip_forward=1` turns the machine into a router. **For every item you change, you must know what problem it solves**.
⚠ `sysctl -w` only affects the current running state and is lost on reboot; persistence requires writing to a file. Apply with `sysctl --system` and check for errors.

---

## 7. Logging and Auditing

### 🔵 Low Risk

```bash
# Persist the journal (by default it may be memory-only and lost on reboot)
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
journalctl --disk-usage

# Cap the size so logs don't fill the disk
sudo sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=2G/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald

# Log rotation
cat /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.d/nginx     # -d is a dry run, no changes
sudo logrotate -f /etc/logrotate.d/nginx
```

### Logs Worth Watching

| File | What to Watch For |
|---|---|
| `/var/log/auth.log` / `/var/log/secure` | Failed logins, sudo privilege escalation, new user creation |
| `/var/log/nginx/access.log` | Anomalous UAs, scanning paths, traffic spikes |
| `journalctl -u sshd` | Source IPs of failed authentication |
| `last` / `lastb` | Successful and failed login history |

```bash
# Quickly gauge the scale of brute-force attempts
sudo grep -c 'Failed password' /var/log/auth.log 2>/dev/null || sudo journalctl -u ssh --since today | grep -c 'Failed password'
sudo awk '/Failed password/ {print $(NF-3)}' /var/log/auth.log | sort | uniq -c | sort -rn | head
```

⚠ The retention period for audit-type logs may be constrained by compliance requirements; confirm before cleaning anything up. Once deleted it cannot be recovered.
⚠ Logs themselves may contain sensitive information (tokens or passwords showing up in URLs or request bodies). When investigating, be careful not to paste such content into chats or tickets.

---

## 8. Service and Port Minimization

```bash
# What is listening
ss -lntup

# What is running
systemctl list-units --type=service --state=running
systemctl list-unit-files --state=enabled

# Turn off what you don't need
sudo systemctl disable --now <svc>
```

Commonly worth turning off: `telnet`, `rsh`, `ftp`, an old `cups`, `avahi-daemon` (on servers), and useless database/cache services.

⚠ Before disabling a service, confirm nothing depends on it: `systemctl list-dependencies <svc> --reverse`.
⚠ For those services that "you don't understand but that are always running", find out what they are before disabling them — don't turn things off just because you don't recognize them (they may be the cloud vendor's monitoring / key-injection agents).

```bash
# Services only accessed locally should bind to 127.0.0.1 rather than 0.0.0.0
# e.g. Redis / MySQL / internal APIs: listen only on the loopback or internal interface
# Changing the listen address is more robust than changing the firewall --
# if the service isn't exposed at all, a wrong rule can't hurt you
```

---

## 9. Files and Permissions

### 🔵 Low Risk: Inventory

```bash
# World-writable files and directories (a common privilege-escalation entry point)
sudo find / -xdev -type f -perm -0002 -not -path '/proc/*' 2>/dev/null | head -30
sudo find / -xdev -type d -perm -0002 -not -path '/proc/*' 2>/dev/null | head -30

# SUID/SGID executables
sudo find / -xdev -perm -4000 -type f 2>/dev/null
sudo find / -xdev -perm -2000 -type f 2>/dev/null

# authorized_keys that shouldn't be there
sudo find / -xdev -name authorized_keys 2>/dev/null

# Files with no owner (the owning account was deleted)
sudo find / -xdev -nouser -o -xdev -nogroup 2>/dev/null | head
```

### 🟡 Medium Risk: Convergence

```bash
sudo chmod 644 /etc/passwd /etc/group
sudo chmod 600 /etc/shadow /etc/gshadow /etc/ssh/ssh_host_*_key
sudo chmod 700 /root
sudo chmod 600 /etc/crontab /etc/sudoers
```

⚠ `chmod -R` / `chown -R` follow symlinks, and applied to `/etc` or `/usr` they can directly break sudo/ssh. Record the state with `getfacl -R` first, and prefer targeting specific files rather than a whole tree.
⚠ Back up before changing `/etc/passwd`, `/etc/group`, `/etc/shadow`: `scripts/backup_config.sh`.

### 🔴 High Risk: Things Not to Do

- Don't do a global `chmod 777` "to save trouble"
- Don't change a business directory's owner to `root` while letting the service run as an ordinary user
- Don't `rm` cron jobs or systemd units you don't recognize — first read what they contain with `crontab -l` / `systemctl cat`

---

## 10. Post-Hardening Verification

### Within Every Session

```bash
sudo sshd -t                                          # SSH config syntax
sudo visudo -c                                        # sudoers syntax
sudo nginx -t                                         # whichever service is actually in use
sudo firewall-cmd --list-all / sudo ufw status verbose
sudo fail2ban-client status
systemctl --failed
ss -lntup                                             # expected ports present, extra ones gone
```

### A Separate Second Session (this step is not optional)

```bash
# Verify real reachability from a different account/source, not just a local curl
ssh -o BatchMode=yes -o ConnectTimeout=8 deploy@<host> true
curl -sS -o /dev/null -w '%{http_code}\n' https://<domain>/
```

### Verify Automation Tasks

The most easily overlooked thing after hardening is **automation tasks getting locked out along with everything else**: CI, monitoring, and backup scripts often log in with their own separate keys or passwords. After hardening, run them proactively once, or at minimum confirm that their login method is still in the allow list.

---

## 11. Checklist

Execute from low risk to high risk, verifying once after each group is complete.

### 🔵 Low Risk (can be done in batches)

- [ ] Read and record the currently effective configuration with `sshd -T`
- [ ] Back up `sshd_config`, `iptables-save`, `/etc/passwd`, `/etc/group`
- [ ] Persist the journal and set a size cap
- [ ] Inventory login-capable accounts, UID 0 accounts, and sudo members
- [ ] Inventory listening ports and running services
- [ ] Inventory world-writable files, SUID, and unknown `authorized_keys`
- [ ] Confirm `~/.ssh` is 700, `authorized_keys` is 600, and the home directory is not group-writable
- [ ] Install fail2ban and **add the office network and jump host to `ignoreip`**
- [ ] Set `PermitEmptyPasswords no`, `X11Forwarding no`, `MaxAuthTries 4`

### 🟡 Medium Risk (verify item by item)

- [ ] Converge sudo privileges to specific commands and configure precise NOPASSWD rules
- [ ] Lock the shell of system accounts (`nologin`)
- [ ] Firewall default-deny inbound, allowing only required ports (**allow SSH before changing the default policy**)
- [ ] Restrict SSH sources (`AllowUsers` / `AllowGroups`)
- [ ] Services listen only on the necessary network interfaces; bind internal services to `127.0.0.1`
- [ ] Enable automatic security updates and confirm they take effect
- [ ] Converge file permissions (shadow, host key, crontab, root directory)

### 🔴 High Risk (rollback and a second entry point are mandatory)

- [ ] `PermitRootLogin no` (or `prohibit-password` first)
- [ ] `PasswordAuthentication no` (confirm every automation task has switched to keys)
- [ ] Change the firewall default policy
- [ ] Change the SSH port (add before removing)
- [ ] Change kernel parameters (one at a time, knowing what each one solves)
- [ ] Delete stale accounts and useless services

### Throughout the Whole Process

- [ ] Before hardening, confirm the cloud console VNC / out-of-band management is available
- [ ] Attach an auto-rollback timer before every high-risk change, and cancel it after verification
- [ ] Keep the current SSH session open; close it only after a new session verifies successfully
- [ ] Record hardening operations in the audit log (`~/.ssh-server-manager/audit.log`)
- [ ] After hardening, verify real reachability from an independent session and run the automation tasks once
