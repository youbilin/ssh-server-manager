#!/usr/bin/env bash
# batch_run.sh - 对多台服务器执行同一命令并汇总结果
#
# 设计意图：批量会把错误放大，所以这里做了三件事来对抗它 ——
#   1) 执行前一定把「确切的目标清单」打印出来，让人有机会发现清单是错的
#   2) 每台机器都通过 ssh_exec.sh 执行，风险分级与审计日志在批量场景同样生效
#   3) 一台失败不影响其他机器，但失败清单一定单独列出（只报"大部分成功"是危险的）
#
# 用法:
#   ./batch_run.sh --inventory inv.yaml --tags web --cmd 'uptime'
#   ./batch_run.sh --hosts-file hosts.txt --cmd 'systemctl is-active nginx'
#   ./batch_run.sh --hosts 'web1 web2' --cmd 'df -h' --parallel 2
#   ./batch_run.sh --from-ssh-config 'web*' --cmd 'uptime'
#   ./batch_run.sh --inventory inv.yaml --tags web --cmd 'rm -rf /tmp/cache' --dry-run
#
# 退出码: 0 全部成功 | 1 有主机失败 | 2 用法错误 | 3 目标清单未确认

set -uo pipefail
LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_EXEC="$SCRIPT_DIR/ssh_exec.sh"

INVENTORY=""
HOSTS_INLINE=""
HOSTS_FILE=""
FROM_SSH_CONFIG=""
SSH_CONFIG_FILTER=""
TAGS=""
EXCLUDE=""
CMD=""
PARALLEL=5
TIMEOUT=30
DRY_RUN=0
CONFIRM_DANGER=0
ASSUME_YES=0
STOP_ON_ERROR=0
MAX_OUTPUT_LINES=40

DEF_USER=""
DEF_PORT=""
DEF_JUMP=""
DEF_IDENTITY=""
# 认证：批量场景下密码尤其要小心 —— 口令只从环境变量/文件/交互读，
# 一次输入、每台机器复用，绝不写进命令行（那会进 ps 与 shell history）。
AUTH_MODE=""
PASSWORD_ENV=""
CREDENTIAL_FILE=""
PROMPT_CREDENTIAL=0
SAVE_CREDENTIAL=0

if [ -t 1 ]; then C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""; fi

err()  { printf '%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'

目标来源（四选一）:
  --inventory FILE       YAML 服务器清单（需要 python3 + PyYAML）
  --hosts-file FILE      纯文本清单，每行一个 host，格式: host [port] [user]
  --hosts "h1 h2 h3"     直接内联
  --from-ssh-config [G]  从 ~/.ssh/config 读取 Host 别名，G 为可选的通配过滤

目标过滤:
  --tags a,b             只选含任一 tag 的主机（需 --inventory）
  --exclude h1,h2        排除指定主机

执行控制:
  --cmd CMD              要执行的命令
  --parallel N           并发数（默认 5；变更操作建议 1）
  --timeout S            单机超时秒数（默认 30）
  --stop-on-error        任一台失败即停止派发后续主机
  --dry-run              只打印目标清单与风险判定，不执行
  --confirm-danger       声明已就高危命令向用户二次确认
  --yes                  确认目标清单（目标超过 10 台时必须显式给出）
  --max-output-lines N   成功主机最多回显多少行输出（默认 40，失败主机总是全量回显）

连接默认值（可被清单中的逐机配置覆盖）:
  --user U  --port P  --jump J  --identity FILE

认证（口令一次输入，每台机器复用；不进命令行、不进 ps、不进审计日志）:
  --auth MODE            auto（默认）| key | password
  --prompt-credential    交互式输入一次（无终端时改用下面两种）
  --password-env VAR     从环境变量读
  --credential-file F    从文件读（建议 0600）
  --save-credential      把口令存到 ~/.ssh-server-manager/credentials（默认不存）
USAGE
}

need_arg() { [ "$2" -ge 2 ] || { err "选项 $1 需要一个参数"; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --inventory)       need_arg "$1" $#; INVENTORY="$2"; shift 2 ;;
    --hosts)           need_arg "$1" $#; HOSTS_INLINE="$2"; shift 2 ;;
    --hosts-file)      need_arg "$1" $#; HOSTS_FILE="$2"; shift 2 ;;
    --from-ssh-config) FROM_SSH_CONFIG=1; shift; SSH_CONFIG_FILTER="${1:-}"; case "$SSH_CONFIG_FILTER" in -*) SSH_CONFIG_FILTER="" ;; *) [ -n "$SSH_CONFIG_FILTER" ] && shift ;; esac ;;
    --tags)            need_arg "$1" $#; TAGS="$2"; shift 2 ;;
    --exclude)         need_arg "$1" $#; EXCLUDE="$2"; shift 2 ;;
    --cmd)             need_arg "$1" $#; CMD="$2"; shift 2 ;;
    --parallel)        need_arg "$1" $#; PARALLEL="$2"; shift 2 ;;
    --timeout)         need_arg "$1" $#; TIMEOUT="$2"; shift 2 ;;
    --stop-on-error)   STOP_ON_ERROR=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --confirm-danger)  CONFIRM_DANGER=1; shift ;;
    --yes|-y)          ASSUME_YES=1; shift ;;
    --max-output-lines) need_arg "$1" $#; MAX_OUTPUT_LINES="$2"; shift 2 ;;
    --user)            need_arg "$1" $#; DEF_USER="$2"; shift 2 ;;
    --port)            need_arg "$1" $#; DEF_PORT="$2"; shift 2 ;;
    --jump)            need_arg "$1" $#; DEF_JUMP="$2"; shift 2 ;;
    --identity)        need_arg "$1" $#; DEF_IDENTITY="$2"; shift 2 ;;
    --auth)            need_arg "$1" $#; AUTH_MODE="$2"; shift 2 ;;
    --password-env)    need_arg "$1" $#; PASSWORD_ENV="$2"; shift 2 ;;
    --credential-file) need_arg "$1" $#; CREDENTIAL_FILE="$2"; shift 2 ;;
    --prompt-credential) PROMPT_CREDENTIAL=1; shift ;;
    --save-credential) SAVE_CREDENTIAL=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 err "未知选项: $1（用 --help 查看用法）"; exit 2 ;;
  esac
done

[ -n "$CMD" ] || { err "缺少 --cmd（要执行的命令）"; exit 2; }
case "${PARALLEL}${TIMEOUT}${MAX_OUTPUT_LINES}" in *[!0-9]*) err "并发/超时/行数必须是整数"; exit 2 ;; esac
[ "$PARALLEL" -ge 1 ] || { err "--parallel 至少为 1"; exit 2; }
[ -x "$SSH_EXEC" ] || [ -f "$SSH_EXEC" ] || { err "找不到 ssh_exec.sh（应与本脚本同目录）"; exit 2; }

# ---------- 目标清单解析 ----------
# 统一输出为 `|` 分隔: label|host|user|port|jump|identity
# 刻意不用 TAB：TAB 属于 IFS 的空白字符，read 会把连续 TAB 折叠成一个分隔符，
# 于是空字段会导致整行错位（端口跑到用户字段里去）。`|` 不是空白字符，空字段能保住位置。
HOSTS_RAW=""

# python 的可执行名在不同环境不一致（Debian 系是 python3，Anaconda/部分 macOS 是 python），
# 这里两个都接受，找不到就明确引导用户走不依赖 python 的路径。
PYTHON=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON="python"
fi

parse_inventory() {
  local file="$1"
  if [ -z "$PYTHON" ]; then
    err "解析 --inventory 需要 python3。可改用 --hosts-file 或 --hosts，它们不依赖 python。"
    return 1
  fi
  if ! "$PYTHON" -c 'import yaml' >/dev/null 2>&1; then
    err "缺少 PyYAML（pip install pyyaml），或改用 --hosts-file / --hosts。"
    return 1
  fi
  INVENTORY_PATH="$file" TAGS_FILTER="$TAGS" "$PYTHON" - <<'PY'
import os, sys, yaml

path = os.environ["INVENTORY_PATH"]
tags_filter = [t for t in os.environ.get("TAGS_FILTER", "").split(",") if t]

try:
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
except Exception as exc:
    sys.stderr.write("读取 inventory 失败: %s\n" % exc)
    sys.exit(1)

if not isinstance(doc, dict):
    sys.stderr.write("inventory 顶层必须是映射（含 defaults / hosts）\n")
    sys.exit(1)

defaults = doc.get("defaults") or {}
hosts = doc.get("hosts") or []
if not isinstance(hosts, list):
    sys.stderr.write("inventory 的 hosts 必须是列表\n")
    sys.exit(1)

for entry in hosts:
    if not isinstance(entry, dict):
        continue
    # 逐字段解析：显式留空（jump: ""）要能和"没写、沿用默认"区分开，
    # 否则跳板机自己会被 defaults 里的 jump 重新指回自己。
    def resolve(key):
        if key in entry:
            v = entry[key]
            return "-" if v in (None, "") else str(v)
        v = defaults.get(key)
        return "" if v in (None, "") else str(v)

    tags = entry.get("tags", defaults.get("tags")) or []
    if isinstance(tags, str):
        tags = [tags]
    if tags_filter and not (set(tags_filter) & set(str(t) for t in tags)):
        continue
    label = str(entry.get("alias") or entry.get("host") or "")
    host = str(entry.get("host") or entry.get("alias") or "")
    if not host:
        continue
    fields = [
        label,
        host,
        resolve("user"),
        resolve("port"),
        resolve("jump"),
        resolve("identity_file"),
    ]
    print("|".join(fields))
PY
}

if [ -n "$INVENTORY" ]; then
  [ -f "$INVENTORY" ] || { err "inventory 文件不存在: $INVENTORY"; exit 2; }
  HOSTS_RAW="$(parse_inventory "$INVENTORY")" || exit 2
elif [ -n "$HOSTS_FILE" ]; then
  [ -f "$HOSTS_FILE" ] || { err "主机清单文件不存在: $HOSTS_FILE"; exit 2; }
  # 每行: host [port] [user]；# 开头为注释
  HOSTS_RAW="$(awk '{
      sub(/#.*/, "");
      n = split($0, f, /[ \t]+/);
      if (n == 0 || f[1] == "") next;
      user = (n >= 3) ? f[3] : "";
      port = (n >= 2) ? f[2] : "";
      printf "%s|%s|%s|%s||\n", f[1], f[1], user, port;
    }' "$HOSTS_FILE")"
elif [ -n "$HOSTS_INLINE" ]; then
  HOSTS_RAW="$(for h in $HOSTS_INLINE; do printf '%s|%s||||\n' "$h" "$h"; done)"
elif [ "$FROM_SSH_CONFIG" -eq 1 ]; then
  cfg="${HOME}/.ssh/config"
  [ -f "$cfg" ] || { err "找不到 $cfg"; exit 2; }
  HOSTS_RAW="$(awk -v filt="$SSH_CONFIG_FILTER" '
      BEGIN {
        IGNORECASE = 1
        # 用户传的是 glob（如 web*），转成正则再来匹配
        if (filt != "") {
          rx = filt
          gsub(/[][(){}.+^$|\\]/, "\\\\&", rx)
          gsub(/\*/, ".*", rx)
          gsub(/\?/, ".", rx)
          pat = "^" rx "$"
        }
      }
      { sub(/#.*/, "") }
      $1 == "host" {
        for (i = 2; i <= NF; i++) {
          a = $i
          # ssh config 里的 Host 模式（含通配符）不是具体机器，跳过
          if (a ~ /[*?]/) continue
          if (filt != "" && a !~ pat) continue
          printf "%s|%s||||\n", a, a
        }
      }' "$cfg")"
else
  err "需要指定目标来源：--inventory / --hosts-file / --hosts / --from-ssh-config"
  exit 2
fi

# 应用 --exclude 与命令行连接默认值。
# "-" 表示清单里显式留空（该字段就该为空），不能被命令行默认值填回去。
HOSTS_RAW="$(printf '%s\n' "$HOSTS_RAW" | awk -F'|' -v ex="$EXCLUDE" -v du="$DEF_USER" -v dp="$DEF_PORT" \
  -v dj="$DEF_JUMP" -v di="$DEF_IDENTITY" '
  BEGIN { n = split(ex, e, ","); for (i = 1; i <= n; i++) skip[e[i]] = 1 }
  NF >= 2 && $2 != "" {
    if ($1 in skip || $2 in skip) next
    for (i = 3; i <= 6; i++) if ($i == "-") $i = ""
    if ($3 == "") $3 = du
    if ($4 == "") $4 = dp
    if ($5 == "") $5 = dj
    if ($6 == "") $6 = di
    printf "%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, $6
  }')"

COUNT="$(printf '%s\n' "$HOSTS_RAW" | grep -c . || true)"
if [ "${COUNT:-0}" -eq 0 ]; then
  err "目标清单为空 —— 检查 tags / exclude / 清单文件内容，别在清单为空时继续。"
  exit 2
fi

# ---------- 目标清单always可见 ----------
printf '%s目标清单（%s 台）:%s\n' "$C_YEL" "$COUNT" "$C_OFF"
printf '%s\n' "$HOSTS_RAW" | awk -F'|' '{
  tgt = $2; if ($3 != "") tgt = $3 "@" tgt; if ($4 != "") tgt = tgt ":" $4;
  extra = ""; if ($5 != "") extra = extra "  jump=" $5; if ($6 != "") extra = extra "  key=" $6;
  printf "  %-16s %s%s\n", $1, tgt, extra
}'

# ---------- 批量下的口令只问一次 ----------
# 逐台去问会说不过去：并发执行时多个提示会交错在一起，顺序执行时问 N 遍同样烦。
# 所以在这里问一次，导出成环境变量，子进程的 ssh_exec.sh 直接复用，不再重复提示。
if [ "$PROMPT_CREDENTIAL" -eq 1 ] && [ -z "${SSHMGR_PASSWORD:-}" ]; then
  # 注意：`[ -r /dev/tty ]` 是不够的 —— 无控制终端时该判断可能为真，
  # 真去读才报 "No such device or address"。所以真读一次并检查结果。
  pw=""; read_ok=0
  if [ -t 0 ]; then
    printf '请输入远端登录密码（%s 台机器共用；不会进入命令行或日志）: ' "$COUNT" >&2
    IFS= read -rs pw && read_ok=1
    printf '\n' >&2
  elif [ -e /dev/tty ]; then
    printf '请输入远端登录密码（%s 台机器共用；不会进入命令行或日志）: ' "$COUNT" >&2
    IFS= read -rs pw < /dev/tty 2>/dev/null && read_ok=1
    printf '\n' >&2
  fi
  if [ "$read_ok" -ne 1 ]; then
    err "--prompt-credential 需要终端，但当前环境没有可用的控制终端。"
    err "非交互场景请改用：--password-env VAR 或 --credential-file F"
    exit 2
  fi
  pw="${pw%$'\r'}"
  if [ -z "$pw" ]; then err "口令为空，已中止"; exit 2; fi
  SSHMGR_PASSWORD="$pw"
  export SSHMGR_PASSWORD
  export SSHMGR_PW_CACHED=1     # 告诉 run_one：别再让子进程去提示
  pw=""
fi

# ---------- 风险判定（复用 ssh_exec.sh，保证分级只有一处定义） ----------
TIER_OUT="$(bash "$SSH_EXEC" -H "$(printf '%s\n' "$HOSTS_RAW" | head -1 | cut -d'|' -f2)" --dry-run -c "$CMD" 2>&1)"
TIER="$(printf '%s\n' "$TIER_OUT" | sed -n 's/^风险等级  : tier\([0-9]\).*/\1/p' | head -1)"
TIER="${TIER:-0}"
TIER_WHY="$(printf '%s\n' "$TIER_OUT" | sed -n 's/^风险等级  : tier[0-9] (\(.*\))/\1/p' | head -1)"
printf '%s风险等级:%s tier%s%s\n' "$C_YEL" "$C_OFF" "$TIER" "${TIER_WHY:+  ($TIER_WHY)}"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n%s[dry-run] 未执行任何命令。以下是每台机器上会执行的内容:%s\n' "$C_DIM" "$C_OFF"
  printf '  通过 ssh_exec.sh 逐个执行: -c %s\n' "$(printf '%q' "$CMD")"
  printf '  超时 %ss / 并发 %s\n' "$TIMEOUT" "$PARALLEL"
  exit 0
fi

# ---------- 变更类操作的确认门槛 ----------
# 一次动 N 台机器时，"清单没看仔细"本身就是主要事故来源，所以这里不给跳过清单确认的余地。
if [ "$TIER" -ge 1 ] && [ "$COUNT" -gt 10 ] && [ "$ASSUME_YES" -ne 1 ]; then
  err "变更类命令作用于 ${COUNT} 台主机，需要显式加 --yes 确认目标清单无误。"
  printf '  先核对上面的清单：多一台或少一台，影响面都不一样。\n' >&2
  exit 3
fi
if [ "$TIER" -ge 2 ] && [ "$CONFIRM_DANGER" -ne 1 ]; then
  err "这是高危命令且作用于 ${COUNT} 台主机，需要 --confirm-danger。"
  printf '  建议先在一台机器上用 --hosts 单机验证，再放开到全部。\n' >&2
  exit 3
fi
if [ "$TIER" -ge 1 ]; then
  warn "变更类命令将作用于 ${COUNT} 台主机；失败的主机会在末尾单独列出。"
  if [ "$PARALLEL" -gt 1 ] && [ "$STOP_ON_ERROR" -ne 1 ]; then
    warn "并发 ${PARALLEL} 且未加 --stop-on-error：首次执行建议 --parallel 1 --stop-on-error。"
  fi
fi

# ---------- 执行 ----------
# 输出留在本地日志目录而不是临时目录：批量执行的结果是事后复盘的主要依据，
# 生成完就删掉等于把证据丢了。
# 与 ssh_exec.sh / profile_store.sh 认同一个家目录（SSHMGR_HOME 优先）
LOG_DIR="${SSHMGR_HOME:-${SSHMGR_LOG_DIR:-$HOME/.ssh-server-manager}}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if mkdir -p "$LOG_DIR/batch-$STAMP" 2>/dev/null; then
  OUTDIR="$LOG_DIR/batch-$STAMP"
else
  OUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/sshmgr-batch.XXXXXX")" || { err "无法创建输出目录"; exit 2; }
  warn "无法写入 $LOG_DIR，输出改存到临时目录 $OUTDIR（退出后可能被清理）"
fi

run_one() {
  local label="$1" host="$2" user="$3" port="$4" jump="$5" ident="$6"
  local args=(-H "$host")
  [ -n "$user" ] && args+=(-u "$user")
  [ -n "$port" ] && args+=(-p "$port")
  [ -n "$jump" ] && args+=(-J "$jump")
  [ -n "$ident" ] && args+=(-i "$ident")
  args+=(-t "$TIMEOUT" -c "$CMD")
  [ "$CONFIRM_DANGER" -eq 1 ] && args+=(--confirm-danger)
  # 认证选项透传到每台机器。口令本身留在环境变量/文件里由 ssh_exec.sh 读取，
  # 不进这个参数数组 —— ps 里看不到，审计日志里也不会记。
  [ -n "$AUTH_MODE" ] && args+=(--auth "$AUTH_MODE") || true
  [ -n "$PASSWORD_ENV" ] && args+=(--password-env "$PASSWORD_ENV") || true
  [ -n "$CREDENTIAL_FILE" ] && args+=(--credential-file "$CREDENTIAL_FILE") || true
  [ "$PROMPT_CREDENTIAL" -eq 1 ] && [ "${SSHMGR_PW_CACHED:-0}" != "1" ] && args+=(--prompt-credential) || true
  [ "$SAVE_CREDENTIAL" -eq 1 ] && args+=(--save-credential) || true

  {
    printf '### %s  (%s)\n' "$label" "$host"
    printf '### cmd: %s\n\n' "$CMD"
  } > "$OUTDIR/$label.log"
  bash "$SSH_EXEC" "${args[@]}" >> "$OUTDIR/$label.log" 2>&1
  printf '%s' "$?" > "$OUTDIR/$label.rc"
}

# --stop-on-error：只要已有任何一台失败，就不再派发新主机。
# 已经跑起来的那几台会自然跑完 —— 中途杀掉反而会留下状态不明的机器。
any_failed() {
  local f r
  for f in "$OUTDIR"/*.rc; do
    [ -e "$f" ] || continue
    r="$(cat "$f" 2>/dev/null)"
    if [ -n "$r" ] && [ "$r" != "0" ] && [ "$r" != "skipped" ]; then
      return 0
    fi
  done
  return 1
}

printf '\n%s开始执行（并发 %s，单机超时 %ss）...%s\n' "$C_DIM" "$PARALLEL" "$TIMEOUT" "$C_OFF"

pids=()
aborted=0
while IFS='|' read -r label host user port jump ident; do
  [ -n "$host" ] || continue
  if [ "$aborted" -eq 1 ]; then
    printf '%s' "skipped" > "$OUTDIR/$label.rc"
    printf '### %s  (%s)\n### 已跳过（--stop-on-error：前序主机失败后停止派发）\n' "$label" "$host" > "$OUTDIR/$label.log"
    continue
  fi
  printf '  -> 派发 %s\n' "$label"
  run_one "$label" "$host" "$user" "$port" "$jump" "$ident" &
  pids+=( $! )
  if [ "${#pids[@]}" -ge "$PARALLEL" ]; then
    wait "${pids[0]}" 2>/dev/null || true
    pids=("${pids[@]:1}")
    if [ "$STOP_ON_ERROR" -eq 1 ] && any_failed; then
      aborted=1
      warn "--stop-on-error：已检测到失败主机，停止派发后续主机"
    fi
  fi
done <<< "$HOSTS_RAW"

while [ "${#pids[@]}" -gt 0 ]; do
  wait "${pids[0]}" 2>/dev/null || true
  pids=("${pids[@]:1}")
done

# ---------- 汇总 ----------
printf '\n%s================ 结果汇总 ================%s\n' "$C_YEL" "$C_OFF"
OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_LIST=""

while IFS='|' read -r label host _rest; do
  [ -n "$host" ] || continue
  rc="$(cat "$OUTDIR/$label.rc" 2>/dev/null || echo unknown)"
  case "$rc" in
    0)        OK_COUNT=$((OK_COUNT + 1));   STATUS="${C_GRN}OK${C_OFF}" ;;
    skipped)  SKIP_COUNT=$((SKIP_COUNT + 1)); STATUS="${C_DIM}SKIPPED${C_OFF}" ;;
    *)        FAIL_COUNT=$((FAIL_COUNT + 1)); STATUS="${C_RED}FAIL(rc=$rc)${C_OFF}"; FAILED_LIST="$FAILED_LIST $label" ;;
  esac
  printf '  %-20s %s\n' "$label" "$STATUS"
  if [ "$rc" = "0" ]; then
    printf '%s\n' "$C_DIM"
    tail -n "$MAX_OUTPUT_LINES" "$OUTDIR/$label.log" 2>/dev/null | sed 's/^/      /'
    printf '%s\n' "$C_OFF"
  elif [ "$rc" != "skipped" ]; then
    # 失败主机全量回显：诊断信息通常就在被截断的那几行里
    cat "$OUTDIR/$label.log" 2>/dev/null | sed 's/^/      /'
  fi
done <<< "$HOSTS_RAW"

printf '\n%s总计:%s 成功 %s / 失败 %s / 跳过 %s （共 %s）\n' \
  "$C_YEL" "$C_OFF" "$OK_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '%s失败主机:%s%s\n' "$C_RED" "$C_OFF" "$FAILED_LIST"
  printf '这些主机需要单独复核 —— 批量结果里的"失败"不区分"命令报错"和"连不上"，\n'
  printf '两者的处理方式不同，别直接重跑。\n'
fi

printf '\n完整输出已保存在: %s\n' "$OUTDIR"
printf '（每次批量执行都会新开一个目录；确认不需要留档后可以自行清理旧目录）\n'

[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
