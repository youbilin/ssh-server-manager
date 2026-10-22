#!/usr/bin/env bash
# backup_config.sh - 修改关键配置前的远端备份，并输出可直接执行的还原命令
#
# 设计意图：改 sshd_config / nginx.conf / 防火墙规则这类文件时，
# 「我备份了吗」和「备份在哪、怎么还原」是两个必须在动手前就有答案的问题。
# 所以这个脚本不只做备份，还会校验备份完整性并打印还原命令。
#
# 用法:
#   ./backup_config.sh -H web1 -f /etc/nginx/nginx.conf
#   ./backup_config.sh -H web1 -f /etc/ssh/sshd_config --sudo
#   ./backup_config.sh -H web1 -d /etc/nginx/sites-enabled --sudo
#   ./backup_config.sh -H web1 -f /etc/nginx/nginx.conf --list
#   ./backup_config.sh -H web1 -f /etc/nginx/nginx.conf --keep 10   # 保留最近 10 份
#
# 退出码: 0 成功 | 1 备份失败 | 2 用法错误 | 3 连接失败

set -uo pipefail
LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_EXEC="$SCRIPT_DIR/ssh_exec.sh"

HOST=""
USER_NAME=""
PORT=""
JUMP=""
IDENTITY=""
R_PATH=""
R_TYPE="file"
USE_SUDO=0
LIST_ONLY=0
KEEP=""
AUTH_MODE=""
PASSWORD_ENV=""
CREDENTIAL_FILE=""
PROMPT_CREDENTIAL=0
SAVE_CREDENTIAL=0
USE_SAVED_CREDENTIAL=0

if [ -t 1 ]; then C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""; fi

err()  { printf '%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'

选项:
  -H, --host HOST     目标主机
  -f, --file PATH     要备份的远端文件（绝对路径）
  -d, --dir PATH      要备份的远端目录（打包为 tar.gz）
  -u, --user USER     登录用户
  -p, --port PORT     SSH 端口
  -J, --jump JUMP     ProxyJump 跳板机
  -i, --identity FILE 私钥文件路径
      --sudo          远端操作使用 sudo -n（非交互，需 NOPASSWD）
      --list          只列出该文件已有的备份
      --keep N        只保留最近 N 份备份（N>=1，会删除更旧的备份，需显式指定）
  -h, --help          显示本帮助

认证（透传给 ssh_exec.sh）:
      --auth MODE        auto | key | password
      --password-env VAR
      --credential-file F
      --prompt-credential
      --use-saved-credential
      --save-credential

备份位置:
  有 sudo 时用 /var/backups/ssh-server-manager（与业务数据不同盘更稳）
  否则用远端 $HOME/.config-backups
USAGE
}

need_arg() { [ "$2" -ge 2 ] || { err "选项 $1 需要一个参数"; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    -H|--host)     need_arg "$1" $#; HOST="$2"; shift 2 ;;
    -u|--user)     need_arg "$1" $#; USER_NAME="$2"; shift 2 ;;
    -p|--port)     need_arg "$1" $#; PORT="$2"; shift 2 ;;
    -J|--jump)     need_arg "$1" $#; JUMP="$2"; shift 2 ;;
    -i|--identity) need_arg "$1" $#; IDENTITY="$2"; shift 2 ;;
    -f|--file)     need_arg "$1" $#; R_PATH="$2"; R_TYPE="file"; shift 2 ;;
    -d|--dir)      need_arg "$1" $#; R_PATH="$2"; R_TYPE="dir"; shift 2 ;;
    --sudo)        USE_SUDO=1; shift ;;
    --list)        LIST_ONLY=1; shift ;;
    --keep)        need_arg "$1" $#; KEEP="$2"; shift 2 ;;
    --auth)        need_arg "$1" $#; AUTH_MODE="$2"; shift 2 ;;
    --password-env) need_arg "$1" $#; PASSWORD_ENV="$2"; shift 2 ;;
    --credential-file) need_arg "$1" $#; CREDENTIAL_FILE="$2"; shift 2 ;;
    --prompt-credential) PROMPT_CREDENTIAL=1; shift ;;
    --save-credential) SAVE_CREDENTIAL=1; shift ;;
    --use-saved-credential) USE_SAVED_CREDENTIAL=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "未知选项: $1（用 --help 查看用法）"; exit 2 ;;
  esac
done

[ -n "$HOST" ] || { err "必须指定目标主机（-H）"; exit 2; }
[ -n "$R_PATH" ] || { err "必须指定远端路径（-f 文件 或 -d 目录）"; exit 2; }
[ -x "$SSH_EXEC" ] || [ -f "$SSH_EXEC" ] || { err "找不到 ssh_exec.sh（应与本脚本同目录）"; exit 2; }
case "${KEEP:-1}" in *[!0-9]*) err "--keep 必须是整数"; exit 2 ;; esac
if [ -n "$KEEP" ] && [ "$KEEP" -lt 1 ]; then
  err "--keep 至少为 1（--keep 0 会连刚生成的备份一起删掉）"; exit 2
fi
case "$AUTH_MODE" in ''|auto|key|password) ;; *) err "--auth 只能是 auto|key|password"; exit 2 ;; esac

# 远端路径会被拼进远端脚本，所以先做保守校验。
# 与其花力气做转义，不如直接拒绝会破坏引号的字符 —— 配置路径本来就不该包含它们。
case "$R_PATH" in
  /*) : ;;
  *)  err "远端路径必须是绝对路径（以 / 开头）: $R_PATH"; exit 2 ;;
esac
case "$R_PATH" in
  *"'"*|*'"'*|*';'*|*'$'*|*'`'*|*'\'*|*$'\n'*)
    err "远端路径包含不安全字符（引号/分号/\$/反引号/反斜杠），请改用简单路径"; exit 2 ;;
esac
case "$R_PATH" in
  */../*|*/..) err "远端路径不能包含 .."; exit 2 ;;
esac

# ---------- 远端脚本 ----------
# 一次 ssh 完成「检查 → 备份 → 校验 → 列目录」，减少往返也减少半途失败的机会。
build_remote_script() {
  local sudo_prefix=""
  [ "$USE_SUDO" -eq 1 ] && sudo_prefix="sudo -n "
  local bkroot="/var/backups/ssh-server-manager"
  if [ "$USE_SUDO" -ne 1 ]; then
    bkroot='$HOME/.config-backups'
  fi

  cat <<REMOTE
set -u
RP='$R_PATH'
RT='$R_TYPE'
BKROOT="$bkroot"
SUDO="$sudo_prefix"
# 下面这两个在本地生成脚本时就已经确定，写死成字面量即可
LIST_ONLY=$LIST_ONLY
# 秒级时间戳不足以区分同一秒内的两次备份（会互相覆盖）；加远端 shell PID 保证唯一。
STAMP="\$(date -u +%Y%m%dT%H%M%SZ)-\$\$"

# 用 \${SUDO} 读取：--sudo 时备份在 /var/backups 下且被 chmod 600，
# 普通用户直接 sha256sum 会读不到，校验就永远失败。
digest() {
  if command -v sha256sum >/dev/null 2>&1; then \${SUDO}sha256sum "\$1" 2>/dev/null | awk '{print \$1}'
  elif command -v shasum >/dev/null 2>&1; then \${SUDO}shasum -a 256 "\$1" 2>/dev/null | awk '{print \$1}'
  elif command -v openssl >/dev/null 2>&1; then \${SUDO}openssl dgst -sha256 "\$1" 2>/dev/null | awk '{print \$NF}'
  else echo unavailable; fi
}

BASE="\$(basename "\$RP")"
SRCDIR="\$(dirname "\$RP")"

# --- 存在性检查：不存在就明确失败，绝不生成一个空备份冒充成功 ---
if [ ! -e "\$RP" ]; then
  \${SUDO}test -e "\$RP" 2>/dev/null || { echo "STATUS=error"; echo "ERROR=path_not_found"; echo "PATH=\$RP"; exit 1; }
fi
if [ "\$RT" = dir ] && [ ! -d "\$RP" ]; then
  echo "STATUS=error"; echo "ERROR=not_a_directory"; echo "PATH=\$RP"; exit 1
fi
if [ "\$RT" = file ] && [ ! -f "\$RP" ]; then
  echo "STATUS=error"; echo "ERROR=not_a_regular_file"; echo "PATH=\$RP"; exit 1
fi

# --- --list：只列已有备份 ---
if [ "\$LIST_ONLY" -eq 1 ]; then
  echo "STATUS=list"
  echo "BKROOT=\$BKROOT"
  if \${SUDO}test -d "\$BKROOT" 2>/dev/null; then
    \${SUDO}ls -1 "\$BKROOT" 2>/dev/null | grep -F "\$BASE." | sort
  fi
  exit 0
fi

\${SUDO}mkdir -p "\$BKROOT" 2>/dev/null || { echo "STATUS=error"; echo "ERROR=backup_dir_unwritable"; echo "BKROOT=\$BKROOT"; exit 1; }
\${SUDO}chmod 700 "\$BKROOT" 2>/dev/null || true

if [ "\$RT" = dir ]; then
  DEST="\$BKROOT/\${BASE}.\${STAMP}.tar.gz"
  \${SUDO}tar -czf "\$DEST" -C "\$SRCDIR" "\$BASE" 2>/dev/null || { echo "STATUS=error"; echo "ERROR=archive_failed"; exit 1; }
  \${SUDO}chmod 600 "\$DEST" 2>/dev/null || true
  DSTSUM="\$(digest "\$DEST")"
  SRCSUM="n/a(dir)"
  NFILES="\$(\${SUDO}find "\$RP" -type f 2>/dev/null | wc -l)"
  SRCSIZE="\$(\${SUDO}du -sb "\$RP" 2>/dev/null | awk '{print \$1}')"
else
  DEST="\$BKROOT/\${BASE}.\${STAMP}.bak"
  \${SUDO}cp -p "\$RP" "\$DEST" 2>/dev/null || { echo "STATUS=error"; echo "ERROR=copy_failed"; exit 1; }
  \${SUDO}chmod 600 "\$DEST" 2>/dev/null || true
  SRCSUM="\$(digest "\$RP")"
  DSTSUM="\$(digest "\$DEST")"
  SRCSIZE="\$(\${SUDO}stat -c %s "\$RP" 2>/dev/null || \${SUDO}wc -c < "\$RP" 2>/dev/null)"
  NFILES="1"
fi

# --- 校验：源与备份的摘要必须一致，否则这份备份不能信 ---
if [ "\$RT" = file ] && [ "\$SRCSUM" != "unavailable" ] && [ "\$SRCSUM" != "\$DSTSUM" ]; then
  echo "STATUS=error"; echo "ERROR=digest_mismatch"
  echo "SRCSUM=\$SRCSUM"; echo "DSTSUM=\$DSTSUM"; echo "BACKUP=\$DEST"
  exit 1
fi
DSTSIZE="\$(\${SUDO}stat -c %s "\$DEST" 2>/dev/null || \${SUDO}wc -c < "\$DEST" 2>/dev/null)"
[ -n "\$DSTSIZE" ] || DSTSIZE=0
if [ "\$DSTSIZE" -lt 1 ] 2>/dev/null; then
  echo "STATUS=error"; echo "ERROR=backup_empty"; echo "BACKUP=\$DEST"; exit 1
fi

echo "STATUS=ok"
echo "PATH=\$RP"
echo "TYPE=\$RT"
echo "BACKUP=\$DEST"
echo "BACKUP_SIZE=\$DSTSIZE"
echo "SRC_SIZE=\$SRCSIZE"
echo "SRC_SHA256=\$SRCSUM"
echo "DST_SHA256=\$DSTSUM"
echo "FILE_COUNT=\$NFILES"
echo "SUDO=$USE_SUDO"
echo "PARENT=\$SRCDIR"
echo "STAMP=\$STAMP"

# --- 可选：只保留最近 N 份 ---
if [ -n "$KEEP" ]; then
  # 只按本文件的备份前缀匹配，并且按时间戳排序（文件名形如 <base>.<UTCstamp>.bak），
  # 不能只靠 sort -r 排字典序去猜"最近"：同一秒内的两次备份会互相覆盖语义。
  OLD="\$(\${SUDO}ls -1 "\$BKROOT" 2>/dev/null | grep -F "\$BASE." | sort | tail -n +$((KEEP + 1)))"
  if [ -n "\$OLD" ]; then
    echo "PRUNED_BEGIN"
    printf '%s\n' "\$OLD" | while IFS= read -r f; do
      [ -n "\$f" ] || continue
      \${SUDO}rm -f "\$BKROOT/\$f" 2>/dev/null && echo "\$f"
    done
    echo "PRUNED_END"
  fi
fi
exit 0
REMOTE
}

# 这里把 build_remote_script 的输出交给远端 bash 执行，而不是用 ssh_exec -f：
# 因为需要按 --sudo / --list / --keep 动态生成脚本内容。
# 传输仍走 ssh_exec.sh，所以风险分级与审计日志依然生效。
run_remote() {
  local script_text="$1"
  local args=(-H "$HOST" -q)
  [ -n "$USER_NAME" ] && args+=(-u "$USER_NAME")
  [ -n "$PORT" ] && args+=(-p "$PORT")
  [ -n "$JUMP" ] && args+=(-J "$JUMP")
  [ -n "$IDENTITY" ] && args+=(-i "$IDENTITY")
  [ -n "$AUTH_MODE" ] && args+=(--auth "$AUTH_MODE")
  [ -n "$PASSWORD_ENV" ] && args+=(--password-env "$PASSWORD_ENV")
  [ -n "$CREDENTIAL_FILE" ] && args+=(--credential-file "$CREDENTIAL_FILE")
  [ "$PROMPT_CREDENTIAL" -eq 1 ] && args+=(--prompt-credential)
  [ "$SAVE_CREDENTIAL" -eq 1 ] && args+=(--save-credential)
  [ "$USE_SAVED_CREDENTIAL" -eq 1 ] && args+=(--use-saved-credential)
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/sshmgr-bk.XXXXXX")" || { err "无法创建临时文件"; return 1; }
  printf '%s\n' "$script_text" > "$tmp"
  # 注意：脚本模式（-f）下命令内容无法静态分级，ssh_exec.sh 会一律按 tier1 处理，
  # 所以这里不需要也不能靠 --confirm-danger 放宽 —— 删除旧备份的确认由 --keep 这个显式开关承担。
  # --label 让审计日志记下"备份了哪个路径"，否则只会留下一个临时文件名。
  if [ "$LIST_ONLY" -eq 1 ]; then
    args+=(--label "backup_config --list $R_PATH")
  elif [ -n "$KEEP" ]; then
    args+=(--label "backup_config $R_PATH (keep=$KEEP)")
  else
    args+=(--label "backup_config $R_PATH")
  fi
  args+=(-f "$tmp" -t 120)
  bash "$SSH_EXEC" "${args[@]}"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

SCRIPT_TEXT="$(build_remote_script)"

if [ -n "$KEEP" ]; then
  warn "--keep $KEEP 会删除更旧的备份，这是你显式要求的行为；确认备份都在 $HOST 上且确实不需要保留。"
fi

printf '%s-> 在 %s 上备份 %s%s\n' "$C_DIM" "$HOST" "$R_PATH" "$C_OFF"
OUT=""
OUT="$(run_remote "$SCRIPT_TEXT")"
rc=$?

if [ "$rc" -ne 0 ] && [ -z "$OUT" ]; then
  err "备份失败：无法取得远端输出（rc=$rc）"
  exit 3
fi

get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

STATUS="$(get STATUS)"
case "$STATUS" in
  ok) ;;
  list)
    printf '%s备份目录:%s %s\n' "$C_YEL" "$C_OFF" "$(get BKROOT)"
    BODY="$(printf '%s\n' "$OUT" | sed -n '/^BKROOT=/,$p' | tail -n +2)"
    if [ -z "$BODY" ]; then
      printf '  （尚无备份）\n'
    else
      printf '  备份文件\n'
      printf '%s\n' "$BODY" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '  %s\n' "$f"
      done
    fi
    exit 0 ;;
  *)
    ERRCODE="$(get ERROR)"
    case "$ERRCODE" in
      path_not_found)          err "远端路径不存在: $(get PATH)" ;;
      not_a_directory)         err "远端路径不是目录: $(get PATH)" ;;
      not_a_regular_file)      err "远端路径不是普通文件（可能是设备/符号链接）: $(get PATH)" ;;
      backup_dir_unwritable)
        if [ "$USE_SUDO" -eq 1 ]; then
          err "备份目录不可写: $(get BKROOT)"
          err "已使用 --sudo，说明该账号的 sudo 需要密码（非交互模式拿不到输入）或没有 NOPASSWD 权限。"
          printf '  解决：为该账号配置 NOPASSWD，或先手工创建目录并授权：\n' >&2
          printf '    sudo mkdir -p %s && sudo chown $(whoami) %s\n' "$(get BKROOT)" "$(get BKROOT)" >&2
        else
          err "备份目录不可写: $(get BKROOT)（试试加 --sudo）"
        fi ;;
      copy_failed|archive_failed)
        if [ "$USE_SUDO" -eq 1 ]; then
          err "复制/打包失败 —— 读源文件或写备份目录的权限不足（--sudo 已开启，检查 NOPASSWD 与源文件权限）"
        else
          err "复制/打包失败 —— 权限不足，试试加 --sudo"
        fi ;;
      digest_mismatch)         err "备份校验失败：源与备份的 SHA256 不一致，这份备份不可信" ;;
      backup_empty)            err "备份文件为空，已拒绝当成功处理" ;;
      *)                       err "备份失败: ${ERRCODE:-未知错误}" ;;
    esac
    printf '%s\n' "$OUT" | sed 's/^/  /' >&2
    exit 1 ;;
esac

BK="$(get BACKUP)"
BK_SIZE="$(get BACKUP_SIZE)"
SRC_SHA="$(get SRC_SHA256)"
DST_SHA="$(get DST_SHA256)"
PARENT="$(get PARENT)"
RTYPE="$(get TYPE)"

printf '%s备份成功%s\n' "$C_GRN" "$C_OFF"
printf '  %-16s %s\n' "源文件"     "$(get PATH)"
printf '  %-16s %s\n' "类型"       "$RTYPE"
printf '  %-16s %s bytes\n' "源大小" "$(get SRC_SIZE)"
printf '  %-16s %s bytes\n' "备份大小" "$BK_SIZE"
printf '  %-16s %s\n' "备份位置"   "$BK"
if [ "$RTYPE" = file ]; then
  if [ "$SRC_SHA" = "$DST_SHA" ] && [ "$SRC_SHA" != "unavailable" ]; then
    printf '  %-16s %s  %s(与源一致)◄%s\n' "SHA256" "$DST_SHA" "$C_GRN" "$C_OFF"
  else
    printf '  %-16s 源=%s 备份=%s\n' "SHA256" "$SRC_SHA" "$DST_SHA"
    [ "$SRC_SHA" = "unavailable" ] && warn "远端缺少 sha256sum/shasum/openssl，无法校验摘要（仅按大小与非空做了校验）"
  fi
else
  printf '  %-16s %s 个文件\n' "文件数" "$(get FILE_COUNT)"
fi

# ---------- 还原命令 ----------
# 备份在远端，所以还原命令必须带 ssh 前缀（或明确“登录到目标机后执行”），
# 否则用户会把远端路径当成本地路径执行。真正出事的时候没有精力再推敲这些。
printf '\n%s还原命令（在本地执行，已带 ssh 前缀）:%s\n' "$C_YEL" "$C_OFF"
R_TARGET="$HOST"
[ -n "$USER_NAME" ] && R_TARGET="$USER_NAME@$HOST"
SSH_PREFIX="ssh"
[ -n "$PORT" ] && SSH_PREFIX="$SSH_PREFIX -p $(printf '%q' "$PORT")"
[ -n "$JUMP" ] && SSH_PREFIX="$SSH_PREFIX -J $(printf '%q' "$JUMP")"
[ -n "$IDENTITY" ] && SSH_PREFIX="$SSH_PREFIX -i $(printf '%q' "$IDENTITY")"
SSH_PREFIX="$SSH_PREFIX $(printf '%q' "$R_TARGET")"
SUDO_PREFIX=""
[ "$USE_SUDO" -eq 1 ] && SUDO_PREFIX="sudo "

RESTORE_PATH="$(get PATH)"
if [ "$RTYPE" = dir ]; then
  REMOTE_CMD="${SUDO_PREFIX}tar -xzf '${BK}' -C '${PARENT}'"
else
  REMOTE_CMD="${SUDO_PREFIX}cp -p -- '${BK}' '${RESTORE_PATH}'"
fi

# 还原后必须做语法检查再重载，否则等于把坏配置重新装回去
CHECK_CMD=""
case "$RESTORE_PATH" in
  */nginx.conf|*/nginx/*.conf|*/sites-enabled/*|*/conf.d/*)
    CHECK_CMD="${SUDO_PREFIX}nginx -t && { ${SUDO_PREFIX}systemctl reload nginx 2>/dev/null || ${SUDO_PREFIX}rc-service nginx reload; }" ;;
  */sshd_config)
    CHECK_CMD="${SUDO_PREFIX}sshd -t && { ${SUDO_PREFIX}systemctl reload sshd 2>/dev/null || ${SUDO_PREFIX}systemctl reload ssh 2>/dev/null || ${SUDO_PREFIX}rc-service sshd reload; }" ;;
  *php-fpm*|*/php/*)
    CHECK_CMD="${SUDO_PREFIX}php-fpm -t && { ${SUDO_PREFIX}systemctl reload php-fpm 2>/dev/null || ${SUDO_PREFIX}rc-service php-fpm reload; }" ;;
  *fstab)
    CHECK_CMD="${SUDO_PREFIX}findmnt --verify" ;;
esac
[ -n "$CHECK_CMD" ] && REMOTE_CMD="${REMOTE_CMD} && ${CHECK_CMD}"

printf '  %s "%s"\n' "$SSH_PREFIX" "$REMOTE_CMD"
printf '  %s（也可以在目标机上执行引号内的命令）%s\n' "$C_DIM" "$C_OFF"

# ---------- 裁剪结果 ----------
PRUNED="$(printf '%s\n' "$OUT" | sed -n '/^PRUNED_BEGIN$/,/^PRUNED_END$/p' | sed '1d;$d')"
if [ -n "$PRUNED" ]; then
  printf '\n%s已按 --keep %s 删除更旧的备份:%s\n' "$C_YEL" "$KEEP" "$C_OFF"
  printf '%s\n' "$PRUNED" | sed 's/^/  /'
fi

printf '\n%s下一步:%s 修改配置前先确认这份备份可用，改完做语法检查，并保留当前 SSH 会话不要退出。\n' \
  "$C_DIM" "$C_OFF"
exit 0
