#!/bin/bash
# route-bash.sh — Claude Code PreToolUse(Bash) hook.
# Reads the hook JSON on stdin. When remote routing is ON, rewrites the command to run on the
# remote server by returning hookSpecificOutput.updatedInput.command. Otherwise emits nothing
# (command runs locally, unchanged). Must NEVER break Claude's Bash tool: any error → passthrough.

set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT="$(cat)"

# Fail-safe passthrough helper: emit nothing → Claude runs the original command unchanged.
passthrough() { exit 0; }

# jq is required to parse the hook payload; without it, passthrough.
command -v jq >/dev/null 2>&1 || passthrough
# shellcheck disable=SC1091
source "$HERE/lib.sh" 2>/dev/null || passthrough

cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$cmd" ] || passthrough

# routing off → local passthrough
[ "$(c4rd_mode "$sid")" = "on" ] || passthrough

# --- bypass rules: commands that must run LOCALLY even when routing is on ---
trimmed="${cmd#"${cmd%%[![:space:]]*}"}"   # left-trim
case "$trimmed" in
  # c4rd's own machinery + manual helpers (they run locally and ssh internally)
  cpull*|resync*|mutagen*|sync-start*|sync-stop*|sync-status*) passthrough ;;
  *"c4rd-exec.sh "*|*".claude/c4rd/"*) passthrough ;;
  # explicit local escape hatch: prefix a command with `C4RD_LOCAL ` to force local
  "C4RD_LOCAL "*) exec_local="${trimmed#C4RD_LOCAL }"
     printf '%s' "$INPUT" | jq --arg c "$exec_local" \
       '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:(.tool_input + {command:$c})}}'
     exit 0 ;;
esac
# pure `cd ...` (no chaining) must run locally so Claude's persistent shell cwd tracks correctly
case "$trimmed" in
  cd|cd\ *)
    case "$trimmed" in *"&&"*|*";"*|*"|"*) : ;;  # compound cd → route remotely
    *) passthrough ;; esac ;;
esac

# --- rewrite: run on remote via base64-encoded payload (dodges all quoting) ---
b64="$(printf '%s' "$cmd" | base64 | tr -d '\n')"
newcmd="$HERE/c4rd-exec.sh $b64"

printf '%s' "$INPUT" | jq --arg c "$newcmd" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:(.tool_input + {command:$c})}}'
exit 0
