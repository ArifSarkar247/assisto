"""Dahua HTTP API on the LAN (CCTV Guard V3 A2 + B, agent cctvconnect) —
the CGI interface every Dahua (and most Imou-OEM) DVR / NVR / camera has,
HTTP digest auth, password typed once on the Guard Box:

  device   GET /cgi-bin/magicBox.cgi?action=getSerialNo / getDeviceType
  disks    GET /cgi-bin/storageDevice.cgi?action=getDeviceAllInfo
           list.info[i].State=Success|Error|... , .Detail[j].TotalBytes /
           UsedBytes / IsError
  record   GET /cgi-bin/configManager.cgi?action=getConfig&name=RecordMode
           table.RecordMode[ch].Mode = 0 auto(schedule) | 1 manual | 2 off
  cameras  GET /cgi-bin/LogicDeviceManager.cgi?action=getCameraState&uniqueChannels[0]=-1
           states[i].channel / .connectionState = Connected|Disconnected (NVR)
  overwrite GET /cgi-bin/configManager.cgi?action=getConfig&name=StorageGlobal
           table.StorageGlobal.FileHoldTime / .OverWrite? (when present)
  events   GET /cgi-bin/eventManager.cgi?action=attach&codes=[All]&heartbeat=5
           multipart text: "Code=SmartMotionHuman;action=Start;index=0;data={...}"
           (SMD human / vehicle, CrossLineDetection, VideoBlind, StorageFailure ...)

Events are forwarded RAW to the server's Dahua hook (one parser, backend).
Recorded-days needs the multi-step mediaFileFind API; not read yet — the
health card says "not checked" for it on Dahua (honest).
"""
from __future__ import annotations

from typing import Callable, Dict, Iterator, List, Optional, Tuple

from ..vendors import clean_host
from .isapi import IsapiError
from .multipart import MultipartStream, boundary_of

TIMEOUT_S = 6.0
MAX_BODY = 128 * 1024


def parse_kv(text: str) -> Dict[str, str]:
    out = {}
    for line in (text or "").splitlines()[:4000]:
        k, sep, v = line.partition("=")
        if sep:
            out[k.strip()] = v.strip()
    return out


class DahuaClient:
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

    def _get(self, path: str, stream=False, timeout: float = TIMEOUT_S):
        try:
            r = self._sess().request("GET", self.base + path, timeout=timeout,
                                     allow_redirects=False, stream=stream)
        except Exception as e:  # noqa: BLE001
            raise IsapiError("unreachable", str(e)[:120])
        if r.status_code == 401:
            raise IsapiError("auth_failed")
        if r.status_code in (400, 403, 404, 501):
            raise IsapiError("not_supported", "http %d" % r.status_code)
        if r.status_code != 200:
            raise IsapiError("bad_response", "http %d" % r.status_code)
        return r

    def kv(self, path: str) -> Dict[str, str]:
        r = self._get(path)
        body = r.content[:MAX_BODY + 1]
        if len(body) > MAX_BODY:
            raise IsapiError("bad_response", "too large")
        return parse_kv(body.decode("utf-8", "replace"))

    def device_info(self) -> dict:
        sn = self.kv("/cgi-bin/magicBox.cgi?action=getSerialNo").get("sn", "")
        try:
            model = self.kv("/cgi-bin/magicBox.cgi?action=getDeviceType").get("type", "")
        except IsapiError:
            model = ""
        return {"serial": sn[:64], "model": model[:60]}

    def storage(self) -> Dict[str, str]:
        return self.kv("/cgi-bin/storageDevice.cgi?action=getDeviceAllInfo")

    def record_mode(self) -> Dict[str, str]:
        return self.kv("/cgi-bin/configManager.cgi?action=getConfig&name=RecordMode")

    def camera_state(self) -> Dict[str, str]:
        return self.kv("/cgi-bin/LogicDeviceManager.cgi?action=getCameraState"
                       "&uniqueChannels[0]=-1")

    def storage_global(self) -> Dict[str, str]:
        return self.kv("/cgi-bin/configManager.cgi?action=getConfig&name=StorageGlobal")

    def event_stream(self, timeout: float = 70.0) -> Iterator[Tuple[str, bytes]]:
        r = self._get("/cgi-bin/eventManager.cgi?action=attach&codes=[All]&heartbeat=5",
                      stream=True, timeout=timeout)
        mp = MultipartStream(boundary_of(r.headers.get("Content-Type") or "") or "myboundary")
        for chunk in r.iter_content(chunk_size=2048):
            for part in mp.feed(chunk):
                yield part


# ---------------------------------------------------------------- parsing
def _idx(key: str, name: str) -> Optional[int]:
    i = key.find(name + "[")
    if i < 0:
        return None
    j = key.find("]", i)
    try:
        return int(key[i + len(name) + 1:j])
    except ValueError:
        return None


def parse_storage(kv: Dict[str, str]) -> List[dict]:
    disks: Dict[int, dict] = {}
    for k, v in kv.items():
        i = _idx(k, "info")
        if i is None:
            continue
        d = disks.setdefault(i, {"id": str(i + 1), "state": "unknown", "total": 0.0,
                                 "used": 0.0, "err": False})
        if k.endswith(".State"):
            s = v.lower()
            d["state"] = "ok" if s == "success" else ("none" if "notexist" in s or s == "nodisk"
                                                      else "error")
        elif k.endswith(".TotalBytes"):
            d["total"] += _f(v)
        elif k.endswith(".UsedBytes"):
            d["used"] += _f(v)
        elif k.endswith(".IsError") and v.lower() == "true":
            d["err"] = True
    out = []
    for i in sorted(disks):
        d = disks[i]
        st = "error" if d["err"] else d["state"]
        tot = d["total"] / 1e9 if d["total"] else None
        free = max(0.0, d["total"] - d["used"]) / 1e9 if d["total"] else None
        if st == "ok" and tot and free is not None and free <= max(0.5, tot * 0.005):
            st = "full"
        out.append({"id": d["id"], "state": st,
                    "total_gb": round(tot, 1) if tot else None,
                    "free_gb": round(free, 1) if free is not None else None})
    return out


def _f(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def parse_record_mode(kv: Dict[str, str]) -> Dict[int, Optional[bool]]:
    """channel (1-based) -> recording switched on (auto / manual) or off."""
    out = {}
    for k, v in kv.items():
        i = _idx(k, "RecordMode")
        if i is None or not k.endswith(".Mode"):
            continue
        out[i + 1] = {"0": True, "1": True, "2": False}.get(v.strip())
    return out


def parse_camera_state(kv: Dict[str, str]) -> Dict[int, Optional[bool]]:
    chans: Dict[int, Optional[bool]] = {}
    rows: Dict[int, dict] = {}
    for k, v in kv.items():
        i = _idx(k, "states")
        if i is None:
            continue
        r = rows.setdefault(i, {})
        if k.endswith(".channel"):
            r["ch"] = int(_f(v))
        elif k.endswith(".connectionState"):
            r["state"] = v.lower()
    for i, r in rows.items():
        ch = r.get("ch", i) + 1
        st = r.get("state", "")
        chans[ch] = True if st == "connected" else (False if st else None)
    return chans


def parse_overwrite(kv: Dict[str, str]) -> Optional[bool]:
    for k, v in kv.items():
        if k.lower().endswith(".overwrite"):
            return v.strip().lower() in ("true", "1")
    return None


def forward_event(post: Callable, server: str, camera_token: str, ctype: str,
                  body: bytes) -> bool:
    """One attach-stream part to the server's Dahua hook. Heartbeats dropped."""
    if not body or body.strip().lower().startswith(b"heartbeat"):
        return False
    url = "%s/api/v1/shop/hook/dahua/%s" % (server.rstrip("/"), camera_token)
    try:
        st = post(url, body, {"Content-Type": ctype or "text/plain"})
    except Exception:  # noqa: BLE001
        return False
    return 200 <= int(st or 0) < 300
