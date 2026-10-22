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
#   ./ssh_exec.sh -H web1 --upload ./app.tgz /tmp/app.tgz  # 上传，走同一套认证/审计
#   ./ssh_exec.sh -H web1 --download /var/log/app.log ./app.log
#   ./ssh_exec.sh -H web1 --dry-run -c 'rm -rf /tmp/x'     # 只看风险判定，不执行
#   ./ssh_exec.sh -H web1 --show-host-key                  # 只打印指纹，不写入
#   ./ssh_exec.sh -H web1 --accept-host-key --fingerprint SHA256:xxxx
#
# 执行阶段顺序：分级 -> dry-run -> 高危拒绝 -> 自检 -> 主机密钥 -> 认证 -> 预检 -> 执行。
# dry-run 与自检不会发起网络连接，也不会读取/保存凭据。
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

if [ ! -r "$SCRIPT_DIR_SELF/lib/risk.sh" ] || [ ! -r "$SCRIPT_DIR_SELF/lib/target.sh" ]; then
  printf '[error] 安装不完整：缺少 scripts/lib/risk.sh 或 scripts/lib/target.sh\n' >&2
  exit 1
fi
# shellcheck source=lib/risk.sh
. "$SCRIPT_DIR_SELF/lib/risk.sh"
# shellcheck source=lib/target.sh
. "$SCRIPT_DIR_SELF/lib/target.sh"

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
SHOW_HOST_KEY=0
FINGERPRINT=""
DRY_RUN=0
PRINT_TIER=0
DO_LOG=1
QUIET=0
LOG_LABEL=""
NO_PREFLIGHT=0
SELFTEST=0
# 文件传输：复用同一套认证/主机密钥/审计，避免 scp/rsync 绕过 wrapper
TRANSFER_MODE=""          # upload | download
UPLOAD_LOCAL=""
UPLOAD_REMOTE=""
DOWNLOAD_REMOTE=""
DOWNLOAD_LOCAL=""
RECURSIVE=0
# 密码认证
AUTH_MODE="auto"          # auto | key | password
PASSWORD_ENV=""           # --password-env VAR
CREDENTIAL_FILE="${SSHMGR_CREDENTIAL_FILE:-}"   # 显式指定
CONFIRM_CRED_FILE=""      # --credential-file F
SAVE_CREDENTIAL=0
USE_SAVED_CREDENTIAL=0
PROMPT_CREDENTIAL=0
PASSWORD=""               # 只在内存里；永不进命令行、日志、档案
ASKPASS_HELPER=""         # 临时 helper 路径
PW_TMPFILE=""
TMP_FILES=()              # 所有临时文件统一登记，cleanup 逐个删除

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
# ⚠ bash 的 `trap ... EXIT` 是**替换**而不是追加。全脚本只装一个 EXIT trap，
# 所有要清理的东西都登记在 TMP_FILES 里；否则后注册的 trap 会把前一个顶掉，
# 密码临时文件就会留在磁盘上。
OUT_FILE=""
ERR_FILE=""
WATCHDOG_PID=""
cleanup() {
  local f
  [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    for f in "${TMP_FILES[@]}"; do
      [ -n "${f:-}" ] && rm -f "$f" 2>/dev/null
    done
  fi
  [ -n "${OUT_FILE:-}" ] && rm -f "$OUT_FILE" 2>/dev/null
  [ -n "${ERR_FILE:-}" ] && rm -f "$ERR_FILE" 2>/dev/null
  [ -n "${ASKPASS_HELPER:-}" ] && rm -f "$ASKPASS_HELPER" 2>/dev/null
  [ -n "${PW_TMPFILE:-}" ] && rm -f "$PW_TMPFILE" 2>/dev/null
  PASSWORD=""
  return 0
}
on_signal() { cleanup; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
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
      --dry-run          只打印将执行的命令与风险等级，不执行；不连接、不读口令
      --print-tier       只输出风险等级数字（0/1/2），不连接、不需要 -H
      --upload LOCAL REMOTE
                         上传文件：LOCAL -> 远端 REMOTE（走同一套认证、审计与分级）
      --download REMOTE LOCAL
                         下载文件：远端 REMOTE -> 本地 LOCAL
      --recursive        配合 --upload/--download 传输目录（scp -r）
      --accept-host-key  首次连接时把远端指纹写入 known_hosts（须先人工核对指纹）
                         单独使用即可，不必同时给 -c；写入前必须提供 --fingerprint
      --show-host-key    只扫描并打印候选指纹，不写入 known_hosts
      --fingerprint FP   配合 --accept-host-key：只有扫描到的指纹与这个值**完全一致**
                         才写入，且只写入匹配的那一条密钥
      --no-log           不写审计日志（默认写入，用于事故复盘）
  -q, --quiet            只输出远端原始内容，不带装饰（供其他脚本调用）
      --label TEXT       审计日志里记录的操作说明，替代原始命令
                         （脚本模式或包装脚本用它，事后复盘才看得懂日志）
      --selftest         自检：打印 ssh 路径/版本、askpass 支持、/dev/tcp、
                         GNU timeout/内置看门狗、连接复用目录。连不上时先跑这个
  -h, --help             显示本帮助

认证（密码与密钥是平等的两条路，给什么用什么，不强推密钥）:
      --auth MODE        auto（默认）| key | password
                         auto：有可用密钥就用密钥，否则用密码
                         password：明确走密码，会关掉公钥尝试
      --password-env VAR 从环境变量 VAR 读口令（不进命令行）
      --credential-file F 从文件读口令（建议 0600；会剥掉行尾 CR）
      --prompt-credential 交互式输入口令（read -s，不进 shell history）
      --use-saved-credential
                         读取 ~/.ssh-server-manager/credentials（配合 --save-credential）
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
  SSHMGR_SCP              指定 scp 可执行文件（--upload/--download 用）
  SSHMGR_ASKPASS_DEBUG=1  把 askpass 收到的 prompt 记到 askpass.log（绝不记口令），
                          用于排查"口令为什么没发出去"
  SSHMGR_NO_MUX=1         关闭连接复用（默认开 ControlMaster，10 分钟内只认证一次）
  SSHMGR_AUDIT_MAX_BYTES  审计日志超过该字节数时轮转为 audit.log.1（默认关闭）
  SSHMGR_NO_TIMEOUT=1     强制使用内置 bash 看门狗（测试/诊断用）
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
    --show-host-key)   SHOW_HOST_KEY=1; shift ;;
    --fingerprint)     need_arg "$1" $#; FINGERPRINT="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --print-tier)      PRINT_TIER=1; shift ;;
    --upload)
      [ $# -ge 3 ] || { err "--upload 需要 LOCAL 和 REMOTE 两个参数"; exit 1; }
      TRANSFER_MODE="upload"; UPLOAD_LOCAL="$2"; UPLOAD_REMOTE="$3"; shift 3 ;;
    --download)
      [ $# -ge 3 ] || { err "--download 需要 REMOTE 和 LOCAL 两个参数"; exit 1; }
      TRANSFER_MODE="download"; DOWNLOAD_REMOTE="$2"; DOWNLOAD_LOCAL="$3"; shift 3 ;;
    --recursive)       RECURSIVE=1; shift ;;
    --no-log)          DO_LOG=0; shift ;;
    --label)           need_arg "$1" $#; LOG_LABEL="$2"; shift 2 ;;
    --selftest)        SELFTEST=1; shift ;;
    --auth)            need_arg "$1" $#; AUTH_MODE="$2"; shift 2 ;;
    --password-env)    need_arg "$1" $#; PASSWORD_ENV="$2"; shift 2 ;;
    --credential-file) need_arg "$1" $#; CONFIRM_CRED_FILE="$2"; shift 2 ;;
    --save-credential) SAVE_CREDENTIAL=1; shift ;;
    --use-saved-credential) USE_SAVED_CREDENTIAL=1; shift ;;
    --prompt-credential) PROMPT_CREDENTIAL=1; shift ;;
    -q|--quiet)        QUIET=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; COMMAND="$*"; break ;;
    -*)                err "未知选项: $1（用 --help 查看用法）"; exit 1 ;;
    *)
      if [ -z "$HOST" ]; then
        HOST="$1"; shift
      elif [ -n "$COMMAND" ] || [ -n "$SCRIPT_FILE" ]; then
        # -c/-f 已经给出命令，却还有裸的位置参数：这几乎总是"命令没被引号包住"，
        # 被外层 shell（PowerShell 尤其常见）拆成了多个参数。
        # 静默改变要执行/要记录的内容比报错危险得多，所以这里直接拒绝。
        err "命令已被 -c/-f 指定，却又收到多余的位置参数: $*"
        err "  -c 的命令必须整体加引号；否则外层 shell 会把它拆成多个参数，"
        err "  风险分级将作用在被截断的片段上（高危命令可能被误判为只读）。"
        err "  正确写法: -c '<完整命令>'  或改用 -- <完整命令>"
        exit 1
      else
        COMMAND="$*"; break
      fi
      ;;
  esac
done

# ---------- 基础校验 ----------
case "$AUTH_MODE" in auto|key|password) ;; *) err "--auth 只能是 auto|key|password"; exit 1 ;; esac

case "$TIMEOUT" in ''|*[!0-9]*) err "超时必须是整数秒"; exit 1 ;; esac
case "$CONNECT_TIMEOUT" in ''|*[!0-9]*) err "连接超时必须是整数秒"; exit 1 ;; esac
[ "$TIMEOUT" -ge 1 ] || { err "超时至少为 1 秒"; exit 1; }
[ "$CONNECT_TIMEOUT" -ge 1 ] || { err "连接超时至少为 1 秒"; exit 1; }

if [ -n "$PORT" ]; then
  case "$PORT" in ''|*[!0-9]*) err "端口必须是数字"; exit 1 ;; esac
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { err "端口必须在 1-65535 之间"; exit 1; }
fi

if [ -n "$FINGERPRINT" ]; then
  case "$FINGERPRINT" in
    SHA256:*) ;;
    *) err "--fingerprint 必须是完整的 SHA256:... 指纹"; exit 1 ;;
  esac
fi

if [ "$NO_PREFLIGHT" -eq 1 ] && [ "$PREFLIGHT" -eq 1 ]; then
  err "--preflight 与 --no-preflight 不能同时使用"; exit 1
fi
if [ -n "$TRANSFER_MODE" ] && { [ -n "$COMMAND" ] || [ -n "$SCRIPT_FILE" ]; }; then
  err "--upload/--download 不能与 -c/-f 同时使用"; exit 1
fi
if [ "$RECURSIVE" -eq 1 ] && [ -z "$TRANSFER_MODE" ]; then
  err "--recursive 只能配合 --upload/--download 使用"; exit 1
fi
if [ "$ACCEPT_HOST_KEY" -eq 1 ] && [ "$SHOW_HOST_KEY" -eq 1 ]; then
  err "--accept-host-key 与 --show-host-key 不能同时使用"; exit 1
fi
if [ "$SHOW_HOST_KEY" -eq 1 ] && { [ -n "$COMMAND" ] || [ -n "$SCRIPT_FILE" ] || [ "$PREFLIGHT" -eq 1 ] || [ -n "$TRANSFER_MODE" ]; }; then
  err "--show-host-key 只扫描并打印指纹，不能与命令/传输/--preflight 同时使用"; exit 1
fi
if [ -n "$FINGERPRINT" ] && [ "$ACCEPT_HOST_KEY" -eq 0 ] && [ "$SHOW_HOST_KEY" -eq 0 ]; then
  err "--fingerprint 只能配合 --accept-host-key 或 --show-host-key 使用"; exit 1
fi
if [ "$AUTH_MODE" = "key" ] && { [ -n "$PASSWORD_ENV" ] || [ -n "$CONFIRM_CRED_FILE" ] || [ "$PROMPT_CREDENTIAL" -eq 1 ] || [ "$SAVE_CREDENTIAL" -eq 1 ] || [ "$USE_SAVED_CREDENTIAL" -eq 1 ]; }; then
  err "--auth key 与密码相关选项冲突"; exit 1
fi

# -H user@host：把 user 拆出来，避免和 -u 叠成 user2@user1@host
if [ -n "$HOST" ]; then
  case "$HOST" in
    *@*)
      _host_user="${HOST%%@*}"
      HOST="${HOST#*@}"
      if [ -n "$USER_NAME" ] && [ "$USER_NAME" != "$_host_user" ]; then
        err "-H 中的用户 ($_host_user) 与 -u ($USER_NAME) 不一致"; exit 1
      fi
      USER_NAME="$_host_user"
      ;;
  esac
  case "$HOST" in
    -*) err "主机名不能以 - 开头: $HOST"; exit 1 ;;
    *[[:space:]]*|*"'"*|*'"'*|*';'*|*'$'*|*'`'*|*'|'*|*'&'*|*'<'*|*'>'*) err "主机名包含不安全字符: $HOST"; exit 1 ;;
  esac
fi

[ -n "$HOST" ] || {
  if [ "$SELFTEST" -eq 1 ] || [ "$PRINT_TIER" -eq 1 ]; then :; else
    err "必须指定目标主机（-H）"; exit 1
  fi
}
if [ -z "$COMMAND" ] && [ -z "$SCRIPT_FILE" ] && [ "$PREFLIGHT" -eq 0 ] && [ "$SELFTEST" -eq 0 ] && [ "$PRINT_TIER" -eq 0 ] && [ "$ACCEPT_HOST_KEY" -eq 0 ] && [ "$SHOW_HOST_KEY" -eq 0 ] && [ -z "$TRANSFER_MODE" ]; then
  err "需要 -c '命令'、-f 脚本文件、--upload/--download、--preflight、--accept-host-key 或 --selftest 之一"; exit 1
fi

if [ -n "$TRANSFER_MODE" ]; then
  SCP_BIN="${SSHMGR_SCP:-scp}"
  command -v "$SCP_BIN" >/dev/null 2>&1 || [ -x "$SCP_BIN" ] || { err "找不到 scp 可执行文件: $SCP_BIN（可用 SSHMGR_SCP 指定）"; exit 1; }
  if [ "$TRANSFER_MODE" = "upload" ]; then
    [ -e "$UPLOAD_LOCAL" ] || { err "本地路径不存在: $UPLOAD_LOCAL"; exit 1; }
    [ -n "$HOST" ] || { err "--upload 需要目标主机（-H）"; exit 1; }
    [ -n "$UPLOAD_REMOTE" ] || { err "远端路径不能为空"; exit 1; }
    case "$UPLOAD_REMOTE" in *$'\n'*|*$'\r'*) err "远端路径包含换行"; exit 1 ;; esac
  else
    [ -n "$HOST" ] || { err "--download 需要目标主机（-H）"; exit 1; }
    [ -n "$DOWNLOAD_REMOTE" ] || { err "远端路径不能为空"; exit 1; }
    case "$DOWNLOAD_REMOTE" in *$'\n'*|*$'\r'*) err "远端路径包含换行"; exit 1 ;; esac
    [ -d "$(dirname "$DOWNLOAD_LOCAL")" ] || { err "本地目标目录不存在: $(dirname "$DOWNLOAD_LOCAL")"; exit 1; }
  fi
fi

if [ -n "$SCRIPT_FILE" ]; then
  [ -f "$SCRIPT_FILE" ] || { err "脚本文件不存在: $SCRIPT_FILE"; exit 1; }
  SCRIPT_FILE="$(cd "$(dirname "$SCRIPT_FILE")" && pwd)/$(basename "$SCRIPT_FILE")"
  if [ -n "$SCRIPT_ARGS" ]; then
    REMOTE_SCRIPT_CMD="bash -s -- $SCRIPT_ARGS"
  fi
  [ -n "$COMMAND" ] || COMMAND="$REMOTE_SCRIPT_CMD < $(basename "$SCRIPT_FILE")"
fi

# 目标标签要在分级/拒绝/日志之前确定。
TARGET="$HOST"
TARGET_LABEL="$HOST"
if [ -n "$USER_NAME" ]; then
  TARGET="${USER_NAME}@${HOST}"
  TARGET_LABEL="$TARGET"
fi

if [ "$TRANSFER_MODE" = "upload" ]; then
  COMMAND="scp $([ "$RECURSIVE" -eq 1 ] && echo '-r ')${UPLOAD_LOCAL} ${TARGET}:${UPLOAD_REMOTE}"
elif [ "$TRANSFER_MODE" = "download" ]; then
  COMMAND="scp $([ "$RECURSIVE" -eq 1 ] && echo '-r ')${TARGET}:${DOWNLOAD_REMOTE} ${DOWNLOAD_LOCAL}"
fi

# ---------- 风险分级 ----------
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
else
  sshmgr_classify "$COMMAND"
fi

# ---------- 审计日志 ----------
file_digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -c1-12
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | cut -c1-12
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print substr($NF,1,12)}'
  fi
}

_log_escape() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/|/\\|/g'
}

log_cmd() {
  [ "$DO_LOG" -eq 1 ] || return 0
  local rc="$1" dur="$2" override="${3:-}" what sum max
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
  max="${SSHMGR_AUDIT_MAX_BYTES:-0}"
  case "$max" in ''|*[!0-9]*) max=0 ;; esac
  if [ "$max" -gt 0 ] && [ -f "$LOG_FILE" ]; then
    if [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$max" ]; then
      mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
  fi
  if [ ! -e "$LOG_FILE" ]; then
    ( umask 077; : > "$LOG_FILE" ) 2>/dev/null || return 0
  fi
  printf '%s | %s | tier%s | rc=%s | %ss | %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(_log_escape "$TARGET_LABEL")" "$RISK_TIER" "$rc" "$dur" "$(_log_escape "$what")" \
    >> "$LOG_FILE" 2>/dev/null || true
}

# --print-tier：给 batch_run.sh 等调用方一个稳定接口，不再解析中文 dry-run 输出。
if [ "$PRINT_TIER" -eq 1 ]; then
  printf '%s\n' "$RISK_TIER"
  exit 0
fi

# ---------- --dry-run ----------
# ⚠ 输出格式有下游依赖：
#   batch_run.sh 用
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

# ---------- ssh / timeout 探测 ----------
# 必须放在认证逻辑之前：key_auth_possible 会用它。
# Windows 上 PATH 里可能同时有 msys 的 ssh 和 C:\Windows\System32\OpenSSH\ssh.exe。
# 后者是原生程序，**无法执行 shebang 脚本**，因此 askpass helper 会失败、密码登录用不了。
SSH_BIN="${SSHMGR_SSH:-ssh}"
if [ ! -x "$SSH_BIN" ] && ! command -v "$SSH_BIN" >/dev/null 2>&1; then
  err "找不到 ssh 可执行文件: $SSH_BIN（可用 SSHMGR_SSH 指定路径）"
  exit 1
fi

# 优先用 GNU coreutils 的 timeout。Windows / Git-Bash 下 `timeout` 可能解析到
# Windows 自带的 timeout.exe（等待按键，语义完全不同），因此用 --version 探测避开它。
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi
# 测试/诊断用：强制走内置看门狗
[ "${SSHMGR_NO_TIMEOUT:-0}" = "1" ] && TIMEOUT_BIN=""

# 没有 GNU timeout（例如默认 macOS）时的兜底看门狗。返回 124 与 timeout(1) 一致。
run_limited() { # <seconds> <command...>
  local secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
    return $?
  fi
  local marker pid wd rc
  marker="$(mktemp "${TMPDIR:-/tmp}/sshmgr-wd.XXXXXX" 2>/dev/null)" || { "$@"; return $?; }
  # 后台任务在非交互 shell 中会把 stdin 接到 /dev/null；脚本模式（-f）正是把
  # 远端脚本从 stdin 送进去的，必须先保存并显式恢复 fd 0，否则脚本会变成空文件。
  exec 9<&0
  "$@" <&9 &
  pid=$!
  exec 9<&-
  (
    sleep "$secs" 2>/dev/null || true
    printf 'timeout\n' > "$marker" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  wd=$!
  WATCHDOG_PID="$wd"
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  WATCHDOG_PID=""
  if [ -s "$marker" ]; then rc=124; fi
  rm -f "$marker" 2>/dev/null
  return "$rc"
}

# ---------- 凭据：读取 / askpass ----------
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
  # 优先级：--password-env > SSHMGR_PASSWORD > --credential-file > SSHMGR_CREDENTIAL_FILE
  #         > --use-saved-credential > --prompt-credential
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
  if [ "$USE_SAVED_CREDENTIAL" -eq 1 ]; then
    PASSWORD="$(read_credential_file "$CRED_FILE_DEFAULT")" || {
      err "无法从 $CRED_FILE_DEFAULT 读到口令（先运行一次带 --save-credential 的命令）"; exit 1; }
    return 0
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

# 写 askpass helper：ssh 通过 execlp 执行它，所以必须是可执行的**真实文件**，
# 且 stdout 只能打印口令（诊断信息一律走 stderr）。
write_askpass_helper() { # $1=helper 路径 $2=口令文件
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
    printf 'cat "%s" 2>/dev/null\n' "$2"
    printf 'exit 0\n'
  } > "$1" || return 1
  chmod 700 "$1" 2>/dev/null || true
  return 0
}

setup_askpass() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  ASKPASS_HELPER="$(mktemp "${TMPDIR:-/tmp}/sshmgr-askpass.XXXXXX")" || return 1
  PW_TMPFILE="$(mktemp "${TMPDIR:-/tmp}/sshmgr-pw.XXXXXX")" || return 1
  TMP_FILES+=("$ASKPASS_HELPER" "$PW_TMPFILE")
  chmod 700 "$ASKPASS_HELPER" "$PW_TMPFILE" 2>/dev/null || true
  ( umask 077; printf '%s\n' "$PASSWORD" > "$PW_TMPFILE" ) || return 1
  write_askpass_helper "$ASKPASS_HELPER" "$PW_TMPFILE" || return 1
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
  run_limited 12 "$SSH_BIN" "${t[@]}" "$target" true >/dev/null 2>&1
}

# ---------- --selftest ----------
# 一屏把"为什么连不上/口令为什么没发出去"能自查的东西全打出来。
# 这一步发生在认证之前：不读口令、不连目标、不留下任何凭据文件。
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
  ST() { local w pad="" i; w="$(_sw "$1")"; for ((i=w; i<22; i++)); do pad="$pad "; done; printf '%s%s %s\n' "$1" "$pad" "$2"; }
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
  for _c in scp ssh-keygen ssh-keyscan rsync sha256sum shasum openssl; do
    if command -v "$_c" >/dev/null 2>&1; then
      ST "工具: $_c" "可用"
    else
      case "$_c" in
        rsync|shasum) ST "工具: $_c" "未安装（可选）" ;;
        *) ST "工具: $_c" "缺失" ;;
      esac
    fi
  done
  _dt_err="$( (exec 3<>/dev/tcp/127.0.0.1/1) 2>&1 | head -1 )"
  case "$_dt_err" in
    *"No such file or directory"*|*"not supported"*|*"unknown file system"*)
      ST "/dev/tcp" "不可用（这个 bash 未编译 net redirection）" ;;
    *"Connection refused"*)
      ST "/dev/tcp" "可用（连接被拒绝，符合预期）" ;;
    *)
      ST "/dev/tcp" "可用（未预期错误: ${_dt_err:-unknown}）" ;;
  esac
  ST "GNU timeout" "${TIMEOUT_BIN:-未找到（使用内置 bash 看门狗）}"
  ST "审计日志目录" "$LOG_DIR"
  ST "凭据文件" "$CRED_FILE_DEFAULT $([ -f "$CRED_FILE_DEFAULT" ] && echo '(存在)' || echo '(未创建)')"
  if [ "${SSHMGR_NO_MUX:-0}" = "1" ]; then
    ST "连接复用" "已通过 SSHMGR_NO_MUX 关闭"
  elif mkdir -p "$LOG_DIR/cm" 2>/dev/null; then
    ST "连接复用" "目录可创建（$LOG_DIR/cm；实际复用未验证）"
  else
    ST "连接复用" "不可用（$LOG_DIR/cm 建不出来）"
  fi
  if [ -n "$HOST" ]; then
    sshmgr_resolve_target "$SSH_BIN" "$HOST" "$USER_NAME" "$PORT" "$JUMP" "$IDENTITY"
    ST "解析目标" "host=${SSHMGR_TARGET_HOST} port=${SSHMGR_TARGET_PORT} user=${SSHMGR_TARGET_USER:-?}"
    ST "known_hosts 条目" "${SSHMGR_TARGET_KH_ENTRY:-?}"
    [ "$SSHMGR_TARGET_RESOLVED" -eq 1 ] && ST "ssh -G" "解析成功" || ST "ssh -G" "解析失败，使用调用方参数"
  fi
  # askpass helper 端到端自测：独立临时文件，绝不碰真实口令。
  printf '\n生成一个临时 askpass helper 做端到端自测...\n'
  _saved_pw_test="selftest-$(date +%s)"
  _sth="$(mktemp "${TMPDIR:-/tmp}/sshmgr-st-askpass.XXXXXX" 2>/dev/null)" || _sth=""
  _stp="$(mktemp "${TMPDIR:-/tmp}/sshmgr-st-pw.XXXXXX" 2>/dev/null)" || _stp=""
  if [ -n "$_sth" ] && [ -n "$_stp" ]; then
    ( umask 077; printf '%s\n' "$_saved_pw_test" > "$_stp" ) 2>/dev/null
    if write_askpass_helper "$_sth" "$_stp" 2>/dev/null; then
      got="$("$_sth" "test prompt" 2>/dev/null)"
      if [ "$got" = "$_saved_pw_test" ]; then
        ST "askpass 端到端" "通过（helper 能正确回传口令）"
      else
        ST "askpass 端到端" "失败：helper 回传了 '${got:0:20}'，与预期不符"
      fi
    else
      ST "askpass 端到端" "失败：helper 建不出来（临时目录不可写？）"
    fi
  else
    ST "askpass 端到端" "失败：临时文件建不出来"
  fi
  rm -f "${_sth:-}" "${_stp:-}" 2>/dev/null
  PASSWORD=""
  _saved_pw_test=""
  printf '\n透明代理检查（对照探测保留地址，能连上说明本机栈在拦截流量）：\n'
  if [ -f "$SCRIPT_DIR_SELF/tcping.sh" ]; then
    bash "$SCRIPT_DIR_SELF/tcping.sh" -H 192.0.2.1 -p 9 -n 1 -q 2>/dev/null | head -1
  fi
  exit 0
fi

# ---------- 主机密钥 ----------
# 只写入用户明确给过指纹的那一条密钥。指纹是机制，不是口头承诺。
handle_host_key() {
  command -v ssh-keyscan >/dev/null 2>&1 || { err "缺少 ssh-keyscan，无法扫描主机密钥"; exit 2; }
  command -v ssh-keygen >/dev/null 2>&1 || { err "缺少 ssh-keygen，无法核对指纹"; exit 2; }

  sshmgr_resolve_target "$SSH_BIN" "$HOST" "$USER_NAME" "$PORT" "$JUMP" "$IDENTITY"
  local scan_host="$SSHMGR_TARGET_HOST"
  local scan_port="$SSHMGR_TARGET_PORT"
  if ! sshmgr_target_safe_host "$scan_host"; then
    err "解析出的主机名包含不安全字符，拒绝拼进扫描命令: $scan_host"; exit 2
  fi
  case "$scan_port" in ''|*[!0-9]*) err "解析出的端口不是数字: $scan_port"; exit 2 ;; esac
  [ "$scan_port" -ge 1 ] && [ "$scan_port" -le 65535 ] || { err "解析出的端口越界: $scan_port"; exit 2; }

  say "${C_YEL}扫描 $scan_host:$scan_port 的主机密钥（ssh-keyscan 本身不提供认证，必须核对指纹）：${C_OFF}"
  local keys=""

  if [ -n "$SSHMGR_TARGET_JUMP" ]; then
    # ssh-keyscan 没有 -J；只能从跳板机上去扫目标。跳板机自己的 host key 仍按严格校验，
    # 所以跳板机必须先被信任，否则这里会在 host key 校验处失败。
    local remote_cmd
    remote_cmd="ssh-keyscan -p ${scan_port} -T 5 -t rsa,ecdsa,ed25519 '${scan_host}' 2>/dev/null"
    keys="$(run_limited 20 "$SSH_BIN" -J "$SSHMGR_TARGET_JUMP" -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o BatchMode=yes -o StrictHostKeyChecking=yes "$remote_cmd" 2>/dev/null)"
  else
    keys="$(run_limited 20 ssh-keyscan -p "$scan_port" -T 5 -t rsa,ecdsa,ed25519 "$scan_host" 2>/dev/null)"
  fi

  if [ -z "$keys" ]; then
    err "未能获取 $scan_host:$scan_port 的主机密钥（网络不通 / sshd 无响应 / 目标只对跳板机可见）"
    if [ -n "$SSHMGR_TARGET_JUMP" ]; then
      say "  经跳板机（-J $SSHMGR_TARGET_JUMP）时，跳板机本身也必须已在 known_hosts 中。"
      say "  先在跳板机上扫描目标并核对："
      say "    ssh-keyscan -p $scan_port $scan_host 2>/dev/null | ssh-keygen -lf -"
    fi
    exit 2
  fi

  local scanfp
  scanfp="$(printf '%s\n' "$keys" | ssh-keygen -lf - 2>/dev/null)"
  if [ -z "$scanfp" ]; then
    err "ssh-keygen 无法解析扫描结果"; exit 2
  fi
  printf '%s\n' "$scanfp" | sed 's/^/  /'

  local match_idx="" matched_key=""
  if [ -n "$FINGERPRINT" ]; then
    match_idx="$(printf '%s\n' "$scanfp" | awk -v fp="$FINGERPRINT" '$2==fp {print NR; exit}')"
    if [ -z "$match_idx" ]; then
      err "指纹不匹配！扫描到的指纹里没有完整等于 $FINGERPRINT 的值"
      err "已拒绝继续。这可能是中间人，也可能是你抄错了值 —— 两种情况都别继续。"
      exit 2
    fi
    matched_key="$(printf '%s\n' "$keys" | sed -n "${match_idx}p")"
    say "${C_GRN}指纹精确匹配（第 ${match_idx} 条），核对通过。${C_OFF}"
  else
    printf '\n%s请与云控制台或机房记录逐字符核对。%s\n' "$C_YEL" "$C_OFF"
    printf '%s--accept-host-key 必须同时提供 --fingerprint；--show-host-key 只查看，不写入。%s\n' "$C_YEL" "$C_OFF"
  fi

  if [ "$SHOW_HOST_KEY" -eq 1 ]; then
    if [ -z "$FINGERPRINT" ]; then
      say "（只查看模式，未写入 known_hosts）"
    else
      say "（只查看模式：指纹已核对，但未写入 known_hosts）"
    fi
    exit 0
  fi

  if [ -z "$FINGERPRINT" ]; then
    err "拒绝写入 known_hosts：没有提供 --fingerprint。"
    err "请核对上面打印的指纹后重新运行："
    err "  $PROG -H $HOST --accept-host-key --fingerprint SHA256:..."
    exit 2
  fi
  if [ -z "$SSHMGR_TARGET_KH_FILE" ]; then
    err "ssh 配置把 UserKnownHostsFile 设为 none；写入默认文件不会生效。"
    err "请先修正 ssh 配置，或把目标密钥手工加入可信来源。"
    exit 2
  fi

  local kh="$SSHMGR_TARGET_KH_FILE" entry="$SSHMGR_TARGET_KH_ENTRY"
  local oldfp="" oldfps=""
  if [ -f "$kh" ]; then
    oldfps="$(ssh-keygen -F "$entry" -f "$kh" 2>/dev/null | grep -v '^#' | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
  fi
  if [ -n "$oldfps" ]; then
    if printf '%s\n' "$oldfps" | grep -Fxq "$FINGERPRINT"; then
      say "${C_GRN}known_hosts 里已有相同指纹，无需重复写入。${C_OFF}"
      exit 0
    fi
    oldfp="$(printf '%s\n' "$oldfps" | head -1)"
    err "known_hosts 里 $entry 已存在，但指纹与这次核对的不一致："
    say "  已有: $oldfp"
    say "  提供: $FINGERPRINT"
    say "  这通常意味着目标重装了系统或换了机器，但也可能是中间人。"
    say "  确认是重装后，先删除旧记录再重试："
    say "    ssh-keygen -R \"$entry\""
    exit 2
  fi

  mkdir -p "$(dirname "$kh")" 2>/dev/null
  if [ -s "$kh" ] && [ "$(tail -c 1 "$kh" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$kh"
  fi
  printf '%s\n' "$matched_key" >> "$kh"
  chmod 600 "$kh" 2>/dev/null || true
  say "${C_GRN}已写入 $kh：$entry ${C_OFF}"
}

if [ "$ACCEPT_HOST_KEY" -eq 1 ] || [ "$SHOW_HOST_KEY" -eq 1 ]; then
  handle_host_key
  # 只接受/只查看时，不执行任何命令，也不做认证。
  if [ "$SHOW_HOST_KEY" -eq 1 ]; then exit 0; fi
  if [ -z "$COMMAND" ] && [ -z "$SCRIPT_FILE" ] && [ "$PREFLIGHT" -eq 0 ]; then exit 0; fi
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
      say "  --use-saved-credential  读取之前 --save-credential 保存的口令"
      exit 1
    }
    AUTH_RESOLVED="password"
    ;;
  auto)
    # auto：显式要求使用已存凭据时直接走密码；否则能免密就免密
    if [ "$USE_SAVED_CREDENTIAL" -eq 1 ]; then
      resolve_password || exit 1
      AUTH_RESOLVED="password"
    elif key_auth_possible; then
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
  # 口令已经写入私有临时文件；从子进程环境里移除来源，减少 /proc/<pid>/environ 暴露。
  if [ -n "$PASSWORD_ENV" ]; then unset "$PASSWORD_ENV" 2>/dev/null || true; fi
  unset SSHMGR_PASSWORD 2>/dev/null || true
fi

# --save-credential：只有用户明确要求才落盘，且尽力做到 0600
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
      say "  文件权限已设为 ${_actual}。之后可用 --use-saved-credential 复用。"
    else
      say "  ${C_YEL}注意：当前文件权限是 ${_actual:-未知}，不是 600 —— Git-Bash 的磁盘挂载通常是"
      say "        noacl，chmod 对权限位是空操作（改不了 Windows ACL）。${C_OFF}"
      say "        实际的保护边界是 %USERPROFILE% 目录的 ACL，而不是这个文件的 mode；"
    fi
    say "  同用户下任何进程（包括本 agent）都能读它。不想要了就 rm 掉。"
  fi
fi

# ---------- SSH 选项 ----------
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
  # 密钥路径：BatchMode 让认证失败立即报错而不是挂起等输入。
  SSH_OPTS+=( -o BatchMode=yes -o "NumberOfPasswordPrompts=0" )
fi

[ -n "$PORT" ] && SSH_OPTS+=( -p "$PORT" )
[ -n "$JUMP" ] && SSH_OPTS+=( -J "$JUMP" )
[ -n "$IDENTITY" ] && SSH_OPTS+=( -i "$IDENTITY" -o IdentitiesOnly=yes )

# 连接复用：默认每次调用要预检 + 执行 = 两次 TCP 握手、两次认证。
# 对密钥是延迟问题；对密码则是口令要重复提交两遍、Failed password 机会翻倍。
# ControlPersist 10m 让这段时间内只认证一次。msys 的 ssh 不会自己建 ControlPath 目录。
SSH_OPTS_CORE=("${SSH_OPTS[@]}")
MUX_ENABLED=0
if [ "${SSHMGR_NO_MUX:-0}" != "1" ]; then
  CM_DIR="$LOG_DIR/cm"
  if mkdir -p "$CM_DIR" 2>/dev/null; then
    chmod 700 "$CM_DIR" 2>/dev/null || true
    SSH_OPTS+=( -o ControlMaster=auto -o "ControlPath=$CM_DIR/%C" -o ControlPersist=10m )
    MUX_ENABLED=1
  fi
fi

# 文件传输单独走 scp，直接连接（不依赖容易失效的 control socket），
# 但认证方式、严格主机密钥和 askpass 与 ssh 路径完全一致。
SCP_OPTS=()
if [ -n "$TRANSFER_MODE" ]; then
  SCP_OPTS=(
    -S "$SSH_BIN"
    -o "ConnectTimeout=${CONNECT_TIMEOUT}"
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o "StrictHostKeyChecking=yes"
    -o ControlMaster=no
  )
  if [ "$AUTH_RESOLVED" = "password" ]; then
    SCP_OPTS+=( -o "BatchMode=no" -o "NumberOfPasswordPrompts=1" )
    SCP_OPTS+=( -o "PubkeyAuthentication=no" -o "PreferredAuthentications=password,keyboard-interactive" )
  else
    SCP_OPTS+=( -o BatchMode=yes -o "NumberOfPasswordPrompts=0" )
  fi
  [ -n "$PORT" ] && SCP_OPTS+=( -P "$PORT" )
  [ -n "$JUMP" ] && SCP_OPTS+=( -o "ProxyJump=$JUMP" )
  [ -n "$IDENTITY" ] && SCP_OPTS+=( -i "$IDENTITY" -o IdentitiesOnly=yes )
fi

# ---------- 错误诊断 ----------
# 把 ssh 的报错翻译成「下一步该做什么」，避免在错误方向上反复重试。
diagnose() {
  local text="$1"
  case "$text" in
    *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
      err "主机密钥校验失败 —— 目标不在 known_hosts 中，或指纹已变更。"
      say "  1) 先核对指纹（别跳过，指纹不符可能意味着中间人）："
      say "     $PROG -H $HOST --show-host-key"
      say "  2) 与云控制台或机房记录比对一致后，再加 --fingerprint 写入 known_hosts："
      say "     $PROG -H $HOST --accept-host-key --fingerprint SHA256:..."
      say "  3) 若确认是重装系统导致变更: ssh-keygen -R \"$HOST\" 后重新核对" ;;
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
      say "            或 --password-env VAR / --credential-file F / --use-saved-credential" ;;
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
    *"bash: not found"*|*"bash: command not found"*)
      err "目标主机没有 bash —— -f 脚本模式需要 bash。"
      say "  解决：Alpine 执行 apk add bash（需 root），或改用 -c 执行 POSIX sh 兼容命令" ;;
    *"command not found"*)
      warn "远端缺少该命令 —— 确认是否装在非标准路径，或需要先安装对应软件包。" ;;
  esac
}

# ---------- 连接预检 ----------
if [ "$RISK_TIER" -eq 1 ] && [ "$READ_ONLY_DECLARED" -eq 0 ]; then
  warn "变更类操作：确认已向用户说明影响面与回滚方式。"
fi

say "${C_DIM}-> ${TARGET_LABEL} (tier${RISK_TIER}${AUTH_RESOLVED:+, auth=${AUTH_RESOLVED}})${C_OFF}"

start_ts=$(date +%s)
preflight_rc=0
preflight_out=""
if [ "$NO_PREFLIGHT" -eq 0 ]; then
  # 脚本模式通过 stdin 交给远端 bash -s；Alpine 默认只有 ash，必须在预检就给出
  # 明确提示，而不是执行到一半才报一个含糊的 command not found。
  preflight_remote='true'
  # 用 sh -c 包一层：登录 shell 可能是 csh，但它一定有 /bin/sh。
  [ -n "$SCRIPT_FILE" ] && preflight_remote="sh -c 'command -v bash >/dev/null 2>&1 || { echo SSHMGR_PREFLIGHT_NO_BASH; exit 127; }'"
  preflight_out="$(run_limited "$CONNECT_TIMEOUT" "$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" "$preflight_remote" 2>&1)"
  preflight_rc=$?
  # 某些 Windows/Git-Bash + 透明代理/网络设备组合下 ControlMaster 会被重置。
  # 认证本身可能是成功的；自动退回单连接再试一次，而不是把用户推向排查网络。
  if [ "$preflight_rc" -ne 0 ] && [ "$MUX_ENABLED" -eq 1 ] && \
     printf '%s' "$preflight_out" | grep -Eqi 'mux_client|failed to connect to new control master|control master|multiplex'; then
    warn "连接复用（ControlMaster）失败，自动改用单连接重试（本次不复用连接）。"
    SSH_OPTS=("${SSH_OPTS_CORE[@]}")
    MUX_ENABLED=0
    preflight_out="$(run_limited "$CONNECT_TIMEOUT" "$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" "$preflight_remote" 2>&1)"
    preflight_rc=$?
  fi
fi

if [ "$preflight_rc" -ne 0 ] && printf '%s' "$preflight_out" | grep -q 'SSHMGR_PREFLIGHT_NO_BASH'; then
  err "目标主机没有 bash —— 本 skill 的 -f 脚本模式需要 bash。"
  say "  Alpine: apk add bash（需要 root）；安装后重试。"
  say "  不需要脚本时，可用 -c 执行 POSIX sh 兼容命令。"
  log_cmd 2 "$(( $(date +%s) - start_ts ))" "no-bash"
  exit 2
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
    hintline="$(bash "$PS" hint -H "$HOST" 2>/dev/null | head -1)" || hintline=""
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
ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/sshmgr-err.XXXXXX")" || { err "无法创建临时文件"; exit 1; }
TMP_FILES+=("$OUT_FILE" "$ERR_FILE")

# stdout 是调用方消费的载荷（profile/health 的 key=value、batch 的日志）；
# ssh 自己的警告（mux、IdentityFile）走 stderr，不能混进载荷。
if [ "$TRANSFER_MODE" = "upload" ]; then
  _scp_args=("${SCP_OPTS[@]}")
  [ "$RECURSIVE" -eq 1 ] && _scp_args+=(-r)
  run_limited "$TIMEOUT" "$SCP_BIN" "${_scp_args[@]}" -- "$UPLOAD_LOCAL" "${TARGET}:${UPLOAD_REMOTE}" > "$OUT_FILE" 2> "$ERR_FILE"
elif [ "$TRANSFER_MODE" = "download" ]; then
  _scp_args=("${SCP_OPTS[@]}")
  [ "$RECURSIVE" -eq 1 ] && _scp_args+=(-r)
  run_limited "$TIMEOUT" "$SCP_BIN" "${_scp_args[@]}" -- "${TARGET}:${DOWNLOAD_REMOTE}" "$DOWNLOAD_LOCAL" > "$OUT_FILE" 2> "$ERR_FILE"
elif [ -n "$SCRIPT_FILE" ]; then
  run_limited "$TIMEOUT" "$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" "$REMOTE_SCRIPT_CMD" < "$SCRIPT_FILE" > "$OUT_FILE" 2> "$ERR_FILE"
else
  run_limited "$TIMEOUT" "$SSH_BIN" "${SSH_OPTS[@]}" "$TARGET" "$COMMAND" > "$OUT_FILE" 2> "$ERR_FILE"
fi
rc=$?
dur=$(( $(date +%s) - start_ts ))

cat "$OUT_FILE"
if [ -s "$ERR_FILE" ]; then
  cat "$ERR_FILE" >&2
fi

if [ "$rc" -eq 124 ]; then
  err "执行超时（${TIMEOUT}s）—— 远端命令可能仍在运行，先确认其状态再决定是否重试"
  say "  提示：长任务用 nohup / setsid 放后台，或用 -t 调大超时"
elif [ "$rc" -ne 0 ]; then
  err "远端命令退出码 ${rc}（耗时 ${dur}s）"
  diagnose "$(cat "$OUT_FILE" 2>/dev/null; cat "$ERR_FILE" 2>/dev/null)"
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
      *nginx*|*httpd*) secs="services,runtimes" ;;
    esac
    if [ -n "$secs" ]; then
      bash "$PS" mark-stale -H "$HOST" --sections "$secs" \
        --reason "$(printf '%s' "$COMMAND" | tr '\n\r\t' '   ' | cut -c1-120)" >/dev/null 2>&1 || true
    fi
  fi
fi

log_cmd "$rc" "$dur"
exit "$rc"
