#!/bin/bash
# c4rd-exec.sh <base64-command> — the runner the hook rewrites commands into.
# Runs locally (inheriting Claude's $PWD), flushes sync, and forwards the command to the remote.
# Falls back to LOCAL execution (with a warning) if the remote is unreachable.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh" || exit 127

cmd="$(printf '%s' "${1:-}" | base64 -d 2>/dev/null)"
if [ -z "$cmd" ]; then echo "[c4rd] empty command" >&2; exit 2; fi

# Reachability → local fallback keeps you working when the tunnel is down.
if ! c4rd_probe; then
  echo "[c4rd] remote '$REMOTE_HOST' unreachable → running LOCALLY (mirror). Toggle: /claude4remotedev off" >&2
  bash -c "$cmd"
  exit $?
fi

remote_pwd="$(c4rd_map_remote_pwd "$PWD")"
c4rd_flush   # ensure latest edits are on the remote — but never flush a halted (deleted-mirror) session

run_remote() {
  printf '%s\ncd %q || { echo "[c4rd] remote dir missing: %s" >&2; exit 1; }\n%s\n' \
    "$REMOTE_PATH_FIX" "$remote_pwd" "$remote_pwd" "$cmd" | c4rd_ssh bash -l -s
}

if [ "$MIRROR_ROOT" = "$REMOTE_ROOT" ]; then
  # path-identity: remote paths are valid locally too → stream directly, preserve exit code
  run_remote
  exit $?
fi

# roots differ → capture, map remote paths back to local mirror paths, preserve exit code
out="$(mktemp)"; err="$(mktemp)"
run_remote >"$out" 2>"$err"; rc=$?
sed "s#$REMOTE_ROOT#$MIRROR_ROOT#g" "$out"
sed "s#$REMOTE_ROOT#$MIRROR_ROOT#g" "$err" >&2
rm -f "$out" "$err"
exit $rc
