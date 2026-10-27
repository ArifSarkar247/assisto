"""
Assisto vehicle tracker server — standalone asyncio TCP service (v1-vehicle).

    python -m tracker --host 0.0.0.0 --port 5023

Speaks Concox GT06, H02 text (Sinotrack ST-901 family) and Teltonika Codec 8 /
8E (+ Codec 12 commands) on ONE port; the protocol is detected from the first
bytes of each connection.

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

from .protocols import gt06, h02, teltonika

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
        self.sos = False              # H02: SOS bit seen on the last frame

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
        for s in list(self.sessions.values()):
            try:
                s.writer.close()
            except Exception:
                pass
        await self.flush()

    # ---------------------------------------------------------------- buffer
    def _buf(self, tid):
        b = self.buffer.get(tid)
        if b is None:
            b = self.buffer[tid] = {"fixes": [], "status": {}}
        return b

    def add_fix(self, tid, fix):
        self._buf(tid)["fixes"].append(fix)
        self.buffered += 1

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

    # ---------------------------------------------------------------- commands
    async def _commander(self):
        while True:
            await asyncio.sleep(self.cmd_poll_s)
            try:
                await self.dispatch_commands()
            except Exception:
                log.exception("command dispatch failed")

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
            sent += 1
        return sent

    @staticmethod
    def _command_text(proto, cmd):
        mod = {"gt06": gt06, "h02": h02}.get(proto, teltonika)
        if cmd["kind"] in mod.COMMANDS:
            return mod.COMMANDS[cmd["kind"]]
        if cmd["kind"] == "set_interval":
            p = cmd.get("payload") or {}
            return mod.interval_command(p.get("moving_s", 5), p.get("parked_s", 180))
        return None

    async def _reply(self, s, text, ok, flag=None):
        from core import vehicle_service as VS
        s.inflight = None
        await self.store.call(VS.mark_reply, s.tracker_id, text, ok, flag)

    async def _housekeeper(self):
        last_prune = 0.0
        while True:
            await asyncio.sleep(HOUSEKEEP_S)
            try:
                from core import vehicle_service as VS
                await self.store.call(VS.expire_commands)
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
            if session and self.sessions.get(session.tracker_id) is session:
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
            self._buf(s.tracker_id)["status"].update(
                ignition=st["ignition"], relay_cut=st["relay_cut"])
        elif k == "alarm":
            self.add_fix(s.tracker_id, pkt["fix"])
            if pkt.get("alarm") in ("sos", "power_cut", "tamper", "low_battery"):
                await self.store.call(_device_alarm, s.tracker_id, pkt["alarm"])
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
                    self.add_fix(s.tracker_id, pkt["fix"])
                    sos = pkt.get("alarm") == "sos"
                    if sos and not s.sos:        # the SOS bit repeats in every
                        await self.store.call(_device_alarm, s.tracker_id, "sos")
                    s.sos = sos                  # frame: alert on the edge only
                elif k == "heartbeat":
                    self._buf(s.tracker_id)
                elif k == "cmd_reply":
                    await self._reply(s, pkt["text"], h02.reply_ok(pkt["text"]))
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
        if s is not None:
            await self.store.call(_audit_abuse, s.tracker_id, ip)


def _device_alarm(tracker_id, alarm):
    from core.models import VehicleTracker
    from core import vehicle_service as VS
    t = VehicleTracker.objects.filter(pk=tracker_id).select_related("owner").first()
    if t is not None:
        VS.deliver_alert(t, {"kind": "device_alarm", "alarm": alarm})


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
