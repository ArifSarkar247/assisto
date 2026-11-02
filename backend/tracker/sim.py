"""
Device simulator for the Assisto tracker server — speaks GT06, H02 (Sinotrack
ST-901 text), Coban TK103 / GPS103 text (veh100) and Teltonika.

Used by the end-to-end test (core/tests_v1_vehicle.py) and by hand:

    python -m tracker.sim gt06 --imei 359339077003915 --port 15023 --fixes 20
    python -m tracker.sim teltonika --imei 356307042441013 --port 15023
    python -m tracker.sim h02 --imei 9171234567 --port 15023
    python -m tracker.sim tk103 --imei 359586015829802 --port 15023
    python -m tracker.sim watch --imei 8800000015 --port 15023   (kids watch)

Each simulated device auto-answers server commands like real firmware does:
GT06 replies to a 0x80 online command with a 0x15 string reply carrying the
same server flag; Teltonika replies to a Codec 12 command with a Codec 12
response. Never point this at port 5023 of a production box with a real IMEI.
"""
import argparse
import asyncio
import struct
from datetime import datetime, timedelta, timezone

from .protocols import gt06, h02, teltonika, tk103, watch


class GT06Device:
    def __init__(self, imei, reply_text="Cut off the fuel supply: Success!"):
        self.imei = imei
        self.serial = 0
        self.reply_text = reply_text
        self.commands = []            # texts received from the server
        self.acks = []                # protocol numbers ACKed by the server
        self.reader = self.writer = None
        self._task = None
        self._login_ok = asyncio.Event()

    def _ser(self):
        self.serial = (self.serial + 1) & 0xFFFF
        return self.serial

    async def connect(self, host, port):
        self.reader, self.writer = await asyncio.open_connection(host, port)
        self._task = asyncio.create_task(self._listen())

    async def login(self, timeout=5.0):
        self.writer.write(gt06.login_packet(self.imei, self._ser()))
        await self.writer.drain()
        try:
            await asyncio.wait_for(self._login_ok.wait(), timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def fix(self, lat, lng, speed_kmh, ignition=True, at=None, course=90):
        at = at or datetime.now(timezone.utc)
        self.writer.write(gt06.gps_packet(at, lat, lng, speed_kmh, course,
                                          self._ser(), ignition=ignition))
        await self.writer.drain()

    async def heartbeat(self, ignition=False, relay_cut=False):
        self.writer.write(gt06.status_packet(self._ser(), ignition, relay_cut))
        await self.writer.drain()

    async def alarm(self, lat, lng, alarm="sos", speed_kmh=0, at=None):
        at = at or datetime.now(timezone.utc)
        self.writer.write(gt06.alarm_packet(at, lat, lng, speed_kmh, alarm, self._ser()))
        await self.writer.drain()

    async def raw(self, data: bytes):
        self.writer.write(data)
        await self.writer.drain()

    async def _listen(self):
        buf = b""
        try:
            while True:
                data = await self.reader.read(4096)
                if not data:
                    return
                buf += data
                frames, buf = gt06.split_frames(buf)
                for fr in frames:
                    proto = fr[3]
                    if proto == gt06.P_SERVER_CMD:
                        flag, text, _ = gt06.parse_server_command(fr)
                        self.commands.append(text)
                        self.writer.write(gt06.reply_packet(flag, self.reply_text,
                                                            self._ser()))
                        await self.writer.drain()
                    else:
                        self.acks.append(proto)
                        if proto == gt06.P_LOGIN:
                            self._login_ok.set()
        except (ConnectionError, asyncio.CancelledError, gt06.FrameError):
            return

    async def close(self):
        if self._task:
            self._task.cancel()
        if self.writer:
            self.writer.close()


class H02Device:
    """Sinotrack ST-901-style text tracker: no login, IMEI in every frame,
    answers S20 / S71 server commands with a V4 reply (like real firmware)."""

    def __init__(self, imei, reply_result="DONE"):
        self.imei = imei
        self.reply_result = reply_result
        self.commands = []
        self.reader = self.writer = None
        self._task = None
        self._eof = asyncio.Event()

    async def connect(self, host, port):
        self.reader, self.writer = await asyncio.open_connection(host, port)
        self._task = asyncio.create_task(self._listen())

    async def fix(self, lat, lng, speed_kmh, ignition=True, at=None, course=90,
                  sos=False, valid=True):
        at = at or datetime.now(timezone.utc)
        self.writer.write(h02.v1_packet(self.imei, at, lat, lng, speed_kmh, course,
                                        valid=valid, ignition=ignition, sos=sos))
        await self.writer.drain()

    async def heartbeat(self):
        self.writer.write(h02.heartbeat_packet(self.imei))
        await self.writer.drain()

    async def closed(self, timeout=2.0):
        """True if the server hung up on us (refused IMEI)."""
        try:
            await asyncio.wait_for(self._eof.wait(), timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def _listen(self):
        buf = b""
        try:
            while True:
                data = await self.reader.read(4096)
                if not data:
                    self._eof.set()
                    return
                buf += data
                frames, buf = h02.split_frames(buf)
                for fr in frames:
                    code, params = h02.parse_server_command(fr)
                    self.commands.append(",".join([code] + params))
                    self.writer.write(h02.reply_packet(
                        self.imei, code, self.reply_result, datetime.now(timezone.utc)))
                    await self.writer.drain()
        except (ConnectionError, asyncio.CancelledError, h02.FrameError):
            return

    async def close(self):
        if self._task:
            self._task.cancel()
        if self.writer:
            self.writer.close()


class TK103Device:
    """Coban TK103-style text tracker: '##,imei:..,A;' login (server answers
    LOAD), '<imei>;' heartbeat (ON), position frames, and J / K / C commands
    answered with a 'jt' / 'kt' keyword frame (TK103B firmware behaviour)."""

    def __init__(self, imei, confirm=True):
        self.imei = imei
        self.confirm = confirm
        self.commands = []
        self.replies = []             # LOAD / ON tokens from the server
        self.reader = self.writer = None
        self._task = None
        self._loaded = asyncio.Event()
        self._eof = asyncio.Event()

    async def connect(self, host, port):
        self.reader, self.writer = await asyncio.open_connection(host, port)
        self._task = asyncio.create_task(self._listen())

    async def login(self, timeout=5.0):
        self.writer.write(tk103.login_packet(self.imei))
        await self.writer.drain()
        try:
            await asyncio.wait_for(self._loaded.wait(), timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def heartbeat(self):
        self.writer.write(tk103.heartbeat_packet(self.imei))
        await self.writer.drain()

    async def fix(self, lat, lng, speed_kmh, at=None, course=90, keyword="tracker"):
        at = at or datetime.now(timezone.utc)
        self.writer.write(tk103.position_packet(self.imei, at, lat, lng, speed_kmh,
                                                course, keyword=keyword))
        await self.writer.drain()

    async def closed(self, timeout=2.0):
        try:
            await asyncio.wait_for(self._eof.wait(), timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def _listen(self):
        buf = b""
        try:
            while True:
                data = await self.reader.read(4096)
                if not data:
                    self._eof.set()
                    return
                buf += data
                while True:
                    for tok in (tk103.LOGIN_REPLY, tk103.HEARTBEAT_REPLY):
                        if buf.startswith(tok) and not buf.startswith(b"**"):
                            self.replies.append(tok.decode())
                            if tok == tk103.LOGIN_REPLY:
                                self._loaded.set()
                            buf = buf[len(tok):]
                            break
                    else:
                        break
                j = buf.find(b";")
                while buf.startswith(b"**") and j >= 0:
                    _imei, cmd = tk103.parse_server_command(buf[:j + 1])
                    buf = buf[j + 1:]
                    self.commands.append(cmd)
                    kw = {"J": "jt", "K": "kt"}.get(cmd)
                    if kw and self.confirm:
                        self.writer.write(tk103.reply_packet(self.imei, kw))
                        await self.writer.drain()
                    j = buf.find(b";")
        except (ConnectionError, asyncio.CancelledError, tk103.FrameError):
            return

    async def close(self):
        if self._task:
            self._task.cancel()
        if self.writer:
            self.writer.close()


class TeltonikaDevice:
    def __init__(self, imei, reply_text="DOUT1:1 DOUT2:0 Timeout:INFINITY"):
        self.imei = imei
        self.reply_text = reply_text
        self.commands = []
        self.acks = asyncio.Queue()
        self.accepted = None
        self.reader = self.writer = None
        self._task = None

    async def connect(self, host, port):
        self.reader, self.writer = await asyncio.open_connection(host, port)

    async def handshake(self, timeout=5.0):
        self.writer.write(teltonika.imei_frame(self.imei))
        await self.writer.drain()
        try:
            b = await asyncio.wait_for(self.reader.readexactly(1), timeout)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError):
            self.accepted = False
            return False
        self.accepted = b == teltonika.IMEI_ACCEPT
        if self.accepted:
            self._task = asyncio.create_task(self._listen())
        return self.accepted

    async def send(self, records, codec=teltonika.CODEC_8E, timeout=5.0):
        """Send one AVL packet; return the server's accepted-record count."""
        self.writer.write(teltonika.build_avl(records, codec))
        await self.writer.drain()
        return await asyncio.wait_for(self.acks.get(), timeout)

    async def _listen(self):
        buf = b""
        try:
            while True:
                data = await self.reader.read(4096)
                if not data:
                    return
                buf += data
                while len(buf) >= 4:
                    if (len(buf) >= 9 and buf[:4] == b"\x00\x00\x00\x00"
                            and buf[8] == teltonika.CODEC_12):
                        (ln,) = struct.unpack(">I", buf[4:8])
                        if len(buf) < 12 + ln:
                            break
                        pkt, buf = buf[:12 + ln], buf[12 + ln:]
                        cmd = teltonika.parse_packet(pkt)
                        self.commands.append(cmd["text"])
                        self.writer.write(teltonika.codec12_response(self.reply_text))
                        await self.writer.drain()
                    else:
                        (n,) = struct.unpack(">I", buf[:4])
                        buf = buf[4:]
                        await self.acks.put(n)
        except (ConnectionError, asyncio.CancelledError, teltonika.FrameError):
            return

    async def close(self):
        if self._task:
            self._task.cancel()
        if self.writer:
            self.writer.close()


class WatchDevice:
    """Kids GPS watch speaking the "3G" (SeTracker / Wonlex) text protocol:
    LK link (server echoes LK), UD positions, AL alarms (server answers AL),
    TK voice notes (server answers TK,1). Server commands are ACKed by echoing
    their type like real firmware; a TK voice push is answered "TK,1" and its
    audio kept in `voice_received`. `forbidden_seen` records any command type
    in watch.FORBIDDEN (there must never be one)."""

    def __init__(self, dev_id, maker="SG", index=None, ack_commands=True):
        self.dev = dev_id
        self.maker = maker
        self.index = index
        self.ack_commands = ack_commands
        self.replies = []             # types of the server's replies (LK, AL, TK...)
        self.commands = []            # server command contents (text)
        self.voice_received = []
        self.forbidden_seen = []
        self.reader = self.writer = None
        self._task = None
        self._eof = asyncio.Event()
        self._got = asyncio.Condition()

    async def connect(self, host, port):
        self.reader, self.writer = await asyncio.open_connection(host, port)
        self._task = asyncio.create_task(self._listen())

    async def send(self, content):
        self.writer.write(watch.device_frame(self.maker, self.dev, content, self.index))
        await self.writer.drain()

    async def _wait_reply(self, typ, n_before, timeout):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            if self.replies[n_before:].count(typ):
                return True
            if self._eof.is_set():
                return False
            await asyncio.sleep(0.02)
        return False

    async def link(self, battery=80, steps=100, timeout=5.0):
        n = len(self.replies)
        await self.send("LK,%d,0,%d" % (steps, battery))
        return await self._wait_reply("LK", n, timeout)

    async def position(self, lat, lng, at=None, valid=True, battery=80, wifi=None,
                       cells=None, typ="UD", status=0):
        at = at or datetime.now(timezone.utc)
        await self.send(watch.position_content(at, lat, lng, valid=valid, battery=battery,
                                               wifi=wifi, cells=cells, typ=typ,
                                               status=status))

    async def alarm(self, lat, lng, status=1 << watch.BIT_SOS, at=None, timeout=5.0):
        at = at or datetime.now(timezone.utc)
        n = len(self.replies)
        await self.send(watch.position_content(at, lat, lng, status=status, typ="AL"))
        return await self._wait_reply("AL", n, timeout)

    async def voice(self, audio, timeout=5.0):
        n = len(self.replies)
        await self.send(b"TK," + audio)
        return await self._wait_reply("TK", n, timeout)

    async def closed(self, timeout=2.0):
        try:
            await asyncio.wait_for(self._eof.wait(), timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def _listen(self):
        buf = b""
        try:
            while True:
                data = await self.reader.read(4096)
                if not data:
                    self._eof.set()
                    return
                buf += data
                frames, buf = watch.split_frames(buf)
                for fr in frames:
                    typ, content = watch.parse_server_frame(fr)
                    if typ in watch.FORBIDDEN:
                        self.forbidden_seen.append(typ)
                        continue
                    if typ in ("LK", "AL", "TKQ", "TKQ2", "INIT") or \
                            (typ == "TK" and content in (b"TK,1", b"TK,0")):
                        self.replies.append(typ)
                        continue
                    if typ == "TK":
                        self.voice_received.append(content[3:])
                        self.commands.append("TK")
                        if self.ack_commands:
                            await self.send("TK,1")
                        continue
                    self.commands.append(content.decode("utf-8", "replace"))
                    if self.ack_commands:
                        await self.send(typ)
        except (ConnectionError, asyncio.CancelledError, watch.FrameError):
            self._eof.set()
            return

    async def close(self):
        if self._task:
            self._task.cancel()
        if self.writer:
            self.writer.close()


def drive_path(start_lat, start_lng, n, speed_kmh=40.0, step_s=5, t0=None,
               bearing_deg=90.0):
    """A straight drive: n fixes `step_s` apart at `speed_kmh`. Pure helper."""
    import math
    t0 = t0 or datetime.now(timezone.utc) - timedelta(seconds=n * step_s)
    out = []
    lat, lng = start_lat, start_lng
    step_m = speed_kmh / 3.6 * step_s
    b = math.radians(bearing_deg)
    for i in range(n):
        out.append({"at": t0 + timedelta(seconds=i * step_s), "lat": lat, "lng": lng,
                    "speed_kmh": speed_kmh})
        lat += (step_m * math.cos(b)) / 111320.0
        lng += (step_m * math.sin(b)) / (111320.0 * math.cos(math.radians(lat)))
    return out


async def _cli(a):
    path = drive_path(23.7808, 90.4130, a.fixes, a.speed, 5)
    if a.proto == "gt06":
        d = GT06Device(a.imei)
        await d.connect(a.host, a.port)
        ok = await d.login()
        print("login acked:", ok)
        if not ok:
            return
        for p in path:
            await d.fix(p["lat"], p["lng"], p["speed_kmh"], True, p["at"])
            await asyncio.sleep(a.delay)
        await d.heartbeat(ignition=True)
        await asyncio.sleep(a.listen)
        print("commands received:", d.commands)
        await d.close()
    elif a.proto == "h02":
        d = H02Device(a.imei)
        await d.connect(a.host, a.port)
        for p in path:
            await d.fix(p["lat"], p["lng"], p["speed_kmh"], True, p["at"])
            await asyncio.sleep(a.delay)
        await d.heartbeat()
        await asyncio.sleep(a.listen)
        print("frames sent:", len(path) + 1, "commands received:", d.commands)
        await d.close()
    elif a.proto == "tk103":
        d = TK103Device(a.imei)
        await d.connect(a.host, a.port)
        ok = await d.login()
        print("login LOAD:", ok)
        if not ok:
            return
        for p in path:
            await d.fix(p["lat"], p["lng"], p["speed_kmh"], p["at"])
            await asyncio.sleep(a.delay)
        await d.heartbeat()
        await asyncio.sleep(a.listen)
        print("commands received:", d.commands)
        await d.close()
    elif a.proto == "watch":
        d = WatchDevice(a.imei)
        await d.connect(a.host, a.port)
        ok = await d.link()
        print("LK answered:", ok)
        if not ok:
            return
        for p in path:
            await d.position(p["lat"], p["lng"], p["at"])
            await asyncio.sleep(a.delay)
        await asyncio.sleep(a.listen)
        print("commands received:", d.commands)
        await d.close()
    else:
        d = TeltonikaDevice(a.imei)
        await d.connect(a.host, a.port)
        ok = await d.handshake()
        print("imei accepted:", ok)
        if not ok:
            return
        recs = [{**p, "io": {teltonika.IO_IGNITION: 1, teltonika.IO_MOVEMENT: 1,
                             teltonika.IO_EXT_VOLTAGE: 12600}} for p in path]
        n = await d.send(recs)
        print("server acked records:", n)
        await asyncio.sleep(a.listen)
        print("commands received:", d.commands)
        await d.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Assisto tracker device simulator")
    ap.add_argument("proto", choices=["gt06", "h02", "tk103", "teltonika", "watch"])
    ap.add_argument("--imei", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=15023)
    ap.add_argument("--fixes", type=int, default=10)
    ap.add_argument("--speed", type=float, default=40.0)
    ap.add_argument("--delay", type=float, default=0.2)
    ap.add_argument("--listen", type=float, default=5.0,
                    help="seconds to stay connected for commands")
    asyncio.run(_cli(ap.parse_args(argv)))


if __name__ == "__main__":
    main()
