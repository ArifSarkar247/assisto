"""
JT/T 808 (China national vehicle-terminal standard, 2013 + 2019 headers) —
PURE parser + encoder (no I/O, no Django). veh100b.

Many 4G (LTE Cat-1) vehicle trackers sold in Bangladesh speak JT808 out of
the box or as a menu option (Jimi JM-VL03, Howen, Queclink-OEM, most
"4G GPS tracker relay" listings). Layout follows the public standard
JT/T 808-2013 / -2019 and Traccar's Jt808ProtocolDecoder (the de-facto
reference); every decoder path is tested against frames RECORDED from real
devices (Traccar Jt808ProtocolDecoderTest, Apache-2.0) in
core/tests_veh100b.py.

Frame:  0x7E | escaped( header | body | xor-checksum ) | 0x7E
        escape: 0x7E -> 0x7D 0x02, 0x7D -> 0x7D 0x01
Header: msg id (2) | props (2: body length bits 0-9, sub-package bit 13,
        2019-version bit 14) | [version (1)] | terminal phone (BCD 6, or 10
        in 2019) | serial (2) | [package total (2) + index (2)]

TIME: the standard says device time is GMT+8 (Beijing). We convert to UTC
here (TIME_OFFSET_H). A device someone re-configured to local time is
caught by the server's clock-offset check (core.logic.vehicle_tracking
.correct_clock) only when it runs AHEAD of UTC+8 — documented limit.

Security: like every tracker protocol here it is plain TCP; the IMEI /
terminal-id allowlist on the server is the gate. Authentication codes we
hand out at 0x8100 are not secrets (devices echo them in clear).
"""
from datetime import datetime, timedelta, timezone
import struct

FLAG = 0x7E
ESC = 0x7D
MAX_FRAME = 2048          # a 0x0704 batch of 5 records is ~600 bytes
TIME_OFFSET_H = 8         # JT808 device time is Beijing time by the standard
STRICT_CHECKSUM = False

# terminal -> platform
M_GENERAL_RESP = 0x0001
M_HEARTBEAT = 0x0002
M_LOGOUT = 0x0003
M_REGISTER = 0x0100
M_AUTH = 0x0102
M_LOCATION = 0x0200
M_LOCATION_BATCH = 0x0704
# platform -> terminal
P_GENERAL_RESP = 0x8001
P_REGISTER_RESP = 0x8100
P_SET_PARAMS = 0x8103
P_TEXT = 0x8300
P_VEHICLE_CONTROL = 0x8500

# alarm-flag bits (JT/T 808 table 24)
ALARM_BITS = {0: "sos", 1: "overspeed", 7: "low_battery", 8: "power_cut",
              29: "collision", 31: "door"}
# status bits (table 25)
ST_ACC, ST_LOCATED, ST_SOUTH, ST_WEST, ST_OIL_CUT, ST_CIRCUIT_CUT = 0, 1, 2, 3, 10, 11


class FrameError(ValueError):
    pass


def looks_like_jt808(first: bytes) -> bool:
    # 0x7E then a terminal message id 0x00xx / 0x01xx / 0x02xx / 0x07xx
    return len(first) >= 3 and first[0] == FLAG and first[1] in (0x00, 0x01, 0x02, 0x07, 0x09)


def unescape(b: bytes) -> bytes:
    out = bytearray()
    i = 0
    n = len(b)
    while i < n:
        c = b[i]
        if c == ESC and i + 1 < n:
            nx = b[i + 1]
            if nx == 0x02:
                out.append(FLAG)
            elif nx == 0x01:
                out.append(ESC)
            else:
                # recorded firmware that does not escape: keep the byte as-is
                # (Traccar does the same) — the checksum then flags it.
                out.append(c)
                i += 1
                continue
            i += 2
            continue
        out.append(c)
        i += 1
    return bytes(out)


def escape(b: bytes) -> bytes:
    return b.replace(bytes([ESC]), b"\x7d\x01").replace(bytes([FLAG]), b"\x7d\x02")


def xor(b: bytes) -> int:
    x = 0
    for c in b:
        x ^= c
    return x


def split_frames(buf: bytes):
    """(frames, rest): each frame is the UNESCAPED content between two 0x7E
    (header..checksum). Junk before the first 0x7E is dropped."""
    frames = []
    while True:
        i = buf.find(bytes([FLAG]))
        if i < 0:
            return frames, b""
        buf = buf[i:]
        # skip repeated flags (some devices send 7E 7E between frames)
        k = 1
        while k < len(buf) and buf[k] == FLAG:
            k += 1
        buf = buf[k - 1:]
        j = buf.find(bytes([FLAG]), 1)
        if j < 0:
            if len(buf) > MAX_FRAME:
                raise FrameError("too_long")
            return frames, buf
        if j > MAX_FRAME:
            raise FrameError("too_long")
        frames.append(unescape(buf[1:j]))
        buf = buf[j + 1:]


def _bcd(b: bytes) -> str:
    return b.hex()


def _phone_id(raw_hex: str) -> str:
    s = raw_hex.lstrip("0")
    if not s.isdigit() or len(s) < 6:
        raise FrameError("bad_terminal_id")
    return s


def parse_header(frame: bytes):
    if len(frame) < 13:
        raise FrameError("short")
    # Checksum mismatches are FLAGGED, not dropped: 6 of 77 frames recorded
    # from real devices (Traccar Jt808ProtocolDecoderTest — Traccar never
    # checks it) do not match, and the checksum is no security anyway.
    checksum_ok = xor(frame[:-1]) == frame[-1]
    if not checksum_ok and STRICT_CHECKSUM:
        raise FrameError("bad_checksum")
    msg_id, props = struct.unpack(">HH", frame[:4])
    body_len = props & 0x03FF
    sub = bool(props & (1 << 13))
    v2019 = bool(props & (1 << 14))
    o = 4
    if v2019:
        o += 1                                   # protocol version
        phone = _bcd(frame[o:o + 10])
        o += 10
    else:
        phone = _bcd(frame[o:o + 6])
        o += 6
    serial = struct.unpack(">H", frame[o:o + 2])[0]
    o += 2
    if sub:
        o += 4
    body = frame[o:-1]
    if len(body) < body_len:
        raise FrameError("truncated")
    return msg_id, _phone_id(phone), serial, body[:body_len], v2019, phone, checksum_ok


def _time(b: bytes):
    s = b.hex()
    if not s.isdigit():
        raise FrameError("bad_time")
    try:
        local = datetime(2000 + int(s[0:2]), int(s[2:4]), int(s[4:6]),
                         int(s[6:8]), int(s[8:10]), int(s[10:12]), tzinfo=timezone.utc)
    except ValueError:
        raise FrameError("bad_time")
    return local - timedelta(hours=TIME_OFFSET_H)


def parse_location(body: bytes) -> dict:
    """0x0200 body -> our fix dict (UTC time, km/h)."""
    if len(body) < 28:
        raise FrameError("short_location")
    alarm, status, lat_r, lng_r = struct.unpack(">IIII", body[:16])
    alt, speed10, course = struct.unpack(">hHH", body[16:22])
    at = _time(body[22:28])
    lat = lat_r / 1e6
    lng = lng_r / 1e6
    if status & (1 << ST_SOUTH):
        lat = -lat
    if status & (1 << ST_WEST):
        lng = -lng
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        raise FrameError("bad_range")
    alarms = sorted({name for bit, name in ALARM_BITS.items() if alarm & (1 << bit)})
    fix = {"at": at, "lat": round(lat, 6), "lng": round(lng, 6),
           "speed_kmh": round(speed10 / 10.0, 1), "course": course % 360,
           "sats": 0, "valid": bool(status & (1 << ST_LOCATED)),
           "ignition": bool(status & (1 << ST_ACC)),
           "relay_cut": bool(status & (1 << ST_OIL_CUT)),
           "alarms": [a for a in alarms if a in ("sos", "power_cut", "low_battery")]}
    # additional items: id(1) len(1) value
    o = 28
    obd = {}
    while o + 2 <= len(body):
        iid, ln = body[o], body[o + 1]
        v = body[o + 2:o + 2 + ln]
        o += 2 + ln
        if len(v) < ln:
            break
        if iid == 0x01 and ln == 4:          # mileage, 1/10 km
            fix["odometer_km"] = struct.unpack(">I", v)[0] / 10.0
        elif iid == 0x02 and ln == 2:        # fuel, 1/10 L
            obd["fuel_l"] = struct.unpack(">H", v)[0] / 10.0
        elif iid == 0x30 and ln == 1:        # GSM signal
            fix["gsm"] = v[0]
        elif iid == 0x31 and ln == 1:        # GNSS satellites
            fix["sats"] = v[0]
        elif iid == 0x2B and ln == 4:        # analog AD0/AD1 (vendor: ext. voltage on some)
            pass
    if obd:
        fix["obd"] = obd
    return fix


def parse_frame(frame: bytes) -> dict:
    """Decode one UNESCAPED frame from split_frames."""
    msg_id, tid, serial, body, v2019, phone, ck = parse_header(frame)
    out = {"msg_id": msg_id, "imei": tid, "serial": serial, "phone_hex": phone,
           "v2019": v2019, "checksum_ok": ck}
    if msg_id == M_REGISTER:
        out["kind"] = "register"
    elif msg_id == M_AUTH:
        out.update(kind="auth", code=body.decode("ascii", "replace")[:64])
    elif msg_id == M_HEARTBEAT:
        out["kind"] = "heartbeat"
    elif msg_id == M_LOGOUT:
        out["kind"] = "logout"
    elif msg_id == M_LOCATION:
        out.update(kind="gps", fix=parse_location(body))
    elif msg_id == M_LOCATION_BATCH:
        if len(body) < 3:
            raise FrameError("short_batch")
        n, typ = struct.unpack(">HB", body[:3])
        o = 3
        fixes = []
        for _ in range(min(n, 50)):
            if o + 2 > len(body):
                break
            ln = struct.unpack(">H", body[o:o + 2])[0]
            item = body[o + 2:o + 2 + ln]
            o += 2 + ln
            try:
                f = parse_location(item)
            except FrameError:
                continue
            if typ == 1:
                f["buffered"] = True             # blind-area re-upload
            fixes.append(f)
        out.update(kind="gps_batch", fixes=fixes)
    elif msg_id == M_GENERAL_RESP:
        if len(body) < 5:
            raise FrameError("short_resp")
        rs, rid, res = struct.unpack(">HHB", body[:5])
        out.update(kind="cmd_reply", reply_serial=rs, reply_id=rid, result=res,
                   text="JT808 %04X result=%d" % (rid, res))
    else:
        out["kind"] = "unknown"
    return out


# ----------------------------------------------------------------- encoders

def build(msg_id: int, phone_hex: str, serial: int, body: bytes = b"",
          v2019: bool = False) -> bytes:
    props = len(body) & 0x03FF
    if v2019:
        props |= 1 << 14
        head = struct.pack(">HHB", msg_id, props, 1) + bytes.fromhex(phone_hex.rjust(20, "0"))
    else:
        head = struct.pack(">HH", msg_id, props) + bytes.fromhex(phone_hex.rjust(12, "0")[-12:])
    raw = head + struct.pack(">H", serial & 0xFFFF) + body
    raw += bytes([xor(raw)])
    return bytes([FLAG]) + escape(raw) + bytes([FLAG])


def general_response(pkt: dict, serial: int, result: int = 0) -> bytes:
    body = struct.pack(">HHB", pkt["serial"], pkt["msg_id"], result)
    return build(P_GENERAL_RESP, pkt["phone_hex"], serial, body, pkt.get("v2019"))


def register_response(pkt: dict, serial: int, auth_code: str) -> bytes:
    body = struct.pack(">HB", pkt["serial"], 0) + auth_code.encode("ascii")
    return build(P_REGISTER_RESP, pkt["phone_hex"], serial, body, pkt.get("v2019"))


# Engine cut: JT808 has no single standard relay command. Most vehicle
# trackers accept the vendor text command inside 0x8300 ("text message
# delivery") — the same RELAY,1# the Concox family uses. The device's
# 0x0001 general response only proves it RECEIVED the text; the server
# confirms the cut from status bit 10 (oil circuit cut) on the next fix.
COMMANDS = {
    "engine_cut": "RELAY,1#",
    "engine_restore": "RELAY,0#",
}


def text_command(phone_hex: str, serial: int, text: str, v2019=False) -> bytes:
    body = b"\x01" + text.encode("ascii")    # flag byte (bit0 = urgent), as Traccar sends
    return build(P_TEXT, phone_hex, serial, body, v2019)


def interval_command(moving_s: int, parked_s: int) -> str:
    """Encoded as a marker; dispatch builds a real 0x8103 frame."""
    return "PARAMS,%d,%d" % (max(5, int(moving_s)), max(10, int(parked_s)))


def params_command(phone_hex: str, serial: int, moving_s: int, parked_s: int,
                   v2019=False) -> bytes:
    """0x8103 set parameters: 0x0029 default report interval (s),
    0x0027 sleep (parked) report interval (s)."""
    items = [(0x0029, int(moving_s)), (0x0027, int(parked_s))]
    body = bytes([len(items)])
    for pid, val in items:
        body += struct.pack(">IBI", pid, 4, val)
    return build(P_SET_PARAMS, phone_hex, serial, body, v2019)


def reply_ok(result: int):
    """0 success, 1 failure, 2 message error, 3 not supported (table 4)."""
    if result == 0:
        return True
    if result in (1, 2, 3):
        return False
    return None


# ----------------------------------------------------------------- device side (sim/tests)

def location_body(at: datetime, lat: float, lng: float, speed_kmh: float, course: int,
                  ignition=False, valid=True, alarms=(), relay_cut=False) -> bytes:
    a = 0
    for bit, name in ALARM_BITS.items():
        if name in alarms:
            a |= 1 << bit
    st = (1 if ignition else 0) | (2 if valid else 0)
    if lat < 0:
        st |= 1 << ST_SOUTH
    if lng < 0:
        st |= 1 << ST_WEST
    if relay_cut:
        st |= 1 << ST_OIL_CUT
    local = at.astimezone(timezone.utc) + timedelta(hours=TIME_OFFSET_H)
    t = bytes.fromhex(local.strftime("%y%m%d%H%M%S"))
    return struct.pack(">IIIIhHH", a, st, int(round(abs(lat) * 1e6)),
                       int(round(abs(lng) * 1e6)), 0, int(round(speed_kmh * 10)),
                       int(course) % 360) + t + b"\x31\x01\x09"


def location_packet(phone_hex: str, serial: int, **kw) -> bytes:
    return build(M_LOCATION, phone_hex, serial, location_body(**kw))


def register_packet(phone_hex: str, serial: int) -> bytes:
    body = struct.pack(">HH", 0, 0) + b"ASSTO" + b"SIM-JT808".ljust(20, b"\x00") \
        + b"0000001" + b"\x00" + b"TEST"
    return build(M_REGISTER, phone_hex, serial, body)


def auth_packet(phone_hex: str, serial: int, code: str) -> bytes:
    return build(M_AUTH, phone_hex, serial, code.encode("ascii"))


def general_response_packet(phone_hex: str, serial: int, reply_serial: int,
                            reply_id: int, result: int = 0) -> bytes:
    return build(M_GENERAL_RESP, phone_hex, serial,
                 struct.pack(">HHB", reply_serial, reply_id, result))
