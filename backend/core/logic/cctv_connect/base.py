"""
cctv_connect/base.py — the provider interface every brand-cloud connector
implements (CCTV Guard V3, part A1, agent cctvconnect).

One adapter per vendor (EZVIZ, Imou, Hik-Connect, DoLynk). Each adapter is
pure Python: it talks to the vendor through an injected `http` callable
(tests and CI use logic/cctv_connect/mocks.py, never the network) and knows
nothing about Django models. The Django glue is core/cctv_connect_views.py.

HOW A USER AUTHORIZES ONCE (per site)
  * "device_code" — the user types the camera / DVR serial number and the
    verification code printed on its label (EZVIZ "Verification Code", Imou /
    DoLynk "Safety Code", Hik-Connect "Verification Code"). Knowing the code
    proves physical ownership — exactly what each vendor's public open API
    asks for to add a device to a developer account. The code is used for
    that one call and NEVER stored.
  * "oauth" — the vendor's own consent page (authorization-code flow). Only
    offered when the owner has saved an authorize + token URL for that
    vendor in Owner Admin (some vendors give this only after partner
    approval). The access / refresh tokens are sealed per site.

The "grant" an adapter returns is a small dict; the views SEAL it (Fernet,
INTEGRATIONS_FERNET_KEY, bound to the site id) before it touches the DB and
open it again only server-side. A grant is never sent to any client.

NORMALISED SHAPES (what every adapter returns)
  device  {"ref": "<SERIAL>", "serial", "name", "model", "kind": "camera"|"nvr",
           "online": bool|None, "channels": [{"no": int, "name", "online"}]}
  event   {"id", "ref": "<SERIAL>:<ch>", "serial", "channel", "at" (epoch s),
           "kind" (cctv_rules KINDS or "" = plain motion), "object",
           "vendor_type", "picture" (allowed https url or "")}
  stream  {"url", "proto": "hls"|"flv"|"rtmp", "expires_s", "token"}
  health  dvr_health report — see logic/dvr_health.py (normalize_report)
"""
import json
import time
from urllib.parse import urlparse

TIMEOUT_S = 8
MAX_DEVICES = 64
MAX_CHANNELS = 64


class ConnectError(Exception):
    """A vendor said no (or could not be reached). `code` is short and safe
    to show in Owner Admin; `hint` maps to a Bangla/English user message."""

    def __init__(self, code, msg="", hint=""):
        super().__init__("%s %s" % (code, msg))
        self.code = str(code)[:40]
        self.msg = str(msg or "")[:200]
        self.hint = hint or HINTS.get(self.code, "vendor")


# user-facing hints (the views turn these into bn / en text)
HINTS = {"network": "network", "wrong_code": "wrong_code", "taken": "taken",
         "not_configured": "not_configured", "no_stream": "no_stream",
         "offline": "offline", "token_expired": "reauth", "revoked": "reauth"}

HINT_TEXT = {
    "network": ("ক্যামেরা কোম্পানির সার্ভারে পৌঁছানো যায়নি — একটু পরে আবার চেষ্টা করুন।",
                "Could not reach the camera maker's server — please try again shortly."),
    "wrong_code": ("সিরিয়াল নম্বর বা লেবেলের কোড মেলেনি — ক্যামেরা / DVR-এর নিচের স্টিকার আবার দেখে লিখুন।",
                   "The serial number or label code did not match — check the sticker under the camera / DVR."),
    "taken": ("এই ডিভাইসটি অন্য একটি অ্যাকাউন্টে যুক্ত আছে — আগে কোম্পানির অ্যাপ থেকে সরান, তারপর আবার চেষ্টা করুন।",
              "This device is linked to another account — remove it in the maker's app first, then try again."),
    "not_configured": ("এই ব্র্যান্ডের ক্লাউড সংযোগ এখনো চালু হয়নি — ক্যামেরা একই Wi-Fi থেকে (Guard Box) ঠিকই যুক্ত করা যায়।",
                       "This brand's cloud link is not switched on yet — you can still add the camera on the same Wi-Fi (Guard Box)."),
    "no_stream": ("কোম্পানির ক্লাউড এখন ভিডিও দিচ্ছে না — ক্যামেরা অনলাইনে আছে কিনা দেখুন।",
                  "The maker's cloud is not giving video right now — check the camera is online."),
    "offline": ("ক্যামেরা / DVR এখন অফলাইন — বিদ্যুৎ ও ইন্টারনেট দেখুন।",
                "The camera / DVR is offline — check its power and internet."),
    "reauth": ("অনুমতির মেয়াদ শেষ — একবার আবার যুক্ত করুন।",
               "The permission expired — please connect once more."),
    # dolynkreal (Dahua DoLynk error codes IDV0011 / IDV0022)
    "locked": ("অনেকবার ভুল পাসওয়ার্ড দেওয়ায় ডিভাইসটি কিছুক্ষণ লক থাকবে — ৩০ মিনিট পরে সঠিক পাসওয়ার্ড দিয়ে আবার চেষ্টা করুন।",
               "Too many wrong passwords — the device is locked for a while. Try again in 30 minutes with the right password."),
    "unsupported": ("এই মডেলটি কোম্পানির ক্লাউড দিয়ে এখনো যুক্ত করা যায় না — একই Wi-Fi দিয়ে (Guard Box) যুক্ত করুন।",
                    "This model cannot be added through the maker's cloud yet — add it on the same Wi-Fi (Guard Box)."),
    "vendor": ("কোম্পানির সার্ভার অনুরোধটি নেয়নি — একটু পরে আবার চেষ্টা করুন।",
               "The maker's server refused the request — please try again shortly."),
}


def hint_text(hint, lang):
    bn, en = HINT_TEXT.get(hint, HINT_TEXT["vendor"])
    return bn if lang == "bn" else en


def host_allowed(url, suffixes):
    """SSRF / leak guard: only https URLs on the vendor's own domains."""
    try:
        u = urlparse(str(url or ""))
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    if u.scheme != "https" or not host:
        return False
    return any(host == s.lstrip(".") or host.endswith(s) for s in suffixes)


def clean_serial(v):
    s = str(v or "").strip().upper()[:40]
    return s if s and s.replace("-", "").isalnum() else ""


def clean_code(v):
    s = str(v or "").strip()[:32]
    return s if s and all(c.isalnum() for c in s) else ""


def json_post(http, url, payload, headers=None, form=False, ok_status=(200,)):
    """-> parsed JSON dict or raises ConnectError(network / http_x / bad_json).
    `http(url, body, timeout, headers)`; body is a JSON string or a form dict."""
    body = payload if form else json.dumps(payload)
    try:
        status, text = http(url, body, TIMEOUT_S, dict(headers or {}))
    except ConnectError:
        raise
    except Exception as e:  # noqa: BLE001 - honest "network" for any socket error
        raise ConnectError("network", str(e)[:120])
    if status not in ok_status:
        if status in (401, 403):
            raise ConnectError("token_expired", "http_%s" % status)
        raise ConnectError("http_%s" % status)
    try:
        res = json.loads(text) if isinstance(text, (str, bytes)) else text
    except ValueError:
        raise ConnectError("bad_json")
    if not isinstance(res, dict):
        raise ConnectError("bad_json")
    return res


def default_http(url, body, timeout, headers):
    import requests
    h = dict(headers or {})
    if isinstance(body, dict):
        r = requests.post(url, data=body, timeout=timeout, headers=h,
                          allow_redirects=False)
    else:
        h.setdefault("Content-Type", "application/json")
        r = requests.post(url, data=body, timeout=timeout, headers=h,
                          allow_redirects=False)
    return r.status_code, r.text


def device(ref, name="", model="", kind="camera", online=None, channels=None):
    chs = []
    for c in (channels or [])[:MAX_CHANNELS]:
        try:
            no = int(c.get("no"))
        except (TypeError, ValueError):
            continue
        chs.append({"no": no, "name": str(c.get("name") or "")[:60],
                    "online": c.get("online") if c.get("online") in (True, False) else None})
    if not chs:
        chs = [{"no": 1 if kind == "nvr" else 0, "name": str(name or "")[:60],
                "online": online}]
    return {"ref": ref, "serial": ref, "name": str(name or ref)[:80],
            "model": str(model or "")[:60], "kind": kind if kind in ("camera", "nvr") else "camera",
            "online": online if online in (True, False) else None, "channels": chs}


def event(serial, channel, at, kind="", obj=None, vendor_type="", picture="",
          ev_id=""):
    return {"id": str(ev_id or "")[:64], "ref": "%s:%s" % (serial, channel),
            "serial": serial, "channel": str(channel)[:4],
            "at": float(at or time.time()), "kind": kind or "",
            "object": obj, "vendor_type": str(vendor_type or "")[:60],
            "picture": picture or ""}


class Provider:
    """Base class. Subclasses set the class attributes and override what
    their vendor's public API supports; anything unsupported raises
    ConnectError("unsupported") so the app can say so honestly."""

    id = ""
    name = ""
    integration = ""          # core.integrations REGISTRY slug holding the keys
    key_fields = ()           # fields that must be present for the connector to be ON
    auth_modes = ("device_code",)
    caps = ("devices", "live", "playback", "events", "health")
    pic_hosts = ()            # https hosts a picture / stream may come from
    code_label = ("লেবেলের কোড", "Label code")
    code_secret = False       # dolynkreal: the app hides the typed code (a password)
    # "device": events() is asked per device; "account": the vendor has ONE
    # queue for the whole developer account -> account_events() once per
    # sync, routed to sites by serial (never per device: it would drain it)
    events_scope = "device"
    # the redirect URI path registered in the vendor console ("" = generic)
    oauth_redirect_path = ""

    def __init__(self, cfg, http=None, now=None):
        self.cfg = dict(cfg or {})
        self.http = http or default_http
        self.now = now or time.time

    @staticmethod
    def clean_code(v):
        """The typed label code / password, or "" when unusable."""
        return clean_code(v)

    # ---- configuration ----
    def configured(self):
        return all(str(self.cfg.get(k) or "").strip() for k in self.key_fields)

    def oauth_ready(self):
        return bool(self.cfg.get("oauth_authorize_url") and self.cfg.get("oauth_token_url")
                    and self.cfg.get("oauth_client_id"))

    def modes(self):
        out = [m for m in self.auth_modes if m != "oauth"]
        if "oauth" in self.auth_modes and self.oauth_ready():
            out.append("oauth")
        return out

    # ---- authorize once ----
    def link_device(self, serial, code):
        """device_code mode: add the device to our developer account with the
        label code; -> grant {"mode": "device_code", "serials": [serial]}."""
        raise ConnectError("unsupported")

    def oauth_url(self, state, redirect_uri):
        from urllib.parse import urlencode
        if not self.oauth_ready():
            raise ConnectError("not_configured")
        q = urlencode({"response_type": "code", "client_id": self.cfg["oauth_client_id"],
                       "redirect_uri": redirect_uri, "state": state,
                       "scope": self.cfg.get("oauth_scope") or ""})
        return "%s?%s" % (self.cfg["oauth_authorize_url"], q)

    def oauth_finish(self, code, redirect_uri):
        """Standard OAuth2 code exchange -> grant {"mode": "oauth", ...}."""
        if not self.oauth_ready():
            raise ConnectError("not_configured")
        res = json_post(self.http, self.cfg["oauth_token_url"], {
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirect_uri, "client_id": self.cfg["oauth_client_id"],
            "client_secret": self.cfg.get("oauth_client_secret") or ""}, form=True)
        data = res.get("data") if isinstance(res.get("data"), dict) else res
        tok = data.get("access_token") or data.get("accessToken")
        if not tok:
            raise ConnectError("no_token", str(res.get("msg") or res.get("error") or ""))
        try:
            ttl = int(data.get("expires_in") or data.get("expireTime") or 3600)
        except (TypeError, ValueError):
            ttl = 3600
        return {"mode": "oauth", "access_token": str(tok),
                "refresh_token": str(data.get("refresh_token") or data.get("refreshToken") or ""),
                "expires_at": self.now() + min(ttl, 90 * 86400), "serials": []}

    def oauth_refresh(self, grant):
        if not grant.get("refresh_token") or not self.oauth_ready():
            raise ConnectError("token_expired")
        res = json_post(self.http, self.cfg["oauth_token_url"], {
            "grant_type": "refresh_token", "refresh_token": grant["refresh_token"],
            "client_id": self.cfg["oauth_client_id"],
            "client_secret": self.cfg.get("oauth_client_secret") or ""}, form=True)
        data = res.get("data") if isinstance(res.get("data"), dict) else res
        tok = data.get("access_token") or data.get("accessToken")
        if not tok:
            raise ConnectError("token_expired")
        g = dict(grant, access_token=str(tok))
        if data.get("refresh_token"):
            g["refresh_token"] = str(data["refresh_token"])
        g["expires_at"] = self.now() + int(data.get("expires_in") or 3600)
        return g

    def fresh(self, grant):
        """-> (grant, changed). Refreshes an OAuth grant close to expiry."""
        if grant.get("mode") == "oauth" and float(grant.get("expires_at") or 0) < self.now() + 120:
            return self.oauth_refresh(grant), True
        return grant, False

    def after_link(self, grant):
        """Vendor-specific set-up right after a link (e.g. message callback)."""
        return None

    def unlink(self, grant):
        """Revoke: release every device this grant added (best effort)."""
        return None

    # ---- what the site sees ----
    def devices(self, grant):
        raise ConnectError("unsupported")

    def live(self, grant, serial, channel, hd=False):
        raise ConnectError("unsupported")

    def playback(self, grant, serial, channel, start_epoch, end_epoch):
        raise ConnectError("unsupported")

    def events(self, grant, serial, since_epoch, channels=None):
        raise ConnectError("unsupported")

    def account_events(self, since_epoch):
        raise ConnectError("unsupported")

    def health(self, grant, serial):
        raise ConnectError("unsupported")

    def owns(self, grant, serial):
        """A device belongs to this grant (scope check before any call)."""
        return clean_serial(serial) in [clean_serial(s) for s in grant.get("serials") or []]
