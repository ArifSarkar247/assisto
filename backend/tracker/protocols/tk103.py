"""
Coban TK103 / "GPS103" text protocol (Coban TK103A/B, TK102, GPS103 clones,
many cheap motorbike trackers sold in Bangladesh) — PURE parser + encoder
(no I/O, no Django). veh100.

Frames are ASCII and end with ';' (Traccar's Gps103ProtocolDecoder is the
reference we follow; NO real Coban has connected to us yet — unproven):

    ##,imei:359586015829802,A;            login      -> server answers "LOAD"
    359586015829802;                      heartbeat  -> server answers "ON"
    imei:359586015829802,tracker,1610281929,,F,132909.000,A,2346.8100,N,
        09024.7800,E,0.11,0;              position   (no reply)

Position fields: imei, keyword, local date-time yyMMddHHmm[ss], admin phone,
F (GPS) | L (LBS only, no fix), UTC time hhmmss[.sss], A|V, lat ddmm.mmmm,
N|S, lng dddmm.mmmm, E|W, speed (KNOTS), course (optional), ...

Keywords -> our alarm codes (Traccar map). Ignition comes ONLY from the
"acc on" / "acc off" keyword frames — a TK103 that is not wired to ACC never
reports it (we show "unknown", never guess):
    help me -> sos            low battery -> low_battery
    ac alarm / power alarm -> power_cut     acc on / acc off -> ignition
    move / shock / sensor alarm -> vibration (stored, no alert)
    jt / kt  (engine stop / resume confirmation on TK103B firmwares)

There is no CRC: structure, ranges and the IMEI are validated instead and a
frame that does not parse is dropped.

Server commands (Coban SMS/GPRS command set, Traccar Gps103ProtocolEncoder):
    **,imei:<imei>,J;        cut oil / electricity (relay)
    **,imei:<imei>,K;        resume
    **,imei:<imei>,C,<n>s;   upload interval (seconds)
"""
from datetime import datetime, timedelta, timezone

END = b";"
MAX_FRAME = 512
KNOT_KMH = 1.852

KEYWORD_ALARMS = {
    "help me": "sos", "low battery": "low_battery", "ac alarm": "power_cut",
    "power alarm": "power_cut", "move": "vibration", "shock": "vibration",
    "sensor alarm": "vibration",
}
REPLY_KEYWORDS = {"jt": ("engine_cut", True), "kt": ("engine_restore", True)}


class FrameError(ValueError):
    pass


def looks_like_tk103(first: bytes) -> bool:
    if first.startswith(b"##,") or first.startswith(b"imei:"):
        return True
    head = first.split(b";", 1)[0]
    return 10 <= len(head) <= 16 and head.isdigit() and b";" in first


def split_frames(buf: bytes):
    """(frames, rest). Leading CR/LF/space between frames is dropped; an
    over-long frame raises."""
    frames = []
    while True:
        buf = buf.lstrip(b"\r\n ")
        j = buf.find(END)
        if j < 0:
            if len(buf) > MAX_FRAME:
                raise FrameError("too_long")
            return frames, buf
        if j + 1 > MAX_FRAME:
            raise FrameError("too_long")
        frames.append(buf[:j + 1])
        buf = buf[j + 1:]


def _imei(v: str) -> str:
    v = v.strip()
    if v.startswith("imei:"):
        v = v[5:]
    if not v.isdigit() or not 10 <= len(v) <= 16:
        raise FrameError("bad_imei")
    return v


def _coord(v: str, hemi: str, deg_digits: int) -> float:
    if not v or "." not in v:
        raise FrameError("bad_coord")
    head = v.split(".", 1)[0]
    if len(head) < deg_digits + 2 - 1:
        raise FrameError("bad_coord")
    deg = int(v[:len(head) - 2] or 0)
    minutes = float(v[len(head) - 2:])
    if minutes >= 60:
        raise FrameError("bad_coord")
    out = deg + minutes / 60.0
    if hemi in ("S", "W"):
        out = -out
    elif hemi not in ("N", "E"):
        raise FrameError("bad_hemi")
    return round(out, 6)


def _when(local_field: str, utc_field: str, now: datetime):
    """Device UTC fix time. The date comes from the LOCAL date-time field and
    the time from the UTC field; fix a day roll-over when local and UTC sit
    on different calendar days (Dhaka is UTC+6)."""
    try:
        hh, mi, ss = int(utc_field[0:2]), int(utc_field[2:4]), int(utc_field[4:6])
    except (ValueError, IndexError):
        raise FrameError("bad_time")
    if local_field and len(local_field) >= 10 and local_field[:10].isdigit():
        yy, mo, dd = int(local_field[0:2]), int(local_field[2:4]), int(local_field[4:6])
        lh, lm = int(local_field[6:8]), int(local_field[8:10])
        try:
            local = datetime(2000 + yy, mo, dd, lh, lm)
            cand = datetime(2000 + yy, mo, dd, hh, mi, ss)
        except ValueError:
            raise FrameError("bad_date")
        diff = (local - cand).total_seconds() / 3600.0
        if diff < -14:
            cand -= timedelta(days=1)
        elif diff > 14:
            cand += timedelta(days=1)
        return cand.replace(tzinfo=timezone.utc)
    n = now.astimezone(timezone.utc)
    try:
        cand = n.replace(hour=hh, minute=mi, second=ss, microsecond=0)
    except ValueError:
        raise FrameError("bad_time")
    if cand - n > timedelta(hours=12):
        cand -= timedelta(days=1)
    return cand


def parse_frame(frame: bytes, now: datetime = None) -> dict:
    """Decode one frame from split_frames -> {kind, imei, ...}."""
    now = now or datetime.now(timezone.utc)
    try:
        text = frame.decode("ascii").strip()
    except UnicodeDecodeError:
        raise FrameError("not_ascii")
    if not text.endswith(";"):
        raise FrameError("bad_delims")
    body = text[:-1]
    if body.startswith("##,"):
        f = body.split(",")
        if len(f) < 2:
            raise FrameError("short_login")
        return {"kind": "login", "imei": _imei(f[1])}
    if body.isdigit():
        return {"kind": "heartbeat", "imei": _imei(body)}
    if not body.startswith("imei:"):
        raise FrameError("unknown_frame")
    f = body.split(",")
    imei = _imei(f[0])
    kw = (f[1] if len(f) > 1 else "").strip().lower()
    if kw in REPLY_KEYWORDS:
        kind, ok = REPLY_KEYWORDS[kw]
        return {"kind": "cmd_reply", "imei": imei, "text": kw, "ok": ok,
                "for_kind": kind}
    out = {"kind": "gps", "imei": imei, "keyword": kw}
    alarms = []
    if kw in KEYWORD_ALARMS:
        alarms.append(KEYWORD_ALARMS[kw])
    ignition = True if kw == "acc on" else (False if kw == "acc off" else None)
    if len(f) < 12:
        # keyword-only frame (some firmwares send "imei:..,acc on,..;" short)
        out.update(kind="event", alarms=alarms, ignition=ignition)
        return out
    gps_ok = f[4].strip().upper() == "F"
    if not gps_ok or not f[7] or not f[9]:
        out.update(kind="event", alarms=alarms, ignition=ignition)
        return out
    try:
        at = _when(f[2].strip(), f[5].strip(), now)
        lat = _coord(f[7].strip(), f[8].strip().upper(), 2)
        lng = _coord(f[9].strip(), f[10].strip().upper(), 3)
        knots = float(f[11] or 0)
        course = int(float(f[12])) % 360 if len(f) > 12 and f[12].strip() else 0
    except (ValueError, IndexError):
        raise FrameError("bad_position")
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        raise FrameError("bad_range")
    fix = {"at": at, "lat": lat, "lng": lng,
           "speed_kmh": round(knots * KNOT_KMH, 1), "course": course,
           "sats": 0, "valid": f[6].strip().upper() == "A", "alarms": alarms}
    if ignition is not None:
        fix["ignition"] = ignition
    out["fix"] = fix
    return out


# ----------------------------------------------------------------- server side

LOGIN_REPLY = b"LOAD"
HEARTBEAT_REPLY = b"ON"

COMMANDS = {"engine_cut": "J", "engine_restore": "K"}


def interval_command(moving_s: int, parked_s: int) -> str:
    """C,<n>s: one upload interval (TK103 has no ACC-on/off pair)."""
    return "C,%ds" % max(10, int(moving_s))


def server_command(imei: str, text: str) -> bytes:
    return ("**,imei:%s,%s;" % (imei, text)).encode("ascii")


def reply_ok(text: str):
    t = (text or "").lower()
    if t in REPLY_KEYWORDS:
        return True
    return None


# ----------------------------------------------------------------- device side
# Encoders a DEVICE would send. Used only by tracker/sim.py and the tests.

def _dm(v: float, deg_digits: int) -> str:
    a = abs(v)
    deg = int(a)
    minutes = (a - deg) * 60.0
    return "%0*d%07.4f" % (deg_digits, deg, minutes)


def login_packet(imei: str) -> bytes:
    return ("##,imei:%s,A;" % imei).encode("ascii")


def heartbeat_packet(imei: str) -> bytes:
    return ("%s;" % imei).encode("ascii")


def position_packet(imei: str, at: datetime, lat: float, lng: float,
                    speed_kmh: float, course: int = 0, keyword="tracker",
                    valid=True, local_offset_h=6) -> bytes:
    a = at.astimezone(timezone.utc)
    local = a + timedelta(hours=local_offset_h)
    s = "imei:%s,%s,%s,,F,%s.000,%s,%s,%s,%s,%s,%.2f,%d;" % (
        imei, keyword, local.strftime("%y%m%d%H%M"), a.strftime("%H%M%S"),
        "A" if valid else "V", _dm(lat, 2), "N" if lat >= 0 else "S",
        _dm(lng, 3), "E" if lng >= 0 else "W", speed_kmh / KNOT_KMH, int(course) % 360)
    return s.encode("ascii")


def reply_packet(imei: str, keyword: str) -> bytes:
    return ("imei:%s,%s,,,F,,,,,,,;" % (imei, keyword)).encode("ascii")


def parse_server_command(frame: bytes):
    """Device-side decode of '**,imei:<imei>,J;' -> (imei, command text)."""
    t = frame.decode("ascii").strip()
    if not t.startswith("**,imei:") or not t.endswith(";"):
        raise FrameError("not_command")
    body = t[len("**,imei:"):-1]
    imei, _, cmd = body.partition(",")
    return imei, cmd
