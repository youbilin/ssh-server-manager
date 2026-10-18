#!/usr/bin/env bash
# profile_store.sh - 服务器档案的本地管理：首次采集、查询、更新、标脏
#
# 为什么需要这个：连过十次的机器，硬件型号、装了哪些 Docker 服务这些事实几乎不会变，
# 每次都重新侦察一遍是浪费，而且采集完就丢等于白采。档案让"第一次看清、之后查档"成立。
#
# 存放位置: ${SSHMGR_HOME:-~/.ssh-server-manager}/profiles/<目标>.profile
#           与 audit.log 同目录。档案里有 IP、主机名、镜像清单这类基础设施细节，
#           不要把它提交到仓库或贴进公开场合。
#
# 档案格式: 平铺 key=value，一行一条，# 开头是注释。同名列表键由本脚本索引成
#           key.0 / key.1。手工编辑也行，保持单行格式即可。
#
# ⚠ 安全要点：解析档案时绝不 source/eval —— 值来自远端（容器名、镜像 tag、挂载路径），
#   一个恶意容器名就是本地代码执行。这里只用 IFS='=' 的 read 逐行解析并校验键名。
#
# 身份判定：IP 会被回收、NAT 下多机共用出口、同一 IP 不同端口可能是不同账号，
#   所以"是不是上次那台机器"主要看主机密钥指纹（客户端实际验证过的那个，
#   从 known_hosts 读），machine_id 只作旁证 —— 它在 Alpine 上不存在、
#   在 golden image 克隆体上完全相同、在容器里每次启动都变。
#   指纹对不上时拒绝覆盖，另存 <目标>.m2.profile 并告警。
#
# 用法:
#   ./profile_store.sh collect -H 203.0.113.10 -u root -p 22   # 首次接触就这一步
#   ./profile_store.sh find -H web1                            # 查档案（本地，不联网）
#   ./profile_store.sh show -H web1 [--fields os,cpu_model] [--short]
#   ./profile_store.sh list                                    # 全部档案一张表
#   ./profile_store.sh check -H web1                           # 1 次连接验证档案是否过期
#   ./profile_store.sh set -H web1 note="生产库，别乱动"
#   ./profile_store.sh mark-stale -H web1 --sections docker,services --reason "docker compose up"
#   ./profile_store.sh forget -H web1
#
# 退出码: 0 成功 | 1 用法错误 | 2 目标不存在 | 3 采集失败/结果不完整

set -uo pipefail
LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_EXEC="$SCRIPT_DIR/ssh_exec.sh"
PROFILE_SH="$SCRIPT_DIR/server_profile.sh"
TCPING="$SCRIPT_DIR/tcping.sh"

HOME_DIR="${SSHMGR_HOME:-${SSHMGR_LOG_DIR:-$HOME/.ssh-server-manager}}"
PROFILE_DIR="$HOME_DIR/profiles"

CMD=""
TARGET="" SSH_USER="" SSH_PORT="" SSH_JUMP="" SSH_IDENTITY=""
SECTIONS="identity,hw,storage,network,docker,services,runtimes,security"
PARTIAL_COLLECT=0   # collect --sections 显式给了段落 → 只重采这些，其余保留
NOTE=""
STALE_SECTIONS="" STALE_REASON=""
FIELDS="" SHORT=0
COLLECT_TIMEOUT=150
SKIP_TCPING=0
FORCE=0
SET_PAIRS=""

if [ -t 1 ]; then C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""; fi

err()  { printf '%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; cat <<'USAGE'

子命令:
  collect   采集档案：tcping -> 远端只读采集 -> 解析入库（首次接触就这一步）
  find      按目标/别名/主机名/IP 查档案（本地，不联网）。命中 exit 0，未命中 exit 2
  show      输出档案内容（--fields 挑字段，--short 出紧凑画像）
  list      全部档案一张表
  check     用 1 次连接（只 cat boot_id）判断档案是否因重启而过期
  set       更新档案字段: set -H web1 note="..." key=value ...
  mark-stale 把某些段落标脏（改了服务之后调用，档案才不会悄悄过时）
  hint      输出一行档案状态提示（给 ssh_exec.sh 用；新鲜时什么都不打印）
  forget    删除档案

collect 选项:
  -H, --host TARGET      目标（IP / 别名 / user@host）
  -u, --user USER        登录用户
  -p, --port PORT        SSH 端口
  -J, --jump JUMP        跳板机
  -i, --identity FILE    私钥路径
      --sections LIST    只采这些段落（默认全采）
      --note TEXT        写一句备注（如"生产库，别乱动"）
      --skip-tcping      跳过延迟探测
      --timeout SEC      采集超时（默认 150）

mark-stale 选项:
      --sections LIST    哪些段落失效了（docker,services,storage...）
      --reason TEXT      为什么失效（会记进档案）
USAGE
}

# ---------- 参数 ----------
# 先处理裸 --help/-h：它出现在子命令之前时不该被当成子命令名
if [ $# -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then usage; exit 0; fi
[ $# -ge 1 ] || { usage; exit 1; }
CMD="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    -H|--host)        [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; TARGET="$2"; shift 2 ;;
    -u|--user)        [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; SSH_USER="$2"; shift 2 ;;
    -p|--port)        [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; SSH_PORT="$2"; shift 2 ;;
    -J|--jump)        [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; SSH_JUMP="$2"; shift 2 ;;
    -i|--identity)    [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; SSH_IDENTITY="$2"; shift 2 ;;
    --sections)       [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }
                      # 同一个选项在 collect 下是"只采这些段落"，
                      # 在 mark-stale 下是"这些段落失效了" —— 按子命令决定含义
                      if [ "$CMD" = "mark-stale" ]; then STALE_SECTIONS="$2"; else SECTIONS="$2"; PARTIAL_COLLECT=1; fi
                      shift 2 ;;
    --note)           [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; NOTE="$2"; shift 2 ;;
    --reason)         [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; STALE_REASON="$2"; shift 2 ;;
    --fields)         [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; FIELDS="$2"; shift 2 ;;
    --short)          SHORT=1; shift ;;
    --skip-tcping)    SKIP_TCPING=1; shift ;;
    --timeout)        [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; COLLECT_TIMEOUT="$2"; shift 2 ;;
    --force)          FORCE=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    # set 子命令的 k=v 对（键名合法性在 do_set 里校验，这里先收下来）
    [A-Za-z_]*=*)     SET_PAIRS="$SET_PAIRS
$1"; shift ;;
    *)                err "未知参数: $1（--help 查看用法）"; exit 1 ;;
  esac
done
case "$CMD" in collect|find|show|check|set|mark-stale|forget|hint)
  [ -n "$TARGET" ] || { err "需要 -H 指定目标"; exit 1; } ;;
esac
case "$CMD" in list) ;; *) ;; esac

# ---------- 工具 ----------
# 文件名清洗：IPv6 的冒号在 NTFS 上是非法字符，其它路径特殊字符一并转下划线。
# 用"白名单以外的字符全替换成 _"（tr -c）而不是逐一列举要替换的字符 ——
# 枚举写法里末尾那个反斜杠会让 tr 打印可移植性警告，而且总容易漏掉字符。
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'; }

file_digest() {
  if   command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -c1-12
  elif command -v shasum >/dev/null 2>&1;    then shasum -a 256 "$1" 2>/dev/null | cut -c1-12
  elif command -v openssl >/dev/null 2>&1;   then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print substr($NF,1,12)}'
  fi
}

# 已声明的列表键：解析时固定索引成 key.N；其余键视为标量，重复出现则告警取末值
LIST_KEYS=" docker_container docker_compose_project disk_dev fs_mount diskstat
            net_iface addr listen unit_running unit_failed timer user_shell "
# 直通键：可以重复出现但**不**索引。原因：find 用固定字符串 grep（grep -F）匹配它们，
# 索引成 ip_all.0=... 会让查找失配。直通写法对人和 grep 都最友好。
REPEAT_KEYS=" ip_all alias "
is_list_key() { case "$LIST_KEYS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---------- 段落归属 ----------
# 只重采某几个段落时（collect --sections docker），旧档案里**其余段落必须原样保留**。
# 以前是整份重写：采一次 docker 就把 hw/identity/storage 全丢了，档案悄悄变残，
# 而使用者以为它还是完整的。这里把"哪个键属于哪个段落"写死成一张表，
# 用于合并时决定保留还是丢弃 —— 与 server_profile.sh 的 want 分支一一对应。
KEY_SECTION_PATTERNS="
identity:profile_schema collected_at collected_by hostname fqdn kernel arch virt os os_id os_version machine_id boot_id uptime_s boot_time ip_primary ip_all ip6_primary reboot_required selinux apparmor timezone ntp_synced ssh_unit
hw:cpu_ mem_total_mb swap_total_mb gpu
storage:disk_dev diskstat fs_mount
network:gateway listen net_iface dns
docker:docker
services:cron_entries pkg_manager unit_running unit_failed timer
runtimes:python3 node php java go ruby nginx mysqld redis postgres_client
security:firewall ssh_ user_shell
"

# 显示列宽：中文标签是双宽字符，而 printf 的 %-Ns 按字节补空格、本脚本又是 LC_ALL=C
# （bash 的 ${#s} 也只数字节），直接用 %-Ns 会让中文列错位。
# ASCII 每字节 1 列，UTF-8 多字节字符（CJK）按 2 列，续字节跳过。
dispwidth() {
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

profile_path() { printf '%s/%s.profile' "$PROFILE_DIR" "$(sanitize "$1")"; }

# ---------- 解析 ----------
# 把 key=value 流规范化：列表键索引化、剥掉行尾 CR（这些文件会被记事本/PowerShell 打开）、
# 校验键名。绝不 eval —— 值是远端来的不可信字符串。
normalize_kv() { # stdin -> stdout
  awk -F'=' -v LIST_KEYS="$LIST_KEYS" -v REPEAT_KEYS="$REPEAT_KEYS" '
    function ltrim(s){gsub(/^[ \t]+/,"",s);return s}
    function rtrim(s){gsub(/[ \t]+$/,"",s);return s}
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    {
      k=$1; v=substr($0, index($0,"=")+1)
      sub(/\r$/, "", v)
      k=ltrim(rtrim(k)); v=ltrim(rtrim(v))
      if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { printf "#WARN 非法键名已丢弃: %s\n", k > "/dev/stderr"; next }
      if (index(REPEAT_KEYS, " " k " ") > 0) { print k "=" v }
      else if (index(LIST_KEYS, " " k " ") > 0) { printf "%s.%d=%s\n", k, lc[k]++, v }
      else {
        if (k in seen) printf "#WARN 重复标量键取末值: %s\n", k > "/dev/stderr"
        seen[k]=1; print k "=" v
      }
    }'
}

# 读档案里的标量值（含 key.N 形式的列表键首值）
pget() { # pget <file> <key>
  awk -F'=' -v want="$1" '
    { sub(/\r$/,"") }
    /^[ \t]*#/ { next }
    {
      k=$1; if (k==want || index(k, want ".")==1) { v=substr($0, index($0,"=")+1); if (v!="") { print v; exit } }
    }' "$2" 2>/dev/null
}

# ---------- 查找 ----------
# 档案名是"用户连接时用的目标"，但机器的真实 IP 也在档案里。
# 所以按别名/主机名/IP 都能找到 —— 用 IP 连和用名字连应该命中同一份档案。
find_profile() { # find_profile <target> -> 打印路径，找不到 exit 2
  [ -d "$PROFILE_DIR" ] || return 2
  local t="$1" f hit
  # 1) 精确文件名
  f="$(profile_path "$t")"
  [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  # 2) 去掉 user@ 前缀再试
  t="${t##*@}"
  f="$(profile_path "$t")"
  [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  # 3) 扫内容：alias / hostname / ip_primary / ip_all / 精确目标记录
  t="${1##*@}"
  hit="$(grep -lF -e "alias=$t" -e "hostname=$t" -e "ip_primary=$t" -e "ip_all=$t" -e "connect_target=$t" \
         "$PROFILE_DIR"/*.profile 2>/dev/null | head -1)"
  [ -n "$hit" ] && { printf '%s\n' "$hit"; return 0; }
  return 2
}

# key_section <key> -> 段落名；未收录的键输出空串（调用方按"其他段落"保留）
# 直接遍历字符串，不开管道：管道里的 while 跑在子 shell，return 行为容易踩坑，
# 而且每合并一个键 fork 一次太浪费。
key_section() {
  local k="$1" ent sec names n
  while IFS= read -r ent; do
    [ -n "$ent" ] || continue
    sec="${ent%%:*}"
    names="${ent#*:}"
    for n in $names; do
      case "$k" in
        "$n"|"$n"*) printf '%s\n' "$sec"; return 0 ;;
      esac
    done
  done <<EOF
$KEY_SECTION_PATTERNS
EOF
  printf ''
}

# 合并旧档案：保留本次没重采的段落，丢弃本次重采段落里已不存在的旧键。
# $1=旧档案文件  $2=本次采集的段落列表（逗号分隔）
# 由调用方把它接到新结果**之前**写进临时文件；同名标量键在档案里后写者生效
# （normalize_kv 取末值），所以旧值被新值的覆盖是天然成立的。
merge_old_sections() {
  local old="$1" wanted=",$2," k sec
  [ -f "$old" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;       # 注释与空行不搬
      *=*) ;;                    # 只搬 key=value
      *) continue ;;
    esac
    case "$line" in
      connect_target=*|ssh_user=*|ssh_port=*|ssh_jump=*|ssh_identity=*|first_seen=*|last_scan=*|scan_count=*|collector_sha256=*|latency_min_ms=*|latency_avg_ms=*|latency_reliable=*|host_key_fp=*|alias=*|note=*|stale_sections=*|stale_reason=*|stale_at=*|profile_updated=*)
        continue ;;              # 元数据由本次采集重新生成
    esac
    k="${line%%=*}"
    sec="$(key_section "$k")"
    if [ -n "$sec" ]; then
      case "$wanted" in
        *",$sec,"*) continue ;;  # 本次重采了这一段：旧值作废
      esac
    fi
    printf '%s\n' "$line"
  done < "$old"
}

# ---------- collect ----------
do_collect() {
  [ -f "$SSH_EXEC" ]    || { err "找不到 $SSH_EXEC"; exit 1; }
  [ -f "$PROFILE_SH" ]  || { err "找不到 $PROFILE_SH"; exit 1; }
  mkdir -p "$PROFILE_DIR" 2>/dev/null || { err "无法创建 $PROFILE_DIR"; exit 1; }

  local host="${TARGET##*@}"
  local pfile="$(profile_path "$host")"

  # ---------- 1. 延迟探测（本地，零远端负载） ----------
  local latency_line=""
  # port 必须在两个分支之前定义：经跳板机那条分支以前引用了只在前一个分支里
  # 声明的局部变量，`set -u` 下直接 `port: unbound variable` 退出。
  local port="${SSH_PORT:-22}"
  if [ "$SKIP_TCPING" -eq 0 ] && [ -f "$TCPING" ] && [ -z "$SSH_JUMP" ]; then
    latency_line="$(bash "$TCPING" -H "$host" -p "$port" -n 4 -q 2>/dev/null | head -1)"
    [ -n "$latency_line" ] && dim "  $latency_line"
  elif [ -n "$SSH_JUMP" ]; then
    # 经跳板机时本地 RTT 无意义，直接跳过
    latency_line="SSHMGR_TCPING=$host:$port min=- avg=- max=- loss=-/- skip=jump"
    dim "  经跳板机连接，跳过本地延迟探测（测了也不是到目标机的真实延迟）"
  fi
  lat_min="$(printf '%s' "$latency_line" | sed -n 's/.*[[:space:]]min=\([^[:space:]]*\).*/\1/p')"
  lat_avg="$(printf '%s' "$latency_line" | sed -n 's/.*[[:space:]]avg=\([^[:space:]]*\).*/\1/p')"
  lat_rel="$(printf '%s' "$latency_line" | sed -n 's/.*[[:space:]]reliable=\([01]\).*/\1/p')"
  lat_skip="$(printf '%s' "$latency_line" | sed -n 's/.*[[:space:]]skip=\([a-z]*\).*/\1/p')"
  # 对照探测发现本机有透明代理时，这个延迟就不是到服务器的延迟 —— 记下来，别当成网络 RTT 用
  [ "${lat_rel:-1}" = "0" ] && warn "本机存在透明代理，延迟数值不可信（详见 tcping.sh 头部说明）"

  # ---------- 2. 远端采集 ----------
  dim "  -> 在 $TARGET 上采集（只读，不跑任何压测）..."
  local out rc
  # 用数组拼参数，不要用 ${VAR:+...} 直接展开：那种写法没有引号包住，
  # 值里一旦有空格就会被拆成两个参数（用户名或路径里出现空格并非不可能）。
  local -a sshargs=(-q -H "$TARGET")
  [ -n "$SSH_USER" ]     && sshargs+=(-u "$SSH_USER")
  [ -n "$SSH_PORT" ]     && sshargs+=(-p "$SSH_PORT")
  [ -n "$SSH_JUMP" ]     && sshargs+=(-J "$SSH_JUMP")
  [ -n "$SSH_IDENTITY" ] && sshargs+=(-i "$SSH_IDENTITY")
  sshargs+=(-f "$PROFILE_SH" -A "--sections $SECTIONS" -t "$COLLECT_TIMEOUT")
  sshargs+=(--label "profile-collect $TARGET")
  out="$(bash "$SSH_EXEC" "${sshargs[@]}" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    err "采集失败（ssh_exec.sh 退出码 $rc）。常见原因：连不上 / 认证失败 / 超时"
    # 半份结果绝不入库：见 server_profile.sh 尾部的完整性哨兵说明
    if [ -n "$out" ]; then
      local pf="$pfile.partial"
      printf '%s\n' "$out" > "$pf" 2>/dev/null || true
      warn "原始输出已存到 $pf 供排查，未写入档案"
    fi
    exit 3
  fi

  # ---------- 3. 完整性检查 ----------
  if ! printf '%s\n' "$out" | grep -q '^profile_complete=1[[:space:]]*$'; then
    err "采集结果不完整（没有 profile_complete=1 哨兵行）—— 很可能是采集超时被掐断。"
    err "半份结果不能当档案用（宁缺毋滥），已丢弃。可以加 --timeout 300 重试，"
    err "或用 --sections 缩小范围只采需要的段落。"
    printf '%s\n' "$out" > "$pfile.partial" 2>/dev/null || true
    warn "原始输出已存到 $pfile.partial"
    exit 3
  fi

  # ---------- 4. 与已有档案比对身份（是不是同一台机器） ----------
  local old_machine old_fp
  if [ -f "$pfile" ]; then
    old_machine="$(pget machine_id "$pfile")"
    old_fp="$(pget host_key_fp "$pfile")"
  fi

  # 主机密钥指纹：用客户端实际验证过的那条记录（known_hosts），不是重新 keyscan
  local kh_entry fp=""
  if [ "${SSH_PORT:-22}" = "22" ]; then kh_entry="$host"; else kh_entry="[$host]:$SSH_PORT"; fi
  for kh in "$HOME/.ssh/known_hosts"; do
    [ -f "$kh" ] || continue
    fp="$(ssh-keygen -F "$kh_entry" -f "$kh" 2>/dev/null | grep -v '^#' | ssh-keygen -lf - 2>/dev/null | head -1 | awk '{print $2}')"
    [ -n "$fp" ] && break
  done

  # ---------- 5. 组装档案（原子写入） ----------
  local tmp="$pfile.tmp.$$"
  local scan_count=1 first_seen now
  now="$(now_utc)"
  if [ -f "$pfile" ]; then
    scan_count=$(( $(pget scan_count "$pfile" || echo 0) + 1 ))
    first_seen="$(pget first_seen "$pfile")"
  fi
  [ -n "${first_seen:-}" ] || first_seen="$now"

  {
    printf '# ssh-server-manager profile —— 手工可编辑，保持 key=value 单行格式\n'
    printf '# 由 profile_store.sh collect 生成于 %s\n' "$now"
    printf 'connect_target=%s\n' "$TARGET"
    printf 'ssh_user=%s\n' "${SSH_USER:-$(pget ssh_user "$pfile" 2>/dev/null || echo '')}"
    printf 'ssh_port=%s\n' "${SSH_PORT:-$(pget ssh_port "$pfile" 2>/dev/null || echo 22)}"
    [ -n "$SSH_JUMP" ] && printf 'ssh_jump=%s\n' "$SSH_JUMP"
    [ -n "$SSH_IDENTITY" ] && printf 'ssh_identity=%s\n' "$SSH_IDENTITY"
    printf 'first_seen=%s\n' "$first_seen"
    printf 'last_scan=%s\n' "$now"
    printf 'scan_count=%s\n' "$scan_count"
    local d; d="$(file_digest "$PROFILE_SH")"; [ -n "$d" ] && printf 'collector_sha256=%s\n' "$d"
    [ -n "${lat_min:-}" ] && [ "$lat_min" != "-" ] && printf 'latency_min_ms=%s\n' "$lat_min"
    [ -n "${lat_avg:-}" ] && [ "$lat_avg" != "-" ] && printf 'latency_avg_ms=%s\n' "$lat_avg"
    if [ -n "${lat_skip:-}" ]; then
      printf 'latency_reliable=skip\n'
    else
      printf 'latency_reliable=%s\n' "${lat_rel:-1}"
    fi
    [ -n "$fp" ] && printf 'host_key_fp=%s\n' "$fp"
    printf 'alias=%s\n' "$TARGET"
    [ -n "$NOTE" ] && printf 'note=%s\n' "$NOTE"
    # 保留旧档案里的手工字段（note/alias），丢掉会被本次覆盖的事实字段
    if [ -f "$pfile" ]; then
      local old_note; old_note="$(pget note "$pfile")"
      [ -n "$old_note" ] && [ -z "$NOTE" ] && printf 'note=%s\n' "$old_note"
    fi
    # 部分重采（--sections）时，先把旧档案里"本次没采的段落"整段搬过来，
    # 再接本次结果：档案才不会因为采了一个段落就悄悄丢掉其余事实。
    # 全量采集时不合并 —— 那种情况下旧值本来就该全部作废。
    if [ -n "$PARTIAL_COLLECT" ]; then
      merge_old_sections "$pfile" "$SECTIONS"
    fi
    printf '%s\n' "$out" | normalize_kv
    printf '# 以下由 profile_store 管理，勿手工改\n'
    printf 'profile_updated=%s\n' "$now"
  } > "$tmp" 2>"$tmp.warn" || { err "写入临时文件失败"; rm -f "$tmp"; exit 1; }

  grep '^#WARN' "$tmp.warn" 2>/dev/null | sed 's/^/  /' >&2
  rm -f "$tmp.warn"

  # ---------- 6. 身份校验后再落盘 ----------
  local new_machine; new_machine="$(printf '%s\n' "$out" | sed -n 's/^machine_id=//p' | head -1)"
  if [ -f "$pfile" ] && [ -n "${old_machine:-}" ] && [ -n "$new_machine" ] && [ "$old_machine" != "$new_machine" ]; then
    if [ "$FORCE" -eq 1 ]; then
      warn "machine_id 变了（原 ${old_machine:0:12}… 现 ${new_machine:0:12}…），--force 已确认覆盖"
    else
      local alt="${pfile%.profile}.m2.profile"
      mv "$tmp" "$alt" 2>/dev/null
      err "检测到同一目标下换了一台机器（machine_id 不一致）："
      err "  原档案: $pfile"
      err "  新机器的采集结果另存为: $alt"
      err "  如果确实重装/换机了，用 forget 删旧档案后重新 collect，或加 --force 覆盖。"
      exit 3
    fi
  fi
  if [ -f "$pfile" ] && [ -n "${old_fp:-}" ] && [ -n "$fp" ] && [ "$old_fp" != "$fp" ]; then
    warn "主机密钥指纹变了（原 ${old_fp:0:20}… 现 ${fp:0:20}…）——"
    warn "可能是重装系统，也可能是中间人。确认过来源再继续，必要时 forget 后重采。"
  fi

  mv "$tmp" "$pfile" || { err "落盘失败"; exit 1; }

  # ---------- 7. 跨档案的 IP 冲突提示 ----------
  local ip_primary; ip_primary="$(pget ip_primary "$pfile")"
  if [ -n "$ip_primary" ]; then
    local other
    other="$(grep -l -e "ip_primary=$ip_primary" -e "ip_all=$ip_primary" "$PROFILE_DIR"/*.profile 2>/dev/null \
             | grep -v "^$pfile\$" | head -1)"
    [ -n "$other" ] && warn "IP $ip_primary 同时出现在 $(basename "$other") 里 —— 可能是两台机器共用出口 IP（NAT），或档案没清理"
  fi

  # 摘要
  ok "档案已写入 $pfile (第 ${scan_count} 次采集)"
  do_show_short "$pfile"
}

# ---------- 紧凑画像：≤20 行，够判断"这台机器是什么"，别把 200 行原文倒进对话 ----------
do_show_short() { # $1 = profile file
  local f="$1"
  [ -f "$f" ] || { err "档案不存在: $f"; exit 2; }
  printf '\n'
  printf '%s\n' "═══ 服务器画像 ═══"
  line() { # line <key> <label> —— 值为空就整行不输出
    local v; v="$(pget "$1" "$f")"
    [ -n "$v" ] || return 0
    local w pad="" i
    w="$(dispwidth "$2")"
    for ((i=w; i<16; i++)); do pad="$pad "; done
    printf '  %s%s %s\n' "$2" "$pad" "$v"
  }
  line "os"           "系统"
  line "kernel"       "内核"
  line "virt"         "虚拟化"
  line "cpu_model"    "CPU"
  line "mem_total_mb" "内存MB"
  line "dmi_product_name" "机型"
  line "ip_primary"   "主IP"
  line "docker"       "Docker"
  local nc; nc="$(grep -c '^docker_container\.[0-9]' "$f" 2>/dev/null)"
  [ "${nc:-0}" -gt 0 ] && printf '  容器              %s 个\n' "$nc"
  local ns; ns="$(grep -c '^unit_running\.' "$f" 2>/dev/null)"
  [ "${ns:-0}" -gt 0 ] && printf '  systemd服务       %s 个在跑\n' "$ns"
  line "latency_avg_ms" "延迟avg"
  grep -q '^latency_reliable=0' "$f" 2>/dev/null && printf '  延迟可信度        否（本机透明代理）\n'
  line "last_scan"    "上次采集"
  local st; st="$(pget stale_sections "$f")"
  [ -n "$st" ] && printf '  %s已标脏: %s（原因: %s）%s\n' "$C_YEL" "$st" "$(pget stale_reason "$f")" "$C_OFF"
  line "note"         "备注"
}

# ---------- show ----------
do_show() {
  local f; f="$(find_profile "$TARGET")" || { err "没有 $TARGET 的档案（先 collect）"; exit 2; }
  if [ "$SHORT" -eq 1 ]; then do_show_short "$f"; return 0; fi
  if [ -n "$FIELDS" ]; then
    local IFS=','
    for k in $FIELDS; do
      k="${k%%=*}"
      # 列表键可能有多条（key.0, key.1...），全部打出来
      grep -E "^${k}(\.[0-9]+)?=" "$f" 2>/dev/null | sed 's/^/  /'
    done
  else
    cat "$f"
  fi
}

# ---------- list / table ----------
do_list() {
  [ -d "$PROFILE_DIR" ] || { dim "（还没有任何档案）"; return 0; }
  # 表头是中文（双宽），printf 的 %-Ns 按字节补空格会错位，所以用 dispwidth 自己算列宽
  col() { # col <字符串> <列宽> —— 恰好占用"列宽+1个空格"的显示宽度（含分隔空格）
    local s="$1" want="$2" w i pad="" acc="" c wc
    w="$(dispwidth "$s")"
    if [ "$w" -gt "$want" ]; then
      # 按**显示宽度**截断（不能按字节切，会切坏 UTF-8），末位用 ~ 表示被截断
      acc=""; wc=0
      for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in [[:ascii:]]) wc=$((wc+1)) ;; *) wc=$((wc+2)) ;; esac
        [ "$wc" -gt "$((want-1))" ] && break
        acc="$acc$c"
      done
      w="$(dispwidth "$acc")"
      pad="~"
      for ((i=w+1; i<want; i++)); do pad="$pad "; done
      printf '%s%s ' "$acc" "$pad"
      return 0
    fi
    for ((i=w; i<want; i++)); do pad="$pad "; done
    printf '%s%s ' "$s" "$pad"   # 末尾那个空格是列分隔，保证最后一列不会贴上来
  }
  local f short n=0
  for f in "$PROFILE_DIR"/*.profile; do [ -f "$f" ] && n=$((n+1)); done
  if [ "$n" -eq 0 ]; then dim "（还没有任何档案）"; return 0; fi

  col "目标" 20; col "系统" 24; col "CPU" 26; col "内存MB" 9; col "上次采集" 19
  printf '状态\n'
  for f in "$PROFILE_DIR"/*.profile; do
    [ -f "$f" ] || continue
    short="$(basename "$f" .profile)"
    col "$(pget connect_target "$f" 2>/dev/null || echo "$short")" 20
    col "$(pget os "$f" 2>/dev/null)" 24
    col "$(pget cpu_model "$f" 2>/dev/null)" 26
    col "$(pget mem_total_mb "$f" 2>/dev/null)" 9
    col "$(pget last_scan "$f" 2>/dev/null | cut -c1-19)" 19
    if [ -n "$(pget stale_sections "$f")" ]; then
      printf '%s\n' "已标脏($(pget stale_sections "$f"))"
    else
      printf '新鲜\n'
    fi
  done
  printf '\n共 %s 台。看单台: show -H <目标> --short\n' "$n"
}

# ---------- check ----------
# 只发 1 次连接、只 cat 两个文件，判断"机器重启过没有"。
# 重启过 => runtime/services/storage 基线失效，而 identity/hw 依然有效。
# 这是免费的保鲜检查，比"每隔 N 天全量重采"便宜得多，也比"什么都不查"诚实。
do_check() {
  local f; f="$(find_profile "$TARGET")" || { err "没有 $TARGET 的档案"; exit 2; }
  local old_boot; old_boot="$(pget boot_id "$f")"
  [ -n "$old_boot" ] || { warn "档案里没有 boot_id（旧版档案），无法判断是否重启过"; exit 0; }
  local cur crc
  local -a cargs=(-q -H "$TARGET")
  [ -n "$SSH_USER" ]     && cargs+=(-u "$SSH_USER")
  [ -n "$SSH_PORT" ]     && cargs+=(-p "$SSH_PORT")
  [ -n "$SSH_JUMP" ]     && cargs+=(-J "$SSH_JUMP")
  [ -n "$SSH_IDENTITY" ] && cargs+=(-i "$SSH_IDENTITY")
  cargs+=(-t 20 -c 'cat /proc/sys/kernel/random/boot_id 2>/dev/null; cut -d. -f1 /proc/uptime 2>/dev/null')
  cur="$(bash "$SSH_EXEC" "${cargs[@]}" 2>/dev/null)"
  crc=$?   # 必须在管道/替换之外取退出码：`cmd | tr` 的 $? 是 tr 的状态，永远是 0
  if [ "$crc" -ne 0 ] || [ -z "$cur" ]; then
    err "无法连接（ssh_exec.sh 退出码 $crc），档案状态未知"; exit 2
  fi
  cur="$(printf '%s' "$cur" | tr -d '\r')"
  local new_boot new_up
  new_boot="$(printf '%s\n' "$cur" | head -1)"
  new_up="$(printf '%s\n' "$cur" | sed -n '2p')"
  if [ "$new_boot" != "$old_boot" ]; then
    warn "机器重启过（boot_id 变了，当前 uptime ${new_up:-?}s）"
    warn "失效段落: runtime/services/storage 基线；identity/hw 依然有效，无需重采。"
    warn "刷新: profile_store.sh collect -H $TARGET --sections docker,services,storage"
    exit 1
  fi
  ok "机器未重启，档案基线仍有效 (uptime ${new_up:-?}s)"
}

# ---------- set ----------
# 更新档案里的标量字段。列表键（docker_container 之类）不允许在这里改 ——
# 它们由采集器生成，手改会在下次采集时被覆盖，造成"改了又没了"的错觉。
do_set() {
  local f; f="$(find_profile "$TARGET")" || { err "没有 $TARGET 的档案"; exit 2; }
  [ -n "${SET_PAIRS// /}" ] || { err "没有要更新的字段。用法: set -H web1 note=\"生产库，别乱动\" os_label=..."; exit 1; }
  local tmp="$f.tmp.$$"
  cp "$f" "$tmp" || exit 1
  local changed=0 k v
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    k="${pair%%=*}"; v="${pair#*=}"
    case "$k" in
      [A-Za-z_][A-Za-z0-9_]*) ;;
      *) err "非法键名: $k"; rm -f "$tmp"; exit 1 ;;
    esac
    if is_list_key "$k"; then
      warn "跳过列表键 $k（由采集器维护，手改会在下次采集时被覆盖）"
      continue
    fi
    if grep -q "^${k}=" "$tmp"; then
      # 用 awk 而不是 sed -i：值里可能有 | / 等字符，sed 的分隔符会被打断
      awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} $1==k {$1=k; print k"="v; next} {print}' \
        "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
    else
      printf '%s=%s\n' "$k" "$v" >> "$tmp"
    fi
    changed=$((changed + 1))
  done <<EOF
$SET_PAIRS
EOF
  if [ "$changed" -gt 0 ]; then
    printf 'profile_updated=%s\n' "$(now_utc)" >> "$tmp"
    mv "$tmp" "$f" && ok "已更新 $changed 个字段: $f"
  else
    rm -f "$tmp"
    err "没有实际更新任何字段"
    exit 1
  fi
}

# ---------- mark-stale ----------
do_mark_stale() {
  local f; f="$(find_profile "$TARGET")" || return 0   # 没有档案就不用标，静默返回
  [ -n "$STALE_SECTIONS" ] || { err "需要 --sections 指明哪些段落失效了"; exit 1; }
  local tmp="$f.tmp.$$"
  local now; now="$(now_utc)"
  # 合并已有的 stale_sections（不覆盖别的段落）
  local old; old="$(pget stale_sections "$f")"
  local merged="$STALE_SECTIONS"
  [ -n "$old" ] && merged="$old,$STALE_SECTIONS"
  merged="$(printf '%s' "$merged" | tr ',' '\n' | awk '!seen[$0]++' | paste -sd, -)"
  {
    grep -v -e '^stale_sections=' -e '^stale_reason=' -e '^stale_at=' "$f"
    printf 'stale_sections=%s\n' "$merged"
    [ -n "$STALE_REASON" ] && printf 'stale_reason=%s\n' "$STALE_REASON"
    printf 'stale_at=%s\n' "$now"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 0; }
  dim "  档案已标脏: $merged"
}

# ---------- hint ----------
# 给 ssh_exec.sh 用的一行提示：只在"可操作"时输出（缺档案 / 已标脏 / 机器重启过）。
# 档案新鲜就什么都不打印 —— 否则每次连接都刷一行就成了新的噪音。
do_hint() {
  local f
  if ! f="$(find_profile "$TARGET")"; then
    printf '[无档案] 首次连这台，可跑: profile_store.sh collect -H %s\n' "$TARGET"
    return 0
  fi
  local st; st="$(pget stale_sections "$f")"
  if [ -n "$st" ]; then
    printf '[档案已标脏: %s] 原因: %s — 需要时刷新: collect -H %s --sections %s\n' \
      "$st" "$(pget stale_reason "$f")" "$TARGET" "$st"
    return 0
  fi
  return 0
}

# ---------- forget ----------
do_forget() {
  local f; f="$(find_profile "$TARGET")" || { err "没有 $TARGET 的档案"; exit 2; }
  rm -f "$f" "${f%.profile}.m2.profile" "${f%.profile}.partial" && ok "已删除 $f"
}

# ---------- 分发 ----------
case "$CMD" in
  collect)    do_collect ;;
  find)       f="$(find_profile "$TARGET")" || { dim "没有 $TARGET 的档案"; exit 2; }
              echo "$f"
              do_show_short "$f" ;;
  show)       do_show ;;
  list)       do_list ;;
  check)      do_check ;;
  set)        do_set ;;
  mark-stale) do_mark_stale ;;
  hint)       do_hint ;;
  forget)     do_forget ;;
  *)          usage; exit 1 ;;
esac
