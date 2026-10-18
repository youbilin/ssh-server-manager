#!/usr/bin/env bash
# tcping.sh - 本地 TCP 握手延迟探测：只看"连得上吗、要多久"，不在远端产生任何负载
#
# 为什么不用 ping：ICMP 常被云安全组直接丢弃，而且它测的是网络层；
# 运维真正关心的是"TCP 能不能连上、要多久"。
# 为什么不在远端跑：在目标机上生成流量正是要避免的事。这里全部在本地发起，
# 只做 3~5 次 TCP 握手，对服务器是零负担。
#
# ⚠ 本机可能装透明代理（Clash/Mihomo 的 TUN 模式、部分杀软的流量扫描、企业 SSL 网关）。
#   这类软件会在本地**接受任意 TCP 连接**，包括 192.0.2.1 这种保留地址。
#   后果有两个，都会让"测延迟"这件事彻底失真：
#     1) 计时测到的是"到代理"的延迟，不是"到服务器"的延迟；
#     2) 连接"成功"也不能证明远端端口是开的 —— 是代理替你接的。
#   所以本脚本在正式探测前先做一次**对照探测**：连 192.0.2.1:9
#   （TEST-NET-1，保留地址，正常网络必须失败）。若它"成功"，说明本机栈在拦截流量，
#   本次结果会被标成 reliable=0，并且在输出里说明原因。
#   宁可报"这个数不可信"，也不要给一个看起来很确定的错数字。
#
# 计时实现（在 Windows/Git-Bash 上实测得出，直接决定这个工具能不能用）：
#   `timeout N bash -c ...` 一条链约 62 ms 纯 fork 开销，外部 `date` 约 24 ms/次。
#   若每次探测都 fork 一次再计时，本机 127.0.0.1（真实 RTT≈0）会测出 ~100 ms，
#   真实数字被完全淹没。所以这里整批探测只 fork 一次，循环内用 bash 内建变量
#   EPOCHREALTIME 取微秒、纯整数求差 —— 每次探测额外开销≈0。
#   bash < 5（如 CentOS 7）没有 EPOCHREALTIME，降级到外部 `date`，会有每次约 24 ms
#   的固定偏高，输出以 clock=date 标注。
#
# 不做域名解析：本机 nslookup 输出随系统语言变化（中文 Windows 是"服务器:"），
# 解析它不可靠；目标机的真实 IP 由 server_profile.sh 在远端采集（ip -br addr），
# 那才是权威来源。这里只探测你给的那个主机名/地址。
#
# 用法:
#   ./tcping.sh -H 203.0.113.10 -p 22
#   ./tcping.sh -H web1 -n 6 -t 8
#   ./tcping.sh -H 203.0.113.10 -p 443 -q     # 只输出结论行（供其他脚本解析）
#
# 退出码: 0 至少一次成功 | 1 用法错误 | 2 全部失败

set -uo pipefail
LC_ALL=C

PROG="$(basename "$0")"
HOST=""
PORT=22
COUNT=4
TOTAL_TIMEOUT=""
GAP=0.2
QUIET=0

if [ -t 1 ]; then C_DIM=$'\033[2m'; C_YEL=$'\033[33m'; C_OFF=$'\033[0m'
else C_DIM=""; C_YEL=""; C_OFF=""; fi
err() { printf '[error] %s\n' "$*" >&2; }
note() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }

need_arg() { [ "$2" -ge 2 ] || { err "选项 $1 需要一个参数"; exit 1; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    -H|--host)    need_arg "$1" $#; HOST="$2"; shift 2 ;;
    -p|--port)    need_arg "$1" $#; PORT="$2"; shift 2 ;;
    -n|--count)   need_arg "$1" $#; COUNT="$2"; shift 2 ;;
    -t|--timeout) need_arg "$1" $#; TOTAL_TIMEOUT="$2"; shift 2 ;;
    -g|--gap)     need_arg "$1" $#; GAP="$2"; shift 2 ;;
    -q|--quiet)   QUIET=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           err "未知选项: $1（--help 查看用法）"; exit 1 ;;
    *)            if [ -z "$HOST" ]; then HOST="$1"; shift; else err "多余参数: $1"; exit 1; fi ;;
  esac
done

[ -n "$HOST" ] || { err "必须指定目标主机（-H）"; exit 1; }
case "$PORT" in ''|*[!0-9]*) err "端口必须是数字"; exit 1 ;; esac
case "$COUNT" in ''|*[!0-9]*) err "探测次数必须是数字"; exit 1 ;; esac
[ "$COUNT" -ge 1 ] || { err "探测次数至少为 1"; exit 1; }
[ "$COUNT" -le 20 ] || { err "探测次数最多 20（再多也只是给对端添麻烦）"; exit 1; }

if [ -z "$TOTAL_TIMEOUT" ]; then
  TOTAL_TIMEOUT=$(( COUNT * 3 + 3 ))
  [ "$TOTAL_TIMEOUT" -gt 30 ] && TOTAL_TIMEOUT=30
fi
case "$TOTAL_TIMEOUT" in ''|*[!0-9]*) err "超时必须是整数秒"; exit 1 ;; esac

# 优先用 GNU coreutils 的 timeout。Windows/Git-Bash 下 `timeout` 可能解析到
# Windows 自带 timeout.exe（等待按键，语义完全不同），用 --version 探测避开。
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# ---------- 探测内核 ----------
# 在子 shell 里跑，整批只 fork 这一次。参数经 '_' 之后的 $1.. 传入。
INNER='
H=$1; P=$2; N=$3; GAP=$4
for ((i=0;i<N;i++)); do
  if [ -n "${EPOCHREALTIME:-}" ]; then
    s=${EPOCHREALTIME/./}
    while [ ${#s} -lt 16 ]; do s="${s}0"; done
  else
    s=$(date +%s%N); s=${s%???}
  fi
  if exec 3<>"/dev/tcp/$H/$P" 2>/dev/null; then
    if [ -n "${EPOCHREALTIME:-}" ]; then
      e=${EPOCHREALTIME/./}
      while [ ${#e} -lt 16 ]; do e="${e}0"; done
    else
      e=$(date +%s%N); e=${e%???}
    fi
    exec 3<&- 2>/dev/null
    exec 3>&- 2>/dev/null
    printf "OK %d\n" "$(( (e-s)/1000 ))"
  else
    printf "FAIL 0\n"
  fi
  if [ "$i" -lt "$((N-1))" ]; then sleep "$GAP" 2>/dev/null || true; fi
done
'

probe() { # host port count gap deadline -> "OK ms" / "FAIL 0" 每行
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$5" bash -c "$INNER" _ "$1" "$2" "$3" "$4" 2>/dev/null
  else
    bash -c "$INNER" _ "$1" "$2" "$3" "$4" 2>/dev/null
  fi
}

# ---------- 对照探测：本机是否在透明代理所有 TCP ----------
# 192.0.2.1/24 是 RFC 5737 的 TEST-NET-1，保留给文档用，正常网络绝不可能连上。
# 若能连上，只可能是本机栈（TUN 代理 / 杀软 / 企业网关）替你接了。
RELIABLE=1
REASON=""
CONTROL="$(probe 192.0.2.1 9 1 0 2)"
case "$CONTROL" in
  OK*)
    RELIABLE=0
    REASON="transparent_proxy"
    note "${C_YEL}[!] 对照探测 192.0.2.1:9（保留地址）竟然连上了 —— 本机存在透明代理${C_OFF}"
    note "${C_YEL}    （Clash/Mihomo 的 TUN、部分杀毒软件的流量扫描、企业 SSL 网关都会这样）。${C_OFF}"
    note "${C_YEL}    因此：计时测的是到代理的延迟，不是到服务器的延迟；${C_OFF}"
    note "${C_YEL}    「连接成功」也不能证明远端端口开着 —— 是代理替你接的。${C_OFF}"
    ;;
esac

# ---------- 正式探测 ----------
note "${C_DIM}-> tcping ${HOST}:${PORT}  探测 ${COUNT} 次${C_OFF}"
RAW="$(probe "$HOST" "$PORT" "$COUNT" "$GAP" "$TOTAL_TIMEOUT")"

OK=0; REFUSED=0; MIN=""; MAX=""; SUM=0; n=0
while IFS=' ' read -r st ms; do
  [ -n "${st:-}" ] || continue
  case "$st" in
    OK)
      n=$(( n + 1 )); OK=$(( OK + 1 )); SUM=$(( SUM + ms ))
      [ -z "$MIN" ] || [ "$ms" -lt "$MIN" ] && MIN="$ms"
      [ -z "$MAX" ] || [ "$ms" -gt "$MAX" ] && MAX="$ms"
      note "$(printf '   #%-2s %s ms' "$n" "$ms")"
      ;;
    FAIL)
      n=$(( n + 1 )); REFUSED=$(( REFUSED + 1 ))
      note "$(printf '   #%-2s %s' "$n" "连接被拒")"
      ;;
  esac
done <<EOF
$RAW
EOF

NOANSWER=$(( COUNT - n ))
[ "$NOANSWER" -lt 0 ] && NOANSWER=0
LOST=$(( REFUSED + NOANSWER ))

if [ -n "${EPOCHREALTIME:-}" ]; then CLOCK="realtime"; else CLOCK="date"; fi
SUFFIX="clock=${CLOCK} reliable=${RELIABLE}"
[ -n "$REASON" ] && SUFFIX="${SUFFIX} reason=${REASON}"

if [ "$OK" -eq 0 ]; then
  if [ "$RELIABLE" -eq 1 ] && [ "$REFUSED" -gt 0 ]; then
    note "   全部失败：连接被拒 —— 主机可达，但该端口没有服务在监听（或被 REJECT）"
  else
    note "   全部失败：${TOTAL_TIMEOUT}s 内无任何响应 —— 主机不可达，或被丢包（安全组 / 防火墙 DROP）"
  fi
  printf 'SSHMGR_TCPING=%s:%s min=- avg=- max=- loss=%s/%s %s\n' "$HOST" "$PORT" "$LOST" "$COUNT" "$SUFFIX"
  exit 2
fi

AVG=$(( SUM / OK ))
if [ "$RELIABLE" -eq 1 ]; then
  note "   成功 ${OK} / 丢失 ${LOST}（拒绝 ${REFUSED}，无响应 ${NOANSWER}）  min=${MIN}ms avg=${AVG}ms max=${MAX}ms"
else
  note "   成功 ${OK} / 丢失 ${LOST}  min=${MIN}ms avg=${AVG}ms max=${MAX}ms  ${C_YEL}[数值不可信：本机透明代理]${C_OFF}"
fi
printf 'SSHMGR_TCPING=%s:%s min=%s avg=%s max=%s loss=%s/%s %s\n' \
  "$HOST" "$PORT" "$MIN" "$AVG" "$MAX" "$LOST" "$COUNT" "$SUFFIX"
exit 0
