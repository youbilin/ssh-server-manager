#!/usr/bin/env bash
# sshmgr:read-only  —— 声明本脚本只读。ssh_exec.sh 看到这行就不会把它当成变更类操作，
#                     profile_store.sh 也依赖这一点：采集档案绝不能反过来把自己标脏。
#
# server_profile.sh - 首次接触一台服务器时的信息采集（在目标主机上运行）
#
# 定位：把「这台机器是什么、装了什么」这类**慢变事实**一次看清并存档。
# 负载、内存余量、当前连接数这类**易变状态**不在这里采 —— 那是 health_check.sh 的事，
# 采了也会天天过期，等于没有档案。
#
# ═══════════════════════════════════════════════════════════════════════════
# 硬红线：本脚本绝不运行任何压测 / 基准测试。
#   禁止: sysbench / fio / dd 写测试 / stress-ng / memtester / iperf3 /
#         openssl speed / bonnie++ / unixbench
#   只做: 读型号、读清单、数数量 —— lscpu / /proc/meminfo / lsblk / df -l /
#         ip / ss / docker ps / docker info / systemctl
# 理由：在生产机上跑基准测试，既污染业务指标、又可能触发监控告警，
#       而结论对运维决策毫无用处。连通性由本地 tcping.sh 负责（3~5 次 TCP 握手），
#       不在远端产生任何流量。
# ═══════════════════════════════════════════════════════════════════════════
#
# 输出：平铺的 key=value 行（同名键可重复出现，由 profile_store.sh 索引化）。
# 最后一行固定是 profile_complete=1 —— 采集被中断时不会有这一行，
# profile_store.sh 见不到它就拒绝入库，防止半份报告静默变成"可信档案"。
#
# 用法（一般不直接跑，走 profile_store.sh collect）:
#   ./ssh_exec.sh -H web1 -f scripts/server_profile.sh -t 120
#   ./ssh_exec.sh -H web1 -f scripts/server_profile.sh -A "--sections hw,docker"
#
# 成本纪律（每一条都是踩过坑的）：
#   - 不跑 `docker system df`：要遍历全部镜像/卷，是整个采集里最慢的一步
#   - `df` 必须带 `-l`：不带头的话，一个僵死的 NFS 挂载点能让 df 卡几分钟
#   - `lsblk` 不带 `-f`：-f 会对未挂载设备触发 blkid 探测；文件系统从 findmnt 读
#   - 需要 root 的一律显式记 unknown reason=needs_root。
#     特别不要学"非 root 时打印 iptables 规则数 0"——那读起来像"没有防火墙"，
#     在安全评估里是危险的假阴性
#   - /sys/class/net/*/speed 在 down 的网卡上会返回 EINVAL → 记 unknown，
#     不要回退 ethtool（要 root，还可能慢）
#   - 语言运行时先 command -v 再跑（java -version 要起 JVM，约 0.2~1s）
#   - docker ps 在非 root 的 deploy 用户下常因 socket 权限失败，
#     要记 docker=present,inaccessible 而不是 docker=absent —— 两者含义完全不同
#   - 每个可能慢的探测都套 timeout，避免一台病态主机吃掉整个采集窗口

LC_ALL=C

WANT_SECTIONS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sections) shift; WANT_SECTIONS="${1:-}"; shift ;;
    -h|--help)  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          printf '未知选项: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

# 给可能慢的命令套上限。用法: RUN 5 docker ps
if have timeout && timeout --version >/dev/null 2>&1; then
  RUN() { timeout "$@" 2>/dev/null; }
else
  RUN() { shift; "$@" 2>/dev/null; }
fi

# 输出一行 key=value。值会被单行化（换行/制表符折成空格）并去掉首尾空白。
K() {
  local v
  v="$(printf '%s' "${2:-}" | tr '\t\r\n' '   ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s=%s\n' "$1" "$v"
}
# 列表键：同一键名重复出现，由 profile_store.sh 索引化成 key.0 / key.1 ...
L() { K "$1" "$2"; }

want() {
  [ -z "$WANT_SECTIONS" ] && return 0
  case ",${WANT_SECTIONS}," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

IS_ROOT=0
[ "$(id -u 2>/dev/null || echo 1)" = "0" ] && IS_ROOT=1

# ══════════════════════════════ identity ══════════════════════════════
if want identity; then

K "profile_schema" "1"
K "collected_at" "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
K "collected_by" "$(id -un 2>/dev/null) (uid=$(id -u 2>/dev/null))"

K "hostname" "$(hostname 2>/dev/null || echo unknown)"
K "fqdn" "$(hostname -f 2>/dev/null || echo unknown)"

# 本机地址。ip_primary 取"对外发包时用的源地址"（默认路由的 src），
# 这是"这台机器是哪台"最有意义的答案；ip_all 记全部地址，供按 IP 查档案时比对。
# ip route get 只查路由表不发包。
if have ip; then
  K "ip_primary" "$(RUN 5 ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  RUN 5 ip -brief addr 2>/dev/null | awk 'NR>0 && $1!="lo" && $2!="DOWN" {for(i=3;i<=NF;i++) if($i ~ /^[0-9a-fA-F.:]+\//) {sub(/\/.*/,"",$i); print $i}}' \
    | sort -u | head -10 \
    | while read -r a; do [ -n "$a" ] && L "ip_all" "$a"; done
fi

[ -r /etc/machine-id ] && K "machine_id" "$(head -c 64 /etc/machine-id 2>/dev/null)"
[ -r /proc/sys/kernel/random/boot_id ] && K "boot_id" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null
  K "os" "${PRETTY_NAME:-${NAME:-unknown}}"
  K "os_id" "${ID:-}"
  K "os_version" "${VERSION_ID:-}"
elif [ -r /etc/redhat-release ]; then
  K "os" "$(cat /etc/redhat-release 2>/dev/null)"
fi

K "kernel" "$(uname -sr 2>/dev/null)"
K "arch" "$(uname -m 2>/dev/null)"
have systemd-detect-virt && K "virt" "$(RUN 3 systemd-detect-virt 2>/dev/null || echo unknown)"

if have timedatectl; then
  K "timezone" "$(RUN 3 timedatectl show -p Timezone --value 2>/dev/null)"
  sync="$(RUN 3 timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  [ -n "$sync" ] && K "ntp_synced" "$sync"
fi

if [ -r /proc/uptime ]; then
  up_s="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
  K "uptime_s" "${up_s:-0}"
  [ -n "${up_s:-}" ] && K "boot_time" "$(date -d "@$(( $(date +%s) - up_s ))" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo unknown)"
fi

if [ -f /sys/fs/selinux/enforce ]; then
  K "selinux" "$([ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = "1" ] && echo enforcing || echo permissive)"
elif [ -d /etc/apparmor.d ]; then
  K "apparmor" "$([ -d /sys/kernel/security/apparmor ] && echo present || echo unknown)"
fi

[ -f /var/run/reboot-required ] && K "reboot_required" "yes"
if have needs-restarting && ! RUN 10 needs-restarting -r >/dev/null 2>&1; then
  K "reboot_required" "yes"
fi

# SSH 守护进程的单元名：Debian/Ubuntu 叫 ssh，RHEL 系叫 sshd。记下来省得以后猜。
if have systemctl; then
  ssh_unit="$(RUN 5 systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
              | awk '{print $1}' | grep -m1 -E '^(sshd?|openssh-server)\.service$')"
  [ -n "$ssh_unit" ] && K "ssh_unit" "$ssh_unit"
fi

fi  # identity

# ══════════════════════════════ hw ════════════════════════════════════
if want hw; then

if have lscpu; then
  lc="$(RUN 5 lscpu 2>/dev/null)"
  if [ -n "$lc" ]; then
    # lscpu 输出是 "Key  : Value"。键名随语言环境变，按英文键取；
    # 非英文环境取不到就留空，由下面的 /proc/cpuinfo 兜底。
    gv() { printf '%s\n' "$lc" | awk -F: -v k="$1" '$1 ~ k {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}'; }
    K "cpu_vendor"    "$(gv '^Vendor ID')"
    K "cpu_model"     "$(gv '^Model name')"
    K "cpu_sockets"   "$(gv '^Socket')"
    K "cpu_cores"     "$(gv '^Core')"
    K "cpu_threads"   "$(gv '^CPU\(s\)|^CPU\(s\):')"
    K "cpu_per_core"  "$(gv '^Thread')"
    K "cpu_mhz_max"   "$(gv '^CPU max MHz')"
    K "cpu_cache_l3"  "$(gv '^L3 cache')"
    K "cpu_numa"      "$(gv '^NUMA node')"
    K "cpu_flags_key" "$(printf '%s\n' "$lc" | grep -oE 'aes|avx2|avx512f|amx' | sort -u | tr '\n' ',' | sed 's/,$//')"
  fi
fi
# lscpu 缺席或非英文环境取不到时，用 /proc/cpuinfo 兜底（所有 Linux 都有）
if [ -z "$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2)" ] && [ -r /proc/cpuinfo ]; then
  K "cpu_model" "$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2-)"
fi
# 物理核数：lscpu 拿不到时数 /proc/cpuinfo 里唯一的 (physical id, core id) 组合
if [ ! -r /proc/cpuinfo ]; then :; fi

if [ -r /proc/meminfo ]; then
  K "mem_total_mb"  "$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))"
  K "swap_total_mb" "$(( $(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))"
fi

# 机型信息：/sys/class/dmi/id 通常不需要 root 就能读
for f in product_name product_vendor board_name board_vendor; do
  [ -r "/sys/class/dmi/id/$f" ] && K "dmi_$f" "$(head -c 100 "/sys/class/dmi/id/$f" 2>/dev/null)"
done

have lspci && K "gpu" "$(RUN 5 lspci 2>/dev/null | grep -iE 'vga|3d controller' | head -3 | tr '\n' ';' | sed 's/;$//')"

fi  # hw

# ══════════════════════════════ storage ═══════════════════════════════
if want storage; then

if have lsblk; then
  # -dn：不带 -f（-f 会对未挂载设备做 blkid 探测），-d 不递归分区树
  RUN 8 lsblk -dn -o NAME,SIZE,TYPE,ROTA,MODEL 2>/dev/null \
    | awk '$3=="disk"' | head -20 \
    | while read -r nm sz ty ro model; do
        L "disk_dev" "${nm}|${sz:-?}|${ty:-disk}|rota=${ro:-?}|${model:-}"
      done
fi

if have findmnt; then
  # findmnt 读 /proc/self/mountinfo，不实际探测设备，僵死 NFS 不会卡住
  RUN 8 findmnt -rno TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL 2>/dev/null | head -40 \
    | while read -r tgt src fst sz usd av; do
        case "$fst" in tmpfs|devtmpfs|proc|sysfs|cgroup*|squashfs|overlay|devpts|mqueue|hugetlbfs|tracefs|debugfs|bpf|securityfs|pstore|configfs|fusectl|ramfs) continue ;; esac
        case "$tgt" in /proc*|/sys*|/dev*|/run/*) continue ;; esac
        L "fs_mount" "${tgt}|${fst:-?}|${sz:-?}|${usd:-?}|${av:-?}|src=${src:-?}"
      done
elif have df; then
  # -l 只看本地文件系统：不带它，僵死的 NFS 挂载点会让 df 阻塞数分钟
  RUN 10 df -lPT -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | tail -n +2 | head -30 \
    | while read -r src fst sz usd av pct tgt; do
        L "fs_mount" "${tgt}|${fst}|${sz}|${usd}|${av}|pct=${pct}|src=${src}"
      done
fi

# 累计扇区数：存成基线，下次采集相减就能算出这段时间的 IO 活动量，零成本。
# 判读时要知道：
#   * 扇区恒按 512 字节算，与设备真实扇区大小无关
#   * LVM/mapper 主机上 dm-* 和底层 sd*/nvme* 会重复计数
#   * 这个基线只在 boot_id 不变时有效 —— 重启后计数器归零
if [ -r /proc/diskstats ]; then
  awk '$3 ~ /^(sd|nvme|vd|hd|dm-)[a-z0-9-]*$/ {print $3, $6, $10}' /proc/diskstats 2>/dev/null | head -25 \
    | while read -r dev rd wr; do
        L "diskstat" "${dev}|read=${rd}|written=${wr}"
      done
fi

fi  # storage

# ══════════════════════════════ network ═══════════════════════════════
if want network; then

if have ip; then
  RUN 5 ip -br addr 2>/dev/null | head -20 \
    | while IFS=' ' read -r iface state addrs; do
        L "net_iface" "${iface}|state=${state:-?}|${addrs:-}"
      done
  K "gateway" "$(RUN 5 ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
fi

if have ss; then
  # 监听端口（半稳定事实，适合入档案）。进程名要 root 才看得到，拿不到就留空。
  RUN 5 ss -lntH 2>/dev/null | awk '{print $1"|"$4}' | sort -u | head -40 \
    | while IFS='|' read -r proto local; do
        L "listen" "${proto}|${local}"
      done
fi

[ -r /etc/resolv.conf ] && K "dns" "$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"

fi  # network

# ══════════════════════════════ docker ════════════════════════════════
if want docker; then

if have docker; then
  K "docker" "present"
  K "docker_client_version" "$(RUN 5 docker version --format '{{.Client.Version}}' 2>/dev/null)"
  # daemon 不可达时区分"没装"和"装了没权限" —— 运维处理方向完全不同
  docker_info="$(RUN 10 docker info --format '{{.ServerVersion}}|{{.ContainersRunning}}|{{.Containers}}|{{.Images}}|{{.Driver}}|{{.DockerRootDir}}' 2>/dev/null)"
  srv="$(printf '%s' "$docker_info" | awk -F'|' '{print $1}')"
  if [ -n "$srv" ]; then
    running="$(printf '%s' "$docker_info" | awk -F'|' '{print $2}')"
    total="$(printf '%s' "$docker_info" | awk -F'|' '{print $3}')"
    imgs="$(printf '%s' "$docker_info" | awk -F'|' '{print $4}')"
    driver="$(printf '%s' "$docker_info" | awk -F'|' '{print $5}')"
    rootdir="$(printf '%s' "$docker_info" | awk -F'|' '{print $6}')"
    K "docker_server_version" "$srv"
    K "docker_containers" "running=${running:-?} total=${total:-?} images=${imgs:-?}"
    K "docker_driver" "${driver:-?}"
    K "docker_root_dir" "${rootdir:-?}"
    K "docker_accessible" "yes"

    # 全量容器清单（这台机器"有哪些 Docker 服务"的核心答案）
    RUN 10 docker ps -a --format '{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null \
      | head -60 \
      | while IFS='|' read -r nm img st status ports proj; do
          L "docker_container" "${nm}|${img:-?}|${st:-?}|${status:-?}|${ports:-}|${proj:-}"
        done

    # compose 项目（v2 插件才有；老机器没有就算了）
    if RUN 5 docker compose version >/dev/null 2>&1; then
      K "docker_compose" "v2"
      RUN 8 docker compose ls --format '{{.Name}}|{{.Status}}|{{.ConfigFiles}}' 2>/dev/null | head -20 \
        | while IFS='|' read -r nm st cfg; do
            L "docker_compose_project" "${nm}|${st:-?}|${cfg:-?}"
          done
    else
      K "docker_compose" "v1_or_absent"
    fi

    K "docker_volumes"  "$(RUN 5 docker volume ls -q 2>/dev/null | grep -c .)"
    K "docker_networks" "$(RUN 5 docker network ls -q 2>/dev/null | grep -c .)"
  else
    K "docker_accessible" "no"
    K "docker_accessible_reason" "daemon 不可达（非 root 用户通常缺 docker 组权限，或 daemon 未运行）"
  fi
else
  K "docker" "absent"
fi

fi  # docker

# ══════════════════════════════ services ══════════════════════════════
if want services; then

if have systemctl; then
  RUN 8 systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' | head -80 \
    | while read -r u; do L "unit_running" "$u"; done

  RUN 8 systemctl --failed --no-legend --no-pager 2>/dev/null | head -20 \
    | while read -r u load act sub desc; do
        [ -n "$u" ] && L "unit_failed" "${u}|${act:-?}/${sub:-?}"
      done

  RUN 8 systemctl list-timers --all --no-legend --no-pager 2>/dev/null | head -20 \
    | awk '{print $NF"|"$(NF-4)}' | head -20 \
    | while IFS='|' read -r unit next; do
        [ -n "$unit" ] && L "timer" "${unit}|next=${next}"
      done
fi

# cron 入口数量（只数文件，不读内容）
n=0
for d in /var/spool/cron /var/spool/cron/crontabs /etc/cron.d; do
  [ -d "$d" ] && n=$(( n + $(RUN 3 ls -1 "$d" 2>/dev/null | grep -c .) ))
done
K "cron_entries" "$n"

if have apt-get; then   K "pkg_manager" "apt"
elif have dnf; then     K "pkg_manager" "dnf"
elif have yum; then     K "pkg_manager" "yum"
elif have zypper; then  K "pkg_manager" "zypper"
elif have pacman; then  K "pkg_manager" "pacman"
fi

fi  # services

# ══════════════════════════════ runtimes ══════════════════════════════
if want runtimes; then

have python3 && K "python3" "$(RUN 5 python3 -V 2>&1 | head -1)"
have node    && K "node"    "$(RUN 5 node -v 2>&1 | head -1)"
have php     && K "php"     "$(RUN 5 php -v 2>&1 | head -1)"
have java    && K "java"    "$(RUN 8 java -version 2>&1 | head -1)"
have go      && K "go"      "$(RUN 5 go version 2>&1 | head -1)"
have ruby    && K "ruby"    "$(RUN 5 ruby -v 2>&1 | head -1)"
have nginx   && K "nginx"   "$(RUN 5 nginx -v 2>&1 | head -1)"
have mysqld  && K "mysqld"  "$(RUN 5 mysqld --version 2>&1 | head -1)"
have redis-server && K "redis" "$(RUN 5 redis-server --version 2>&1 | head -1)"
have psql    && K "postgres_client" "$(RUN 5 psql --version 2>&1 | head -1)"

fi  # runtimes

# ══════════════════════════════ security ══════════════════════════════
if want security; then

# 防火墙：非 root 时显式记 unknown —— 绝不把"看不了"写成"没有规则"
fw_done=0
if [ "$IS_ROOT" = "1" ] && have ufw; then
  st="$(RUN 5 ufw status 2>/dev/null | head -1)"
  case "$st" in
    *active*)   K "firewall" "ufw=active rules=$(RUN 5 ufw status numbered 2>/dev/null | grep -c '\[')"; fw_done=1 ;;
    *inactive*) K "firewall" "ufw=inactive"; fw_done=1 ;;
  esac
elif [ "$IS_ROOT" = "1" ] && have firewall-cmd; then
  if RUN 5 firewall-cmd --state >/dev/null 2>&1; then
    K "firewall" "firewalld=active"
  else
    K "firewall" "firewalld=inactive"
  fi
  fw_done=1
fi
if [ "$fw_done" = "0" ]; then
  if have ufw || have firewall-cmd || have iptables || have nft; then
    K "firewall" "unknown reason=needs_root（检测到防火墙工具但当前用户读不到状态）"
  else
    K "firewall" "absent"
  fi
fi

# sshd 生效配置：root 用 sshd -T（才是真正生效的），否则退回读配置文件（可能不准）
if [ "$IS_ROOT" = "1" ] && have sshd && RUN 5 sshd -T >/dev/null 2>&1; then
  K "ssh_port"              "$(RUN 5 sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
  K "ssh_permit_root_login" "$(RUN 5 sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2; exit}')"
  K "ssh_password_auth"     "$(RUN 5 sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2; exit}')"
  K "ssh_pubkey_auth"       "$(RUN 5 sshd -T 2>/dev/null | awk '$1=="pubkeyauthentication"{print $2; exit}')"
  K "ssh_config_source"     "sshd -T"
elif [ -r /etc/ssh/sshd_config ]; then
  # Include 目录里的文件也可能是最终生效值；这里取"最后一次出现"作为近似
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ -r "$f" ] || continue
    v="$(grep -iE '^[[:space:]]*Port[[:space:]]' "$f" 2>/dev/null | tail -1 | awk '{print $2}')"
    [ -n "$v" ] && K "ssh_port" "$v"
    v="$(grep -iE '^[[:space:]]*PermitRootLogin[[:space:]]' "$f" 2>/dev/null | tail -1 | awk '{print $2}')"
    [ -n "$v" ] && K "ssh_permit_root_login" "$v"
    v="$(grep -iE '^[[:space:]]*PasswordAuthentication[[:space:]]' "$f" 2>/dev/null | tail -1 | awk '{print $2}')"
    [ -n "$v" ] && K "ssh_password_auth" "$v"
    v="$(grep -iE '^[[:space:]]*PubkeyAuthentication[[:space:]]' "$f" 2>/dev/null | tail -1 | awk '{print $2}')"
    [ -n "$v" ] && K "ssh_pubkey_auth" "$v"
  done
  K "ssh_config_source" "config_files（非 root，可能与生效值有出入）"
fi

# 有登录 shell 的账号
{
  if have getent; then RUN 5 getent passwd 2>/dev/null; fi
  cat /etc/passwd 2>/dev/null
} | awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ {print $1"|uid="$3"|"$7}' | head -20 \
  | while IFS='|' read -r u uid sh; do L "user_shell" "${u}|${uid}|${sh}"; done

fi  # security

# ---------- 完整性哨兵 ----------
# 必须是最后一行。采集被中断（ssh 超时、连接断开）时不会有这一行，
# profile_store.sh 据此拒绝把半份结果写入档案。
K "profile_complete" "1"
exit 0
