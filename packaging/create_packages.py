#!/usr/bin/env python3
"""Create Linux (.tar.gz) and Debian/Ubuntu (.deb) release packages in dist/."""

import io
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKG_NAME = "conky-hardware-monitor"
VERSION = "1.0.0"

LAUNCHER_SCRIPT = """#!/bin/bash
set -euo pipefail

SHARE_DIR="/usr/share/conky-hardware-monitor"
CONF_PATH="$SHARE_DIR/dashboard.conf"
AUTOSTART_FILE="$HOME/.config/autostart/conky-hardware-monitor.desktop"

case "${1:-}" in
    --stop)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --user stop conky-dashboard.service 2>/dev/null || true
        fi
        pkill -f "conky -c .*dashboard\\.conf" 2>/dev/null || true
        echo "Stopped Conky Hardware Monitor."
        exit 0
        ;;
    --install-autostart)
        mkdir -p "$HOME/.config/autostart"
        cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Conky Hardware Monitor
Comment=Frosted-glass desktop hardware monitor
Exec=/usr/bin/conky -c $CONF_PATH
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
        echo "Enabled autostart at $AUTOSTART_FILE"
        exit 0
        ;;
    --remove-autostart)
        rm -f "$AUTOSTART_FILE"
        echo "Removed autostart entry."
        exit 0
        ;;
    --setup-sensors)
        exec "$SHARE_DIR/setup-sensors.sh"
        ;;
    --help|-h)
        echo "Usage: conky-hardware-monitor [--stop|--install-autostart|--remove-autostart|--setup-sensors]"
        exit 0
        ;;
esac

pkill -f "conky -c .*dashboard\\.conf" 2>/dev/null || true
sleep 0.3

if command -v systemd-run >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    systemctl --user stop conky-dashboard.service 2>/dev/null || true
    exec systemd-run --user --unit=conky-dashboard --collect /usr/bin/conky -c "$CONF_PATH"
else
    nohup /usr/bin/conky -c "$CONF_PATH" >/tmp/conky-dashboard.log 2>&1 </dev/null &
    echo "Started Conky Hardware Monitor (PID $!)."
fi
"""

DESKTOP_ENTRY = """[Desktop Entry]
Type=Application
Name=Conky Hardware Monitor
Name[zh_CN]=桌面硬件监控
Comment=Frosted-glass Conky desktop hardware monitor
Exec=/usr/bin/conky-hardware-monitor
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
"""

DEBIAN_CONTROL = f"""Package: {PKG_NAME}
Version: {VERSION}
Section: utils
Priority: optional
Architecture: all
Maintainer: rzls420420 <rzls420420@users.noreply.github.com>
Depends: conky-all, python3, xdotool
Recommends: fonts-noto-cjk
Description: Frosted-glass Conky desktop hardware monitor for Linux (X11)
 Displays CPU, NVIDIA GPU (including NVAPI memory temperature and VRAM clock),
 DDR5 RAM temperatures (via hwmon or read-only SMBus), network speeds,
 NVMe disk temperatures/SMART health/I/O, and battery stats with left-click drag.
"""

DEBIAN_POSTINST = """#!/bin/sh
set -e
echo "Installed conky-hardware-monitor."
echo "Run 'conky-hardware-monitor' to start, or 'sudo conky-hardware-monitor --setup-sensors' to unlock CPU power and DDR5 RAM temps."
exit 0
"""


def build_tarball(dest_dir: Path) -> Path:
    tar_path = dest_dir / f"{PKG_NAME}-v{VERSION}-linux.tar.gz"
    prefix = f"{PKG_NAME}-linux"

    files = []
    for p in sorted((ROOT / "packaging" / "linux").iterdir()):
        if p.is_file():
            arc_name = "docs/LINUX.md" if p.name == "README.md" else p.name
            files.append((arc_name, p, 0o755 if p.suffix == ".sh" else 0o644))
    for p in sorted((ROOT / "monitor").iterdir()):
        if p.is_file():
            mode = 0o755 if p.suffix == ".py" else 0o644
            files.append((f"monitor/{p.name}", p, mode))
    for doc_name in ("README.md", "NOTICE.md", "LICENSE"):
        p = ROOT / doc_name
        if p.is_file():
            files.append((doc_name, p, 0o644))
    preview = ROOT / "docs" / "preview.png"
    if preview.is_file():
        files.append(("docs/preview.png", preview, 0o644))

    with tarfile.open(tar_path, "w:gz", compresslevel=9) as tf:
        for rel, src, mode in files:
            payload = src.read_bytes()
            info = tf.gettarinfo(str(src), arcname=f"{prefix}/{rel}")
            info.size = len(payload)
            info.mode = mode
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            tf.addfile(info, io.BytesIO(payload))
    return tar_path


def build_deb(dest_dir: Path) -> Path:
    deb_path = dest_dir / f"{PKG_NAME}_{VERSION}_all.deb"
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp) / f"{PKG_NAME}_{VERSION}_all"
        debian_dir = stage / "DEBIAN"
        share_dir = stage / "usr" / "share" / PKG_NAME
        bin_dir = stage / "usr" / "bin"
        apps_dir = stage / "usr" / "share" / "applications"
        doc_dir = stage / "usr" / "share" / "doc" / PKG_NAME

        for d in (debian_dir, share_dir, bin_dir, apps_dir, doc_dir):
            d.mkdir(parents=True, exist_ok=True)

        (debian_dir / "control").write_text(DEBIAN_CONTROL, encoding="utf-8")
        postinst = debian_dir / "postinst"
        postinst.write_text(DEBIAN_POSTINST, encoding="utf-8")
        postinst.chmod(0o755)

        for p in sorted((ROOT / "monitor").iterdir()):
            if p.is_file():
                dst = share_dir / p.name
                shutil.copy2(p, dst)
                dst.chmod(0o755 if p.suffix == ".py" else 0o644)

        setup_sh = ROOT / "packaging" / "linux" / "setup-sensors.sh"
        dst_setup = share_dir / "setup-sensors.sh"
        shutil.copy2(setup_sh, dst_setup)
        dst_setup.chmod(0o755)

        launcher = bin_dir / PKG_NAME
        launcher.write_text(LAUNCHER_SCRIPT, encoding="utf-8")
        launcher.chmod(0o755)

        desktop = apps_dir / f"{PKG_NAME}.desktop"
        desktop.write_text(DESKTOP_ENTRY, encoding="utf-8")
        desktop.chmod(0o644)

        shutil.copy2(ROOT / "README.md", doc_dir / "README.md")
        shutil.copy2(ROOT / "NOTICE.md", doc_dir / "NOTICE.md")
        shutil.copy2(ROOT / "LICENSE", doc_dir / "copyright")
        for f in doc_dir.iterdir():
            f.chmod(0o644)

        subprocess.run(
            ["dpkg-deb", "--build", "--root-owner-group", str(stage), str(deb_path)],
            check=True,
        )
    return deb_path


def main():
    dest = ROOT / "dist"
    dest.mkdir(exist_ok=True)
    tar_path = build_tarball(dest)
    deb_path = build_deb(dest)
    print(tar_path)
    print(deb_path)


if __name__ == "__main__":
    main()
