"""gboxlinux — DVR / NVR health from the Guard Box, a few times a day.

The LAN reads (Hikvision ISAPI, Dahua CGI: recording on/off, HDD state,
recorded days, channels online) are the camlink library's
(shopbox.camlink.health_probe, agent cctvconnect). This module only decides
WHICH recorders to read and WHEN, and posts the reports to
shop/gateway/dvr-health with the box's token. The DVR password comes from
the box's encrypted store and is never sent or logged.

When camlink is not in this build (an older bundle), DVR health is simply
off and says so in the status — never a fake green.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Callable, Dict, List, Optional, Tuple
from urllib.parse import urljoin

log = logging.getLogger(__name__)

DVR_VENDORS = ("hikvision", "dahua", "imou", "hilook", "cpplus")
EVERY_S = 6 * 3600.0
FIRST_AFTER_S = 120.0
PATH = "shop/gateway/dvr-health"


def camlink_probe() -> Optional[Callable]:
    try:
        from .camlink import health_probe     # agent cctvconnect
        return health_probe.probe
    except Exception:
        return None


def recorders(cfg, creds: Callable[[object], Tuple[Optional[str], Optional[str]]]
              ) -> List[dict]:
    """One entry per recorder (vendor + host) among the configured cameras
    whose brand we can read. -> [{vendor, host, port, user, password, cameras}]"""
    out: Dict[Tuple[str, str], dict] = {}
    for cam in cfg.cameras:
        src = cam.source or {}
        vendor = str(src.get("vendor") or "").lower()
        host = str(src.get("host") or "")
        if vendor not in DVR_VENDORS or not host:
            continue
        user, pwd = creds(cam)
        if not pwd:
            continue
        v = "dahua" if vendor in ("dahua", "imou", "cpplus") else "hikvision"
        key = (v, host)
        if key not in out:
            out[key] = {"vendor": v, "host": host, "port": 80,
                        "user": user or "admin", "password": pwd, "cameras": []}
        if cam.server_id is not None:
            out[key]["cameras"].append(int(cam.server_id))
    return list(out.values())


class DvrHealth(threading.Thread):
    def __init__(self, cfg, creds, base_url: str, token: Callable[[], Optional[str]],
                 probe: Optional[Callable] = None, post: Optional[Callable] = None,
                 every_s: float = EVERY_S, first_after_s: float = FIRST_AFTER_S):
        super().__init__(name="dvr-health", daemon=True)
        self.cfg = cfg
        self.creds = creds
        self.url = urljoin(base_url if base_url.endswith("/") else base_url + "/", PATH)
        self.token = token
        self.probe = probe if probe is not None else camlink_probe()
        self.post = post or self._post
        self.every_s = float(every_s)
        self.first_after_s = float(first_after_s)
        self._halt = threading.Event()
        self.last: Optional[dict] = None     # {at, recorders, posted_status}

    @property
    def available(self) -> bool:
        return self.probe is not None

    def stop(self) -> None:
        self._halt.set()

    def _post(self, url: str, body: dict, headers: dict) -> int:
        import requests
        try:
            return requests.post(url, json=body, headers=headers, timeout=20).status_code
        except requests.RequestException:
            return 0

    def run_once(self) -> dict:
        reports = []
        for r in recorders(self.cfg, self.creds):
            try:
                rep = self.probe(r["vendor"], r["host"], r["port"], r["user"], r["password"])
            except Exception as exc:
                rep = {"error": type(exc).__name__}
            if not isinstance(rep, dict) or rep.get("error"):
                continue
            # exactly camlink's report (the server's dvr_health.normalize_report
            # keeps only its known keys); never a credential
            reports.append({k: v for k, v in rep.items()
                            if k not in ("password", "secret", "user", "error")})
        status = None
        tok = self.token()
        if reports and tok:
            status = self.post(self.url, {"reports": reports[:8]}, {"X-Shop-Token": tok})
        self.last = {"at": time.time(), "recorders": len(reports), "posted_status": status}
        return self.last

    def run(self) -> None:
        if not self.available:
            log.info("DVR health: camlink not in this build (off)")
            return
        if self._halt.wait(self.first_after_s):
            return
        while not self._halt.is_set():
            try:
                self.run_once()
            except Exception:
                log.exception("DVR health round failed")
            self._halt.wait(self.every_s)
