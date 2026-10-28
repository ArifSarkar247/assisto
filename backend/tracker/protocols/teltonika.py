"""
Teltonika FMxxx TCP protocol — PURE parser + encoder (no I/O, no Django).

Session:
  1. device -> 2-byte length + IMEI (ASCII digits)
     server -> 0x01 (accept) or 0x00 (reject)
  2. device -> AVL packet:
        00000000 | data length(4) | codec(1: 0x08 / 0x8E) | N1(1)
        | N1 records | N2(1) | CRC-16/IBM (4, low 2 bytes used)
     CRC covers codec .. N2.
     server -> 4-byte big-endian count of records accepted.
  3. server -> Codec 12 command (0x0C, type 0x05); device answers with a
     Codec 12 response (type 0x06) on the same socket.

Record (Codec 8):  ts(8 ms) prio(1) lng(4) lat(4) alt(2) angle(2) sats(1)
                   speed(2) | eventIO(1) total(1) N1 [id1 v1].. N2 [id1 v2]..
                   N4 [id1 v4].. N8 [id1 v8]..
Record (Codec 8E): same GPS; eventIO(2) total(2) N1(2) [id2 v1].. N2(2)
                   [id2 v2].. N4(2) .. N8(2) .. NX(2) [id2 len2 bytes]..
"""
import struct
from datetime import datetime, timezone

CODEC_8 = 0x08
CODEC_8E = 0x8E
CODEC_12 = 0x0C
MAX_PACKET = 16 * 1024     # FMB packets are ~1.3 KB max; refuse anything huge

# Well-known FMB IO element ids (Teltonika "FMB AVL ID" list). OBD ids only
# appear on OBD-capable models (FMB001/FMB003/FMB010 + OBD Bluetooth / FMM00A).
IO_IGNITION = 239
IO_MOVEMENT = 240
IO_EXT_VOLTAGE = 66        # mV
IO_BATTERY_VOLTAGE = 67    # mV (internal backup battery)
IO_DOUT1 = 179             # digital output 1 (immobilizer relay on most kits)
IO_TOTAL_ODOMETER = 16     # m
IO_UNPLUG = 252            # FMB "Unplug": 1 = device unplugged from main power
OBD_IO = {                 # id -> (our key, scale)
    30: ("dtc_count", 1),
    31: ("engine_load_pct", 1),
    32: ("coolant_temp_c", 1),
    36: ("rpm", 1),
    37: ("obd_speed_kmh", 1),
    48: ("fuel_level_pct", 1),
    51: ("module_voltage_v", 0.001),
    53: ("ambient_temp_c", 1),
}
IO_DTC_CODES = 281         # FMB OBD "Fault codes" (NX / variable length, ASCII)


class FrameError(ValueError):
    pass


def crc16_ibm(data: bytes) -> int:
    crc = 0x0000
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


# ----------------------------------------------------------------- IMEI

def split_imei(buf: bytes):
    """Return (imei or None, rest). None = need more bytes. Raises FrameError
    if this is clearly not a Teltonika IMEI frame."""
    if len(buf) < 2:
        return None, buf
    ln = struct.unpack(">H", buf[:2])[0]
    if ln < 8 or ln > 20:
        raise FrameError("bad_imei_length")
    if len(buf) < 2 + ln:
        return None, buf
    raw = buf[2:2 + ln]
    if not raw.isdigit():
        raise FrameError("bad_imei")
    return raw.decode("ascii"), buf[2 + ln:]


def looks_like_imei_frame(buf: bytes) -> bool:
    if len(buf) < 3:
        return False
    ln = struct.unpack(">H", buf[:2])[0]
    return 8 <= ln <= 20 and 0x30 <= buf[2] <= 0x39


IMEI_ACCEPT = b"\x01"
IMEI_REJECT = b"\x00"


# ----------------------------------------------------------------- AVL

def split_packet(buf: bytes):
    """Return (packet or None, rest). A packet is preamble..CRC inclusive."""
    if len(buf) < 8:
        return None, buf
    if buf[:4] != b"\x00\x00\x00\x00":
        raise FrameError("bad_preamble")
    ln = struct.unpack(">I", buf[4:8])[0]
    total = 8 + ln + 4
    if ln < 3 or total > MAX_PACKET:
        raise FrameError("bad_length")
    if len(buf) < total:
        return None, buf
    return buf[:total], buf[total:]


def _check(packet: bytes):
    ln = struct.unpack(">I", packet[4:8])[0]
    data = packet[8:8 + ln]
    crc = struct.unpack(">I", packet[8 + ln:12 + ln])[0]
    if crc16_ibm(data) != (crc & 0xFFFF):
        raise FrameError("bad_crc")
    return data


def _io_block(data, off, ext):
    """Parse the IO section. Returns (io dict id->int|bytes, event_id, off)."""
    io = {}
    if ext:
        event_id, _total = struct.unpack(">HH", data[off:off + 4])
        off += 4
        for size in (1, 2, 4, 8):
            (n,) = struct.unpack(">H", data[off:off + 2])
            off += 2
            for _ in range(n):
                (iid,) = struct.unpack(">H", data[off:off + 2])
                io[iid] = int.from_bytes(data[off + 2:off + 2 + size], "big")
                off += 2 + size
        (nx,) = struct.unpack(">H", data[off:off + 2])
        off += 2
        for _ in range(nx):
            iid, ln = struct.unpack(">HH", data[off:off + 4])
            io[iid] = bytes(data[off + 4:off + 4 + ln])
            off += 4 + ln
    else:
        event_id, _total = data[off], data[off + 1]
        off += 2
        for size in (1, 2, 4, 8):
            n = data[off]
            off += 1
            for _ in range(n):
                iid = data[off]
                io[iid] = int.from_bytes(data[off + 1:off + 1 + size], "big")
                off += 1 + size
    return io, event_id, off


def parse_packet(packet: bytes) -> dict:
    """Decode a full AVL packet -> {codec, count, records:[fix...]}. Raises
    FrameError on CRC / structure problems (never returns half a packet)."""
    data = _check(packet)
    try:
        codec = data[0]
        if codec == CODEC_12:
            return parse_codec12(data)
        if codec not in (CODEC_8, CODEC_8E):
            raise FrameError("unsupported_codec")
        ext = codec == CODEC_8E
        n1 = data[1]
        off = 2
        recs = []
        for _ in range(n1):
            ts_ms, prio = struct.unpack(">QB", data[off:off + 9])
            off += 9
            lng, lat, alt, angle, sats, speed = struct.unpack(
                ">iihHBH", data[off:off + 15])
            off += 15
            io, event_id, off = _io_block(data, off, ext)
            lat_f, lng_f = lat / 1e7, lng / 1e7
            recs.append({
                "at": datetime.fromtimestamp(ts_ms / 1000.0, tz=timezone.utc),
                "priority": prio, "lat": round(lat_f, 6), "lng": round(lng_f, 6),
                "alt": alt, "course": angle, "sats": sats,
                "speed_kmh": float(speed),
                "valid": sats > 0 and not (lat == 0 and lng == 0),
                "event_io": event_id, "io": io,
                **derive_io(io),
            })
        n2 = data[off]
        if n2 != n1:
            raise FrameError("count_mismatch")
    except (IndexError, struct.error):
        raise FrameError("truncated")
    return {"codec": codec, "count": n1, "records": recs, "kind": "avl"}


def derive_io(io: dict) -> dict:
    """Pull the IO elements Assisto understands into named fields. Unknown ids
    stay in `io` untouched (stored raw, never guessed at)."""
    out = {}
    if IO_IGNITION in io and isinstance(io[IO_IGNITION], int):
        out["ignition"] = bool(io[IO_IGNITION])
    if IO_MOVEMENT in io and isinstance(io[IO_MOVEMENT], int):
        out["movement"] = bool(io[IO_MOVEMENT])
    if isinstance(io.get(IO_EXT_VOLTAGE), int):
        out["ext_voltage_v"] = round(io[IO_EXT_VOLTAGE] / 1000.0, 2)
    if isinstance(io.get(IO_BATTERY_VOLTAGE), int):
        out["battery_v"] = round(io[IO_BATTERY_VOLTAGE] / 1000.0, 2)
    if isinstance(io.get(IO_DOUT1), int):
        out["relay_cut"] = bool(io[IO_DOUT1])
    # veh100: explicit device alarms the server alerts on (rising edge only).
    alarms = []
    if io.get(IO_UNPLUG) == 1:
        alarms.append("power_cut")
    if alarms:
        out["alarms"] = alarms
    obd = {}
    for iid, (key, scale) in OBD_IO.items():
        v = io.get(iid)
        if isinstance(v, int):
            if key in ("coolant_temp_c", "ambient_temp_c") and v > 127:
                v -= 256          # signed byte temperatures
            obd[key] = round(v * scale, 3) if scale != 1 else v
    codes = io.get(IO_DTC_CODES)
    if isinstance(codes, (bytes, bytearray)) and codes:
        txt = codes.decode("ascii", "replace")
        obd["dtc"] = [c.strip().upper() for c in txt.replace(";", ",").split(",")
                      if c.strip()]
    if obd:
        out["obd"] = obd
    return out


def ack(count: int) -> bytes:
    return struct.pack(">I", count)


# ----------------------------------------------------------------- Codec 12

def codec12_command(text: str) -> bytes:
    cmd = text.encode("ascii")
    data = bytes([CODEC_12, 1, 0x05]) + struct.pack(">I", len(cmd)) + cmd + b"\x01"
    return b"\x00\x00\x00\x00" + struct.pack(">I", len(data)) + data \
        + struct.pack(">I", crc16_ibm(data))


def codec12_response(text: str) -> bytes:
    """Device-side response (used by sim / tests)."""
    r = text.encode("ascii")
    data = bytes([CODEC_12, 1, 0x06]) + struct.pack(">I", len(r)) + r + b"\x01"
    return b"\x00\x00\x00\x00" + struct.pack(">I", len(data)) + data \
        + struct.pack(">I", crc16_ibm(data))


def parse_codec12(data: bytes) -> dict:
    if data[0] != CODEC_12:
        raise FrameError("not_codec12")
    typ = data[2]
    (ln,) = struct.unpack(">I", data[3:7])
    text = data[7:7 + ln].decode("ascii", "replace")
    return {"codec": CODEC_12, "kind": "cmd_reply" if typ == 0x06 else "command",
            "type": typ, "text": text, "count": 0, "records": []}


# setdigout <DOUT1><DOUT2>: "1" engages the immobilizer relay on DOUT1 kits.
COMMANDS = {
    "engine_cut": "setdigout 1",
    "engine_restore": "setdigout 0",
}


def interval_command(moving_s: int, parked_s: int) -> str:
    """FMB 'Home network' data-acquisition periods: 10000 = on-stop min period,
    10050 = moving min period (FMB1xx/FMB9xx parameter ids). MODEL-DEPENDENT —
    the reply text is stored so a mismatch is visible, never assumed applied."""
    return "setparam 10000:%d;10050:%d" % (max(10, int(parked_s)),
                                          max(1, int(moving_s)))


def reply_ok(text: str):
    t = (text or "").lower()
    if any(w in t for w in ("error", "fail", "invalid", "not supported")):
        return False
    if t.startswith("dout1:") or "new value" in t or "param id" in t \
            or "ok" in t or "success" in t:
        return True
    return None


# ----------------------------------------------------------------- device side

def imei_frame(imei: str) -> bytes:
    return struct.pack(">H", len(imei)) + imei.encode("ascii")


def build_avl(records, codec=CODEC_8E) -> bytes:
    """Encode records [{at, lat, lng, speed_kmh, course, sats, io:{id:int}}]."""
    ext = codec == CODEC_8E
    body = bytes([codec, len(records)])
    for r in records:
        ts = int(r["at"].timestamp() * 1000)
        body += struct.pack(">QB", ts, 0)
        body += struct.pack(">iihHBH", int(round(r["lng"] * 1e7)),
                            int(round(r["lat"] * 1e7)), int(r.get("alt", 10)),
                            int(r.get("course", 0)), int(r.get("sats", 9)),
                            int(r.get("speed_kmh", 0)))
        io = r.get("io") or {}
        groups = {1: [], 2: [], 4: [], 8: []}
        nx = []
        for iid, v in io.items():
            if isinstance(v, (bytes, bytearray)):
                nx.append((iid, bytes(v)))
                continue
            size = 1 if v < 0x100 else 2 if v < 0x10000 else 4 if v < 0x100000000 else 8
            groups[size].append((iid, v))
        total = sum(len(g) for g in groups.values()) + len(nx)
        if ext:
            body += struct.pack(">HH", 0, total)
            for size in (1, 2, 4, 8):
                body += struct.pack(">H", len(groups[size]))
                for iid, v in groups[size]:
                    body += struct.pack(">H", iid) + v.to_bytes(size, "big")
            body += struct.pack(">H", len(nx))
            for iid, b in nx:
                body += struct.pack(">HH", iid, len(b)) + b
        else:
            body += bytes([0, total])
            for size in (1, 2, 4, 8):
                body += bytes([len(groups[size])])
                for iid, v in groups[size]:
                    body += bytes([iid]) + v.to_bytes(size, "big")
    body += bytes([len(records)])
    return b"\x00\x00\x00\x00" + struct.pack(">I", len(body)) + body \
        + struct.pack(">I", crc16_ibm(body))
