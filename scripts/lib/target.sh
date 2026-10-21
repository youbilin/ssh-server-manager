#!/usr/bin/env bash
# target.sh - 用 `ssh -G` 解析目标的真实 hostname/port/user/jump/known_hosts
#
# 为什么需要它：-H web1 可能是 ~/.ssh/config 里的别名，真实主机名和端口只有 ssh
# 自己知道。--accept-host-key、known_hosts 指纹查询、档案文件名都需要这些真实值；
# 直接拿别名去 ssh-keyscan 或 ssh-keygen -F 会悄悄查错位置。
#
# 本函数不建立网络连接（ssh -G 只解析配置），结果写入 SSHMGR_TARGET_* 全局变量。
# 这些变量由 source 本文件的脚本读取，shellcheck 单文件分析看不到。
# shellcheck disable=SC2034,SC2088

SSHMGR_TARGET_HOST=""
SSHMGR_TARGET_PORT=""
SSHMGR_TARGET_USER=""
SSHMGR_TARGET_JUMP=""
SSHMGR_TARGET_IDENTITY=""
SSHMGR_TARGET_KH_FILE=""
SSHMGR_TARGET_KH_ENTRY=""
SSHMGR_TARGET_RESOLVED=0

_sshmgr_target_get() { # $1=key $2=ssh -G output
  printf '%s\n' "$2" | awk -v k="$1" '$1==k {sub(/^[^[:space:]]+[[:space:]]+/, ""); print; exit}'
}

_sshmgr_target_get1() { # 只取第二个字段：userknownhostsfile 等一行可能有多个值
  printf '%s\n' "$2" | awk -v k="$1" '$1==k {print $2; exit}'
}

# 只用于拼进远端 ssh-keyscan 命令的主机名白名单。
sshmgr_target_safe_host() {
  case "$1" in
    ''|-*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._:%-]+$'
}

# sshmgr_resolve_target <ssh_bin> <target> <user> <port> <jump> <identity>
# target 可以带 user@ 前缀。
sshmgr_resolve_target() {
  local ssh_bin="$1" target="$2" user="$3" port="$4" jump="$5" identity="$6"
  local hostpart="$target"
  case "$target" in
    *@*) hostpart="${target#*@}" ;;
  esac

  SSHMGR_TARGET_HOST="$hostpart"
  SSHMGR_TARGET_PORT="${port:-22}"
  SSHMGR_TARGET_USER="$user"
  SSHMGR_TARGET_JUMP="$jump"
  SSHMGR_TARGET_IDENTITY="$identity"
  SSHMGR_TARGET_KH_FILE="${HOME}/.ssh/known_hosts"
  SSHMGR_TARGET_KH_ENTRY=""
  SSHMGR_TARGET_RESOLVED=0

  local t="$target"
  if [ -n "$user" ]; then
    t="${user}@${hostpart}"
  fi

  local -a gopts=()
  [ -n "$port" ] && gopts+=( -p "$port" )
  [ -n "$jump" ] && gopts+=( -J "$jump" )
  [ -n "$identity" ] && gopts+=( -i "$identity" )

  local out=""
  out="$("$ssh_bin" -G "${gopts[@]}" "$t" 2>/dev/null)" || out=""
  if [ -z "$out" ]; then
    # ssh -G 失败时保留调用方给的值，至少 known_hosts 条目是确定的。
    if [ "$SSHMGR_TARGET_PORT" != "22" ]; then
      SSHMGR_TARGET_KH_ENTRY="[${SSHMGR_TARGET_HOST}]:${SSHMGR_TARGET_PORT}"
    else
      SSHMGR_TARGET_KH_ENTRY="$SSHMGR_TARGET_HOST"
    fi
    return 0
  fi
  SSHMGR_TARGET_RESOLVED=1

  local v
  v="$(_sshmgr_target_get hostname "$out")"; [ -n "$v" ] && SSHMGR_TARGET_HOST="$v"
  v="$(_sshmgr_target_get port "$out")";     [ -n "$v" ] && SSHMGR_TARGET_PORT="$v"
  v="$(_sshmgr_target_get user "$out")";     [ -n "$v" ] && SSHMGR_TARGET_USER="$v"
  v="$(_sshmgr_target_get proxyjump "$out")"
  case "$v" in none|"") ;; *) SSHMGR_TARGET_JUMP="$v" ;; esac
  v="$(_sshmgr_target_get identityfile "$out")"
  [ -n "$v" ] && SSHMGR_TARGET_IDENTITY="$v"
  v="$(_sshmgr_target_get1 userknownhostsfile "$out")"
  case "$v" in
    none) SSHMGR_TARGET_KH_FILE="" ;;
    "") ;;
    # 这里匹配的是 ssh -G 输出里的字面量 "~/"；不是要展开本地路径。
    "~/"*) SSHMGR_TARGET_KH_FILE="$HOME/${v#\~/}" ;;
    *) SSHMGR_TARGET_KH_FILE="$v" ;;
  esac

  local alias
  alias="$(_sshmgr_target_get hostkeyalias "$out")"
  case "$alias" in
    none|"") alias="" ;;
  esac

  if [ -n "$alias" ]; then
    SSHMGR_TARGET_KH_ENTRY="$alias"
  elif [ "$SSHMGR_TARGET_PORT" != "22" ]; then
    SSHMGR_TARGET_KH_ENTRY="[${SSHMGR_TARGET_HOST}]:${SSHMGR_TARGET_PORT}"
  else
    SSHMGR_TARGET_KH_ENTRY="$SSHMGR_TARGET_HOST"
  fi
  return 0
}
