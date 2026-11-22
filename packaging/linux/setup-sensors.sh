#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

TARGET_USER="${SUDO_USER:-${USER:-}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "Cannot determine non-root target user; set SUDO_USER=<username>."
    exit 1
fi

# 1. Allow user read access to Intel RAPL CPU package energy counter
cat > /etc/tmpfiles.d/rapl-read.conf <<'EOF'
z /sys/class/powercap/intel-rapl:0/energy_uj 0444 root root -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/rapl-read.conf || true

# 2. Load DDR5 SPD5118 driver and grant read-only SMBus access to the user
modprobe spd5118 2>/dev/null || true
echo spd5118 > /etc/modules-load.d/spd5118.conf

cat > /etc/udev/rules.d/99-smbus-ram-temp.rules <<EOF
SUBSYSTEM=="i2c-dev", ATTR{name}=="SMBus I801*", MODE="0660", GROUP="$TARGET_USER"
EOF
udevadm control --reload-rules
udevadm trigger --subsystem-match=i2c-dev

echo "Configured Intel RAPL and SMBus I801 access for user '$TARGET_USER'."
