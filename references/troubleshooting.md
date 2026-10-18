# Troubleshooting Handbook

A troubleshooting handbook organized by symptom. Each section is structured as: **quick triage** (run these first) → **root-cause reading** → **fix** → **prevention**.

When you hit a symptom, read the matching section first — do not guess and try commands at random. In SSH scenarios, blind retries can also trigger fail2ban and make things worse.

## Table of Contents

- [1. Can't Connect to the Server](#1-cant-connect-to-the-server)
- [2. Disk Full / Inodes Exhausted](#2-disk-full--inodes-exhausted)
- [3. Service Won't Start](#3-service-wont-start)
- [4. Website 502 / 504](#4-website-502--504)
- [5. High Load / CPU Maxed Out](#5-high-load--cpu-maxed-out)
- [6. Out of Memory / OOM](#6-out-of-memory--oom)
- [7. Port Already in Use](#7-port-already-in-use)
- [8. Strange Problems Caused by Clock Skew](#8-strange-problems-caused-by-clock-skew)
- [9. Certificate Expiry](#9-certificate-expiry)
- [10. Container Restart Loop](#10-container-restart-loop)
- [11. Slow Disk I/O](#11-slow-disk-io)
- [12. Blocked by fail2ban / Security Group](#12-blocked-by-fail2ban--security-group)
- [13. Permissions Look Right but Access Still Fails](#13-permissions-look-right-but-access-still-fails)
- [14. Locked Yourself Out After a Config Change](#14-locked-yourself-out-after-a-config-change)

---

## 1. Can't Connect to the Server

### Quick Triage

Work down the layers, **do not skip steps** — jumping ahead wastes a lot of time heading in the wrong direction.

```bash
# Layer 0: is the network from this machine to the target alive
ping -c 3 <host>
# Layer 1: does DNS resolve to the IP you expect (common after a cloud host changes IP)
dig +short <host>; getent hosts <host>
# Layer 2: is the port reachable
nc -zv <host> <port>
traceroute -T -p <port> <host>      # -T uses TCP, so it gets through a firewall that only allows that port
# Layer 3: at which step does the SSH handshake fail
ssh -vvv -o ConnectTimeout=8 <host> true 2>&1 | tail -40
```

### Reading the Error Message

| Error message | Root cause | Handling |
|---|---|---|
| `Could not resolve hostname` | Name resolution failed | Check the HostName spelling in `~/.ssh/config`, `/etc/hosts`, DNS |
| `Connection timed out` / `No route to host` | Blocked at the network layer, or the target is offline | Security group inbound rules, cloud firewall, whether the target is powered off |
| `Connection refused` | Host reachable but nothing listening on the port | sshd not running, port changed, listening only on 127.0.0.1 |
| `Connection closed by ... port 22` | The peer dropped the connection | fail2ban ban, `MaxStartups` rate limiting, interference from an intermediate device |
| `kex_exchange_identification: ...` | Same as above, or TCP wrapper / load balancer interference | Check fail2ban, `/etc/hosts.deny` |
| `Permission denied (publickey)` | Authentication failed (the network is fine) | See "Authentication Problems" below |
| `Permission denied (publickey,password)` | The server rejected both the key and the password | The client did not present the right key, and the password was not accepted either — see the decision tree below |
| `Permission denied (password)` | The server asks for a password and rejected the one submitted | Wrong password, or the password never reached ssh — see "Authentication Problems" |
| `Too many authentication failures` | Too many keys in the agent, all offered one by one | Add `-i <private key> -o IdentitiesOnly=yes`, or use `--auth password` |
| `Host key verification failed` | The host fingerprint changed, or it is not in known_hosts | Verify the fingerprint, see below |
| `no matching host key type` | Algorithm mismatch (new client + old server) | Add `HostkeyAlgorithms +ssh-rsa` to the ssh config |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | The fingerprint does not match the recorded one | **Suspect a man-in-the-middle first**, then suspect a reinstall or an IP change |
| `no askpass program specified` | ssh needs a password but has no non-interactive way to ask | Use `--auth password --prompt-credential` / `--password-env` / `--credential-file` |

### Authentication Problems

Check in this order, starting from the most common cause. Run `scripts/ssh_exec.sh --selftest` first —
it answers most of the environment questions in one screen (which ssh binary, whether it supports
`SSH_ASKPASS_REQUIRE`, whether the askpass helper works end to end).

```bash
# Client side: which key is actually being offered, and which one the server accepts
ssh -vvv -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 <host> true 2>&1 | grep -iE 'offering|authentications|publickey'

# Server side (if you have another way in):
ls -ld ~ ~/.ssh
ls -l ~/.ssh/authorized_keys
stat -c '%a %U:%G %n' ~ ~/.ssh ~/.ssh/authorized_keys
# Expect: ~/.ssh 700, authorized_keys 600, home directory not group/other writable

# The server log states the rejection reason explicitly
journalctl -u ssh -n 50 --no-pager          # Debian family
journalctl -u sshd -n 50 --no-pager         # RHEL family
tail -50 /var/log/auth.log /var/log/secure 2>/dev/null

# Effective server configuration
sshd -T | grep -iE 'pubkey|passwordauth|kbdinteractive|authorizedkeysfile|allowusers|allowgroups|permitrootlogin|maxauthtries'
```

Common root causes:

- The home directory or `~/.ssh` permissions are too permissive (if group or other can write, the connection is refused — and the error is still `Permission denied`)
- The user is excluded by `AllowUsers` / `AllowGroups`
- The `home` directory is mounted `noexec`, or its SELinux context is wrong (`restorecon -Rv ~/.ssh`)
- The user is explicitly disabled in `sshd_config`, or the account is locked with `usermod -L`
- The cloud vendor image disables root password login by default, but you assumed it did not

**Password-specific checks.** If the server offers password auth and you are getting
`Permission denied (password)` or it looks like the password is simply ignored:

```bash
# 1) Is password auth even allowed on the server?
sshd -T | grep -iE '^passwordauthentication|^kbdinteractiveauthentication|^permitemptypasswords'

# 2) Is ssh-agent holding so many keys that it exhausts MaxAuthTries before the password is offered?
ssh -vvv <host> true 2>&1 | grep -iE 'offering|authentications that can continue|MaxAuthTries'

# 3) Did the password actually reach ssh? (logs the prompt text, never the password)
SSHMGR_ASKPASS_DEBUG=1 scripts/ssh_exec.sh -H <host> --auth password --prompt-credential -c 'true'
cat ~/.ssh-server-manager/askpass.log
```

- **A key file containing a trailing CR** is a classic silent failure: a credential file saved by
  Notepad or PowerShell ends in `\r\n`, and the CR becomes part of the password. `ssh_exec.sh`
  strips it, but a hand-rolled pipeline may not.
- **If the password path keeps failing, force it explicitly** with `--auth password`. That disables
  pubkey attempts, so a crowded ssh-agent cannot burn through `MaxAuthTries` first.

### Host Fingerprint

```bash
# Fetch the fingerprint from a trusted network and compare it with the cloud console's
# "key pair / host fingerprint" entry
ssh-keyscan -t ed25519,rsa -p <port> <host> 2>/dev/null | ssh-keygen -lf -
```

⚠ When the fingerprint does not match, do **not** just run `ssh-keygen -R` and be done with it. First confirm whether a reinstall or migration caused it; a fingerprint that changes suddenly can also mean a man-in-the-middle.

### Prevention

- Keep a second way in: cloud console VNC, out-of-band management, another account, or another network path
- Attach an automatic rollback timer before changing sshd or the firewall (see the config-change protocol in SKILL.md)
- Do not turn off `StrictHostKeyChecking` just to save yourself trouble

---

## 2. Disk Full / Inodes Exhausted

Both report `No space left on device`, but you have to look in different places, so **check both**.

### Quick Triage

```bash
df -hT                                  # which partition, how full
df -i                                   # inodes -- a disk with free space but exhausted inodes reports the same error
```

### Disk Full: Locating the Usage

```bash
du -xhd1 / 2>/dev/null | sort -rh | head -12      # -x stays on one filesystem
du -xhd1 /var 2>/dev/null | sort -rh | head -12
du -xhd1 /var/log 2>/dev/null | sort -rh | head -12
```

**df shows the disk full, but no matter how you add up du it doesn't come close** — this is the situation most easily misdiagnosed. Check in this order:

```bash
# 1) Deleted files still held open by a process (the space is never released)
lsof -nP +L1
# Fix: restart the process holding the file; as an emergency, truncate that fd
truncate -s 0 /proc/<pid>/fd/<n>

# 2) A directory covered by a mount point (data written before the mount is hidden)
mount | grep -E ' /(var|home|srv)'
# Fix: look after unmounting, or reach the hidden directory through another path

# 3) Reserved blocks (ext filesystems reserve 5% for root by default)
tune2fs -l /dev/sda1 | grep -i reserved
# Fix: a data disk can drop to 1% -- tune2fs -m 1 /dev/sda1

# 4) Snapshot / overlay usage
lvs; docker system df
```

### Common Space Hogs and the Order to Clean Them

| Location | How to clean | Risk |
|---|---|---|
| journal | `journalctl --vacuum-time=7d` | Low (confirm log retention requirements first) |
| package cache | `apt-get clean` / `dnf clean all` | Low |
| exited containers / dangling images | `docker system prune` | Medium (deletes unused images) |
| application logs | configure `logrotate` or use `truncate -s 0`, **do not `rm`** | Medium |
| old kernels | `apt-get autoremove --purge` | Medium (keep at least one bootable kernel) |
| business data files | confirm backups and provenance first | High |

⚠ Deleting a log file that a process still has open with `rm` does not free the space (the inode is still held). Use `truncate -s 0`, or reload the process first.
⚠ Confirm compliance/audit retention requirements before deleting logs. Deleting audit logs may be a violation, and it is unrecoverable.

### Inodes Exhausted

```bash
# Which directory holds the most files
find /var -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -20
# Typical culprits: session files, mail queues, cache fragments, many small files in tmp
ls -U /var/lib/php/sessions | head        # -U skips sorting, much faster on huge directories
find /tmp -xdev -type f | wc -l
```

When inodes are exhausted, **deleting large files does not help** — you must delete "a great many small files" or archive them into a single file.

### Prevention

- Hand all logs to `logrotate` (`/etc/logrotate.d/`), and trigger by size rather than only by time
- Limit `max-size`/`max-file` for Docker in the compose file
- Monitor disk usage **and** inode usage together
- Give `/var/log` its own partition, so logs filling up cannot drag down the system disk

---

## 3. Service Won't Start

### Quick Triage

```bash
systemctl status <svc> --no-pager -l        # -l shows full lines; otherwise key info is truncated
journalctl -u <svc> -n 100 --no-pager
journalctl -u <svc> --since '10 min ago'
systemctl cat <svc>                          # the unit actually in effect (including drop-ins)
systemctl show <svc> -p ExecStart,User,Environment,Restart
```

### Checking by Root Cause

**1) Config syntax error** — the most common

```bash
nginx -t
sshd -t
php-fpm -t
named-checkconf
apachectl configtest
docker compose config
```

**2) Port already in use**

```bash
ss -lntp | grep ':<port>'
fuser -v <port>/tcp
lsof -nP -iTCP:<port> -sTCP:LISTEN
```

**3) Permissions or SELinux**

```bash
namei -l /srv/app/binary            # check permissions level by level along the path
getenforce; ausearch -m avc -ts recent | tail -20
# Emergency diagnosis only: setenforce 0 (⚠ use it to confirm the hypothesis, never as the fix)
restorecon -Rv /srv/app
```

**4) Dependencies not up yet**

```bash
systemctl list-dependencies <svc> --reverse
systemctl status <dependency-service>
```

**5) Environment variables / working directory**

A service started by `systemd` does not read `~/.bashrc`, and it does not necessarily have a PATH. Use `systemctl show -p Environment` to see the actual environment, and write `Environment=` and `WorkingDirectory=` explicitly in the unit.

**6) Insufficient resources**

```bash
free -m; df -h /; ulimit -n
systemctl show <svc> -p LimitNOFILE
```

**7) Startup timeout**

If `systemctl status` shows `start operation timed out`, the process failed to stay in the foreground (often because `-D`/`--no-daemon` was missing and the service forked itself into the background). Run it in foreground mode instead.

**8) Unit changed but not reloaded**

```bash
systemctl daemon-reload && systemctl restart <svc>
```

### Verifying After the Fix

```bash
systemctl is-active <svc>
systemctl is-enabled <svc>          # running ≠ enabled at boot; check both
ss -lntp | grep <port>
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>/
```

---

## 4. Website 502 / 504

### Tell Them Apart First

- **502 Bad Gateway**: the gateway got an invalid response from the upstream, or could not connect to the upstream
- **504 Gateway Timeout**: the gateway timed out waiting for the upstream

### Quick Triage

```bash
# 1) Quantify: how many, which URLs, and when did it start
awk '$9==502 || $9==504 {print $9, $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head
awk '$9 ~ /^5/ {print substr($4,2,17)}' /var/log/nginx/access.log | uniq -c | tail -20

# 2) Read nginx's own error, which names the failing link directly
tail -n 300 /var/log/nginx/error.log | grep -iE 'error|crit|upstream|connect|timeout'

# 3) Upstream service state
systemctl status php-fpm nginx --no-pager -l
journalctl -u php-fpm -n 100 --no-pager

# 4) Is the upstream port listening
ss -lntp | grep -E ':(9000|8000|3000|8080)'

# 5) Resources
free -m; nproc; uptime; df -h /
```

### Reading It from error.log

| Error | Root cause | Handling |
|---|---|---|
| `connect() failed (111: Connection refused)` | The upstream process is not listening | Start the upstream service; check the address and port in `upstream`/`fastcgi_pass` |
| `upstream timed out (110)` | The upstream is up but slow | Look at slow requests on the upstream and slow DB queries; adjust `proxy_read_timeout` (a stopgap) |
| `no live upstreams while connecting` | Every upstream was judged unavailable | Check `max_fails`/`fail_timeout`, and whether the upstreams are really down |
| `recv() failed (104: Connection reset by peer)` | The upstream process crashed or closed the connection | Look at the upstream logs and OOM records |
| `worker_connections are not enough` | Not enough connections | `worker_connections`, `ulimit -n` |
| `Too many open files` | File descriptors exhausted | `worker_rlimit_nofile`, system `ulimit -n` |
| `upstream sent too big header` | The upstream response header is too large | `proxy_buffer_size` / `fastcgi_buffer_size` |
| `pool www seems busy` (PHP-FPM log) | The process pool is saturated | Tune `pm.max_children`; look at slow requests and blocking calls |

### Common Root-Cause Chains

1. **PHP-FPM / application process pool saturated** — requests queue up, showing as intermittent 502/504. First look at FPM's `max_children` against the real concurrency, then at the slow log.
2. **Database connections exhausted or slow queries** — the application waits on the DB until it times out. Look at the DB's `max_connections`, `SHOW PROCESSLIST`, and the slow query log.
3. **Upstream restarting** — normal during a deployment or crash-restart window; confirm whether it lines up with the release/restart time.
4. **File descriptors exhausted** — a hidden ceiling under high concurrency; `ulimit -n` is often 1024.
5. **Backend killed by the OOM killer for lack of memory** — `dmesg -T | grep -i oom`.
6. **Disk full causing log/session writes to fail** — the application returns 500, and nginx shows it as 502.

### Fixing and Verifying

After you have located it, **hand the conclusion and the plan to the user for confirmation before restarting services**, and explain that a restart interrupts requests currently being processed. To verify:

```bash
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' http://127.0.0.1/
tail -f /var/log/nginx/error.log      # watch for new errors
awk '$9==502' /var/log/nginx/access.log | wc -l   # compare the count before and after
```

---

## 5. High Load / CPU Maxed Out

### Quick Triage

```bash
uptime; nproc          # load only means something divided by core count
vmstat 1 5             # r = run queue; b = blocked processes; wa = IO wait
mpstat -P ALL 1 3      # one core saturated vs. busy overall
top -b -n1 | head -20
pidstat -u 1 3
```

### Reading the Numbers

- **High load but idle CPU**: most likely I/O wait (`wa` high) or a lot of uninterruptible sleep (D state). Check the disk and NFS.
- **High load and the `r` column far above the core count**: genuine CPU queueing; find the processes eating CPU.
- **One core at 100% while the others are idle**: a single-threaded bottleneck (common with a single Node/Python process, or lock contention).
- **High `us`**: the application's own computation.
- **High `sy`**: syscall-heavy, common with heavy I/O, context switching, container networking.
- **High `st` (steal)**: the VM is being squeezed by the host; you cannot fix it, only talk to the cloud vendor or upgrade the instance.

### Finding the Culprit

```bash
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd --sort=-%cpu | head -15
top -H -p <pid>                        # which thread
perf top -p <pid>                      # requires the perf tools
strace -c -p <pid>                     # syscall counts (has a performance cost)
```

### Emergency Handling

```bash
renice -n 10 -p <pid>                  # lower priority (reversible, try first)
kill -15 <pid>                         # graceful stop
# or start another instance with `nice` to share the load, if the service is stateless
```

⚠ `kill -9` can lose data or leave locks behind for a database/file service. Use TERM first.
⚠ Do not just reboot the machine: a restart under load is very slow, and it destroys the evidence on the scene.

### Prevention

- Establish an explicit capacity baseline: how many cores, expected QPS, what a normal load is
- Monitor `load/nproc`, `%st`, and `wa`, not just the CPU percentage
- For single-threaded services, use multiple instances behind a load balancer instead of relying entirely on adding cores

---

## 6. Out of Memory / OOM

### Quick Triage

```bash
free -m                     # look at available, not free
cat /proc/meminfo | head -5
ps -eo pid,user,%mem,rss,cmd --sort=-%mem | head -10
dmesg -T | grep -i -E 'oom|killed process'
journalctl -k --since '7 days ago' | grep -i 'killed process'
```

### Reading the Numbers

- **`available` very low + heavy `swap` use**: real memory pressure.
- **`free` low but `available` high**: normal. Linux uses free memory as cache; low `free` does not mean there is a problem.
- **A process whose RSS far exceeds expectations and keeps growing**: a memory leak.
- **OOM kill records present**: the process was killed by the kernel, not "crashed on its own" — this explains why a service mysteriously disappeared.

### The Knock-On Effects of OOM

The OOM killer picks the process using the most memory, which is not necessarily the one that *should* be killed. A database killed by OOM causes cascading 502s in the application above it. So when you see a 502, also check back for OOM.

### Emergency Handling

```bash
# Degrade before restarting: drop caches (a stopgap, and it makes things slower briefly)
sync; echo 3 > /proc/sys/vm/drop_caches
# Find and restart the service actually consuming memory (a mutating operation, needs confirmation)
systemctl restart <svc>
```

Hardening directions:

- Set `MemoryMax` (cgroup v2) or systemd's `MemoryLimit` on critical services, so one service cannot drag down the whole machine
- Lower the OOM score to protect the database: `echo -500 > /proc/<pid>/oom_score_adj`
- Explicitly cap connection counts and buffer sizes in the database configuration

### Prevention

- Monitor `available`, swap usage, and the `oom_kill` counter
- Do memory limits and health checks at the application layer, so it restarts itself when it exceeds the limit instead of dragging down the machine
- Add `deploy.resources.limits.memory` to containers, and confirm what exit code 137 means

---

## 7. Port Already in Use

```bash
ss -lntp | grep ':<port>'
lsof -nP -iTCP:<port> -sTCP:LISTEN
fuser -v <port>/tcp
```

### Handling

1. **Confirm who is holding it**: it may be a leftover instance that did not exit cleanly, another service, or docker-proxy.
2. **Do not just `kill -9`**: first confirm whether it is a stateful service.
3. **Docker port conflict**: `docker ps` shows which container published that port. Note that docker-proxy holds the port, and only removing the container releases it.
4. **`TIME_WAIT` looks like a port in use but is not**: `ss -tan state time-wait | head`, then add `SO_REUSEADDR` or tune `net.ipv4.tcp_tw_reuse`.
5. **Check the firewall before changing the port**: the new port must be allowed in both the security group and the host firewall, otherwise you will not be able to connect once you switch.

⚠ When changing a listening port, follow "add first, remove later": make the new port available and verify it before stopping the old one.

---

## 8. Strange Problems Caused by Clock Skew

A time offset triggers a batch of failures that look completely unrelated, and it is easy to investigate in the wrong direction.

### Symptoms

- The TLS certificate "is not yet valid" / "has expired", but the certificate itself is fine
- Log timestamps out of order, logs across machines that do not line up
- `apt`/`dnf` reporting GPG signature errors
- Authentication failures between cluster nodes (Kerberos, etcd, Kafka)
- Scheduled tasks firing at unexpected times, or not firing at all

### Quick Triage

```bash
timedatectl                                  # check NTP synchronized and the timezone
timedatectl show -p NTPSynchronized --value
chronyc tracking                             # chrony
ntpq -p                                      # ntpd
date; date -u; ls -l --time-style=full-iso /etc/hostname
```

### Handling

```bash
timedatectl set-timezone Asia/Shanghai
systemctl restart systemd-timesyncd          # or chronyd / ntpd
chronyc sources -v
```

⚠ A time jump affects programs that depend on time differences (such as `cron`, certificate validation, log indexing). If the offset is large, it is best to sync during a maintenance window rather than flattening it out during peak business hours.

---

## 9. Certificate Expiry

```bash
echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null \
  | openssl x509 -noout -dates -subject -issuer
certbot certificates                          # Let's Encrypt
```

### Common Causes

1. **Auto-renewal is not running**: `systemctl list-timers | grep certbot`, or the cron job is failing (check `/var/log/letsencrypt/`).
2. **Renewal succeeded but the service was not reloaded**: nginx keeps using the certificate loaded at startup until it is reloaded. **This is the most common cause.**
3. **Renewal failed and nobody noticed**: a changed validation method (HTTP-01 needs port 80 reachable), a DNS change, rate limiting.
4. **Certificate and private key do not match**: the md5 of `openssl x509 -noout -modulus` and `openssl rsa -noout -modulus` must be identical.

### Handling

```bash
certbot renew --dry-run          # rehearse first
certbot renew
nginx -t && systemctl reload nginx    # reload is mandatory after renewal
```

⚠ Verify the certificate from the **external network** (`openssl s_client` to the public domain name); a local curl may see a different certificate because of a different SNI/Host.
⚠ Monitor the certificate's remaining days, and set the threshold above 21 days — do not wait until 3 days.

---

## 10. Container Restart Loop

```bash
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'
docker inspect <name> --format '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}'
docker logs --tail 200 <name>
docker logs --since 30m <name>
docker events --since 1h --filter container=<name>
```

### Reading by Exit Code

| Exit code | Meaning | What to check |
|---|---|---|
| 0 | Clean exit | A long-running service should not exit 0; does the entrypoint command just finish and exit |
| 1 | Application error | The exception stack in the logs; configuration/dependencies/permissions |
| 126 | Command not executable | The entrypoint script has no execute bit |
| 127 | Command not found | Not installed in the image; wrong `CMD` path; missing interpreter in the shebang |
| 137 | SIGKILL (128+9) | **Check OOM first**: `oom=true` or the host's `dmesg`; it can also be a forced kill after `docker stop` timed out |
| 139 | Segmentation fault | Architecture mismatch, native library problems |
| 143 | SIGTERM (128+15) | Reclaimed by `docker stop`/orchestration; check whether the health check judged it failed |

### Common Root Causes

1. **Health check too strict**: the `healthcheck` interval or timeout is too short, and the service is declared dead before it has come up → the orchestrator restarts it. Loosen `start_period`.
2. **Killed by OOM for exceeding memory**: add `deploy.resources.limits.memory`, and at the same time check whether the application really needs that much.
3. **Dependency service not ready**: a startup-order problem; add `depends_on: condition: service_healthy` or retry inside the application.
4. **Timezone/encoding**: UTC inside the container does not match the host, causing wrong business logic.
5. **Disk full**: the container fails to write logs or temporary files and exits immediately.
6. **Volume permissions**: the owner of the mounted directory does not match the user inside the container.
7. **`Restart: always` hides the real error**: constant restarts make people overlook the earliest error — look at the log of the **first** crash.

---

## 11. Slow Disk I/O

```bash
iostat -xz 1 5                 # %util near 100 means saturated; high await means slow
iotop -oP                      # who is reading and writing (needs root)
pidstat -d 1 3
vmstat 1 5                     # high wa = IO wait
cat /proc/pressure/io          # PSI, a more accurate pressure metric
```

### Reading the Numbers

- **High `%util` + high `await`**: the device really cannot keep up.
- **`%util` not high but `await` high**: could be network storage (NFS/EBS) latency, or a problem at the queueing layer.
- **`await` high while your own write volume is small**: check whether you are being dragged down by someone else (other instances on the same host, backup jobs).
- **`iops` maxed out**: cloud disks have an IOPS ceiling, and performance drops sharply once the burst allowance is used up.

### Common Culprits

- Backups/log rotation/`find` full-disk scans running during peak business hours
- Missing indexes in the database causing full table scans
- Container logs growing without a limit
- Swap thrashing (a knock-on symptom of insufficient memory)

### Handling

- Move heavy I/O tasks to off-peak hours, and use `ionice -c3` to drop them to idle priority
- Check slow queries and add indexes
- Upgrade the cloud disk or switch to a higher-IOPS type

---

## 12. Blocked by fail2ban / Security Group

### Symptoms

You suddenly cannot connect, or the connection is closed immediately (`Connection closed by ... port 22`), but the network itself is fine.

```bash
# On the server (if you can still get in):
fail2ban-client status sshd
fail2ban-client status
fail2ban-client set sshd unbanip <your-ip>
# Temporarily disable (restore as soon as you have confirmed the cause)
fail2ban-client stop sshd
```

If it is **your own IP** that got banned, it is usually because:

- A script retried repeatedly, exceeding the authentication failure limit
- Too many keys in `ssh-agent`, and offering them one by one tripped `maxretry`
- A misconfigured automation task is looping on login

⚠ When troubleshooting connection problems, **do not retry blindly**. Consecutive failures will get you banned for longer — this is also why `ssh_exec.sh` uses `BatchMode=yes` on the key path to fail fast instead of reconnecting over and over. (On the password path `BatchMode` is deliberately relaxed, but `NumberOfPasswordPrompts=1` still caps it to a single attempt per invocation.)

⚠ A cloud host's **security group** lives in the console, not on the machine. On the machine `iptables -S` may show the port allowed, but if the security group does not allow it, it still will not connect — and the reverse can happen too.

---

## 13. Permissions Look Right but Access Still Fails

`ls -l` looks fine, but the process still cannot read the file. Check in this order:

```bash
namei -l /srv/app/dist/index.html      # check permissions on every directory level
```

1. **A directory is missing the execute bit**: reading a file requires `x` on **every** directory along the path. If `/srv/app` is 700 while `/srv` is 755, others still cannot get in.
2. **SELinux / AppArmor**: `getenforce`; `ausearch -m avc -ts recent`; `restorecon -Rv /path`.
3. **An ACL overrides the base permissions**: `getfacl /path`; there may be a deny entry or a mask limiting the effective bits.
4. **Mount options**: `mount | grep <path>`; it could be `noexec`, `nosuid`, or read-only.
5. **File attributes (chattr)**: `lsattr /path`; the `i` attribute makes a file immutable (even root cannot change it — you must `chattr -i` first).
6. **The process runs as a different user than you**: `ps -o user= -p <pid>`; the service may run as `www-data`/`nginx` while you are testing as root.
7. **Home directory permissions too permissive, causing SSH to refuse** (see Section 1).

---

## 14. Locked Yourself Out After a Config Change

### What to Do Immediately (Do Not Close Anything!)

1. **Do not disconnect the current session.** An already-established SSH connection usually survives an sshd restart — this is your lifeline.
2. **Change it back** in the current session:

   ```bash
   # Example: sshd_config was broken
   cp /etc/ssh/sshd_config.bak.<timestamp> /etc/ssh/sshd_config
   /usr/sbin/sshd -t && systemctl reload sshd
   ```

   ⚠ Use `reload`, not `restart`: `reload` does not cut off existing connections.
3. Open **a second** new session to verify you can log in, and only close the old session after that succeeds.
4. If it was the firewall you broke:

   ```bash
   # ufw
   ufw disable           # restore availability first (⚠ dangerous; only for this self-rescue scenario)
   # or just allow the current port
   ufw allow 22/tcp
   ```

   ```bash
   # iptables: flush and restore the default policy (confirm the current policy first!)
   iptables -P INPUT ACCEPT
   iptables -S > /root/iptables.broken.$(date -u +%Y%m%dT%H%M%SZ)
   iptables-restore < /root/iptables.<last-good-timestamp>.rules
   ```

### If the Session Is Already Gone

Try from the highest availability downward:

1. **Cloud console VNC / serial console**: as long as you have the cloud account password you can get in — the most reliable fallback.
2. **Out-of-band management** (IPMI/iDRAC/iLO).
3. **Ask someone else with access** to log in from their own IP (maybe only your IP is blocked by the firewall).
4. **Rescue mode**: cloud vendors generally offer a "rescue/recovery mode" where you attach the system disk and edit the config file.
5. **Third-party reachability**: if it is a security group problem rather than a machine configuration problem, just change it back in the console.

### Prevention (These Measures Exist for Exactly This Moment)

- Back up before changing: `scripts/backup_config.sh -H web1 -f /etc/ssh/sshd_config --sudo`
- Attach an automatic rollback timer before changing:

  ```bash
  sudo systemd-run --on-active=10min --unit=sshd-rollback \
    /bin/sh -c 'cp /etc/ssh/sshd_config.bak.<ts> /etc/ssh/sshd_config && systemctl reload sshd'
  # cancel it once verified
  sudo systemctl stop sshd-rollback.timer
  ```

- Keep a second way in: a backup account, a backup network path, or the cloud console VNC
- Use `reload` instead of `restart`
- Validate in the pre-release environment first, then touch production
