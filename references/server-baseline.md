# Server Profiles

On first contact with a machine, read everything worth knowing once and store it. Afterwards
read the profile instead of re-reconnoitering every time.

## Why

A machine you have connected to ten times still has the same CPU model, the same memory, the
same set of Docker services, the same disk baseline — those **almost never change**. Re-collecting
them each time is waste, and collecting without storing is worse. But "current state" (load, free
memory, failed services) **changes constantly**, so storing that just goes stale immediately.

So the division is explicit:

| | Stored in the profile | Checked only during inspection |
|---|---|---|
| Content | Hardware model, kernel, virtualization, disks and filesystems, NICs and listening ports, Docker and container inventory, systemd service inventory, runtime versions, firewall and effective sshd config, accounts | Load, memory/swap headroom, current connection counts, failed units, container health, disk usage |
| Rate of change | Months to years | Seconds to minutes |
| Owned by | `scripts/server_profile.sh` + `profile_store.sh` | `scripts/health_check.sh` |

## Location and Format

```
~/.ssh-server-manager/
├── audit.log              # audit log (one line per remote command)
├── credentials            # optional: password (only created on explicit --save-credential)
├── cm/                    # ControlMaster connection-multiplexing sockets
└── profiles/
    ├── 203.0.113.10.profile        # named after the connection target
    ├── 203.0.113.10_2222.profile   # non-22 port
    └── web1.m2.profile             # a different machine at the same target (machine_id mismatch)
```

The format is flat `key=value`, `#` for comments, and it is hand-editable. List keys are indexed
as `key.0` / `key.1` when read; `ip_all` and `alias` are exceptions — they stay as plain repeated
lines because `find` matches them with fixed-string grep.

Override the directory with `SSHMGR_HOME` (or `SSHMGR_LOG_DIR`).

**⚠ Profiles contain infrastructure detail — IPs, hostnames, image lists. Do not commit them to
a repository or paste them somewhere public.**

## Fields Collected

| Section | Content |
|---|---|
| `identity` | hostname/fqdn, `ip_primary` (source address of the default route), `ip_all`, machine_id, boot_id, os-release, kernel, arch, virt, tz/NTP, uptime, SELinux/AppArmor, reboot-required, sshd unit name |
| `hw` | CPU vendor/model/sockets/physical cores/threads/frequency/L3/NUMA/key flags, MemTotal, SwapTotal, DMI chassis, GPU |
| `storage` | `lsblk -dn` disks and models, `findmnt` filesystems and usage, `/proc/diskstats` cumulative sectors (baseline) |
| `network` | all addresses via `ip -br addr`, default gateway, listening ports via `ss -lnt`, DNS |
| `docker` | version, container/image counts, driver, root dir, **full container inventory**, compose projects, volume/network counts |
| `services` | running systemd units, failed units, timers, cron entry count, package manager |
| `runtimes` | python3/node/php/java/go/ruby/nginx/mysqld/redis/psql versions |
| `security` | firewall state, effective sshd config, accounts with a login shell |

## ⛔ Prohibited Collection Methods (Hard Rule of This Skill)

**Never run benchmarks or stress tests.** Prohibited: `sysbench`, `fio`, `dd` write tests,
`stress-ng`, `memtester`, `iperf3`, `openssl speed`, `bonnie++`, `unixbench`, `hdparm -t`.

Three reasons:

1. **It pollutes business metrics.** Generating CPU/disk/network pressure on a production host
   sets off monitoring alerts, and whoever is on call has no idea you caused it.
2. **It can genuinely affect production.** A disk write test can fill the disk; a memory test
   can trigger the OOM killer.
3. **The result is useless.** "How many points this host scores" tells you nothing about an
   operational decision. To judge "is capacity sufficient", you look at current load and
   headroom, not a benchmark score.

One look at TCP handshake latency is all the connectivity measurement needed (initiated locally,
zero remote load): `scripts/tcping.sh -H <host> -p 22`.

These commands are classified as dangerous and `ssh_exec.sh` **refuses them by default** — the
rule is implemented as a mechanism.

### Cost Discipline for the Collector

These are not fastidiousness; each one corresponds to a real trap:

- **No `docker system df`**: it walks every image and volume and is the single slowest step in
  collection.
- **`df` must carry `-l`**: without it, one stale NFS/autofs mount can block `df` for minutes.
- **`lsblk` without `-f`**: `-f` triggers `blkid` probing on unmounted devices; filesystem
  information comes from `findmnt` instead (which only reads `/proc/self/mountinfo` and never
  probes a device).
- **Anything needing root is explicitly recorded as `unknown reason=needs_root`**: `ufw status`,
  `firewall-cmd`, `iptables -S`, `sshd -T` all fail silently without root. Never write "can't
  read it" as "there are no rules" — that is a dangerous false negative in a security
  assessment.
- **`/sys/class/net/*/speed`** returns EINVAL on a downed interface → record unknown, and do not
  fall back to `ethtool`.
- **Check `command -v` before probing a language runtime**: `java -version` starts a JVM
  (~0.2–1s), and spawning a process for a runtime that doesn't exist is not worth it.
- **`docker ps` often fails on socket permissions for a non-root user** → record
  `docker=present,inaccessible`. That is a completely different meaning from `docker=absent`,
  and is handled differently.

## The Completeness Sentinel

Collection runs over a **single** SSH stream. When it is cut short by a timeout (`rc=124`), the
partial output is **still printed**, so the collector always emits `profile_complete=1` as its
final line. Without that line `profile_store.sh` **refuses to store the result**, keeping only a
`.partial` file for diagnosis.

Without this gate, one slow query silently poisons the cache — and the entire premise of the
design is that the cache is trustworthy. Better to report "collection failed" than to hand back
a profile that looks complete but is missing half its contents.

`schema_version` / `collector_sha256` also provide the basis for automatic re-collection after
the collector itself changes.

## Identity: Why IP Alone Is Not Enough

IPs get recycled and reused after a reinstall; behind NAT several machines share one egress IP;
different ports on the same IP can be entirely different machines or accounts. Therefore:

- **The primary criterion is the host-key fingerprint** — read the record the client **actually
  verified**, from `known_hosts` via `ssh-keygen -F`, rather than re-running `ssh-keyscan`:
  keyscan is unauthenticated and can be MITM'd independently of the real key. Note that entries
  for non-22 ports take the form `[host]:port`.
- **`machine_id` is corroboration only.** It is absent on Alpine/OpenRC, **identical** across
  clones of a golden image, and overwritten by `/run/machine-id` inside containers so that it
  **changes on every boot**.
- On a `machine_id` mismatch the script **refuses to overwrite**, saving a
  `<target>.m2.profile` and warning instead. Once you have confirmed it really was a reinstall
  or a different machine, delete the old profile with `forget` or overwrite with `--force`.
- A changed host-key fingerprint raises a warning — it could be a reinstall, or it could be a
  man in the middle. Either way it is worth stopping to look.

## Freshness: Free Reboot Detection

Profiles store `boot_id` and `uptime_s`. Reading `/proc/sys/kernel/random/boot_id` once on
connect tells you whether the machine has rebooted since collection:

```bash
scripts/profile_store.sh check -H web1
```

- **No reboot** → the profile baseline (including the cumulative `/proc/diskstats` counters) is
  still valid; keep using it.
- **Rebooted** → `runtime`/`services`/`storage` are invalid (the diskstats counters reset), but
  `identity` and `hw` **remain perfectly good** — there is no reason to re-read the CPU model
  because of a reboot.

This is far cheaper than "re-collect everything every N days", and more honest than checking
nothing.

## Refresh Rules

After a change you do **not** need a full re-collection; invalidate only the affected sections:

| What you did | Sections invalidated |
|---|---|
| `docker compose up/down`, added or removed containers | `docker,services` |
| `systemctl restart`, service config changes | `services` |
| Installed or removed packages | `services,runtimes` |
| Firewall changes | `security` |
| Mounted a disk / changed partitions | `storage` |
| User changes | `security,services` |
| nginx/httpd config changes | `services,runtimes` |

After a successful mutating command `ssh_exec.sh` marks sections stale **automatically**
according to this table; it does not depend on anyone remembering. By hand:

```bash
scripts/profile_store.sh mark-stale -H web1 --sections docker --reason "swapped image"
scripts/profile_store.sh collect  -H web1 --sections docker,services   # re-collect just these
```

`identity` and `hw` essentially never go stale, unless the machine is replaced.

`collect --sections a,b` is a **partial** refresh: the sections you did not name are carried
over from the existing profile unchanged, and only the named ones are rewritten. Run `collect`
with no `--sections` for a full refresh, which replaces the whole fact set.

## Security: An Honest Account

- **Never `source` or `eval` a profile.** Values come from the remote host (container names,
  image tags, mount paths, os-release strings), so a hostile container name is a local code
  execution vector. Parsing only ever uses `IFS='='` `read` line by line, and validates that
  keys match `^[A-Za-z_][A-Za-z0-9_]*$`.
- **Strip trailing CR when reading.** Users will open these files in Notepad or PowerShell. The
  same applies to the credential file: `sshpass -f` does not strip CR and would submit a
  password with a trailing `\r`.
- **Writes are atomic (`tmp` + `mv`)**, because batch execution forks multiple `ssh_exec.sh`
  processes concurrently.
- **`chmod 0600` is often a no-op under Git-Bash.** Measured on this machine: the disk mounts
  carry `noacl`, and `stat` returns `644` after both `chmod 600` and `chmod 777` — the
  permission bits simply don't move, let alone Windows ACLs. So:

  | What you see | What it actually means |
  |---|---|
  | `chmod 0600` succeeds with no error | Effective on a Linux target; usually ineffective on a Git-Bash mount |
  | `stat -c '%a'` reports 644 | Not a bug — this mount doesn't support permission bits |

  The real boundary is the ACL on `%USERPROFILE%`, not the file mode. And any process running as
  the same Windows user (including this agent) can read the file. `ssh_exec.sh` measures and
  **reports the actual permissions** when saving credentials rather than printing a reassuring
  "0600". **Do not treat file permissions as a security boundary** — not persisting by default is.

## Command Reference

```bash
# First contact
scripts/profile_store.sh collect -H 203.0.113.10 -u root --prompt-credential --note "prod web frontend"

# Query the profile (local, no network)
scripts/profile_store.sh find -H web1
scripts/profile_store.sh show -H web1 --short
scripts/profile_store.sh show -H web1 --fields os,cpu_model,docker_container
scripts/profile_store.sh list

# Freshness
scripts/profile_store.sh check -H web1

# Maintenance
scripts/profile_store.sh set -H web1 --note "prod DB, hands off"
scripts/profile_store.sh mark-stale -H web1 --sections docker --reason "..."
scripts/profile_store.sh forget -H web1

# Collect only some sections / see collector options
scripts/profile_store.sh collect -H web1 --sections identity,hw
scripts/ssh_exec.sh -H web1 -f scripts/server_profile.sh -A "--sections docker" -t 60
```
