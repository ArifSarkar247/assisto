"""
ezviz.py — a small client for the EZVIZ Open Platform (open.ezvizlife.com /
open.ys7.com international) for the Smart Cash Guard (owner order 28 Oct,
item 4). KEY-GATED: nothing runs until the owner saves appKey + appSecret in
Owner Admin -> Integrations -> "EZVIZ Open Platform" and the test passes.
Tests inject `http` (no network). NOT YET PROVEN against the real platform —
the request/response shapes follow EZVIZ's public HTTP API docs:

  token      POST https://open.ezvizlife.com/api/lapp/token/get
             form appKey, appSecret -> {"code": "200", "data": {"accessToken",
             "expireTime" (epoch ms), "areaDomain"}}; later calls go to the
             returned areaDomain (tokens are region-bound).
  add        POST <areaDomain>/api/lapp/device/add  accessToken, deviceSerial,
             validateCode (the 6-letter "Verification Code" on the label)
             errors: 20010 wrong code, 20013 added by someone else,
             20017 already in this account, 10002 token expired
  alarms     POST <areaDomain>/api/lapp/alarm/device/list  accessToken,
             deviceSerial, startTime/endTime (ms), status 2, alarmType -1,
             pageSize -> data [{alarmId, alarmType, alarmName, alarmTime,
             alarmPicUrl, isEncrypt, channelNo}]
  capture    POST <areaDomain>/api/lapp/device/capture -> data {picUrl}

Real-time PUSH needs a separate EZVIZ approval ("message subscription",
applied for by work order) — until then the server POLLS the alarm list once
a minute (command ezviz_poll_alarms) for linked cameras only. Pictures the
device encrypts (isEncrypt = 1, keyed by the verification code we never
store) are NOT downloaded: the alert then carries no photo (honest).
Video is never fetched.
"""
import time
from urllib.parse import urlparse

DEFAULT_API_BASE = "https://open.ezvizlife.com"
SNAPSHOT_HOST_SUFFIXES = (".ezvizlife.com", ".ezviz.com", ".ys7.com",
                          ".ezvizru.com", ".hik-connect.com")
TIMEOUT_S = 8
_HUMAN_WORDS = ("human", "person", "people", "pedestrian", "人形", "人体")

_token_cache = {}   # appKey -> (token, area_domain, expires_epoch)

ERROR_HINTS = {
    "20010": "wrong_code", "20013": "taken", "20017": "already_mine",
    "10002": "token_expired", "20002": "no_device", "20007": "offline",
}


class EzvizError(Exception):
    def __init__(self, code, msg=""):
        super().__init__("%s %s" % (code, msg))
        self.code = str(code)
        self.msg = str(msg or "")[:200]

    @property
    def hint(self):
        return ERROR_HINTS.get(self.code, "network" if self.code == "network" else "other")


def _default_http(url, form, timeout):
    import requests
    r = requests.post(url, data=form, timeout=timeout, allow_redirects=False)
    return r.status_code, r.text


def _domain_ok(url):
    try:
        u = urlparse(url)
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    return u.scheme == "https" and any(host.endswith(s) for s in SNAPSHOT_HOST_SUFFIXES)


class EzvizClient:
    def __init__(self, app_key, app_secret, api_base=None, http=None, now=None):
        self.app_key = str(app_key or "").strip()
        self.app_secret = str(app_secret or "").strip()
        self.api_base = (api_base or DEFAULT_API_BASE).rstrip("/")
        self.http = http or _default_http
        self.now = now or time.time

    @classmethod
    def from_integration(cls, http=None):
        from .. import integrations as I
        cfg = I.get("ezviz")
        if not cfg.get("app_key") or not cfg.get("app_secret"):
            return None
        return cls(cfg["app_key"], cfg["app_secret"], cfg.get("api_base"), http=http)

    def _post(self, base, path, form):
        import json
        try:
            status, text = self.http(base + path, form, TIMEOUT_S)
        except Exception as e:  # noqa: BLE001
            raise EzvizError("network", str(e)[:120])
        if status != 200:
            raise EzvizError("http_%s" % status)
        try:
            res = json.loads(text) or {}
        except ValueError:
            raise EzvizError("bad_json")
        code = str(res.get("code", ""))
        if code != "200":
            raise EzvizError(code or "unknown", res.get("msg"))
        return res.get("data")

    def token(self):
        hit = _token_cache.get(self.app_key)
        if hit and hit[2] > self.now() + 60:
            return hit[0], hit[1]
        data = self._post(self.api_base, "/api/lapp/token/get",
                          {"appKey": self.app_key, "appSecret": self.app_secret}) or {}
        tok = data.get("accessToken")
        if not tok:
            raise EzvizError("no_token")
        area = str(data.get("areaDomain") or self.api_base).rstrip("/")
        if not _domain_ok(area + "/"):
            area = self.api_base       # never follow a foreign host
        try:
            exp = float(data.get("expireTime")) / 1000.0
        except (TypeError, ValueError):
            exp = self.now() + 3600
        _token_cache[self.app_key] = (tok, area, exp)
        return tok, area

    def call(self, path, form):
        tok, area = self.token()
        try:
            return self._post(area, path, dict(form, accessToken=tok))
        except EzvizError as e:
            if e.code != "10002":
                raise
            _token_cache.pop(self.app_key, None)          # expired: once more
            tok, area = self.token()
            return self._post(area, path, dict(form, accessToken=tok))

    def add_device(self, serial, verification_code):
        return self.call("/api/lapp/device/add",
                         {"deviceSerial": serial, "validateCode": verification_code})

    def alarms(self, serial, since_ms, until_ms, page_size=20):
        data = self.call("/api/lapp/alarm/device/list", {
            "deviceSerial": serial, "startTime": int(since_ms),
            "endTime": int(until_ms), "status": 2, "alarmType": -1,
            "pageStart": 0, "pageSize": int(page_size)})
        return data if isinstance(data, list) else []

    def capture(self, serial, channel=1):
        data = self.call("/api/lapp/device/capture",
                         {"deviceSerial": serial, "channelNo": int(channel)}) or {}
        return data.get("picUrl") or ""


def parse_alarm(row):
    """One alarm-list row -> {serial, channel, human, alarm_id, at_ms, pic}
    or None. `pic` is None when the picture is device-encrypted."""
    if not isinstance(row, dict):
        return None
    serial = str(row.get("deviceSerial") or "").strip().upper()
    if not serial:
        return None
    try:
        at_ms = int(float(row.get("alarmTime") or 0))
    except (TypeError, ValueError):
        at_ms = 0
    name = ("%s %s" % (row.get("alarmName") or "", row.get("alarmType") or "")).lower()
    pic = row.get("alarmPicUrl")
    enc = str(row.get("isEncrypt") or "0") == "1"
    return {"serial": serial[:40],
            "channel": str(row.get("channelNo") or "1")[:4],
            "human": any(w in name for w in _HUMAN_WORDS),
            "alarm_id": str(row.get("alarmId") or "")[:64],
            "at_ms": at_ms,
            "pic": pic if (isinstance(pic, str) and not enc and _domain_ok(pic)) else None,
            "encrypted_pic": enc}


def snapshot_url_allowed(url):
    return _domain_ok(url)
