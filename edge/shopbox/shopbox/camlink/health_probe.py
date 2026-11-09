"""DVR health probe (CCTV Guard V3 part B, agent cctvconnect): read a DVR /
NVR over the LAN and build the report the server's /shop/gateway/dvr-health
expects (backend core/logic/dvr_health.normalize_report). Each read is
optional: a model that does not answer one part leaves it out and the
server shows that part as "not checked" — never as green.

The Guard Box runtime (agent cctvbox) calls probe() a few times a day and
post_reports() with the SITE token; the DVR password stays on the box.
"""
from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from typing import Callable, List, Optional

from . import dahua_api as D
from . import isapi as H
from .isapi import IsapiError


def probe_hikvision(c: H.IsapiClient, now: Optional[float] = None,
                    tracks: Optional[List[int]] = None) -> dict:
    now = now if now is not None else time.time()
    rep = {"source": "isapi", "device": c.host, "at": now, "disks": [], "channels": []}
    try:
        info = c.device_info()
        rep["device"] = info.get("serial") or c.host
        rep["model"] = info.get("model")
    except IsapiError as e:
        if e.code in ("auth_failed", "unreachable"):
            return dict(rep, error=e.code)
    try:
        chans, disks = H.parse_working_status(c.working_status())
        rep["channels"], rep["disks"] = chans, disks
    except IsapiError:
        pass
    if not rep["disks"]:
        try:
            rep["disks"] = H.parse_storage(c.storage())
        except IsapiError:
            pass
    if not rep["channels"]:
        try:
            rep["channels"] = H.parse_ip_channels(c.ip_channels())
        except IsapiError:
            pass
    # recorded range on the first channel's main track (101)
    track = (tracks or [101])[0]
    end = datetime.fromtimestamp(now, timezone.utc)
    try:
        first = c.search_records(track, end - timedelta(days=400), end, max_results=1)
        if first:
            rep["oldest_record"] = first[0][0]
        last = c.search_records(track, end - timedelta(hours=2), end, max_results=40)
        if last:
            rep["latest_record"] = max(e for _s, e in last)
    except IsapiError:
        pass
    return rep


def probe_dahua(c: D.DahuaClient, now: Optional[float] = None) -> dict:
    now = now if now is not None else time.time()
    rep = {"source": "dahua", "device": c.host, "at": now, "disks": [], "channels": []}
    try:
        info = c.device_info()
        rep["device"] = info.get("serial") or c.host
        rep["model"] = info.get("model")
    except IsapiError as e:
        if e.code in ("auth_failed", "unreachable"):
            return dict(rep, error=e.code)
    try:
        rep["disks"] = D.parse_storage(c.storage())
    except IsapiError:
        pass
    online, rec = {}, {}
    try:
        online = D.parse_camera_state(c.camera_state())
    except IsapiError:
        pass
    try:
        rec = D.parse_record_mode(c.record_mode())
    except IsapiError:
        pass
    for ch in sorted(set(online) | set(rec)):
        rep["channels"].append({"no": ch, "name": "", "online": online.get(ch),
                                "recording": rec.get(ch)})
    try:
        ow = D.parse_overwrite(c.storage_global())
        if ow is not None:
            rep["overwrite"] = ow
    except IsapiError:
        pass
    return rep


def probe(vendor: str, host: str, port: int, user: str, password: str,
          session=None, now: Optional[float] = None) -> dict:
    if vendor == "dahua" or vendor == "imou":
        return probe_dahua(D.DahuaClient(host, port, user, password, session=session), now)
    return probe_hikvision(H.IsapiClient(host, port, user, password, session=session), now)


def post_reports(post: Callable, server: str, site_token: str, reports: List[dict]) -> int:
    """POST the reports (no passwords — refused server-side anyway).
    `post(url, json_body, headers) -> status`."""
    clean = [{k: v for k, v in r.items() if k not in ("error", "password", "secret")}
             for r in reports if not r.get("error")]
    if not clean:
        return 0
    return post("%s/api/v1/shop/gateway/dvr-health" % server.rstrip("/"),
                {"reports": clean[:8]}, {"X-Shop-Token": site_token})
