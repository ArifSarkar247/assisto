"""
imou.py — a small client for the Imou Open Platform (open.imoulife.com) used by
the Home & shop watchman (cctv1) for an Imou camera's OWN alarms (motion /
human) + their snapshot URL. KEY-GATED: nothing here runs until the owner saves
appId + appSecret in Owner Admin → Integrations → "Imou Open Platform" and the
test passes. Tests inject `http` (no network).

Protocol (Imou Open API v1): POST <api_base>/<method> with JSON
  {"system": {"ver": "1.0", "appId", "time", "nonce",
              "sign": md5("time:<t>,nonce:<n>,appSecret:<secret>")},
   "params": {...}, "id": "<uuid>"}
answer {"result": {"code": "0", "msg", "data": {...}}}. code "0" = success.

Used methods: accessToken, bindDevice (deviceId + the label's safety code),
setMessageCallback (alarm push to our callback URL), getAlarmMessage (poll
fallback), setDeviceSnapEnhanced (a still for the zone editor).

Video is never fetched: only alarm metadata + at most one still per alarm.
"""
import hashlib
import json
import time
import uuid
from datetime import datetime, timedelta
from urllib.parse import urlparse

DEFAULT_API_BASE = "https://openapi.easy4ip.com/openapi"
# snapshot URLs we are willing to download (SSRF guard): Imou / Dahua clouds
SNAPSHOT_HOST_SUFFIXES = (".easy4ip.com", ".imoulife.com", ".lechange.cn",
                          ".lechange.com", ".easy4ipcloud.com")
MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024
TIMEOUT_S = 8

_token_cache = {}   # appId -> (token, expires_epoch)


class ImouError(Exception):
    def __init__(self, code, msg=""):
        super().__init__("%s %s" % (code, msg))
        self.code = str(code)
        self.msg = str(msg or "")[:200]


def sign(ts, nonce, app_secret):
    raw = "time:%d,nonce:%s,appSecret:%s" % (int(ts), nonce, app_secret)
    return hashlib.md5(raw.encode("utf-8")).hexdigest()


def _default_http(url, body, timeout):
    import requests
    r = requests.post(url, data=body, timeout=timeout,
                      headers={"Content-Type": "application/json"})
    return r.status_code, r.text


class ImouClient:
    def __init__(self, app_id, app_secret, api_base=None, http=None, now=None):
        self.app_id = str(app_id or "").strip()
        self.app_secret = str(app_secret or "").strip()
        self.api_base = (api_base or DEFAULT_API_BASE).rstrip("/")
        self.http = http or _default_http
        self.now = now or time.time

    @classmethod
    def from_integration(cls, http=None):
        """A client from the saved integration, or None when keys are missing."""
        from .. import integrations as I
        cfg = I.get("imou")
        if not cfg.get("app_id") or not cfg.get("app_secret"):
            return None
        return cls(cfg["app_id"], cfg["app_secret"], cfg.get("api_base"),
                   http=http)

    def call(self, method, params=None):
        ts = int(self.now())
        nonce = uuid.uuid4().hex
        body = json.dumps({
            "system": {"ver": "1.0", "appId": self.app_id, "time": ts,
                       "nonce": nonce, "sign": sign(ts, nonce, self.app_secret)},
            "params": params or {}, "id": uuid.uuid4().hex})
        try:
            status, text = self.http("%s/%s" % (self.api_base, method), body,
                                     TIMEOUT_S)
        except Exception as e:  # noqa: BLE001 - network: honest error code
            raise ImouError("network", str(e)[:120])
        if status != 200:
            raise ImouError("http_%s" % status)
        try:
            res = (json.loads(text) or {}).get("result") or {}
        except (ValueError, AttributeError):
            raise ImouError("bad_json")
        code = str(res.get("code", ""))
        if code != "0":
            raise ImouError(code or "unknown", res.get("msg"))
        return res.get("data") or {}

    def token(self):
        hit = _token_cache.get(self.app_id)
        if hit and hit[1] > self.now() + 60:
            return hit[0]
        data = self.call("accessToken")
        tok = data.get("accessToken")
        if not tok:
            raise ImouError("no_token")
        ttl = int(data.get("expireTime") or 3600)
        _token_cache[self.app_id] = (tok, self.now() + ttl)
        return tok

    def bind_device(self, device_id, safety_code):
        return self.call("bindDevice", {"token": self.token(),
                                        "deviceId": device_id,
                                        "code": safety_code})

    def device_online(self, device_id):
        """Succeeds only when THIS account can see the device."""
        return self.call("deviceOnline", {"token": self.token(),
                                          "deviceId": device_id})

    def set_callback(self, url):
        return self.call("setMessageCallback", {
            "token": self.token(), "callbackFlag": "alarm,deviceStatus",
            "callbackUrl": url, "status": "on"})

    def alarms(self, device_id, channel_id="0", since_minutes=10, count=20):
        end = datetime.utcfromtimestamp(self.now()) + timedelta(hours=8)
        begin = end - timedelta(minutes=since_minutes)
        fmt = "%Y-%m-%d %H:%M:%S"
        data = self.call("getAlarmMessage", {
            "token": self.token(), "deviceId": device_id,
            "channelId": str(channel_id), "beginTime": begin.strftime(fmt),
            "endTime": end.strftime(fmt), "count": int(count),
            "nextAlarmId": "-1"})
        return data.get("alarms") or []

    def snapshot_url(self, device_id, channel_id="0"):
        data = self.call("setDeviceSnapEnhanced", {
            "token": self.token(), "deviceId": device_id,
            "channelId": str(channel_id)})
        return data.get("url") or ""


# ---------------------------------------------------------------- parsing
_HUMAN_WORDS = ("human", "humanoid", "people", "person", "body")


def parse_alarm(msg):
    """Normalise one Imou alarm (callback body or getAlarmMessage row) ->
    {"device_id", "channel", "human": bool, "alarm_id", "pic": url|None} or
    None for non-alarm messages (device status etc.)."""
    if not isinstance(msg, dict):
        return None
    mtype = str(msg.get("msgType") or "").lower()
    if mtype in ("devicestatus", "online", "offline", "status", "heartbeat"):
        return None
    did = str(msg.get("did") or msg.get("deviceId") or "").strip()
    if not did:
        return None
    cid = str(msg.get("cid") if msg.get("cid") is not None
              else msg.get("channelId") if msg.get("channelId") is not None
              else "0")
    blob = json.dumps({k: msg.get(k) for k in
                       ("labelType", "type", "msgType", "name", "alarmType")},
                      default=str).lower()
    human = any(w in blob for w in _HUMAN_WORDS)
    pics = msg.get("picurlArray") or msg.get("picUrls") or []
    if isinstance(pics, str):
        pics = [pics]
    pic = None
    for u in list(pics) + [msg.get("thumbUrl"), msg.get("picurl")]:
        if isinstance(u, str) and u.startswith("https://"):
            pic = u
            break
    return {"device_id": did[:64], "channel": cid[:8], "human": human,
            "alarm_id": str(msg.get("alarmId") or msg.get("id") or "")[:64],
            "pic": pic}


def snapshot_url_allowed(url):
    try:
        u = urlparse(url)
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    return u.scheme == "https" and any(
        host.endswith(s) or host == s.lstrip(".") for s in SNAPSHOT_HOST_SUFFIXES)


def fetch_snapshot(url, getter=None):
    """Download ONE still from an allowed Imou host (<= 2 MB), else None."""
    if not url or not snapshot_url_allowed(url):
        return None
    try:
        if getter is not None:
            raw = getter(url)
        else:
            import requests
            r = requests.get(url, timeout=TIMEOUT_S, stream=True,
                             allow_redirects=False)
            if r.status_code != 200:
                return None
            ctype = (r.headers.get("Content-Type") or "").lower()
            if ctype and not ctype.startswith("image/"):
                return None
            raw = r.raw.read(MAX_SNAPSHOT_BYTES + 1, decode_content=True)
        if not raw or len(raw) > MAX_SNAPSHOT_BYTES:
            return None
        return raw
    except Exception:  # noqa: BLE001
        return None


def callback_token(app_id, secret_key):
    """The unguessable path segment of our Imou callback URL."""
    return hashlib.sha256(("imou-cb:%s:%s" % (app_id, secret_key)).encode()
                          ).hexdigest()[:32]
