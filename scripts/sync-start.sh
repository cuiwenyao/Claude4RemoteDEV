#!/bin/bash
# sync-start.sh [--force] — create/ensure the Mutagen session for this project.
# Sync scope is read from <MIRROR_ROOT>/.gitignore (single source of truth). --force rebuilds it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh" || exit 1

mutagen daemon start >/dev/null 2>&1 || true

GI="$MIRROR_ROOT/.gitignore"
args=()
if [ -f "$GI" ]; then
  while IFS= read -r line; do args+=(--ignore="$line"); done \
    < <(sed -E 's/\r$//' "$GI" | grep -vE '^[[:space:]]*(#|$)')
fi

exists=0
mutagen sync list "$SESSION" 2>/dev/null | grep -q "Name: $SESSION" && exists=1

if [ "${1:-}" = "--force" ] && [ "$exists" = 1 ]; then
  mutagen sync terminate "$SESSION" >/dev/null 2>&1 || true
  exists=0
fi

if [ "$exists" = 1 ]; then
  echo "[c4rd] sync '$SESSION' already running (use 'resync' to rebuild scope from .gitignore)"
  mutagen sync flush "$SESSION" >/dev/null 2>&1 || true
else
  echo "[c4rd] creating sync '$SESSION' (${#args[@]} ignore rules from .gitignore)"
  mutagen sync create --name="$SESSION" --ignore-vcs --symlink-mode=ignore \
    "${args[@]}" "$MIRROR_ROOT" "$REMOTE_ENDPOINT"
  mutagen sync flush "$SESSION" >/dev/null 2>&1 || true
fi
mutagen sync list "$SESSION" 2>/dev/null | grep -E 'Status|files|directories' || true
