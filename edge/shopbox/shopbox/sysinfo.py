"""gboxlinux — what kind of machine the Guard Box runs on, read from the OS
only (no network, nothing sent except the short platform / model strings the
heartbeat and pairing already carry):

  platform_name()   "linux-arm64" | "linux-x64" | "windows" | ...
  device_model()    "Raspberry Pi 4 Model B Rev 1.4", a PC's DMI name, ...
  mem_total_mb()    for the resource profile (2 GB Pi -> "lite")
  boot_id()         changes on every boot (power-cut detection)
  power_source()    mains / battery / Raspberry Pi under-voltage hints
  sd_notify()       systemd READY / WATCHDOG pings (no dependency)

Every function is best-effort and never raises.
"""
from __future__ import annotations

import os
import platform
import socket
import sys
import time
from typing import Optional

_ROOT = os.environ.get("SHOPBOX_SYSROOT", "")   # tests point this at a fake /sys + /proc


def _p(path: str) -> str:
    return _ROOT + path if _ROOT else path


def _read(path: str, limit: int = 4096) -> Optional[str]:
    try:
        with open(_p(path), "rb") as f:
            return f.read(limit).decode("utf-8", "replace").replace("\x00", "").strip()
    except OSError:
        return None


def arch() -> str:
    m = (platform.machine() or "").lower()
    if m in ("x86_64", "amd64"):
        return "x64"
    if m in ("aarch64", "arm64"):
        return "arm64"
    if m.startswith("armv7") or m == "armhf":
        return "armv7"
    return m or "unknown"


def platform_name() -> str:
    if sys.platform == "win32":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux-%s" % arch()
    return sys.platform[:16]


def device_model() -> str:
    """A short human name for the box (shown to the owner as the camera's
    device model). Never a serial number."""
    for path in ("/proc/device-tree/model", "/sys/firmware/devicetree/base/model"):
        v = _read(path)
        if v:
            return v[:60]
    vendor = _read("/sys/class/dmi/id/sys_vendor") or ""
    prod = _read("/sys/class/dmi/id/product_name") or ""
    name = (" ".join(x for x in (vendor, prod) if x and "to be filled" not in x.lower())).strip()
    if name:
        return name[:60]
    if sys.platform == "win32":
        return ("Windows PC %s" % platform.release()).strip()[:60]
    return ("%s %s" % (platform.system(), arch())).strip()[:60]


def is_raspberry_pi() -> bool:
    return "raspberry pi" in device_model().lower()


def mem_total_mb() -> Optional[int]:
    txt = _read("/proc/meminfo")
    if txt:
        for line in txt.splitlines():
            if line.startswith("MemTotal:"):
                try:
                    return int(line.split()[1]) // 1024
                except (IndexError, ValueError):
                    return None
    if sys.platform == "win32":
        try:
            import ctypes

            class MS(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong),
                            ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong),
                            ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong),
                            ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
            ms = MS()
            ms.dwLength = ctypes.sizeof(MS)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms)):
                return int(ms.ullTotalPhys // (1024 * 1024))
        except Exception:
            return None
    return None


def boot_id() -> Optional[str]:
    """Changes on every boot. Linux: the kernel's random boot_id. Windows:
    the boot time rounded to 5 minutes (GetTickCount64). SHOPBOX_BOOT_ID
    overrides it (the CI simulates a reboot inside a container this way)."""
    fake = os.environ.get("SHOPBOX_BOOT_ID")
    if fake:
        return fake[:64]
    v = _read("/proc/sys/kernel/random/boot_id")
    if v:
        return v[:64]
    bt = boot_time()
    return "bt-%d" % (int(bt) // 300) if bt else None


def boot_time() -> Optional[float]:
    """Epoch seconds the machine booted (None when unknown)."""
    fake = os.environ.get("SHOPBOX_BOOT_TIME")
    if fake:
        try:
            return float(fake)
        except ValueError:
            pass
    txt = _read("/proc/stat")
    if txt:
        for line in txt.splitlines():
            if line.startswith("btime "):
                try:
                    return float(line.split()[1])
                except (IndexError, ValueError):
                    break
    if sys.platform == "win32":
        try:
            import ctypes
            ms = ctypes.windll.kernel32.GetTickCount64()
            return time.time() - ms / 1000.0
        except Exception:
            return None
    return None


def power_source() -> dict:
    """{"ac": True|False|None, "battery_pct": int|None, "undervoltage": bool|None}

    * ac — mains present. False only when the OS really reports a power
      supply of type Mains/USB that is offline, or a battery discharging
      (laptop, UPS HAT, a USB UPS through NUT/upower is NOT read here).
      None = this machine cannot tell (most mini PCs / Pis without a UPS).
    * undervoltage — Raspberry Pi firmware says the supply is too weak NOW
      (bit 0 of get_throttled)."""
    out = {"ac": None, "battery_pct": None, "undervoltage": None}
    base = "/sys/class/power_supply"
    try:
        names = sorted(os.listdir(_p(base)))
    except OSError:
        names = []
    mains_seen = []
    for n in names:
        typ = (_read("%s/%s/type" % (base, n)) or "").lower()
        if typ in ("mains", "usb", "ups"):
            on = _read("%s/%s/online" % (base, n))
            if on in ("0", "1"):
                mains_seen.append(on == "1")
        elif typ == "battery":
            cap = _read("%s/%s/capacity" % (base, n))
            if cap and cap.isdigit():
                out["battery_pct"] = max(0, min(100, int(cap)))
            st = (_read("%s/%s/status" % (base, n)) or "").lower()
            if st == "discharging" and not mains_seen:
                out["ac"] = False
    if mains_seen:
        out["ac"] = any(mains_seen)
    thr = _read("/sys/devices/platform/soc/soc:firmware/get_throttled") or \
        _read("/sys/devices/platform/soc/soc:firmware/raspberrypi-hwmon/throttled")
    if thr:
        try:
            out["undervoltage"] = bool(int(thr, 16) & 0x1)   # sysfs prints hex
        except ValueError:
            pass
    if sys.platform == "win32" and out["ac"] is None:
        try:
            import ctypes

            class SPS(ctypes.Structure):
                _fields_ = [("ACLineStatus", ctypes.c_byte), ("BatteryFlag", ctypes.c_byte),
                            ("BatteryLifePercent", ctypes.c_byte),
                            ("SystemStatusFlag", ctypes.c_byte),
                            ("BatteryLifeTime", ctypes.c_ulong),
                            ("BatteryFullLifeTime", ctypes.c_ulong)]
            s = SPS()
            if ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(s)):
                has_batt = (s.BatteryFlag & 0x80) == 0     # 128 = no battery
                if s.ACLineStatus in (0, 1) and has_batt:
                    out["ac"] = s.ACLineStatus == 1
                if has_batt and 0 <= s.BatteryLifePercent <= 100:
                    out["battery_pct"] = int(s.BatteryLifePercent)
        except Exception:
            pass
    return out


def sd_notify(state: str) -> bool:
    """Tell systemd READY=1 / WATCHDOG=1 / STATUS=... (Type=notify units).
    No-op (False) outside systemd."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr or sys.platform == "win32":
        return False
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            s.connect(addr)
            s.sendall(state.encode("utf-8"))
        finally:
            s.close()
        return True
    except OSError:
        return False
