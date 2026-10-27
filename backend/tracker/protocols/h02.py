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
Traccar's H02 decoder (the de-facto reference) reads: bit 10 = ignition (ACC),
bit 1 clear = SOS. Anything else stays in the raw status so nothing is
over-claimed.

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


def looks_like_h02(first: bytes) -> bool:
    return first[:1] == START and first[1:3].isalpha()


def split_frames(buf: bytes):
    """(frames, rest). Junk before '*' is dropped; an over-long frame raises."""
    frames = []
    while True:
        i = buf.find(START)
        if i < 0:
            return frames, b""
        buf = buf[i:]
        j = buf.find(END)
        if j < 0:
            if len(buf) > MAX_FRAME:
                raise FrameError("too_long")
            return frames, buf
        if j + 1 > MAX_FRAME:
            raise FrameError("too_long")
        frames.append(buf[:j + 1])
        buf = buf[j + 1:]


def _coord(v: str, hemi: str, deg_digits: int) -> float:
    if not v or "." not in v:
        raise FrameError("bad_coord")
    head, _ = v.split(".", 1)
    if len(head) < deg_digits + 2:
        raise FrameError("bad_coord")
    deg = int(v[:len(head) - 2])
    minutes = float(v[len(head) - 2:])
    if minutes >= 60:
        raise FrameError("bad_coord")
    out = deg + minutes / 60.0
    if hemi in ("S", "W"):
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
        if len(f) < 13:
            raise FrameError("short_v1")
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
        if status is not None:
            fix["ignition"] = bool(status & (1 << 10))
            if not status & (1 << 1):
                alarm = "sos"
        return {"kind": "gps", "imei": imei, "fix": fix, "status": status,
                "alarm": alarm}
    if typ in ("HTBT", "LINK", "XT", "NBR"):
        return {"kind": "heartbeat", "imei": imei}
    if typ == "V4":
        return {"kind": "cmd_reply", "imei": imei, "text": ",".join(f[3:])[:200]}
    return {"kind": "unknown", "imei": imei}


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
              course: int = 0, valid=True, ignition=True, sos=False) -> bytes:
    a = at.astimezone(timezone.utc)
    status = 0xFFFFFFFF
    if not ignition:
        status &= ~(1 << 10)
    if sos:
        status &= ~(1 << 1)
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
