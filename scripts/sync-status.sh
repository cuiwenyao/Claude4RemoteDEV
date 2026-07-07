#!/bin/bash
# sync-status.sh — one-glance status: routing mode, remote reachability, sync state.
# Used by the /claude4remotedev skill to inject live status.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh" || exit 1

echo "routing mode : $(c4rd_mode "${CLAUDE_SESSION_ID:-}")   (on = bash runs on remote)"
echo "remote       : $REMOTE_ALIAS ($REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT)"
echo "remote dir   : $REMOTE_ROOT"
echo "local mirror : $MIRROR_ROOT"
if c4rd_probe; then echo "reachable    : yes"; else echo "reachable    : NO (commands fall back to local)"; fi
echo "-- mutagen sync '$SESSION' --"
mutagen sync list "$SESSION" 2>/dev/null | grep -E 'Status|Connected|files|directories|conflicts' \
  || echo "  (no sync session; run sync-start)"
