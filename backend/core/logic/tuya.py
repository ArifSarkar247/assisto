"""
tuya.py — Tuya / Smart Life cloud client for CCTV automations (cctvact, owner
CCTV GUARD V3 part D). Tuya's PUBLIC OpenAPI (developer.tuya.com, "Cloud
Development"), HMAC-SHA256 request signing v2 ("new signature algorithm"):

  stringToSign = METHOD \n sha256(body) \n "" \n path?sorted_query
  token call   : sign = HMAC(secret, client_id + t + nonce + stringToSign)
  business call: sign = HMAC(secret, client_id + access_token + t + nonce + stringToSign)
  (upper-case hex; headers client_id, t, nonce, sign, sign_method, access_token)

Endpoints used (all documented, v1.0):
  GET  /v1.0/token?grant_type=1                  project token
  GET  /v1.0/users/{uid}/devices                 the linked Smart Life user's devices
  GET  /v1.0/devices/{id}/functions              the codes a device accepts
  POST /v1.0/devices/{id}/commands               {"commands":[{"code","value"}]}
  POST /v1.0/devices/{id}/door-lock/password-ticket       a one-time ticket
  POST /v1.0/smart-lock/devices/{id}/password-free/door-operate {ticket_id, open}

Credentials: the owner's Tuya cloud project (Owner Admin integration "tuya":
access_id, access_secret, region) OR a shop owner's own project (sealed on
the site). The Smart Life account is linked to the project in Tuya's console
("Devices -> Link Tuya App Account"); its UID tells us whose devices to list.
No network in tests: `http` is injected.
"""
import hashlib
import hmac
import json
import time
import uuid
from urllib.parse import urlencode

REGIONS = {
    "in": "https://openapi.tuyain.com",          # India data centre
    "eu": "https://openapi.tuyaeu.com",          # Central Europe
    "weu": "https://openapi-weaz.tuyaeu.com",    # Western Europe
    "us": "https://openapi.tuyaus.com",          # Western America
    "eus": "https://openapi-ueaz.tuyaus.com",    # Eastern America
    "cn": "https://openapi.tuyacn.com",          # China
}
REGION_ORDER = ("in", "eu", "us", "weu", "eus", "cn")
TIMEOUT_S = 6

# Tuya product categories -> what Assisto can do with them
CATEGORY_KIND = {
    "dj": "light", "dd": "light", "fwd": "light", "xdd": "light", "dc": "light",
    "tgq": "light", "tgkg": "light",
    "cz": "plug", "pc": "plug", "kg": "switch", "cjkg": "switch", "ckmkzq": "switch",
    "sgbj": "siren", "bjsj": "siren",
    "ms": "lock", "jtmspro": "lock", "videolock": "lock",
}
# the switch code each kind tries, in order (the device's own function list wins)
ON_CODES = {
    "light": ("switch_led", "switch_1", "switch"),
    "plug": ("switch_1", "switch", "switch_on"),
    "switch": ("switch_1", "switch", "switch_on"),
    "siren": ("alarm_switch", "AlarmSwitch", "switch_alarm_sound", "switch_1"),
}


class TuyaError(Exception):
    def __init__(self, code, msg=""):
        super().__init__("%s %s" % (code, msg))
        self.code = str(code)
        self.msg = msg


def _default_http(method, url, headers, body, timeout):
    import requests
    r = requests.request(method, url, headers=headers, data=body or None,
                         timeout=timeout)
    return r.status_code, r.text


def string_to_sign(method, path, query=None, body=""):
    q = ""
    if query:
        q = "?" + "&".join("%s=%s" % (k, query[k]) for k in sorted(query))
    sha = hashlib.sha256((body or "").encode("utf-8")).hexdigest()
    return "%s\n%s\n\n%s%s" % (method.upper(), sha, path, q)


def calc_sign(secret, client_id, t, nonce, sts, access_token=""):
    msg = client_id + (access_token or "") + str(t) + nonce + sts
    return hmac.new(secret.encode("utf-8"), msg.encode("utf-8"),
                    hashlib.sha256).hexdigest().upper()


def kind_of(category):
    return CATEGORY_KIND.get(str(category or "").lower())


def pick_code(kind, functions):
    """The device's own switch code for `kind` (from its function list), or
    the first default when the list is unknown."""
    codes = [f.get("code") for f in (functions or []) if isinstance(f, dict)]
    for c in ON_CODES.get(kind, ()):
        if c in codes:
            return c
    return ON_CODES.get(kind, (None,))[0] if not codes else None


class TuyaClient:
    def __init__(self, access_id, access_secret, region="in", http=None, now=None):
        self.client_id = str(access_id or "").strip()
        self.secret = str(access_secret or "").strip()
        self.region = region if region in REGIONS else "in"
        self.base = REGIONS[self.region]
        self.http = http or _default_http
        self.now = now or time.time
        self._token = None
        self._token_exp = 0

    @classmethod
    def from_integration(cls, http=None):
        from .. import integrations as I
        try:
            cfg = I.get("tuya")
        except Exception:
            cfg = {}
        if not cfg.get("access_id") or not cfg.get("access_secret"):
            return None
        return cls(cfg["access_id"], cfg["access_secret"], cfg.get("region") or "in",
                   http=http)

    # ------------------------------------------------------------ transport
    def _request(self, method, path, query=None, body=None, token=True):
        raw = json.dumps(body, separators=(",", ":")) if body is not None else ""
        t = int(self.now() * 1000)
        nonce = uuid.uuid4().hex
        sts = string_to_sign(method, path, query, raw)
        at = self.access_token() if token else ""
        headers = {"client_id": self.client_id, "t": str(t), "nonce": nonce,
                   "sign_method": "HMAC-SHA256",
                   "sign": calc_sign(self.secret, self.client_id, t, nonce, sts, at),
                   "Content-Type": "application/json"}
        if at:
            headers["access_token"] = at
        url = self.base + path + ("?" + urlencode(sorted(query.items())) if query else "")
        try:
            status, text = self.http(method, url, headers, raw, TIMEOUT_S)
        except Exception as e:  # noqa: BLE001 - network: honest code
            raise TuyaError("network", str(e)[:120])
        if status != 200:
            raise TuyaError("http_%s" % status)
        try:
            d = json.loads(text)
        except (TypeError, ValueError):
            raise TuyaError("bad_json")
        if not d.get("success"):
            raise TuyaError(d.get("code") or "error", d.get("msg") or "")
        return d.get("result")

    def access_token(self):
        if self._token and self.now() < self._token_exp - 60:
            return self._token
        res = self._request("GET", "/v1.0/token", {"grant_type": "1"}, token=False) or {}
        self._token = res.get("access_token")
        if not self._token:
            raise TuyaError("no_token")
        self._token_exp = self.now() + int(res.get("expire_time") or 7200)
        return self._token

    # ------------------------------------------------------------ calls
    def devices(self, uid):
        rows = self._request("GET", "/v1.0/users/%s/devices" % uid) or []
        out = []
        for d in rows if isinstance(rows, list) else []:
            k = kind_of(d.get("category"))
            if not k:
                continue
            out.append({"id": str(d.get("id") or ""), "name": str(d.get("name") or "")[:60],
                        "kind": k, "category": d.get("category"),
                        "online": bool(d.get("online"))})
        return out

    def functions(self, device_id):
        res = self._request("GET", "/v1.0/devices/%s/functions" % device_id) or {}
        return res.get("functions") or []

    def switch(self, device_id, kind, on=True, code=None):
        code = code or pick_code(kind, self.functions(device_id))
        if not code:
            raise TuyaError("no_switch_code")
        self._request("POST", "/v1.0/devices/%s/commands" % device_id,
                      body={"commands": [{"code": code, "value": bool(on)}]})
        return code

    def lock(self, device_id, lock=True):
        """Lock (open=False) / unlock with a one-time ticket. Called ONLY
        after the owner confirmed on the phone."""
        tk = self._request("POST", "/v1.0/devices/%s/door-lock/password-ticket" % device_id,
                           body={}) or {}
        tid = tk.get("ticket_id")
        if not tid:
            raise TuyaError("no_ticket")
        self._request("POST", "/v1.0/smart-lock/devices/%s/password-free/door-operate" % device_id,
                      body={"ticket_id": tid, "open": not lock})
        return True
