#!/bin/bash
# sync-start.sh [--force] — create/ensure the Mutagen session for this project.
# Sync scope is read from <MIRROR_ROOT>/.gitignore (single source of truth). --force rebuilds it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh" || exit 1

mutagen daemon start >/dev/null 2>&1 || true

GI="$MIRROR_ROOT/.gitignore"

# Resolve the ignore source. Prefer the local mirror's .gitignore; but when the mirror is a fresh
# empty dir and the REMOTE is an existing project, the local .gitignore doesn't exist yet — in that
# case seed it from the REMOTE's .gitignore FIRST, so we don't try to pull huge remote dirs.
if [ ! -s "$GI" ]; then
  if remote_gi="$(c4rd_ssh cat "$REMOTE_ROOT/.gitignore" 2>/dev/null)" && [ -n "$remote_gi" ]; then
    printf '%s\n' "$remote_gi" > "$GI"
    echo "[c4rd] 本地无 .gitignore → 已从远程 $REMOTE_ROOT/.gitignore 拉取作为同步范围"
  fi
fi

args=()
if [ -s "$GI" ]; then
  while IFS= read -r line; do args+=(--ignore="$line"); done \
    < <(sed -E 's/\r$//' "$GI" | grep -vE '^[[:space:]]*(#|$)')
fi

# SAFETY: refuse to create a wide-open (0-ignore) sync — it could pull huge remote dirs and fill the disk.
if [ "${#args[@]}" -eq 0 ] && [ "${C4RD_ALLOW_EMPTY_IGNORES:-0}" != "1" ]; then
  echo "[c4rd] 拒绝创建同步:两端都没有 .gitignore(0 条忽略规则)。" >&2
  echo "       全量同步可能把远程的大目录(数据/模型)拉爆本机磁盘。" >&2
  echo "       请在 $GI 里列出要排除的大目录(如 /data/  /.venv*/  /logs/  *.pt  *.ckpt),再重试;" >&2
  echo "       确知安全时可用:  C4RD_ALLOW_EMPTY_IGNORES=1 $0 ${1:-}" >&2
  exit 1
fi

exists=0; halted=0; mirror_empty=0
mutagen sync list "$SESSION" 2>/dev/null | grep -q "Name: $SESSION" && exists=1
mutagen sync list "$SESSION" 2>/dev/null | grep -i '^Status:' | grep -qi 'halt' && halted=1
{ [ ! -d "$MIRROR_ROOT" ] || [ -z "$(ls -A "$MIRROR_ROOT" 2>/dev/null)" ]; } && mirror_empty=1

# Rebuild fresh when: --force, the session halted, OR a session exists but the local mirror is
# empty/missing (i.e. the folder was deleted). Rebuilding is the SAFE RECOVERY path:
#  - we terminate the stale session FIRST (stops its watcher, so a recreated-empty dir can't be
#    scanned-and-propagated as a mass deletion), THEN
#  - create a fresh two-way-safe session; its initial sync repopulates the empty local mirror FROM
#    the remote and never deletes remote content.
if [ "$exists" = 1 ] && { [ "${1:-}" = "--force" ] || [ "$halted" = 1 ] || [ "$mirror_empty" = 1 ]; }; then
  if [ "$halted" = 1 ] || [ "$mirror_empty" = 1 ]; then
    echo "[c4rd] 本地镜像为空/缺失且已有会话(通常是目录被删)→ 安全重建:先终止旧会话,再从远程恢复本地,远程不受影响"
  fi
  mutagen sync terminate "$SESSION" >/dev/null 2>&1 || true
  exists=0
fi

if [ "$exists" = 1 ]; then
  echo "[c4rd] sync '$SESSION' already running (use 'resync' to rebuild scope from .gitignore)"
  mutagen sync flush "$SESSION" >/dev/null 2>&1 || true
else
  mkdir -p "$MIRROR_ROOT"
  echo "[c4rd] creating sync '$SESSION' (${#args[@]} ignore rules from .gitignore)"
  # -m two-way-safe is pinned on purpose: it gives the "Halted due to root deletion" protection,
  # so deleting the whole local project folder never wipes the remote.
  mutagen sync create --name="$SESSION" -m two-way-safe --ignore-vcs --symlink-mode=ignore \
    "${args[@]}" "$MIRROR_ROOT" "$REMOTE_ENDPOINT"
  mutagen sync flush "$SESSION" >/dev/null 2>&1 || true
fi
mutagen sync list "$SESSION" 2>/dev/null | grep -E 'Status|files|directories' || true
