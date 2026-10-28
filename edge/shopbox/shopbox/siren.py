"""Sound a LAN camera's own siren / alarm output (cctvx, owner 28 Oct) — the
owner taps "Siren" on an alert; the server queues a `siren` gateway task and
this PC (on the shop's LAN, holding the camera password) runs it.

Hikvision ISAPI (HTTP digest auth, the camera's own web port, default 80):

  1. built-in speaker (AcuSense / ColorVu "audible warning" models):
       PUT /ISAPI/Event/triggers/notifications/AudioAlarm/1/test?format=json
     plays the configured alarm sound for ~5 s; repeated until `seconds`.
  2. alarm OUTPUT 1 (an external siren / strobe wired to the camera relay):
       PUT /ISAPI/System/IO/outputs/1/trigger
       <IOPortData><outputState>high</outputState></IOPortData>   ... low
     (ISAPI developer guide, "IO" chapter).

A camera that supports neither answers 403/400 "notSupport" -> the result is
an honest `not_supported`, never a fake success. Nothing here may raise into
the task runner; secrets are never logged or returned.
"""
from __future__ import annotations

import time
from typing import Callable, Optional, Tuple

from .vendors import clean_host

AUDIO_TEST = "/ISAPI/Event/triggers/notifications/AudioAlarm/%d/test?format=json"
IO_TRIGGER = "/ISAPI/System/IO/outputs/%d/trigger"
IO_BODY = ('<?xml version="1.0" encoding="UTF-8"?><IOPortData '
           'xmlns="http://www.hikvision.com/ver20/XMLSchema">'
           '<outputState>%s</outputState></IOPortData>')
AUDIO_TEST_S = 5.0
MAX_S = 30


def _requests_put(url: str, body: bytes, headers: dict, timeout: float,
                  auth: Tuple[str, str]) -> int:
    import requests
    from requests.auth import HTTPDigestAuth
    try:
        r = requests.put(url, data=body, headers=headers, timeout=timeout,
                         allow_redirects=False, auth=HTTPDigestAuth(*auth))
        return r.status_code
    except requests.RequestException:
        return 0


def hikvision_siren(host: str, port: int, user: Optional[str], secret: Optional[str],
                    seconds: int = 15, channel: int = 1, *,
                    put: Callable = _requests_put, sleep: Callable = time.sleep,
                    timeout: float = 5.0) -> dict:
    """-> {ok, code, method, seconds}. code: ok | no_password | unreachable |
    auth_failed | not_supported."""
    try:
        h = clean_host(host)
    except ValueError:
        return {"ok": False, "code": "bad_host", "method": "", "seconds": 0}
    if not secret:
        return {"ok": False, "code": "no_password", "method": "", "seconds": 0}
    auth = (user or "admin", secret)
    base = "http://%s:%d" % (h, int(port or 80))
    secs = max(1, min(MAX_S, int(seconds or 15)))
    # 1) the built-in speaker
    st = put(base + AUDIO_TEST % 1, b"", {"Content-Type": "application/json"},
             timeout, auth)
    if st == 0:
        return {"ok": False, "code": "unreachable", "method": "", "seconds": 0}
    if st == 401:
        return {"ok": False, "code": "auth_failed", "method": "", "seconds": 0}
    if 200 <= st < 300:
        played = AUDIO_TEST_S
        while played < secs:
            sleep(AUDIO_TEST_S)
            if not 200 <= put(base + AUDIO_TEST % 1, b"",
                              {"Content-Type": "application/json"}, timeout,
                              auth) < 300:
                break
            played += AUDIO_TEST_S
        return {"ok": True, "code": "ok", "method": "audio_alarm",
                "seconds": int(min(played, secs))}
    # 2) alarm output 1 (external siren on the relay)
    hdr = {"Content-Type": "application/xml"}
    st = put(base + IO_TRIGGER % 1, (IO_BODY % "high").encode(), hdr, timeout, auth)
    if 200 <= st < 300:
        sleep(secs)
        put(base + IO_TRIGGER % 1, (IO_BODY % "low").encode(), hdr, timeout, auth)
        return {"ok": True, "code": "ok", "method": "alarm_output", "seconds": secs}
    if st == 401:
        return {"ok": False, "code": "auth_failed", "method": "", "seconds": 0}
    return {"ok": False, "code": "not_supported", "method": "", "seconds": 0}
