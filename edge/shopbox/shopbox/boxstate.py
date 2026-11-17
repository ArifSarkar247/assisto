"""gboxlinux — power-cut and internet-down events of the Guard Box.

Bangladesh shops lose power (load-shedding) and internet many times a week;
the owner wants to KNOW, in plain words, afterwards:

  power_back  "power returned after X minutes (from 14:05 to 14:52)"
              * after a reboot: the box was running, did NOT stop cleanly and
                the machine booted again (the kernel boot id changed) ->
                the box was dead from its last "alive" stamp until the boot;
              * live, on a box with a UPS / battery the OS can read: mains
                went away (power_cut is sent at once while the battery holds)
                and came back.
  power_cut   sent at once, only when the OS really reports "on battery".
  net_back    "internet was down from 14:05 to 14:40; 3 alerts from that
              time follow" — alerts made offline wait on disk (Outbox) and go
              out on reconnect with the time they really happened.

Events wait in a small file (box_events.json) until the server confirms
them, so a power cut during an internet outage still arrives. Times are epoch
seconds; a "to" left as None for a reboot is filled at SEND time from the boot
clock (a Raspberry Pi has no real-time clock: right after a power cut its time
is wrong until it reaches the internet).
Nothing here raises into the caller.
"""
from __future__ import annotations

import json
import logging
import os
import threading
import time
import uuid
from typing import Callable, List, Optional

from . import paths, sysinfo

log = logging.getLogger(__name__)

KINDS = ("power_back", "power_cut", "net_back")
NET_MIN_DOWN_S = 180.0       # shorter blips are not worth a notification
MAX_EVENTS = 30
MAX_AGE_S = 7 * 86400
ALIVE_EVERY_S = 60.0


def _atomic_write(path: str, data: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
        f.flush()
        try:
            os.fsync(f.fileno())    # the next write may be the last before the power dies
        except OSError:
            pass
    os.replace(tmp, path)


def _read_json(path: str) -> Optional[dict]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


class BoxEventQueue:
    """Persistent, bounded list of box events waiting for the server."""

    def __init__(self, path: Optional[str] = None, clock: Callable[[], float] = time.time,
                 boot_time: Callable[[], Optional[float]] = sysinfo.boot_time,
                 boot_id: Callable[[], Optional[str]] = sysinfo.boot_id):
        self.path = path or paths.path("box_events.json")
        self.clock = clock
        self.boot_time = boot_time
        self.boot_id = boot_id
        self._lock = threading.Lock()

    def _load(self) -> List[dict]:
        d = _read_json(self.path) or {}
        rows = d.get("events") if isinstance(d.get("events"), list) else []
        return [r for r in rows if isinstance(r, dict) and r.get("kind") in KINDS]

    def _save(self, rows: List[dict]) -> None:
        try:
            _atomic_write(self.path, {"events": rows})
        except OSError:
            log.warning("could not save box events")

    def add(self, kind: str, start: float, end: Optional[float] = None, **extra) -> dict:
        ev = {"id": uuid.uuid4().hex[:12], "kind": kind, "from": round(float(start), 1),
              "to": None if end is None else round(float(end), 1)}
        if end is None and kind == "power_back":
            ev["to_boot"] = self.boot_id()       # filled from the boot clock at send time
        for k, v in extra.items():
            if isinstance(v, (bool, int, float, str)) or v is None:
                ev[k] = v
        with self._lock:
            rows = self._load()
            rows.append(ev)
            now = self.clock()
            rows = [r for r in rows if now - float(r.get("from") or now) <= MAX_AGE_S]
            self._save(rows[-MAX_EVENTS:])
        log.info("box event queued: %s", kind)
        return ev

    def pending(self) -> List[dict]:
        """Events ready to send (wire form: id, kind, from, to, extras)."""
        out = []
        with self._lock:
            rows = self._load()
        cur_boot = self.boot_id()
        for r in rows:
            r = dict(r)
            tb = r.pop("to_boot", None)
            if r.get("to") is None and r["kind"] == "power_back":
                bt = self.boot_time() if tb and tb == cur_boot else None
                # no boot clock (or another boot since): the best honest
                # bound we have is "it was back by the time we started"
                r["to"] = round(bt, 1) if bt else r.get("started")
                if r["to"] is None:
                    continue
                if r["to"] < r["from"]:
                    r["to"] = r["from"]          # clock not synced yet: never negative
            out.append(r)
        return out

    def ack(self, ids) -> None:
        ids = {str(i) for i in ids or []}
        if not ids:
            return
        with self._lock:
            rows = [r for r in self._load() if str(r.get("id")) not in ids]
            self._save(rows)

    def __len__(self) -> int:
        with self._lock:
            return len(self._load())


class RunMarker:
    """A stamp file written every minute while the box runs; on a clean stop
    it says so. Read at the next start to tell a power cut from a restart."""

    def __init__(self, queue: BoxEventQueue, path: Optional[str] = None,
                 clock: Callable[[], float] = time.time,
                 boot_id: Callable[[], Optional[str]] = sysinfo.boot_id,
                 boot_time: Callable[[], Optional[float]] = sysinfo.boot_time,
                 power: Callable[[], dict] = sysinfo.power_source):
        self.queue = queue
        self.path = path or paths.path("run_marker.json")
        self.clock = clock
        self.boot_id = boot_id
        self.boot_time = boot_time
        self.power = power
        self._last_touch = 0.0
        self.started_at: Optional[float] = None

    def _rebooted(self, prev: dict, cur_id: Optional[str]) -> bool:
        pid = prev.get("boot_id")
        if pid and cur_id and not str(pid).startswith("bt-") and not cur_id.startswith("bt-"):
            return pid != cur_id
        pbt, cbt = prev.get("boot_time"), self.boot_time()
        try:
            return abs(float(pbt) - float(cbt)) > 120
        except (TypeError, ValueError):
            return bool(pid and cur_id and pid != cur_id)

    def start(self) -> Optional[dict]:
        """-> the power_back event queued for the previous run, or None."""
        now = self.clock()
        self.started_at = now
        prev = _read_json(self.path)
        cur_id = self.boot_id()
        ev = None
        if prev and not prev.get("clean") and self._rebooted(prev, cur_id):
            try:
                alive = float(prev.get("alive"))
            except (TypeError, ValueError):
                alive = None
            if alive is not None and alive <= now + 60:
                ev = self.queue.add("power_back", alive, None, started=round(now, 1),
                                    after_reboot=True,
                                    low_power_stop=bool(prev.get("low_power_stop")))
        elif prev and not prev.get("clean"):
            log.info("previous run ended without a clean stop (same boot: a restart, not a power cut)")
        self._write(now, clean=False)
        return ev

    def _write(self, now: float, clean: bool, **extra) -> None:
        d = {"boot_id": self.boot_id(), "boot_time": self.boot_time(),
             "alive": round(now, 1), "clean": clean}
        d.update(extra)
        try:
            _atomic_write(self.path, d)
        except OSError:
            pass

    def touch(self, force: bool = False) -> None:
        now = self.clock()
        if force or now - self._last_touch >= ALIVE_EVERY_S:
            self._last_touch = now
            self._write(now, clean=False)

    def stop(self) -> None:
        """Clean stop. A stop while the machine runs on battery (a UPS shutting
        the box down before it is empty) is NOT clean: the next start reports
        the power cut."""
        ac = None
        try:
            ac = self.power().get("ac")
        except Exception:
            pass
        if ac is False:
            self._write(self.clock(), clean=False, low_power_stop=True)
        else:
            self._write(self.clock(), clean=True)


class NetWatch:
    """Internet up/down from the heartbeat results -> one net_back event per
    outage of NET_MIN_DOWN_S or longer (sent when the internet is back)."""

    def __init__(self, queue: BoxEventQueue, path: Optional[str] = None,
                 clock: Callable[[], float] = time.time, min_down_s: float = NET_MIN_DOWN_S):
        self.queue = queue
        self.path = path or paths.path("net_state.json")
        self.clock = clock
        self.min_down_s = float(min_down_s)
        d = _read_json(self.path) or {}
        self.down_since: Optional[float] = d.get("down_since") if isinstance(
            d.get("down_since"), (int, float)) else None
        self.last_ok: Optional[float] = None

    def _persist(self) -> None:
        try:
            _atomic_write(self.path, {"down_since": self.down_since})
        except OSError:
            pass

    def update(self, online: Optional[bool], queued: int = 0) -> Optional[dict]:
        if online is None:
            return None
        now = self.clock()
        ev = None
        if online:
            if self.down_since is not None:
                if now - self.down_since >= self.min_down_s:
                    ev = self.queue.add("net_back", self.down_since, now,
                                        queued_alerts=int(queued))
                self.down_since = None
                self._persist()
            self.last_ok = now
        elif self.down_since is None:
            self.down_since = self.last_ok if self.last_ok is not None else now
            self._persist()
        return ev


class PowerWatch:
    """Mains present / gone, polled from the OS. Only boxes that can REALLY
    tell (a laptop, a UPS HAT, a battery the OS sees) ever send power_cut."""

    def __init__(self, queue: BoxEventQueue, clock: Callable[[], float] = time.time,
                 power: Callable[[], dict] = sysinfo.power_source, every_s: float = 10.0):
        self.queue = queue
        self.clock = clock
        self.power = power
        self.every_s = float(every_s)
        self._last_poll = -1e18
        self.on_battery_since: Optional[float] = None
        self.last: dict = {}

    def poll(self) -> Optional[dict]:
        now = self.clock()
        if now - self._last_poll < self.every_s:
            return None
        self._last_poll = now
        try:
            p = self.power() or {}
        except Exception:
            return None
        self.last = p
        ac = p.get("ac")
        if ac is False and self.on_battery_since is None:
            self.on_battery_since = now
            return self.queue.add("power_cut", now, None, battery_pct=p.get("battery_pct"))
        if ac is True and self.on_battery_since is not None:
            start, self.on_battery_since = self.on_battery_since, None
            return self.queue.add("power_back", start, now, on_battery=True)
        return None


class BoxMonitor:
    """Everything above, driven by the heartbeat loop (DeviceSync)."""

    def __init__(self, queue: Optional[BoxEventQueue] = None, **kw):
        self.queue = queue or BoxEventQueue()
        self.marker = RunMarker(self.queue)
        self.net = NetWatch(self.queue)
        self.power = PowerWatch(self.queue)
        self.queued_alerts: Callable[[], int] = kw.get("queued_alerts") or (lambda: 0)

    def start(self) -> None:
        try:
            self.marker.start()
        except Exception:
            log.exception("power marker failed")

    def tick(self, online: Optional[bool]) -> None:
        try:
            self.marker.touch()
            self.power.poll()
            self.net.update(online, self.queued_alerts())
        except Exception:
            log.exception("box monitor tick failed")

    def stop(self) -> None:
        try:
            self.marker.stop()
        except Exception:
            pass

    def pending(self) -> List[dict]:
        try:
            return self.queue.pending()
        except Exception:
            return []

    def ack(self, ids) -> None:
        try:
            self.queue.ack(ids)
        except Exception:
            pass
