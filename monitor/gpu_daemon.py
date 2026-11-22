#!/usr/bin/env python3
"""Persistent NVML + NVAPI GPU telemetry poller for Conky."""

import argparse
import ctypes
import fcntl
import os
import signal
import struct
import sys
import time

NVAPI_LIB_PATH = "/usr/lib/x86_64-linux-gnu/libnvidia-api.so.1"
NVML_LIB_PATH = "libnvidia-ml.so.1"
STATS_PATH = "/tmp/conky-gpu-stats.txt"
PID_PATH = "/tmp/conky-gpu-daemon.pid"
LOCK_PATH = "/tmp/conky-gpu-daemon.lock"

NVML_TEMPERATURE_GPU = 0
NVML_CLOCK_GRAPHICS = 0
NVML_CLOCK_MEM = 2

NVAPI_INIT = 0x0150E828
NVAPI_UNLOAD = 0xD22BDD7E
NVAPI_ENUM_GPUS = 0xE5AC921F
NVAPI_THERM_INFO = 0x0BC8163D
NVAPI_THERM_STATUS = 0x65FE3AAD

I2C_SLAVE = 0x0703
I2C_SMBUS = 0x0720
I2C_SMBUS_READ = 1
I2C_SMBUS_BYTE_DATA = 2


class I2cSmbusIoctlData(ctypes.Structure):
    _fields_ = [
        ("read_write", ctypes.c_uint8),
        ("command", ctypes.c_uint8),
        ("size", ctypes.c_uint32),
        ("data", ctypes.c_void_p),
    ]


def decode_spd5118_temp(mr49, mr50):
    raw16 = (mr50 << 8) | mr49
    val = (raw16 >> 2) & 0x7FF
    if val & 0x400:
        val -= 0x800
    return val * 0.25


class Spd5118Reader:
    """Pure read-only SMBus DDR5 SPD5118 temperature reader (safe with SPD Write Disable)."""

    def __init__(self):
        self.dev_path = None
        self.addrs = []
        self.last_scan_ts = -999.0

    @staticmethod
    def _find_i801_dev():
        base = "/sys/bus/i2c/devices"
        try:
            entries = sorted(os.listdir(base))
        except OSError:
            return None
        for name in entries:
            if not name.startswith("i2c-"):
                continue
            name_file = os.path.join(base, name, "name")
            try:
                with open(name_file, "r", encoding="utf-8") as f:
                    adapter_name = f.read().strip()
                if adapter_name.startswith("SMBus I801"):
                    dev = os.path.join("/dev", name)
                    if os.path.exists(dev):
                        return dev
            except OSError:
                continue
        return None

    @staticmethod
    def _smbus_read_byte(fd, reg):
        buf = (ctypes.c_uint8 * 34)()
        req = I2cSmbusIoctlData(
            I2C_SMBUS_READ,
            reg & 0xFF,
            I2C_SMBUS_BYTE_DATA,
            ctypes.addressof(buf),
        )
        fcntl.ioctl(fd, I2C_SMBUS, req)
        return int(buf[0])

    def _discover(self, now):
        if now - self.last_scan_ts < 10.0:
            return
        self.last_scan_ts = now
        if not self.dev_path:
            self.dev_path = self._find_i801_dev()
        if not self.dev_path:
            return
        try:
            fd = os.open(self.dev_path, os.O_RDWR)
        except OSError:
            return
        found = []
        try:
            for addr in range(0x50, 0x58):
                try:
                    fcntl.ioctl(fd, I2C_SLAVE, addr)
                    mr0 = self._smbus_read_byte(fd, 0x00)
                    mr1 = self._smbus_read_byte(fd, 0x01)
                    if mr0 == 0x51 and mr1 == 0x18:
                        found.append(addr)
                except OSError:
                    continue
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
        self.addrs = found

    def read_temps(self, now):
        if not self.addrs:
            self._discover(now)
        if not self.addrs or not self.dev_path:
            return []
        try:
            fd = os.open(self.dev_path, os.O_RDWR)
        except OSError:
            self.addrs = []
            return []
        temps = []
        try:
            for addr in self.addrs:
                try:
                    fcntl.ioctl(fd, I2C_SLAVE, addr)
                    mr49 = self._smbus_read_byte(fd, 0x31)
                    mr50 = self._smbus_read_byte(fd, 0x32)
                    temp_c = decode_spd5118_temp(mr49, mr50)
                    if -20.0 < temp_c < 125.0:
                        temps.append(f"{temp_c:.1f}")
                except OSError:
                    continue
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
        return temps


class NvmlUtil(ctypes.Structure):
    _fields_ = [("gpu", ctypes.c_uint), ("memory", ctypes.c_uint)]


class NvmlMemV2(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_uint),
        ("total", ctypes.c_ulonglong),
        ("reserved", ctypes.c_ulonglong),
        ("free", ctypes.c_ulonglong),
        ("used", ctypes.c_ulonglong),
    ]


class NvmlMemV1(ctypes.Structure):
    _fields_ = [
        ("total", ctypes.c_ulonglong),
        ("free", ctypes.c_ulonglong),
        ("used", ctypes.c_ulonglong),
    ]


def read_uptime():
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            return float(f.read().split()[0])
    except Exception:
        return time.monotonic()


def parent_alive(ppid):
    if not ppid or ppid <= 1:
        return True
    try:
        os.kill(ppid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def atomic_write(path, content):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)


def acquire_singleton_lock():
    lock_fd = open(LOCK_PATH, "w", encoding="utf-8")
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        # Ask existing daemon to exit, then wait briefly for lock
        try:
            with open(PID_PATH, "r", encoding="utf-8") as pf:
                old_pid = int(pf.read().strip())
            if old_pid > 1 and old_pid != os.getpid():
                os.kill(old_pid, signal.SIGTERM)
        except Exception:
            pass
        for _ in range(30):
            try:
                fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(0.1)
        else:
            lock_fd.close()
            raise RuntimeError("Existing gpu_daemon did not release lock in time")

    atomic_write(PID_PATH, f"{os.getpid()}\n")
    return lock_fd


class GpuCollector:
    def __init__(self):
        self.nvml = None
        self.nvml_handle = None
        self.nvapi = None
        self.nvapi_handle = None
        self.nvapi_unload = None
        self.nvapi_stat_fn = None
        self.mem_ch = None
        self.spd_reader = Spd5118Reader()
        self._init_nvml()
        self._init_nvapi()

    def _init_nvml(self):
        try:
            nvml = ctypes.CDLL(NVML_LIB_PATH)
            if nvml.nvmlInit_v2() != 0:
                return
            h = ctypes.c_void_p()
            if nvml.nvmlDeviceGetHandleByIndex_v2(0, ctypes.byref(h)) != 0:
                nvml.nvmlShutdown()
                return
            self.nvml = nvml
            self.nvml_handle = h
        except Exception as e:
            print(f"[gpu_daemon] NVML init error: {e}", file=sys.stderr)

    def _init_nvapi(self):
        if not os.path.exists(NVAPI_LIB_PATH):
            return
        try:
            nvapi = ctypes.CDLL(NVAPI_LIB_PATH)
            qi = nvapi.nvapi_QueryInterface
            qi.argtypes = [ctypes.c_uint32]
            qi.restype = ctypes.c_void_p

            p_init = qi(NVAPI_INIT)
            p_enum = qi(NVAPI_ENUM_GPUS)
            p_info = qi(NVAPI_THERM_INFO)
            p_stat = qi(NVAPI_THERM_STATUS)
            p_unload = qi(NVAPI_UNLOAD)
            if not (p_init and p_enum and p_info and p_stat):
                return

            if ctypes.CFUNCTYPE(ctypes.c_int)(p_init)() != 0:
                return

            self.nvapi = nvapi
            if p_unload:
                self.nvapi_unload = ctypes.CFUNCTYPE(ctypes.c_int)(p_unload)

            handles = (ctypes.c_void_p * 64)()
            cnt = ctypes.c_uint32(0)
            enum_fn = ctypes.CFUNCTYPE(
                ctypes.c_int,
                ctypes.POINTER(ctypes.c_void_p),
                ctypes.POINTER(ctypes.c_uint32),
            )(p_enum)
            if enum_fn(handles, ctypes.byref(cnt)) != 0 or cnt.value == 0:
                return
            self.nvapi_handle = handles[0]

            buf_i = (ctypes.c_uint8 * 0xAB0)()
            ctypes.cast(buf_i, ctypes.POINTER(ctypes.c_uint32))[0] = 0x20AB0
            info_fn = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)(p_info)
            if info_fn(self.nvapi_handle, ctypes.byref(buf_i)) != 0:
                return

            raw_i = bytes(buf_i)
            mask = struct.unpack_from("<I", raw_i, 4)[0]
            mem_ch = None
            for ch in range(32):
                if not (mask & (1 << ch)):
                    continue
                off = 40 + ch * 84
                if off + 36 > len(raw_i):
                    break
                ch_type, ch_target = struct.unpack_from("<II", raw_i, off)
                flags = struct.unpack_from("<I", raw_i, off + 32)[0]
                if ch_type == 4 and (flags & 0x8000):
                    mem_ch = ch
                    break
                if mem_ch is None and ch_target == 3 and (flags & 0x8000):
                    mem_ch = ch

            if mem_ch is not None:
                self.mem_ch = mem_ch
                self.nvapi_stat_fn = ctypes.CFUNCTYPE(
                    ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p
                )(p_stat)
        except Exception as e:
            print(f"[gpu_daemon] NVAPI init error: {e}", file=sys.stderr)

    def poll(self):
        now_ts = read_uptime()
        data = {
            "name": "GPU",
            "util": "",
            "core_temp": "",
            "mem_temp": "",
            "power_w": "",
            "core_clk": "",
            "mem_clk": "",
            "vram_used_mib": "",
            "vram_total_mib": "",
            "ram_temps": "",
            "ts": f"{now_ts:.3f}",
        }

        if self.nvml and self.nvml_handle:
            h = self.nvml_handle
            name_buf = ctypes.create_string_buffer(96)
            if self.nvml.nvmlDeviceGetName(h, name_buf, 96) == 0:
                data["name"] = name_buf.value.decode("utf-8", errors="replace").strip()

            util = NvmlUtil()
            if self.nvml.nvmlDeviceGetUtilizationRates(h, ctypes.byref(util)) == 0:
                data["util"] = str(util.gpu)

            core_t = ctypes.c_uint()
            if self.nvml.nvmlDeviceGetTemperature(h, NVML_TEMPERATURE_GPU, ctypes.byref(core_t)) == 0:
                data["core_temp"] = str(core_t.value)

            pwr_mw = ctypes.c_uint()
            if self.nvml.nvmlDeviceGetPowerUsage(h, ctypes.byref(pwr_mw)) == 0:
                data["power_w"] = f"{pwr_mw.value / 1000.0:.2f}"

            clk_gr = ctypes.c_uint()
            if self.nvml.nvmlDeviceGetClockInfo(h, NVML_CLOCK_GRAPHICS, ctypes.byref(clk_gr)) == 0:
                data["core_clk"] = str(clk_gr.value)

            clk_mem = ctypes.c_uint()
            if self.nvml.nvmlDeviceGetClockInfo(h, NVML_CLOCK_MEM, ctypes.byref(clk_mem)) == 0:
                data["mem_clk"] = str(clk_mem.value)

            mem2 = NvmlMemV2()
            mem2.version = (2 << 24) | ctypes.sizeof(NvmlMemV2)
            if self.nvml.nvmlDeviceGetMemoryInfo_v2(h, ctypes.byref(mem2)) == 0:
                data["vram_used_mib"] = f"{mem2.used / 1048576.0:.1f}"
                data["vram_total_mib"] = f"{mem2.total / 1048576.0:.1f}"
            else:
                mem1 = NvmlMemV1()
                if self.nvml.nvmlDeviceGetMemoryInfo(h, ctypes.byref(mem1)) == 0:
                    data["vram_used_mib"] = f"{mem1.used / 1048576.0:.1f}"
                    data["vram_total_mib"] = f"{mem1.total / 1048576.0:.1f}"

        if self.nvapi_stat_fn and self.nvapi_handle and self.mem_ch is not None:
            buf_s = (ctypes.c_uint8 * 0xA8)()
            ctypes.cast(buf_s, ctypes.POINTER(ctypes.c_uint32))[0] = 0x200A8
            ctypes.cast(buf_s, ctypes.POINTER(ctypes.c_uint32))[1] = 1 << self.mem_ch
            if self.nvapi_stat_fn(self.nvapi_handle, ctypes.byref(buf_s)) == 0:
                t_raw = struct.unpack_from("<i", bytes(buf_s), 40 + self.mem_ch * 4)[0]
                t_c = t_raw / 256.0
                if -20.0 < t_c < 150.0:
                    data["mem_temp"] = f"{t_c:.1f}"

        try:
            ram_temps = self.spd_reader.read_temps(now_ts)
            if ram_temps:
                data["ram_temps"] = ",".join(ram_temps)
        except Exception as e:
            print(f"[gpu_daemon] SPD read error: {e}", file=sys.stderr)

        lines = [f"{k}={v}" for k, v in data.items()]
        atomic_write(STATS_PATH, "\n".join(lines) + "\n")

    def close(self):
        if self.nvapi_unload:
            try:
                self.nvapi_unload()
            except Exception:
                pass
            self.nvapi_unload = None
        if self.nvml:
            try:
                self.nvml.nvmlShutdown()
            except Exception:
                pass
            self.nvml = None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ppid", type=int, default=0)
    parser.add_argument("--interval", type=float, default=2.0)
    parser.add_argument("--oneshot", action="store_true")
    args = parser.parse_args()

    if args.oneshot:
        c = GpuCollector()
        try:
            c.poll()
        finally:
            c.close()
        return

    lock_fd = acquire_singleton_lock()
    running = True

    def handle_sig(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    collector = GpuCollector()
    try:
        while running:
            if not parent_alive(args.ppid):
                break
            try:
                collector.poll()
            except Exception as e:
                print(f"[gpu_daemon] poll error: {e}", file=sys.stderr)
            deadline = time.monotonic() + args.interval
            while running and time.monotonic() < deadline:
                if not parent_alive(args.ppid):
                    running = False
                    break
                time.sleep(min(0.4, max(0.05, deadline - time.monotonic())))
    finally:
        collector.close()
        try:
            if os.path.exists(PID_PATH):
                with open(PID_PATH, "r", encoding="utf-8") as f:
                    if f.read().strip() == str(os.getpid()):
                        os.unlink(PID_PATH)
        except Exception:
            pass
        lock_fd.close()


if __name__ == "__main__":
    main()
