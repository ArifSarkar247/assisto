"""
Kids GPS watch "3G" text protocol (SeTracker / SeTracker2 / Wonlex family,
a.k.a. the "[SG*" protocol) — PURE parser + encoder (no I/O, no Django).
Reference implementation: Traccar's WatchFrameDecoder / WatchProtocolDecoder
/ WatchProtocolEncoder (github.com/traccar/traccar, Apache-2.0). Nothing is
copied; field orders below follow the public "3G protocol" document as
Traccar reads it.

FRAME
    [MF*ID*LLLL*CONTENT]            MF = 2 chars (SG, 3G, CS, ZJ, ...)
    [MF*ID*IIII*LLLL*CONTENT]       newer firmwares: a 4-hex message index
                                    (echoed back in our replies)
    ID   = the watch's 10-digit "registration code" (printed under the QR
           code on the box / back cover; some firmwares send the 15-digit IMEI)
    LLLL = 4 hex digits, length of CONTENT in bytes.
    CONTENT = TYPE[,field,field...]. Binary payloads (TK voice) escape
    0x7D 0x5B 0x5D 0x2C 0x2A as 0x7D 0x01..0x05.

DEVICE -> SERVER (what we read)
    LK[,steps,rolls,battery%]              link / heartbeat   -> reply "LK"
    UD / UD2 / UD3 / UD_LTE / UD_WCDMA,... position (UD2 = blind-area re-send)
    AL / AL_LTE,...                        alarm + position   -> reply "AL"
    position fields: ddMMyy,HHmmss,A|V,lat,N|S,lng,E|W,speed km/h,course,
        altitude,satellites,gsm signal,battery%,steps,rolls,status(hex),
        cell count,ta,mcc,mnc,[lac,cid,rssi]*n,wifi count,[ssid,mac,rssi]*n,
        [accuracy]
    status word (hex): bit 16 SOS, bit 17 low battery, bit 20 watch taken
        off ("removed"), bit 21/22 fall; bit 0 = low-battery LEVEL, bit 3 =
        worn. Alarms are acted on from AL frames and the event bits only.
    TKQ / TKQ2                             "any voice for me?" -> echo
    TK,<binary AMR>                        child's voice note  -> reply "TK,1"
    anything else whose TYPE equals a command we sent = the watch's ACK.

SERVER -> WATCH (command_content(); the ONLY way we build commands)
    UPLOAD,<s>    position interval      CR       locate once now
    SOS,a,b,c     the 3 SOS numbers      FIND     ring the watch ("find")
    TK,<amr>      parent's voice reply   MESSAGE,<UTF-16BE hex> text on screen
    SILENCETIME,hh:mm-hh:mm  class mode (no calls/games in class)
    LZ,<lang>,<tz>  language + time zone PEDO,1   step counter on
    LOWBAT,1      low-battery alarm on   SOSSMS,0 no SOS SMS (we push instead)

NEVER: remote listening. The protocol's "MONITOR,<phone>" (the watch silently
calls a number with the screen off and the microphone on) and its relatives
are refused by command_content() with ForbiddenCommand — there is no "custom"
/ raw command path at all. core.tests_kidswatch fails if any builder ever
emits a FORBIDDEN type.

TRANSPORT HONESTY: plain TCP, no TLS (the watches cannot do TLS). Same
mitigations as the vehicle trackers: ID allow-list (only paired watches),
rate limit, frame caps, idle timeout; the watch can never command us.
"""
from datetime import datetime, timedelta, timezone

START = 0x5B          # [
END = 0x5D            # ]
ESC = 0x7D            # }
_ESC_MAP = {0x01: 0x7D, 0x02: 0x5B, 0x03: 0x5D, 0x04: 0x2C, 0x05: 0x2A}
_UNESC_MAP = {v: k for k, v in _ESC_MAP.items()}
MAX_CONTENT = 96 * 1024          # a 15 s AMR-NB note is ~25 KB; headroom
MAX_HEADER = 48
DEFAULT_TZ_MIN = 360             # Bangladesh: watches show local time (UTC+6)

POSITION_TYPES = ("UD", "UD2", "UD3", "UD_LTE", "UD_WCDMA", "UD_CDMA")
ALARM_TYPES = ("AL", "AL_LTE", "AL_WCDMA", "AL_CDMA")

# The remote-listening family. Never built, never sent. (MONITOR = silent
# call-back with the mic on; CALL = make the watch dial out on its own; the
# rest are aliases / variants seen in vendor documents and forums, plus the
# remote camera capture.)
FORBIDDEN = frozenset({
    # listening / calls the child did not start (3g-elec V1.7 + Beesure docs)
    "MONITOR", "CALL", "ACALL", "GSMANT", "SMS",
    # covert camera (remote snapshot uploaded as "img")
    "RCAPTURE",
    # take-over commands: firmware / debug / identity / server redirect
    "UPGRADE", "DEBUG", "IMEI", "IP",
    # defensive aliases seen in forums (not in the documents we found)
    "MONITOR2", "LISTEN", "JT", "SILENTCALL", "CALLBACK", "AUDIOMONITOR",
})

# status-word event bits (3G protocol document / Traccar decodeAlarm)
BIT_LOW_BATT_LEVEL = 0
BIT_WORN = 3
BIT_SOS = 16
BIT_LOW_BATT = 17
BIT_REMOVED = 20
BIT_FALL = (21,)         # bit 22 = abnormal heart rate on Beesure firmwares


class FrameError(ValueError):
    pass


class ForbiddenCommand(ValueError):
    """A command that could be used to listen in on a child. Never sent."""


def looks_like_watch(first: bytes) -> bool:
    """'[' + two id chars + '*' + digits."""
    if len(first) < 6 or first[0] != START:
        return False
    try:
        head = first[1:MAX_HEADER].decode("ascii", "ignore")
    except Exception:
        return False
    parts = head.split("*")
    return (len(parts) >= 3 and len(parts[0]) == 2 and parts[0].isalnum()
            and parts[1].isdigit() and 6 <= len(parts[1]) <= 16)


# --------------------------------------------------------------- escaping

def escape(data: bytes) -> bytes:
    out = bytearray()
    for b in data:
        if b in _UNESC_MAP:
            out += bytes((ESC, _UNESC_MAP[b]))
        else:
            out.append(b)
    return bytes(out)


def unescape(data: bytes) -> bytes:
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        b = data[i]
        if b == ESC and i + 1 < n and data[i + 1] in _ESC_MAP:
            out.append(_ESC_MAP[data[i + 1]])
            i += 2
            continue
        out.append(b)
        i += 1
    return bytes(out)


# --------------------------------------------------------------- framing

def _header(buf: bytes):
    """(maker, id, index|None, length, content_start) or None when the header
    is not complete yet. Raises FrameError on a malformed header."""
    stars = []
    i = 1
    lim = min(len(buf), MAX_HEADER)
    while i < lim and len(stars) < 4:
        if buf[i] == 0x2A:
            stars.append(i)
            if len(stars) == 3:
                # [MF*ID*LLLL*  or  [MF*ID*IIII*LLLL*  (peek for a 4th star)
                j = i + 1
                if j + 5 <= len(buf) and buf[j + 4] == 0x2A and \
                        _is_hex(buf[j:j + 4]) and _is_hex(buf[stars[1] + 1:i]):
                    stars.append(j + 4)
                break
        i += 1
    if len(stars) < 3:
        if len(buf) >= MAX_HEADER:
            raise FrameError("bad_header")
        return None
    try:
        maker = buf[1:stars[0]].decode("ascii")
        dev = buf[stars[0] + 1:stars[1]].decode("ascii")
    except UnicodeDecodeError:
        raise FrameError("bad_header")
    if len(maker) != 2 or not maker.isalnum() or not dev.isdigit() \
            or not 6 <= len(dev) <= 16:
        raise FrameError("bad_header")
    if len(stars) == 4:
        index = buf[stars[1] + 1:stars[2]].decode("ascii")
        lfield = buf[stars[2] + 1:stars[3]]
        start = stars[3] + 1
    else:
        index = None
        lfield = buf[stars[1] + 1:stars[2]]
        start = stars[2] + 1
    if not _is_hex(lfield) or not 1 <= len(lfield) <= 6:
        raise FrameError("bad_length")
    length = int(lfield, 16)
    if length > MAX_CONTENT:
        raise FrameError("too_long")
    return maker, dev, index, length, start


def _is_hex(b: bytes) -> bool:
    return bool(b) and all(c in b"0123456789abcdefABCDEF" for c in b)


def split_frames(buf: bytes):
    """(frames, rest). Each frame = (maker, id, index, content_bytes) with the
    content UNESCAPED. The end is found from LLLL (counting unescaped bytes,
    or raw bytes on firmwares that count after escaping), else the first raw
    ']' (escaped content never holds a raw ']'). Junk before '[' is dropped;
    an over-long frame raises."""
    frames = []
    while True:
        i = buf.find(b"[")
        if i < 0:
            return frames, b""
        buf = buf[i:]
        h = _header(buf)
        if h is None:
            return frames, buf
        maker, dev, index, length, start = h
        end = _content_end(buf, start, length)
        if end is None:
            if len(buf) - start > MAX_CONTENT * 2 + 16:
                raise FrameError("too_long")
            return frames, buf
        raw = buf[start:end]
        frames.append((maker, dev, index, unescape(raw)))
        buf = buf[end + 1:]
        if buf[:1] in (b"\n", b"\r"):
            buf = buf.lstrip(b"\r\n")


def _content_end(buf, start, length):
    """Index of the closing ']' or None (need more bytes)."""
    # (a) LLLL counts unescaped bytes: walk, skipping escape pairs
    i, got, n = start, 0, len(buf)
    while got < length and i < n:
        i += 2 if (buf[i] == ESC and i + 1 < n and buf[i + 1] in _ESC_MAP) else 1
        got += 1
    if got == length and i < n and buf[i] == END:
        return i
    # (b) LLLL counts raw bytes
    j = start + length
    if j < n and buf[j] == END:
        return j
    # (c) first raw ']' (escaped content never holds one)
    k = buf.find(b"]", start)
    if k >= 0:
        return k
    return None


# --------------------------------------------------------------- content

def _f(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _i(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def _when(date_s, time_s, tz_min):
    """Watch-local ddMMyy HHmmss -> aware UTC datetime (watches show local
    time; Bangladesh = UTC+6). None when unparsable."""
    try:
        dd, mo, yy = int(date_s[0:2]), int(date_s[2:4]), int(date_s[4:6])
        hh, mi, ss = int(time_s[0:2]), int(time_s[2:4]), int(time_s[4:6])
        local = datetime(2000 + yy, mo, dd, hh, mi, ss,
                         tzinfo=timezone(timedelta(minutes=tz_min)))
        return local.astimezone(timezone.utc)
    except (ValueError, IndexError, TypeError):
        return None


def status_alarms(status):
    """Event alarms in a status word (levels like 'worn' are not alarms)."""
    if status is None:
        return []
    out = []
    if status & (1 << BIT_SOS):
        out.append("sos")
    if status & (1 << BIT_LOW_BATT):
        out.append("low_battery")
    if status & (1 << BIT_REMOVED):
        out.append("removed")
    if any(status & (1 << b) for b in BIT_FALL):
        out.append("fall")
    return out


def parse_position(fields, tz_min=DEFAULT_TZ_MIN):
    """fields = the comma fields AFTER the type. Returns a fix dict:
    {at, valid, lat, lng, speed_kmh, course, alt_m, sats, gsm, battery,
     steps, status, alarms, cells:[{mcc,mnc,lac,cid,rssi}], wifi:[{mac,rssi}],
     acc_m}."""
    if len(fields) < 16:
        raise FrameError("short_position")
    at = _when(fields[0], fields[1], tz_min)
    valid = fields[2].upper() == "A"
    try:
        lat = float(fields[3] or 0)
        lng = float(fields[5] or 0)
    except ValueError:
        raise FrameError("bad_coord")
    if fields[4].upper() == "S":
        lat = -lat
    if fields[6].upper() == "W":
        lng = -lng
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        raise FrameError("bad_range")
    if lat == 0 and lng == 0:
        valid = False
    try:
        status = int(fields[15], 16) if fields[15] else None
    except ValueError:
        status = None
    fix = {"at": at, "valid": valid, "lat": round(lat, 6), "lng": round(lng, 6),
           "speed_kmh": round(_f(fields[7]), 1), "course": _i(fields[8]) % 360,
           "alt_m": _f(fields[9]), "sats": _i(fields[10]), "gsm": _i(fields[11]),
           "battery": max(0, min(100, _i(fields[12], -1))) if fields[12] else None,
           "steps": _i(fields[13]), "status": status,
           "alarms": status_alarms(status), "cells": [], "wifi": [], "acc_m": None}
    k = 16
    try:
        n_cells = _i(fields[k]) if k < len(fields) else 0
        if n_cells > 0 and k + 4 + 3 * n_cells <= len(fields):
            mcc, mnc = _i(fields[k + 2]), _i(fields[k + 3])
            for c in range(n_cells):
                b = k + 4 + 3 * c
                fix["cells"].append({"mcc": mcc, "mnc": mnc, "lac": _i(fields[b]),
                                     "cid": _i(fields[b + 1]),
                                     "rssi": _i(fields[b + 2])})
            k = k + 4 + 3 * n_cells
        elif n_cells == 0:
            k += 1
        else:
            k = len(fields)
        if k < len(fields):
            n_wifi = _i(fields[k])
            k += 1
            for w in range(min(n_wifi, 16)):
                if k + 2 >= len(fields):
                    break
                mac = fields[k + 1].strip().lower()
                if _mac_ok(mac):
                    fix["wifi"].append({"mac": mac, "rssi": _i(fields[k + 2])})
                k += 3
        if k < len(fields) and fields[k]:
            acc = _f(fields[k], -1)
            if 0 < acc < 100000:
                fix["acc_m"] = acc
    except IndexError:
        pass
    return fix


def _mac_ok(mac):
    p = mac.split(":")
    return len(p) == 6 and all(len(x) == 2 and _is_hex(x.encode()) for x in p)


def parse_frame(frame, tz_min=DEFAULT_TZ_MIN):
    """frame = (maker, id, index, content) from split_frames. Returns
    {kind, maker, id, index, type, ...}."""
    maker, dev, index, content = frame
    head, sep, rest = content.partition(b",")
    try:
        typ = head.decode("ascii").strip().upper()
    except UnicodeDecodeError:
        raise FrameError("bad_type")
    if not typ or len(typ) > 16:
        raise FrameError("bad_type")
    base = {"maker": maker, "id": dev, "index": index, "type": typ}
    if typ == "TK":
        if len(rest) <= 2:
            # "TK,1" / "TK,0": the watch's answer to OUR voice push, not a note
            return dict(base, kind="other", text=rest.decode("ascii", "replace"),
                        ok=rest.strip() == b"1")
        return dict(base, kind="voice", audio=bytes(rest))
    try:
        text = rest.decode("ascii", "replace")
    except Exception:
        text = ""
    fields = text.split(",") if sep else []
    if typ == "LK":
        out = dict(base, kind="link")
        if len(fields) >= 3:
            out.update(steps=_i(fields[0]), battery=_i(fields[2], -1))
            if out["battery"] < 0:
                out["battery"] = None
        return out
    if typ in POSITION_TYPES or typ in ALARM_TYPES:
        fix = parse_position(fields, tz_min)
        kind = "alarm" if typ in ALARM_TYPES else "position"
        out = dict(base, kind=kind, fix=fix, blind=typ == "UD2")
        if kind == "alarm" and not fix["alarms"]:
            # an AL frame without a known event bit: tell the family "the
            # watch raised an alarm" (never guessed to be an SOS)
            fix["alarms"] = ["alarm"]
        return out
    if typ in ("TKQ", "TKQ2"):
        return dict(base, kind="voice_query")
    return dict(base, kind="other", text=text[:200])


# --------------------------------------------------------------- encoders

def frame(maker, dev, content, index=None):
    """Build a frame (content: str or bytes). Only the binary part of a TK
    voice frame is escaped. Traccar's field-tested encoder conventions: LLLL
    = lower-case hex length AFTER escaping; a watch that sends '3G' is
    answered as 'SG'; a frame with an index header gets '0001'."""
    body = content.encode("ascii") if isinstance(content, str) else bytes(content)
    if len(body) > MAX_CONTENT:
        raise FrameError("too_long")
    # only a binary payload (TK voice) is escaped; text fields are sent as is
    wire = body[:3] + escape(body[3:]) if body[:3] == b"TK," else body
    head = "[%s*%s*" % (reply_maker(maker), dev)
    if index is not None:
        head += "0001*"
    return head.encode("ascii") + ("%04x" % len(wire)).encode("ascii") + b"*" + wire + b"]"


def reply_maker(maker):
    return "SG" if maker == "3G" else (maker or "CS")


def device_frame(maker, dev, content, index=None):
    """What a WATCH sends (simulator / tests): maker kept as is, upper-case
    LLLL counting unescaped bytes (the other convention split_frames reads)."""
    body = content.encode("ascii") if isinstance(content, str) else bytes(content)
    wire = body[:3] + escape(body[3:]) if body[:3] == b"TK," else body
    head = "[%s*%s*" % (maker, dev)
    if index is not None:
        head += "%s*" % index
    return head.encode("ascii") + ("%04X" % len(body)).encode("ascii") + b"*" + wire + b"]"


def reply_for(pkt):
    """The ACK the watch expects for this packet, or None."""
    t = pkt["type"]
    if t == "LK":
        return "LK"
    if t in ALARM_TYPES:
        return "AL"
    if t in ("TKQ", "TKQ2"):
        return t
    if t == "TK":
        # Beesure doc (Traccar sends none; harmless) — only for a real note
        return "TK,1" if pkt.get("kind") == "voice" else None
    if t == "INIT":
        return "INIT,1"
    return None


def _phone(p):
    s = "".join(ch for ch in str(p or "") if ch.isdigit() or ch == "+")
    if s and not 3 <= len(s.lstrip("+")) <= 16:
        raise ValueError("bad_phone")
    return s


def _hhmm(s):
    s = str(s or "")
    if len(s) != 5 or s[2] != ":" or not (s[:2] + s[3:]).isdigit():
        raise ValueError("bad_time")
    if int(s[:2]) > 23 or int(s[3:]) > 59:
        raise ValueError("bad_time")
    return s


INTERVAL_MIN_S = 60
INTERVAL_MAX_S = 3600

# kind -> what the watch is told. EVERYTHING the server can send is here.
COMMAND_KINDS = ("set_interval", "locate_now", "sos_numbers", "find_watch",
                 "voice_down", "message", "class_mode", "class_mode_off",
                 "timezone", "steps_on", "low_battery_alarm", "sos_sms_off")


def command_content(kind, payload=None):
    """(content bytes, ack_type). Raises ForbiddenCommand for anything that
    is not one of COMMAND_KINDS (there is deliberately no raw / custom path),
    ValueError for bad parameters."""
    p = payload or {}
    if kind not in COMMAND_KINDS:
        raise ForbiddenCommand(kind)
    if kind == "set_interval":
        s = max(INTERVAL_MIN_S, min(INTERVAL_MAX_S, int(p.get("seconds") or 600)))
        out = "UPLOAD,%d" % s
    elif kind == "locate_now":
        out = "CR"
    elif kind == "sos_numbers":
        nums = [_phone(x) for x in (p.get("numbers") or [])][:3]
        nums += [""] * (3 - len(nums))
        out = "SOS,%s,%s,%s" % tuple(nums)
    elif kind == "find_watch":
        out = "FIND"
    elif kind == "voice_down":
        audio = bytes(p.get("audio") or b"")
        if not audio:
            raise ValueError("no_audio")
        out = b"TK," + audio
    elif kind == "message":
        txt = str(p.get("text") or "")[:60]
        out = "MESSAGE," + txt.encode("utf-16-be").hex().upper()
    elif kind == "class_mode":
        out = "SILENCETIME,%s-%s" % (_hhmm(p.get("start")), _hhmm(p.get("end")))
    elif kind == "class_mode_off":
        out = "SILENCETIME,"
    elif kind == "timezone":
        tz = float(p.get("tz_hours", 6))
        if not -12 <= tz <= 14:
            raise ValueError("bad_tz")
        out = "LZ,%d,%s" % (int(p.get("lang", 1)), ("%g" % tz))
    elif kind == "steps_on":
        out = "PEDO,1"
    elif kind == "low_battery_alarm":
        out = "LOWBAT,1"
    else:  # sos_sms_off
        out = "SOSSMS,0"
    content = out if isinstance(out, bytes) else out.encode("utf-8")
    typ = content.split(b",", 1)[0].decode("ascii").upper()
    if typ in FORBIDDEN:          # defence in depth: never, whatever the table says
        raise ForbiddenCommand(typ)
    return content, typ


def server_command(maker, dev, kind, payload=None, index=None):
    content, typ = command_content(kind, payload)
    return frame(maker, dev, content, index), typ


def interval_for(phase):
    """Battery-friendly UPLOAD interval (seconds) for a school-mode phase."""
    return {"commute": 60, "at_school": 600, "at_home": 600,
            "night": 3600, "off": 1800}.get(phase, 600)


# --------------------------------------------------------------- device side
# Encoders a WATCH would send. Used only by tracker/sim.py and the tests.

def _local(at, tz_min):
    return at.astimezone(timezone(timedelta(minutes=tz_min)))


def position_content(at, lat, lng, valid=True, speed_kmh=0.0, course=0,
                     battery=80, steps=0, status=0, cells=None, wifi=None,
                     typ="UD", tz_min=DEFAULT_TZ_MIN, acc_m=None):
    loc = _local(at, tz_min)
    f = [typ, loc.strftime("%d%m%y"), loc.strftime("%H%M%S"), "A" if valid else "V",
         "%.6f" % abs(lat), "N" if lat >= 0 else "S", "%.6f" % abs(lng),
         "E" if lng >= 0 else "W", "%.2f" % speed_kmh, "%d" % course, "0.0",
         "9" if valid else "0", "100", str(battery), str(steps), "0",
         "%08X" % status]
    cells = cells or []
    f.append(str(len(cells)))
    if cells:
        f += ["1", str(cells[0].get("mcc", 470)), str(cells[0].get("mnc", 1))]
        for c in cells:
            f += [str(c.get("lac", 0)), str(c.get("cid", 0)), str(c.get("rssi", -70))]
    wifi = wifi or []
    f.append(str(len(wifi)))
    for w in wifi:
        f += [w.get("ssid", "wifi"), w["mac"], str(w.get("rssi", -60))]
    f.append("%g" % acc_m if acc_m else "")
    return ",".join(f)


def parse_server_frame(fr):
    """Device-side decode of a server frame -> (type, content bytes)."""
    _maker, _dev, _index, content = fr
    typ = content.split(b",", 1)[0].decode("ascii", "replace").upper()
    return typ, content
