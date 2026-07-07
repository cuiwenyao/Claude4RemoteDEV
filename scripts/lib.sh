#!/bin/bash
# lib.sh — shared helpers for Claude4RemoteDEV. Sourced by every c4rd script.
# Lives alongside config.sh in <project>/.claude/c4rd/.

C4RD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$C4RD_DIR/state"

# --- load config (fail loudly if missing) ---
if [ -f "$C4RD_DIR/config.sh" ]; then
  # shellcheck disable=SC1091
  source "$C4RD_DIR/config.sh"
else
  echo "[c4rd] missing config: $C4RD_DIR/config.sh (run setup.sh)" >&2
  return 1 2>/dev/null || exit 1
fi

# sensible defaults
: "${REMOTE_PORT:=22}"
: "${PROBE_TIMEOUT:=3}"
: "${REMOTE_PATH_FIX:=:}"
: "${SSH_KEY:=$HOME/.ssh/id_c4rd}"

# All SSH goes through the alias in ~/.ssh/config (setup.sh writes it with port, key,
# ControlMaster/ControlPersist). Mutagen also uses this alias, so they share one connection.
: "${REMOTE_ALIAS:=c4rd-remote}"
REMOTE_ENDPOINT="${REMOTE_ALIAS}:${REMOTE_ROOT}"   # for `mutagen sync create`

# c4rd_ssh [remote-command...] — ssh to the remote reusing the multiplexed connection.
# The remote command (e.g. `bash -l -s`) is placed AFTER the host, per ssh syntax.
c4rd_ssh() { ssh "$REMOTE_ALIAS" "$@"; }

# c4rd_probe — return 0 if remote reachable within PROBE_TIMEOUT.
c4rd_probe() { ssh -o "ConnectTimeout=$PROBE_TIMEOUT" "$REMOTE_ALIAS" true >/dev/null 2>&1; }

# c4rd_mode [session_id] — resolve routing mode: session file > project mode file > "off".
c4rd_mode() {
  local sid="${1:-}"
  if [ -n "$sid" ] && [ -f "$STATE_DIR/session-$sid" ]; then
    cat "$STATE_DIR/session-$sid"; return
  fi
  if [ -f "$STATE_DIR/mode" ]; then cat "$STATE_DIR/mode"; return; fi
  echo "off"
}

# c4rd_sync_healthy — return 0 if the session exists and is NOT halted. A halted session (e.g. the
# mirror was emptied/deleted → Mutagen's safety halt) must never be flushed automatically, or the
# flush could force the mass deletion through to the remote. Callers skip flush when this is false.
c4rd_sync_healthy() {
  mutagen sync list "$SESSION" 2>/dev/null | grep -i '^Status:' | grep -qi 'halt' && return 1
  return 0
}

# c4rd_flush — flush the session ONLY when healthy; warn (and protect remote) when halted.
c4rd_flush() {
  if c4rd_sync_healthy; then
    mutagen sync flush "$SESSION" >/dev/null 2>&1 || true
  else
    echo "[c4rd] 同步处于 halt(镜像可能被删/清空)——跳过自动 flush 以保护远程。" >&2
    echo "       运行  '$C4RD_DIR/sync-start.sh'  从远程安全恢复本地。" >&2
  fi
}

# c4rd_map_remote_pwd [local_pwd] — map a path under MIRROR_ROOT to its REMOTE_ROOT twin.
c4rd_map_remote_pwd() {
  local p="${1:-$PWD}"
  case "$p" in
    "$MIRROR_ROOT")   printf '%s' "$REMOTE_ROOT" ;;
    "$MIRROR_ROOT"/*) printf '%s/%s' "$REMOTE_ROOT" "${p#"$MIRROR_ROOT"/}" ;;
    *)                printf '%s' "$REMOTE_ROOT" ;;  # outside mirror → remote root
  esac
}
