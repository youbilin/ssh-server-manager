<div align="center">

# ssh-server-manager

**Safety-first SSH operations for Linux servers — packaged as a Claude Code skill.**

Read-only reconnaissance before action · risk-tiered command gating · immutable audit trail ·
cached per-host server profiles

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash%204%2B-4EAA25?logo=gnubash&logoColor=white)](#requirements)
[![Target](https://img.shields.io/badge/target-Linux-0b7285?logo=linux&logoColor=white)](#requirements)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-skill-d97757)](https://claude.com/claude-code)

[Overview](#overview) · [Install](#installation) · [Quick start](#quick-start) · [Scripts](#script-reference) · [Safety model](#how-the-safety-model-works) · [Security](#security-model) · [Docs](#documentation)

</div>

---

## Overview

`ssh-server-manager` is a [Claude Code](https://claude.com/claude-code) skill for operating remote
Linux hosts over SSH. It exists because three properties of remote work make the conventional
"run the command and see what happens" workflow unsafe:

| Property | Consequence |
|---|---|
| Remote actions are hard to undo | A local `rm` may have a snapshot behind it; a remote `rm -rf` usually has nothing |
| SSH and firewall changes can lock you out | One wrong line in `sshd_config` and the only remaining path is the provider console |
| Batch operations multiply mistakes | One command on one host is a change; on fifty hosts it is an incident |

Each safety rule is implemented as a **mechanism in the scripts**, not as prose the model is asked
to remember:

- Dangerous commands — recursive deletes, filesystem creation, firewall flushes, disk-level writes,
  `sshd_config` edits, SIGKILL on PID 1, benchmark suites — are **refused** unless
  `--confirm-danger` is supplied explicitly.
- Every remote command is appended to an audit log, so "who changed what, when" has an answer.
- A first-contact profile records hardware, services, and disk baselines once, so later work reads
  cache instead of re-reconnoitering a production host.
- Batch runs print the exact target list and require an explicit confirmation flag above ten
  mutating targets.

Password authentication works **without `sshpass`**, through OpenSSH's own `SSH_ASKPASS`
mechanism, because a one-off login should not require generating a key pair first.

## Features

| | Capability | What it does |
|---|---|---|
| 🔐 | Password login, no `sshpass` | Credentials reach `ssh` through a private askpass helper — never argv, `ps`, shell history, or the audit log |
| 🧭 | Risk tiering | Read-only / mutating / dangerous; tier 2 requires `--confirm-danger`, tier 1 warns with blast radius |
| 📝 | Audit log | `timestamp \| host \| tier \| exit code \| duration \| command`, written by the wrapper itself |
| 🗂 | Server profiles | One-time collection of slow-moving facts; identity verified by `machine_id` and host-key fingerprint |
| 🩺 | One-shot inspection | Structured health report ending in a machine-readable `SSHMGR_VERDICT=OK\|WARN\|CRIT` |
| 🔌 | Failure diagnosis | Translates `ssh` errors into the next diagnostic step; `--selftest` validates the local environment |
| 🚫 | Benchmark refusal | `sysbench`/`fio`/`stress-ng`/`iperf3` are tier 2 by default — load tests on production corrupt metrics and can OOM a host |
| 🧯 | Config-change protocol | Backup → syntax check → rollback timer → verify in a second session |
| 🖥 | Batch execution | Tag-based selection, bounded concurrency, per-host logs, explicit failure list |
| 🌐 | Zero remote load for latency | TCP handshake probing runs locally and detects transparent proxies that would falsify the numbers |

## Requirements

**Local machine**

- `ssh`, `scp`, and `bash` 4.0 or newer
- Optional: `rsync` (many small files), `python3` with PyYAML (multi-host inventory parsing only)

**Target hosts**

- Linux with systemd — Ubuntu/Debian, RHEL/CentOS/Rocky/Alma
- `bash` on the remote side; scripts are piped in as `ssh host bash -s`

**Windows**

Run inside **Git-Bash**, not PowerShell with the native OpenSSH client. The native `ssh.exe`
cannot execute shebang scripts, so the askpass helper fails and password login breaks.
`scripts/ssh_exec.sh --selftest` detects and reports this case.

## Installation

The skill is a directory. Clone it into your Claude Code skills path:

```bash
# macOS / Linux
git clone https://github.com/youbilin/ssh-server-manager.git ~/.claude/skills/ssh-server-manager

# Windows (Git-Bash)
git clone https://github.com/youbilin/ssh-server-manager.git "$USERPROFILE/.claude/skills/ssh-server-manager"
```

`SKILL.md` must sit at the root of that directory. A symlink works equally well if you prefer to
keep the working copy elsewhere.

## Quick start

```bash
# 1. Validate the local environment: ssh flavour, askpass support, timeout, multiplexing
scripts/ssh_exec.sh --selftest

# 2. Connect with a password — the prompt never enters shell history
scripts/ssh_exec.sh -H 203.0.113.10 -u root --prompt-credential -c 'uptime'

# 3. First contact: probe latency, collect a read-only profile, store it
scripts/profile_store.sh collect -H 203.0.113.10 -u root \
  --prompt-credential --note "prod web frontend"

# 4. Later: read the cached profile, no network traffic
scripts/profile_store.sh show -H 203.0.113.10 --short

# 5. Current state rather than static facts
scripts/ssh_exec.sh -H 203.0.113.10 -f scripts/health_check.sh -t 180

# 6. Preview a batch before running it
scripts/batch_run.sh --inventory assets/inventory.example.yaml --tags web \
  --cmd 'uptime' --dry-run
```

## Script reference

All scripts support `--help`.

### `ssh_exec.sh` — remote execution wrapper

Preflight, timeout, risk classification, audit logging, and error diagnosis in one entry point.

```bash
ssh_exec.sh -H web1 -c 'df -h'                          # read-only
ssh_exec.sh -H web1 --preflight                         # connectivity only
ssh_exec.sh -H web1 -f scripts/health_check.sh -t 180   # run a local script remotely
ssh_exec.sh -H web1 --dry-run -c 'rm -rf /tmp/x'        # show the tier, execute nothing
```

Key options: `-u/--user`, `-p/--port`, `-J/--jump`, `-i/--identity`, `-t/--timeout`,
`--preflight`, `--confirm-danger`, `--accept-host-key --fingerprint SHA256:…`, `--dry-run`,
`--no-log`, `-q/--quiet`.

Authentication: `--auth auto|key|password`, `--prompt-credential`, `--password-env VAR`,
`--credential-file FILE`, `--save-credential`.

Exit codes: `0` success · `124` timeout · `4` dangerous command not confirmed · `1` usage or local
error · `2` connection or authentication failure · any other value is passed through from the
remote command.

### `health_check.sh` — one-shot inspection

Runs **on the target host**. Read-only throughout, and deliberately without `set -e` so a missing
tool degrades to "unavailable" instead of truncating the report.

```bash
ssh_exec.sh -H web1 -f scripts/health_check.sh -t 180
ssh_exec.sh -H web1 -f scripts/health_check.sh -A '--sections cpu,memory,disk' -t 120
ssh_exec.sh -H web1 -f scripts/health_check.sh -A '--deep --updates' -t 300
```

Sections: `identity`, `cpu`, `memory`, `disk`, `network`, `services`, `security`, `logins`,
`docker`, `updates`.

Flags: `--quick` (skip slow collection), `--deep` (directory scans), `--updates` (pending package
counts), `--strict` (exit `1` on WARN, `2` on CRIT).

Thresholds are environment-tunable: `SSHMGR_DISK_WARN`, `SSHMGR_DISK_CRIT`, `SSHMGR_INODE_WARN`,
`SSHMGR_INODE_CRIT`, `SSHMGR_LOAD_WARN`, `SSHMGR_LOAD_CRIT`, `SSHMGR_MEM_WARN`,
`SSHMGR_MEM_CRIT`.

### `batch_run.sh` — multi-host execution

```bash
batch_run.sh --hosts 'web1 web2' --cmd 'df -h' --parallel 2
batch_run.sh --hosts-file hosts.txt --cmd 'systemctl is-active nginx'
batch_run.sh --inventory inv.yaml --tags web --cmd 'uptime' --dry-run
batch_run.sh --from-ssh-config 'web*' --cmd 'uptime'
```

Every host executes through `ssh_exec.sh`, so tiering and audit logging apply unchanged. Output is
grouped per host; failing hosts are listed separately and always dumped in full. Mutating runs need
`--yes` above ten targets; `--parallel 1 --stop-on-error` is the recommended first run.

### `backup_config.sh` — pre-change backup

```bash
backup_config.sh -H web1 -f /etc/nginx/nginx.conf
backup_config.sh -H web1 -d /etc/nginx/sites-enabled --sudo
backup_config.sh -H web1 -f /etc/nginx/nginx.conf --list
```

Copies with a UTC timestamp, verifies the SHA-256 against the source, and prints a ready-to-run
restore command followed by the matching syntax check and reload.

### `profile_store.sh` — server profiles

```bash
profile_store.sh collect -H web1 --sections docker,services   # partial refresh
profile_store.sh find | show | list | check | set | mark-stale | forget
```

Profiles are flat `key=value` files under `~/.ssh-server-manager/profiles/`. A collection with
`--sections` is a **partial** refresh — unnamed sections are carried over untouched. Omitting
`--sections` replaces the whole fact set.

### `server_profile.sh` — remote collector

Runs on the target host and is normally invoked through `profile_store.sh`. Read-only; the
`# sshmgr:read-only` marker in its header is what exempts it from the mutating tier.

### `tcping.sh` — local latency probe

```bash
tcping.sh -H 203.0.113.10 -p 22 -n 4
```

Performs TCP handshakes locally and produces no remote load. A control probe against
`192.0.2.1:9` (TEST-NET-1, guaranteed unreachable) detects transparent proxies; if that probe
succeeds, results are labelled `reliable=0` rather than presented as authoritative.

## How the safety model works

**Risk tiers.** Commands are classified by pattern before execution.

| Tier | Examples | Behaviour |
|---|---|---|
| 0 — read-only | `df`, `systemctl status`, `journalctl`, `ss`, `docker ps` | Runs directly |
| 1 — mutating | `systemctl restart`, package installs, `chmod`, `sed -i`, `docker compose up` | Warns with blast radius; affected profile sections are marked stale automatically |
| 2 — dangerous | `rm -rf`, `mkfs`, `dd`, `iptables -F`, `ufw disable`, `sshd_config` edits, `DROP DATABASE`, benchmark suites | Refused unless `--confirm-danger` is passed |

**Host keys.** Verification stays strict. First contact uses
`--accept-host-key --fingerprint SHA256:…`; a scanned fingerprint that does not match the supplied
value is rejected, and an existing `known_hosts` entry with a different key is never overwritten
silently.

**Config changes.** Backup → syntax check (`nginx -t`, `sshd -t`, `visudo -c`, `findmnt --verify`)
→ arm an automatic rollback timer → verify in a second session while keeping the first one open.

**Profiles.** Identity is `machine_id` plus the host-key fingerprint actually verified by the
client, not the IP — addresses are recycled and NAT blurs them. A mismatch writes a separate
`.m2.profile` and warns instead of overwriting.

## Security model

- **Credentials are not persisted by default.** Only `--save-credential` writes
  `~/.ssh-server-manager/credentials`. Storing nothing is the protection; file modes are not.
- **`sshpass -p` is never used** — it exposes the password in `ps` output.
- **`chmod 600` is often a no-op under Git-Bash.** Mounts there carry `noacl`, so permission bits do
  not move and Windows ACLs are untouched. The scripts report the measured mode instead of
  printing a reassuring `0600`.
- **Profiles, audit logs, and credentials contain infrastructure detail** — IPs, hostnames, image
  lists. They live in `~/.ssh-server-manager/`, excluded from this repository by `.gitignore`.
  Do not commit or paste them.
- **Profile files are never `source`d or `eval`ed.** Values originate on the remote host, so a
  malicious container name would otherwise be local code execution.

## Documentation

| Document | Contents |
|---|---|
| [`SKILL.md`](SKILL.md) | The skill definition and operating rules Claude Code loads |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Symptom-indexed handbook: connectivity, disk and inode exhaustion, service failures, 502/504, high load, OOM, port conflicts, certificate expiry, container restart loops |
| [`references/common-commands.md`](references/common-commands.md) | Command reference grouped by scenario |
| [`references/hardening.md`](references/hardening.md) | Hardening checklist ordered by risk, with lockout warnings |
| [`references/server-baseline.md`](references/server-baseline.md) | Profile fields, reading rules, and refresh semantics |
| [`assets/inventory.example.yaml`](assets/inventory.example.yaml) | Multi-host inventory template with tags and jump-host examples |

## Repository layout

```
.
├── SKILL.md                      # skill definition loaded by Claude Code
├── README.md
├── LICENSE
├── scripts/
│   ├── ssh_exec.sh               # execution wrapper (tiering, audit, diagnosis)
│   ├── health_check.sh           # remote inspection
│   ├── batch_run.sh              # multi-host runner
│   ├── backup_config.sh          # pre-change backup and restore command
│   ├── profile_store.sh          # local profile store
│   ├── server_profile.sh         # remote profile collector
│   └── tcping.sh                 # local TCP latency probe
├── references/                   # on-demand knowledge documents
├── assets/                       # inventory template
└── evals/                        # skill evaluation fixtures
```

## Contributing

Issues and pull requests are welcome. The scripts target `bash` 4 and must keep working on macOS,
Linux, and Git-Bash on Windows. Run `bash -n` over `scripts/*.sh` and
`scripts/ssh_exec.sh --selftest` before submitting. Please preserve the `# sshmgr:read-only` header
marker on read-only collectors — the wrapper relies on it for tiering.

## License

Released under the [MIT License](LICENSE). Copyright © 2026 You Bilin.
