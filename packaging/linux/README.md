# Conky Hardware Monitor — Linux 使用说明

## 环境依赖

- 图形桌面会话（X11，例如 Ubuntu GNOME on Xorg）
- `conky-all`（需包含 Cairo + Lua 支持）
- `python3`、`xdotool`
- `fonts-noto-cjk`（用于显示 `°`、`↓`、`↑` 与 `寿命100%`）
- NVIDIA 专有驱动（可选，用于监控 NVIDIA GPU 核心与显存指标）

Ubuntu / Debian 安装依赖：

```bash
sudo apt update
sudo apt install -y conky-all python3 xdotool fonts-noto-cjk
```

## 运行与安装

- **直接试用**：`./start.sh`
- **安装到用户目录并配置开机自启**：`./install.sh`
- **卸载用户配置与自启**：`./uninstall.sh`
- **可选开启 CPU 功耗与 DDR5 内存温度权限**：`sudo ./setup-sensors.sh`

## 交互说明

- 在监控卡片任意区域按住 **鼠标左键** 即可拖动位置；拖动范围会自动限制在当前桌面工作区内，松开后位置会自动保存至 `~/.config/conky/position.txt`。
