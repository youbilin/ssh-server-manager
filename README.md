<div align="center">

# ssh-server-manager

**Safety-first SSH operations for Linux servers — packaged as a Claude Code skill.**

Read-only reconnaissance before action · risk-tiered command gating · append-only audit trail ·
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
- Batch runs print the exact target list and require `--yes` for **every** mutating run; each
  run writes to a unique output directory with per-host logs.

Password authentication works **without `sshpass`**, through OpenSSH's own `SSH_ASKPASS`
mechanism, because a one-off login should not require generating a key pair first.

## Features

| | Capability | What it does |
|---|---|---|
| 🔐 | Password login, no `sshpass` | Credentials reach `ssh` through a private askpass helper — never argv, `ps`, shell history, or the audit log |
| 🧭 | Risk tiering | Read-only / mutating / dangerous; tier 2 requires `--confirm-danger`, tier 1 warns with blast radius |
| 📝 | Audit log | `timestamp \| host \| tier \| exit code \| duration \| command`, escaped and appended by the wrapper itself |
| 🗂 | Server profiles | One-time collection of slow-moving facts; fingerprint-first identity; per-port files; local `compare` |
| 🩺 | One-shot inspection | Structured report ending in `SSHMGR_VERDICT=OK\|WARN\|CRIT`; thresholds pass via `-A "--disk-warn 75"`; systemd and OpenRC service checks |
| 🔌 | Failure diagnosis | Translates `ssh` errors into the next diagnostic step; `--selftest` validates the local environment |
| 🚫 | Benchmark refusal | `sysbench`/`fio`/`stress-ng`/`iperf3` are tier 2 by default — load tests on production corrupt metrics and can OOM a host |
| 🧯 | Config-change protocol | Backup → syntax check → rollback timer → verify in a second session; the printed restore line already carries the ssh prefix |
| 🖥 | Batch execution | Tag-based selection, bounded concurrency, per-host logs, explicit failure list, per-host auth |
| 🌐 | Zero remote load for latency | TCP handshake probing runs locally and detects transparent proxies that would falsify the numbers |
| ✅ | Offline regression suite | `tests/run.sh` uses a fake ssh/keyscan/docker and needs no network; CI runs on Linux, macOS and Git-Bash |

## Requirements

**Local machine**

- `ssh`, `scp`, and `bash` 4.0 or newer
- Optional: `rsync` (many small files), `python3` with PyYAML (multi-host inventory parsing only)

**Target hosts**

- Linux with systemd — Ubuntu/Debian, RHEL/CentOS/Rocky/Alma
- Alpine/OpenRC is supported when `bash` is installed on the target (`apk add bash`); the
  remote scripts are piped in as `ssh host bash -s`, so ash-only Alpine fails the preflight
  with an explicit message
- Service inspection supports systemd and OpenRC; package inspection/updates support
  apt/dnf/yum and apk

**Windows**

Run inside **Git-Bash**, not PowerShell with the native OpenSSH client. The native `ssh.exe`
cannot execute shebang scripts, so the askpass helper fails and password login breaks.
`scripts/ssh_exec.sh --selftest` detects and reports this case.

## Installation

The repository ships two builds of the same skill. `codex/scripts`, `codex/references`,
`codex/assets` and `codex/LICENSE.txt` are generated byte-for-byte from the root directories;
only the `SKILL.md` (harness-specific path/approval guidance) and `agents/openai.yaml` are
maintained separately.

| Harness | Skill folder in this repo | Install to |
|---|---|---|
| Claude Code | repository root | `~/.claude/skills/ssh-server-manager` |
| Codex | [`codex/`](codex/) | `~/.agents/skills/ssh-server-manager` |

**Claude Code**

```bash
# macOS / Linux
git clone https://github.com/youbilin/ssh-server-manager.git ~/.claude/skills/ssh-server-manager

# Windows (Git-Bash)
git clone https://github.com/youbilin/ssh-server-manager.git "$USERPROFILE/.claude/skills/ssh-server-manager"
```

**Codex**

```bash
git clone https://github.com/youbilin/ssh-server-manager.git /tmp/ssm
mkdir -p ~/.agents/skills
cp -r /tmp/ssm/codex ~/.agents/skills/ssh-server-manager
```

Or, for a single project only, copy `codex/` to `<repo>/.agents/skills/ssh-server-manager`.
Codex scans `.agents/skills` from the current directory up to the repository root, plus
`~/.agents/skills` for personal skills.

`SKILL.md` must sit at the root of the installed folder. A symlink works equally well if you prefer
to keep the working copy elsewhere.

### What differs between the two builds

| | Claude Code build | Codex build |
|---|---|---|
| Frontmatter | `name`, `description`, `compatibility` | `name`, `description` only |
| Path resolution | `SKILL_DIR` bootstrap in the skill body | Explicit `$SKILL_DIR`, since Codex does not expand a skill placeholder |
| Invocation | Model-invoked from the description | Same, plus `agents/openai.yaml` UI metadata |
| Sandbox guidance | — | Notes that Codex approval prompts are not a substitute for the remote-change confirmation, and that a sandboxed network error must be reported rather than worked around |
| Launch | `bash "$SKILL_DIR/scripts/ssh_exec.sh" …` | Same |

## Quick start

Set `SKILL_DIR` to the installed skill folder (the one containing `SKILL.md`); the examples
below use it so they work from any working directory.

```bash
SKILL_DIR="$HOME/.claude/skills/ssh-server-manager"

# 1. Validate the local environment: ssh flavour, askpass support, timeout, tools, multiplexing.
#    This does not connect anywhere and does not read credentials.
bash "$SKILL_DIR/scripts/ssh_exec.sh" --selftest

# 2. First contact with a new host: print the scanned fingerprints, compare them with the
#    cloud console, then write only the fingerprint you actually verified.
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H 203.0.113.10 --show-host-key
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H 203.0.113.10 \
  --accept-host-key --fingerprint SHA256:xxxx

# 3. Connect with a password — the prompt never enters shell history.
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H 203.0.113.10 -u root \
  --prompt-credential -c 'uptime'

# Optional: save it once for explicit later reuse.
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H 203.0.113.10 -u root \
  --prompt-credential --save-credential -c 'uptime'
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H 203.0.113.10 -u root \
  --use-saved-credential -c 'uptime'

# 4. First contact: probe latency, collect a read-only profile, store it.
bash "$SKILL_DIR/scripts/profile_store.sh" collect -H 203.0.113.10 -u root \
  --prompt-credential --note "prod web frontend"

# 5. Later: read the cached profile, no network traffic.
bash "$SKILL_DIR/scripts/profile_store.sh" show -H 203.0.113.10 --short

# 6. Current state rather than static facts.
bash "$SKILL_DIR/scripts/ssh_exec.sh" -H 203.0.113.10 \
  -f "$SKILL_DIR/scripts/health_check.sh" -t 180

# 7. Preview a batch before running it.
bash "$SKILL_DIR/scripts/batch_run.sh" \
  --inventory "$SKILL_DIR/assets/inventory.example.yaml" --tags web \
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
ssh_exec.sh -H web1 --dry-run -c 'rm -rf /tmp/x'        # show the tier; no connection, no credentials
ssh_exec.sh --print-tier -c 'systemctl restart nginx'   # machine-readable tier: 0/1/2
ssh_exec.sh -H web1 --show-host-key                     # print fingerprints, write nothing
```

Key options: `-u/--user`, `-p/--port`, `-J/--jump`, `-i/--identity`, `-t/--timeout`,
`--preflight`, `--confirm-danger`, `--accept-host-key --fingerprint SHA256:…`,
`--show-host-key`, `--dry-run`, `--print-tier`, `--no-log`, `-q/--quiet`.

`--accept-host-key` requires the complete `--fingerprint` value, matches it exactly, and writes
only that one key line. It works without `-c` and exits after writing. `--dry-run`,
`--print-tier` and `--selftest` never authenticate or read credentials.

Authentication: `--auth auto|key|password`, `--prompt-credential`, `--password-env VAR`,
`--credential-file FILE`, `--use-saved-credential`, `--save-credential`.

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
counts), `--strict` (exit `1` on WARN, `2` on CRIT), and the threshold flags below.

```bash
# Local environment variables are not forwarded over ssh; pass thresholds through -A.
ssh_exec.sh -H web1 -f scripts/health_check.sh \
  -A '--disk-warn 75 --disk-crit 85 --load-warn 1.5' -t 180
```

Threshold flags: `--disk-warn/--disk-crit`, `--inode-warn/--inode-crit`,
`--load-warn/--load-crit`, `--mem-warn/--mem-crit`. The equivalent `SSHMGR_*` environment
variables work when the script is run directly on the host.

Only containers that are `Exited`, `Restarting`, `Dead`, `Paused`, `Created`, or `(unhealthy)` are
reported. A running container without a healthcheck is normal and is not flagged.

### `batch_run.sh` — multi-host execution

```bash
batch_run.sh --hosts 'web1 web2' --cmd 'df -h' --parallel 2
batch_run.sh --hosts-file hosts.txt --cmd 'systemctl is-active nginx'
batch_run.sh --inventory inv.yaml --tags web --cmd 'uptime' --dry-run
batch_run.sh --from-ssh-config 'web*' --cmd 'uptime'
```

Every host executes through `ssh_exec.sh`, so tiering and audit logging apply unchanged. Output is
grouped per host; failing hosts are listed separately and always dumped in full. Any mutating run
needs `--yes`; dangerous commands also need `--confirm-danger`. Each run gets a unique
`~/.ssh-server-manager/batch-<UTC>.<random>/` directory with per-host logs named by index, so
aliases cannot become paths. Inventory entries may set `auth: auto|key|password`; `--auth`
overrides it for every host. `--parallel 1 --stop-on-error` is the recommended first run; with
higher concurrency, up to N already-started hosts will finish after a failure is detected.

### `backup_config.sh` — pre-change backup

```bash
backup_config.sh -H web1 -f /etc/nginx/nginx.conf
backup_config.sh -H web1 -d /etc/nginx/sites-enabled --sudo
backup_config.sh -H web1 -f /etc/nginx/nginx.conf --list
```

Copies with a UTC timestamp, verifies the SHA-256 against the source, and prints a restore
command with the ssh prefix already attached, followed by the matching syntax check and reload.
`--keep N` keeps the newest N backups and requires `N >= 1` (0 is rejected rather than deleting
the backup that was just created). Password-authentication flags are passed through to the
wrapper.

### `profile_store.sh` — server profiles

```bash
profile_store.sh collect -H web1 --sections docker,services   # partial refresh
profile_store.sh find | show | list | check | compare | set | mark-stale | forget
profile_store.sh compare -H web1,web2
```

Profiles are flat `key=value` files under `~/.ssh-server-manager/profiles/`, named
`<target>.profile` or `<target>_<port>.profile`. A collection with `--sections` is a **partial**
refresh — unnamed sections are carried over untouched, and only the refreshed sections are
cleared from `stale_sections`. Omitting `--sections` replaces the whole fact set.

Lookups are exact-line matches (`web1` does not match `web10`); when a host has profiles for
multiple ports, pass `-p` rather than letting the script guess. `collect` and `check` accept the
same password flags as `ssh_exec.sh` and reuse stored user/port/jump/identity metadata. The store
is created with `umask 077`. `set --note "..."` updates the note; collector-maintained fields
(`machine_id`, `boot_id`, `ssh_*`, timestamps, fingerprints) are protected.

### `server_profile.sh` — remote collector

Runs on the target host and is normally invoked through `profile_store.sh`. Read-only; the
`# sshmgr:read-only` marker in its header is what exempts it from the mutating tier. It records
`init_system=systemd|openrc` and supports Alpine/OpenRC when bash is installed.

### `tcping.sh` — local latency probe

```bash
tcping.sh -H 203.0.113.10 -p 22 -n 4
```

Performs TCP handshakes locally and produces no remote load. A control probe against
`192.0.2.1:9` (TEST-NET-1, guaranteed unreachable) detects transparent proxies; if that probe
succeeds, results are labelled `reliable=0` rather than presented as authoritative.

## How the safety model works

**Risk tiers.** Commands are split on unquoted separators, stripped of `sudo`/`env`/`timeout`
prefixes, and classified by the command actually being run and its write targets. This is a
guardrail, not a sandbox — interpreter one-liners (`python -c ...`) and dynamically assembled
commands cannot be classified reliably. `--print-tier` exposes the result as `0/1/2` for scripts.

| Tier | Examples | Behaviour |
|---|---|---|
| 0 — read-only | `df`, `systemctl status`, `journalctl`, `ss`, `docker ps` | Runs directly |
| 1 — mutating | `systemctl restart`, package installs, `chmod`, `sed -i`, `docker compose up` | Warns with blast radius; affected profile sections are marked stale automatically |
| 2 — dangerous | `rm -r`, `mkfs`, `dd`, `iptables -F`, `ufw disable`, `sshd_config`/`fstab`/`sudoers` edits, `DROP DATABASE`, benchmark suites | Refused unless `--confirm-danger` is passed |

Read-only commands that merely mention a dangerous word (`cat /etc/ssh/sshd_config`,
`journalctl | grep reboot`, `ps aux | grep fio`) stay at tier 0.

**Host keys.** Verification stays strict. First contact uses
`--show-host-key` to print candidates, then `--accept-host-key --fingerprint SHA256:…` with the
complete fingerprint. Only the matching key line is written; a partial or mismatched fingerprint
is rejected, and an existing `known_hosts` entry with a different key is never overwritten
silently. Target aliases and ports are resolved through `ssh -G`.

**Config changes.** Backup → syntax check (`nginx -t`, `sshd -t`, `visudo -c`, `findmnt --verify`)
→ arm an automatic rollback timer → verify in a second session while keeping the first one open.

**Profiles.** Identity is the host-key fingerprint actually verified by the client, with
`machine_id` as corroboration, not the IP — addresses are recycled and NAT blurs them. A mismatch
in either writes a separate `.m2.profile` and exits 3 instead of overwriting; `--force` overrides
after you have confirmed the change. Non-22 ports get their own `<target>_<port>.profile`.

## Security model

- **Credentials are not persisted by default.** Only `--save-credential` writes
  `~/.ssh-server-manager/credentials`; it is reused only when `--use-saved-credential` is given
  explicitly, never implicitly. Storing nothing is the protection; file modes are not.
- **`sshpass -p` is never used** — it exposes the password in `ps` output.
- **`--selftest` and `--dry-run` do not read credentials** and cannot leave password temp files.
- **`chmod 600` is often a no-op under Git-Bash.** Mounts there carry `noacl`, so permission bits do
  not move and Windows ACLs are untouched. The scripts report the measured mode instead of
  printing a reassuring `0600`. The profile store uses `umask 077` on POSIX filesystems.
- **Profiles, audit logs, and credentials contain infrastructure detail** — IPs, hostnames, image
  lists. They live in `~/.ssh-server-manager/`, excluded from this repository by `.gitignore`.
  Do not commit or paste them.
- **Profile files are never `source`d or `eval`ed.** Values originate from the remote host, so a
  malicious container name would otherwise be local code execution.
- **The audit log is append-only, not immutable.** Anyone who can write the file can edit it;
  ship it off-box if compliance requires tamper evidence.

## Documentation

| Document | Contents |
|---|---|
| [`SKILL.md`](SKILL.md) | The skill definition and operating rules Claude Code loads |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Symptom-indexed handbook: connectivity, disk and inode exhaustion, service failures, 502/504, high load, OOM, port conflicts, certificate expiry, container restart loops |
| [`references/common-commands.md`](references/common-commands.md) | Command reference grouped by scenario |
| [`references/hardening.md`](references/hardening.md) | Hardening checklist ordered by risk, with lockout warnings |
| [`references/server-baseline.md`](references/server-baseline.md) | Profile fields, reading rules, and refresh semantics |
| [`assets/inventory.example.yaml`](assets/inventory.example.yaml) | Multi-host inventory template with tags and jump-host examples |
| [`tests/`](tests/) | Offline regression suite: risk tiers, credential lifecycle, host keys, profiles, backup, health, batch, fake SSH/Docker |

## Repository layout

```
.
├── SKILL.md                      # Claude Code skill definition
├── README.md
├── LICENSE
├── codex/                        # Codex build of the same skill
│   ├── SKILL.md                  # Codex skill definition (name + description only)
│   ├── agents/openai.yaml        # Codex UI metadata
│   ├── LICENSE.txt
│   └── scripts|references|assets # copies of the shared material
├── scripts/
│   ├── ssh_exec.sh               # execution wrapper (tiering, audit, diagnosis)
│   ├── health_check.sh           # remote inspection
│   ├── batch_run.sh              # multi-host runner
│   ├── backup_config.sh          # pre-change backup and restore command
│   ├── profile_store.sh          # local profile store
│   ├── server_profile.sh         # remote profile collector
│   ├── tcping.sh                 # local TCP latency probe
│   └── lib/                      # risk classifier + ssh -G target resolver
├── references/                   # on-demand knowledge documents
├── assets/                       # inventory template
├── tests/                        # offline regression suite + fake bins
├── tools/build-codex.sh          # regenerate/verify the Codex shared copy
├── evals/                        # skill evaluation fixtures
└── .github/workflows/ci.yml      # Linux/macOS/Git-Bash + shellcheck + sync check
```

## Testing

```bash
bash tests/run.sh
```

The suite needs no network and no real host: fake `ssh`, `ssh-keyscan` and `docker` are used,
with host keys generated locally. It covers risk classification, dry-run/selftest side effects,
credential temp files, exact host-key matching, profile port/lookup/stale/identity behavior,
restore-command generation, Docker health classification, batch confirmation/stop behavior, and
systemd/OpenRC service detection. CI runs the same suite on Ubuntu, macOS and Windows (Git-Bash),
plus `shellcheck`, a BSD/onetrue-awk profile pass, and a Codex-copy sync check. Alpine/OpenRC
targets need `bash` installed (`apk add bash`).

## Contributing

Issues and pull requests are welcome. The scripts target `bash` 4 and must keep working on macOS,
Linux, and Git-Bash on Windows. Run `bash tests/run.sh` and
`bash scripts/ssh_exec.sh --selftest` before submitting. Please preserve the
`# sshmgr:read-only` header marker on read-only collectors — the wrapper relies on it for tiering.

`codex/scripts`, `codex/references`, `codex/assets`, and `codex/LICENSE.txt` are generated from
the root files. After editing the shared material, run:

```bash
bash tools/build-codex.sh          # regenerate
bash tools/build-codex.sh --check  # verify, same check CI runs
```

Only `codex/SKILL.md` and `codex/agents/openai.yaml` are maintained separately for the Codex
harness.

## License

Released under the [MIT License](LICENSE). Copyright © 2026 You Bilin.
