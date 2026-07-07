#!/bin/bash
# Claude4RemoteDEV installer.
# Configures a project so Claude Code (running on THIS machine) transparently executes its
# Bash-tool commands on a REMOTE server, with files kept in real-time bidi sync via Mutagen.
#
#   ./setup.sh                         # interactive, configures the current directory
#   ./setup.sh --project /path/to/proj # configure a specific project
#   Flags (skip prompts): --remote-host H --remote-user U --port N --remote-root PATH
#                         --mirror PATH --alias NAME --session NAME --gen-key --yes --no-sync
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- defaults / arg parsing ----
PROJECT="$PWD"; ALIAS=""; REMOTE_HOST=""; REMOTE_USER=""; REMOTE_PORT=""
REMOTE_ROOT=""; MIRROR_ROOT=""; SESSION=""; SSH_KEY="$HOME/.ssh/id_c4rd"
GEN_KEY=0; ASSUME_YES=0; DO_SYNC=1; AUTOSTART=""
while [ $# -gt 0 ]; do case "$1" in
  --project) PROJECT="$2"; shift 2;;
  --autostart) AUTOSTART=yes; shift;;
  --no-autostart) AUTOSTART=no; shift;;
  --remote-host) REMOTE_HOST="$2"; shift 2;;
  --remote-user) REMOTE_USER="$2"; shift 2;;
  --port) REMOTE_PORT="$2"; shift 2;;
  --remote-root) REMOTE_ROOT="$2"; shift 2;;
  --mirror) MIRROR_ROOT="$2"; shift 2;;
  --alias) ALIAS="$2"; shift 2;;
  --session) SESSION="$2"; shift 2;;
  --key) SSH_KEY="$2"; shift 2;;
  --gen-key) GEN_KEY=1; shift;;
  --yes|-y) ASSUME_YES=1; shift;;
  --no-sync) DO_SYNC=0; shift;;
  -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

# Resolve to an absolute path WITHOUT requiring the project dir to exist yet (recovery: it may have
# been deleted). Parent must exist. We create the dir later, AFTER terminating any stale session.
PARENT="$(cd "$(dirname "$PROJECT")" 2>/dev/null && pwd)" || { echo "parent dir not found: $(dirname "$PROJECT")" >&2; exit 1; }
PROJECT="$PARENT/$(basename "$PROJECT")"
info(){ printf '\033[36m[c4rd]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[c4rd]\033[0m %s\n' "$*" >&2; }
die(){  printf '\033[31m[c4rd]\033[0m %s\n' "$*" >&2; exit 1; }

ask(){ # ask VAR "prompt" "default"
  local __v="$1" __p="$2" __d="${3:-}" __a
  [ -n "${!__v:-}" ] && return
  if [ "$ASSUME_YES" = 1 ]; then printf -v "$__v" '%s' "$__d"; return; fi
  read -r -p "  $__p${__d:+ [$__d]}: " __a </dev/tty || true
  printf -v "$__v" '%s' "${__a:-$__d}"
}

command -v jq  >/dev/null 2>&1 || die "jq is required (apt-get install jq / brew install jq)"
command -v ssh >/dev/null 2>&1 || die "ssh is required"
command -v rsync >/dev/null 2>&1 || warn "rsync not found — 'cpull' will not work until installed"

echo; info "Configuring project: $PROJECT"; echo
ask REMOTE_HOST "远程服务器地址 (IP/域名)"     ""
ask REMOTE_USER "远程用户名"                    ""
ask REMOTE_PORT "远程 SSH 端口"                 "22"
ask REMOTE_ROOT "远程项目绝对路径"              ""
ask MIRROR_ROOT "本机镜像目录"                  "$PROJECT"
ask ALIAS       "ssh 别名"                      "c4rd-$(basename "$PROJECT")"
ask SESSION     "Mutagen 会话名"                "c4rd-$(basename "$PROJECT")"
[ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_USER" ] && [ -n "$REMOTE_ROOT" ] \
  || die "REMOTE_HOST / REMOTE_USER / REMOTE_ROOT 不能为空"

# ---- SSH key ----
if [ "$GEN_KEY" = 1 ] || [ ! -f "$SSH_KEY" ]; then
  if [ ! -f "$SSH_KEY" ]; then
    info "生成 SSH 密钥: $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "claude4remotedev" >/dev/null
  fi
  info "把公钥装到远程 (可能要求输入一次密码)"
  ssh-copy-id -i "$SSH_KEY.pub" -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_HOST" 2>/dev/null \
    || { warn "ssh-copy-id 未成功。请手动把下面这行加到远程 ~/.ssh/authorized_keys:"; echo; cat "$SSH_KEY.pub"; echo; }
fi

# ---- ~/.ssh/config (idempotent) ----
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if ! grep -qE "^Host[[:space:]]+$ALIAS\$" "$HOME/.ssh/config" 2>/dev/null; then
  info "写入 ~/.ssh/config: Host $ALIAS"
  cat >> "$HOME/.ssh/config" <<EOF

Host $ALIAS
    HostName $REMOTE_HOST
    Port $REMOTE_PORT
    User $REMOTE_USER
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
    ServerAliveInterval 20
    ServerAliveCountMax 3
    TCPKeepAlive yes
    ControlMaster auto
    ControlPath ~/.ssh/cm-c4rd-%r@%h:%p
    ControlPersist 30m
EOF
  chmod 600 "$HOME/.ssh/config"
else
  info "~/.ssh/config 已有 Host $ALIAS,跳过"
fi

info "测试 SSH 连接…"
if ssh -o ConnectTimeout=15 "$ALIAS" true 2>/dev/null; then info "SSH OK ✓"
else warn "SSH 暂时连不通(密钥没装好?网络?)。配置照常写入,稍后可 'ssh $ALIAS' 自检。"; fi

# ---- SAFETY: terminate any pre-existing session BEFORE we repopulate the mirror ----
# If this project was deleted and is being reinstalled, a stale session could otherwise resume and
# propagate the "missing files" as deletions to the remote. Terminating first guarantees the sync we
# (re)create at the end is a FRESH session whose initial sync only repopulates local from remote.
if command -v mutagen >/dev/null 2>&1 && mutagen sync list "$SESSION" 2>/dev/null | grep -q "Name: $SESSION"; then
  mutagen sync terminate "$SESSION" >/dev/null 2>&1 || true
  info "检测到同名旧同步会话,已先终止(安全:重建后将从远程恢复,远程不受影响)"
fi

# ---- install scripts + config into project .claude/c4rd ----
C4RD="$PROJECT/.claude/c4rd"
mkdir -p "$C4RD/state" "$PROJECT/.claude/skills"
cp "$SELF_DIR/scripts/"* "$C4RD/"
chmod +x "$C4RD/"*.sh "$C4RD/c" "$C4RD/cpull" 2>/dev/null || true

cat > "$C4RD/config.sh" <<EOF
# generated by Claude4RemoteDEV setup.sh
REMOTE_ALIAS="$ALIAS"
REMOTE_HOST="$REMOTE_HOST"
REMOTE_USER="$REMOTE_USER"
REMOTE_PORT="$REMOTE_PORT"
REMOTE_ROOT="$REMOTE_ROOT"
MIRROR_ROOT="$MIRROR_ROOT"
SESSION="$SESSION"
SSH_KEY="$SSH_KEY"
REMOTE_PATH_FIX='export PATH="\$HOME/miniconda3/bin:\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH"'
PROBE_TIMEOUT="3"
EOF

# seed routing OFF (wraps-not-activates)
[ -f "$C4RD/state/mode" ] || echo "off" > "$C4RD/state/mode"
info "已安装脚本到 $C4RD  (routing 默认 OFF)"

# ---- merge settings.json: register PreToolUse(Bash) hook ----
SETTINGS="$PROJECT/.claude/settings.json"
HOOK_CMD='$CLAUDE_PROJECT_DIR/.claude/c4rd/route-bash.sh'
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.c4rd-bak" 2>/dev/null || true
if jq --arg cmd "$HOOK_CMD" '
      .hooks //= {} | .hooks.PreToolUse //= [] |
      if ([.hooks.PreToolUse[]?.hooks[]?.command] | index($cmd))
      then .
      else .hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}] end
   ' "$SETTINGS" > "$SETTINGS.tmp" 2>/dev/null; then
  mv "$SETTINGS.tmp" "$SETTINGS"; info "已在 $SETTINGS 注册 PreToolUse(Bash) hook"
else
  rm -f "$SETTINGS.tmp"; warn "settings.json 合并失败,请手动添加 hook(见 README)"
fi

# ---- install skill ----
cp -r "$SELF_DIR/skill/claude4remotedev" "$PROJECT/.claude/skills/"
info "已安装 skill: /claude4remotedev"

# ---- start sync ----
if [ "$DO_SYNC" = 1 ]; then
  if command -v mutagen >/dev/null 2>&1; then
    info "启动 Mutagen 同步(范围读 $MIRROR_ROOT/.gitignore)…"
    "$C4RD/sync-start.sh" || warn "sync-start 失败,稍后手动运行 $C4RD/sync-start.sh"
  else
    warn "未检测到 mutagen。请先安装,再运行 $C4RD/sync-start.sh:"
    echo '      ver=$(curl -sL https://api.github.com/repos/mutagen-io/mutagen/releases/latest | grep -oP "\"tag_name\":\s*\"\K[^\"]+")'
    echo '      curl -sL -o /tmp/m.tgz "https://github.com/mutagen-io/mutagen/releases/download/$ver/mutagen_linux_amd64_$ver.tar.gz"'
    echo '      sudo tar -xzf /tmp/m.tgz -C /usr/local/bin && mutagen daemon start   # macOS: brew install mutagen-io/mutagen/mutagen'
  fi
fi

# ---- optional: daemon autostart on boot (systemd) ----
if [ -z "$AUTOSTART" ]; then
  if [ "$ASSUME_YES" = 1 ]; then AUTOSTART=no
  else
    read -r -p "  设置 mutagen 守护进程开机自启 (systemd,需要 sudo)? [y/N]: " __a </dev/tty || true
    case "$__a" in y|Y|yes|YES) AUTOSTART=yes;; *) AUTOSTART=no;; esac
  fi
fi
if [ "$AUTOSTART" = yes ]; then
  bash "$C4RD/install-daemon-service.sh" \
    || warn "开机自启设置失败(权限?),可稍后手动:bash $C4RD/install-daemon-service.sh"
else
  info "未设开机自启。B 重启后需 'mutagen daemon start' 恢复同步(或稍后 bash $C4RD/install-daemon-service.sh)"
fi

echo
info "完成 ✓  后续:"
echo "  1) cd $PROJECT && claude"
echo "  2) 在 Claude 里输入  /claude4remotedev on   开启远程执行(默认关闭)"
echo "  3) 让 Claude 跑 'hostname' 验证:应显示远程主机名"
echo "  4) 改了 .gitignore 后运行  $C4RD/resync   重建同步范围"
echo "  自测: $SELF_DIR/tests/smoke.sh --project $PROJECT"
