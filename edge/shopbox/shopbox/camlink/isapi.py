"""Hikvision ISAPI on the LAN (CCTV Guard V3 A2 + B, agent cctvconnect).

What the Guard Box reads from a Hikvision DVR / NVR / camera with the DVR
password the owner typed ONCE on the box (kept encrypted there by
shopbox.secure_store — never sent to our server):

  device   GET  /ISAPI/System/deviceInfo             model, serialNumber, firmware
  status   GET  /ISAPI/System/workingstatus          per-channel online + record,
                                                     per-disk status (most DVR/NVR)
  disks    GET  /ISAPI/ContentMgmt/Storage           hddList (fallback / detail)
  ip chans GET  /ISAPI/ContentMgmt/InputProxy/channels/status   NVR IP cameras
  records  POST /ISAPI/ContentMgmt/search            oldest + newest recording
  events   GET  /ISAPI/Event/notification/alertStream  (multipart, long-lived):
                                                     AcuSense human / vehicle
                                                     line-crossing, intrusion,
                                                     tamper, disk errors ...

Events are forwarded RAW to the server's existing Hikvision parser
(POST /api/v1/shop/hook/hikvision/<camera_token>), so classification lives in
ONE place (backend core/logic/camera_hooks.py + cctv_rules.py).
HTTP digest auth, short timeouts, responses capped, DTDs refused.
"""
from __future__ import annotations

import time
from datetime import datetime, timezone
from typing import Callable, Iterator, List, Optional, Tuple

from .. import onvif as O
from ..vendors import clean_host
from .multipart import MultipartStream, boundary_of

TIMEOUT_S = 6.0
MAX_BODY = 256 * 1024


class IsapiError(Exception):
    def __init__(self, code: str, detail: str = ""):
        super().__init__(code)
        self.code = code
        self.detail = detail[:200]


class IsapiClient:
    """`session` is a requests.Session-like object (tests pass a fake or
    point at a local simulator)."""

    def __init__(self, host: str, port: int = 80, user: str = "admin",
                 password: str = "", session=None, scheme: str = "http"):
        self.base = "%s://%s:%d" % (scheme, clean_host(host), int(port or 80))
        self.host = clean_host(host)
        self._auth = (user or "admin", password or "")
        self.session = session

    def _sess(self):
        if self.session is None:
            import requests
            from requests.auth import HTTPDigestAuth
            s = requests.Session()
            s.auth = HTTPDigestAuth(*self._auth)
            self.session = s
        return self.session

    def _req(self, method: str, path: str, body: Optional[bytes] = None, stream=False,
             timeout: float = TIMEOUT_S):
        try:
            r = self._sess().request(method, self.base + path, data=body, timeout=timeout,
                                     allow_redirects=False, stream=stream,
                                     headers={"Content-Type": "application/xml"} if body else None)
        except Exception as e:  # noqa: BLE001 - any socket error
            raise IsapiError("unreachable", str(e)[:120])
        if r.status_code == 401:
            raise IsapiError("auth_failed")
        if r.status_code in (403, 404, 405, 501):
            raise IsapiError("not_supported", "http %d" % r.status_code)
        if r.status_code != 200:
            raise IsapiError("bad_response", "http %d" % r.status_code)
        return r

    def xml(self, path: str, body: Optional[bytes] = None):
        r = self._req("POST" if body else "GET", path, body)
        data = r.content[:MAX_BODY + 1]
        if len(data) > MAX_BODY:
            raise IsapiError("bad_response", "too large")
        try:
            return O.parse_xml(data)
        except O.OnvifError as e:
            raise IsapiError("bad_response", e.detail)

    # ---------------------------------------------------------- reads
    def device_info(self) -> dict:
        r = self.xml("/ISAPI/System/deviceInfo")
        return {"model": (O.text(r, "model") or "")[:60],
                "serial": (O.text(r, "serialNumber") or "")[:64],
                "firmware": (O.text(r, "firmwareVersion") or "")[:40],
                "name": (O.text(r, "deviceName") or "")[:60]}

    def working_status(self):
        return self.xml("/ISAPI/System/workingstatus")

    def storage(self):
        return self.xml("/ISAPI/ContentMgmt/Storage")

    def ip_channels(self):
        return self.xml("/ISAPI/ContentMgmt/InputProxy/channels/status")

    def search_records(self, track: int, start: datetime, end: datetime,
                       max_results: int = 40, position: int = 0) -> List[Tuple[float, float]]:
        body = SEARCH_TEMPLATE % {
            "id": "assisto-%d" % int(time.time() * 1000), "track": int(track),
            "start": _iso(start), "end": _iso(end), "max": int(max_results),
            "pos": int(position)}
        root = self.xml("/ISAPI/ContentMgmt/search", body.encode())
        out = []
        for m in O.find_all(root, "searchMatchItem"):
            s, e = _parse_iso(O.text(m, "startTime")), _parse_iso(O.text(m, "endTime"))
            if s and e:
                out.append((s, e))
        return out

    # ---------------------------------------------------------- events
    def alert_stream(self, timeout: float = 70.0) -> Iterator[Tuple[str, bytes]]:
        """Yield (content_type, body) parts from the long-lived alertStream.
        The DVR sends a heartbeat every few seconds, so `timeout` is the
        read idle limit; the caller reconnects with a back-off."""
        r = self._req("GET", "/ISAPI/Event/notification/alertStream", stream=True,
                      timeout=timeout)
        b = boundary_of(r.headers.get("Content-Type") or "") or "boundary"
        mp = MultipartStream(b)
        for chunk in r.iter_content(chunk_size=4096):
            for part in mp.feed(chunk):
                yield part


SEARCH_TEMPLATE = (
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<CMSearchDescription xmlns="http://www.hikvision.com/ver20/XMLSchema" version="2.0">'
    '<searchID>%(id)s</searchID><trackList><trackID>%(track)d</trackID></trackList>'
    '<timeSpanList><timeSpan><startTime>%(start)s</startTime><endTime>%(end)s</endTime>'
    '</timeSpan></timeSpanList><maxResults>%(max)d</maxResults>'
    '<searchResultPostion>%(pos)d</searchResultPostion>'
    '<metadataList><metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor>'
    '</metadataList></CMSearchDescription>')


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(v: Optional[str]) -> Optional[float]:
    if not v:
        return None
    s = v.strip().replace("Z", "+00:00")
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.timestamp()


# ------------------------------------------------------------ parsing
HDD_STATE = {"ok": "ok", "normal": "ok", "0": "ok", "idle": "ok", "sleeping": "ok",
             "unformatted": "unformatted", "1": "unformatted", "error": "error",
             "abnormal": "error", "2": "error", "smarterror": "error", "nohdd": "none",
             "notexist": "none", "offline": "error", "full": "full", "formatting": "formatting"}


def parse_storage(root) -> List[dict]:
    out = []
    for h in O.find_all(root, "hdd"):
        st = (O.text(h, "status") or "").replace(" ", "").lower()
        cap, free = _mb(O.text(h, "capacity")), _mb(O.text(h, "freeSpace"))
        out.append({"id": (O.text(h, "id") or str(len(out) + 1))[:8],
                    "state": HDD_STATE.get(st, "unknown"),
                    "total_gb": cap, "free_gb": free})
    return out


def _mb(v) -> Optional[float]:
    try:
        return round(float(v) / 1024.0, 1)
    except (TypeError, ValueError):
        return None


def _flag(v) -> Optional[bool]:
    s = (v or "").strip().lower()
    if s in ("true", "1", "yes", "online", "connect", "recording"):
        return True
    if s in ("false", "0", "no", "offline", "disconnect", "norecord"):
        return False
    return None


def parse_working_status(root) -> Tuple[List[dict], List[dict]]:
    """-> (channels, disks). Channel: online from <online> (or signal loss
    <signal>1</signal>), recording from <recordStatus>/<record>."""
    chans = []
    for c in O.find_all(root, "ChanStatus") + O.find_all(root, "chanStatus"):
        no = O.text(c, "chanNo") or O.text(c, "id")
        try:
            no = int(no)
        except (TypeError, ValueError):
            continue
        online = _flag(O.text(c, "online"))
        sig = O.text(c, "signal")
        if online is None and sig is not None:
            online = sig.strip() == "0"          # 0 = normal, 1 = video loss
        rec = O.text(c, "recordStatus") or O.text(c, "record")
        chans.append({"no": no, "name": "", "online": online, "recording": _flag(rec)})
    disks = []
    for h in O.find_all(root, "HDStatus") + O.find_all(root, "hdStatus"):
        st = (O.text(h, "status") or "").strip().lower()
        disks.append({"id": (O.text(h, "hdNo") or str(len(disks) + 1))[:8],
                      "state": HDD_STATE.get(st, "unknown"),
                      "total_gb": _mb(O.text(h, "volume")),
                      "free_gb": _mb(O.text(h, "freeSpace"))})
    return chans, disks


def parse_ip_channels(root) -> List[dict]:
    out = []
    for c in O.find_all(root, "InputProxyChannelStatus"):
        try:
            no = int(O.text(c, "id") or "")
        except ValueError:
            continue
        out.append({"no": no, "name": "", "online": _flag(O.text(c, "online")),
                    "recording": None})
    return out


def is_heartbeat(ctype: str, body: bytes) -> bool:
    b = body[:2048].lower()
    return b"videoloss" in b and b"<eventstate>inactive" in b


def forward_event(post: Callable, server: str, camera_token: str, ctype: str,
                  body: bytes) -> bool:
    """Hand one alertStream part to the server's Hikvision hook (the same
    URL a camera's own HTTP-listening push uses). Heartbeats are dropped;
    pictures ride along only as their own parts (the server keeps one)."""
    if not body or is_heartbeat(ctype, body):
        return False
    url = "%s/api/v1/shop/hook/hikvision/%s" % (server.rstrip("/"), camera_token)
    try:
        st = post(url, body, {"Content-Type": ctype or "application/xml"})
    except Exception:  # noqa: BLE001
        return False
    return 200 <= int(st or 0) < 300
