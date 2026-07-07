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

# c4rd_map_remote_pwd [local_pwd] — map a path under MIRROR_ROOT to its REMOTE_ROOT twin.
c4rd_map_remote_pwd() {
  local p="${1:-$PWD}"
  case "$p" in
    "$MIRROR_ROOT")   printf '%s' "$REMOTE_ROOT" ;;
    "$MIRROR_ROOT"/*) printf '%s/%s' "$REMOTE_ROOT" "${p#"$MIRROR_ROOT"/}" ;;
    *)                printf '%s' "$REMOTE_ROOT" ;;  # outside mirror → remote root
  esac
}
