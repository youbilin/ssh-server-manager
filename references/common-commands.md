# Common Command Quick Reference (Grouped by Scenario)

A reference for when you already know what you want to do and need the exact command and arguments. Items marked ⚠ are the easy places to trip up.

## Contents

- [1. Connection and Debugging](#1-connection-and-debugging)
- [2. System Information and Health Checks](#2-system-information-and-health-checks)
- [3. Processes and Services](#3-processes-and-services)
- [4. Logs](#4-logs)
- [5. Disk and Files](#5-disk-and-files)
- [6. Network and Ports](#6-network-and-ports)
- [7. Firewall](#7-firewall)
- [8. Package Management](#8-package-management)
- [9. Users and Permissions](#9-users-and-permissions)
- [10. Docker](#10-docker)
- [11. Git Deployment and Rollback](#11-git-deployment-and-rollback)
- [12. Certificates](#12-certificates)
- [13. Distribution Differences Quick Reference](#13-distribution-differences-quick-reference)

---

## 1. Connection and Debugging

```bash
# Basic connection (custom port, private key, jump host)
ssh -p 2222 -i ~/.ssh/id_ed25519 deploy@203.0.113.10
ssh -J ops@198.51.100.5:22 deploy@10.0.0.10        # ProxyJump

# Non-interactive preflight: fail immediately on auth failure instead of hanging at a password prompt
ssh -o BatchMode=yes -o ConnectTimeout=8 host true

# Diagnose connection problems (-vvv prints every negotiation step)
ssh -vvv -o ConnectTimeout=8 host true 2>&1 | head -60

# Connection multiplexing: much faster when reconnecting to the same host, and a big difference in batch runs
ssh -o ControlMaster=auto -o ControlPath=~/.ssh/cm-%r@%h:%p -o ControlPersist=10m host uptime
ssh -O check host      # is the multiplexed connection still alive
ssh -O exit host       # close the multiplexed connection
```

**Keys and Permissions**

```bash
ssh-keygen -t ed25519 -C "ops@laptop" -f ~/.ssh/id_ed25519   # generate a key (ed25519 recommended)
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 deploy@host    # install the public key
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519          # load it into the agent
ssh-add -l                                                   # list loaded keys
```

Permission requirements on the remote side (if they are not met the connection is refused silently, and the only error you get is "Permission denied"):

| Path | Permission |
|---|---|
| `~/.ssh` | 700 |
| `~/.ssh/authorized_keys` | 600 |
| `~/` | Must not be group/other writable |
| Private key (local) | 600 |

⚠ Use `ssh -v` to see which key the client is actually offering. `Too many authentication failures` is almost always an agent holding too many keys — it tries them one by one and gets rejected; adding `-i <private-key>` and `-o IdentitiesOnly=yes` fixes it.

**Host Fingerprints**

```bash
ssh-keyscan -t ed25519,rsa -p 2222 host 2>/dev/null | ssh-keygen -lf -
ssh-keygen -F host                    # is this host already in known_hosts
ssh-keygen -R host                    # remove the old entry (only after confirming a reinstall or IP change)
```

⚠ Don't take the easy way out with `StrictHostKeyChecking=no`: it amounts to giving up your protection against man-in-the-middle attacks. A first connection should be "verify the fingerprint, then write it down", not "skip verification".

**Transferring Files**

```bash
scp -P 2222 ./app.tar.gz deploy@host:/tmp/
scp -r -P 2222 deploy@host:/var/log/nginx/ ./nginx-logs/
rsync -avz --partial --progress -e 'ssh -p 2222' ./dist/ deploy@host:/srv/app/dist/
rsync -avz --dry-run --delete ./dist/ deploy@host:/srv/app/dist/   # see what would be deleted first
rsync -avz --exclude='.git' --exclude='node_modules' ./ deploy@host:/srv/app/
```

⚠ `scp -P` (uppercase) is the port, `ssh -p` (lowercase) is the port; but `scp -p` actually means "preserve timestamps". This upper/lowercase mix-up is very common.
⚠ `rsync --delete` removes extra files on the remote side. That is a mutating operation — run `--dry-run` first.
⚠ A trailing `/` on a path carries meaning: `./dist/` transfers the contents of the directory, `./dist` transfers the directory itself.

---

## 2. System Information and Health Checks

```bash
# Distribution and kernel
cat /etc/os-release                 # universal
cat /etc/redhat-release             # RHEL family
uname -sr; uname -m                 # kernel / architecture
hostnamectl                         # systemd system overview

# Load and CPU
uptime                              # load 1/5/15 -- remember to divide by nproc
nproc; lscpu | head -20
vmstat 1 5                          # an r column above core count means queuing; high wa means an IO bottleneck
mpstat -P ALL 1 3                   # per-core usage (tells single-core saturation from overall busyness)
pidstat -u 1 3                      # CPU by process

# Memory
free -m                             # look at the available column, not free
cat /proc/meminfo | head -5
ps -eo pid,user,%mem,rss,cmd --sort=-%mem | head -10
slabtop -o | head -15               # when kernel slab usage looks abnormal

# Disk
df -hT                              # usage + filesystem type
df -i                               # inodes -- must be checked separately
lsblk -f                            # block devices and filesystems
du -xhd1 /var | sort -rh | head -15 # -x stays on one filesystem
lsof -nP +L1                        # deleted files still held open

# Uptime and boot
uptime -p; who -b
systemd-analyze blame | head -20
last reboot | head -5

# Hardware and kernel logs
dmesg -T | tail -50
dmesg -T | grep -iE 'error|fail|oom|I/O error'
```

⚠ `du -sh /` walks `/proc` and `/sys` and crosses mount points, so it is both slow and inaccurate. Use `du -xhd1` and drill down layer by layer.
⚠ When `df` and `du` disagree (df says full, du can't find anything that adds up) it is almost always "deleted files that a process still holds open" — see section 5.

---

## 3. Processes and Services

```bash
# systemd
systemctl status nginx --no-pager -l      # -l shows full lines; otherwise key info is truncated
systemctl is-active nginx                 # is it running
systemctl is-enabled nginx                # is it enabled at boot -- a separate question from running
systemctl list-units --failed             # all failed units
systemctl list-unit-files --state=enabled | head -30
systemctl cat nginx                       # the unit file actually in effect (including drop-ins)
systemctl show nginx -p MainPID,ExecStart,Restart
systemctl list-dependencies nginx

# Starting, stopping, reloading
systemctl reload nginx        # reload config without dropping existing connections (prefer this over restart)
systemctl restart nginx       # full restart, drops connections
systemctl daemon-reload       # required after editing a unit file, or restart still uses the old config

# Scheduled tasks
systemctl list-timers --all
crontab -l                    # current user
sudo crontab -l -u www-data   # a specific user
ls -l /etc/cron.d/ /etc/cron.daily/
```

**Finding Processes**

```bash
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd --sort=-%cpu | head -15
ps -ef | grep -v grep | grep nginx
pgrep -a nginx; pgrep -f 'python.*worker'
pstree -ap | head -30
ss -lntp                                  # which process owns a port (faster than netstat)
lsof -p <pid> | head -30                  # what files a process has open
lsof -nP -iTCP -sTCP:LISTEN               # every listening process
```

⚠ The `%cpu` from `ps` is a **process-lifetime average**, not an instantaneous value. A busy process that just started may look like it is only at 5%. For an instantaneous hotspot use `top -b -n1` or `pidstat`.

**Terminating Processes**

```bash
kill -15 <pid>      # TERM: let the process clean up (try this first)
kill -9 <pid>       # KILL: the kernel reclaims it immediately; no chance to flush data or clear lock files
kill -HUP <pid>     # make a daemon re-read its config (some services)
pkill -f 'pattern'  # match on the command line
```

⚠ `kill -9` on a database, a message queue, or a file service can lose data or leave lock files behind. Send TERM first, wait a few seconds, confirm the process is still there, and only then KILL.
⚠ The pattern for `pkill -f` will match your own shell's command line, so be careful about killing the wrong thing; run `pgrep -af` first to see what it would hit.

**OOM**

```bash
dmesg -T | grep -i -E 'oom|killed process'
journalctl -k --since '7 days ago' | grep -i 'killed process'
systemd-cgtop                     # resource usage by cgroup
```

---

## 4. Logs

```bash
# journalctl (use it whenever systemd is present -- no need to remember log paths)
journalctl -u nginx -n 200 --no-pager
journalctl -u nginx --since '2 hours ago' -p warning
journalctl -u nginx --since '2026-10-17 09:00' --until '2026-10-17 10:00'
journalctl -u nginx -f                          # follow in real time
journalctl -u nginx -o json-pretty -n 5         # when you need field-level detail
journalctl -k --since today                     # kernel log
journalctl --disk-usage                         # how much space it takes
journalctl --vacuum-time=7d                     # keep 7 days (prefer this for cleanup)
journalctl --vacuum-size=500M

# Traditional log files
tail -f /var/log/nginx/access.log
tail -n 500 /var/log/nginx/error.log | grep -iE 'error|crit|upstream'
less +F /var/log/syslog                          # Ctrl+C to stop following, then you can still search

# Filter a plain-text log by time window
sed -n '/2026-10-17 09:00/,/2026-10-17 10:00/p' app.log

# Don't cat large files
grep -m 50 'ERROR' app.log            # take only the first 50 matches
sed -n '10000,10100p' app.log
tac app.log | head -100               # read backwards from the end
```

**Common Nginx Analysis**

```bash
# how many 502s and which URLs
awk '$9==502 {print $7}' access.log | sort | uniq -c | sort -rn | head
# status code distribution
awk '{print $9}' access.log | sort | uniq -c | sort -rn | head
# top source IPs by request count
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head
# slowest requests (assuming $NF is request_time)
awk '{print $NF, $7}' access.log | sort -rn | head
# 5xx trend by minute (to pinpoint when the incident started)
awk '$9 ~ /^5/ {print substr($4, 2, 17)}' access.log | uniq -c
```

**error.log Key Messages Reference**

| Error | Meaning | What to check |
|---|---|---|
| `connect() failed (111: Connection refused)` | The upstream is not listening | Is the upstream service running, is the port right |
| `upstream timed out` | The upstream is up but the response timed out | Upstream load, slow queries, proxy_read_timeout |
| `no live upstreams` | Every upstream was judged unavailable | upstream health checks, fail_timeout |
| `worker_connections are not enough` | Not enough connections | worker_connections, ulimit |
| `Too many open files` | File descriptors exhausted | `ulimit -n`, `worker_rlimit_nofile` |
| `client intended to send too large body` | Request body over the limit | `client_max_body_size` |

⚠ Log paths differ by distribution: on the Debian family it is `/var/log/syslog`, on the RHEL family `/var/log/messages`. `journalctl` works on both, so prefer it.
⚠ Emptying a log with `> app.log` throws away the evidence, and the handle held by the process is not released (the application keeps writing to the old inode). Use `truncate -s 0 app.log`, and prefer `logrotate`.

---

## 5. Disk and Files

```bash
# Locate usage (drill down layer by layer; don't scan the whole disk first thing)
du -xhd1 / | sort -rh | head -10
du -xhd1 /var | sort -rh | head -10
du -xhd1 /var/log | sort -rh | head -10
du -ah /var/log | sort -rh | head -20
find /var -xdev -type f -size +500M -exec ls -lh {} + 2>/dev/null | head

# Deleted but still held open (the culprit when df says full and du finds nothing)
lsof -nP +L1
ls -l /proc/*/fd 2>/dev/null | grep deleted | head
# How to free it: restart the process holding the file; or (carefully) truncate that fd
truncate -s 0 /proc/<pid>/fd/<n>

# inodes
df -i
find /var -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head   # which directory has the most files

# Files and permissions
stat -c '%a %U:%G %s %y %n' /etc/nginx/nginx.conf
ls -l --time-style=long-iso /srv/app/
find /srv -user root -perm -4000 -type f        # look for SUID
namei -l /srv/app/dist/index.html               # check permissions level by level -- for "permissions look right but access fails"

# Safe delete and replace
mv app.conf app.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)   # reversible, unlike rm
truncate -s 0 app.log                                  # free log space while keeping the inode
rsync -a --delete --dry-run src/ dst/                  # look before syncing
```

⚠ If `df` shows full but `du` adds up to far less, check `lsof +L1` first, then check whether you crossed a mount point (`du -x`) or something is hidden by a directory that a mount has covered over.
⚠ `chmod -R` / `chown -R` follow symbolic links, and when applied to `/etc` or `/usr` they can break the system, or sudo/ssh, outright. Before changing anything run `find -type l` to see whether links exist, and record the original permissions (`getfacl -R` is better).

---

## 6. Network and Ports

```bash
ip -brief addr                    # addresses
ip route                          # routes
ip -s link                        # NIC counters and error counts
cat /etc/resolv.conf
resolvectl status                 # systemd-resolved systems

ss -tulpn                         # listening ports + processes
ss -tan state established | wc -l # established connection count
ss -tan state time-wait | wc -l   # TIME_WAIT buildup
ss -s                             # summary
ss -tan 'sport = :80' | head      # connections on one port

# Connectivity
ping -c 4 8.8.8.8
traceroute -T -p 443 target       # -T uses TCP, which gets through firewalls that only allow 443
mtr -rwzbc 20 target              # continuous observation of where packets are lost
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' http://127.0.0.1/
curl -sS -I https://example.com
nc -zv host 443                   # can the port be connected to
dig +short example.com; dig @1.1.1.1 example.com
```

⚠ When troubleshooting "the service is fine but it can't be reached from outside", work through the order upstream/security group → local firewall → service listen address (`0.0.0.0` or `127.0.0.1`) → application layer. Don't skip steps.
⚠ `netstat` has been superseded by `ss` on modern systems; `netstat -p` needs root to show process names.

---

## 7. Firewall

```bash
# ufw (Ubuntu/Debian)
ufw status verbose
ufw allow 443/tcp
ufw allow from 203.0.113.0/24 to any port 22 proto tcp   # add first, verify, then remove the old one
ufw delete allow 443/tcp
ufw --dry-run allow 443/tcp                              # see what it would add

# firewalld (RHEL family)
firewall-cmd --state
firewall-cmd --list-all
firewall-cmd --permanent --add-port=443/tcp && firewall-cmd --reload
firewall-cmd --permanent --remove-port=8080/tcp && firewall-cmd --reload
firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=203.0.113.0/24 port port=22 protocol=tcp accept'

# iptables / nftables
iptables -S                       # rule list (-S is more readable and more rollback-friendly than -L)
iptables -L -n -v --line-numbers
iptables-save > /root/iptables.$(date -u +%Y%m%dT%H%M%SZ).rules   # save before changing
nft list ruleset
```

⚠ **The firewall is where you are most likely to lock yourself out.** Iron rule: add the allow rule first → verify it with a new connection → then remove the old rule. Never close port 22 first and open a new port afterwards while you are on your only SSH session.
⚠ `iptables -F` flushes the rules but **does not change the default policy**; if the default policy is DROP, flushing leaves you cut off. Always use `iptables -S` rather than `-L`, because the output of `-S` can be fed straight back into `iptables-restore` to roll back.
⚠ When `ufw` and `iptables` both exist, ufw's rules land on iptables; go by what `iptables-save` actually shows.
⚠ Cloud hosts have one more layer: the **security group** (in the cloud console, not on the machine). If you allowed it on the machine but not in the security group, it still won't get through.

---

## 8. Package Management

```bash
# Debian family
apt-get update
apt-get install -s nginx              # -s is a simulation; see what it would touch first
apt-get install -y nginx
apt-get -y upgrade                    # upgrade installed packages (removes nothing, adds nothing)
apt-get -y -o Dpkg::Options::=--force-confold upgrade    # keep locally modified config (mandatory non-interactively)
apt-get -y dist-upgrade
apt list --upgradable                 # what can be upgraded
apt-mark hold nginx                   # pin the version so an upgrade can't overwrite it
dpkg -l | grep nginx                  # installed packages
dpkg -S /etc/nginx/nginx.conf         # which package owns this file
apt-get -y --purge autoremove

# RHEL family
dnf check-update
dnf install -y nginx
dnf -y --best upgrade
dnf list installed | grep nginx
rpm -qf /etc/nginx/nginx.conf         # which package owns this file
rpm -Va | head                        # verify package integrity (detect hand edits)
dnf versionlock add nginx             # pin the version

# Cache cleanup (common during disk alerts)
apt-get clean; apt-get autoclean
dnf clean all
```

⚠ A non-interactive upgrade that hits a conffile conflict will **hang waiting for input**, and the whole batch job times out. Use `-o Dpkg::Options::=--force-confold` (keep the existing config) or `--force-confnew` (accept the new config); you must pick one explicitly.
⚠ `apt-get upgrade` may restart services and update the kernel. A kernel update only takes effect after a reboot, and a reboot is a high-risk operation.
⚠ To decide which package manager to use: `command -v dnf || command -v yum`, or read `ID` from `/etc/os-release`.

---

## 9. Users and Permissions

```bash
# Inspection
id user; groups user
getent passwd user; getent group sudo
sudo -l -U user                       # what this user can actually escalate to
who; w; last -n 10
cat /etc/passwd | awk -F: '$7 !~ /(nologin|false)$/ {print $1}'   # accounts that can log in

# Create, modify, delete
useradd -m -s /bin/bash -G sudo deploy
usermod -aG docker deploy             # -a is mandatory! without it the supplementary groups are replaced
usermod -aG sudo deploy
userdel -r olduser                    # -r also deletes the home directory (confirm before using)
passwd deploy
chage -l deploy                       # password expiry policy

# sudo rights: use visudo only, it syntax-checks
visudo -f /etc/sudoers.d/deploy
# deploy ALL=(ALL) NOPASSWD: /bin/systemctl restart nginx
visudo -c                             # check all sudoers files for syntax errors

# Permissions
chmod 640 /etc/nginx/nginx.conf
chown www-data:www-data /srv/app -R   # ⚠ use -R with care, see below
setfacl -m u:deploy:rw /srv/app/logs  # fine-grained grants, instead of changing a whole directory for one person
getfacl /srv/app/logs
umask 027
```

⚠ `usermod -G group user` (without `-a`) **replaces** the user's supplementary groups with that single one, which can incidentally strip away sudo access. Always write `-aG`.
⚠ Editing `/etc/sudoers` directly and getting a single character wrong can cost you sudo permanently. Use `visudo` only; adding a new file under `sudoers.d` is lower risk, and verify afterwards with `visudo -c`.
⚠ Back up `/etc/passwd` and `/etc/group` before changing them (`scripts/backup_config.sh`). If either file is corrupted, you will no longer be able to log in.

---

## 10. Docker

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker ps -a --filter 'status=exited'
docker logs --tail 100 -f <name>
docker logs --since 30m <name>
docker inspect <name> --format '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}'
docker stats --no-stream

# compose
docker compose config                 # validate the compose file syntax (mandatory after editing)
docker compose ps                     # look at actual state, not just the exit code of up -d
docker compose up -d --no-deps <svc>  # recreate only one service
docker compose up -d --force-recreate <svc>
docker compose logs --tail 100 <svc>
docker compose pull && docker compose up -d

# Images and cleanup
docker images; docker image prune -f
docker system df                      # disk usage by category
docker system prune -a                # ⚠ deletes unused images; a mutating operation

# Getting into a container to investigate
docker exec -it <name> sh
docker exec <name> cat /etc/os-release
docker cp <name>:/var/log/app.log ./app.log
docker events --since 1h              # container lifecycle events

# Container processes as seen from the host
ps -eo pid,cmd | grep containerd
```

**Exit Codes Quick Reference**

| Exit code | Common cause |
|---|---|
| 0 | Normal exit (for a long-running service it means the service exited on its own) |
| 1 | Application failed to start: bad config, missing dependency, port already in use |
| 126 | Command exists but is not executable (permission bits) |
| 127 | Command not found (not installed in the image, wrong path) |
| 137 | 128+9: killed by SIGKILL — **check for OOM first** (`OOMKilled=true`) |
| 139 | Segmentation fault |
| 143 | 128+15: killed by SIGTERM, usually `docker stop` |

⚠ `docker system prune -a` deletes every image that no container references, including the old version you were planning to roll back to. Confirm the image is still there before you roll back.
⚠ Container logs grow without bound by default, and they are a common cause of disk alerts. Give every service `logging.options.max-size`/`max-file` in your compose file.

---

## 11. Git Deployment and Rollback

```bash
# See what's new upstream (without changing local state)
git -C /srv/app fetch --all
git -C /srv/app log --oneline HEAD..origin/main
git -C /srv/app diff --stat HEAD origin/main

# Deploy: --ff-only avoids merge commits or a hung conflict
git -C /srv/app pull --ff-only

# Current version and recent commits
git -C /srv/app rev-parse --short HEAD
git -C /srv/app log -3 --oneline
git -C /srv/app status --short

# Rollback
git -C /srv/app reset --hard <last good commit>
git -C /srv/app checkout <tag>
git -C /srv/app revert <commit>        # produces a reverse commit, suitable for an already-pushed branch

# Deployment chain (order matters)
# 1. Record the current commit (the rollback anchor)
# 2. Back up the current build artifacts / config
# 3. fetch + inspect changes + pull --ff-only
# 4. Install dependencies (npm ci / pip install -r)
# 5. Build
# 6. Reload the service (reload rather than restart where possible)
# 7. Health check: curl the local port + confirm no new errors in the log
# 8. On failure: git reset --hard back to the anchor + rebuild + reload
```

⚠ Always record the current commit before deploying. When something goes wrong, "which version do we go back to" has to be a definite value, not "roughly the previous one".
⚠ `git clean -fd` deletes untracked files (including uploaded build artifacts and local config). That is high-risk.
⚠ Lock deployments (flock), or use a release directory plus a symlink switch, so that several processes don't deploy into the same directory at the same time.

---

## 12. Certificates

```bash
# Check a remote certificate's validity
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null \
  | openssl x509 -noout -dates -subject -issuer

# Expand and show the full chain
openssl s_client -connect example.com:443 -servername example.com -showcerts </dev/null

# Local certificate files
openssl x509 -in /etc/ssl/certs/app.crt -noout -dates -subject
openssl rsa -in app.key -check -noout            # private key integrity
openssl x509 -noout -modulus -in app.crt | openssl md5
openssl rsa -noout -modulus -in app.key | openssl md5   # both md5s must match -> cert and key are a pair

# Let's Encrypt
certbot certificates                             # days remaining
certbot renew --dry-run
systemctl list-timers | grep certbot

# Batch checks (pair with batch_run.sh)
echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null \
  | openssl x509 -noout -enddate
```

⚠ Wrap batch checks in `timeout 10`, otherwise hosts that can't be reached will hang indefinitely.
⚠ After renewing a certificate don't forget to reload the service (nginx keeps using the copy it loaded at startup until you reload).
⚠ Check expiry **from an external network**; a local curl may see a different certificate because the SNI/Host header differs.

---

## 13. Distribution Differences Quick Reference

| Item | Debian / Ubuntu | RHEL / CentOS / Rocky / Alma |
|---|---|---|
| Package manager | `apt-get` / `apt` | `dnf` (CentOS 7 uses `yum`) |
| Install a package | `apt-get install -y x` | `dnf install -y x` |
| Keep config non-interactively | `-o Dpkg::Options::=--force-confold` | keeps `.rpmnew` by default |
| Firewall | `ufw` | `firewalld` |
| SSH service name | `ssh` | `sshd` |
| System log | `/var/log/syslog` | `/var/log/messages` |
| Auth log | `/var/log/auth.log` | `/var/log/secure` |
| Package log | `/var/log/dpkg.log` | `/var/log/dnf.log` (yum.log on older versions) |
| SELinux / AppArmor | AppArmor | SELinux (`getenforce`) |
| Reboot-required file | `/var/run/reboot-required` | `needs-restarting -r` |
| Service management | `systemctl` (both are systemd) | `systemctl` |
| Web service user | `www-data` | `nginx` / `apache` |
| Timezone setting | `timedatectl set-timezone` | `timedatectl set-timezone` |

```bash
# Writing one command that works on both distributions
if command -v apt-get >/dev/null 2>&1; then
  apt-get install -y "$pkg"
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y "$pkg"
elif command -v yum >/dev/null 2>&1; then
  yum install -y "$pkg"
else
  echo "unknown package manager" >&2; exit 1
fi

# SSH service name differs
svc=ssh; systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service' && svc=sshd
systemctl reload "$svc"
```
