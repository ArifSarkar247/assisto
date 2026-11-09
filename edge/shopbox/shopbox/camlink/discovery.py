"""Local auto-discovery (CCTV Guard V3 A3, agent cctvconnect) — find the
DVRs / NVRs / cameras on the shop's Wi-Fi with no PC skills needed:

  * ONVIF WS-Discovery  (any brand; reuses shopbox.onvif.discover)
  * Hikvision SADP      UDP multicast 239.255.255.250:37020, XML <Probe>
                        -> <ProbeMatch> with DeviceSN, DeviceDescription,
                        IPv4Address, HttpPort, CommandPort, Activated, MAC
  * Dahua discovery     UDP 37810 (multicast 239.255.255.251 + broadcast),
                        a 32-byte "DHIP" header + JSON {"method":
                        "DHDiscover.search"} -> client.notifyDevInfo JSON with
                        SerialNo, DeviceType, IPv4Address, HttpPort, Port

All three run from the Guard Box (PC / mini PC / Raspberry Pi / TV box) on
the same network. Results are merged by IP. Nothing here needs or sends a
password; serials are shown to the owner only (they pick their own DVR).
Stdlib only; sockets are injectable for tests.
"""
from __future__ import annotations

import json
import socket
import struct
import time
import uuid
from typing import Callable, Dict, List, Optional

from .. import onvif as O

SADP_ADDR = ("239.255.255.250", 37020)
DAHUA_MCAST = ("239.255.255.251", 37810)
DAHUA_BCAST = ("255.255.255.255", 37810)
MAX_DEVICES = 64


# ------------------------------------------------------------------ SADP
def sadp_probe(probe_id: Optional[str] = None) -> bytes:
    pid = probe_id or str(uuid.uuid4()).upper()
    return ('<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>%s</Uuid>'
            '<Types>inquiry</Types></Probe>' % pid).encode("utf-8")


def _int(v, default=None):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


def parse_sadp(data: bytes, sender_ip: Optional[str] = None) -> List[dict]:
    try:
        root = O.parse_xml(data)
    except O.OnvifError:
        return []
    out = []
    nodes = [root] if O.local(root.tag) == "ProbeMatch" else O.find_all(root, "ProbeMatch")
    for pm in nodes:
        ip = O.text(pm, "IPv4Address") or sender_ip
        if not ip:
            continue
        sn = O.text(pm, "DeviceSN") or ""
        act = (O.text(pm, "Activated") or "").lower()
        out.append({"host": ip, "vendor": "hikvision", "source": "sadp",
                    "model": (O.text(pm, "DeviceDescription") or "")[:60],
                    "serial": sn[:64],
                    "http_port": _int(O.text(pm, "HttpPort"), 80),
                    "sdk_port": _int(O.text(pm, "CommandPort")),
                    "mac": (O.text(pm, "MAC") or "")[:20],
                    "activated": None if not act else act == "true",
                    "channels": _int(O.text(pm, "AnalogChannelNum"), 0) + _int(
                        O.text(pm, "DigitalChannelNum"), 0) or None})
    return out


# ------------------------------------------------------------------ Dahua
def dhip_packet(payload: dict, req_id: int = 0) -> bytes:
    body = json.dumps(payload, separators=(",", ":")).encode()
    hdr = struct.pack("<I4sIIIIII", 0x20, b"DHIP", 0, req_id, len(body), 0, len(body), 0)
    return hdr + body


def dahua_probe() -> bytes:
    return dhip_packet({"method": "DHDiscover.search", "params": {"mac": "", "uni": 1}})


def parse_dahua(data: bytes, sender_ip: Optional[str] = None) -> List[dict]:
    if not data or len(data) > 65535:
        return []
    i = data.find(b"{")
    if i < 0:
        return []
    try:
        msg = json.loads(data[i:].rstrip(b"\x00").decode("utf-8", "replace"))
    except ValueError:
        return []
    info = ((msg.get("params") or {}).get("deviceInfo") or {}) if isinstance(msg, dict) else {}
    if not isinstance(info, dict) or not info:
        return []
    v4 = info.get("IPv4Address") or {}
    ip = (v4.get("IPAddress") if isinstance(v4, dict) else None) or sender_ip
    if not ip:
        return []
    return [{"host": str(ip)[:45], "vendor": "dahua", "source": "dhip",
             "model": str(info.get("DeviceType") or info.get("DeviceClass") or "")[:60],
             "serial": str(info.get("SerialNo") or "")[:64],
             "http_port": _int(info.get("HttpPort"), 80),
             "sdk_port": _int(info.get("Port"), 37777),
             "mac": str(info.get("Mac") or "")[:20],
             "activated": None if "Init" not in info else not bool(info.get("Init")),
             "channels": _int(info.get("VideoInputChannels"))}]


# ------------------------------------------------------------------ loop
def _default_sock(broadcast=False):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    if broadcast:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("", 0))
    return s


def udp_search(dests, msg: bytes, parse: Callable, timeout_s: float = 3.0,
               sock_factory: Optional[Callable] = None,
               clock: Callable[[], float] = time.monotonic) -> List[dict]:
    """Send `msg` to every dest (twice: UDP is lossy) and collect parsed
    devices until the timeout. Unique by host."""
    timeout_s = max(0.5, min(float(timeout_s or 3.0), 15.0))
    sock = (sock_factory or (lambda: _default_sock(broadcast=True)))()
    found: Dict[str, dict] = {}

    def send():
        for d in dests:
            try:
                sock.sendto(msg, d)
            except OSError:
                continue
    try:
        send()
        deadline = clock() + timeout_s
        resent = False
        while len(found) < MAX_DEVICES:
            left = deadline - clock()
            if left <= 0:
                break
            if not resent and left < timeout_s / 2:
                send()
                resent = True
            sock.settimeout(min(left, 0.5))
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            for dev in parse(data, addr[0] if addr else None):
                found.setdefault(dev["host"], dev)
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return list(found.values())


def discover_sadp(timeout_s=3.0, sock_factory=None, clock=time.monotonic):
    return udp_search([SADP_ADDR], sadp_probe(), parse_sadp, timeout_s, sock_factory, clock)


def discover_dahua(timeout_s=3.0, sock_factory=None, clock=time.monotonic):
    return udp_search([DAHUA_MCAST, DAHUA_BCAST], dahua_probe(), parse_dahua, timeout_s,
                      sock_factory, clock)


def _onvif_vendor(dev):
    blob = ("%s %s" % (dev.get("manufacturer") or "", dev.get("model") or "")).lower()
    for v in ("hikvision", "dahua", "imou", "ezviz", "tapo", "tp-link", "reolink"):
        if v in blob:
            return "tapo" if v == "tp-link" else v
    return "onvif"


def merge(onvif_rows, sadp_rows, dahua_rows) -> List[dict]:
    """One row per IP: vendor discovery (serial, model, ports) wins over the
    ONVIF guess; ONVIF adds the xaddr (needed for the RTSP check)."""
    out: Dict[str, dict] = {}
    for r in list(sadp_rows) + list(dahua_rows):
        out.setdefault(r["host"], dict(r, sources=[r["source"]], onvif=None))
    for d in onvif_rows:
        h = d.get("host")
        if not h:
            continue
        if h in out:
            out[h]["onvif"] = d.get("xaddr")
            out[h]["sources"].append("onvif")
        else:
            out[h] = {"host": h, "vendor": _onvif_vendor(d), "source": "onvif",
                      "model": (d.get("model") or "")[:60], "serial": "",
                      "http_port": 80, "sdk_port": None, "mac": "", "activated": None,
                      "channels": None, "onvif": d.get("xaddr"), "sources": ["onvif"]}
    return sorted(out.values(), key=lambda r: tuple(int(p) if p.isdigit() else 0
                                                     for p in r["host"].split(".")))


def discover_all(timeout_s=3.0, onvif_fn=None, sadp_fn=None, dahua_fn=None) -> List[dict]:
    """All three, one after another (a small box: no threads needed, ~3 x
    timeout). Any one failing (no multicast on this Wi-Fi) never stops the
    others."""
    def safe(fn):
        try:
            return fn() or []
        except OSError:
            return []
    on = safe(onvif_fn or (lambda: O.discover(timeout_s)))
    sa = safe(sadp_fn or (lambda: discover_sadp(timeout_s)))
    dh = safe(dahua_fn or (lambda: discover_dahua(timeout_s)))
    return merge(on, sa, dh)
