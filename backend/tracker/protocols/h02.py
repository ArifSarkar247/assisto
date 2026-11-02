"""
H02 text protocol (Sinotrack ST-901 / ST-906 / ST-907, many cheap "GPS-103"
style trackers sold in Bangladesh) — PURE parser + encoder (no I/O, no Django).

Frames are ASCII, start with '*' and end with '#':

    *HQ,<imei>,V1,<hhmmss>,<A|V>,<ddmm.mmmm>,<N|S>,<dddmm.mmmm>,<E|W>,
        <speed knots>,<course>,<ddmmyy>,<status hex 8>[,mcc,mnc,lac,cell]#

    *HQ,<imei>,HTBT#            heartbeat (some firmwares: LINK / XT)
    *HQ,<imei>,V4,<cmd>,<result...>#   reply to a server command

There is no login packet: the IMEI travels in every frame. There is no CRC
(it is a text protocol) — we validate structure, ranges and the IMEI instead,
and a frame that does not parse is dropped.

Status word (32 bits, hex): bits are mostly ACTIVE-LOW. We read only what
Traccar's H02 decoder (the de-facto reference) reads: bit 10 = ignition (ACC);
alarms (a CLEAR bit = active): bit 0 vibration, bit 1 or 18 SOS, bit 2
overspeed (device-side), bit 19 main-power cut (veh100). These are LEVELS
repeated in every frame — the server alerts on the rising edge only.
UNPROVEN on a real ST-901 (no real device has connected yet); low battery is
NOT in the GPRS status (Sinotrack sends it by SMS to the admin phone), so we
never claim it for H02. Anything else stays in the raw status.

Server commands (Traccar H02 encoder conventions):
    *HQ,<imei>,S20,<hhmmss>,1,1#     cut oil / electricity (relay)
    *HQ,<imei>,S20,<hhmmss>,1,0#     restore
    *HQ,<imei>,S71,<hhmmss>,22,<s>#  upload interval (seconds)
"""
from datetime import datetime, timezone

START = b"*"
END = b"#"
MAX_FRAME = 256

KNOT_KMH = 1.852


class FrameError(ValueError):
    pass


BIN_START = b"$"
BIN_SHORT = 32       # '$' + 5-byte BCD id + time/date/lat/lng/speed/status ...
BIN_LONG = 45        # same record with trailing extras (Traccar H02FrameDecoder)
BIN_LONG_ID = 42     # 8-byte id variant (15-digit IMEI)


def looks_like_h02(first: bytes) -> bool:
    if first[:1] == BIN_START and len(first) >= 2:
        # binary H02: BCD device id right after '$' (every nibble 0-9)
        return all((b >> 4) < 10 and (b & 0x0F) < 10 for b in first[1:6])
    return first[:1] == START and first[1:3].isalpha()


def _bin_len(buf: bytes):
    """Length of the binary frame at buf[0] ('$'), or None = wait for more.
    Devices send one record per TCP segment almost always; when several
    arrive together the next frame's first byte ('$' or '*') decides."""
    n = len(buf)
    if n in (BIN_SHORT, BIN_LONG_ID, BIN_LONG):
        return n
    for L in (BIN_SHORT, BIN_LONG, BIN_LONG_ID):
        if n > L and buf[L:L + 1] in (BIN_START, START):
            return L
    if n < BIN_LONG:
        return None
    return BIN_SHORT


def split_frames(buf: bytes):
    """(frames, rest). Text '*...#' and binary '$...' frames (veh100b: many
    H02 firmwares, incl. Sinotrack clones, report in binary). Junk before a
    start byte is dropped; an over-long frame raises."""
    frames = []
    while True:
        i_t = buf.find(START)
        i_b = buf.find(BIN_START)
        cands = [x for x in (i_t, i_b) if x >= 0]
        if not cands:
            return frames, b""
        buf = buf[min(cands):]
        if buf[:1] == BIN_START:
            L = _bin_len(buf)
            if L is None:
                return frames, buf
            frames.append(buf[:L])
            buf = buf[L:]
            continue
        j = buf.find(END)
        if j < 0:
            if len(buf) > MAX_FRAME:
                raise FrameError("too_long")
            return frames, buf
        if j + 1 > MAX_FRAME:
            raise FrameError("too_long")
        frames.append(buf[:j + 1])
        buf = buf[j + 1:]


def _nibbles(b: bytes) -> str:
    h = b.hex()
    if not h.isdigit():
        raise FrameError("bad_bcd")
    return h


def parse_binary(frame: bytes) -> dict:
    """Binary H02 position (layout as Traccar H02ProtocolDecoder.decodeBinary):
    '$', id (5 BCD bytes; 8 when the frame is 42 bytes), hhmmss, ddmmyy,
    lat ddmm.mmmm (4 BCD bytes), battery (1), lng dddmm.mmmm + flags
    nibble (5 bytes), speed (3 BCD digits, knots) + course (3 digits),
    status (4 bytes, same bits as the text status word)."""
    if frame[:1] != BIN_START or len(frame) < BIN_SHORT:
        raise FrameError("short_bin")
    o = 1
    if len(frame) == BIN_LONG_ID:
        imei = _nibbles(frame[1:9])[:15]
        o = 9
    else:
        imei = _nibbles(frame[1:6])
        o = 6
    if len(frame) < o + 26:
        raise FrameError("short_bin")
    t = _nibbles(frame[o:o + 6])                     # hhmmss ddmmyy
    lat_s = _nibbles(frame[o + 6:o + 10])            # ddmmmmmm
    battery = frame[o + 10]
    lng_b = frame[o + 11:o + 16]                     # dddmmmmm m+flags
    lng_s = lng_b.hex()
    flags = lng_b[4] & 0x0F
    lng_digits = lng_s[:9]
    if not (lng_digits.isdigit() and t.isdigit()):
        raise FrameError("bad_bcd")
    sp = frame[o + 16:o + 19].hex()                  # sss c cc (c = course)
    if not sp.isdigit():
        raise FrameError("bad_bcd")
    status = int.from_bytes(frame[o + 19:o + 23], "big")
    try:
        at = datetime(2000 + int(t[10:12]), int(t[8:10]), int(t[6:8]),
                      int(t[0:2]), int(t[2:4]), int(t[4:6]), tzinfo=timezone.utc)
    except ValueError:
        raise FrameError("bad_time")
    lat = int(lat_s[:2]) + int(lat_s[2:]) / 10000.0 / 60.0
    lng = int(lng_digits[:3]) + int(lng_digits[3:]) / 10000.0 / 60.0
    if not flags & 0x04:
        lat = -lat
    if not flags & 0x08:
        lng = -lng
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        raise FrameError("bad_range")
    knots = int(sp[:3])
    course = int(sp[3:6]) % 360
    alarms = status_alarms(status)
    fix = {"at": at, "lat": round(lat, 6), "lng": round(lng, 6),
           "speed_kmh": round(knots * KNOT_KMH, 1), "course": course,
           "sats": 0, "valid": bool(flags & 0x02),
           "ignition": bool(status & (1 << 10)), "alarms": alarms}
    return {"kind": "gps", "imei": _imei(imei.lstrip("0") if len(imei) > 10 else imei),
            "fix": fix, "status": status, "battery_pct": battery,
            "alarm": "sos" if "sos" in alarms else None, "alarms": alarms,
            "binary": True}


def _coord(v: str, hemi: str, deg_digits: int) -> float:
    """ddmm.mmmm / dddmm.mmmm. veh100b, from recorded device frames (Traccar
    H02ProtocolDecoderTest): firmwares drop leading zeros ("954.9490" =
    9 deg 54.949 min), some send no dot ("37573392" = 37 deg 57.3392 min)
    and a few sign both parts ("-23-35.3408")."""
    v = (v or "").strip()
    neg = False
    if v.startswith("-") and v.count("-") == 2:
        d, m = v[1:].split("-", 1)
        try:
            deg, minutes = int(d), float(m)
        except ValueError:
            raise FrameError("bad_coord")
        neg = True
    elif v.isdigit() and len(v) >= 7:
        deg, minutes = int(v[:-6]), int(v[-6:]) / 10000.0
    else:
        if not v or "." not in v:
            raise FrameError("bad_coord")
        head, _ = v.split(".", 1)
        if len(head) < 3 or not head.isdigit():
            raise FrameError("bad_coord")
        try:
            deg = int(head[:-2])
            minutes = float(v[len(head) - 2:])
        except ValueError:
            raise FrameError("bad_coord")
    if minutes >= 60 or deg > (90 if deg_digits == 2 else 180):
        raise FrameError("bad_coord")
    out = deg + minutes / 60.0
    if hemi in ("S", "W") or (neg and hemi not in ("N", "E")):
        out = -out
    elif hemi not in ("N", "E"):
        raise FrameError("bad_hemi")
    return round(out, 6)


def _imei(v: str) -> str:
    if not v.isdigit() or not 10 <= len(v) <= 16:
        raise FrameError("bad_imei")
    return v


def parse_frame(frame: bytes) -> dict:
    """Decode one frame from split_frames. Returns {kind, imei, ...}."""
    if frame[:1] == BIN_START:
        return parse_binary(frame)
    try:
        text = frame.decode("ascii")
    except UnicodeDecodeError:
        raise FrameError("not_ascii")
    if not (text.startswith("*") and text.endswith("#")):
        raise FrameError("bad_delims")
    f = text[1:-1].split(",")
    if len(f) < 3:
        if len(f) == 2 and f[1].isdigit():
            return {"kind": "heartbeat", "imei": _imei(f[1])}
        raise FrameError("short")
    imei = _imei(f[1])
    typ = f[2].upper()
    if typ in ("V1", "V2", "V19", "V6"):
        if len(f) < 12:
            raise FrameError("short_v1")
        if not f[3] and f[4].upper() == "V":
            # no GPS time at all (cold start, no fix): alive, nothing to store
            return {"kind": "heartbeat", "imei": imei}
        # date = first 6-digit field after course; a few firmwares insert one
        # extra field before it ("...,047,4,080918,EEE7FBDF").
        di = next((i for i in range(11, min(len(f), 14))
                   if len(f[i]) == 6 and f[i].isdigit()), None)
        if di is None:
            raise FrameError("bad_v1")
        f = f[:11] + f[di:]
        if len(f) < 13:
            f = f + [""]                  # no status word: ignition/alarms unknown
        try:
            hh, mi, ss = int(f[3][0:2]), int(f[3][2:4]), int(f[3][4:6])
            dd, mo, yy = int(f[11][0:2]), int(f[11][2:4]), int(f[11][4:6])
            at = datetime(2000 + yy, mo, dd, hh, mi, ss, tzinfo=timezone.utc)
            lat = _coord(f[5], f[6].upper(), 2)
            lng = _coord(f[7], f[8].upper(), 3)
            knots = float(f[9] or 0)
            course = int(float(f[10] or 0)) % 360
        except (ValueError, IndexError):
            raise FrameError("bad_v1")
        if not (-90 <= lat <= 90 and -180 <= lng <= 180):
            raise FrameError("bad_range")
        try:
            status = int(f[12][:8], 16)
        except ValueError:
            status = None
        fix = {"at": at, "lat": lat, "lng": lng,
               "speed_kmh": round(knots * KNOT_KMH, 1), "course": course,
               "sats": 0, "valid": f[4].upper() == "A"}
        alarm = None
        alarms = []
        if status is not None:
            fix["ignition"] = bool(status & (1 << 10))
            alarms = status_alarms(status)
            if "sos" in alarms:
                alarm = "sos"
        fix["alarms"] = alarms
        return {"kind": "gps", "imei": imei, "fix": fix, "status": status,
                "alarm": alarm, "alarms": alarms}
    if typ in ("HTBT", "LINK", "XT", "NBR"):
        return {"kind": "heartbeat", "imei": imei}
    if typ == "V4":
        return {"kind": "cmd_reply", "imei": imei, "text": ",".join(f[3:])[:200]}
    return {"kind": "unknown", "imei": imei}


def status_alarms(status: int):
    """Active alarms in an H02 status word (active-low bits, Traccar map)."""
    out = []
    if not status & (1 << 1) or not status & (1 << 18):
        out.append("sos")
    if not status & (1 << 19):
        out.append("power_cut")
    if not status & (1 << 0):
        out.append("vibration")
    return out


# ----------------------------------------------------------------- server side

COMMANDS = {
    "engine_cut": "S20,1,1",
    "engine_restore": "S20,1,0",
}


def interval_command(moving_s: int, parked_s: int) -> str:
    """S71,22,<s>: one upload interval (H02 has no ACC-on/off pair)."""
    return "S71,22,%d" % max(10, int(moving_s))


def server_command(imei: str, text: str, now: datetime) -> bytes:
    """'S20,1,1' -> b'*HQ,<imei>,S20,<hhmmss>,1,1#'."""
    code, _, params = text.partition(",")
    t = now.astimezone(timezone.utc).strftime("%H%M%S")
    body = "*HQ,%s,%s,%s%s#" % (imei, code, t, ("," + params) if params else "")
    return body.encode("ascii")


def reply_ok(text: str):
    t = (text or "").lower()
    if any(w in t for w in ("fail", "error", "invalid")):
        return False
    if any(w in t for w in ("done", "ok", "success")):
        return True
    return None


# ----------------------------------------------------------------- device side
# Encoders a DEVICE would send. Used only by tracker/sim.py and the tests.

def _dm(v: float, deg_digits: int) -> str:
    a = abs(v)
    deg = int(a)
    minutes = (a - deg) * 60.0
    return "%0*d%07.4f" % (deg_digits, deg, minutes)


def v1_packet(imei: str, at: datetime, lat: float, lng: float, speed_kmh: float,
              course: int = 0, valid=True, ignition=True, sos=False,
              power_cut=False) -> bytes:
    a = at.astimezone(timezone.utc)
    status = 0xFFFFFFFF
    if not ignition:
        status &= ~(1 << 10)
    if sos:
        status &= ~(1 << 1)
    if power_cut:
        status &= ~(1 << 19)
    s = "*HQ,%s,V1,%s,%s,%s,%s,%s,%s,%.2f,%d,%s,%08X,470,01,0001,0001#" % (
        imei, a.strftime("%H%M%S"), "A" if valid else "V",
        _dm(lat, 2), "N" if lat >= 0 else "S", _dm(lng, 3), "E" if lng >= 0 else "W",
        speed_kmh / KNOT_KMH, int(course) % 360, a.strftime("%d%m%y"), status)
    return s.encode("ascii")


def heartbeat_packet(imei: str) -> bytes:
    return ("*HQ,%s,HTBT#" % imei).encode("ascii")


def reply_packet(imei: str, cmd_code: str, result: str, now: datetime) -> bytes:
    return ("*HQ,%s,V4,%s,%s,%s#" % (imei, cmd_code, result,
                                     now.astimezone(timezone.utc).strftime("%H%M%S"))
            ).encode("ascii")


def parse_server_command(frame: bytes):
    """Device-side decode -> (code, params list)."""
    f = frame.decode("ascii")[1:-1].split(",")
    return f[2], f[4:]


def binary_packet(device_id: str, at: datetime, lat: float, lng: float,
                  speed_kmh: float, course: int, status: int = 0xFFFFFBFF,
                  valid=True, battery=6) -> bytes:
    """Device side (sim/tests): a 32-byte binary H02 record ('$' frame).
    status default = all alarms clear, ACC (bit 10) off."""
    a = at.astimezone(timezone.utc)
    alat, alng = abs(lat), abs(lng)
    lat_d = int(alat)
    lat_m = int(round((alat - lat_d) * 60 * 10000))
    lng_d = int(alng)
    lng_m = int(round((alng - lng_d) * 60 * 10000))
    flags = (0x02 if valid else 0) | (0x04 if lat >= 0 else 0) | (0x08 if lng >= 0 else 0)
    knots = int(round(speed_kmh / KNOT_KMH))
    hexs = (device_id.rjust(10, "0")[-10:]
            + a.strftime("%H%M%S%d%m%y")
            + "%02d%06d" % (lat_d, lat_m)
            + "%02x" % (battery & 0xFF)
            + "%03d%05d%x" % (lng_d, lng_m, flags)
            + "%03d%03d" % (knots, int(course) % 360)
            + "%08x" % (status & 0xFFFFFFFF))
    body = bytes.fromhex(hexs)
    return (b"$" + body).ljust(BIN_SHORT, b"\x00")
