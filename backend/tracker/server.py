"""
Assisto vehicle tracker server — standalone asyncio TCP service (v1-vehicle).

    python -m tracker --host 0.0.0.0 --port 5023

Speaks Concox GT06, H02 text (Sinotrack ST-901 family), Coban TK103 / GPS103
text (veh100), Teltonika Codec 8 / 8E (+ Codec 12 commands) and the kids-watch
"3G" text protocol (SeTracker / Wonlex "[SG*", kidswatch) on ONE port; the
protocol is detected from the first bytes of each connection. Kids watches
have their own ORM side (core.kidswatch_service) and their own sessions,
buffer and command queue here; SOS / alarm frames are flushed at once.

Device alarms (SOS, power cut / unplug, low battery) travel INSIDE the fix or
status batch to core.vehicle_service.ingest, which alerts on the rising edge
with per-kind cooldowns and a daily cap (core.logic.vehicle_tracking) — so a
level that repeats in every frame (H02 status bits) alerts once.

TRANSPORT HONESTY: these trackers speak plain TCP and cannot do TLS. Position
data on the device->server leg is therefore not encrypted. Mitigations:
  * IMEI allowlist — only IMEIs an owner paired (inside the pairing window) are
    accepted; unknown IMEIs are refused and logged;
  * per-device packet rate limit + frame size caps + idle timeout;
  * devices can never command us: inbound packets only ever add positions /
    status / replies to commands WE sent; device-originated "commands" are
    ignored;
  * all app <-> server traffic is HTTPS (Django behind nginx).

DB access: Django ORM through ONE worker thread (Store). Fixes are buffered
in memory and written in batches (bulk_create) every FLUSH_S seconds or when
BATCH_MAX fixes are waiting — the live position is part of that same flush.
"""
import argparse
import asyncio
import logging
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

from .protocols import gt06, h02, teltonika, tk103, watch

log = logging.getLogger("assisto.tracker")

FLUSH_S = 2.0
BATCH_MAX = 200
CMD_POLL_S = 2.0
HOUSEKEEP_S = 30.0
PRUNE_EVERY_S = 3600.0
FIRST_BYTES_TIMEOUT_S = 30.0
IDLE_TIMEOUT_S = 900.0          # trackers report at least every few minutes
MAX_CONN_TOTAL = 5000
MAX_CONN_PER_IP = 200           # mobile carriers CGNAT many SIMs behind one IP
READ_CHUNK = 4096
MAX_BUFFER = 32 * 1024
WATCH_MAX_BUFFER = 256 * 1024   # a TK voice frame is up to ~30 KB escaped
# Device alarms worth a push (vibration / displacement are stored, not pushed).
ALERT_ALARMS = ("sos", "power_cut", "tamper", "low_battery")


class Store:
    """Runs ORM calls on a single dedicated thread (Django connections are per
    thread). inline=True runs them on the caller's thread (tests only)."""

    def __init__(self, inline=False):
        self.inline = inline
        self._ex = None if inline else ThreadPoolExecutor(max_workers=1,
                                                         thread_name_prefix="trk-db")

    async def call(self, fn, *args, **kw):
        if self.inline:
            return fn(*args, **kw)
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self._ex, _with_conn, fn, args, kw)

    def close(self):
        if self._ex:
            self._ex.shutdown(wait=False)


def _with_conn(fn, args, kw):
    from django.db import close_old_connections
    close_old_connections()
    try:
        return fn(*args, **kw)
    finally:
        close_old_connections()


class Bucket:
    """Token bucket: `per_min` packets/minute, burst = per_min / 4 (>= 20)."""

    def __init__(self, per_min):
        self.rate = per_min / 60.0
        self.cap = max(20.0, per_min / 4.0)
        self.tokens = self.cap
        self.t = time.monotonic()
        self.dropped = 0

    def take(self):
        now = time.monotonic()
        self.tokens = min(self.cap, self.tokens + (now - self.t) * self.rate)
        self.t = now
        if self.tokens >= 1:
            self.tokens -= 1
            return True
        self.dropped += 1
        return False


class Session:
    def __init__(self, proto, tracker_id, imei, writer):
        self.proto = proto
        self.tracker_id = tracker_id
        self.imei = imei
        self.writer = writer
        self.serial = 1
        self.inflight = None          # (cmd_id, sent_monotonic)

    def next_serial(self):
        self.serial = (self.serial + 1) & 0xFFFF
        return self.serial


class TrackerServer:
    def __init__(self, host="0.0.0.0", port=5023, store=None, cfg=None,
                 flush_s=FLUSH_S, cmd_poll_s=CMD_POLL_S):
        self.host, self.port = host, port
        self.store = store or Store()
        self.cfg = dict(cfg or {})
        self.flush_s = flush_s
        self.cmd_poll_s = cmd_poll_s
        self.sessions = {}            # tracker_id -> Session
        self.wsessions = {}           # kids watch id -> WatchSession
        self.wbuffer = {}             # kids watch id -> {"fixes", "link", "alarms"}
        self.wlock = asyncio.Lock()
        self.buffer = {}              # tracker_id -> {"fixes": [], "status": {}}
        self.buffered = 0
        self.conns_by_ip = {}
        self.conns = 0
        self._server = None
        self._tasks = []
        self._flush_lock = asyncio.Lock()
        self.stats = {"frames": 0, "bad_frames": 0, "rejected": 0, "written": 0}

    # ---------------------------------------------------------------- config
    def _c(self, key, default):
        return int(self.cfg.get(key, default))

    async def refresh_cfg(self):
        try:
            from core import vehicle_service as VS
            self.cfg = await self.store.call(VS.vcfg)
        except Exception:
            log.exception("cfg refresh failed")

    # ---------------------------------------------------------------- lifecycle
    async def start(self):
        if not self.cfg:
            await self.refresh_cfg()
        self._server = await asyncio.start_server(self._handle, self.host, self.port)
        self._tasks = [asyncio.create_task(self._flusher()),
                       asyncio.create_task(self._commander()),
                       asyncio.create_task(self._housekeeper())]
        log.info("tracker listening on %s:%s", self.host, self.port)

    async def stop(self):
        for t in self._tasks:
            t.cancel()
        for t in self._tasks:
            try:
                await t
            except (asyncio.CancelledError, Exception):
                pass
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        for s in list(self.sessions.values()) + list(self.wsessions.values()):
            try:
                s.writer.close()
            except Exception:
                pass
        await self.flush()
        await self.wflush()

    # ---------------------------------------------------------------- buffer
    def _buf(self, tid):
        b = self.buffer.get(tid)
        if b is None:
            b = self.buffer[tid] = {"fixes": [], "status": {}}
        return b

    def add_fix(self, tid, fix):
        self._buf(tid)["fixes"].append(fix)
        self.buffered += 1

    def add_status(self, tid, **kw):
        """Merge a status report (no GPS) into the next flush. `alarms`
        accumulate (a heartbeat-only alarm is never overwritten)."""
        st = self._buf(tid)["status"]
        alarms = kw.pop("alarms", None) or []
        st.update({k: v for k, v in kw.items() if v is not None})
        if alarms:
            st["alarms"] = sorted(set(st.get("alarms") or []) | set(alarms))

    async def flush(self):
        async with self._flush_lock:
            if not self.buffer:
                return 0
            batch, self.buffer, self.buffered = self.buffer, {}, 0
            try:
                from core import vehicle_service as VS
                n = await self.store.call(VS.ingest, batch)
                self.stats["written"] += n
                return n
            except Exception:
                log.exception("flush failed (%d trackers) — batch dropped", len(batch))
                return 0

    async def _flusher(self):
        while True:
            await asyncio.sleep(self.flush_s)
            await self.flush()
            await self.wflush()

    # ---------------------------------------------------------------- commands
    async def _commander(self):
        while True:
            await asyncio.sleep(self.cmd_poll_s)
            try:
                await self.dispatch_commands()
            except Exception:
                log.exception("command dispatch failed")
            try:
                await self.dispatch_watch_commands()
            except Exception:
                log.exception("watch command dispatch failed")

    async def dispatch_commands(self):
        if not self.sessions:
            return 0
        from core import vehicle_service as VS
        timeout = self._c("command_timeout_s", 120)
        now = time.monotonic()
        for s in self.sessions.values():
            if s.inflight and now - s.inflight[1] > timeout:
                s.inflight = None
        free = [tid for tid, s in self.sessions.items() if s.inflight is None]
        if not free:
            return 0
        pending = await self.store.call(VS.pending_for, free)
        sent = 0
        for cmd in pending:
            s = self.sessions.get(cmd["tracker_id"])
            if s is None or s.inflight is not None:
                continue
            text = self._command_text(s.proto, cmd)
            if text is None:
                continue
            flag = cmd["id"] & 0xFFFFFFFF
            if s.proto == "gt06":
                wire = gt06.server_command(text, flag, s.next_serial())
            elif s.proto == "h02":
                wire = h02.server_command(s.imei, text, datetime.now(timezone.utc))
                flag = 0
            elif s.proto == "tk103":
                wire = tk103.server_command(s.imei, text)
                flag = 0
            else:
                wire = teltonika.codec12_command(text)
                flag = 0
            try:
                s.writer.write(wire)
                await s.writer.drain()
            except Exception:
                continue
            s.inflight = (cmd["id"], time.monotonic())
            await self.store.call(VS.mark_sent, cmd["id"], text, flag)
            if s.proto == "tk103" and cmd["kind"] == "set_interval":
                # TK103 never answers "C,<n>s": do not hold the socket for it
                # (the row ends 'failed / no_reply' after the timeout — honest).
                s.inflight = None
            sent += 1
        return sent

    @staticmethod
    def _command_text(proto, cmd):
        mod = {"gt06": gt06, "h02": h02, "tk103": tk103}.get(proto, teltonika)
        if cmd["kind"] in mod.COMMANDS:
            return mod.COMMANDS[cmd["kind"]]
        if cmd["kind"] == "set_interval":
            p = cmd.get("payload") or {}
            return mod.interval_command(p.get("moving_s", 5), p.get("parked_s", 180))
        return None

    async def _reply(self, s, text, ok, flag=None, kind=None):
        from core import vehicle_service as VS
        s.inflight = None
        await self.store.call(VS.mark_reply, s.tracker_id, text, ok, flag, kind=kind)

    async def _housekeeper(self):
        last_prune = 0.0
        while True:
            await asyncio.sleep(HOUSEKEEP_S)
            try:
                from core import vehicle_service as VS
                await self.store.call(VS.expire_commands)
                await self.store.call(VS.sweep_silent)
                from core import kidswatch_service as KW
                await self.store.call(KW.expire_commands)
                await self.refresh_cfg()
                if time.monotonic() - last_prune > PRUNE_EVERY_S:
                    last_prune = time.monotonic()
                    n = await self.store.call(VS.prune)
                    if n:
                        log.info("pruned %d old positions", n)
            except Exception:
                log.exception("housekeeping failed")

    # ---------------------------------------------------------------- connections
    async def _handle(self, reader, writer):
        peer = writer.get_extra_info("peername") or ("?", 0)
        ip = str(peer[0])
        if self.conns >= MAX_CONN_TOTAL or self.conns_by_ip.get(ip, 0) >= MAX_CONN_PER_IP:
            writer.close()
            return
        self.conns += 1
        self.conns_by_ip[ip] = self.conns_by_ip.get(ip, 0) + 1
        session = None
        try:
            first = await asyncio.wait_for(reader.read(READ_CHUNK), FIRST_BYTES_TIMEOUT_S)
            if not first:
                return
            if first[:2] in (gt06.START_SHORT, gt06.START_LONG):
                session = await self._gt06(reader, writer, first, ip)
            elif h02.looks_like_h02(first):
                session = await self._h02(reader, writer, first, ip)
            elif tk103.looks_like_tk103(first):
                session = await self._tk103(reader, writer, first, ip)
            elif watch.looks_like_watch(first):
                session = await self._watch(reader, writer, first, ip)
            elif teltonika.looks_like_imei_frame(first):
                session = await self._teltonika(reader, writer, first, ip)
            # anything else: not a tracker we speak -> just close
        except (asyncio.TimeoutError, ConnectionError, OSError):
            pass
        except Exception:
            log.exception("connection handler crashed (%s)", ip)
        finally:
            self.conns -= 1
            self.conns_by_ip[ip] = max(0, self.conns_by_ip.get(ip, 1) - 1)
            if not self.conns_by_ip.get(ip):
                self.conns_by_ip.pop(ip, None)
            if isinstance(session, WatchSession):
                if self.wsessions.get(session.watch_id) is session:
                    self.wsessions.pop(session.watch_id, None)
            elif session and self.sessions.get(session.tracker_id) is session:
                self.sessions.pop(session.tracker_id, None)
            try:
                writer.close()
            except Exception:
                pass

    async def _connect(self, imei, proto, ip):
        from core import vehicle_service as VS
        tid, reason = await self.store.call(VS.on_device_connect, imei, proto, ip)
        if tid is None:
            self.stats["rejected"] += 1
        return tid, reason

    def _register(self, proto, tid, imei, writer):
        old = self.sessions.get(tid)
        if old is not None:          # device reconnected: drop the stale socket
            try:
                old.writer.close()
            except Exception:
                pass
        s = Session(proto, tid, imei, writer)
        self.sessions[tid] = s
        self._buf(tid)               # so the next flush stamps last_seen_at
        return s

    async def _read(self, reader):
        data = await asyncio.wait_for(reader.read(READ_CHUNK), IDLE_TIMEOUT_S)
        if not data:
            raise ConnectionError("eof")
        return data

    # ---- GT06
    async def _gt06(self, reader, writer, buf, ip):
        bucket = Bucket(self._c("max_packets_per_min", 240))
        s = None
        while True:
            try:
                frames, buf = gt06.split_frames(buf)
            except gt06.FrameError:
                self.stats["bad_frames"] += 1
                return s
            for fr in frames:
                if not bucket.take():
                    if bucket.dropped > 3 * self._c("max_packets_per_min", 240):
                        await self._abuse(s, ip)
                        return s
                    continue
                try:
                    pkt = gt06.parse_frame(fr)
                except gt06.FrameError:
                    self.stats["bad_frames"] += 1
                    continue
                self.stats["frames"] += 1
                if s is None:
                    if pkt["kind"] != "login":
                        return None          # must log in first
                    tid, _reason = await self._connect(pkt["imei"], "gt06", ip)
                    if tid is None:
                        return None          # refused: no ACK, close
                    s = self._register("gt06", tid, pkt["imei"], writer)
                    writer.write(gt06.ack(gt06.P_LOGIN, pkt["serial"]))
                    await writer.drain()
                    continue
                await self._gt06_packet(s, pkt, writer)
            if len(buf) > MAX_BUFFER:
                return s
            buf += await self._read(reader)

    async def _gt06_packet(self, s, pkt, writer):
        k = pkt["kind"]
        if k == "gps":
            self.add_fix(s.tracker_id, pkt["fix"])
        elif k == "status":
            st = pkt["status"]
            self.add_status(s.tracker_id, ignition=st["ignition"],
                            relay_cut=st["relay_cut"],
                            voltage_level=pkt.get("voltage_level"),
                            battery_v=pkt.get("battery_v"),
                            alarms=[st["alarm"]] if st.get("alarm") else [])
        elif k == "info":
            if pkt.get("ext_voltage_v") is not None:
                self.add_status(s.tracker_id, ext_voltage_v=pkt["ext_voltage_v"])
        elif k == "alarm":
            fix = dict(pkt["fix"])
            fix["alarms"] = [pkt["alarm"]] if pkt.get("alarm") in ALERT_ALARMS else []
            self.add_fix(s.tracker_id, fix)
        elif k == "cmd_reply":
            await self._reply(s, pkt["text"], gt06.reply_ok(pkt["text"]),
                              pkt.get("server_flag"))
        elif k == "time_req":
            writer.write(gt06.time_reply(pkt["serial"], datetime.now(timezone.utc)))
        if pkt["ack_required"] and k != "login":
            writer.write(gt06.ack(pkt["proto"], pkt["serial"]))
        await writer.drain()
        if self.buffered >= BATCH_MAX:
            await self.flush()

    # ---- H02 (text; no login packet — the IMEI rides in every frame)
    async def _h02(self, reader, writer, buf, ip):
        bucket = Bucket(self._c("max_packets_per_min", 240))
        s = None
        while True:
            try:
                frames, buf = h02.split_frames(buf)
            except h02.FrameError:
                self.stats["bad_frames"] += 1
                return s
            for fr in frames:
                if not bucket.take():
                    if bucket.dropped > 3 * self._c("max_packets_per_min", 240):
                        await self._abuse(s, ip)
                        return s
                    continue
                try:
                    pkt = h02.parse_frame(fr)
                except h02.FrameError:
                    self.stats["bad_frames"] += 1
                    continue
                self.stats["frames"] += 1
                if s is None:
                    tid, _reason = await self._connect(pkt["imei"], "h02", ip)
                    if tid is None:
                        return None          # refused: close, no reply
                    s = self._register("h02", tid, pkt["imei"], writer)
                elif pkt["imei"] != s.imei:
                    self.stats["bad_frames"] += 1     # never switch IMEI mid-socket
                    continue
                k = pkt["kind"]
                if k == "gps":
                    # alarms are LEVELS here (repeat in every frame); ingest
                    # alerts on the rising edge only.
                    self.add_fix(s.tracker_id, pkt["fix"])
                elif k == "heartbeat":
                    self._buf(s.tracker_id)
                elif k == "cmd_reply":
                    await self._reply(s, pkt["text"], h02.reply_ok(pkt["text"]))
                if self.buffered >= BATCH_MAX:
                    await self.flush()
            if len(buf) > MAX_BUFFER:
                return s
            buf += await self._read(reader)

    # ---- Coban TK103 / GPS103 (text; login "##,imei:..,A;" -> "LOAD")
    async def _tk103(self, reader, writer, buf, ip):
        bucket = Bucket(self._c("max_packets_per_min", 240))
        s = None
        while True:
            try:
                frames, buf = tk103.split_frames(buf)
            except tk103.FrameError:
                self.stats["bad_frames"] += 1
                return s
            for fr in frames:
                if not bucket.take():
                    if bucket.dropped > 3 * self._c("max_packets_per_min", 240):
                        await self._abuse(s, ip)
                        return s
                    continue
                try:
                    pkt = tk103.parse_frame(fr)
                except tk103.FrameError:
                    self.stats["bad_frames"] += 1
                    continue
                self.stats["frames"] += 1
                if s is None:
                    tid, _reason = await self._connect(pkt["imei"], "tk103", ip)
                    if tid is None:
                        return None          # refused: close, no LOAD
                    s = self._register("tk103", tid, pkt["imei"], writer)
                elif pkt["imei"] != s.imei:
                    self.stats["bad_frames"] += 1     # never switch IMEI mid-socket
                    continue
                k = pkt["kind"]
                if k == "login":
                    writer.write(tk103.LOGIN_REPLY)
                elif k == "heartbeat":
                    self._buf(s.tracker_id)
                    writer.write(tk103.HEARTBEAT_REPLY)
                elif k == "gps":
                    self.add_fix(s.tracker_id, pkt["fix"])
                elif k == "event":
                    self.add_status(s.tracker_id, ignition=pkt.get("ignition"),
                                    alarms=[a for a in pkt.get("alarms") or []
                                            if a in ALERT_ALARMS])
                elif k == "cmd_reply":
                    await self._reply(s, pkt["text"], tk103.reply_ok(pkt["text"]),
                                      kind=pkt.get("for_kind"))
                await writer.drain()
                if self.buffered >= BATCH_MAX:
                    await self.flush()
            if len(buf) > MAX_BUFFER:
                return s
            buf += await self._read(reader)

    # ---- Teltonika
    async def _teltonika(self, reader, writer, buf, ip):
        while True:
            try:
                imei, buf = teltonika.split_imei(buf)
            except teltonika.FrameError:
                return None
            if imei is not None:
                break
            if len(buf) > 64:
                return None
            buf += await self._read(reader)
        tid, _reason = await self._connect(imei, "teltonika", ip)
        if tid is None:
            writer.write(teltonika.IMEI_REJECT)
            await writer.drain()
            return None
        s = self._register("teltonika", tid, imei, writer)
        writer.write(teltonika.IMEI_ACCEPT)
        await writer.drain()
        bucket = Bucket(self._c("max_packets_per_min", 240))
        while True:
            while True:
                try:
                    pkt_bytes, buf = teltonika.split_packet(buf)
                except teltonika.FrameError:
                    self.stats["bad_frames"] += 1
                    return s
                if pkt_bytes is None:
                    break
                try:
                    pkt = teltonika.parse_packet(pkt_bytes)
                except teltonika.FrameError:
                    self.stats["bad_frames"] += 1
                    writer.write(teltonika.ack(0))      # device will resend
                    await writer.drain()
                    continue
                self.stats["frames"] += 1
                if pkt["kind"] == "cmd_reply":
                    await self._reply(s, pkt["text"], teltonika.reply_ok(pkt["text"]))
                    continue
                if pkt["kind"] != "avl":
                    continue                       # never act on device "commands"
                if not bucket.take():
                    if bucket.dropped > 3 * self._c("max_packets_per_min", 240):
                        await self._abuse(s, ip)
                        return s
                    continue                       # no ACK -> device keeps & resends
                for r in pkt["records"]:
                    self.add_fix(s.tracker_id, r)
                writer.write(teltonika.ack(pkt["count"]))
                await writer.drain()
                if self.buffered >= BATCH_MAX:
                    await self.flush()
            if len(buf) > MAX_BUFFER:
                return s
            buf += await self._read(reader)

    async def _abuse(self, s, ip):
        log.warning("rate limit exceeded, dropping %s", ip)
        if s is not None and not isinstance(s, WatchSession):
            await self.store.call(_audit_abuse, s.tracker_id, ip)

    # ---- kids watch ("3G" / SeTracker text protocol; core.kidswatch_service)
    def _wbuf(self, wid):
        b = self.wbuffer.get(wid)
        if b is None:
            b = self.wbuffer[wid] = {"fixes": [], "link": {}, "alarms": []}
        return b

    async def wflush(self):
        async with self.wlock:
            if not self.wbuffer:
                return 0
            batch, self.wbuffer = self.wbuffer, {}
            try:
                from core import kidswatch_service as KW
                return await self.store.call(KW.ingest, batch)
            except Exception:
                log.exception("watch flush failed (%d watches)", len(batch))
                return 0

    async def _wsend(self, s, content):
        s.writer.write(watch.frame(s.maker, s.dev, content, s.index))
        await s.writer.drain()

    async def _watch(self, reader, writer, buf, ip):
        from core import kidswatch_service as KW
        bucket = Bucket(self._c("max_packets_per_min", 240))
        s = None
        while True:
            try:
                frames, buf = watch.split_frames(buf)
            except watch.FrameError:
                self.stats["bad_frames"] += 1
                return s
            for fr in frames:
                if not bucket.take():
                    if bucket.dropped > 3 * self._c("max_packets_per_min", 240):
                        await self._abuse(s, ip)
                        return s
                    continue
                try:
                    pkt = watch.parse_frame(fr, s.tz_min if s else watch.DEFAULT_TZ_MIN)
                except watch.FrameError:
                    self.stats["bad_frames"] += 1
                    continue
                self.stats["frames"] += 1
                if s is None:
                    wid, _reason, tz = await self.store.call(
                        KW.on_watch_connect, pkt["id"], pkt["maker"], ip)
                    if wid is None:
                        self.stats["rejected"] += 1
                        return None             # refused: no reply, close
                    s = self._wregister(wid, pkt, tz, writer)
                elif pkt["id"] != s.dev:
                    self.stats["bad_frames"] += 1   # never switch id mid-socket
                    continue
                s.index = pkt["index"]
                await self._watch_packet(s, pkt)
            if len(buf) > WATCH_MAX_BUFFER:
                return s
            buf += await self._read(reader)

    def _wregister(self, wid, pkt, tz, writer):
        old = self.wsessions.get(wid)
        if old is not None:
            try:
                old.writer.close()
            except Exception:
                pass
        s = WatchSession(wid, pkt["maker"], pkt["id"], tz, writer)
        self.wsessions[wid] = s
        self._wbuf(wid)
        return s

    async def _watch_packet(self, s, pkt):
        from core import kidswatch_service as KW
        k = pkt["kind"]
        b = self._wbuf(s.watch_id)
        if k == "link":
            if pkt.get("battery") is not None:
                b["link"]["battery"] = pkt["battery"]
            if pkt.get("steps") is not None:
                b["link"]["steps"] = pkt["steps"]
        elif k in ("position", "alarm"):
            fix = dict(pkt["fix"], blind=pkt.get("blind", False))
            b["fixes"].append(fix)
            if k == "alarm":
                lat = fix["lat"] if fix["valid"] else None
                lng = fix["lng"] if fix["valid"] else None
                for a in fix["alarms"]:
                    b["alarms"].append([a, lat, lng])
        elif k == "voice":
            # store first, then ACK, so a crash never loses a note the watch
            # believes was delivered
            await self.wflush()
            await self.store.call(KW.voice_up, s.watch_id, pkt["audio"])
        elif s.inflight and pkt["type"] == s.inflight[2]:
            if pkt.get("ok") is False:
                await self.store.call(KW.mark_failed, s.inflight[0], "watch_refused")
            else:
                await self.store.call(KW.mark_ack, s.watch_id, pkt["type"])
            s.inflight = None
            await self.dispatch_watch_commands()    # next queued one at once
        reply = watch.reply_for(pkt)
        if reply:
            await self._wsend(s, reply)
        if k == "alarm":
            await self.wflush()                 # SOS never waits for the timer

    async def dispatch_watch_commands(self):
        if not self.wsessions:
            return 0
        from core import kidswatch_service as KW
        now = time.monotonic()
        for s in self.wsessions.values():
            if s.inflight and now - s.inflight[1] > KW.CMD_TIMEOUT_S:
                s.inflight = None
        free = [wid for wid, s in self.wsessions.items() if s.inflight is None]
        if not free:
            return 0
        sent = 0
        for cmd in await self.store.call(KW.pending_for, free):
            s = self.wsessions.get(cmd["watch_id"])
            if s is None or s.inflight is not None:
                continue
            try:
                wire, typ = watch.server_command(s.maker, s.dev, cmd["kind"],
                                                 cmd["payload"], s.index)
            except (watch.ForbiddenCommand, ValueError) as e:
                await self.store.call(KW.mark_failed, cmd["id"], type(e).__name__)
                continue
            try:
                s.writer.write(wire)
                await s.writer.drain()
            except Exception:
                continue
            s.inflight = (cmd["id"], time.monotonic(), typ)
            await self.store.call(KW.mark_sent, cmd["id"], typ)
            sent += 1
        return sent


class WatchSession:
    def __init__(self, watch_id, maker, dev, tz_min, writer):
        self.watch_id = watch_id
        self.maker = maker
        self.dev = dev
        self.tz_min = tz_min
        self.writer = writer
        self.index = None
        self.inflight = None          # (cmd_id, sent_monotonic, ack_type)


def _audit_abuse(tracker_id, ip):
    from core.models import VehicleTracker
    from core import vehicle_service as VS
    t = VehicleTracker.objects.filter(pk=tracker_id).first()
    VS.audit(t, "rate_limited", remote=ip)


# ---------------------------------------------------------------- entrypoint

def main(argv=None):
    ap = argparse.ArgumentParser(description="Assisto vehicle tracker server")
    ap.add_argument("--host", default=os.environ.get("TRACKER_HOST", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("TRACKER_PORT", "5023")))
    ap.add_argument("--settings", default=os.environ.get(
        "DJANGO_SETTINGS_MODULE", "assisto_backend.settings"))
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    os.environ["DJANGO_SETTINGS_MODULE"] = a.settings
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    import django
    django.setup()

    async def run():
        srv = TrackerServer(a.host, a.port)
        await srv.start()
        stop = asyncio.Event()
        try:
            import signal
            loop = asyncio.get_running_loop()
            for sig in (signal.SIGTERM, signal.SIGINT):
                loop.add_signal_handler(sig, stop.set)
        except Exception:
            pass
        await stop.wait()
        await srv.stop()
        srv.store.close()

    asyncio.run(run())


if __name__ == "__main__":
    main()
