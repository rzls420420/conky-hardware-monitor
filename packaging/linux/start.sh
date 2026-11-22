#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_PATH="$SCRIPT_DIR/monitor/dashboard.conf"
if [ ! -f "$CONF_PATH" ]; then
    CONF_PATH="$HOME/.config/conky/dashboard.conf"
fi

pkill -f "conky -c .*dashboard\.conf" 2>/dev/null || true
sleep 0.3

if command -v systemd-run >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    systemctl --user stop conky-dashboard.service 2>/dev/null || true
    systemd-run --user --unit=conky-dashboard --collect /usr/bin/conky -c "$CONF_PATH"
    echo "Started conky-dashboard.service (independent systemd --user service)."
else
    nohup /usr/bin/conky -c "$CONF_PATH" >/tmp/conky-dashboard.log 2>&1 </dev/null &
    echo "Started conky in background (PID $!)."
fi
