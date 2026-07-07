#!/bin/bash
# smoke.sh --project <dir> — script-level tests for an installed Claude4RemoteDEV project.
# Checks the hook's routing decisions and (if the remote is reachable) real remote execution.
set -uo pipefail
PROJECT=""
while [ $# -gt 0 ]; do case "$1" in --project) PROJECT="$2"; shift 2;; *) shift;; esac; done
[ -n "$PROJECT" ] || { echo "usage: smoke.sh --project <dir>"; exit 2; }
C4RD="$PROJECT/.claude/c4rd"
[ -d "$C4RD" ] || { echo "not installed: $C4RD"; exit 1; }

pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
hook(){ printf '%s' "$1" | bash "$C4RD/route-bash.sh"; }

orig_mode="$(cat "$C4RD/state/mode" 2>/dev/null || echo off)"

echo "== 1. routing OFF → passthrough (empty output) =="
echo off > "$C4RD/state/mode"
out="$(hook '{"tool_input":{"command":"echo hi"},"session_id":"t"}')"
[ -z "$out" ] && ok "off → no rewrite" || no "off should not rewrite (got: $out)"

echo "== 2. routing ON → command rewritten to c4rd-exec.sh =="
echo on > "$C4RD/state/mode"
out="$(hook '{"tool_input":{"command":"echo hi"},"session_id":"t"}')"
echo "$out" | grep -q 'c4rd-exec.sh' && ok "on → rewritten" || no "on should rewrite (got: $out)"
echo "$out" | jq -e '.hookSpecificOutput.updatedInput.command' >/dev/null 2>&1 \
  && ok "output is valid hook JSON" || no "invalid hook JSON"

echo "== 3. ON but bypassed commands stay local =="
for c in "cpull logs/x" "mutagen sync list" ".claude/c4rd/resync" "cd src" "C4RD_LOCAL ls"; do
  out="$(hook "$(jq -nc --arg c "$c" '{tool_input:{command:$c},session_id:"t"}')")"
  if [ "$c" = "C4RD_LOCAL ls" ]; then
    echo "$out" | jq -e '.hookSpecificOutput.updatedInput.command=="ls"' >/dev/null 2>&1 \
      && ok "C4RD_LOCAL strips prefix → local 'ls'" || no "C4RD_LOCAL handling ($out)"
  else
    [ -z "$out" ] && ok "bypass: $c" || no "should bypass: $c (got: $out)"
  fi
done

echo "== 4. compound cd IS routed =="
out="$(hook '{"tool_input":{"command":"cd src && ls"},"session_id":"t"}')"
echo "$out" | grep -q 'c4rd-exec.sh' && ok "cd+&& routed remote" || no "compound cd should route ($out)"

echo "== 5. real remote execution (if reachable) =="
# shellcheck disable=SC1091
source "$C4RD/lib.sh"
if c4rd_probe; then
  rhost="$(c4rd_ssh hostname 2>/dev/null)"
  b64="$(printf 'hostname' | base64 | tr -d '\n')"
  ehost="$(bash "$C4RD/c4rd-exec.sh" "$b64" 2>/dev/null)"
  [ -n "$ehost" ] && [ "$ehost" = "$rhost" ] && [ "$ehost" != "$(hostname)" ] \
    && ok "c4rd-exec ran on remote ($ehost)" || no "remote exec mismatch (remote=$rhost exec=$ehost local=$(hostname))"
else
  echo "  SKIP: remote not reachable"
fi

echo "$orig_mode" > "$C4RD/state/mode"   # restore
echo; echo "== result: $pass passed, $fail failed =="
[ "$fail" = 0 ]
