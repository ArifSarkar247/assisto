"""
Concox GT06 / GT06N binary protocol — PURE parser + encoder (no I/O, no Django).

Frame layout (short form):
    78 78 | len(1) | proto(1) | info(N) | serial(2) | crc(2) | 0D 0A
Long form (some info / alarm packets):
    79 79 | len(2) | proto(1) | info(N) | serial(2) | crc(2) | 0D 0A

`len` counts proto + info + serial + crc. The CRC is CRC-ITU (CRC-16/X-25:
reflected poly 0x8408, init 0xFFFF, xorout 0xFFFF) over len .. serial.

Supported inbound protocol numbers:
    0x01 login (IMEI, 8 bytes BCD)             -> ACK required
    0x12 GPS+LBS (GT06)                         -> no ACK
    0x22 GPS+LBS (GT06N: + ACC / upload mode)   -> no ACK
    0x13 status / heartbeat                     -> ACK required
    0x16 alarm (GPS + LBS + status)             -> ACK required
    0x26 alarm (GT06N variant)                  -> ACK required
    0x15 / 0x21 reply to a server command       -> no ACK
    0x23 heartbeat (newer Concox: 2-byte volts) -> ACK required
    0x94 information transmission (long form;   -> no ACK
         sub-type 0x00 = external power voltage)
    0x8A time request                           -> answered with UTC time
veh100: the terminal-information byte of 0x13 / 0x23 / 0x16 also carries an
ALARM field (bits 5..3: 100 SOS, 011 low battery, 010 power cut, 001 shock)
and the 0x13 voltage level (0..6) — both are decoded into `alarms` / `status`
so a heartbeat-only alarm (no GPS) is never lost.
Anything else is reported as kind="unknown" and ignored by the server (we never
act on device-originated "commands" — devices only report).

Outbound:
    login / status / alarm ACK (echo proto + serial)
    0x80 server command (online command, ASCII, with a 4-byte server flag the
         device echoes in its 0x15/0x21 reply — that is how we match an ack to
         the VehicleCommand row)
"""
import struct
from datetime import datetime, timezone

START_SHORT = b"\x78\x78"
START_LONG = b"\x79\x79"
STOP = b"\x0d\x0a"

P_LOGIN = 0x01
P_GPS_LBS = 0x12
P_STATUS = 0x13
P_STRING_REPLY = 0x15
P_ALARM = 0x16
P_GPS_LBS_2 = 0x22
P_ALARM_2 = 0x26
P_CMD_REPLY_2 = 0x21
P_TIME_REQ = 0x8A
P_SERVER_CMD = 0x80
P_HEARTBEAT_2 = 0x23
P_INFO = 0x94

ACK_REQUIRED = {P_LOGIN, P_STATUS, P_ALARM, P_ALARM_2, P_HEARTBEAT_2}

# Terminal-information byte, bits 5..3 (Concox GT06 protocol v1.8 §5.4).
TERM_ALARMS = {4: "sos", 3: "low_battery", 2: "power_cut", 1: "vibration"}

MAX_FRAME = 1024          # a GT06 frame is ~40-100 bytes; anything bigger is junk

# Alarm byte (0x16 / 0x26 "alarm/language" first byte) -> our alarm codes.
ALARMS = {
    0x00: "normal", 0x01: "sos", 0x02: "power_cut", 0x03: "vibration",
    0x04: "fence_in", 0x05: "fence_out", 0x06: "overspeed", 0x09: "displacement",
    0x0E: "low_battery", 0x13: "tamper",
}


class FrameError(ValueError):
    """A malformed / bad-CRC frame. The server drops it (and counts it toward
    the per-device abuse limit) — it never crashes the connection loop."""


def crc_itu(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return (~crc) & 0xFFFF


# ----------------------------------------------------------------- framing

def split_frames(buf: bytes):
    """Split a TCP byte buffer into complete frames. Returns (frames, rest)
    where `rest` is an incomplete tail to keep for the next read. Leading junk
    bytes before a start marker are discarded. Raises FrameError on an
    impossible length (so the caller can drop the connection)."""
    frames = []
    i = 0
    n = len(buf)
    while i < n:
        j_s = buf.find(START_SHORT, i)
        j_l = buf.find(START_LONG, i)
        cands = [j for j in (j_s, j_l) if j >= 0]
        if not cands:
            # keep a lone trailing 0x78/0x79 (half a start marker)
            return frames, (buf[-1:] if buf[-1:] in (b"\x78", b"\x79") else b"")
        j = min(cands)
        long_form = buf[j:j + 2] == START_LONG
        hdr = 4 if long_form else 3
        if n - j < hdr:
            return frames, buf[j:]
        ln = (struct.unpack(">H", buf[j + 2:j + 4])[0] if long_form else buf[j + 2])
        total = hdr + ln + 2
        if ln < 5 or total > MAX_FRAME:
            raise FrameError("bad_length")
        if n - j < total:
            return frames, buf[j:]
        frames.append(buf[j:j + total])
        i = j + total
    return frames, b""


def _check(frame: bytes):
    long_form = frame[:2] == START_LONG
    hdr = 4 if long_form else 3
    if frame[-2:] != STOP:
        raise FrameError("bad_stop")
    body = frame[2:-4]            # len .. serial
    crc = struct.unpack(">H", frame[-4:-2])[0]
    if crc_itu(body) != crc:
        raise FrameError("bad_crc")
    proto = frame[hdr]
    info = frame[hdr + 1:-6]
    serial = struct.unpack(">H", frame[-6:-4])[0]
    return proto, info, serial


def _bcd_imei(b: bytes) -> str:
    s = b.hex()
    return s.lstrip("0") if len(s.lstrip("0")) >= 14 else s[-15:]


def _datetime(b: bytes):
    yy, mm, dd, hh, mi, ss = b[:6]
    try:
        return datetime(2000 + yy, mm, dd, hh, mi, ss, tzinfo=timezone.utc)
    except ValueError:
        return None


def _gps(info: bytes, off: int):
    """Parse the 18-byte date+GPS block at `off`. Returns (fix dict, new off)."""
    if len(info) < off + 18:
        raise FrameError("short_gps")
    at = _datetime(info[off:off + 6])
    sats = info[off + 6] & 0x0F
    lat_raw, lng_raw = struct.unpack(">II", info[off + 7:off + 15])
    speed = info[off + 15]
    flags = struct.unpack(">H", info[off + 16:off + 18])[0]
    lat = lat_raw / 1800000.0
    lng = lng_raw / 1800000.0
    if not flags & (1 << 10):     # bit10 = north latitude
        lat = -lat
    if flags & (1 << 11):         # bit11 = west longitude
        lng = -lng
    fix = {
        "at": at, "lat": round(lat, 6), "lng": round(lng, 6),
        "speed_kmh": float(speed), "course": flags & 0x03FF,
        "sats": sats, "valid": bool(flags & (1 << 12)),
    }
    return fix, off + 18


def _status_byte(b: int):
    return {
        "defend": bool(b & 0x01),
        "ignition": bool(b & 0x02),
        "charging": bool(b & 0x04),
        "gps_tracking": bool(b & 0x40),
        # bit7: 1 = oil & electricity DISCONNECTED (relay engaged = engine cut)
        "relay_cut": bool(b & 0x80),
        # bits 5..3: the alarm the terminal is currently reporting (or None)
        "alarm": TERM_ALARMS.get((b >> 3) & 0x07),
    }


def parse_frame(frame: bytes) -> dict:
    """Decode ONE complete frame (from split_frames). Returns a dict with at
    least {kind, proto, serial, ack_required}. Raises FrameError."""
    proto, info, serial = _check(frame)
    out = {"proto": proto, "serial": serial,
           "ack_required": proto in ACK_REQUIRED}
    if proto == P_LOGIN:
        if len(info) < 8:
            raise FrameError("short_login")
        out.update(kind="login", imei=_bcd_imei(info[:8]))
    elif proto in (P_GPS_LBS, P_GPS_LBS_2):
        fix, off = _gps(info, 0)
        if proto == P_GPS_LBS_2 and len(info) >= off + 8 + 1:
            # MCC2 MNC1 LAC2 CELL3 then ACC(1)
            fix["ignition"] = bool(info[off + 8])
        out.update(kind="gps", fix=fix)
    elif proto == P_STATUS:
        if len(info) < 1:
            raise FrameError("short_status")
        st = _status_byte(info[0])
        out.update(kind="status", status=st,
                   voltage_level=info[1] if len(info) > 1 else None,
                   gsm=info[2] if len(info) > 2 else None)
    elif proto == P_HEARTBEAT_2:
        # terminal info(1) + internal battery voltage(2, /100 V) + GSM(1) + lang(2)
        if len(info) < 3:
            raise FrameError("short_status")
        st = _status_byte(info[0])
        out.update(kind="status", status=st, voltage_level=None,
                   battery_v=round(struct.unpack(">H", info[1:3])[0] / 100.0, 2),
                   gsm=info[3] if len(info) > 3 else None)
    elif proto == P_INFO:
        if len(info) < 1:
            raise FrameError("short_info")
        sub = info[0]
        out.update(kind="info", sub=sub)
        if sub == 0x00 and len(info) >= 3:
            out["ext_voltage_v"] = round(struct.unpack(">H", info[1:3])[0] / 100.0, 2)
    elif proto in (P_ALARM, P_ALARM_2):
        fix, off = _gps(info, 0)
        lbs_len = info[off] if len(info) > off else 0
        off += max(lbs_len, 1)
        st = _status_byte(info[off]) if len(info) > off else {}
        alarm_b = info[off + 3] if len(info) > off + 3 else 0
        fix["ignition"] = st.get("ignition")
        out.update(kind="alarm", fix=fix, status=st,
                   alarm=ALARMS.get(alarm_b, "other"), alarm_code=alarm_b)
    elif proto in (P_STRING_REPLY, P_CMD_REPLY_2):
        # 0x15: len(1) + server flag(4) + content + language(2)
        # 0x21: server flag(4) + encoding(1) + content
        if proto == P_STRING_REPLY:
            if len(info) < 5:
                raise FrameError("short_reply")
            flag = struct.unpack(">I", info[1:5])[0]
            content = info[5:1 + info[0]] if info[0] >= 4 else info[5:]
        else:
            if len(info) < 5:
                raise FrameError("short_reply")
            flag = struct.unpack(">I", info[0:4])[0]
            content = info[5:]
        out.update(kind="cmd_reply", server_flag=flag,
                   text=content.decode("ascii", "replace").strip("\x00 "))
    elif proto == P_TIME_REQ:
        out.update(kind="time_req")
    else:
        out.update(kind="unknown")
    return out


# ----------------------------------------------------------------- encoders

def _build(proto: int, info: bytes, serial: int) -> bytes:
    body = bytes([5 + len(info), proto]) + info + struct.pack(">H", serial & 0xFFFF)
    return START_SHORT + body + struct.pack(">H", crc_itu(body)) + STOP


def ack(proto: int, serial: int) -> bytes:
    """Server ACK for login / status / alarm: echo protocol + serial."""
    return _build(proto, b"", serial)


def time_reply(serial: int, now: datetime) -> bytes:
    n = now.astimezone(timezone.utc)
    return _build(P_TIME_REQ, bytes([n.year - 2000, n.month, n.day,
                                     n.hour, n.minute, n.second]), serial)


def server_command(text: str, server_flag: int, serial: int) -> bytes:
    """0x80 online command. `text` must be ASCII (e.g. 'RELAY,1#')."""
    cmd = text.encode("ascii")
    info = bytes([4 + len(cmd)]) + struct.pack(">I", server_flag & 0xFFFFFFFF) \
        + cmd + b"\x00\x02"          # language: English
    return _build(P_SERVER_CMD, info, serial)


# Concox command texts. RELAY,1 = cut oil/electricity, RELAY,0 = restore.
# (Older GT06 firmwares use DYD/HFYD; the device answers either way and we
# record the raw reply honestly.)
COMMANDS = {
    "engine_cut": "RELAY,1#",
    "engine_restore": "RELAY,0#",
}


def interval_command(moving_s: int, parked_s: int) -> str:
    """TIMER,<ACC-on s>,<ACC-off s># (Concox GT06N/GT800 family)."""
    return "TIMER,%d,%d#" % (max(5, int(moving_s)), max(10, int(parked_s)))


def reply_ok(text: str):
    """Classify a device reply. True = success, False = explicit failure,
    None = unclear (we keep the raw text; the app shows it)."""
    t = (text or "").lower()
    if any(w in t for w in ("fail", "error", "invalid", "unknown", "not support")):
        return False
    if any(w in t for w in ("success", "ok", "done", "succeed")):
        return True
    return None


# ----------------------------------------------------------------- client side
# Encoders a DEVICE would send. Used only by tracker/sim.py and the tests.

def login_packet(imei: str, serial: int) -> bytes:
    digits = imei.rjust(16, "0")
    return _build(P_LOGIN, bytes.fromhex(digits), serial)


def gps_packet(at: datetime, lat: float, lng: float, speed_kmh: float,
               course: int, serial: int, ignition=None, valid=True,
               sats=9) -> bytes:
    a = at.astimezone(timezone.utc)
    flags = (course & 0x03FF)
    if lat >= 0:
        flags |= 1 << 10
    if lng < 0:
        flags |= 1 << 11
    if valid:
        flags |= 1 << 12
    info = bytes([a.year - 2000, a.month, a.day, a.hour, a.minute, a.second,
                  0xC0 | (sats & 0x0F)])
    info += struct.pack(">II", int(round(abs(lat) * 1800000)),
                        int(round(abs(lng) * 1800000)))
    info += bytes([max(0, min(255, int(speed_kmh)))]) + struct.pack(">H", flags)
    info += b"\x01\xd6\x01\x00\x01\x00\x00\x01"      # MCC 470 (BD), MNC 1, LAC, cell
    if ignition is None:
        return _build(P_GPS_LBS, info, serial)
    info += bytes([1 if ignition else 0, 0, 1])       # ACC, upload mode, realtime
    return _build(P_GPS_LBS_2, info, serial)


def alarm_packet(at: datetime, lat: float, lng: float, speed_kmh: float,
                 alarm: str, serial: int, ignition=True, course=0) -> bytes:
    """0x16 alarm: GPS block + LBS (len-prefixed) + terminal info + voltage +
    GSM + alarm byte + language."""
    gps = gps_packet(at, lat, lng, speed_kmh, course, 0)[4:4 + 18]
    code = {v: k for k, v in ALARMS.items()}.get(alarm, 0)
    term = 0x40 | (0x02 if ignition else 0)
    info = gps + bytes([9]) + b"\x01\xd6\x01\x00\x01\x00\x00\x01" \
        + bytes([term, 4, 4, code, 0x02])
    return _build(P_ALARM, info, serial)


def status_packet(serial: int, ignition=False, relay_cut=False, alarm=None,
                  voltage_level=4) -> bytes:
    code = {v: k for k, v in TERM_ALARMS.items()}.get(alarm, 0)
    b = 0x40 | (0x02 if ignition else 0) | (0x80 if relay_cut else 0) | (code << 3)
    return _build(P_STATUS, bytes([b, voltage_level & 0xFF, 4, 0, 2]), serial)


def heartbeat2_packet(serial: int, battery_v: float, ignition=False, alarm=None) -> bytes:
    code = {v: k for k, v in TERM_ALARMS.items()}.get(alarm, 0)
    b = 0x40 | (0x02 if ignition else 0) | (code << 3)
    info = bytes([b]) + struct.pack(">H", int(round(battery_v * 100))) + bytes([4, 0, 2])
    return _build(P_HEARTBEAT_2, info, serial)


def _build_long(proto: int, info: bytes, serial: int) -> bytes:
    body = struct.pack(">H", 5 + len(info)) + bytes([proto]) + info \
        + struct.pack(">H", serial & 0xFFFF)
    return START_LONG + body + struct.pack(">H", crc_itu(body)) + STOP


def ext_voltage_packet(serial: int, volts: float) -> bytes:
    """0x94 sub-type 0x00 (external power voltage, /100 V), long form."""
    return _build_long(P_INFO, b"\x00" + struct.pack(">H", int(round(volts * 100))),
                       serial)


def reply_packet(server_flag: int, text: str, serial: int) -> bytes:
    c = text.encode("ascii")
    info = bytes([4 + len(c)]) + struct.pack(">I", server_flag) + c + b"\x00\x02"
    return _build(P_STRING_REPLY, info, serial)


def parse_server_command(frame: bytes):
    """Device-side decode of a 0x80 command -> (server_flag, text, serial)."""
    proto, info, serial = _check(frame)
    if proto != P_SERVER_CMD:
        raise FrameError("not_command")
    ln = info[0]
    flag = struct.unpack(">I", info[1:5])[0]
    text = info[5:1 + ln].decode("ascii", "replace")
    return flag, text, serial
