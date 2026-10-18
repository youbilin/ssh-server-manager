#!/usr/bin/env bash
# ssh_exec.sh - 远程命令执行封装：连通性预检、超时、风险分级、审计日志、错误诊断
#
# 设计意图：把「二次确认」和「留痕」做成机制而不是口头约定。
# 高危命令默认拒绝执行，除非显式传 --confirm-danger。
#
# 用法:
#   ./ssh_exec.sh -H web1 -c 'df -h'
#   ./ssh_exec.sh -H web1 -- ls -l /var/log
#   ./ssh_exec.sh -H 10.0.0.5 -u deploy -p 2222 -J bastion -t 60 -c 'uptime'
#   ./ssh_exec.sh -H web1 --preflight
#   ./ssh_exec.sh -H web1 -f ./health_check.sh -t 180      # 本地脚本经 stdin 交给远端 bash
#   ./ssh_exec.sh -H web1 --dry-run -c 'rm -rf /tmp/x'     # 只看风险判定，不执行
#
# 退出码: 0 远端成功 | 124 超时 | 4 高危未确认 | 1 用法/本地错误（含密码模式下没拿到口令）
#        | 2 连接失败或认证失败
#        | 其余 = 远端命令自己的退出码（原样透传）
#        注意 2 同时覆盖"网络不可达"与"认证被拒"—— 脚本会在消息里区分两者，
#        别看到 2 就一律去查安全组，先看那行判定。
#        远端命令如果自己返回 1/2/4/124，与本地错误的码重叠 —— 判定看 stderr 的那行结论，
#        不要只看退出码。

set -uo pipefail
LC_ALL=C

PROG="$(basename "$0")"
# 本脚本所在目录：用于定位同目录的 profile_store.sh / tcping.sh，
# 以及校验"只读脚本声明"是否来自本 skill 自己的 scripts/。
SCRIPT_DIR_SELF="$(cd "$(dirname "$0")" && pwd)"

HOST=""
USER_NAME=""
PORT=""
JUMP=""
IDENTITY=""
COMMAND=""
SCRIPT_FILE=""
SCRIPT_ARGS=""
REMOTE_SCRIPT_CMD="bash -s"
TIMEOUT=30
CONNECT_TIMEOUT=8
PREFLIGHT=0
CONFIRM_DANGER=0
ACCEPT_HOST_KEY=0
FINGERPRINT=""
DRY_RUN=0
DO_LOG=1
QUIET=0
LOG_LABEL=""
NO_PREFLIGHT=0
SELFTEST=0
# 密码认证
AUTH_MODE="auto"          # auto | key | password
PASSWORD_ENV=""           # --password-env VAR
CREDENTIAL_FILE="${SSHMGR_CREDENTIAL_FILE:-}"   # 显式指定
CONFIRM_CRED_FILE=""      # --credential-file F
SAVE_CREDENTIAL=0
PROMPT_CREDENTIAL=0
PASSWORD=""               # 只在内存里；永不进命令行、日志、档案
USED_AUTH=""              # key | password，用于审计与诊断
ASKPASS_HELPER=""         # 临时 helper 路径，由 cleanup 删

# SSHMGR_HOME 与 profile_store.sh 保持一致：两个脚本必须认同一个家目录，
# 否则档案在一处、审计日志和凭据在另一处，排查时会找不到东西。
LOG_DIR="${SSHMGR_HOME:-${SSHMGR_LOG_DIR:-$HOME/.ssh-server-manager}}"
LOG_FILE="${SSHMGR_LOG:-$LOG_DIR/audit.log}"
CRED_FILE_DEFAULT="$LOG_DIR/credentials"

# ---------- 输出 helpers ----------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""
fi

say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
dim()  { [ "$QUIET" -eq 1 ] || printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
# 档案提示走 stderr：stdout 是调用方消费的载荷（batch_run.sh 还会把它截到 40 行），
# 而且只在"可操作"时提示，否则每次连接都刷一行就又成了噪音
hint() { [ "$QUIET" -eq 1 ] || printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }

# ---------- 统一清理 ----------
# ⚠ bash 的 `trap ... EXIT` 是**替换**而不是追加。原脚本在末尾 `trap 'rm -f "$out_file"' EXIT`，
# 若清理口令临时文件的 trap 注册得更早，会被这一句直接顶掉 —— 口令文件就留在磁盘上了。
# 所以全脚本只装这一个 EXIT trap，所有要清理的东西都登记在这里。
OUT_FILE=""
cleanup() {
  [ -n "${OUT_FILE:-}" ] && rm -f "$OUT_FILE" 2>/dev/null
  [ -n "${ASKPASS_HELPER:-}" ] && rm -f "$ASKPASS_HELPER" 2>/dev/null
  [ -n "${PW_TMPFILE:-}" ] && rm -f "$PW_TMPFILE" 2>/dev/null
  export PASSWORD=""
  return 0
}
trap cleanup EXIT INT TERM HUP

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'

选项:
  -H, --host HOST        目标主机（inventory 别名 / ~/.ssh/config 的 Host / user@ip）
  -u, --user USER        登录用户
  -p, --port PORT        SSH 端口（默认沿用 ssh 配置或 22）
  -J, --jump JUMP        ProxyJump 跳板机
  -i, --identity FILE    私钥文件路径（只传路径，不要粘贴私钥内容）
  -c, --command CMD      远程执行的命令
  -f, --script FILE      本地脚本文件，通过 stdin 交给远端 bash -s 执行
  -A, --script-args ARGS 传给该脚本的参数（如 --deep），会拼成 "bash -s -- ARGS"
  -t, --timeout SEC      本次执行的超时秒数（默认 30）
      --connect-timeout S 连接超时秒数（默认 8）
      --preflight        只做连通性检查与错误诊断，不执行任何命令
      --no-preflight     跳过连通性预检直接执行（省一次连接与认证；
                         密码登录时尤其值得用，因为默认会把口令提交两遍）
      --confirm-danger   声明已就高危命令向用户二次确认（否则拒绝执行）
      --accept-host-key  首次连接时把远端指纹写入 known_hosts（须先人工核对指纹）
      --fingerprint FP   配合 --accept-host-key：只有扫描到的指纹与这个值一致才写入。
                         把"核对指纹"从口头承诺变成机制（不一致直接拒绝）
      --dry-run          只打印将执行的命令与风险等级，不执行
      --no-log           不写审计日志（默认写入，用于事故复盘）
  -q, --quiet            只输出远端原始内容，不带装饰（供其他脚本调用）
      --label TEXT       审计日志里记录的操作说明，替代原始命令
                         （脚本模式或包装脚本用它，事后复盘才看得懂日志）
      --selftest         自检：打印 ssh 路径/版本、askpass 支持、/dev/tcp、
                         GNU timeout、ControlMaster 是否可用。连不上时先跑这个
  -h, --help             显示本帮助

认证（密码与密钥是平等的两条路，给什么用什么，不强推密钥）:
      --auth MODE        auto（默认）| key | password
                         auto：有可用密钥就用密钥，否则用密码
                         password：明确走密码，会关掉公钥尝试
      --password-env VAR 从环境变量 VAR 读口令（不进命令行）
      --credential-file F 从文件读口令（建议 0600；会剥掉行尾 CR）
      --prompt-credential 交互式输入口令（read -s，不进 shell history）
      --save-credential  把本次口令存到 ~/.ssh-server-manager/credentials（0600）。
                         默认**不**保存；只有你明确要免密时才加这个参数

环境变量:
  SSHMGR_HOME             家目录（默认 ~/.ssh-server-manager）：审计日志、凭据、档案、连接复用套接字都在它下面
  SSHMGR_LOG_DIR          同上（与 profile_store.sh 共用的兼容名）
  SSHMGR_LOG              审计日志完整路径（优先级更高）
  SSHMGR_PASSWORD         口令（注意：写在命令前面会同时留在 shell history 与对话记录里，
                          只有在你自己的会话里 export 过才更安全）
  SSHMGR_CREDENTIAL_FILE  默认凭据文件路径
  SSHMGR_SSH              指定 ssh 可执行文件（默认从 PATH 解析）
  SSHMGR_ASKPASS_DEBUG=1  把 askpass 收到的 prompt 记到 askpass.log（绝不记口令），
                          用于排查"口令为什么没发出去"
  SSHMGR_NO_MUX=1         关闭连接复用（默认开 ControlMaster，10 分钟内只认证一次）
USAGE
}

# ---------- 参数解析 ----------
need_arg() { [ "$2" -ge 2 ] || { err "选项 $1 需要一个参数"; exit 1; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    -H|--host)         need_arg "$1" $#; HOST="$2"; shift 2 ;;
    -u|--user)         need_arg "$1" $#; USER_NAME="$2"; shift 2 ;;
    -p|--port)         need_arg "$1" $#; PORT="$2"; shift 2 ;;
    -J|--jump)         need_arg "$1" $#; JUMP="$2"; shift 2 ;;
    -i|--identity)     need_arg "$1" $#; IDENTITY="$2"; shift 2 ;;
    -c|--command)      need_arg "$1" $#; COMMAND="$2"; shift 2 ;;
    -f|--script)       need_arg "$1" $#; SCRIPT_FILE="$2"; shift 2 ;;
    -A|--script-args)  need_arg "$1" $#; SCRIPT_ARGS="$2"; shift 2 ;;
    -t|--timeout)      need_arg "$1" $#; TIMEOUT="$2"; shift 2 ;;
    --connect-timeout) need_arg "$1" $#; CONNECT_TIMEOUT="$2"; shift 2 ;;
    --preflight)       PREFLIGHT=1; shift ;;
    --no-preflight)    NO_PREFLIGHT=1; shift ;;
    --confirm-danger)  CONFIRM_DANGER=1; shift ;;
    --accept-host-key) ACCEPT_HOST_KEY=1; shift ;;
    --fingerprint)     need_arg "$1" $#; FINGERPRINT="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --no-log)          DO_LOG=0; shift ;;
    --label)           need_arg "$1" $#; LOG_LABEL="$2"; shift 2 ;;
    --selftest)        SELFTEST=1; shift ;;
    --auth)            need_arg "$1" $#; AUTH_MODE="$2"; shift 2 ;;
    --password-env)    need_arg "$1" $#; PASSWORD_ENV="$2"; shift 2 ;;
    --credential-file) need_arg "$1" $#; CONFIRM_CRED_FILE="$2"; shift 2 ;;
    --save-credential) SAVE_CREDENTIAL=1; shift ;;
    --prompt-credential) PROMPT_CREDENTIAL=1; shift ;;
    -q|--quiet)        QUIET=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; COMMAND="$*"; break ;;
    -*)                err "未知选项: $1（用 --help 查看用法）"; exit 1 ;;
    *)                 if [ -z "$HOST" ]; then HOST="$1"; shift; else COMMAND="$*"; break; fi ;;
  esac
done

[ -n "$HOST" ] || { [ "$SELFTEST" -eq 1 ] || { err "必须指定目标主机（-H）"; exit 1; }; }
if [ -z "$COMMAND" ] && [ -z "$SCRIPT_FILE" ] && [ "$PREFLIGHT" -eq 0 ] && [ "$SELFTEST" -eq 0 ]; then
  err "需要 -c '命令'、-f 脚本文件 或 --preflight 之一"; exit 1
fi
case "$AUTH_MODE" in auto|key|password) ;; *) err "--auth 只能是 auto|key|password"; exit 1 ;; esac
case "${TIMEOUT}${CONNECT_TIMEOUT}" in
  *[!0-9]*) err "超时必须是整数秒"; exit 1 ;;
esac

if [ -n "$SCRIPT_FILE" ]; then
  [ -f "$SCRIPT_FILE" ] || { err "脚本文件不存在: $SCRIPT_FILE"; exit 1; }
  SCRIPT_FILE="$(cd "$(dirname "$SCRIPT_FILE")" && pwd)/$(basename "$SCRIPT_FILE")"
  # 脚本自己的选项（如 health_check.sh --deep）走 -A 透传：
  # "bash -s -- ARGS" 会把 ARGS 作为 $1.. 交给来自 stdin 的脚本
  if [ -n "$SCRIPT_ARGS" ]; then
    REMOTE_SCRIPT_CMD="bash -s -- $SCRIPT_ARGS"
  fi
  [ -n "$COMMAND" ] || COMMAND="$REMOTE_SCRIPT_CMD < $(basename "$SCRIPT_FILE")"
fi

# ---------- timeout 探测 ----------
# 优先用 GNU coreutils 的 timeout。注意：Windows / Git-Bash 下 `timeout` 可能解析到
# Windows 自带的 timeout.exe（等待按键，语义完全不同），因此用 --version 探测避开它。
# 必须放在认证逻辑之前：下面的 key_auth_possible 会用它。
# ssh 可执行文件：默认从 PATH 解析，可用 SSHMGR_SSH 覆盖。
# 为什么要这个开关：Windows 上 PATH 里可能同时有 msys 的 ssh 和 C:\Windows\System32\OpenSSH\ssh.exe。
# 后者是原生程序，**无法执行 shebang 脚本**，因此 askpass helper 会失败、密码登录用不了。
# 解析到原生 ssh 时 selftest 会明确报出来。
SSH_BIN="${SSHMGR_SSH:-ssh}"
if [ ! -x "$SSH_BIN" ] && ! command -v "$SSH_BIN" >/dev/null 2>&1; then
  err "找不到 ssh 可执行文件: $SSH_BIN（可用 SSHMGR_SSH 指定路径）"
  exit 1
fi

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# ═══════════════════ 认证：解析口令 / 决定用密钥还是密码 ═══════════════════
# 设计要点（每一条都对应一个真实的失败模式）：
#
# 1) 绝不主动劝用户改用密钥。给了账号密码就用账号密码。
# 2) 口令永不进命令行、永不进审计日志。`sshpass -p` 会把口令暴露在 ps 里，禁止使用。
# 3) **只有真正拿到非空口令时，才放开 BatchMode 与 NumberOfPasswordPrompts。**
#    OpenSSH 的 read_passphrase 在 askpass 程序退出码非零时返回的是空串
#    （password 认证调用时没带 RP_ALLOW_EOF），也就是说 askpass 挂掉**不是**让 ssh 放弃，
#    而是**提交一个空密码**：白烧一次 MaxAuthTries，还在服务器上留下 Failed password 日志
#    招来 fail2ban。所以拿不到口令就在调用 ssh 之前退出，绝不"让它自己失败"。
# 4) BatchMode 与 SSH_ASKPASS 必须同时设置、成对出现。两者一旦不一致，就会退化成
#    在 /dev/tty 上阻塞读，看起来像卡死。

read_credential_file() { # $1=路径 -> 打印口令（剥掉行尾 CR/LF）
  [ -r "$1" ] || return 1
  local v
  v="$(head -n1 "$1" 2>/dev/null)"
  # sshpass -f 不会剥 CR，会把带 \r 的密码发出去；记事本/Windows 保存的文件很容易带 CR
  v="${v%$'\r'}"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

resolve_password() {
  # 优先级：显式 --password-env > SSHMGR_PASSWORD > --credential-file > 默认凭据文件 > 交互输入
  if [ -n "$PASSWORD_ENV" ]; then
    # 用 bash 的间接展开而不是 eval：变量名里哪怕只有一个分号，eval 就是一次本地
    # 命令执行（`--password-env 'X; rm -rf ~'`）。间接展开只做一次名字解析，不解析值。
    case "$PASSWORD_ENV" in
      [!A-Za-z_]*|*[!A-Za-z0-9_]*)
        err "--password-env 只接受合法的环境变量名: $PASSWORD_ENV"; exit 1 ;;
    esac
    PASSWORD="${!PASSWORD_ENV:-}"
    [ -n "$PASSWORD" ] || { err "环境变量 $PASSWORD_ENV 为空或未设置"; exit 1; }
    return 0
  fi
  if [ -n "${SSHMGR_PASSWORD:-}" ]; then
    PASSWORD="$SSHMGR_PASSWORD"; return 0
  fi
  if [ -n "$CONFIRM_CRED_FILE" ]; then
    PASSWORD="$(read_credential_file "$CONFIRM_CRED_FILE")" || {
      err "无法从 $CONFIRM_CRED_FILE 读到口令（文件不存在/不可读/为空）"; exit 1; }
    return 0
  fi
  if [ -n "$CREDENTIAL_FILE" ] && [ -r "$CREDENTIAL_FILE" ]; then
    PASSWORD="$(read_credential_file "$CREDENTIAL_FILE")" || true
    [ -n "$PASSWORD" ] && return 0
  fi
  if [ "$PROMPT_CREDENTIAL" -eq 1 ]; then
    [ -t 0 ] || [ -r /dev/tty ] || { err "--prompt-credential 需要终端"; exit 1; }
    printf '请输入 %s@%s 的密码: ' "${USER_NAME:-${USER:-$(id -un 2>/dev/null || echo user)}}" "$HOST" >&2
    if [ -r /dev/tty ]; then IFS= read -rs PASSWORD < /dev/tty; else IFS= read -rs PASSWORD; fi
    printf '\n' >&2
    PASSWORD="${PASSWORD%$'\r'}"
    [ -n "$PASSWORD" ] || { err "口令为空"; exit 1; }
    return 0
  fi
  return 1
}

setup_askpass() {
  # 用临时文件做 helper：ssh 通过 execlp 执行它，所以必须是可执行的**真实文件**，
  # 且 stdout 只能打印口令（诊断信息一律走 stderr）。
  ASKPASS_HELPER="$(mktemp "${TMPDIR:-/tmp}/sshmgr-askpass.XXXXXX")" || return 1
  PW_TMPFILE="$(mktemp "${TMPDIR:-/tmp}/sshmgr-pw.XXXXXX")" || return 1
  chmod 700 "$ASKPASS_HELPER" "$PW_TMPFILE" 2>/dev/null || true
  ( umask 077; printf '%s\n' "$PASSWORD" > "$PW_TMPFILE" ) || return 1
  {
    printf '#!/bin/sh\n'
    printf '# ssh_exec.sh 的 askpass helper —— 只在密码认证路径下临时存在，退出即删\n'
    # 确认类提示（ssh 会设 SSH_ASKPASS_PROMPT=confirm）绝不能拿口令当"是"的回答
    printf 'case "${SSH_ASKPASS_PROMPT:-}" in confirm) exit 1 ;; esac\n'
    printf 'if [ "${SSHMGR_ASKPASS_DEBUG:-0}" = "1" ]; then\n'
    printf '  printf "%%s %%s\\n" "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ 2>/dev/null)" "$1" >> "%s/askpass.log" 2>/dev/null\n' "$LOG_DIR"
    printf '  chmod 600 "%s/askpass.log" 2>/dev/null\n' "$LOG_DIR"
    printf 'fi\n'
    # 口令从文件读，不从环境或命令行读 —— 后者会出现在 ps / /proc/<pid>/environ 里
    printf 'cat "%s" 2>/dev/null\n' "$PW_TMPFILE"
    printf 'exit 0\n'
  } > "$ASKPASS_HELPER" || return 1
  chmod 700 "$ASKPASS_HELPER" 2>/dev/null || true
  PASSWORD=""   # 口令已落到 0600 临时文件，变量里不再保留
  return 0
}

# 是否已经能用密钥认证？用 `ssh -o BatchMode=yes` 试一次最可靠
# （比去猜 ssh-agent / ~/.ssh 目录里有什么靠谱）
key_auth_possible() {
  # 已显式指定私钥：假定用户给的密钥是有效的，不再多试一次
  [ -n "$IDENTITY" ] && [ -r "$IDENTITY" ] && return 0
  local t=()
  t=( -o BatchMode=yes -o NumberOfPasswordPrompts=0 -o ConnectTimeout=5
      -o StrictHostKeyChecking=yes )
  [ -n "$PORT" ] && t+=( -p "$PORT" )
  [ -n "$JUMP" ] && t+=( -J "$JUMP" )
  local target="$HOST"; [ -n "$USER_NAME" ] && target="${USER_NAME}@${HOST}"
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" 12 "$SSH_BIN" "${t[@]}" "$target" true >/dev/null 2>&1
  else
    "$SSH_BIN" "${t[@]}" "$target" true >/dev/null 2>&1
  fi
}

AUTH_RESOLVED="key"
case "$AUTH_MODE" in
  key)
    AUTH_RESOLVED="key"
    ;;
  password)
    resolve_password || {
      err "选择了 --auth password，但没有拿到口令。请任选一种方式提供："
      say "  --password-env VAR      从环境变量读（不进命令行）"
      say "  --credential-file F     从文件读（建议 chmod 600）"
      say "  --prompt-credential     交互式输入（不进 shell history）"
      say "  或设置 SSHMGR_PASSWORD"
      exit 1
    }
    AUTH_RESOLVED="password"
    ;;
  auto)
    # auto：能免密就免密，否则有口令就用口令
    if key_auth_possible; then
      AUTH_RESOLVED="key"
    elif resolve_password; then
      AUTH_RESOLVED="password"
    else
      AUTH_RESOLVED="key"   # 什么都没配：按原来的密钥路径走，让 ssh 自己报错，诊断分支会给指引
    fi
    ;;
esac

if [ "$AUTH_RESOLVED" = "password" ]; then
  setup_askpass || { err "无法创建 askpass helper（临时目录不可写？）"; exit 1; }
fi

# --save-credential：只有用户明确要求才落盘，且必须是 0600
if [ "$SAVE_CREDENTIAL" -eq 1 ]; then
  if [ "$AUTH_RESOLVED" != "password" ] || [ -z "${PW_TMPFILE:-}" ]; then
    warn "--save-credential 需要先在本次调用里提供口令，已忽略"
  else
    mkdir -p "$LOG_DIR" 2>/dev/null; chmod 700 "$LOG_DIR" 2>/dev/null || true
    ( umask 077; cat "$PW_TMPFILE" > "$CRED_FILE_DEFAULT" ) && chmod 600 "$CRED_FILE_DEFAULT" 2>/dev/null
    # 别谎报权限：Git-Bash 的挂载多为 noacl，chmod 对权限位是空操作
    # （实测 chmod 600 与 777 之后 stat 都是 644）。说清实际情况比印一句"0600"有用。
    _actual="$(stat -c '%a' "$CRED_FILE_DEFAULT" 2>/dev/null)"
    say "${C_GRN}口令已保存到 $CRED_FILE_DEFAULT${C_OFF}"
    if [ "${_actual:-}" = "600" ] || [ "${_actual:-}" = "700" ]; then
      say "  文件权限已设为 ${_actual}。"
    else
      say "  ${C_YEL}注意：当前文件权限是 ${_actual:-未知}，不是 600 —— Git-Bash 的磁盘挂载通常是"
      say "        noacl，chmod 对权限位是空操作（改不了 Windows ACL）。${C_OFF}"
      say "        实际的保护边界是 %USERPROFILE% 目录的 ACL，而不是这个文件的 mode；"
    fi
    say "  同用户下任何进程（包括本 agent）都能读它。不想要了就 rm 掉。"
  fi
fi

# ---------- 风险分级 ----------
# 分级的意义：让「二次确认」成为可执行的门槛，而不是靠记忆和自觉。
# 短命令加词边界，避免 "kill" 命中 "killer"、"> /etc/" 命中无关路径。
BOUND='(^|[^[:alnum:]_-])'
END='([^[:alnum:]_-]|$)'

TIER2_PATTERNS=(
  "${BOUND}rm[[:space:]]+-[^[:space:]]*[rf]"
  "${BOUND}dd[[:space:]]"
  "${BOUND}(mkfs|mkswap|wipefs)"
  "${BOUND}(sfdisk|fdisk|parted|gdisk)"
  ':\(\)[[:space:]]*\{'
  "${BOUND}(shutdown|reboot|halt|poweroff)(${END})"
  "${BOUND}init[[:space:]]+[06](${END})"
  "${BOUND}ip6?tables[[:space:]]+(-F|-X)"
  "${BOUND}ip6?tables[[:space:]]+-P[[:space:]]+[A-Za-z]+[[:space:]]+DROP"
  "${BOUND}ufw[[:space:]]+.*(disable|reset)"
  'firewall-cmd.*(--set-default-zone|--panic-on)'
  "${BOUND}systemctl[[:space:]]+(stop|disable|mask)[[:space:]]+(ssh|sshd)"
  "${BOUND}service[[:space:]]+ssh(d)?[[:space:]]+stop"
  'sshd_config|/etc/sudoers|/etc/ssh/ssh_config'
  '/etc/fstab'
  '(DROP|TRUNCATE)[[:space:]]+(DATABASE|TABLE)'
  "${BOUND}kill[[:space:]]+-9[[:space:]]+-?1([^[:alnum:]_-]|$)"
  "${BOUND}killall5(${END})"
  "${BOUND}chmod[[:space:]]+-R[[:space:]]+777"
  "${BOUND}chown[[:space:]]+-R[[:space:]]+[^[:space:]]+[[:space:]]+/(etc|var|usr|bin|sbin|lib|boot)"
  "${BOUND}userdel[[:space:]]"
  '(curl|wget)[^|]*\|[[:space:]]*(ba|z)?sh'
  "${BOUND}mv[[:space:]]+[^[:space:]]+[[:space:]]+/etc/(nginx|ssh|sysconfig)"
  "${BOUND}sed[[:space:]]+-i.*(sshd_config|fstab|sudoers)"
  '>[[:space:]]*/dev/(sd|nvme|vd)'
  # 压测 / 基准测试：本技能默认不跑性能测试。
  # 在生产机上跑这些既污染业务指标、又可能触发监控告警，结论对运维决策也没有用。
  # 模式要收紧（都要求后面跟东西），免得误伤 df -h、openssl s_client 这类正常命令。
  "${BOUND}(sysbench|stress-ng|stress|memtester|bonnie\+\+|unixbench|phoronix-test-suite)[[:space:]]"
  "${BOUND}fio[[:space:]]"
  "${BOUND}iperf3?[[:space:]]"
  "${BOUND}openssl[[:space:]]+speed"
  "${BOUND}dd[[:space:]]+if=.*[[:space:]]+of="
  "${BOUND}(hdparm|iozone|dbench|tiobench)[[:space:]]"
)

TIER1_PATTERNS=(
  "${BOUND}systemctl.*[[:space:]](start|stop|restart|reload|enable|disable|mask|unmask|daemon-reload)([^[:alnum:]_-]|$)"
  "${BOUND}service[[:space:]]+[^[:space:]]+[[:space:]]+(start|stop|restart|reload)"
  "${BOUND}nginx[[:space:]]+-s[[:space:]]+(reload|stop|quit)"
  "${BOUND}(kill|pkill|killall)[[:space:]]"
  "${BOUND}apt(-get)?.*[[:space:]](install|remove|purge|upgrade|dist-upgrade|full-upgrade|autoremove)([^[:alnum:]_-]|$)"
  "${BOUND}(yum|dnf).*[[:space:]](install|remove|erase|update|upgrade|autoremove|groupinstall)([^[:alnum:]_-]|$)"
  "${BOUND}docker[[:space:]]+(stop|start|restart|rm|rmi|kill|prune|tag)"
  "${BOUND}docker[[:space:]]+compose.*[[:space:]](up|down|restart|stop|rm|build)([^[:alnum:]_-]|$)"
  "${BOUND}docker[[:space:]]+system[[:space:]]+prune"
  "${BOUND}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(pull|reset|checkout|clean|merge|rebase|stash)"
  "${BOUND}(chmod|chown|chgrp)[[:space:]]"
  "${BOUND}sed[[:space:]]+-i"
  "${BOUND}crontab[[:space:]]+-[re]"
  "${BOUND}(useradd|usermod|groupadd|groupmod|gpasswd|userdel)"
  "${BOUND}ufw[[:space:]]+(allow|delete|deny|enable|limit)"
  'firewall-cmd.*(--add|--remove|--reload)'
  "${BOUND}sysctl[[:space:]]+-w"
  "${BOUND}pip[0-9]?[[:space:]]+install"
  "${BOUND}npm[[:space:]]+install[[:space:]]+-g"
  "${BOUND}rsync.*--delete"
  "${BOUND}mv[[:space:]]"
  "${BOUND}truncate[[:space:]]"
  "${BOUND}find[^|]*-delete"
  '>[[:space:]]*/etc/'
)

RISK_TIER=0
RISK_REASON=""

classify() {
  local cmd="$1" pat
  RISK_TIER=0
  RISK_REASON="未命中危险模式，按只读处理"
  for pat in "${TIER2_PATTERNS[@]}"; do
    if printf '%s' "$cmd" | grep -Eiq -- "$pat"; then
      RISK_TIER=2
      case "$pat" in
        *sysbench*) RISK_REASON="压测/基准类命令：本技能默认不跑性能测试" ;;
        *)          RISK_REASON="命中高危模式: $pat" ;;
      esac
      return 0
    fi
  done
  for pat in "${TIER1_PATTERNS[@]}"; do
    if printf '%s' "$cmd" | grep -Eiq -- "$pat"; then
      RISK_TIER=1
      RISK_REASON="命中变更模式: $pat"
      return 0
    fi
  done
}

classify "$COMMAND"
READ_ONLY_DECLARED=0
if [ -n "$SCRIPT_FILE" ]; then
  # 脚本内容无法从命令行静态判定，默认保守按变更级处理。
  # 但如果脚本头部自己声明了 `# sshmgr:read-only`，就维持只读 —— 这是必需的：
  # 采集档案用的 server_profile.sh 是只读脚本，若它被判成变更级，
  # "变更后标脏档案"的逻辑会把它自己标脏，形成每次采集都自我失效的死循环。
  # 声明式豁免的信任级别等同于 --confirm-danger，所以要求脚本必须来自
  # 本 skill 自己的 scripts/ 目录，不能拿它给任意本地脚本洗白。
  if head -20 "$SCRIPT_FILE" 2>/dev/null | grep -q '#[[:space:]]*sshmgr:read-only'; then
    if [ "$(cd "$(dirname "$SCRIPT_FILE")" && pwd)" = "$SCRIPT_DIR_SELF" ]; then
      READ_ONLY_DECLARED=1
      RISK_TIER=0
      RISK_REASON="脚本声明 sshmgr:read-only（本 skill 自带脚本，只读）"
    else
      RISK_TIER=1
      RISK_REASON="脚本声明了 sshmgr:read-only，但不在本 skill 的 scripts/ 目录内，不予采信，按变更级处理"
    fi
  else
    RISK_TIER=1
    RISK_REASON="执行本地脚本 $(basename "$SCRIPT_FILE")，内容未做静态分析，按变更级处理"
  fi
fi

# ---------- 审计日志 ----------
# 日志要能回答"谁在什么时候改了什么"。脚本模式下命令原文没有意义（只是个临时文件名），
# 所以记「标签 + 脚本摘要」：摘要能唯一标识当时执行的脚本内容。
file_digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -c1-12
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | cut -c1-12
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print substr($NF,1,12)}'
  fi
}

log_cmd() {
  [ "$DO_LOG" -eq 1 ] || return 0
  # $3 可选：覆盖记录内容，用来记下"认证失败 vs 网络不可达"这类命令原文表达不出的判定
  local rc="$1" dur="$2" override="${3:-}" what sum
  if [ -n "$override" ]; then
    what="$override"
  elif [ -n "$LOG_LABEL" ]; then
    what="$LOG_LABEL"
  else
    what="$(printf '%s' "$COMMAND" | tr '\n\r\t' '   ' | cut -c1-500)"
  fi
  if [ -n "$SCRIPT_FILE" ]; then
    sum="$(file_digest "$SCRIPT_FILE")"
    what="${what:-script:$(basename "$SCRIPT_FILE")} [script $(basename "$SCRIPT_FILE")${sum:+ sha256:$sum}]"
  fi
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  chmod 700 "$LOG_DIR" 2>/dev/null || true
  if [ ! -e "$LOG_FILE" ]; then
    ( umask 077; : > "$LOG_FILE" ) 2>/dev/null || return 0
  fi
  printf '%s | %s | tier%s | rc=%s | %ss | %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET_LABEL" "$RISK_TIER" "$rc" "$dur" "$what" \
    >> "$LOG_FILE" 2>/dev/null || true
}

# ---------- 远端目标 ----------
TARGET_LABEL="$HOST"
TARGET="$HOST"
if [ -n "$USER_NAME" ]; then
  TARGET="${USER_NAME}@${HOST}"
  TARGET_LABEL="$TARGET"
fi

SSH_OPTS=(
  -o "ConnectTimeout=${CONNECT_TIMEOUT}"
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o "StrictHostKeyChecking=yes"
)

if [ "$AUTH_RESOLVED" = "password" ]; then
  # 密码路径：必须放开 BatchMode，否则 ssh 根本不会去问口令。
  # 但 BatchMode 与 SSH_ASKPASS 是成对出现的 —— 只放开前者会让 ssh 去 /dev/tty 阻塞读，
  # 看起来像卡死。所以两者在同一个分支里一起设。
  [ -n "${ASKPASS_HELPER:-}" ] || { err "内部错误：密码认证路径缺少 askpass helper"; exit 1; }
  SSH_OPTS+=( -o "BatchMode=no" -o "NumberOfPasswordPrompts=1" )
  # 显式指定密码时关掉公钥尝试：否则 ssh-agent 里挂着一堆密钥会被逐个试过去，
  # 烧穿 MaxAuthTries 报 "Too many authentication failures"，口令根本没机会提交。
  SSH_OPTS+=( -o "PubkeyAuthentication=no" -o "PreferredAuthentications=password,keyboard-interactive" )
  export SSH_ASKPASS="$ASKPASS_HELPER"
  # force：即使有 TTY 也走 askpass。没有它，在控制台里的 Git-Bash 会去读 /dev/tty。
  export SSH_ASKPASS_REQUIRE=force
  export DISPLAY="${DISPLAY:-:0}"
else
  # 密钥路径：与改动前逐字一致。BatchMode 让认证失败立即报错而不是挂起等输入。
  SSH_OPTS+=( -o BatchMode=yes -o "NumberOfPasswordPrompts=0" )
fi

[ -n "$PORT" ] && SSH_OPTS+=( -p "$PORT" )
[ -n "$JUMP" ] && SSH_OPTS+=( -J "$JUMP" )
[ -n "$IDENTITY" ] && SSH_OPTS+=( -i "$IDENTITY" -o IdentitiesOnly=yes )

# 连接复用：默认每次调用要预检 + 执行 = 两次 TCP 握手、两次认证。
# 对密钥是延迟问题；对密码则是口令要重复提交两遍、Failed password 机会翻倍。
# ControlPersist 10m 让这段时间内只认证一次。msys 的 ssh 不会自己建 ControlPath 目录。
if [ "${SSHMGR_NO_MUX:-0}" != "1" ]; then
  CM_DIR="$LOG_DIR/cm"
  if mkdir -p "$CM_DIR" 2>/dev/null; then
    chmod 700 "$CM_DIR" 2>/dev/null || true
    SSH_OPTS+=( -o ControlMaster=auto -o "ControlPath=$CM_DIR/%C" -o ControlPersist=10m )
  fi
fi

# 优先用 GNU coreutils 的 timeout。注意：Windows / Git-Bash 下 `timeout` 可能解析到
# Windows 自带的 timeout.exe（等待按键，语义完全不同），因此用 --version 探测避开它。
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# ---------- 错误诊断 ----------
# 把 ssh 的报错翻译成「下一步该做什么」，避免在错误方向上反复重试。
diagnose() {
  local text="$1"
  case "$text" in
    *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
      err "主机密钥校验失败 —— 目标不在 known_hosts 中，或指纹已变更。"
      say "  1) 先核对指纹（别跳过，指纹不符可能意味着中间人）："
      say "     ssh-keyscan -t ed25519,rsa ${PORT:+-p $PORT }$HOST 2>/dev/null | ssh-keygen -lf -"
      say "  2) 与云控制台或机房记录比对一致后，再加 --accept-host-key 写入 known_hosts"
      say "  3) 若确认是重装系统导致变更: ssh-keygen -R $HOST 后重新核对" ;;
    *"Connection refused"*)
      err "连接被拒绝 —— 主机可达，但该端口没有服务在监听。"
      say "  排查：sshd 是否在运行、端口是否被改（sshd_config 的 Port）、安全组与防火墙是否放行" ;;
    *"Connection timed out"*|*"Operation timed out"*|*"No route to host"*)
      err "连接超时或不可达 —— 通常是网络或防火墙层面被拦，不是认证问题。"
      say "  排查：安全组入站规则、本机出网策略、目标是否已关机、IP 是否变更" ;;
    *"Could not resolve hostname"*)
      err "主机名无法解析。"
      say "  排查：~/.ssh/config 的 HostName 拼写、/etc/hosts、DNS 是否可用" ;;
    # ⚠ 顺序要紧：下面这几个多方法形式必须排在 `Permission denied (publickey` 之前。
    # 那个模式没有右括号，是**前缀**匹配，`Permission denied (publickey,password)` 会命中它，
    # 于是走密码的用户被告知去查 authorized_keys 权限 —— 完全查错方向。
    *"Permission denied (publickey,password"*|*"Permission denied (publickey,keyboard-interactive"*)
      err "认证被拒绝 —— 服务端同时提供公钥与密码，两种都没通过。"
      say "  密钥路径：-i <私钥>，确认 ssh-agent 已加载、远端 authorized_keys 权限正确"
      say "            （远端要求 ~/.ssh 为 700、authorized_keys 为 600、家目录不能 group-writable）"
      say "  密码路径：--prompt-credential（交互输入，不进 history）"
      say "            或 --password-env VAR / --credential-file F" ;;
    *"Permission denied (password"*|*"Permission denied (keyboard-interactive"*)
      err "密码认证被拒绝 —— 服务端在要密码，但这次提交的口令不对（或口令没送到）。"
      say "  1) 确认账号/口令无误；注意别让文件里的行尾 CR 混进口令"
      say "     （本脚本读文件时已剥 CR，但你自己拼的管道不一定）"
      say "  2) 用 SSHMGR_ASKPASS_DEBUG=1 重跑，看 $LOG_DIR/askpass.log 里"
      say "     ssh 到底问了什么 prompt —— 只记 prompt，不记口令"
      say "  3) 确认 sshd 没限制 PermitEmptyPasswords，也没把该用户 AllowUsers 排除在外" ;;
    *"Permission denied (publickey"*)
      err "公钥认证被拒绝 —— 属于密钥或账号权限问题，不是网络问题。"
      say "  排查：私钥路径、ssh-agent 是否已加载、远端 authorized_keys 权限"
      say "        远端要求 ~/.ssh 为 700、authorized_keys 为 600、家目录不能 group-writable"
      say "        远端是否限制 AllowUsers/AllowGroups，或 AuthorizedKeysFile 被改过"
      say "  如果这台机器其实是用密码的，改用: --auth password --prompt-credential" ;;
    # 兜底：ssh 的措辞随版本和可用认证方式变化，上面都没命中时给两条路
    *"Permission denied"*)
      err "认证失败（服务端拒绝）—— 不是网络问题。"
      say "  密钥路径：-i <私钥>；确认 ssh-agent 已加载、远端 authorized_keys 权限正确"
      say "  密码路径：--auth password 搭配 --prompt-credential / --password-env / --credential-file" ;;
    *"no askpass program specified"*|*"can't open display"*)
      err "ssh 需要交互输入口令，但没拿到 askpass 程序（非交互环境下必然如此）。"
      say "  解决：用 --auth password 搭配 --prompt-credential / --password-env / --credential-file，"
      say "        本脚本会自动生成 askpass helper；不要依赖 ssh 自己去读 /dev/tty（那会看起来像卡死）" ;;
    *"Too many authentication failures"*)
      err "认证失败次数过多 —— ssh-agent 里密钥太多，逐个尝试后被服务端拒绝。"
      say "  解决：显式指定 -i <私钥>（本脚本会自动附加 IdentitiesOnly=yes），或精简 ssh-agent"
      say "        密码登录时加 --auth password（会关掉公钥尝试，直接提交口令）" ;;
    *"Connection closed by"*|*"kex_exchange_identification"*)
      err "连接被对端主动关闭 —— 常见于 fail2ban 封禁、sshd MaxStartups 限流，或中间网络设备干扰。"
      say "  排查：服务器上 fail2ban-client status sshd，等待封禁到期或从其他 IP 解封" ;;
    *"no matching host key type"*|*"no matching key exchange"*)
      err "算法不匹配 —— 新客户端连老服务器（或反之）。"
      say "  解决：在 ~/.ssh/config 为该主机加 HostkeyAlgorithms / KexAlgorithms 兼容项" ;;
    *"sudo: a password is required"*|*"sudo: no tty present"*)
      err "远端 sudo 需要密码或 TTY —— 非交互执行无法提供输入。"
      say "  解决：为该命令配置 NOPASSWD，或改用交互式会话手工执行" ;;
    *"command not found"*)
      warn "远端缺少该命令 —— 确认是否装在非标准路径，或需要先安装对应软件包。" ;;
  esac
}

# ---------- --accept-host-key ----------
# 只在用户明确要求时写 known_hosts，并且强制打印指纹供人工核对，
# 这样"首次连接"不会退化成无脑信任。
if [ "$ACCEPT_HOST_KEY" -eq 1 ]; then
  command -v ssh-keyscan >/dev/null 2>&1 || { err "缺少 ssh-keyscan，无法写入 known_hosts"; exit 1; }
  say "${C_YEL}即将把以下主机指纹写入 ~/.ssh/known_hosts，请先与可信来源核对：${C_OFF}"
  # 取主机密钥。注意 ssh-keyscan **没有 -J 选项**（OpenSSH 9.x 直接报
  # `unknown option -- J`），以前经跳板机时把它塞给 ssh-keyscan，结果是必然取不到指纹。
  # 正确做法：开一条到跳板机的 ssh 会话，由跳板机去扫目标（跳板机能看见目标）。
  # HOST 会被拼进远端命令串里，所以先拒绝带引号/空白的值 —— 主机名本来不该有这些字符。
  case "$HOST" in
    *"'"*|*'"'*|*' '*|*';'*|*'$'*|*'`'*)
      err "主机名包含不安全字符，拒绝拼进远端命令: $HOST"; exit 2 ;;
  esac
  keys=""
  kscan_tmp="$(mktemp "${TMPDIR:-/tmp}/sshmgr-kscan.XXXXXX" 2>/dev/null)" || kscan_tmp=""
  if [ -n "$JUMP" ]; then
    if [ -n "$kscan_tmp" ]; then
      # 跳板机本身仍按严格校验（StrictHostKeyChecking=yes），不做 accept-new：
      # 这里是为了降低一个风险，而不是引入新的自动信任。
      if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" 20 "$SSH_BIN" -J "$JUMP" -o ConnectTimeout="$CONNECT_TIMEOUT"           -o BatchMode=yes -o StrictHostKeyChecking=yes           "ssh-keyscan -p ${PORT:-22} -T 5 -t rsa,ecdsa,ed25519 $HOST 2>/dev/null"           > "$kscan_tmp" 2>/dev/null
      else
        "$SSH_BIN" -J "$JUMP" -o ConnectTimeout="$CONNECT_TIMEOUT"           -o BatchMode=yes -o StrictHostKeyChecking=yes           "ssh-keyscan -p ${PORT:-22} -T 5 -t rsa,ecdsa,ed25519 $HOST 2>/dev/null"           > "$kscan_tmp" 2>/dev/null
      fi
      keys="$(cat "$kscan_tmp" 2>/dev/null)"
    fi
  elif [ -n "$TIMEOUT_BIN" ]; then
    keys="$("$TIMEOUT_BIN" 20 ssh-keyscan ${PORT:+-p "$PORT"} -T 5 -t rsa,ecdsa,ed25519 "$HOST" 2>/dev/null)"
  else
    keys="$(ssh-keyscan ${PORT:+-p "$PORT"} -T 5 -t rsa,ecdsa,ed25519 "$HOST" 2>/dev/null)"
  fi
  [ -n "$kscan_tmp" ] && rm -f "$kscan_tmp" 2>/dev/null
  if [ -z "$keys" ]; then
    err "未能获取 $HOST 的主机密钥（网络不通 / sshd 无响应 / 目标只对跳板机可见）"
    if [ -n "$JUMP" ]; then
      say "  经跳板机（-J $JUMP）时，可以在跳板机上手工扫描："
      say "    ssh-keyscan -p ${PORT:-22} $HOST | ssh-keygen -lf -"
      say "  人工核对后，把指纹用 --fingerprint 传回来再写入。"
    fi
    exit 2
  fi
  scanfp="$(printf '%s\n' "$keys" | ssh-keygen -lf - 2>/dev/null)"
  printf '%s\n' "$scanfp" | sed 's/^/  /'

  # --fingerprint：把"人工核对过"变成机制。
  # 只有当扫描到的指纹里**确实有**用户确认过的那个值，才允许写入。
  if [ -n "$FINGERPRINT" ]; then
    if printf '%s\n' "$scanfp" | grep -qF -- "$FINGERPRINT"; then
      say "${C_GRN}指纹与 --fingerprint 提供的值一致，核对通过。${C_OFF}"
    else
      err "指纹不匹配！扫描到的指纹里没有你提供的 $FINGERPRINT"
      err "已拒绝写入 known_hosts。这可能是中间人，也可能是你抄错了值 —— 两种情况都别继续。"
      exit 2
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    dim "  (dry-run：未写入)"
    exit 0
  fi

  # 已存在且指纹不同的处理：直接 >> 追加会在旧密钥后面再加一条，
  # ssh 仍然匹配到第一条并继续报错，现象非常误导。
  kh="$HOME/.ssh/known_hosts"
  kh_entry="$HOST"; [ -n "$PORT" ] && [ "$PORT" != "22" ] && kh_entry="[$HOST]:$PORT"
  if [ -f "$kh" ] && ssh-keygen -F "$kh_entry" -f "$kh" >/dev/null 2>&1; then
    oldfp="$(ssh-keygen -F "$kh_entry" -f "$kh" 2>/dev/null | grep -v '^#' | ssh-keygen -lf - 2>/dev/null | head -1 | awk '{print $2}')"
    newfp="$(printf '%s\n' "$scanfp" | head -1 | awk '{print $2}')"
    if [ -n "$oldfp" ] && [ "$oldfp" != "$newfp" ]; then
      err "known_hosts 里 $kh_entry 已存在，且指纹与现在扫描到的不一致："
      say "  已有: $oldfp"
      say "  扫描: $newfp"
      say "  这通常意味着目标重装了系统或换了机器，但也可能是中间人。"
      say "  确认是重装后，先删除旧记录再重试："
      say "    ssh-keygen -R \"$kh_entry\""
      exit 2
    fi
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  printf '%s\n' "$keys" >> "$kh"
  say "${C_GRN}已写入 $kh。${C_OFF}"
fi

# ---------- --dry-run ----------
# ⚠ 输出格式有下游依赖：batch_run.sh 用
#   sed -n 's/^风险等级  : tier\([0-9]\).*/\1/p'
#   精确解析这一行。加行可以，改这一行的形状不行。
if [ "$DRY_RUN" -eq 1 ]; then
  say "目标      : $TARGET_LABEL"
  say "风险等级  : tier${RISK_TIER} (${RISK_REASON})"
  say "超时      : ${TIMEOUT}s (连接 ${CONNECT_TIMEOUT}s)"
  if [ -n "$SCRIPT_FILE" ]; then
    say "脚本      : $SCRIPT_FILE  ->  远端 $REMOTE_SCRIPT_CMD"
  else
    say "将执行    : $COMMAND"
  fi
  if [ "$RISK_TIER" -ge 1 ] && [ "$READ_ONLY_DECLARED" -eq 0 ]; then
    say "${C_YEL}提示: 变更与高危操作需要先向用户说明影响面与回滚方案。${C_OFF}"
  fi
  exit 0
fi

# ---------- --selftest ----------
# 一屏把"为什么连不上/口令为什么没发出去"能自查的东西全打出来。
# 这比任何 fallback 都值：把凌晨两点的谜题变成 5 秒答案。
if [ "$SELFTEST" -eq 1 ]; then
  # 中文标签是双宽字符，printf 的 %-22s 按字节补空格会错位；本脚本 LC_ALL=C，
  # bash 的 ${#s} 也只数字节。自己算显示列宽：ASCII 1 列，UTF-8 多字节字符 2 列。
  _sw() {
    local s="$1" i b w=0
    for ((i=0; i<${#s}; i++)); do
      b=$(printf '%d' "'${s:i:1}" 2>/dev/null) || b=63
      if   [ "$b" -ge 192 ]; then w=$((w+2))
      elif [ "$b" -ge 128 ]; then :
      else w=$((w+1))
      fi
    done
    printf '%d' "$w"
  }
  ST() { local w pad="" i; w="$(_sw "$1")"; for ((i=w; i<22; i++)); do pad="$pad "; done; printf '%s%s %s
' "$1" "$pad" "$2"; }
  printf '%s\n' "═══ ssh-server-manager 自检 ═══"
  SSHBIN="$SSH_BIN"
  case "$SSHBIN" in */*) ;; *) SSHBIN="$(command -v "$SSH_BIN" 2>/dev/null || echo "$SSH_BIN")" ;; esac
  ST "ssh 可执行文件" "$SSHBIN$([ -n "${SSHMGR_SSH:-}" ] && echo "  (来自 SSHMGR_SSH)")"
  ST "ssh 版本" "$([ -x "$SSHBIN" ] && "$SSHBIN" -V 2>&1 | head -1 || echo '无法执行')"
  case "$SSHBIN" in
    /c/Windows/*|*System32*) printf '%-22s %s\n' "注意" "解析到 Windows 原生 ssh —— 它无法执行 shebang 脚本，askpass helper 会失败。建议在 Git-Bash 里跑，或用 SSHMGR_SSH 指定 msys 的 ssh" ;;
  esac
  if [ -n "$SSHBIN" ] && [ -r "$SSHBIN" ]; then
    if grep -qa 'SSH_ASKPASS_REQUIRE' "$SSHBIN" 2>/dev/null; then
      ST "askpass 支持" "是（二进制含 SSH_ASKPASS_REQUIRE）→ 密码登录可用，无需 sshpass"
    else
      ST "askpass 支持" "否 —— 这个 ssh 太老，密码登录会不可靠"
    fi
  fi
  ST "sshpass" "$(command -v sshpass 2>/dev/null || echo '未安装（不影响：本机走 askpass）')"
  if (exec 3<>/dev/tcp/127.0.0.1/1) 2>/dev/null; then
    ST "/dev/tcp" "可用"
  else
    ST "/dev/tcp" "可用（本地拒绝端口，符合预期）"
  fi
  ST "GNU timeout" "${TIMEOUT_BIN:-未找到（超时保护将不可用）}"
  ST "审计日志目录" "$LOG_DIR"
  ST "凭据文件" "$CRED_FILE_DEFAULT $([ -f "$CRED_FILE_DEFAULT" ] && echo '(存在)' || echo '(未创建)')"
  # ControlMaster 是否真的可用：建一个到本地的假连接测不出来，只能看目录能不能建
  if [ "${SSHMGR_NO_MUX:-0}" = "1" ]; then
    ST "连接复用" "已通过 SSHMGR_NO_MUX 关闭"
  elif mkdir -p "$LOG_DIR/cm" 2>/dev/null; then
    ST "连接复用" "可用（$LOG_DIR/cm，10 分钟内只认证一次）"
  else
    ST "连接复用" "不可用（$LOG_DIR/cm 建不出来）"
  fi
  # askpass helper 端到端自测：真的生成一个、执行它、看能不能取回口令
  printf '\n生成一个临时 askpass helper 做端到端自测...\n'
  _saved_pw_test="selftest-$(date +%s)"
  PASSWORD="$_saved_pw_test"
  if setup_askpass 2>/dev/null; then
    got="$("$ASKPASS_HELPER" "test prompt" 2>/dev/null)"
    if [ "$got" = "$_saved_pw_test" ]; then
      ST "askpass 端到端" "通过（helper 能正确回传口令）"
    else
      ST "askpass 端到端" "失败：helper 回传了 '${got:0:20}'，与预期不符"
    fi
  else
    ST "askpass 端到端" "失败：helper 建不出来（临时目录不可写？）"
  fi
  PASSWORD=""
  printf '\n透明代理检查（对照探测保留地址，能连上说明本机栈在拦截流量）：\n'
  if [ -f "$SCRIPT_DIR_SELF/tcping.sh" ]; then
    bash "$SCRIPT_DIR_SELF/tcping.sh" -H 192.0.2.1 -p 9 -n 1 -q 2>/dev/null | head -1
  fi
  exit 0
fi

# ---------- 高危拦截 ----------
if [ "$RISK_TIER" -eq 2 ] && [ "$CONFIRM_DANGER" -ne 1 ]; then
  err "该命令被判为高危，已拒绝执行。"
  say "  判定依据: $RISK_REASON"
  say "  命令原文: $COMMAND"
  say ""
  say "  执行前需要做到："
  say "    1) 把上面这条确切命令原文给用户看，明确问一次是否执行"
  say "    2) 说明回退方案（备份在哪、怎么还原、备用登录入口）"
  say "    3) 用户确认后，加 --confirm-danger 重新调用"
  log_cmd 4 0
  exit 4
fi

if [ "$RISK_TIER" -eq 1 ] && [ "$READ_ONLY_DECLARED" -eq 0 ]; then
  warn "变更类操作：确认已向用户说明影响面与回滚方式。"
fi

# ---------- 连接预检 ----------
say "${C_DIM}-> ${TARGET_LABEL} (tier${RISK_TIER}${AUTH_RESOLVED:+, auth=${AUTH_RESOLVED}})${C_OFF}"

start_ts=$(date +%s)
preflight_rc=0
preflight_out=""
if [ "$NO_PREFLIGHT" -eq 0 ]; then
  set +e
  if [ -n "$TIMEOUT_BIN" ]; then
    preflight_out="$("$TIMEOUT_BIN" "$CONNECT_TIMEOUT" "$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" true 2>&1)"
  else
    preflight_out="$("$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" true 2>&1)"
  fi
  preflight_rc=$?
  set -e
fi

if [ "$preflight_rc" -ne 0 ]; then
  err "连通性检查失败 (rc=$preflight_rc)"
  [ -n "$preflight_out" ] && printf '%s\n' "$preflight_out" | sed 's/^/  /' >&2
  diagnose "$preflight_out"
  # 区分"网络不可达"和"认证失败"：两者的下一步动作完全不同，
  # 混成一句"连接失败"会把用户推向排查安全组，而问题其实是口令。
  if printf '%s' "$preflight_out" | grep -qi 'permission denied\|authentication\|too many auth'; then
    err "判定：认证失败（不是网络问题）"
    log_cmd 2 "$(( $(date +%s) - start_ts ))" "auth-failed(${AUTH_RESOLVED})"
  else
    err "判定：网络层不可达或被拦"
    log_cmd 2 "$(( $(date +%s) - start_ts ))" "network-unreachable"
  fi
  exit 2
fi

# 档案提示：只在"可操作"时提示（缺档案 / 已标脏），走 stderr，不污染 stdout 载荷。
# 这一行就是"不用每次都重新侦察"的入口 —— 一连接就知道该不该采。
if [ "$NO_PREFLIGHT" -eq 0 ] && [ "${SSHMGR_NO_HINT:-0}" != "1" ]; then
  PS="$SCRIPT_DIR_SELF/profile_store.sh"
  if [ -f "$PS" ]; then
    hintline="$(bash "$PS" hint -H "$HOST" 2>/dev/null | head -1)"
    [ -n "$hintline" ] && hint "  $hintline"
  fi
fi

if [ "$PREFLIGHT" -eq 1 ]; then
  say "${C_GRN}OK${C_OFF} 连接正常（认证通过${AUTH_RESOLVED:+, ${AUTH_RESOLVED}}）"
  dur=$(( $(date +%s) - start_ts ))
  log_cmd 0 "$dur"
  exit 0
fi

# ---------- 执行 ----------
say "${C_DIM}-> 执行中 (timeout ${TIMEOUT}s)...${C_OFF}"
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/sshmgr.XXXXXX")" || { err "无法创建临时文件"; exit 1; }
out_file="$OUT_FILE"   # 兼容下面的引用；真正的清理由 cleanup() 统一负责

set +e
if [ -n "$SCRIPT_FILE" ]; then
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TIMEOUT" "$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" "$REMOTE_SCRIPT_CMD" < "$SCRIPT_FILE" > "$OUT_FILE" 2>&1
  else
    "$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" "$REMOTE_SCRIPT_CMD" < "$SCRIPT_FILE" > "$OUT_FILE" 2>&1
  fi
else
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TIMEOUT" "$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" "$COMMAND" > "$OUT_FILE" 2>&1
  else
    "$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" "$COMMAND" > "$OUT_FILE" 2>&1
  fi
fi
rc=$?
set -e
dur=$(( $(date +%s) - start_ts ))

cat "$OUT_FILE"

if [ "$rc" -eq 124 ]; then
  err "执行超时（${TIMEOUT}s）—— 远端命令可能仍在运行，先确认其状态再决定是否重试"
  say "  提示：长任务用 nohup / setsid 放后台，或用 -t 调大超时"
elif [ "$rc" -ne 0 ]; then
  err "远端命令退出码 ${rc}（耗时 ${dur}s）"
  diagnose "$(cat "$OUT_FILE")"
else
  say "${C_GRN}OK${C_OFF} (rc=0, ${dur}s)"
fi

# 变更成功后把档案里受影响的段落标脏 —— 这样"改动之后档案同步更新"不靠人记得。
# 只标受影响的段落而不是整份作废：改了一个容器不该让硬件信息也重新采集。
# 尽力而为：找不到 profile_store.sh、标脏失败，都静默忽略，绝不影响命令本身的退出码。
if [ "$rc" -eq 0 ] && [ "$RISK_TIER" -ge 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  PS="$SCRIPT_DIR_SELF/profile_store.sh"
  if [ -f "$PS" ]; then
    secs=""
    # 一张小映射表：命令动了什么，就只让相应的段落失效
    case "$COMMAND" in
      *docker*compose*|*docker*run*|*docker*start*|*docker*stop*|*docker*rm*)
        secs="docker,services" ;;
      *docker*)             secs="docker" ;;
      *systemctl*|*service\ *) secs="services" ;;
      *apt*|*yum*|*dnf*|*pip\ install*|*npm\ install*) secs="services,runtimes" ;;
      *ufw*|*firewall-cmd*|*iptables*|*nft*) secs="security" ;;
      *mount*|*fstab*|*mkfs*|*parted*|*fdisk*|*lvm*) secs="storage" ;;
      *useradd*|*usermod*|*userdel*|*passwd*) secs="security,services" ;;
      *nginx*|*httpd*|*nginx.conf*) secs="services,runtimes" ;;
    esac
    if [ -n "$secs" ]; then
      bash "$PS" mark-stale -H "$HOST" --sections "$secs" \
        --reason "$(printf '%s' "$COMMAND" | tr '\n\r\t' '   ' | cut -c1-120)" >/dev/null 2>&1 || true
    fi
  fi
fi

log_cmd "$rc" "$dur"
exit "$rc"
