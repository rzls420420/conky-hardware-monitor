#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.config/conky"
AUTOSTART_DIR="$HOME/.config/autostart"

for cmd in conky python3 xdotool; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing dependency: $cmd"
        echo "Please install: sudo apt install -y conky-all python3 xdotool fonts-noto-cjk"
        exit 1
    fi
done

mkdir -p "$TARGET_DIR" "$AUTOSTART_DIR"

if [ -f "$TARGET_DIR/dashboard.conf" ] && [ ! -f "$TARGET_DIR/dashboard.conf.bak" ]; then
    cp "$TARGET_DIR/dashboard.conf" "$TARGET_DIR/dashboard.conf.bak"
fi

cp "$SCRIPT_DIR/monitor/dashboard.conf" "$TARGET_DIR/dashboard.conf"
cp "$SCRIPT_DIR/monitor/dashboard.lua" "$TARGET_DIR/dashboard.lua"
cp "$SCRIPT_DIR/monitor/gpu_daemon.py" "$TARGET_DIR/gpu_daemon.py"
cp "$SCRIPT_DIR/monitor/drag_helper.py" "$TARGET_DIR/drag_helper.py"
chmod +x "$TARGET_DIR/gpu_daemon.py" "$TARGET_DIR/drag_helper.py"

cat > "$AUTOSTART_DIR/conky-dashboard.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Conky Hardware Monitor
Comment=Frosted-glass desktop hardware monitor
Exec=/usr/bin/conky -c $TARGET_DIR/dashboard.conf
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

"$SCRIPT_DIR/start.sh"
echo "Installed to $TARGET_DIR and enabled autostart."
echo "Optional: run 'sudo $SCRIPT_DIR/setup-sensors.sh' to unlock CPU power and DDR5 RAM temperatures."
