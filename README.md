# ssh-server-manager

一个面向 Claude Code 的 **SSH 服务器运维 Skill**：把「远程操作如何不闯祸」写成可执行的机制，
而不是靠自觉。

它支持**账号密码直接登录**（不需要先配密钥），把风险分级、二次确认、审计留痕、
服务器档案缓存、连接诊断这些事做成了脚本里的默认行为。

[English summary](#english) · [SKILL.md](SKILL.md) · [故障排查手册](references/troubleshooting.md)

---

## 它解决什么问题

远程运维有三件事天然容易出事：

1. **远程操作很难撤销。** 本地删错可能有快照，远端 `rm -rf` 通常什么都没有。
2. **改 SSH / 防火墙会把自己锁在外面。** 改错一行 `sshd_config`，唯一的退路只剩云控制台的 VNC。
3. **批量会把错误放大。** 对 1 台是改动，对 50 台是事故。

所以这个 skill 的三条硬规则是：**先只读侦察再动手**、**改 SSH/防火墙前先留退路**、
**批量执行前先打印确切目标清单**。其余流程按需取用，不搞固定套路。

## 特性

| 能力 | 说明 |
|---|---|
| 🔐 密码登录开箱即用 | 走 ssh 自带的 `SSH_ASKPASS`，**不需要 sshpass**；口令不进命令行、不进 `ps`、不进审计日志 |
| 🧭 风险分级 | 只读 / 变更 / 高危三级；高危命令默认拒绝，必须显式 `--confirm-danger` |
| 📝 审计日志 | 每条远程命令记 `时间 \| 主机 \| 风险级 \| 退出码 \| 耗时 \| 命令` |
| 🗂 服务器档案 | 首次接触采集一次硬件/服务/磁盘基线，之后查本地缓存，不重复侦察；身份用 machine_id + 主机密钥指纹校验 |
| 🩺 一键巡检 | `health_check.sh` 输出结构化报告，末尾给 `SSHMGR_VERDICT=OK\|WARN\|CRIT` |
| 🔌 连接诊断 | 把 ssh 报错翻译成「下一步查什么」；`--selftest` 一屏自检环境 |
| 🚫 拒绝压测 | `sysbench`/`fio`/`stress-ng` 等基准测试被判为高危并默认拒绝——生产机上跑压测既污染监控又伤业务 |
| 🧯 配置变更协议 | 备份 → 语法检查 → 自动回滚定时器 → 新会话验证，四步锁死 |
| 🖥 批量执行 | 按 tag 选机器、并发执行、逐台日志、失败清单单独列出 |

## 安装

把整个目录放到 Claude Code 的 skills 目录即可：

```bash
# macOS / Linux
git clone https://github.com/youbilin/ssh-server-manager.git ~/.claude/skills/ssh-server-manager

# Windows (Git-Bash)
git clone https://github.com/youbilin/ssh-server-manager.git "$USERPROFILE/.claude/skills/ssh-server-manager"
```

也可以用软链接或直接复制，关键是让 `SKILL.md` 位于该目录根部。

## 依赖

- **必须**：`ssh`、`scp`、`bash 4+`
- **可选**：`rsync`（大量小文件传输更快）、`python3` + PyYAML（只用于解析多机 inventory）
- 目标机需为 Linux（Ubuntu/Debian/CentOS/Rocky/Alma）
- Windows 上请在 **Git-Bash** 里跑，不要用 `C:\Windows\System32\OpenSSH\ssh.exe`（它无法执行 shebang 脚本，密码登录会失败）；`ssh_exec.sh --selftest` 会明确指出

## 快速开始

```bash
# 1) 自检本机环境
scripts/ssh_exec.sh --selftest

# 2) 首次连一台机器（密码登录，口令不进 history）
scripts/ssh_exec.sh -H 203.0.113.10 -u root --prompt-credential -c 'uptime'

# 3) 首次接触：采集服务器画像并存档（tcping + 只读采集 + 入库）
scripts/profile_store.sh collect -H 203.0.113.10 -u root --prompt-credential --note "prod web"

# 4) 之后查档案，不联网
scripts/profile_store.sh show -H 203.0.113.10 --short

# 5) 当前状态巡检
scripts/ssh_exec.sh -H 203.0.113.10 -f scripts/health_check.sh -t 180

# 6) 批量执行前先干跑
scripts/batch_run.sh --inventory assets/inventory.example.yaml --tags web --cmd 'uptime' --dry-run
```

## 脚本一览

| 脚本 | 作用 |
|---|---|
| `scripts/ssh_exec.sh` | 远程执行封装：预检、超时、风险分级、审计、错误诊断 |
| `scripts/health_check.sh` | 远端一键巡检（只读），输出结构化报告与结论行 |
| `scripts/batch_run.sh` | 多机执行与汇总（tag 过滤、并发、失败清单） |
| `scripts/backup_config.sh` | 改配置前备份 + 校验 + 打印可执行的还原命令 |
| `scripts/profile_store.sh` | 服务器档案的采集/查询/标脏/重采 |
| `scripts/server_profile.sh` | 远端只读采集器（通常由 profile_store 调用） |
| `scripts/tcping.sh` | 本地 TCP 握手延迟探测，远端零负载 |

每个脚本都支持 `--help`。

## 参考文档

- [`references/troubleshooting.md`](references/troubleshooting.md) —— 按症状组织的故障排查手册（连不上、磁盘/Inode 满、服务起不来、502/504、高负载、OOM、端口占用、证书过期、容器重启循环）
- [`references/common-commands.md`](references/common-commands.md) —— 按场景分组的命令速查
- [`references/hardening.md`](references/hardening.md) —— 安全加固清单，带风险排序与锁死警告
- [`references/server-baseline.md`](references/server-baseline.md) —— 服务器档案的字段、阅读方式、刷新规则
- [`assets/inventory.example.yaml`](assets/inventory.example.yaml) —— 多机 inventory 模板

## 安全说明

- **默认不落盘口令**。只有显式 `--save-credential` 才会写 `~/.ssh-server-manager/credentials`。
- 主机密钥默认严格校验（`StrictHostKeyChecking=yes`）；首次连接用 `--accept-host-key --fingerprint SHA256:...`，
  只有扫描到的指纹与人工核对过的值一致才写入。
- `~/.ssh-server-manager/`（档案、审计日志、凭据、连接复用 socket）**不要提交到仓库或贴到公开场合**，
  已包含在 `.gitignore` 中。
- **不要用 `sshpass -p`**：口令会出现在 `ps` 输出里。
- Git-Bash 的磁盘挂载通常是 `noacl`，`chmod 600` 对权限位是空操作，真正的边界是 Windows 账户 ACL。
  「默认不持久化口令」才是实际的保护。

## English

`ssh-server-manager` is a Claude Code skill for operating remote Linux hosts over SSH.
It supports password login out of the box (via ssh's own `SSH_ASKPASS`, no sshpass needed),
classifies every command into read-only / mutating / dangerous tiers, refuses dangerous
commands unless `--confirm-danger` is passed, audit-logs every remote command, caches a
per-host profile collected on first contact, and ships a troubleshooting handbook.
Stress-test and benchmark tools are classified as dangerous and refused by default.

Requires `ssh`, `scp`, `bash 4+`; `rsync` and `python3` are optional.

## 许可

未指定许可证。如需复用，请先联系仓库所有者。
