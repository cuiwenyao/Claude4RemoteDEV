#!/bin/bash
# install-daemon-service.sh — make the Mutagen daemon auto-start on boot (Linux/systemd).
# Sessions persist on disk, so once the daemon is back up all syncs resume automatically.
set -uo pipefail

if ! command -v systemctl >/dev/null 2>&1; then
  echo "[c4rd] 非 systemd 系统。请把 'mutagen daemon start' 加入登录启动项;" >&2
  echo "       macOS 可用 launchd,或在 shell profile 里加 'mutagen daemon start'。" >&2
  exit 1
fi
MUTAGEN="$(command -v mutagen)" || { echo "[c4rd] 未找到 mutagen" >&2; exit 1; }
RUN_USER="$(id -un)"; USER_HOME="$HOME"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
SVC=/etc/systemd/system/mutagen.service

echo "[c4rd] 写入 systemd 服务 $SVC (user=$RUN_USER)"
$SUDO tee "$SVC" >/dev/null <<EOF
[Unit]
Description=Mutagen daemon (Claude4RemoteDEV real-time sync)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Environment=HOME=$USER_HOME
ExecStart=$MUTAGEN daemon run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
mutagen daemon stop >/dev/null 2>&1 || true          # avoid lock conflict with the manual daemon
$SUDO systemctl enable --now mutagen.service
sleep 2
if systemctl is-active --quiet mutagen.service; then
  echo "[c4rd] mutagen 守护进程已设为开机自启并运行中 ✓  (sessions 会自动恢复)"
else
  echo "[c4rd] 服务已安装,但未处于 active,请查看: systemctl status mutagen.service" >&2
fi
