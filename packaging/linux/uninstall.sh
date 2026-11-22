#!/bin/bash
set -euo pipefail

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop conky-dashboard.service 2>/dev/null || true
fi
pkill -f "conky -c .*dashboard\.conf" 2>/dev/null || true

rm -f "$HOME/.config/autostart/conky-dashboard.desktop"
rm -f "$HOME/.config/conky/dashboard.conf" \
      "$HOME/.config/conky/dashboard.lua" \
      "$HOME/.config/conky/gpu_daemon.py" \
      "$HOME/.config/conky/drag_helper.py" \
      "$HOME/.config/conky/position.txt"

echo "Uninstalled Conky Hardware Monitor user files."
