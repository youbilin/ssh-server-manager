#!/usr/bin/env bash
# risk.sh - 远程命令风险分级（由 ssh_exec.sh source）
#
# 为什么不用一张大正则表：裸 substring 匹配会把“grep reboot /var/log/x”判成重启，
# 又会漏掉“rm --recursive --force”。这里先按引号外的 ; | && || 切段，再去掉
# sudo/env/timeout 等前缀，最后只看每段真正执行的命令词和写入目标。
#
# 分级结果写在全局变量 RISK_TIER（0/1/2）与 RISK_REASON。
# 这是 guardrail，不是 sandbox：解释器内联代码（python -c ...）无法可靠静态判定。

# RISK_TIER / RISK_REASON 由 source 本文件的 ssh_exec.sh 读取。
# shellcheck disable=SC2034
RISK_TIER=0
RISK_REASON="未命中危险模式，按只读处理"
_SSHMGR_RISK_DEPTH="${_SSHMGR_RISK_DEPTH:-0}"

_sshmgr_risk_set() {
  [ "${1:-0}" -gt "$RISK_TIER" ] || return 0
  RISK_TIER="$1"
  RISK_REASON="$2"
}

_sshmgr_risk_trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# 写入这些路径默认按高危处理：改错直接锁死登录或破坏启动。
_sshmgr_risk_critical_path() {
  case "$1" in
    ''|-) return 1 ;;
    sshd_config|*/sshd_config|*sshd_config.bak*) return 0 ;;
    sudoers|*/sudoers|*/sudoers.d/*) return 0 ;;
    fstab|*/fstab) return 0 ;;
    /etc/ssh/ssh_config|*/ssh_config) return 0 ;;
    /dev/sd*|/dev/nvme*|/dev/vd*|/dev/hd*|/dev/mapper/*|/dev/dm-*) return 0 ;;
    /boot|/boot/*) return 0 ;;
    /etc/lvm/*|/etc/mdadm.conf) return 0 ;;
  esac
  return 1
}

_sshmgr_risk_etc_path() {
  case "$1" in
    /etc|/etc/*) return 0 ;;
  esac
  return 1
}

# rsync/scp 的远端目标形如 host:/path；去掉 host 部分再判断。
_sshmgr_risk_strip_remote() {
  case "$1" in
    \[*\]:*) printf '%s' "${1#*]:}" ;;
    *:/*)    printf '%s' "${1#*:}" ;;
    *)       printf '%s' "$1" ;;
  esac
}

_sshmgr_risk_has_simulate() {
  local a
  for a in "$@"; do
    case "$a" in
      -s|--simulate|--dry-run|--just-print|-n) return 0 ;;
    esac
  done
  return 1
}

# 扫描 > / >> 重定向目标。返回 0 表示命中了 critical 目标。
_sshmgr_risk_scan_redirects() {
  local seg="$1" tok path
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    path="${tok#>>}"
    path="${path#>}"
    path="$(_sshmgr_risk_trim "$path")"
    [ -n "$path" ] || continue
    if _sshmgr_risk_critical_path "$path"; then
      _sshmgr_risk_set 2 "命中高危模式: 写入 $path"
      return 0
    fi
    if _sshmgr_risk_etc_path "$path"; then
      _sshmgr_risk_set 1 "命中变更模式: 写入 $path"
    fi
  done <<EOF
$(printf '%s' "$seg" | grep -Eo '>>?[[:space:]]*[^[:space:];&|]+' 2>/dev/null)
EOF
  return 1
}

# 取最后一个非选项参数作为 cp/mv/install/rsync/scp 的目标。
_sshmgr_risk_last_arg() {
  local a last=""
  for a in "$@"; do
    case "$a" in
      -*) ;;
      *) last="$a" ;;
    esac
  done
  printf '%s' "$last"
}

# 在 cp/install 的 -t DIR 形式中，目标在 -t 后面。
_sshmgr_risk_target_dir() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "-t" ] || [ "$prev" = "--target-directory" ]; then
      printf '%s' "$a"
      return 0
    fi
    case "$a" in
      --target-directory=*) printf '%s' "${a#*=}"; return 0 ;;
    esac
    prev="$a"
  done
  return 1
}

_sshmgr_risk_check_write_target() {
  local verb="$1"; shift
  local dest=""
  case "$verb" in
    cp|install|ln)
      dest="$(_sshmgr_risk_target_dir "$@")" || dest="$(_sshmgr_risk_last_arg "$@")" ;;
    mv|rsync|scp|sftp)
      dest="$(_sshmgr_risk_last_arg "$@")" ;;
  esac
  dest="$(_sshmgr_risk_strip_remote "$dest")"
  [ -n "$dest" ] || return 1
  if _sshmgr_risk_critical_path "$dest"; then
    _sshmgr_risk_set 2 "命中高危模式: $verb 写入 $dest"
    return 0
  fi
  if _sshmgr_risk_etc_path "$dest"; then
    _sshmgr_risk_set 1 "命中变更模式: $verb 写入 $dest"
  fi
  return 1
}

# 引号感知的分词：保留引号本身，交给调用方决定是否剥掉。
# 不能直接 W=($seg)，也不建议 eval —— 前者会做路径展开，后者会执行命令替换。
_sshmgr_risk_split_words() {
  local s="$1" i ch cur="" quote="" started=0
  W=()
  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    case "$quote" in
      "'")
        cur="$cur$ch"
        [ "$ch" = "'" ] && quote=""
        continue
        ;;
      '"')
        cur="$cur$ch"
        if [ "$ch" = '\' ]; then
          i=$((i+1)); cur="$cur${s:i:1}"; continue
        fi
        [ "$ch" = '"' ] && quote=""
        continue
        ;;
    esac
    case "$ch" in
      "'"|'"') quote="$ch"; cur="$cur$ch"; started=1 ;;
      '\') cur="$cur$ch"; i=$((i+1)); cur="$cur${s:i:1}"; started=1 ;;
      ' '|$'\t')
        if [ "$started" -eq 1 ]; then W+=("$cur"); cur=""; started=0; fi
        ;;
      *) cur="$cur$ch"; started=1 ;;
    esac
  done
  if [ "$started" -eq 1 ]; then W+=("$cur"); fi
}

_sshmgr_risk_scan_segment() {
  local seg="$1"
  seg="$(_sshmgr_risk_trim "$seg")"
  [ -n "$seg" ] || return 0

  # 提前命中高危后仍继续扫描也没有意义；但 tier1 可能被后续段落升级。
  if [ "$RISK_TIER" -eq 2 ]; then return 0; fi

  _sshmgr_risk_scan_redirects "$seg" || true

  # 前缀剥除：sudo/env/timeout/nice/ionice/command/nohup/setsid/time/stdbuf
  W=()
  _sshmgr_risk_split_words "$seg"
  [ "${#W[@]}" -gt 0 ] || return 0
  set -- "${W[@]}"

  while [ $# -gt 0 ]; do
    case "$1" in
      sudo)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            --) shift; break ;;
            -u|-g|-p|-h|-U|-C|-T|-r|-t) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done ;;
      env)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -u|--unset) shift 2 ;;
            -*) shift ;;
            [A-Za-z_][A-Za-z0-9_]*=*) shift ;;
            *) break ;;
          esac
        done ;;
      timeout)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -s|--signal|-k|--kill-after) shift 2 ;;
            -*) shift ;;
            *[0-9]*) shift; break ;;
            *) break ;;
          esac
        done ;;
      nice)
        shift
        [ "${1:-}" = "-n" ] && shift 2 || true ;;
      ionice)
        shift
        [ "${1:-}" = "-c" ] && shift 2 || true ;;
      command|builtin|exec|nohup|setsid|time|stdbuf)
        shift ;;
      [A-Za-z_][A-Za-z0-9_]*=*)
        shift ;;
      *)
        break ;;
    esac
  done
  [ $# -gt 0 ] || return 0

  local verb="${1##*/}"
  shift

  # xargs：把后面的命令当作真正要执行的命令再分一次。
  if [ "$verb" = "xargs" ]; then
    while [ $# -gt 0 ]; do
      case "$1" in
        -I|-n|-P|-s|-L|-E) shift 2 ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    if [ $# -gt 0 ] && [ "$_SSHMGR_RISK_DEPTH" -lt 2 ]; then
      _SSHMGR_RISK_DEPTH=$((_SSHMGR_RISK_DEPTH + 1))
      _sshmgr_risk_scan_segment "$*"
      _SSHMGR_RISK_DEPTH=$((_SSHMGR_RISK_DEPTH - 1))
    fi
    return 0
  fi

  # bash/sh -c / eval：递归检查内联命令。
  case "$verb" in
    bash|sh|dash|zsh|ksh)
      local a inner="" seen_c=0
      for a in "$@"; do
        if [ "$seen_c" -eq 1 ]; then inner="$a"; break; fi
        [ "$a" = "-c" ] && seen_c=1
      done
      # 分词器保留引号；递归前剥掉最外层引号。
      inner="${inner#\"}"; inner="${inner%\"}"
      inner="${inner#\'}"; inner="${inner%\'}"
      if [ -n "$inner" ] && [ "$_SSHMGR_RISK_DEPTH" -lt 2 ]; then
        _SSHMGR_RISK_DEPTH=$((_SSHMGR_RISK_DEPTH + 1))
        _sshmgr_risk_scan_command_string "$inner"
        _SSHMGR_RISK_DEPTH=$((_SSHMGR_RISK_DEPTH - 1))
      fi
      return 0 ;;
    eval)
      if [ "$_SSHMGR_RISK_DEPTH" -lt 2 ]; then
        _SSHMGR_RISK_DEPTH=$((_SSHMGR_RISK_DEPTH + 1))
        _sshmgr_risk_scan_command_string "$*"
        _SSHMGR_RISK_DEPTH=$((_SSHMGR_RISK_DEPTH - 1))
      fi
      return 0 ;;
  esac

  case "$verb" in
    rm)
      local rec=0
      for a in "$@"; do
        case "$a" in
          --recursive|--recursive=*|-*[rR]*) rec=1 ;;
        esac
      done
      if [ "$rec" -eq 1 ]; then
        _sshmgr_risk_set 2 "命中高危模式: 递归删除 (rm -r)"
      else
        _sshmgr_risk_set 1 "命中变更模式: 删除文件 (rm)"
      fi
      return 0 ;;
    shred)
      _sshmgr_risk_set 2 "命中高危模式: 安全擦除 (shred)"
      return 0 ;;
    dd)
      _sshmgr_risk_set 2 "命中高危模式: 磁盘/原始读写 (dd)"
      return 0 ;;
    blkdiscard|wipefs|mkswap|mkfs|mkfs.*)
      _sshmgr_risk_set 2 "命中高危模式: 文件系统/块设备操作 ($verb)"
      return 0 ;;
    fdisk|sfdisk|parted|gdisk|sgdisk)
      _sshmgr_risk_set 2 "命中高危模式: 分区操作 ($verb)"
      return 0 ;;
    lvremove|vgremove|pvremove)
      _sshmgr_risk_set 2 "命中高危模式: LVM 删除 ($verb)"
      return 0 ;;
    cryptsetup)
      case " $* " in
        *luksFormat*|*luksErase*|*erase*) _sshmgr_risk_set 2 "命中高危模式: 加密卷操作" ;;
        *) _sshmgr_risk_set 1 "命中变更模式: cryptsetup" ;;
      esac
      return 0 ;;
    mdadm)
      case " $* " in
        *--create*|*--stop*|*--fail*|*--remove*|*-C*|*-S*) _sshmgr_risk_set 2 "命中高危模式: RAID 管理" ;;
        *) _sshmgr_risk_set 1 "命中变更模式: RAID 查询/管理" ;;
      esac
      return 0 ;;
    zfs|zpool)
      case " $* " in
        *destroy*|*create*|*add*|*remove*) _sshmgr_risk_set 2 "命中高危模式: ZFS 卷池操作" ;;
        *) _sshmgr_risk_set 1 "命中变更模式: ZFS 操作" ;;
      esac
      return 0 ;;
    shutdown|reboot|halt|poweroff|telinit)
      _sshmgr_risk_set 2 "命中高危模式: 关机/重启 ($verb)"
      return 0 ;;
    init)
      case "${1:-}" in
        0|6) _sshmgr_risk_set 2 "命中高危模式: 切换运行级别 ($1)" ;;
        *)   _sshmgr_risk_set 1 "命中变更模式: 切换运行级别" ;;
      esac
      return 0 ;;
    systemctl)
      local action="" unit="" seen=0
      for a in "$@"; do
        case "$a" in
          -*) continue ;;
          *) if [ "$seen" -eq 0 ]; then action="$a"; seen=1; else unit="$a"; fi ;;
        esac
      done
      case "$action" in
        stop|disable|mask)
          case "$unit" in
            ssh|sshd|ssh.service|sshd.service|openssh*)
              _sshmgr_risk_set 2 "命中高危模式: 停用/禁用 SSH ($action $unit)" ;;
            *) _sshmgr_risk_set 1 "命中变更模式: systemctl $action" ;;
          esac ;;
        isolate)
          _sshmgr_risk_set 2 "命中高危模式: systemctl isolate（切换 target）" ;;
        start|restart|reload|enable|unmask|daemon-reload|set-default|reset-failed)
          _sshmgr_risk_set 1 "命中变更模式: systemctl $action" ;;
        *) return 0 ;;
      esac
      return 0 ;;
    service)
      local svc="${1:-}" act="${2:-}"
      case "$svc:$act" in
        ssh:stop|sshd:stop) _sshmgr_risk_set 2 "命中高危模式: 停止 SSH 服务" ;;
        *:start|*:stop|*:restart|*:reload) _sshmgr_risk_set 1 "命中变更模式: service $act" ;;
      esac
      return 0 ;;
    nginx|apachectl)
      case " $* " in
        *"-s reload"*|*"-s stop"*|*"-s quit"*|*"-k restart"*|*"-k stop"*|*"-k graceful"*)
          _sshmgr_risk_set 1 "命中变更模式: Web 服务重载/停止" ;;
      esac
      return 0 ;;
    kill)
      local sig="" tgt="" has0=0
      for a in "$@"; do
        case "$a" in
          -9|-KILL|-SIGKILL) sig=9 ;;
          -0|-s*0) has0=1 ;;
          -*) ;;
          *) tgt="$a" ;;
        esac
      done
      if [ "$sig" = "9" ] && { [ "$tgt" = "1" ] || [ "$tgt" = "-1" ]; }; then
        _sshmgr_risk_set 2 "命中高危模式: SIGKILL 系统进程"
      elif [ "$has0" -eq 1 ] && [ -z "$sig" ]; then
        return 0
      else
        _sshmgr_risk_set 1 "命中变更模式: kill"
      fi
      return 0 ;;
    killall5)
      _sshmgr_risk_set 2 "命中高危模式: killall5"
      return 0 ;;
    pkill|killall)
      _sshmgr_risk_set 1 "命中变更模式: $verb"
      return 0 ;;
    crontab)
      case " $* " in
        *-r*) _sshmgr_risk_set 2 "命中高危模式: crontab -r（清空定时任务）" ;;
        *-l*) return 0 ;;
        *) _sshmgr_risk_set 1 "命中变更模式: 修改 crontab" ;;
      esac
      return 0 ;;
    chmod)
      local recursive=0 all=0
      for a in "$@"; do
        case "$a" in
          --recursive|-R|-*R*) recursive=1 ;;
          777|0777) all=1 ;;
        esac
      done
      if [ "$recursive" -eq 1 ] && [ "$all" -eq 1 ]; then
        _sshmgr_risk_set 2 "命中高危模式: chmod -R 777"
      else
        _sshmgr_risk_set 1 "命中变更模式: chmod"
      fi
      return 0 ;;
    chown)
      local recursive=0 dest=""
      for a in "$@"; do
        case "$a" in --recursive|-R|-*R*) recursive=1 ;; -*) ;; *) dest="$a" ;; esac
      done
      if [ "$recursive" -eq 1 ]; then
        case "$dest" in
          /etc|/etc/*|/var|/var/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/boot|/boot/*)
            _sshmgr_risk_set 2 "命中高危模式: chown -R 系统目录 ($dest)" ;;
          *) _sshmgr_risk_set 1 "命中变更模式: chown -R" ;;
        esac
      else
        _sshmgr_risk_set 1 "命中变更模式: chown"
      fi
      return 0 ;;
    chgrp|chattr|setfacl)
      _sshmgr_risk_set 1 "命中变更模式: $verb"
      return 0 ;;
    userdel)
      _sshmgr_risk_set 2 "命中高危模式: 删除用户 (userdel)"
      return 0 ;;
    useradd|usermod|groupadd|groupmod|gpasswd|passwd|chpasswd|ssh-copy-id|adduser|deluser)
      _sshmgr_risk_set 1 "命中变更模式: 账号/权限变更 ($verb)"
      return 0 ;;
    visudo)
      case " $* " in
        *-c*) return 0 ;;
        *) _sshmgr_risk_set 1 "命中变更模式: 编辑 sudo 规则 (visudo)" ;;
      esac
      return 0 ;;
    mv)
      if _sshmgr_risk_check_write_target mv "$@"; then return 0; fi
      local dest; dest="$(_sshmgr_risk_strip_remote "$(_sshmgr_risk_last_arg "$@")")"
      case "$dest" in
        /etc/ssh|/etc/ssh/*|/etc/nginx|/etc/nginx/*|/etc/sysconfig|/etc/sysconfig/*)
          _sshmgr_risk_set 2 "命中高危模式: 覆盖系统配置目录 ($dest)" ;;
        *) _sshmgr_risk_set 1 "命中变更模式: mv" ;;
      esac
      return 0 ;;
    cp|install|ln)
      _sshmgr_risk_check_write_target "$verb" "$@" || true
      _sshmgr_risk_set 1 "命中变更模式: $verb"
      return 0 ;;
    rsync)
      if _sshmgr_risk_has_simulate "$@"; then return 0; fi
      _sshmgr_risk_check_write_target rsync "$@" || true
      _sshmgr_risk_set 1 "命中变更模式: rsync"
      return 0 ;;
    scp|sftp)
      _sshmgr_risk_check_write_target "$verb" "$@" || true
      _sshmgr_risk_set 1 "命中变更模式: $verb"
      return 0 ;;
    tee)
      local t
      for t in "$@"; do
        case "$t" in -*) continue ;; esac
        t="$(_sshmgr_risk_strip_remote "$t")"
        if _sshmgr_risk_critical_path "$t"; then
          _sshmgr_risk_set 2 "命中高危模式: tee 写入 $t"
          return 0
        fi
        _sshmgr_risk_etc_path "$t" && _sshmgr_risk_set 1 "命中变更模式: tee 写入 $t"
      done
      _sshmgr_risk_set 1 "命中变更模式: tee"
      return 0 ;;
    truncate)
      local t=""; t="$(_sshmgr_risk_last_arg "$@")"
      if _sshmgr_risk_critical_path "$t"; then
        _sshmgr_risk_set 2 "命中高危模式: truncate $t"
      else
        _sshmgr_risk_set 1 "命中变更模式: truncate"
      fi
      return 0 ;;
    sed)
      local inplace=0 a
      for a in "$@"; do
        case "$a" in -i|--in-place|-i.*) inplace=1 ;; esac
      done
      [ "$inplace" -eq 1 ] || return 0
      for a in "$@"; do
        if _sshmgr_risk_critical_path "$a"; then
          _sshmgr_risk_set 2 "命中高危模式: 就地修改 $a"
          return 0
        fi
      done
      _sshmgr_risk_set 1 "命中变更模式: sed -i"
      return 0 ;;
    find)
      case " $* " in
        *-delete*) _sshmgr_risk_set 1 "命中变更模式: find -delete"; return 0 ;;
      esac
      case " $* " in
        *-execdir*rm*|*-exec*rm*)
          case " $* " in
            *-rf*|*"--recursive"*) _sshmgr_risk_set 2 "命中高危模式: find -exec rm -r" ;;
            *) _sshmgr_risk_set 1 "命中变更模式: find -exec rm" ;;
          esac ;;
      esac
      return 0 ;;
    mount|umount|swapon|swapoff|sysctl|update-alternatives|hostnamectl|timedatectl|localectl|update-grub|grub-install|mkinitramfs|dracut)
      _sshmgr_risk_set 1 "命中变更模式: $verb"
      return 0 ;;
    iptables|ip6tables)
      case " $* " in
        *" -F "*|*" --flush "*|*" -X "*|*" --delete-chain "*)
          _sshmgr_risk_set 2 "命中高危模式: 清空防火墙规则" ;;
        *" -P "*" DROP "*|*" -P "*" REJECT "*)
          _sshmgr_risk_set 2 "命中高危模式: 设置默认 DROP 策略" ;;
        *)
          case " $* " in
            *" -S"*|*"--list"*|*" -L"*) return 0 ;;
            *) _sshmgr_risk_set 1 "命中变更模式: iptables" ;;
          esac ;;
      esac
      return 0 ;;
    nft)
      case " $* " in
        *" flush ruleset"*|*" flush "*|*" delete "*|*" add "*|*" insert "*|*" replace "*)
          case " $* " in
            *" flush ruleset"*) _sshmgr_risk_set 2 "命中高危模式: nft flush ruleset" ;;
            *) _sshmgr_risk_set 1 "命中变更模式: nft" ;;
          esac ;;
        *) return 0 ;;
      esac
      return 0 ;;
    ufw)
      case " $* " in
        *" disable"*|*" reset"*) _sshmgr_risk_set 2 "命中高危模式: ufw disable/reset" ;;
        *" status"*) return 0 ;;
        *) _sshmgr_risk_set 1 "命中变更模式: ufw" ;;
      esac
      return 0 ;;
    firewall-cmd)
      case " $* " in
        *"--panic-on"*|*"--set-default-zone"*) _sshmgr_risk_set 2 "命中高危模式: firewalld 默认策略" ;;
        *"--state"*|*"--list-all"*|*"--get"*) return 0 ;;
        *) _sshmgr_risk_set 1 "命中变更模式: firewalld" ;;
      esac
      return 0 ;;
    git)
      local action="" a skip=0
      for a in "$@"; do
        if [ "$skip" -eq 1 ]; then skip=0; continue; fi
        case "$a" in
          -C|-c|--git-dir|--work-tree) skip=1 ;;
          -*) ;;
          *) action="$a"; break ;;
        esac
      done
      case "$action" in
        pull|reset|checkout|clean|merge|rebase|stash|clone|push|submodule|apply|am)
          _sshmgr_risk_set 1 "命中变更模式: git $action" ;;
      esac
      return 0 ;;
    apt|apt-get)
      local action="" a skip=0
      for a in "$@"; do
        if [ "$skip" -eq 1 ]; then skip=0; continue; fi
        case "$a" in
          -o|-c|-t|--option|--config-file|--target-release) skip=1 ;;
          -*) ;;
          *) action="$a"; break ;;
        esac
      done
      case "$action" in
        install|remove|purge|upgrade|dist-upgrade|full-upgrade|autoremove|autopurge)
          _sshmgr_risk_has_simulate "$@" && return 0
          _sshmgr_risk_set 1 "命中变更模式: apt $action" ;;
        update)
          _sshmgr_risk_set 1 "命中变更模式: apt update" ;;
      esac
      return 0 ;;
    dpkg)
      case " $* " in
        *" -i"*|*" --install"*|*" -r"*|*" --remove"*|*" -P"*|*" --purge"*)
          _sshmgr_risk_set 1 "命中变更模式: dpkg" ;;
      esac
      return 0 ;;
    yum|dnf|zypper)
      local action="" a skip=0
      for a in "$@"; do
        if [ "$skip" -eq 1 ]; then skip=0; continue; fi
        case "$a" in
          -c|--config|--setopt|-x|--exclude|--enablerepo|--disablerepo) skip=1 ;;
          -*) ;;
          *) action="$a"; break ;;
        esac
      done
      case "$action" in
        install|remove|erase|update|upgrade|autoremove|groupinstall|groupremove|dist-upgrade|refresh)
          _sshmgr_risk_set 1 "命中变更模式: $verb $action" ;;
      esac
      return 0 ;;
    rpm)
      case " $* " in
        *" -i"*|*" -U"*|*" --install"*|*" --upgrade"*|*" -e"*|*" --erase"*)
          _sshmgr_risk_set 1 "命中变更模式: rpm" ;;
      esac
      return 0 ;;
    pacman)
      case " $* " in
        *"-S"*|*"-R"*|*"-U"*) _sshmgr_risk_set 1 "命中变更模式: pacman" ;;
      esac
      return 0 ;;
    apk)
      case " $* " in
        *" add "*|*" del "*|*" upgrade "*|*" update "*) _sshmgr_risk_set 1 "命中变更模式: apk" ;;
      esac
      return 0 ;;
    snap)
      case " $* " in
        *" install "*|*" remove "*|*" refresh "*) _sshmgr_risk_set 1 "命中变更模式: snap" ;;
      esac
      return 0 ;;
    pip|pip3|pip[0-9])
      case " $* " in
        *" install "*|*" uninstall "*) _sshmgr_risk_set 1 "命中变更模式: pip" ;;
      esac
      return 0 ;;
    npm)
      case " $* " in
        *" install "*|*" i "*|*" uninstall "*|*" update "*|*" ci "*) _sshmgr_risk_set 1 "命中变更模式: npm" ;;
      esac
      return 0 ;;
    yarn|pnpm)
      case " $* " in
        *" add "*|*" install "*|*" remove "*|*" global "*) _sshmgr_risk_set 1 "命中变更模式: $verb" ;;
      esac
      return 0 ;;
    docker)
      local sub="" act=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --host|-H|--context|--config|-c) shift 2 ;;
          -*) shift ;;
          *) sub="$1"; shift; break ;;
        esac
      done
      case "$sub" in
        stop|start|restart|rm|rmi|kill|prune|tag|save|load|import|export)
          _sshmgr_risk_set 1 "命中变更模式: docker $sub" ;;
        compose)
          while [ $# -gt 0 ]; do
            case "$1" in
              up|down|restart|stop|rm|build|run|create|start) act="$1"; break ;;
              -*) shift ;;
              *) break ;;
            esac
          done
          [ -n "$act" ] && _sshmgr_risk_set 1 "命中变更模式: docker compose $act" ;;
        system)
          case " $* " in *" prune "*) _sshmgr_risk_set 1 "命中变更模式: docker system prune" ;; esac ;;
        volume)
          case " $* " in *" rm "*|*" prune "*) _sshmgr_risk_set 1 "命中变更模式: docker volume" ;; esac ;;
        network)
          case " $* " in *" rm "*|*" prune "*) _sshmgr_risk_set 1 "命中变更模式: docker network" ;; esac ;;
        builder)
          case " $* " in *" prune "*) _sshmgr_risk_set 1 "命中变更模式: docker builder prune" ;; esac ;;
      esac
      return 0 ;;
    mysql|mariadb|psql|sqlite3|mongo|mongosh|redis-cli|mysqladmin)
      if printf '%s\n' "$*" | grep -Eiq '(^|[^[:alnum:]_])(DROP[[:space:]]+(DATABASE|TABLE)|TRUNCATE[[:space:]]+TABLE)([^[:alnum:]_]|$)'; then
        _sshmgr_risk_set 2 "命中高危模式: 数据库 DROP/TRUNCATE"
      fi
      return 0 ;;
    sysbench|stress-ng|stress|memtester|fio|iperf|iperf3|bonnie++|unixbench|phoronix-test-suite|iozone|dbench|tiobench)
      _sshmgr_risk_set 2 "命中高危模式: 压测/基准类命令 ($verb)"
      return 0 ;;
    hdparm)
      _sshmgr_risk_set 2 "命中高危模式: 磁盘性能/参数测试 (hdparm)"
      return 0 ;;
    openssl)
      case " $* " in
        *" speed "*) _sshmgr_risk_set 2 "命中高危模式: openssl speed" ;;
      esac
      return 0 ;;
    setenforce)
      case "${1:-}" in
        0) _sshmgr_risk_set 1 "命中变更模式: 关闭 SELinux enforcing (setenforce 0)" ;;
      esac
      return 0 ;;
  esac

  return 0
}

# 按引号外的 ; | && || 换行切段。引号内的分隔符不切。
_sshmgr_risk_scan_command_string() {
  local s="$1" i ch cur="" quote=""
  local n="${#s}"
  for ((i=0; i<n; i++)); do
    ch="${s:i:1}"
    case "$quote" in
      "'")
        cur="$cur$ch"
        [ "$ch" = "'" ] && quote=""
        ;;
      '"')
        cur="$cur$ch"
        if [ "$ch" = '\' ]; then
          i=$((i+1)); cur="$cur${s:i:1}"; continue
        fi
        [ "$ch" = '"' ] && quote=""
        ;;
      *)
        case "$ch" in
          "'"|'"') quote="$ch"; cur="$cur$ch" ;;
          '\') cur="$cur$ch"; i=$((i+1)); cur="$cur${s:i:1}" ;;
          ';'|'|'|'&') _sshmgr_risk_scan_segment "$cur"; cur="" ;;
          $'\n') _sshmgr_risk_scan_segment "$cur"; cur="" ;;
          *) cur="$cur$ch" ;;
        esac
        ;;
    esac
  done
  _sshmgr_risk_scan_segment "$cur"
}

sshmgr_classify() {
  local raw="$1"
  RISK_TIER=0
  RISK_REASON="未命中危险模式，按只读处理"
  _SSHMGR_RISK_DEPTH=0

  # fork bomb
  if printf '%s' "$raw" | grep -Eiq ':\(\)[[:space:]]*\{'; then
    _sshmgr_risk_set 2 "命中高危模式: fork bomb"
    return 0
  fi

  # 下载后直接执行
  if printf '%s' "$raw" | grep -Eiq '(^|[;&[:space:]])(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da|k)?sh([[:space:]]|$)|(curl|wget)[^|]*\|[[:space:]]*(python[0-9.]*|perl|ruby|node)([[:space:]]|$)'; then
    _sshmgr_risk_set 2 "命中高危模式: 下载内容直接交给解释器执行"
    return 0
  fi

  _sshmgr_risk_scan_command_string "$raw"
}
