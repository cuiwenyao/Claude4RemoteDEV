#!/bin/bash
# sync-stop.sh — terminate this project's Mutagen session (files on both sides are untouched).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh" || exit 1
mutagen sync terminate "$SESSION" 2>/dev/null && echo "[c4rd] sync '$SESSION' stopped" \
  || echo "[c4rd] no active sync '$SESSION'"
