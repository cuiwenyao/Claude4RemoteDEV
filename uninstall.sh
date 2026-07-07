#!/bin/bash
# uninstall.sh --project <dir> [--purge] — safely remove Claude4RemoteDEV from a project.
# It ALWAYS terminates the Mutagen session FIRST, so afterwards deleting the project folder
# cannot affect the remote. Never deletes the remote. --purge also removes the local project dir.
set -uo pipefail
PROJECT="$PWD"; PURGE=0
while [ $# -gt 0 ]; do case "$1" in
  --project) PROJECT="$2"; shift 2;;
  --purge) PURGE=1; shift;;
  -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || { echo "project not found" >&2; exit 1; }
C4RD="$PROJECT/.claude/c4rd"

SESSION=""
[ -f "$C4RD/config.sh" ] && { source "$C4RD/config.sh"; }

# 1. terminate sync FIRST — critical safety step
if [ -n "${SESSION:-}" ]; then
  if mutagen sync terminate "$SESSION" 2>/dev/null; then
    echo "[c4rd] 已终止同步会话 '$SESSION' —— 之后删除本地目录不会影响远程 ✓"
  else
    echo "[c4rd] 同步会话 '$SESSION' 未在运行(或已终止)"
  fi
fi

# 2. remove the PreToolUse hook from settings.json
SETTINGS="$PROJECT/.claude/settings.json"
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  cp "$SETTINGS" "$SETTINGS.c4rd-bak" 2>/dev/null || true
  if jq 'if .hooks.PreToolUse then
           .hooks.PreToolUse |= ( map(.hooks |= map(select((.command // "") | test("c4rd/route-bash.sh") | not)))
                                  | map(select((.hooks // [] | length) > 0)) )
         else . end' "$SETTINGS" > "$SETTINGS.tmp" 2>/dev/null; then
    mv "$SETTINGS.tmp" "$SETTINGS"; echo "[c4rd] 已从 settings.json 移除 PreToolUse hook"
  else rm -f "$SETTINGS.tmp"; fi
fi

# 3. remove installed toolkit files (NOT the project code)
rm -rf "$C4RD" "$PROJECT/.claude/skills/claude4remotedev"
echo "[c4rd] 已删除 .claude/c4rd 与 skill"

echo "[c4rd] 完成。项目代码保留在 $PROJECT。"
if [ "$PURGE" = 1 ]; then
  echo "[c4rd] --purge:删除本地项目目录 $PROJECT(同步已断开,远程安全)"
  rm -rf "$PROJECT"
else
  echo "[c4rd] 如需删本地项目目录,现在可安全执行(同步已断开):rm -rf \"$PROJECT\""
fi
