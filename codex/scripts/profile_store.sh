#!/usr/bin/env bash
# profile_store.sh - 服务器档案的本地管理：首次采集、查询、更新、标脏
#
# 为什么需要这个：连过十次的机器，硬件型号、装了哪些 Docker 服务这些事实几乎不会变，
# 每次都重新侦察一遍是浪费，而且采集完就丢等于白采。档案让"第一次看清、之后查档"成立。
#
# 存放位置: ${SSHMGR_HOME:-~/.ssh-server-manager}/profiles/<目标>.profile
#           非默认端口: <目标>_<port>.profile
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
#   所以身份主要看主机密钥指纹（客户端实际验证过的那个，从 known_hosts 读），
#   machine_id 只作旁证 —— 它在 Alpine 上不存在、在 golden image 克隆体上完全相同、
#   在容器里每次启动都变。任一判据不一致都会拒绝覆盖，另存 <目标>.m2.profile 并告警。
#
# 用法:
#   ./profile_store.sh collect -H 203.0.113.10 -u root -p 22   # 首次接触就这一步
#   ./profile_store.sh find -H web1                            # 查档案（本地，不联网）
#   ./profile_store.sh show -H web1 [--fields os,cpu_model] [--short]
#   ./profile_store.sh list                                    # 全部档案一张表
#   ./profile_store.sh check -H web1                           # 1 次连接验证档案是否过期
#   ./profile_store.sh compare -H web1,web2                    # 本地对比硬件/服务
#   ./profile_store.sh set -H web1 note="生产库，别乱动"
#   ./profile_store.sh mark-stale -H web1 --sections docker,services --reason "docker compose up"
#   ./profile_store.sh forget -H web1
#
# 退出码: 0 成功 | 1 用法错误 | 2 目标不存在/查找不唯一 | 3 采集失败/身份冲突

set -uo pipefail
LC_ALL=C
# 档案含 IP、主机名、镜像清单等基础设施信息；默认子进程创建的文件都应是私有的。
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_EXEC="$SCRIPT_DIR/ssh_exec.sh"
PROFILE_SH="$SCRIPT_DIR/server_profile.sh"
TCPING="$SCRIPT_DIR/tcping.sh"
if [ ! -r "$SCRIPT_DIR/lib/target.sh" ]; then
  printf '[error] 安装不完整：缺少 scripts/lib/target.sh\n' >&2
  exit 1
fi
# shellcheck source=lib/target.sh
. "$SCRIPT_DIR/lib/target.sh"

HOME_DIR="${SSHMGR_HOME:-${SSHMGR_LOG_DIR:-$HOME/.ssh-server-manager}}"
PROFILE_DIR="$HOME_DIR/profiles"

CMD=""
TARGET=""
TARGETS=""
SSH_USER="" SSH_PORT="" SSH_JUMP="" SSH_IDENTITY=""
ALIAS_OPT=""
AUTH_MODE=""
PASSWORD_ENV=""
CREDENTIAL_FILE=""
PROMPT_CREDENTIAL=0
SAVE_CREDENTIAL=0
USE_SAVED_CREDENTIAL=0
SECTIONS="identity,hw,storage,network,docker,services,runtimes,security"
PARTIAL_COLLECT=0
NOTE=""
STALE_SECTIONS="" STALE_REASON=""
FIELDS="" SHORT=0
COLLECT_TIMEOUT=150
SKIP_TCPING=0
FORCE=0
SET_PAIRS=""

KNOWN_SECTIONS="identity hw storage network docker services runtimes security"

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
  compare   本地对比两台或多台档案（-H a,b 或重复 -H）
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
      --alias NAME       设置别名（默认沿用旧值，IP 采集时不会覆盖人工别名）
      --skip-tcping      跳过延迟探测
      --timeout SEC      采集超时（默认 150）
      --force            身份判据不一致时仍覆盖（谨慎）

认证（collect/check 使用；与 ssh_exec.sh 相同）:
      --auth MODE        auto | key | password
      --password-env VAR
      --credential-file F
      --prompt-credential
      --use-saved-credential
      --save-credential

mark-stale 选项:
      --sections LIST    哪些段落失效了（docker,services,storage...）
      --reason TEXT      为什么失效（会记进档案）
USAGE
}

# ---------- 参数 ----------
if [ $# -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then usage; exit 0; fi
[ $# -ge 1 ] || { usage; exit 1; }
CMD="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    -H|--host)
      [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }
      TARGET="$2"; TARGETS="$TARGETS $2"; shift 2 ;;
    -u|--user)        [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; SSH_USER="$2"; shift 2 ;;
    -p|--port)        [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; SSH_PORT="$2"; shift 2 ;;
    -J|--jump)        [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; SSH_JUMP="$2"; shift 2 ;;
    -i|--identity)    [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; SSH_IDENTITY="$2"; shift 2 ;;
    --alias)          [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; ALIAS_OPT="$2"; shift 2 ;;
    --sections)
      [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }
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
    --auth)           [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; AUTH_MODE="$2"; shift 2 ;;
    --password-env)   [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; PASSWORD_ENV="$2"; shift 2 ;;
    --credential-file) [ $# -ge 2 ] || { err "$1 需要参数"; exit 1; }; CREDENTIAL_FILE="$2"; shift 2 ;;
    --prompt-credential) PROMPT_CREDENTIAL=1; shift ;;
    --save-credential) SAVE_CREDENTIAL=1; shift ;;
    --use-saved-credential) USE_SAVED_CREDENTIAL=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    # set 子命令的 k=v 对（键名合法性在 do_set 里校验，这里先收下来）
    [A-Za-z_]*=*)     SET_PAIRS="$SET_PAIRS
$1"; shift ;;
    *)                err "未知参数: $1（--help 查看用法）"; exit 1 ;;
  esac
done

case "$CMD" in collect|find|show|check|set|mark-stale|forget|hint|compare)
  [ -n "$TARGET" ] || { err "需要 -H 指定目标"; exit 1; } ;;
  list) ;;
  *) usage; exit 1 ;;
esac

NOTE="$(printf '%s' "$NOTE" | tr '\n\r\t' '   ')"
ALIAS_OPT="$(printf '%s' "$ALIAS_OPT" | tr '\n\r\t' '   ')"
STALE_REASON="$(printf '%s' "$STALE_REASON" | tr '\n\r\t' '   ')"
case "$AUTH_MODE" in ''|auto|key|password) ;; *) err "--auth 只能是 auto|key|password"; exit 1 ;; esac
case "$COLLECT_TIMEOUT" in ''|*[!0-9]*) err "--timeout 必须是整数秒"; exit 1 ;; esac
[ "$COLLECT_TIMEOUT" -ge 1 ] || { err "--timeout 至少为 1"; exit 1; }
if [ -n "$SSH_PORT" ]; then
  case "$SSH_PORT" in ''|*[!0-9]*) err "端口必须是数字"; exit 1 ;; esac
  [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || { err "端口必须在 1-65535 之间"; exit 1; }
fi

validate_sections() { # $1=逗号列表；未知段落直接拒绝
  local list="$1" s
  [ -n "$list" ] || { err "段落列表不能为空"; exit 1; }
  local IFS=','
  for s in $list; do
    [ -n "$s" ] || continue
    case " $KNOWN_SECTIONS " in
      *" $s "*) ;;
      *) err "未知段落: $s（可用: $KNOWN_SECTIONS）"; exit 1 ;;
    esac
  done
}
case "$CMD" in
  collect) validate_sections "$SECTIONS" ;;
  mark-stale) [ -n "$STALE_SECTIONS" ] && validate_sections "$STALE_SECTIONS" ;;
esac

# ---------- 工具 ----------
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'; }
file_digest() {
  if   command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -c1-12
  elif command -v shasum >/dev/null 2>&1;    then shasum -a 256 "$1" 2>/dev/null | cut -c1-12
  elif command -v openssl >/dev/null 2>&1;   then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print substr($NF,1,12)}'
  fi
}

LIST_KEYS=" docker_container docker_compose_project disk_dev fs_mount diskstat
            net_iface addr listen unit_running unit_failed timer user_shell "
REPEAT_KEYS=" ip_all alias "
is_list_key() { case "$LIST_KEYS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

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

profile_path() { # <host> [port]
  local h p="$2"
  h="$(sanitize "$1")"
  if [ -n "$p" ] && [ "$p" != "22" ]; then
    printf '%s/%s_%s.profile' "$PROFILE_DIR" "$h" "$p"
  else
    printf '%s/%s.profile' "$PROFILE_DIR" "$h"
  fi
}

profile_paths_for() { # <host> -> 所有可能文件名
  local h; h="$(sanitize "$1")"
  [ -f "$PROFILE_DIR/$h.profile" ] && printf '%s\n' "$PROFILE_DIR/$h.profile"
  local f
  for f in "$PROFILE_DIR/$h"_*.profile; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

# ---------- 解析 ----------
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

pget() { # pget <file> <key> -> 首个非空值
  awk -F'=' -v want="$2" '
    { sub(/\r$/,"") }
    /^[ \t]*#/ { next }
    {
      k=$1; if (k==want || index(k, want ".")==1) { v=substr($0, index($0,"=")+1); if (v!="") { print v; exit } }
    }' "$1" 2>/dev/null
}

# ---------- 查找 ----------
# 精确匹配整行；不能用 grep -F 前缀，否则 find -H 203.0.113.1 会命中 .10。
_find_by_content() { # <needle> [port] -> 打印路径
  local needle="$1" port="${2:-}" f hits="" hit_count=0
  local matches
  matches="$(grep -lFx \
      -e "alias=$needle" -e "hostname=$needle" -e "fqdn=$needle" \
      -e "ip_primary=$needle" -e "ip_all=$needle" -e "connect_target=$needle" \
      "$PROFILE_DIR"/*.profile 2>/dev/null | sort -u)"
  for f in $matches; do
    [ -f "$f" ] || continue
    if [ -n "$port" ]; then
      local fp; fp="$(pget "$f" ssh_port)"; [ -n "$fp" ] || fp=22
      [ "$fp" = "$port" ] || continue
    fi
    hits="$hits $f"
    hit_count=$((hit_count + 1))
  done
  [ "$hit_count" -gt 0 ] || return 2
  if [ "$hit_count" -gt 1 ]; then
    warn "多个档案匹配 $needle${port:+（端口 $port）}，请用 -p 或具体路径区分："
    for f in $hits; do printf '    %s\n' "$f" >&2; done
    return 3
  fi
  printf '%s\n' "$hits" | sed 's/^ *//'
  return 0
}

# find_profile <target> [port] -> 打印路径；0 命中，2 未命中，3 不唯一
find_profile() {
  local target="$1" port="${2:-}" host t f
  [ -d "$PROFILE_DIR" ] || return 2
  host="${target##*@}"

  local variants=""
  variants="$(profile_paths_for "$host")"

  if [ -n "$port" ]; then
    # 1) 精确文件名（含端口）
    f="$(profile_path "$host" "$port")"
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    # 2) 同主机的端口变体里按档案记录的 ssh_port 过滤
    if [ -n "$variants" ]; then
      local n f2 matched=""
      for f2 in $variants; do
        local fp2; fp2="$(pget "$f2" ssh_port)"; [ -n "$fp2" ] || fp2=22
        [ "$fp2" = "$port" ] && matched="$matched $f2"
      done
      n="$(printf '%s\n' "$matched" | grep -c . || true)"
      if [ "$n" -eq 1 ]; then printf '%s\n' "$matched" | sed 's/^ *//'; return 0; fi
    fi
  else
    # 未指定端口：只有一个档案才自动选；多个必须让用户用 -p 明确，
    # 否则 show/check 可能悄悄读错端口上的另一台机器。
    if [ -n "$variants" ]; then
      local n; n="$(printf '%s\n' "$variants" | grep -c . || true)"
      if [ "$n" -eq 1 ]; then printf '%s\n' "$variants"; return 0; fi
      warn "目标 $host 有多个端口的档案，请用 -p 指定端口："
      printf '%s\n' "$variants" | sed 's/^/    /' >&2
      return 3
    fi
  fi

  # 3) 内容精确匹配（alias/hostname/ip/connect_target）
  t="${target##*@}"
  _find_by_content "$t" "$port" && return 0
  local rc=$?
  [ "$rc" -eq 3 ] && return 3

  # 4) ssh_config 别名：用 ssh -G 解析出真实 hostname 再查
  if command -v "${SSHMGR_SSH:-ssh}" >/dev/null 2>&1; then
    sshmgr_resolve_target "${SSHMGR_SSH:-ssh}" "$host" "" "$port" "" ""
    if [ -n "$SSHMGR_TARGET_HOST" ] && [ "$SSHMGR_TARGET_HOST" != "$host" ]; then
      _find_by_content "$SSHMGR_TARGET_HOST" "$port" && return 0
      [ $? -eq 3 ] && return 3
    fi
  fi
  return 2
}

# ---------- 段落归属 ----------
key_section() { # <key> -> 段落名；未收录输出空串
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

merge_old_sections() { # $1=旧档案 $2=本次采集的段落
  local old="$1" wanted=",$2," k sec line
  [ -f "$old" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    case "$line" in
      connect_target=*|ssh_user=*|ssh_port=*|ssh_jump=*|ssh_identity=*|first_seen=*|last_scan=*|scan_count=*|collector_sha256=*|latency_*|host_key_fp=*|alias=*|note=*|stale_sections=*|stale_reason=*|stale_at=*|profile_updated=*)
        continue ;;
    esac
    k="${line%%=*}"
    sec="$(key_section "$k")"
    if [ -n "$sec" ]; then
      case "$wanted" in
        *",$sec,"*) continue ;;
      esac
    fi
    printf '%s\n' "$line"
  done < "$old"
}

# ---------- 连接元数据 ----------
# 取档案里保存的 user/port/jump/identity，再用 ssh -G 补齐 ssh_config 中的值。
EFF_HOST="" EFF_PORT="22" EFF_USER="" EFF_JUMP="" EFF_IDENTITY=""
EFF_KH_FILE="" EFF_KH_ENTRY=""
resolve_connection_meta() { # $1=旧档案路径（可为空）
  local pfile="${1:-}" hostpart="$TARGET"
  case "$hostpart" in *@*) hostpart="${hostpart#*@}" ;; esac
  local target_user=""
  case "$TARGET" in *@*) target_user="${TARGET%%@*}" ;; esac

  EFF_USER="${SSH_USER:-$target_user}"
  EFF_PORT="$SSH_PORT"
  EFF_JUMP="$SSH_JUMP"
  EFF_IDENTITY="$SSH_IDENTITY"

  if [ -n "$pfile" ] && [ -f "$pfile" ]; then
    [ -z "$EFF_USER" ]     && EFF_USER="$(pget "$pfile" ssh_user)"
    [ -z "$EFF_PORT" ]     && EFF_PORT="$(pget "$pfile" ssh_port)"
    [ -z "$EFF_JUMP" ]     && EFF_JUMP="$(pget "$pfile" ssh_jump)"
    [ -z "$EFF_IDENTITY" ] && EFF_IDENTITY="$(pget "$pfile" ssh_identity)"
  fi

  sshmgr_resolve_target "${SSHMGR_SSH:-ssh}" "$hostpart" "$EFF_USER" "$EFF_PORT" "$EFF_JUMP" "$EFF_IDENTITY"
  EFF_HOST="$SSHMGR_TARGET_HOST"
  EFF_PORT="$SSHMGR_TARGET_PORT"
  EFF_USER="$SSHMGR_TARGET_USER"
  EFF_JUMP="$SSHMGR_TARGET_JUMP"
  EFF_IDENTITY="$SSHMGR_TARGET_IDENTITY"
  EFF_KH_FILE="$SSHMGR_TARGET_KH_FILE"
  EFF_KH_ENTRY="$SSHMGR_TARGET_KH_ENTRY"
}

# 读取客户端实际验证过的 known_hosts 指纹。
target_fingerprint() {
  [ -n "$EFF_KH_FILE" ] && [ -f "$EFF_KH_FILE" ] || return 0
  command -v ssh-keygen >/dev/null 2>&1 || return 0
  ssh-keygen -F "$EFF_KH_ENTRY" -f "$EFF_KH_FILE" 2>/dev/null \
    | grep -v '^#' | ssh-keygen -lf - 2>/dev/null | head -1 | awk '{print $2}'
}

RUN_ARGS=()
build_run_args() {
  RUN_ARGS=(-q -H "$TARGET")
  [ -n "$EFF_USER" ]     && RUN_ARGS+=(-u "$EFF_USER")
  [ -n "$EFF_PORT" ]     && RUN_ARGS+=(-p "$EFF_PORT")
  [ -n "$EFF_JUMP" ]     && RUN_ARGS+=(-J "$EFF_JUMP")
  [ -n "$EFF_IDENTITY" ] && RUN_ARGS+=(-i "$EFF_IDENTITY")
  [ -n "$AUTH_MODE" ]    && RUN_ARGS+=(--auth "$AUTH_MODE")
  [ -n "$PASSWORD_ENV" ] && RUN_ARGS+=(--password-env "$PASSWORD_ENV")
  [ -n "$CREDENTIAL_FILE" ] && RUN_ARGS+=(--credential-file "$CREDENTIAL_FILE")
  [ "$PROMPT_CREDENTIAL" -eq 1 ] && RUN_ARGS+=(--prompt-credential)
  [ "$SAVE_CREDENTIAL" -eq 1 ] && RUN_ARGS+=(--save-credential)
  [ "$USE_SAVED_CREDENTIAL" -eq 1 ] && RUN_ARGS+=(--use-saved-credential)
}

like_ip() {
  case "$1" in
    *[!0-9.]*) case "$1" in *:*) return 0 ;; *) return 1 ;; esac ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- collect ----------
do_collect() {
  [ -f "$SSH_EXEC" ]    || { err "找不到 $SSH_EXEC"; exit 1; }
  [ -f "$PROFILE_SH" ]  || { err "找不到 $PROFILE_SH"; exit 1; }
  mkdir -p "$PROFILE_DIR" 2>/dev/null || { err "无法创建 $PROFILE_DIR"; exit 1; }
  chmod 700 "$HOME_DIR" "$PROFILE_DIR" 2>/dev/null || true

  local hostpart="${TARGET##*@}" pfile="" find_rc=0
  pfile="$(find_profile "$TARGET" "$SSH_PORT")" || find_rc=$?
  if [ "$find_rc" -eq 3 ]; then
    err "目标有多个档案，无法确定要更新哪一份；请用 -p 指定端口或先 forget 旧档案。"
    exit 2
  fi
  [ "$find_rc" -eq 0 ] || pfile=""

  # 显式端口与旧档案端口不同：不是同一份档案，创建新文件。
  if [ -n "$pfile" ] && [ -n "$SSH_PORT" ]; then
    local old_port; old_port="$(pget "$pfile" ssh_port)"; [ -n "$old_port" ] || old_port=22
    [ "$old_port" = "$SSH_PORT" ] || pfile=""
  fi

  resolve_connection_meta "$pfile"
  [ -n "$EFF_PORT" ] || EFF_PORT=22
  if [ -z "$pfile" ]; then
    pfile="$(profile_path "$hostpart" "$EFF_PORT")"
  fi

  # ---------- 1. 延迟探测（本地，零远端负载） ----------
  local latency_line=""
  if [ "$SKIP_TCPING" -eq 0 ] && [ -f "$TCPING" ] && [ -z "$EFF_JUMP" ]; then
    latency_line="$(bash "$TCPING" -H "$EFF_HOST" -p "$EFF_PORT" -n 4 -q 2>/dev/null | head -1)"
    [ -n "$latency_line" ] && dim "  $latency_line"
  elif [ -n "$EFF_JUMP" ]; then
    latency_line="SSHMGR_TCPING=$EFF_HOST:$EFF_PORT min=- avg=- max=- loss=-/- skip=jump"
    dim "  经跳板机连接，跳过本地延迟探测（测了也不是到目标机的真实延迟）"
  fi
  local lat_min lat_avg lat_rel lat_skip
  lat_min="$(printf '%s' "$latency_line" | sed -n 's/.*[[:space:]]min=\([^[:space:]]*\).*/\1/p')"
  lat_avg="$(printf '%s' "$latency_line" | sed -n 's/.*[[:space:]]avg=\([^[:space:]]*\).*/\1/p')"
  lat_rel="$(printf '%s' "$latency_line" | sed -n 's/.*[[:space:]]reliable=\([01]\).*/\1/p')"
  lat_skip="$(printf '%s' "$latency_line" | sed -n 's/.*[[:space:]]skip=\([a-z]*\).*/\1/p')"
  [ "${lat_rel:-1}" = "0" ] && warn "本机存在透明代理，延迟数值不可信（详见 tcping.sh 头部说明）"

  # ---------- 2. 远端采集 ----------
  dim "  -> 在 $TARGET 上采集（只读，不跑任何压测）..."
  build_run_args
  RUN_ARGS+=(-f "$PROFILE_SH" -A "--sections $SECTIONS" -t "$COLLECT_TIMEOUT" --label "profile-collect $TARGET")
  local errfile out rc
  errfile="$(mktemp "${TMPDIR:-/tmp}/sshmgr-collect.XXXXXX" 2>/dev/null)" || errfile=""
  out="$(bash "$SSH_EXEC" "${RUN_ARGS[@]}" 2>"${errfile:-/dev/null}")"
  rc=$?
  local errout=""
  [ -n "$errfile" ] && [ -f "$errfile" ] && errout="$(cat "$errfile" 2>/dev/null)"
  [ -n "$errfile" ] && rm -f "$errfile"

  if [ "$rc" -ne 0 ]; then
    err "采集失败（ssh_exec.sh 退出码 $rc）。常见原因：连不上 / 认证失败 / 超时"
    [ -n "$errout" ] && printf '%s\n' "$errout" | sed 's/^/  /' >&2
    # 半份结果绝不入库：见 server_profile.sh 尾部的完整性哨兵说明
    if [ -n "$out" ] || [ -n "$errout" ]; then
      local pf="$pfile.partial"
      { [ -n "$errout" ] && printf '# stderr\n%s\n' "$errout"; printf '%s\n' "$out"; } > "$pf" 2>/dev/null || true
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

  # ---------- 4. 与已有档案比对身份 ----------
  local old_machine="" old_fp=""
  if [ -f "$pfile" ]; then
    old_machine="$(pget "$pfile" machine_id)"
    old_fp="$(pget "$pfile" host_key_fp)"
  fi
  local new_machine new_fp
  new_machine="$(printf '%s\n' "$out" | sed -n 's/^machine_id=//p' | head -1)"
  new_fp="$(target_fingerprint)"

  # ---------- 5. 组装档案（原子写入） ----------
  local tmp="$pfile.tmp.$$"
  local scan_count=1 first_seen now old_note old_alias
  now="$(now_utc)"
  if [ -f "$pfile" ]; then
    local old_count; old_count="$(pget "$pfile" scan_count)"
    case "$old_count" in ''|*[!0-9]*) old_count=0 ;; esac
    scan_count=$((old_count + 1))
    first_seen="$(pget "$pfile" first_seen)"
    old_note="$(pget "$pfile" note)"
    old_alias="$(pget "$pfile" alias)"
  fi
  [ -n "${first_seen:-}" ] || first_seen="$now"

  local write_alias=""
  if [ -n "$ALIAS_OPT" ]; then
    write_alias="$ALIAS_OPT"
  elif ! like_ip "$hostpart"; then
    write_alias="$hostpart"
  elif [ -n "${old_alias:-}" ]; then
    write_alias="$old_alias"
  else
    write_alias="$hostpart"
  fi

  local remain_stale="" old_stale=""
  if [ "$PARTIAL_COLLECT" -eq 1 ] && [ -f "$pfile" ]; then
    old_stale="$(pget "$pfile" stale_sections)"
    local s
    local IFS=','
    for s in $old_stale; do
      [ -n "$s" ] || continue
      case ",$SECTIONS," in
        *",$s,"*) ;;
        *) remain_stale="${remain_stale}${remain_stale:+,}$s" ;;
      esac
    done
    unset IFS
  fi

  (
    umask 077
    printf '# ssh-server-manager profile —— 手工可编辑，保持 key=value 单行格式\n'
    printf '# 由 profile_store.sh collect 生成于 %s\n' "$now"
    printf 'connect_target=%s\n' "$TARGET"
    printf 'ssh_user=%s\n' "$EFF_USER"
    printf 'ssh_port=%s\n' "$EFF_PORT"
    [ -n "$EFF_JUMP" ]     && printf 'ssh_jump=%s\n' "$EFF_JUMP"
    [ -n "$EFF_IDENTITY" ] && printf 'ssh_identity=%s\n' "$EFF_IDENTITY"
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
    [ -n "$new_fp" ] && printf 'host_key_fp=%s\n' "$new_fp"
    printf 'alias=%s\n' "$write_alias"
    if [ -n "$NOTE" ]; then
      printf 'note=%s\n' "$NOTE"
    elif [ -n "${old_note:-}" ]; then
      printf 'note=%s\n' "$old_note"
    fi
    if [ "$PARTIAL_COLLECT" -eq 1 ]; then
      merge_old_sections "$pfile" "$SECTIONS"
    fi
    printf '%s\n' "$out" | normalize_kv
    if [ -n "$remain_stale" ]; then
      printf 'stale_sections=%s\n' "$remain_stale"
      local old_reason old_at
      old_reason="$(pget "$pfile" stale_reason)"
      old_at="$(pget "$pfile" stale_at)"
      [ -n "$old_reason" ] && printf 'stale_reason=%s\n' "$old_reason"
      [ -n "$old_at" ] && printf 'stale_at=%s\n' "$old_at"
    fi
    printf '# 以下由 profile_store 管理，勿手工改\n'
    printf 'profile_updated=%s\n' "$now"
  ) > "$tmp" 2>"$tmp.warn" || { err "写入临时文件失败"; rm -f "$tmp"; exit 1; }

  grep '^#WARN' "$tmp.warn" 2>/dev/null | sed 's/^/  /' >&2
  rm -f "$tmp.warn"
  chmod 600 "$tmp" 2>/dev/null || true

  # ---------- 6. 身份校验后再落盘 ----------
  if [ -f "$pfile" ]; then
    local reason=""
    if [ -n "$old_fp" ] && [ -n "$new_fp" ] && [ "$old_fp" != "$new_fp" ]; then
      reason="主机密钥指纹变了（原 ${old_fp:0:20}… 现 ${new_fp:0:20}…）"
    elif [ -n "$old_machine" ] && [ -n "$new_machine" ] && [ "$old_machine" != "$new_machine" ]; then
      reason="machine_id 变了（原 ${old_machine:0:12}… 现 ${new_machine:0:12}…）"
    elif [ -n "$old_fp" ] && [ -z "$new_fp" ]; then
      warn "本次无法从 known_hosts 读到主机指纹，跳过指纹比对（machine_id 仍会比对）"
    fi
    if [ -n "$reason" ]; then
      if [ "$FORCE" -eq 1 ]; then
        warn "$reason --force 已确认覆盖"
      else
        local alt="${pfile%.profile}.m2.profile"
        mv "$tmp" "$alt" 2>/dev/null
        err "检测到同一目标下换了一台机器/重装：$reason"
        err "  原档案: $pfile"
        err "  新机器的采集结果另存为: $alt"
        err "  如果确实重装/换机了，用 forget 删旧档案后重新 collect，或加 --force 覆盖。"
        exit 3
      fi
    fi
  fi

  mv "$tmp" "$pfile" || { err "落盘失败"; exit 1; }
  chmod 600 "$pfile" 2>/dev/null || true

  # ---------- 7. 跨档案的 IP 冲突提示 ----------
  local ip_primary other
  ip_primary="$(pget "$pfile" ip_primary)"
  if [ -n "$ip_primary" ]; then
    other="$(grep -lFx -e "ip_primary=$ip_primary" -e "ip_all=$ip_primary" "$PROFILE_DIR"/*.profile 2>/dev/null \
             | grep -v -F -x "$pfile" | head -1)"
    [ -n "$other" ] && warn "IP $ip_primary 同时出现在 $(basename "$other") 里 —— 可能是两台机器共用出口 IP（NAT），或档案没清理"
  fi

  ok "档案已写入 $pfile (第 ${scan_count} 次采集)"
  do_show_short "$pfile"
}

# ---------- 紧凑画像 ----------
do_show_short() { # $1 = profile file
  local f="$1"
  [ -f "$f" ] || { err "档案不存在: $f"; exit 2; }
  printf '\n'
  printf '%s\n' "═══ 服务器画像 ═══"
  line() {
    local v; v="$(pget "$f" "$1")"
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
  local st; st="$(pget "$f" stale_sections)"
  [ -n "$st" ] && printf '  %s已标脏: %s（原因: %s）%s\n' "$C_YEL" "$st" "$(pget "$f" stale_reason)" "$C_OFF"
  line "note"         "备注"
}

# ---------- show ----------
do_show() {
  local f rc=0
  f="$(find_profile "$TARGET" "$SSH_PORT")" || rc=$?
  [ "$rc" -eq 0 ] || { err "没有 $TARGET 的档案（先 collect；多端口时加 -p）"; exit 2; }
  if [ "$SHORT" -eq 1 ]; then do_show_short "$f"; return 0; fi
  if [ -n "$FIELDS" ]; then
    local IFS=','
    for k in $FIELDS; do
      k="${k%%=*}"
      grep -E "^${k}(\.[0-9]+)?=" "$f" 2>/dev/null | sed 's/^/  /'
    done
  else
    cat "$f"
  fi
}

# ---------- list ----------
do_list() {
  [ -d "$PROFILE_DIR" ] || { dim "（还没有任何档案）"; return 0; }
  col() {
    local s="$1" want="$2" w i pad="" acc="" c wc
    w="$(dispwidth "$s")"
    if [ "$w" -gt "$want" ]; then
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
    printf '%s%s ' "$s" "$pad"
  }
  local f n=0
  for f in "$PROFILE_DIR"/*.profile; do [ -f "$f" ] && n=$((n+1)); done
  if [ "$n" -eq 0 ]; then dim "（还没有任何档案）"; return 0; fi

  col "目标" 20; col "系统" 24; col "CPU" 26; col "内存MB" 9; col "延迟avg" 9; col "上次采集" 19
  printf '状态\n'
  for f in "$PROFILE_DIR"/*.profile; do
    [ -f "$f" ] || continue
    col "$(pget "$f" connect_target 2>/dev/null || echo "$(basename "$f" .profile)")" 20
    col "$(pget "$f" os 2>/dev/null)" 24
    col "$(pget "$f" cpu_model 2>/dev/null)" 26
    col "$(pget "$f" mem_total_mb 2>/dev/null)" 9
    col "$(pget "$f" latency_avg_ms 2>/dev/null)" 9
    col "$(pget "$f" last_scan 2>/dev/null | cut -c1-19)" 19
    if [ -n "$(pget "$f" stale_sections)" ]; then
      printf '%s\n' "已标脏($(pget "$f" stale_sections))"
    else
      printf '新鲜\n'
    fi
  done
  printf '\n共 %s 台。看单台: show -H <目标> --short\n' "$n"
}

# ---------- check ----------
do_check() {
  local f rc=0
  f="$(find_profile "$TARGET" "$SSH_PORT")" || rc=$?
  [ "$rc" -eq 0 ] || { err "没有 $TARGET 的档案（多端口时加 -p）"; exit 2; }
  local old_boot; old_boot="$(pget "$f" boot_id)"
  [ -n "$old_boot" ] || { warn "档案里没有 boot_id（旧版档案），无法判断是否重启过"; exit 0; }

  resolve_connection_meta "$f"
  build_run_args
  RUN_ARGS+=(-t 20 -c 'cat /proc/sys/kernel/random/boot_id 2>/dev/null; cut -d. -f1 /proc/uptime 2>/dev/null' \
             --label "profile-check $TARGET")
  local cur crc
  cur="$(bash "$SSH_EXEC" "${RUN_ARGS[@]}" 2>/dev/null)"
  crc=$?
  if [ "$crc" -ne 0 ] || [ -z "$cur" ]; then
    err "无法连接（ssh_exec.sh 退出码 $crc），档案状态未知"; exit 2
  fi
  cur="$(printf '%s' "$cur" | tr -d '\r')"
  local new_boot new_up
  new_boot="$(printf '%s\n' "$cur" | head -1)"
  new_up="$(printf '%s\n' "$cur" | sed -n '2p')"
  if [ "$new_boot" != "$old_boot" ]; then
    warn "机器重启过（boot_id 变了，当前 uptime ${new_up:-?}s）"
    warn "失效段落: runtimes/services/storage 基线；identity/hw 依然有效，无需重采。"
    warn "刷新: profile_store.sh collect -H $TARGET --sections runtimes,services,storage"
    exit 1
  fi
  ok "机器未重启，档案基线仍有效 (uptime ${new_up:-?}s)"
}

# ---------- compare ----------
do_compare() {
  local list="$TARGETS" t f rc pair
  local -a PFILES=() HOSTS=()
  list="$(printf '%s' "$list" | tr ',' ' ')"
  for t in $list; do
    rc=0
    f="$(find_profile "$t" "" 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$f" ]; then
      err "没有 $t 的档案"; exit 2
    fi
    PFILES+=("$f")
    HOSTS+=("$t")
  done
  [ "${#HOSTS[@]}" -ge 2 ] || { err "compare 至少需要两个目标（-H a,b 或重复 -H）"; exit 1; }

  local width=18
  row() { # label values...
    local lab="$1"; shift
    local w pad="" i val
    w="$(dispwidth "$lab")"
    for ((i=w; i<width; i++)); do pad="$pad "; done
    printf '%s%s' "$lab" "$pad"
    for val in "$@"; do
      printf '%-24s ' "$val"
    done
    printf '\n'
  }
  printf '%s\n' "═══ 档案对比 ═══"
  row "字段" "${HOSTS[@]}"
  for pair in "os|系统" "kernel|内核" "virt|虚拟化" "cpu_model|CPU" "cpu_cores|物理核" "cpu_threads|线程" "mem_total_mb|内存MB" "dmi_product_name|机型" "ip_primary|主IP" "latency_avg_ms|延迟avg"; do
    local field="${pair%%|*}" label="${pair#*|}"
    local -a VALS=()
    for f in "${PFILES[@]}"; do
      VALS+=("$(pget "$f" "$field")")
    done
    for t in "${!VALS[@]}"; do [ -n "${VALS[$t]}" ] || VALS[$t]="-"; done
    row "$label" "${VALS[@]}"
  done
  local -a VALS=()
  for f in "${PFILES[@]}"; do VALS+=("$(grep -c '^docker_container\.' "$f" 2>/dev/null)"); done
  row "容器数" "${VALS[@]}"
  VALS=()
  for f in "${PFILES[@]}"; do VALS+=("$(grep -c '^unit_running\.' "$f" 2>/dev/null)"); done
  row "运行服务数" "${VALS[@]}"
}

# ---------- set ----------
do_set() {
  local f rc=0
  f="$(find_profile "$TARGET" "$SSH_PORT")" || rc=$?
  [ "$rc" -eq 0 ] || { err "没有 $TARGET 的档案（多端口时加 -p）"; exit 2; }
  [ -n "$NOTE" ] && SET_PAIRS="$SET_PAIRS
note=$NOTE"
  [ -n "${SET_PAIRS// /}" ] || { err "没有要更新的字段。用法: set -H web1 note=\"生产库，别乱动\" os_label=..."; exit 1; }
  local tmp="$f.tmp.$$"
  ( umask 077; cp "$f" "$tmp" ) || exit 1
  local changed=0 pair k v
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    k="${pair%%=*}"; v="${pair#*=}"
    case "$k" in
      [A-Za-z_][A-Za-z0-9_]*) ;;
      *) err "非法键名: $k"; rm -f "$tmp"; exit 1 ;;
    esac
    case "$k" in
      connect_target|ssh_user|ssh_port|ssh_jump|ssh_identity|machine_id|boot_id|first_seen|last_scan|scan_count|collector_sha256|host_key_fp|stale_sections|stale_reason|stale_at|profile_updated)
        err "字段 $k 由采集器维护，不能用 set 修改"; rm -f "$tmp"; exit 1 ;;
    esac
    if is_list_key "$k"; then
      warn "跳过列表键 $k（由采集器维护，手改会在下次采集时被覆盖）"
      continue
    fi
    v="$(printf '%s' "$v" | tr '\n\r\t' '   ')"
    if grep -q "^${k}=" "$tmp"; then
      V="$v" awk -v k="$k" 'BEGIN{FS=OFS="="} $1==k {print k"="ENVIRON["V"]; next} {print}' \
        "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
    else
      printf '%s=%s\n' "$k" "$v" >> "$tmp"
    fi
    changed=$((changed + 1))
  done <<EOF
$SET_PAIRS
EOF
  if [ "$changed" -gt 0 ]; then
    grep -v '^profile_updated=' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
    printf 'profile_updated=%s\n' "$(now_utc)" >> "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$f" && ok "已更新 $changed 个字段: $f"
  else
    rm -f "$tmp"
    err "没有实际更新任何字段"
    exit 1
  fi
}

# ---------- mark-stale ----------
do_mark_stale() {
  local f rc=0
  f="$(find_profile "$TARGET" "$SSH_PORT")" || rc=$?
  [ "$rc" -eq 3 ] && return 0
  [ "$rc" -eq 0 ] || return 0
  [ -n "$STALE_SECTIONS" ] || { err "需要 --sections 指明哪些段落失效了"; exit 1; }
  local tmp="$f.tmp.$$"
  local now; now="$(now_utc)"
  local old; old="$(pget "$f" stale_sections)"
  local merged="$STALE_SECTIONS"
  [ -n "$old" ] && merged="$old,$STALE_SECTIONS"
  merged="$(printf '%s' "$merged" | tr ',' '\n' | awk '!seen[$0]++' | paste -sd, -)"
  (
    umask 077
    grep -v -e '^stale_sections=' -e '^stale_reason=' -e '^stale_at=' -e '^profile_updated=' "$f"
    printf 'stale_sections=%s\n' "$merged"
    [ -n "$STALE_REASON" ] && printf 'stale_reason=%s\n' "$STALE_REASON"
    printf 'stale_at=%s\n' "$now"
    printf 'profile_updated=%s\n' "$now"
  ) > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 0; }
  dim "  档案已标脏: $merged"
}

# ---------- hint ----------
do_hint() {
  local f rc=0
  f="$(find_profile "$TARGET" "$SSH_PORT" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 3 ]; then
    printf '[档案不唯一] %s 有多个端口的档案，请加 -p 指定\n' "$TARGET"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf '[无档案] 首次连这台，可跑: profile_store.sh collect -H %s\n' "$TARGET"
    return 0
  fi
  local st; st="$(pget "$f" stale_sections)"
  if [ -n "$st" ]; then
    printf '[档案已标脏: %s] 原因: %s — 需要时刷新: collect -H %s --sections %s\n' \
      "$st" "$(pget "$f" stale_reason)" "$TARGET" "$st"
    return 0
  fi
  return 0
}

# ---------- forget ----------
do_forget() {
  local f rc=0
  f="$(find_profile "$TARGET" "$SSH_PORT")" || rc=$?
  [ "$rc" -eq 0 ] || { err "没有 $TARGET 的档案（多端口时加 -p）"; exit 2; }
  local alt="${f%.profile}.m2.profile" partial="${f%.profile}.partial"
  rm -f "$f" "$alt" "$partial" && ok "已删除 $f"
}

# ---------- 分发 ----------
case "$CMD" in
  collect)    do_collect ;;
  find)
    f="$(find_profile "$TARGET" "$SSH_PORT")" || {
      [ $? -eq 3 ] || dim "没有 $TARGET 的档案"
      exit 2
    }
    echo "$f"
    do_show_short "$f" ;;
  show)       do_show ;;
  list)       do_list ;;
  check)      do_check ;;
  compare)    do_compare ;;
  set)        do_set ;;
  mark-stale) do_mark_stale ;;
  hint)       do_hint ;;
  forget)     do_forget ;;
  *)          usage; exit 1 ;;
esac
