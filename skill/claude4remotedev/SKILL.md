---
name: claude4remotedev
description: Manage remote-execution offload for this project — toggle whether Claude's Bash commands run on the remote GPU/dev server, and show sync status. Use when the user asks to turn remote mode on/off, check remote/sync status, run something on the remote, or read remote results. Trigger words: remote on, remote off, c4rd, offload, remote status, run on server, sync status.
argument-hint: "[on|off|status]"
allowed-tools: Bash, Read
---

# Claude4RemoteDEV — remote execution control

This project is wired so that (when routing is ON) every command you run with the Bash tool is
transparently executed on a remote server, while files stay in real-time two-way sync (Mutagen).
Your Read/Edit/Grep/Glob keep operating on the local mirror (fast); only Bash is forwarded.

## Current status
!`bash .claude/c4rd/sync-status.sh 2>/dev/null || echo "not configured — run setup.sh"`

## What to do with the argument: `$ARGUMENTS`

- **on** → run `echo on > .claude/c4rd/state/mode`, then tell the user remote execution is ON
  (bash now runs on the remote; takes effect on the very next command, no restart).
- **off** → run `echo off > .claude/c4rd/state/mode`, then tell the user it's back to LOCAL execution.
- **status** or empty → just report the "Current status" block above; do not change anything.

(The toggle is a plain file, so it survives across your Bash calls where env vars would not.)

## How to work in this project (once ON)

- **Edit code normally** in the local mirror — changes sync to the remote within ~1–2s. Before each
  forwarded command the sync is flushed, so the remote never runs stale code.
- **Just run commands normally** (`nvidia-smi`, `python train.py`, `pytest`, `git status`) — they
  execute on the remote automatically. Combine multi-step work in one command (`cd sub && make`),
  because each Bash call is an independent remote shell (no persisted env between calls).
- **Long jobs** must be backgrounded on the remote so they survive and don't block:
  `tmux new -d -s job 'python train.py 2>&1 | tee logs/run.log'`, then `tmux ls`, `tail -n 80 logs/run.log`.
- **Reading remote-only results**: big/generated dirs (data, logs, checkpoints) are excluded from sync
  by `.gitignore`, so they are NOT on the local mirror. Fetch a specific one with
  `.claude/c4rd/cpull <relpath>` (e.g. `.claude/c4rd/cpull logs/run.log`), then Read it locally.
- **Changing sync scope**: edit `.gitignore` (single source of truth for git AND sync), then run
  `.claude/c4rd/resync`. Add any new large output dir to `.gitignore` first, or it will flow to the
  local machine and can fill the disk.
- **Fallback**: if the remote is unreachable a forwarded command auto-runs locally with a warning.
- **Force one command local** while ON: prefix it with `C4RD_LOCAL ` (e.g. `C4RD_LOCAL ls`).
