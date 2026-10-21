---
name: ssh-server-manager
description: Use when the user wants to connect to, inspect, deploy to, or troubleshoot a remote Linux server over SSH, even when they never say SSH. Supports account+password login — no key setup needed first. Trigger on Chinese phrases such as ssh 登录, 远程服务器, 登录服务器, 用账号密码登录, 密码登录, 运维, 部署上线, 重启服务, 查日志, 服务器挂了, 网站 502, 磁盘满了, CPU 跑满, 服务器信息, 硬件信息, 服务器画像, 这台机器什么配置, 对比服务器, 第一次连这台, 批量执行, 多台机器, 上传下载文件, 跳板机, 免密登录; and English phrases such as ssh into, remote server, server ops, deploy to prod, restart nginx, tail the logs, check server health, disk space, firewall rules, batch run across hosts, password login, server inventory, hardware specs. Do not trigger for local-only shell work, container orchestration with no remote host, or code review. Covers password/key auth, cached per-host profiles (hardware, Docker services, disk baseline), connectivity debugging, health checks, process/service management, logs, file transfer, package/Docker deploys, firewall/user administration, and batch operations across hosts.
---

# SSH Server Operations

## Why This Skill Exists

Three properties of remote operations drive every rule below:

1. **Remote actions are hard to undo.** A wrong delete locally might have a snapshot behind it; `rm -rf` on a remote host usually leaves nothing. So "reconnaissance read-only first, then act" is not process ceremony — it is the only reliable way to limit damage.
2. **Breaking SSH or network config locks you out.** A bad `sshd_config`, `iptables -F`, or a default DROP policy means your only way back in is the cloud console's VNC. Keep an escape hatch before touching any of that.
3. **Batch operations multiply mistakes.** One command across 1 host is a change; across 50 it is an incident. So always be able to print the exact target list first.

## Safety Rules

### Credentials

**Passwords and keys are equal paths — use whatever the user has.** If the user gives you an
account and password, use password login. Do not first talk them into generating a key,
setting up passwordless auth, and then verifying `authorized_keys` permissions — for a one-off
login or a bit of troubleshooting, that whole sequence is wasted effort. Only bring up keys
when the user explicitly wants passwordless access.

```bash
# User gave a password: use it directly (never enters argv, history, or logs)
bash $SKILL_DIR/scripts/ssh_exec.sh -H 203.0.113.10 -u root --prompt-credential -c 'uptime'
bash $SKILL_DIR/scripts/ssh_exec.sh -H 203.0.113.10 -u root --password-env MY_PW -c 'uptime'

# User wants passwordless access: only then set up a key
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host
```

- **Passwords are not written to disk by default.** The user will say so if they want that;
  at that point add `--save-credential` to store it in `~/.ssh-server-manager/credentials`.
  Later invocations reuse it explicitly with `--use-saved-credential` — it is never read
  implicitly. Don't store it if they didn't ask.
- **`--dry-run`, `--print-tier` and `--selftest` never read credentials and never connect.**
- **Never use `sshpass -p`**: the password shows up in `ps` output. This script goes through
  ssh's own askpass; the password is handed to the helper via a private temp file that is
  deleted on exit. No sshpass needed.
- **Be honest about where it lands.** If the user pastes the password into the conversation,
  it is already in the transcript. Accept it, put it in an environment variable for that one
  invocation, and say so once — don't nag repeatedly. Note also that
  `SSHMGR_PASSWORD=xxx bash ssh_exec.sh …` leaves the password in both shell history and the
  transcript; the env form is only safer when the user already exported it in their own session.
- **`chmod 600` is often a no-op under Git-Bash.** Measured: mounts here carry `noacl`, so
  `chmod 600` and `chmod 777` both leave `stat` reporting 644. It certainly does not change
  Windows ACLs. The real boundary is the ACL on `%USERPROFILE%`, not the file mode — and any
  process running as that user can read the file. **Not persisting it by default is the actual protection.**
- A remote `PasswordAuthentication yes` is the user's existing choice. Don't file it as a
  fault in your report. Only discuss it under `references/hardening.md` when the user asks
  about hardening or compliance.

### Host Keys

- Keep verification strict (`StrictHostKeyChecking=yes`). Never auto-trust. Verify the
  fingerprint on first contact:

  ```bash
  # Print candidates without writing anything
  bash $SKILL_DIR/scripts/ssh_exec.sh -H <host> --show-host-key
  # After checking against the cloud console or an admin, hand the confirmed value to the
  # script — only then will it write the key.
  bash $SKILL_DIR/scripts/ssh_exec.sh -H <host> --accept-host-key --fingerprint SHA256:xxxx
  ```

  `--fingerprint` must be the complete `SHA256:...` value, must match a scanned key exactly, and
  only that one key line is written. Partial values and mismatches are refused.
  `--accept-host-key` works on its own (no `-c` needed). Aliases and non-22 ports are resolved
  through `ssh -G`.
- On `REMOTE HOST IDENTIFICATION HAS CHANGED`, suspect a reinstall or an IP change first; don't
  rush to delete the record. The script also refuses to overwrite an existing entry whose
  fingerprint differs, and points you at `ssh-keygen -R`.
- A jump host is a separate trust decision: it must already be in `known_hosts` before
  `--accept-host-key -J bastion` can scan the target through it.

### Command Risk Tiers

Assign a tier before running anything, and let the tier decide how you interact:

| Tier | Scope | Handling |
|---|---|---|
| **Read-only** | df, du, ps, top, cat, ls, tail, head, grep, journalctl, systemctl status, ss, netstat, ip, free, uptime, last, lsblk, docker ps | Run directly |
| **Mutating** | systemctl start/stop/restart/reload/enable, apt·yum·dnf install/remove/upgrade, editing config files, chmod/chown, mv, sed -i, docker stop/rm/compose up·down, git pull deploys, ufw allow | State the blast radius and the rollback path first, then wait for confirmation |
| **Dangerous** | rm -r, dd, mkfs, fdisk/parted, truncate, chmod -R 777, chown -R on system directories, iptables -F, ufw disable / turning off the firewall, editing sshd_config/fstab/sudoers, reboot/shutdown/halt, DROP·TRUNCATE DATABASE, kill -9 on system processes, overwriting files under /etc | Double confirmation required: show the user the exact command and ask once explicitly, and present the rollback plan up front |

Classification is a guardrail, not a sandbox: it understands command position and common write
targets, but cannot see inside `python -c`, assembled scripts, or arbitrary binaries.
Read-only commands that merely mention a dangerous word — `cat /etc/ssh/sshd_config`,
`journalctl | grep reboot`, `ps aux | grep fio` — stay at tier 0.

**Prefer the reversible form.** This is not formalism: if `reload` fails you can revert to the
old config; if `restart` fails the service is simply down.

- `systemctl reload` / `nginx -s reload` over `restart`
- Syntax-check first: `nginx -t`, `sshd -t`, `visudo -c`, `docker compose config`, `bash -n`
- `mv f f.bak` over `rm f`; when a process holds a log file open, use `truncate -s 0` (keeps the
  inode) rather than `rm`
- Run `--dry-run` / `-n` / `--test` first for anything destructive
- Before deleting data, confirm a backup exists — and that it is **not on the same machine or
  the same disk**

### Config-Change Protocol

For files where a mistake means "can't get in or won't boot" — `sshd_config`, `nginx.conf`,
firewall rules, `fstab`, `/etc/sudoers` — follow this order:

1. **Back up**: `scripts/backup_config.sh -H <host> -f <path>`, and verify the backup is
   non-empty with a matching checksum.
2. **Syntax-check**: `sshd -t` / `nginx -t` / `visudo -c` / `findmnt --verify` (fstab).
3. **Keep your current SSH session open** — it is your safety line.
4. **Before a dangerous change, arm an automatic rollback timer** and cancel it once verified.
   This is the only self-rescue when you get locked out:

   ```bash
   # Auto-restore and reload after 10 minutes; cancel it once verified
   sudo systemd-run --on-active=10min --unit=sshd-rollback \
     /bin/sh -c 'cp /etc/ssh/sshd_config.bak.20261017T101500Z /etc/ssh/sshd_config && systemctl reload sshd'
   # After confirming you can log in on a new session:
   sudo systemctl stop sshd-rollback.timer
   ```

   On older systems without systemd, use `at`: `echo '<rollback command>' | sudo at now + 10 minutes`
5. **Use `reload`, not `restart`** (reload does not drop existing connections).
6. **Open a second session** to verify the new config allows login and the service is healthy,
   then close the first.
7. Tell the user about the fallback entry point in advance (cloud console VNC / out-of-band
   management) in case the rollback also fails.

### Audit Log

Record every remote command you run to a local log, in the format
`time | host | risk tier | exit code | duration | command`. Default location is
`~/.ssh-server-manager/audit.log`, overridable with `SSHMGR_LOG`. Fields are escaped so the line
stays parseable.

`scripts/ssh_exec.sh` writes this automatically; add entries by hand when you execute some
other way. The log is append-only, not tamper-evident; ship it off-box if compliance requires
that. Set `SSHMGR_AUDIT_MAX_BYTES` to rotate to `audit.log.1`. Why it's worth keeping: the first
question in any incident review is "who changed what, when" — and often this file is all that's
left.

## Workflow: A Depth Ladder, Used On Demand

**Do not run the same fixed sequence every time.** Ask "what is the least amount of work that
answers this question?" and stop there.

```
L0  Answerable locally   → read the profile / audit log, no network
L1  Answerable in one command → connect once, run one command
L2  First contact with a host → collect a profile (profile_store collect), then L0 afterwards
L3  Current state needed → health_check.sh, scoped with --sections where possible
L4  Genuine deep dive    → state your reason; --deep/--updates are slow and never belong in first contact
```

**One hard rule: if one command answers it, don't run a second; for read-only questions, don't
run an inspection script.**

| User says | Take this path |
|---|---|
| First time on this host / what are its specs | L2 collect a profile → print the "server portrait" |
| Disk is full | L1 `df`/`du` to locate it layer by layer; do **not** run a full inspection |
| Site returns 502 | L1 quantify the logs → follow the chain down, `references/troubleshooting.md` |
| Service is down / restart it | L1 check state → mutating, needs confirmation |
| How's that host doing | L0 read the profile first; `profile_store check` only if you need current state |
| Operate on several hosts | Batch: print the target list, then `batch_run.sh` |
| Hardening / compliance | `references/hardening.md` |

Only three things hold on every task:

1. **Keep an escape hatch before touching SSH or the firewall** (backup + syntax check +
   rollback timer + fallback entry point).
2. **State the blast radius and rollback path for mutating and dangerous operations, and wait
   for confirmation.**
3. **Print the exact target list before any batch operation.**

Everything else is drawn on as the task needs it. `ssh_exec.sh` already makes risk tiering and
audit logging mechanical, so you don't need to walk a fixed process to get them.

For the connection itself:

- Run `--preflight` first to confirm you can connect; on failure work through
  `references/troubleshooting.md` rather than retrying blindly (that trips fail2ban).
- The script prints a one-line profile hint on stderr (no profile / stale), which tells you
  whether collection is needed.
- After a mutating command succeeds, the script automatically marks the affected profile
  sections stale (next section), so "keep the profile in sync after changes" doesn't depend on
  you remembering.

## Server Profiles (Look Once, Then Read the Cache)

**Hardware specs and the set of Docker services on a host you've connected to ten times do not
change.** Re-reconnoitering every time is waste, and collecting without storing is worse.
A profile turns "look carefully once, read it afterwards" into a pipeline.

```bash
# First contact: tcping + read-only collection + persist, in one command
bash $SKILL_DIR/scripts/profile_store.sh collect -H 203.0.113.10 -u root --prompt-credential --note "prod web frontend"

# Afterwards: read the local profile — no network, no re-reconnaissance
bash $SKILL_DIR/scripts/profile_store.sh find -H web1          # resolvable by alias, IP, or hostname
bash $SKILL_DIR/scripts/profile_store.sh show -H web1 --short  # the ≤20-line portrait (show this, not 200 raw lines)
bash $SKILL_DIR/scripts/profile_store.sh list                   # every profile in one table, with latency
bash $SKILL_DIR/scripts/profile_store.sh check -H web1          # one connection to test whether it rebooted
bash $SKILL_DIR/scripts/profile_store.sh compare -H web1,web2   # local hardware/service comparison
```

`collect` and `check` accept the same password options as `ssh_exec.sh` (`--auth`,
`--prompt-credential`, `--password-env`, `--credential-file`, `--use-saved-credential`,
`--save-credential`) and reuse stored user/port/jump/identity metadata.

- Profiles live in `~/.ssh-server-manager/profiles/<target>.profile`, with `_<port>` for
  non-default SSH ports, alongside `audit.log`. They contain IPs, hostnames, image lists and
  other infrastructure detail — **do not commit them to a repository or paste them somewhere
  public**. The store uses `umask 077` (700/600 on POSIX filesystems).
- The machine's real IP, hostname and alias are all recorded inside, so any of the three finds
  the same profile. Lookups match complete lines (`web1` does not match `web10`); if a host has
  profiles for multiple ports, pass `-p` instead of letting the script guess.
- **IPs get recycled, and behind NAT several machines share one egress IP**, so identity is not
  IP alone. The host-key fingerprint from `known_hosts` is primary; `machine_id` corroborates.
  If either changes, the new result is saved as `.m2.profile` and the command exits 3;
  `--force` overrides after you have confirmed the change.
- **Profiles hold slow-moving facts only** (model, inventory, disk baseline). Load, free memory,
  connection counts and similar fast-moving state stay in `health_check.sh` and out of the
  profile — otherwise the profile is stale every day, which is the same as not having one.
- `set -H web1 --note "..."` updates the note; collector-maintained fields cannot be edited.

### Refresh Rules

After a change you don't need a full re-collection; invalidate only the affected sections:

| What you did | Sections invalidated |
|---|---|
| `docker compose up/down`, added or removed containers | `docker,services` |
| `systemctl restart`, service changes | `services` |
| Installed or removed packages | `services,runtimes` |
| Firewall changes | `security` |
| Mounted a disk / changed partitions | `storage` |
| User changes | `security,services` |

The script does this **automatically** after a successful mutating command. To refresh by hand:

```bash
# --sections is a partial refresh: unnamed sections are carried over untouched from the
# existing profile, and only the refreshed sections are cleared from stale_sections.
# Omitting --sections replaces the whole fact set and clears all stale markers.
bash $SKILL_DIR/scripts/profile_store.sh collect -H web1 --sections docker,services   # re-collect just these
bash $SKILL_DIR/scripts/profile_store.sh mark-stale -H web1 --sections docker --reason "swapped image"
```

If the machine rebooted (`check` tells you), `runtimes/services/storage` are invalid while
`identity/hw` remain perfectly good — there is no reason to re-read the CPU model because of a
reboot.

## First-Contact Collection: Read the Specs, Run No Benchmarks

On first contact, get the whole picture in one pass: OS/kernel/virtualization, CPU model and
core count, memory, disks and filesystems, NICs and listening ports, Docker and every
container, systemd services and timers, runtime versions, firewall and effective sshd config,
accounts with a login shell.

### ⛔ Never Run Benchmarks or Stress Tests on a Server

Prohibited: `sysbench`, `fio`, `dd` write tests, `stress-ng`, `memtester`, `iperf3`,
`openssl speed`, `bonnie++`, `unixbench`, `hdparm -t`.

Why:

- **It pollutes business metrics.** Generating CPU/disk/network pressure on a production host
  sets off monitoring alerts, and whoever is on call has no idea you caused it.
- **It can genuinely affect production.** A disk write test can fill the disk; a memory test
  can trigger the OOM killer.
- **The result is useless.** "How many points this host scores in sysbench" tells you nothing
  about an operational decision. What matters is "is capacity sufficient right now" — and that
  comes from current load and headroom, not a benchmark score.

One look at TCP handshake latency is all the connectivity measurement you need (initiated
locally, zero traffic generated remotely):

```bash
bash $SKILL_DIR/scripts/tcping.sh -H 203.0.113.10 -p 22 -n 4
```

Benchmark commands are classified as dangerous and **refused by default**, so this rule is a
mechanism rather than a good intention.

## 1. Connection Management

**Resolution order**: inventory alias → `~/.ssh/config` Host alias → `user@host[:port]`.

- Pick the auth method based on what the user has (**a password is enough — no need to
  generate a key first**). Custom port via `-p`, jump host via `-J` (ProxyJump). Pin it in
  `~/.ssh/config` rather than assembling a long command each time:

  ```sshconfig
  Host web1
      HostName 203.0.113.10
      User deploy
      Port 2222
      IdentityFile ~/.ssh/id_ed25519
      ProxyJump bastion
  Host bastion
      HostName 198.51.100.5
      User ops
  ```

- **Preflight must be able to fail fast and must not stall on an input prompt.** On the key
  path use `ssh -o BatchMode=yes -o ConnectTimeout=8 host true` — `BatchMode=yes` makes an auth
  failure error out immediately instead of hanging for input. **The password path is the
  opposite**: `BatchMode` must be relaxed or ssh will never ask for the password. In that case
  `ssh_exec.sh` generates an askpass helper to hand the password over (and disables pubkey
  attempts, so a pile of keys in ssh-agent doesn't get tried one by one, burning through
  MaxAuthTries before the password is ever offered). The two paths' options are set as a pair —
  do not hand-edit only one, or it degrades into a blocking read on `/dev/tty` that looks like
  a hang.
- **Host fingerprints**: keep verification strict; do not reach for
  `StrictHostKeyChecking=no`. See "Host Keys" above for the verification flow.
- **Connection multiplexing is on by default** (`ControlMaster` + `ControlPath=$LOG_DIR/cm/%C`
  + `ControlPersist=10m`). This matters especially for password login: without multiplexing,
  every invocation does preflight + execute = **two authentications**, meaning the password is
  submitted twice and the opportunity for a `Failed password` entry doubles. Set
  `SSHMGR_NO_MUX=1` to turn it off.
- Through a jump host (`-J`), a local tcping does not measure latency to the target; the script
  records it as `skip=jump`.
- For connection-failure diagnosis order and commands see section 1 of
  `references/troubleshooting.md`; the decision tree for authentication errors is in
  `ssh_exec.sh --help` and `diagnose()` inside the script.

## 2. Health Inspection (Current State, Not "What Is This Machine")

Division of labor: **what this machine is** (model, inventory) comes from the profile and is
not re-collected; **how it is doing now** (load, headroom, failed units) is what inspection is
for. On a host you have already profiled, scope inspection with `--sections` to just what you
need.

```bash
# Full inspection
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -f $SKILL_DIR/scripts/health_check.sh -t 180

# Only the sections you care about (the script's own options pass through with -A)
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -f $SKILL_DIR/scripts/health_check.sh -A "--sections cpu,memory,disk" -t 120

# Enable slow items: --deep scans large directories, --updates counts pending updates
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -f $SKILL_DIR/scripts/health_check.sh -A "--deep --updates" -t 300
```

Coverage: OS and kernel version, uptime, CPU and load (normalized by core count), memory and
swap, disk and inode usage (with threshold verdicts), listening ports and connection states,
failed systemd units, SELinux/AppArmor, firewall state, effective SSH config, recent logins,
Docker container health (only Exited/Restarting/unhealthy are flagged; a running container
without a healthcheck is normal). It ends with `SSHMGR_VERDICT=OK|WARN|CRIT`, which batch runs
can grep directly. Pass thresholds through the wrapper:

```bash
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -f $SKILL_DIR/scripts/health_check.sh \
  -A "--disk-warn 75 --disk-crit 85 --load-warn 1.5" -t 180
```

The equivalent `SSHMGR_DISK_WARN` etc. environment variables work when the script runs directly
on the host; local environment variables are not forwarded by ssh.

**Reading the numbers** (this trips people up more than the commands do):

- Load is only meaningful **divided by core count**: `nproc` 8 with load 6 is healthy; `nproc`
  1 with load 6 is overloaded.
- Look at `available`, not `free`; Linux uses spare memory as cache, so a low `free` is normal.
- **Inode exhaustion and disk exhaustion both report "No space left on device"**, but only one
  of them shows up in `df -h`. Check both.
- When disk alerting fires, first distinguish "growing fast" from "always been this size", then
  find out who is consuming it.

## 3. Process and Service Management

```bash
systemctl status nginx --no-pager -l   # -l shows full lines; otherwise key info is truncated
systemctl is-active nginx; systemctl is-enabled nginx   # running ≠ enabled; check separately
journalctl -u nginx -n 200 --no-pager
journalctl -u nginx --since '2 hours ago' -p warning
systemd-analyze blame | head -20        # where boot time goes
systemctl list-timers --all              # systemd timers
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd --sort=-%cpu | head -15
```

- When a service won't start, read `journalctl -u <svc> -n 100` first. The usual causes are a
  port already in use, a config syntax error, permissions or SELinux, or a dependency not
  running — work through section 4 of `references/troubleshooting.md` item by item.
- `ps` `%cpu` is an average over the process's lifetime. For an instantaneous hotspot use
  `top -b -n1` or `pidstat`, or you will miss processes that just started.
- Send `kill -15` (TERM, giving the process a chance to clean up) first; use `-9` only when
  that fails. `kill -9` against databases and file servers can lose data or leave lock files.
- Back up crontab before editing: `crontab -l > ~/cron.bak`. `crontab -r` wipes it with no
  prompt and is dangerous.
- When a process "mysteriously disappears", check OOM first:
  `dmesg -T | grep -i -E 'oom|killed process'`.

## 4. Log Investigation

```bash
# A time window plus keywords beats paging blindly through tail -f
journalctl --since '2026-10-17 09:00' --until '2026-10-17 10:00' -u myapp --no-pager
tail -n 500 /var/log/nginx/error.log | grep -i -E 'error|crit|upstream'
grep -c ' 502 ' /var/log/nginx/access.log              # quantify first
awk '$9==502 {print $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head
```

- Log paths vary by distribution: `/var/log/syslog` on Debian-family, `/var/log/messages` on
  RHEL-family. Both have `journalctl` — prefer it and sidestep the path differences.
- **Quantify before locating**: count occurrences, look at the time distribution, and identify
  which URLs or users are affected before deciding which slice to read. Going straight to
  `tail -f` usually makes the picture murkier, not clearer.
- Don't `cat` large logs: cap the count with `grep -m 50`, or bound the range with
  `sed -n '1000,1100p'`.
- Check usage with `journalctl --disk-usage`; to reclaim space prefer
  `journalctl --vacuum-time=7d` over deleting files under `/var/log/journal`.
- For tracing Nginx 502/504 through PHP-FPM and application errors, see the log chapter of
  `references/common-commands.md`.

## 5. File Operations

```bash
scp -P 2222 ./app.tar.gz deploy@web1:/tmp/
rsync -avz --progress --partial -e 'ssh -p 2222' ./dist/ deploy@web1:/srv/app/dist/
rsync -avz --dry-run --delete ./dist/ deploy@web1:/srv/app/dist/   # dry-run before deleting remotely
```

- Use `rsync` rather than `scp` for many small files; add `--partial` for resumability.
  `--delete` is a mutating operation — dry-run it first to see the list.
- **Back up before changing any config file**:
  `bash $SKILL_DIR/scripts/backup_config.sh -H <host> -f /etc/nginx/nginx.conf`. It collects
  by timestamp, verifies hashes, and prints a restore command with the ssh prefix attached
  (so it runs from your local machine) plus the matching syntax check.
- Record the current state before changing permissions (`ls -l`,
  `stat -c '%a %U:%G' <path>`), or you cannot restore it afterwards. `chmod -R` / `chown -R`
  on system directories is dangerous: symlinks get followed, and you can break the execute
  permissions or ownership that sudo and ssh depend on.
- Confirm a file actually updated with `stat -c '%y %s %n' /srv/app/main.py`. Checking
  timestamps after a deploy is the fastest way to spot "deployed but not in effect".

## 6. Software and Deployment

- Choose the package manager by distribution: `apt-get` on Debian-family, `dnf` on RHEL-family
  (`yum` on CentOS 7 and older). Detect with `command -v dnf || command -v yum`, or read
  `/etc/os-release`.
- Look before you leap: `apt-get install -s <pkg>` (simulate), `dnf list updates`,
  `apt list --upgradable`.
- **Patch updates are mutating or even dangerous**: `apt-get upgrade` can restart services,
  update the kernel, and overwrite config files you hand-edited. In non-interactive contexts use
  `-o Dpkg::Options::=--force-confold` to keep existing config, or you will stall on a conffile
  prompt. Snapshot beforehand, and roll out in batches rather than all at once.
- Docker: validate the compose file with `docker compose config`; after
  `docker compose up -d` you must confirm status with `docker compose ps` rather than trusting
  the command's exit code.
- When a container keeps restarting, check `docker logs --tail 100 <name>` and the exit code:
  `137` usually means OOM or SIGKILL, `1` usually an application startup failure, `126/127`
  usually a permissions problem or a missing command.
- Git-based deploys: first
  `git -C /srv/app fetch --all && git -C /srv/app log HEAD..origin/main --oneline` to see which
  commits you are about to pull, then `git pull --ff-only` (avoids merge commits or a hung
  conflict). Roll back with `git -C /srv/app reset --hard <last good commit>`.
- For the complete deployment chain see the deployment chapter of
  `references/common-commands.md`: back up → pull → build → reload → health check → roll back
  if it fails.

## 7. Security and Networking

- Check what firewall is actually in effect before changing anything:
  `ufw status verbose` / `firewall-cmd --list-all` / `iptables -S`. All three can coexist, so go
  by what is actually active (`iptables-save` is the truth in the kernel).
- **Firewall and SSH config changes carry the highest lockout risk.** Never, in one session,
  close port 22 and then open the new port. The correct order is **add** the new rule first,
  verify you can connect on the new port, then remove the old rule.
- Users and sudo: `id <user>`, `groups <user>`, `sudo -l -U <user>` show how far they can
  actually escalate. Change sudo rights only through `visudo -f /etc/sudoers.d/<name>` (it
  syntax-checks); editing `/etc/sudoers` directly and getting one character wrong can
  permanently cost you sudo.
- fail2ban: `fail2ban-client status sshd` shows current bans;
  `fail2ban-client set sshd unbanip <ip>` lifts one. If you ban yourself, this is how you get
  back in.
- Certificate expiry:

  ```bash
  echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null | openssl x509 -noout -dates -subject
  certbot certificates          # Let's Encrypt: shows days remaining directly
  ```

- For the hardening checklist (with risk ordering and the specific ways changing everything at
  once locks you out) see `references/hardening.md`.

## 8. Batch Operations

```bash
# Dry-run first to see the target list and the command that will run
bash $SKILL_DIR/scripts/batch_run.sh --inventory $SKILL_DIR/assets/inventory.example.yaml --tags web --cmd 'uptime' --dry-run

# Read-only command: run in parallel and summarize
bash $SKILL_DIR/scripts/batch_run.sh --inventory $SKILL_DIR/assets/inventory.example.yaml --tags web \
  --cmd 'systemctl is-active nginx' --parallel 5

# Mutating command: needs explicit confirmation; audit-logs per host
bash $SKILL_DIR/scripts/batch_run.sh --hosts-file hosts.txt --cmd 'apt-get -y upgrade' --confirm-danger --yes
```

- Every host runs through `ssh_exec.sh`, so risk tiering and audit logging apply to batch runs
  too.
- Output is grouped by host with exit codes and content, ending with a success/failure summary —
  **the failure list is the most important part of that report**. Never report only "mostly
  succeeded".
- **Validate a mutating batch on one host before opening it up to all of them.** Add
  `--stop-on-error` to surface "the very first host failed" quickly.
- Any mutating or dangerous batch requires an explicit `--yes`, so the "confirm the target list"
  step cannot be skipped; dangerous commands also need `--confirm-danger`.
- Inventory entries may set `auth: auto|key|password`; command-line `--auth` overrides it.
- Each run writes to a unique output directory with per-host logs named by index, so aliases are
  display labels rather than file paths.
- `--parallel 1 --stop-on-error` is the steadier combination for a first mutating run: one host
  at a time, stopping immediately on a problem. With higher concurrency, up to N already-started
  hosts will finish after a failure is detected.
- A per-host timeout is recorded as a failure rather than "unknown" — review those hosts in the
  report; don't count them as successes.

## Codex Sandbox and Approval Notes

Three Codex behaviours matter for this skill:

- **Approval prompts are not a substitute for this skill's own confirmation steps.** Codex may ask
  before running a shell command; that prompt is about *running a command*, not about *whether the
  remote host should change*. Still show the exact remote command, its blast radius, and its
  rollback path, and still wait for the user's answer. `--confirm-danger` means *the user confirmed
  the remote change*, so do not pass it just because Codex approved the shell call.
- **Network access may be restricted by the Codex sandbox.** If outbound SSH is blocked, the
  symptom is a connection error from `ssh`, not from the script. Ask the user to re-run the skill
  with network access enabled rather than retrying or working around the sandbox.
- **Read-only inspection and write actions are separated on purpose.** Keep read-only work read-only;
  when the sandbox blocked a write, report it — do not try another path to achieve the same write.

## Running the Bundled Scripts (read this first)

Every path in this document is relative to the directory that contains this `SKILL.md`. Codex does
not expand a skill-directory placeholder, so set the path explicitly before running anything:

**Do not guess this path.** Codex resolves the skill from one of several roots, and the folder it
actually loaded from is the correct one:

- personal: `~/.agents/skills/ssh-server-manager`
- project:  `<repo>/.agents/skills/ssh-server-manager`
- this skill's own source repo: the `codex/` folder

Check in this order and stop at the first that exists:

```bash
for d in "$HOME/.agents/skills/ssh-server-manager" ".agents/skills/ssh-server-manager" codex; do
  [ -f "$d/SKILL.md" ] && SKILL_DIR="$(cd "$d" && pwd)" && break
done
[ -n "${SKILL_DIR:-}" ] && ls "$SKILL_DIR/scripts" || echo "skill dir not found — stop and ask"
```

If the loop finds nothing, stop and tell the user; do not fall back to a hard-coded `$HOME` path.

Run all scripts with `bash` explicitly — do not rely on the executable bit surviving a copy:

```bash
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H web1 -c 'df -h'
```

### Running on Windows (PowerShell)

The scripts are bash, and the password path executes a POSIX askpass helper that the Windows-native
`ssh.exe` cannot run, so everything must go through Git-Bash's bash. Two traps are **measured**, not
theoretical — both were reproduced on Windows 11 with PowerShell 5.1:

**Trap 1 — `$SKILL_DIR` is a PowerShell variable, not a bash one.**

```powershell
# WRONG: PowerShell expands $SKILL_DIR (empty) and bash sees /scripts/ssh_exec.sh -> exit 127
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H web1 -c 'df -h'
```

Assign it in PowerShell. `~` is not expanded by every Windows API, so resolve a real absolute path:

```powershell
$SKILL_DIR = (Resolve-Path "$HOME/.agents/skills/ssh-server-manager").Path
bash "$SKILL_DIR/scripts/ssh_exec.sh" --selftest
```

In Git-Bash itself, the bash form is correct and simpler: `SKILL_DIR=~/.agents/skills/ssh-server-manager`.

**Trap 2 — never wrap the call in `bash -lc '...'` with double-quoted arguments.** PowerShell strips
embedded double quotes when it hands arguments to a native executable, so the remote command is
split and only its first word reaches the script:

```powershell
# WRONG: bash receives `-c systemctl restart nginx`; the script sees -c "systemctl".
# Risk tiering silently degrades: `systemctl restart nginx` is reported as tier0/read-only
# instead of tier1/mutating, and the mutation guard never fires.
bash -lc 'SKILL_DIR=...; bash "$SKILL_DIR/scripts/ssh_exec.sh" -H web1 -c "systemctl restart nginx"'
```

Pass the remote command as a **single-quoted** argument, escaping any single quote inside it by
doubling it (`''`). Single-quoted PowerShell strings also stop `$9`, `$7`, and `>` from being
mangled, which matters for `awk` pipelines:

```powershell
# Single quotes: correct, and the tier is classified from the full command
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H web1 -c 'awk ''$9==502 {print $7}'' /var/log/nginx/access.log | sort | uniq -c'
```

If the command does get split, `ssh_exec.sh` now **refuses** rather than silently running a
truncated version: `命令已被 -c/-f 指定，却又收到多余的位置参数` (`a command was already given via
-c/-f, yet extra positional arguments arrived`) and exits 1. Seeing that message means the outer
shell ate your quotes — fix the quoting and re-run; do not "simplify" by dropping the quotes.

For anything longer than a one-liner, or whenever quoting gets awkward, write the remote command to
a file and pass it with `-f` — this sidesteps argument quoting entirely.

**Use a relative path or a full Windows path, never `/tmp`.** PowerShell resolves `/tmp` against the
current drive (`D:\tmp`) while Git-Bash maps `/tmp` to `C:\WINDOWS\TEMP`; a file written by one is
invisible to the other, and you get `脚本文件不存在` (`script file not found`).

```powershell
$env:SSHMGR_HOME = (Join-Path (Get-Location) ".tmp-home")
'df -hPT -x tmpfs; df -iP' | Out-File -Encoding ascii -NoNewline .\cmd.tmp.sh
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H web1 -f ./cmd.tmp.sh
Remove-Item .\cmd.tmp.sh
```

A script passed with `-f` is classified as **tier 1** (mutating), because its contents cannot be
statically analysed — even when it only reads. That is intended: put read-only collectors in this
skill's `scripts/` directory (they carry a `# sshmgr:read-only` marker) rather than in a temp file.

**Always confirm the classification before trusting it.** `--dry-run` prints the reconstructed
command and the tier — if the printed command is shorter than what you sent, the shell mangled it:

```bash
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H web1 --dry-run -c '<the real command>'
```

**Do not pipe a script's output into a PowerShell cmdlet that stops early.** `bash ... | Select-Object
-First 3` closes the pipe while bash is still writing, and Git-Bash reports
`couldn't create signal pipe, Win32 error 5` — noise that looks like a script failure but is not.
Redirect to a file and read it back instead, which also keeps the output's UTF-8 intact:

```powershell
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H web1 --selftest > .\out.tmp.txt 2>&1
Get-Content -Encoding UTF8 .\out.tmp.txt
Remove-Item .\out.tmp.txt
```

**Reading this skill's files on Windows.** PowerShell's console encoding here is GBK, so a plain
`cat SKILL.md` or `Get-Content SKILL.md` renders this document's Chinese as mojibake. Read UTF-8
explicitly:

```powershell
Get-Content -Encoding UTF8 "$SKILL_DIR/SKILL.md"      # note the hyphen: -Encoding, not --encoding
```

If `--selftest` reports the Windows-native ssh (under `System32`), point `SSHMGR_SSH` at the
Git-Bash ssh (`/usr/bin/ssh`) before using password login.

Reference documents live under `$SKILL_DIR/references/`; read them on demand, not up front.

## Scripts

| Script | Purpose | Typical call |
|---|---|---|
| `$SKILL_DIR/scripts/ssh_exec.sh` | Remote execution wrapper: preflight, timeout, risk tiering, audit log | `bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'df -h'` |
| `$SKILL_DIR/scripts/health_check.sh` | One-shot inspection that runs on the remote host, structured output | `bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -f $SKILL_DIR/scripts/health_check.sh -t 180` |
| `$SKILL_DIR/scripts/batch_run.sh` | Run across many hosts and summarize (tag filtering, concurrency, failure summary) | `bash $SKILL_DIR/scripts/batch_run.sh --inventory inv.yaml --tags web --cmd 'uptime'` |
| `$SKILL_DIR/scripts/backup_config.sh` | Back up before a config change; prints a restore command with the ssh prefix attached | `bash $SKILL_DIR/scripts/backup_config.sh -H web1 -f /etc/nginx/nginx.conf` |
| `$SKILL_DIR/scripts/profile_store.sh` | Server profiles: collect/find/show/list/check/compare/set/mark-stale/forget (local; use collect on first contact) | `bash $SKILL_DIR/scripts/profile_store.sh collect -H web1 -u root` |
| `$SKILL_DIR/scripts/server_profile.sh` | The read-only collector that runs remotely (normally invoked by profile_store) | `bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -f $SKILL_DIR/scripts/server_profile.sh -t 120` |
| `$SKILL_DIR/scripts/tcping.sh` | Local TCP handshake latency probe, zero remote load | `bash $SKILL_DIR/scripts/tcping.sh -H web1 -p 22 -n 4` |

Every script supports `--help`. When `ssh_exec.sh` runs a script with `-f`, that script's own
options pass through with `-A`. It **refuses** dangerous commands by default unless you pass
`--confirm-danger` explicitly — making "ask twice" a mechanism rather than a verbal promise.
Benchmark commands are refused the same way.

The read-only scripts bundled with this skill (`health_check.sh`, `server_profile.sh`) carry a
`# sshmgr:read-only` declaration in their header. Seeing that marker within the first 20 lines,
`ssh_exec.sh` treats them as read-only instead of misreporting "mutating operation". This
exemption applies only to scripts inside this skill's own `scripts/` directory — it cannot be
used to launder an arbitrary local script.

When you cannot connect or authentication fails, run `ssh_exec.sh --selftest` first. It does
not connect or read credentials. It prints the ssh path/version, whether that ssh supports
`SSH_ASKPASS_REQUIRE`, whether `/dev/tcp` is available, whether GNU timeout or the built-in
watchdog will be used, which helper tools are present, whether the askpass helper round-trips a
password end to end, the `ssh -G` resolution of a supplied host, and whether the machine has a
transparent proxy (which corrupts latency measurement).

## Reference Documents

Read on demand; do not read them all at once:

- `$SKILL_DIR/references/common-commands.md` — Commands by scenario (connection, inspection, logs, disk,
  networking, package management, Docker, certificates). Read when you need specific commands
  or flags.
- `$SKILL_DIR/references/troubleshooting.md` — Troubleshooting manual: can't connect, disk/inode full,
  service won't start, 502/504, high load, OOM, port in use, certificate expiry, container
  restart loops. **Read it before acting on a symptom** — it saves a lot of guessing.
- `$SKILL_DIR/references/hardening.md` — Security hardening checklist with risk ordering and lockout
  warnings. Read when the user mentions hardening, security, or compliance.
- `$SKILL_DIR/references/server-baseline.md` — Server profiles: which fields are collected, how to read
  them, refresh rules, and the banned test-script list with the reasoning. Read when using the
  profile feature.
- `$SKILL_DIR/assets/inventory.example.yaml` — Server inventory template with grouping, tags, and jump-host
  examples.

## Report Template

Summarize in this structure at the end of each operations task:

```
## Server Portrait
<Give this on first contact (≤20 lines): OS/kernel/virtualization, CPU model, memory, chassis,
primary IP, Docker container count, running systemd service count, latency, profile timestamp.
Generate with profile_store show --short; do not dump the whole profile into the conversation>

## Goal
<Hosts, environment, intended outcome>

## What Was Done
<The commands actually run, in order, each with its risk tier>

## Results
<Objective evidence: command output, service state, HTTP codes, log excerpts>

## Changes and Impact
<Which files changed (including backup paths), which services restarted, duration of interruption>

## Verification
<The basis for confirming the goal was met>

## Follow-up Recommendations
<Issues found but not addressed, hardening suggestions, metrics worth watching>
```

## Examples

### Example 1: Diagnosing a 502

```bash
# 1. Confirm connectivity and the symptom (read-only)
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 --preflight
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'systemctl is-active nginx; ss -lntp | grep -E ":80|:443"'

# 2. Get facts from the logs first: how many 502s and where. Don't guess.
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c "awk '\$9==502 {print \$7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head"
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'tail -n 200 /var/log/nginx/error.log | grep -i -E "error|crit|upstream"'

# 3. Work down the chain: nginx -> upstream service -> port -> resources
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'systemctl status php-fpm --no-pager -l'
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'journalctl -u php-fpm -n 100 --no-pager'
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'free -m; nproc; uptime'
```

Reading the output: `connect() failed (111: Connection refused)` in error.log means the upstream
is not listening (service down, or wrong port); `upstream timed out` means the upstream is up but
can't keep pace (insufficient resources or too short a timeout); PHP-FPM's `pool www seems busy`
means the process pool is saturated and you need to raise `pm.max_children` or go look for slow
queries. Once located, **hand the conclusion and the plan to the user for confirmation before
restarting the service**, and note that a restart interrupts in-flight requests.

### Example 2: Clearing a Disk Alert

```bash
# 1. See which partition, how far off, and whether it's inodes
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'df -hPT -x tmpfs -x devtmpfs; echo ---; df -iP -x tmpfs'

# 2. Locate the usage (-x stays on one filesystem, avoiding /proc and /sys)
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'du -xhd1 / 2>/dev/null | sort -rh | head -15'
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'du -xhd1 /var 2>/dev/null | sort -rh | head -15'

# 3. Look for deleted files still held open — that's the answer when df says full and du finds nothing
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'lsof -nP +L1 2>/dev/null | head -20'

# 4. Log usage and how much is reclaimable
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'journalctl --disk-usage'
```

Cleanup order (safest first): `journalctl --vacuum-time=7d` → clear apt/yum caches → remove
exited containers and dangling images (`docker system prune`, mutating, needs confirmation) →
rotate and compress active logs → only then consider touching business data files.

When step 3 hits, do not `rm`; restart the process holding the file handle first (or
`truncate -s 0 /proc/<pid>/fd/<n>`), or the space is never freed. **Confirm log retention
requirements before acting** — deleting audit logs can violate compliance.

### Example 3: Batch-Updating System Patches on 5 Hosts

```bash
# 1. Dry-run: confirm the target list and the command that will run
bash $SKILL_DIR/scripts/batch_run.sh --inventory $SKILL_DIR/assets/inventory.example.yaml --tags web \
  --cmd 'apt-get -y -o Dpkg::Options::=--force-confold upgrade' --dry-run

# 2. See how many updates each host has and whether a kernel restart is needed
bash $SKILL_DIR/scripts/batch_run.sh --hosts-file hosts.txt --cmd 'apt list --upgradable 2>/dev/null | wc -l'

# 3. Pilot on one host and verify the application by hand
bash $SKILL_DIR/scripts/ssh_exec.sh -H web1 -c 'apt-get -y -o Dpkg::Options::=--force-confold upgrade'

# 4. Once the pilot passes, roll out in batches rather than all at once
bash $SKILL_DIR/scripts/batch_run.sh --hosts-file hosts.txt --parallel 1 --stop-on-error --confirm-danger --yes \
  --cmd 'apt-get -y -o Dpkg::Options::=--force-confold upgrade'

# 5. Check which hosts need a reboot (reboot is dangerous — separate round, confirm per host)
bash $SKILL_DIR/scripts/batch_run.sh --hosts-file hosts.txt \
  --cmd 'test -f /var/run/reboot-required && echo NEEDS_REBOOT || echo OK'
```

The key to multi-host updates is **batching and reversibility**: going all at once means losing
every node simultaneously if something breaks. `-o Dpkg::Options::=--force-confold` keeps
existing config so the upgrade doesn't stall on an interactive prompt — which in a
non-interactive context fails the entire batch on timeout.
