# 引用、参考与许可说明

- 本项目全部原创代码（Lua 渲染脚本、Python 守护进程与拖拽脚本、打包与安装脚本）采用 **MIT 协议** 发布。
- **界面布局与视觉风格参考**：参考用户提供的 Windows 桌面硬件监控悬浮窗截图（极简透明玻璃卡片、右侧大号核心温度、分栏参数与细进度条样式），在 Linux X11 下基于 Conky + Cairo 矢量绘制重新实现，并增加了半透明钢蓝磨砂玻璃圆角底框与左键桌面拖动定位。
- **NVIDIA 显存温度读取参考**：借鉴开源 Linux GPU 工具社区（如 [LACT](https://github.com/ilya-zlobintsev/LACT)）通过 NVIDIA Linux NVAPI（`libnvidia-api.so.1` 的 `nvapi_QueryInterface` 私有热通道查询 `0x0BC8163D` / `0x65FE3AAD`）读取显存温度的技术路线，解决 `nvidia-smi` / NVML 在 GeForce RTX 50 系列上不返回显存温度的问题。
- **DDR5 内存温度解码参考**：参考 Linux 内核驱动 [`drivers/hwmon/spd5118.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/hwmon/spd5118.c) 与 JEDEC JESD300-5（SPD5118）寄存器规范（器件识别 `MR0:MR1 = 0x5118`、温度寄存器 `MR49:MR50 = 0x31:0x32` 的 11 位补码 `0.25°C` 解码逻辑），采用纯只读 SMBus ioctl 读取，避免触发部分主板 BIOS `SPD Write Disable` 导致的内核绑定跳过或休眠唤醒异常。
- **打包发布结构参考**：参考同作者项目 [rzls420420/gemini-desktop-pet](https://github.com/rzls420420/gemini-desktop-pet) 与 [rzls420420/codex-desktop-pet](https://github.com/rzls420420/codex-desktop-pet) 的 `packaging/linux/`、`dist/` 与文档组织形式。
