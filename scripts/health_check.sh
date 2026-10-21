#!/usr/bin/env bash
# sshmgr:read-only  —— 声明本脚本只读。ssh_exec.sh 见此前 20 行内的标记后不会把它
#                     当成变更类操作，否则每次巡检都会被误报"变更类操作"。
#
# health_check.sh - 一键系统巡检，输出结构化报告（在目标主机上运行）
#
# 设计意图：巡检的价值在于「一次跑完拿到全貌」，所以这里刻意不设 set -e ——
# 缺少某个工具时降级输出"不可用"，而不是中途退出只给半份报告。
# 全程只读，不做任何变更。
#
# 用法:
#   bash health_check.sh                 # 完整巡检
#   bash health_check.sh --deep          # 额外做 du 大目录扫描（慢，可能几分钟）
#   bash health_check.sh --quick         # 跳过 docker / journal / 更新计数等慢项
#   bash health_check.sh --updates       # 额外统计待安装的更新数（apt/dnf，慢）
#   bash health_check.sh --sections cpu,memory,disk
#   bash health_check.sh --strict        # 有 WARN/CRIT 时以非零码退出（供批量脚本判定）
#   bash health_check.sh --disk-warn 75 --disk-crit 85 --load-warn 1.5
#
# 通过 ssh_exec.sh 调用:
#   ./ssh_exec.sh -H web1 -f ./health_check.sh -t 180
#   ./ssh_exec.sh -H web1 -f ./health_check.sh -A "--disk-warn 75" -t 180
#
# 阈值可用命令行参数或环境变量覆盖（默认值按通用服务器设定，日志盘/构建机应各自调整）:
#   --disk-warn / --disk-crit       SSHMGR_DISK_WARN=80    SSHMGR_DISK_CRIT=90
#   --inode-warn / --inode-crit     SSHMGR_INODE_WARN=80   SSHMGR_INODE_CRIT=90
#   --load-warn / --load-crit       SSHMGR_LOAD_WARN=1.0   SSHMGR_LOAD_CRIT=2.0    # 每核负载
#   --mem-warn / --mem-crit         SSHMGR_MEM_WARN=85     SSHMGR_MEM_CRIT=93      # 已用内存百分比

LC_ALL=C

DEEP=0
QUICK=0
DO_UPDATES=0
STRICT=0
WANT_SECTIONS=""
CLI_DISK_WARN="" CLI_DISK_CRIT=""
CLI_INODE_WARN="" CLI_INODE_CRIT=""
CLI_LOAD_WARN="" CLI_LOAD_CRIT=""
CLI_MEM_WARN="" CLI_MEM_CRIT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --deep)     DEEP=1; shift ;;
    --quick)    QUICK=1; shift ;;
    --updates)  DO_UPDATES=1; shift ;;
    --strict)   STRICT=1; shift ;;
    --sections)
      [ $# -ge 2 ] || { printf '[error] --sections 需要一个参数\n' >&2; exit 1; }
      WANT_SECTIONS="$2"; shift 2 ;;
    --disk-warn)  [ $# -ge 2 ] || exit 1; CLI_DISK_WARN="$2"; shift 2 ;;
    --disk-crit)  [ $# -ge 2 ] || exit 1; CLI_DISK_CRIT="$2"; shift 2 ;;
    --inode-warn) [ $# -ge 2 ] || exit 1; CLI_INODE_WARN="$2"; shift 2 ;;
    --inode-crit) [ $# -ge 2 ] || exit 1; CLI_INODE_CRIT="$2"; shift 2 ;;
    --load-warn)  [ $# -ge 2 ] || exit 1; CLI_LOAD_WARN="$2"; shift 2 ;;
    --load-crit)  [ $# -ge 2 ] || exit 1; CLI_LOAD_CRIT="$2"; shift 2 ;;
    --mem-warn)   [ $# -ge 2 ] || exit 1; CLI_MEM_WARN="$2"; shift 2 ;;
    --mem-crit)   [ $# -ge 2 ] || exit 1; CLI_MEM_CRIT="$2"; shift 2 ;;
    -h|--help)  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          printf '未知选项: %s (--help)\n' "$1" >&2; exit 1 ;;
  esac
done

# ---------- 段落校验 ----------
KNOWN_SECTIONS="identity cpu memory disk network services security logins docker updates"
if [ -n "$WANT_SECTIONS" ]; then
  _ifs="$IFS"; IFS=','
  for _s in $WANT_SECTIONS; do
    [ -n "$_s" ] || continue
    case " $KNOWN_SECTIONS " in
      *" $_s "*) ;;
      *) printf '[error] 未知段落: %s（可用: %s）\n' "$_s" "$KNOWN_SECTIONS" >&2; exit 1 ;;
    esac
  done
  IFS="$_ifs"
fi

# ---------- 阈值 ----------
# 可按命令行或环境调整：日志盘、构建机、数据库对"满"和"忙"的定义本来就不同，
# 硬编码一套阈值会逼着使用者去改脚本。
DISK_WARN="${CLI_DISK_WARN:-${SSHMGR_DISK_WARN:-80}}"
DISK_CRIT="${CLI_DISK_CRIT:-${SSHMGR_DISK_CRIT:-90}}"
INODE_WARN="${CLI_INODE_WARN:-${SSHMGR_INODE_WARN:-80}}"
INODE_CRIT="${CLI_INODE_CRIT:-${SSHMGR_INODE_CRIT:-90}}"
LOAD_WARN="${CLI_LOAD_WARN:-${SSHMGR_LOAD_WARN:-1.0}}"
LOAD_CRIT="${CLI_LOAD_CRIT:-${SSHMGR_LOAD_CRIT:-2.0}}"
MEM_WARN="${CLI_MEM_WARN:-${SSHMGR_MEM_WARN:-85}}"
MEM_CRIT="${CLI_MEM_CRIT:-${SSHMGR_MEM_CRIT:-93}}"

_validate_num() { # name value
  case "$2" in
    ''|*[!0-9.]*|*.*.*) printf '[error] 阈值 %s 不是数字: %s\n' "$1" "$2" >&2; exit 1 ;;
  esac
}
_validate_num DISK_WARN "$DISK_WARN"
_validate_num DISK_CRIT "$DISK_CRIT"
_validate_num INODE_WARN "$INODE_WARN"
_validate_num INODE_CRIT "$INODE_CRIT"
_validate_num LOAD_WARN "$LOAD_WARN"
_validate_num LOAD_CRIT "$LOAD_CRIT"
_validate_num MEM_WARN "$MEM_WARN"
_validate_num MEM_CRIT "$MEM_CRIT"
unset _s _ifs

# ---------- 基础 helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

SEC() { printf '\n=== %s ===\n' "$1"; }
KV()  { printf '  %-26s %s\n' "$1" "$2"; }
NOTE(){ printf '  %s\n' "$1"; }
UNAVAIL() { printf '  %-26s %s\n' "$1" "不可用（$2）"; }

# 只跑请求的段落
want() {
  [ -z "$WANT_SECTIONS" ] && return 0
  case ",${WANT_SECTIONS}," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

CRIT=0
WARN=0
VERDICT_LINES=""

# flag <CRIT|WARN|INFO> <一句话描述>
flag() {
  case "$1" in
    CRIT) CRIT=$((CRIT + 1)) ;;
    WARN) WARN=$((WARN + 1)) ;;
  esac
  VERDICT_LINES="${VERDICT_LINES}${1} | ${2}
"
}

pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0<=0) {print "n/a"} else {printf "%.0f", a*100/b} }'; }
num() { awk -v a="$1" 'BEGIN{printf "%.2f", a}'; }
cmp_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }

# ---------- 1. 主机与系统 ----------
if want identity; then
SEC "IDENTITY / 主机与系统"
KV "hostname" "$(hostname 2>/dev/null || echo unknown)"
KV "date (UTC)" "$(date -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
if [ -r /etc/os-release ]; then
  . /etc/os-release 2>/dev/null
  KV "os" "${PRETTY_NAME:-${NAME:-unknown}}"
  KV "os id / version" "${ID:-?} ${VERSION_ID:-?}"
elif [ -r /etc/redhat-release ]; then
  KV "os" "$(cat /etc/redhat-release)"
else
  UNAVAIL "os" "无 /etc/os-release"
fi
KV "kernel" "$(uname -sr 2>/dev/null)"
KV "arch" "$(uname -m 2>/dev/null)"
have systemd-detect-virt && KV "virtualization" "$(systemd-detect-virt 2>/dev/null)"
if [ -r /proc/uptime ]; then
  up_s=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  KV "uptime" "$(awk -v s="${up_s:-0}" 'BEGIN{printf "%dd %dh %dm", s/86400, (s%86400)/3600, (s%3600)/60}')"
  if [ -r /proc/stat ] && [ -r /proc/uptime ]; then
    boot=$(( $(date +%s) - ${up_s:-0} ))
    KV "boot time" "$(date -d "@$boot" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
  fi
fi
if have timedatectl; then
  sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  case "$sync" in
    yes) KV "time sync" "已同步 (NTP)" ;;
    no)  KV "time sync" "未同步"; flag WARN "NTP 时间未同步，日志时间戳与 TLS 校验可能出问题" ;;
    *)   KV "time sync" "未知" ;;
  esac
  tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
  [ -n "$tz" ] && KV "timezone" "$tz"
fi
if [ -f /var/run/reboot-required ]; then
  KV "reboot required" "是 (/var/run/reboot-required)"
  flag WARN "有更新需要重启才能生效（如内核、glibc）"
elif have needs-restarting; then
  if ! needs-restarting -r >/dev/null 2>&1; then
    KV "reboot required" "是 (needs-restarting)"
    flag WARN "有更新需要重启才能生效"
  else
    KV "reboot required" "否"
  fi
else
  KV "reboot required" "未知"
fi
fi

# ---------- 2. CPU 与负载 ----------
if want cpu; then
SEC "CPU / 负载"
CORES="$( (have nproc && nproc) || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1 )"
[ -n "$CORES" ] || CORES=1
KV "cpu cores" "$CORES"
have nproc && KV "cpu model" "$(awk -F: '/^model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
if [ -r /proc/loadavg ]; then
  L1=$(cut -d' ' -f1 /proc/loadavg)
  L5=$(cut -d' ' -f2 /proc/loadavg)
  L15=$(cut -d' ' -f3 /proc/loadavg)
  KV "load (1/5/15)" "$L1 / $L5 / $L15"
  per=$(awk -v l="$L1" -v c="$CORES" 'BEGIN{printf "%.2f", l/c}')
  KV "load per core" "$per   (超过 1.0 说明有排队)"
  # 负载必须除以核数才有意义：8 核跑 6 很健康，1 核跑 6 已经严重过载
  if cmp_ge "$per" "$LOAD_CRIT"; then flag CRIT "负载过高：每核 ${per}（${CORES} 核，load1=${L1}）"
  elif cmp_ge "$per" "$LOAD_WARN"; then flag WARN "负载偏高：每核 ${per}（${CORES} 核）"; fi
else
  UNAVAIL "load" "无 /proc/loadavg"
fi
if have ps; then
  NOTE "按 CPU 排序的进程:"
  if ps -eo pid,user,%cpu,%mem,etime,cmd --sort=-%cpu >/dev/null 2>&1; then
    ps -eo pid,user,%cpu,%mem,etime,cmd --sort=-%cpu 2>/dev/null | head -6 | sed 's/^/    /'
  else
    ps aux 2>/dev/null | sort -k3 -rn | head -6 | sed 's/^/    /'
  fi
fi
fi

# ---------- 3. 内存 ----------
if want memory; then
SEC "MEMORY / 内存"
if [ -r /proc/meminfo ]; then
  mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  if [ -z "$ma" ]; then
    # 老内核没有 MemAvailable，用 Free+Buffers+Cached 近似
    ma=$(awk '/^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} END{print f+b+c}' /proc/meminfo)
  fi
  KV "mem total" "$((mt / 1024)) MB"
  # 看 available 而不是 free：空闲内存会被内核用作缓存，free 低是正常的
  KV "mem available" "$((ma / 1024)) MB  ($(pct "$ma" "$mt")% 可用)"
  used=$(pct "$((mt - ma))" "$mt")
  KV "mem used" "${used}%"
  if cmp_ge "$used" "$MEM_CRIT"; then flag CRIT "内存紧张：已用 ${used}%，available 仅 $((ma / 1024))MB"
  elif cmp_ge "$used" "$MEM_WARN"; then flag WARN "内存偏高：已用 ${used}%"; fi

  st=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  if [ "${st:-0}" -gt 0 ]; then
    su=$(pct "$((st - sf))" "$st")
    KV "swap" "$((st / 1024)) MB total, ${su}% 已用"
    if cmp_ge "$su" 50; then flag WARN "swap 使用率 ${su}%，可能存在内存压力或内存泄漏"; fi
  else
    KV "swap" "未启用"
  fi

  oom=0
  if have journalctl && [ "$QUICK" -eq 0 ]; then
    oom=$(journalctl -k --since '7 days ago' --no-pager 2>/dev/null | grep -ci 'killed process' || true)
  fi
  if [ "${oom:-0}" -eq 0 ]; then
    oom=$(dmesg -T 2>/dev/null | grep -ci 'killed process' || true)
  fi
  if [ "${oom:-0}" -gt 0 ]; then
    KV "OOM kills (7d)" "$oom"
    flag WARN "近 7 天有 ${oom} 次 OOM kill，进程曾被系统杀死"
  fi
else
  UNAVAIL "memory" "无 /proc/meminfo"
fi
if have ps; then
  NOTE "按内存排序的进程:"
  if ps -eo pid,user,%cpu,%mem,rss,cmd --sort=-%mem >/dev/null 2>&1; then
    ps -eo pid,user,%cpu,%mem,rss,cmd --sort=-%mem 2>/dev/null | head -6 | sed 's/^/    /'
  else
    ps aux 2>/dev/null | sort -k4 -rn | head -6 | sed 's/^/    /'
  fi
fi
fi

# ---------- 4. 磁盘与 inode ----------
if want disk; then
SEC "DISK / 磁盘"
if have df; then
  NOTE "文件系统使用率（本地文件系统，排除内存文件系统）:"
  df -PT 2>/dev/null | awk 'NR==1 || ($2 !~ /^(tmpfs|devtmpfs|squashfs|overlay|ramfs|autofs|proc|sysfs)$/)' \
    | head -20 | sed 's/^/    /'
  NOTE "使用率 >= ${DISK_WARN}% 的分区:"
  high=$(df -PT 2>/dev/null | awk -v th="$DISK_WARN" 'NR>1 && $2 !~ /^(tmpfs|devtmpfs|squashfs|overlay|ramfs)$/ {
      gsub(/%/,"",$(NF-1)); if ($(NF-1)+0 >= th+0) print $(NF-1)"%  "$NF }')
  if [ -n "$high" ]; then
    printf '%s\n' "$high" | sed 's/^/    /'
    # 用 here-string 而不是管道：管道会让 while 跑在子 shell 里，flag 的计数就丢了
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      u=$(printf '%s' "$line" | awk '{gsub(/%/,"",$1); print $1}')
      if cmp_ge "${u:-0}" "$DISK_CRIT"; then
        flag CRIT "磁盘告急：$line"
      else
        flag WARN "磁盘偏高：$line"
      fi
    done <<< "$high"
  else
    NOTE "    （无）"
  fi

  NOTE "inode 使用率 >= ${INODE_WARN}% 的分区:"
  # inode 满和磁盘满的报错都是 "No space left on device"，但 df -h 看不出来，必须单独查
  ihigh=$(df -iPT 2>/dev/null | awk -v th="$INODE_WARN" 'NR>1 && $2 !~ /^(tmpfs|devtmpfs|squashfs|overlay|ramfs)$/ {
      gsub(/%/,"",$(NF-1)); if ($(NF-1)+0 >= th+0) print $(NF-1)"%  "$NF }')
  if [ -n "$ihigh" ]; then
    printf '%s\n' "$ihigh" | sed 's/^/    /'
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      u=$(printf '%s' "$line" | awk '{gsub(/%/,"",$1); print $1}')
      if cmp_ge "${u:-0}" "$INODE_CRIT"; then
        flag CRIT "inode 告急：$line（会导致无法创建新文件，即使磁盘还有空间）"
      else
        flag WARN "inode 偏高：$line"
      fi
    done <<< "$ihigh"
  else
    NOTE "    （无）"
  fi
else
  UNAVAIL "disk" "缺少 df"
fi

if have lsof; then
  # df 显示满但 du 找不到大文件时，通常是「已删除但仍被进程占用」的文件
  deleted=$(lsof -nP +L1 2>/dev/null | awk 'NR>1 && $5 ~ /^[0-9]+$/ {print}' | head -8)
  if [ -n "$deleted" ]; then
    NOTE "已删除但仍被进程占用的文件（空间不会自动释放）:"
    printf '%s\n' "$deleted" | sed 's/^/    /'
    flag WARN "存在已删除但被进程占用的文件，需重启对应进程才能释放空间"
  fi
fi

if [ "$DEEP" -eq 1 ] && have du; then
  NOTE "大目录 TOP（du，可能需要几分钟）:"
  du -xhd1 / 2>/dev/null | sort -rh | head -12 | sed 's/^/    /'
  du -xhd1 /var 2>/dev/null | sort -rh | head -8 | sed 's/^/    /'
else
  NOTE "（加 --deep 可扫描大目录占用）"
fi
fi

# ---------- 5. 网络与端口 ----------
if want network; then
SEC "NETWORK / 网络"
if have ss; then
  NOTE "监听端口:"
  ss -tulpnH 2>/dev/null | awk '{print $1, $5, $7}' | sort -u | head -25 | sed 's/^/    /'
  est=$(ss -tanH state established 2>/dev/null | wc -l)
  KV "ESTABLISHED 连接数" "$est"
  tw=$(ss -tanH state time-wait 2>/dev/null | wc -l)
  KV "TIME_WAIT 连接数" "$tw"
elif have netstat; then
  NOTE "监听端口 (netstat):"
  netstat -tulpn 2>/dev/null | awk '/^(tcp|udp)/{print $1, $4, $7}' | sort -u | head -25 | sed 's/^/    /'
  est=$(netstat -tan 2>/dev/null | grep -c ESTABLISHED)
  KV "ESTABLISHED 连接数" "$est"
else
  UNAVAIL "ports" "缺少 ss 与 netstat"
fi
have ip && { NOTE "地址与路由:"; ip -brief addr 2>/dev/null | sed 's/^/    /'; ip route 2>/dev/null | head -5 | sed 's/^/    /'; }
if [ -r /etc/resolv.conf ]; then
  KV "dns" "$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)"
fi
if [ -r /proc/net/dev ]; then
  NOTE "网卡流量统计:"
  awk 'NR>2 {gsub(/:/,"",$1); if ($1!="lo") printf "    %-12s rx=%d MB tx=%d MB\n", $1, $2/1048576, $10/1048576}' /proc/net/dev
fi
fi

# ---------- 6. 服务与定时任务 ----------
if want services; then
SEC "SERVICES / 服务"
if have systemctl; then
  failed="$(systemctl --failed --no-legend --no-pager 2>/dev/null | head -15)"
  if [ -n "$failed" ]; then
    NOTE "失败的 systemd 单元:"
    printf '%s\n' "$failed" | sed 's/^/    /'
    n=$(printf '%s\n' "$failed" | grep -c .)
    flag CRIT "有 ${n} 个 systemd 单元处于 failed 状态"
  else
    KV "systemd failed units" "0"
  fi
  KV "running units" "$(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | grep -c .)"
  NOTE "systemd timers:"
  systemctl list-timers --all --no-legend --no-pager 2>/dev/null | head -8 | sed 's/^/    /'
else
  UNAVAIL "systemd" "非 systemd 系统"
fi
if have crontab || [ -d /etc/cron.d ]; then
  n=0
  for d in /var/spool/cron /var/spool/cron/crontabs; do
    [ -d "$d" ] && n=$((n + $(ls -1 "$d" 2>/dev/null | wc -l)))
  done
  n=$((n + $(ls -1 /etc/cron.d 2>/dev/null | wc -l)))
  KV "cron 相关条目文件数" "$n"
fi
fi

# ---------- 7. 安全状态 ----------
if want security; then
SEC "SECURITY / 安全状态"
if have getenforce; then
  KV "selinux" "$(getenforce 2>/dev/null)"
elif [ -r /sys/fs/selinux/enforce ]; then
  KV "selinux" "$( [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = "1" ] && echo Enforcing || echo Permissive )"
else
  KV "selinux" "未启用"
fi
if [ -r /sys/module/apparmor/parameters/enabled ]; then
  KV "apparmor" "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)"
fi

fw=""
have ufw && fw="$(ufw status 2>/dev/null | head -1)"
[ -n "$fw" ] && KV "ufw" "$fw"
if have firewall-cmd; then
  KV "firewalld" "$(firewall-cmd --state 2>/dev/null || echo 'not running')"
fi
if have iptables; then
  # ⚠ 非 root 时 iptables -S 会静默失败，wc -l 得 0 —— 那读起来像"完全没有防火墙规则"，
  # 在安全评估里是危险的假阴性。所以先确认能真正读到，读不到就明说"需要 root"。
  if iptables -S >/dev/null 2>&1; then
    KV "iptables 规则数" "$(iptables -S 2>/dev/null | wc -l)"
  else
    KV "iptables 规则数" "未知（需要 root 才能读取）"
  fi
fi
case "$fw" in
  *inactive*) flag WARN "ufw 处于 inactive，防火墙未生效" ;;
esac

# 用 sshd -T 读实际生效的配置，比 grep 配置文件可靠（含 Include 与默认值）
if have sshd; then
  if sshd -T >/dev/null 2>&1; then
    NOTE "sshd 生效配置（sshd -T）:"
    sshd -T 2>/dev/null | grep -iE '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|x11forwarding|maxauthtries|allowusers|allowgroups) ' \
      | sed 's/^/    /'
    if sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes'; then
      # 这是 INFO 而不是 WARN：密码登录是合法选择，本 skill 也支持用密码连。
      # 会在用户有意使用密码的机器上每次都报 WARN，只会制造噪音。
      # 真要做合规检查时把 SSHMGR_REQUIRE_KEY=1 打开，它才升级为 WARN。
      if [ "${SSHMGR_REQUIRE_KEY:-0}" = "1" ]; then
        flag WARN "SSH 允许密码登录（SSHMGR_REQUIRE_KEY=1，按 hardening.md 分批推进）"
      else
        KV "SSH 密码登录" "允许（如需改为密钥见 hardening.md；本 skill 支持密码登录，故不告警）"
      fi
    fi
    if sshd -T 2>/dev/null | grep -qi '^permitrootlogin yes'; then
      flag WARN "SSH 允许 root 直接登录，建议改为 prohibit-password"
    fi
  else
    UNAVAIL "sshd -T" "需要 root 权限"
  fi
fi
if have fail2ban-client; then
  KV "fail2ban" "$(fail2ban-client status 2>/dev/null | grep -i 'jail list' | sed 's/.*://' | tr -d '\t' || echo unknown)"
else
  KV "fail2ban" "未安装"
fi
if have journalctl; then
  KV "journal 占用" "$(journalctl --disk-usage 2>/dev/null | sed 's/^Archived and active journals take up //')"
fi
echo
fi

# ---------- 8. 登录与账号 ----------
if want logins; then
SEC "LOGINS / 登录与账号"
have who && { NOTE "当前登录用户:"; who 2>/dev/null | sed 's/^/    /'; [ -z "$(who 2>/dev/null)" ] && NOTE "    （无）"; }
if have last; then
  NOTE "最近登录记录:"
  last -n 6 -w 2>/dev/null | head -8 | sed 's/^/    /'
fi
if have getent; then
  KV "有 sudo 权限的用户" "$( { getent group sudo 2>/dev/null; getent group wheel 2>/dev/null; } | awk -F: '{print $4}' | tr ',' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
fi
if [ -r /etc/passwd ]; then
  KV "可登录账号数（有 shell）" "$(awk -F: '$7 !~ /(nologin|false)$/ {n++} END{print n+0}' /etc/passwd)"
fi
fi

# ---------- 9. Docker（可选） ----------
if want docker && [ "$QUICK" -eq 1 ]; then
  SEC "DOCKER / 容器"
  NOTE "（--quick 已跳过 Docker 检查）"
fi
if want docker && [ "$QUICK" -eq 0 ]; then
SEC "DOCKER / 容器"
if have docker; then
  if docker info >/dev/null 2>&1; then
    running=$(docker ps -q 2>/dev/null | wc -l)
    total=$(docker ps -aq 2>/dev/null | wc -l)
    KV "容器" "${running} running / ${total} total"
    NOTE "Exited / Restarting / unhealthy 的容器:"
    # 没有 healthcheck 的 "Up 2 hours" 是正常状态，不能当成不健康 —— 以前的
    # 负向 grep 会把所有未配置 healthcheck 的容器都报成异常。
    bad=$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | awk -F'\t' '
      {
        s=tolower($2)
        if (s ~ /^(exited|dead|restarting|removing|created|paused)/ || s ~ /\(unhealthy\)/) print $0
      }' | head -10)
    if [ -n "$bad" ]; then
      printf '%s\n' "$bad" | sed 's/^/    /'
      flag WARN "存在 Exited/Restarting/unhealthy 容器"
    else
      NOTE "    （无）"
    fi
    NOTE "docker 磁盘占用:"
    docker system df 2>/dev/null | sed 's/^/    /'
  else
    UNAVAIL "docker" "当前用户无权限访问 docker daemon（需要 docker 组或 root）"
  fi
else
  KV "docker" "未安装"
fi
fi

# ---------- 10. 更新计数（可选，慢） ----------
if want updates && [ "$DO_UPDATES" -eq 1 ]; then
SEC "UPDATES / 待安装更新"
if have apt-get; then
  n=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst' || true)
  KV "可更新软件包" "${n:-未知}"
  sec_n=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst.*[Ss]ecurity' || true)
  KV "其中安全更新" "${sec_n:-未知}"
elif have dnf || have yum; then
  pm=$(have dnf && echo dnf || echo yum)
  KV "可更新软件包" "$($pm -q check-update 2>/dev/null | grep -c '^[a-zA-Z0-9]' || true)"
else
  UNAVAIL "updates" "未知包管理器"
fi
fi

# ---------- SUMMARY ----------
SEC "SUMMARY / 结论"
if [ -n "$VERDICT_LINES" ]; then
  printf '%s' "$VERDICT_LINES" | sort | sed 's/^/  /'
fi
if [ "$CRIT" -gt 0 ]; then
  printf '  %s\n' "SSHMGR_VERDICT=CRIT  (crit=${CRIT} warn=${WARN})"
elif [ "$WARN" -gt 0 ]; then
  printf '  %s\n' "SSHMGR_VERDICT=WARN  (crit=0 warn=${WARN})"
else
  printf '  %s\n' "SSHMGR_VERDICT=OK  (crit=0 warn=0)"
fi

if [ "$STRICT" -eq 1 ]; then
  [ "$CRIT" -gt 0 ] && exit 2
  [ "$WARN" -gt 0 ] && exit 1
fi
exit 0
