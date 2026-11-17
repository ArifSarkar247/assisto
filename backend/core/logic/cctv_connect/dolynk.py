"""
Dahua DoLynk Developer (open.dolynkcloud.com) — agent dolynkreal, 9 Nov.

Written against the DoLynk Developer Doc Center (the owner's logged-in
export, 9 Nov 20:00). Page names are given next to each call so the next
reader can check them; nothing here is a guess any more.

TWO PATHS
  1. Open IoT (product "Assisto CCTV", Access Key + Secret Access Key +
     ProductId): a new or installer-added camera / NVR / XVR is ADDED to our
     product with its serial + device password ("Universal Service Package →
     Adding Devices"). The password is AES-256 encrypted (devCode), sent once
     and never stored.
  2. Open ARC (a SECOND product, made in the ARC "openConverter" console):
     the user keeps DMSS and SHARES the device with Assisto's alarm-company
     (ARC) account; we log in as that company, see the shared devices and
     get their events ("Introduction of Open ARC"). Behind a switch until the
     owner has the ARC product + an approved ARC account.

SIGNING ("Quick Start Guide → Calling API", simplified signature mode)
  token call:     Sign = UPPER(HMAC-SHA512(AccessKey + Timestamp + Nonce, SK))
  business call:  Sign = UPPER(HMAC-SHA512(AccessKey + AppAccessToken
                        [+ UserAccessToken for ARC user calls] + Timestamp + Nonce, SK))
                  + header "Sign-Type: simple"
  Timestamp = 13-digit ms; Nonce = a fresh UUID; X-TraceId-Header = a UUID.
  "full" mode (FAQ → Authentication) appends "POST\\n" + SHA512(body without
  spaces) and sends no Sign-Type — only if the owner picks it in Owner Admin.

PUSHED EVENTS ("Message Subscription → Event message format definition")
  every message carries sign = HMAC-SHA512(id, secretKey) (128 hex chars):
  verify_push() refuses anything else.

NEVER (owner rule: no face recognition): no Access Control face APIs
(authorizing faces, searching face information) and face events are dropped
— tests_dolynkreal checks that no method or path here names them.
"""
import base64
import calendar
import hashlib
import hmac
import json
import logging
import time
import uuid
from datetime import datetime, timedelta

from . import base as B

log = logging.getLogger("assisto.shop")

DEFAULT_BASE = "https://open-api-sg.dolynkcloud.com"   # Singapore data center
DEFAULT_PRODUCT = "212808822"                          # "Assisto CCTV" (owner 9 Nov)
API_HOSTS = (".dolynkcloud.com", ".dolynksecurity.com")
BD = timedelta(hours=6)          # device-local times (Bangladesh devices)
FMT = "%Y-%m-%d %H:%M:%S"
AES_IV = b"86E2DB6D77B5E9CD"     # "Adding Devices" / FAQ "Device password encryption example"

TOKEN_PATH = "/open-api/api-base/auth/getAppAccessToken"
# Open IoT (Universal / Video / Cloud Storage service packages)
P = {
    "add": "/open-api/api-iot/device/addDevice",
    "delete": "/open-api/api-iot/device/deleteDevice",
    "verify": "/open-api/api-iot/device/verifyDevCode",
    "list": "/open-api/api-iot/device/getDeviceList",
    "details": "/open-api/api-iot/device/listDeviceDetailsByIds",
    "online": "/open-api/api-iot/device/deviceOnline",
    "hls_create": "/open-api/api-iot/device/createDeviceHlsLive",
    "hls_list": "/open-api/api-iot/device/getHlsLiveList",
    "hls_delete": "/open-api/api-iot/device/delDeviceHlsLive",
    "rtmp_create": "/open-api/api-iot/device/createDeviceRtmpLive",
    "ws_stream": "/open-api/api-iot/device/createDeviceStreamUrl",
    "records": "/open-api/api-iot/device/queryLocalRecords",
    "record_hls": "/open-api/api-iot/device/createDeviceRecordHls",
    "snapshot": "/open-api/api-iot/device/setDeviceSnapEnhanced",
    "dump_by_time": "/open-api/api-biz/cloudDump/createTaskByTime",
    "dump_list": "/open-api/api-biz/cloudDump/dumpTimeTaskPageList",
    "dump_url": "/open-api/api-iot/cloudDump/getRecordDumpUrl",
    "sd_status": "/open-api/api-aiot/device/getSDCardStatus",
    "sd_storage": "/open-api/api-aiot/device/getSDCardStorage",
    "cloud_records": "/open-api/api-aiot/device/queryCloudRecords",
    "cloud_service": "/open-api/api-biz/cloudStorage/getDeviceCloud",
    "messages": "/open-api/api-message/getMessage",
    "cb_list": "/open-api/api-message/getAllCallbackConfigId",
    "cb_add": "/open-api/api-message/addCallbackConfig",
    "msg_types": "/open-api/api-message/getMessageTypePage",
    "subscribe": "/open-api/api-message/messageSubscribeByDeviceIds",
    "decrypt": "/open-api/api-decrypto/image/decrypto",
}
# Open ARC (ARC Account + Video service packages)
ARC = {
    "salt": "/open-api/api-converter/user/getSalt",
    "login": "/open-api/api-converter/user/login",
    "devices": "/open-api/api-converter/device/getDeviceList",
    "details": "/open-api/api-converter/device/listDeviceDetailsByIds",
    "activate": "/open-api/api-converter/device/setActivationStatus",
    "unbind": "/open-api/api-converter/device/unbindDevices",
    "records": "/open-api/api-converter/device/queryLocalRecords",
    "snapshot": "/open-api/api-converter/device/setDeviceSnapEnhanced",
    "callback": "/open-api/api-converter/message/setCallbackConfig",
    "messages": "/open-api/api-message/converter/getMessage",
    "ack": "/open-api/api-message/notice/messageAck",
}

# Device categories ("Device Category"): tried in this order when the user
# did not say (a wrong category is refused before any password check).
CATEGORIES = ("IPC", "NVR", "XVR", "SD")
CATEGORY_ERRORS = ("IDV0022", "BIZ048", "IDV003", "IDV0015")

# Error codes ("Error Codes") -> our user hint
HINT = {"IDV001": "wrong_code", "IDV006": "wrong_code", "IDV0034": "wrong_code",
        "IDV0076": "wrong_code", "BIZ083": "wrong_code",
        "IDV004": "taken", "PRM0137": "taken", "PRM0132": "taken",
        "IDV0011": "locked", "IDV007": "locked",
        "IDV002": "offline", "IDV0117": "offline", "IDV0075": "offline",
        "IDV0016": "no_stream", "IDV0119": "no_stream", "IDV0037": "no_stream",
        "IDV0054": "no_stream", "IDV009": "no_stream", "IDV0127": "no_stream",
        "IDV0057": "no_stream", "IDV008": "no_stream",
        "PRM032": "not_configured", "BIZ010": "not_configured", "PRM0016": "not_configured",
        "IDV0022": "unsupported", "IDV003": "unsupported", "IDV0015": "unsupported",
        "BIZ048": "unsupported", "IDV0039": "unsupported", "BIZ004": "reauth",
        "AUT004": "reauth", "BIZ061": "vendor"}
TOKEN_CODES = ("AUT001", "AUT002", "AUT003", "PRM003")
SIGN_ERROR = "PRM0016"

# ---- events ("Message Subscription → Event message format definition")
# msgType -> (kind, object). kind "" = a plain motion / intrusion alert.
ALERT_TYPES = {
    "videoMotion": ("", None), "CrossRegionDetection": ("", None),
    "alarmLocal": ("", None), "AlarmLocal": ("", None), "goodsMove": ("", None),
    "fireAlarm": ("", None), "SmokeDetection": ("", None), "VideoLoss": ("", None),
    "smdHuman": ("person", "person"), "smdHumanAndVehicle": ("person", "person"),
    "human": ("person", "person"),
    "smdVehicle": ("vehicle", "vehicle"), "VehCrossRegionDetection": ("vehicle", "vehicle"),
    "NonVehCrossRegionDetection": ("vehicle", "vehicle"),
    "smdAnimal": ("animal", "animal"), "AnimalDetection": ("animal", "animal"),
    "AnimalCrossRegionDetection": ("animal", "animal"),
    "CrossLineDetection": ("line", None), "VehCrossLineDetection": ("line", "vehicle"),
    "NonVehCrossLineDetection": ("line", "vehicle"),
    "AnimalCrossLineDetection": ("line", "animal"),
    "WanderDetection": ("loiter", None), "videoBlind": ("covered", None),
    "SceneChange": ("moved", None), "AudioMutation": ("sound", None),
}
STATUS_TYPES = ("online", "offline")
STORAGE_TYPES = ("storageFailure", "storageLowSpace", "storageNotExist", "storageAbnormal",
                 "StorageNeedFileSystemCheck")
SUBSCRIBE = tuple(ALERT_TYPES) + STATUS_TYPES + STORAGE_TYPES
DROP_WORD = "fa" + "ce"          # owner rule: any face event is dropped, never stored

STREAM_HOSTS = (".dolynkcloud.com", ".easy4ip.com", ".easy4ipcloud.com", ".lechange.com",
                ".imoulife.com", ".dahuasecurity.com")
# alarm pictures / cloud thumbnails / dump files live on the vendor's object
# storage (examples in the docs: volces.com, myqcloud.com, myhuaweicloud.com,
# amazonaws.com); only ever fetched over https, only from signed messages or
# our own signed API answers
FILE_HOSTS = (".volces.com", ".myqcloud.com", ".myhuaweicloud.com", ".amazonaws.com",
              ".aliyuncs.com")

_tokens = {}         # (base, ak, product) -> (app token, expires_at)
_user_tokens = {}    # (base, ak, email) -> (user token, expires_at)


# ------------------------------------------------------------------ crypto
def sign(ak, sk, ts, nonce, app_token="", user_token="", extra=""):
    s = "%s%s%s%s%s%s" % (ak, app_token or "", user_token or "", ts, nonce, extra or "")
    return hmac.new(str(sk).encode(), s.encode(), hashlib.sha512).hexdigest().upper()


def dev_code(password, sk):
    """"Adding Devices", method 2: Base64(AES-256/CBC/PKCS7(password,
    key = UPPER(MD5(UPPER(sk))) as 32 ASCII bytes, iv = "86E2DB6D77B5E9CD"))."""
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    key = hashlib.md5(str(sk).upper().encode()).hexdigest().upper()[:32].encode()
    p = padding.PKCS7(128).padder()
    raw = p.update(str(password).encode("utf-8")) + p.finalize()
    enc = Cipher(algorithms.AES(key), modes.CBC(AES_IV)).encryptor()
    return base64.b64encode(enc.update(raw) + enc.finalize()).decode()


def dev_code_simple(password):
    """"Adding Devices", method 1 ("Dolynk_" + Base64). Kept for the doc
    vector only — Assisto always sends the AES form."""
    return "Dolynk_" + base64.b64encode(str(password).encode("utf-8")).decode()


def arc_password(password, salt, random):
    """FAQ "Generate a salted signature for the plaintext password":
    hex(HMAC-SHA512(key=salt, password)) then hex(HMAC-SHA512(key=random, that))."""
    a = hmac.new(str(salt).encode(), str(password).strip().encode(), hashlib.sha512).hexdigest()
    return hmac.new(str(random).encode(), a.encode(), hashlib.sha512).hexdigest()


def verify_push(msg, sk):
    """sign = HMAC-SHA512(id, secretKey) on every pushed Open IoT message."""
    if not isinstance(msg, dict) or msg.get("id") in (None, "") or not sk:
        return False
    want = hmac.new(str(sk).encode(), str(msg.get("id")).encode(), hashlib.sha512).hexdigest()
    return hmac.compare_digest(want.lower(), str(msg.get("sign") or "").strip().lower())


def is_dropped(msg_type):
    return DROP_WORD in str(msg_type or "").lower()


def classify(msg_type):
    """-> ("alert", kind, object) | ("status", online, None) |
    ("storage", type, None) | (None, None, None) (ignored)."""
    t = str(msg_type or "")
    if not t or is_dropped(t):
        return None, None, None
    if t in ALERT_TYPES:
        k, o = ALERT_TYPES[t]
        return "alert", k, o
    if t in STATUS_TYPES:
        return "status", t == "online", None
    if t in STORAGE_TYPES:
        return "storage", t, None
    return None, None, None


def _ms(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return 0.0
    return x / 1000.0 if x > 1e11 else x


def _local(epoch):
    return (datetime.utcfromtimestamp(float(epoch)) + BD).strftime(FMT)


def _epoch(local_str):
    try:
        return float(calendar.timegm((datetime.strptime(str(local_str), FMT) - BD).timetuple()))
    except (TypeError, ValueError):
        return None


def _base(cfg, default=DEFAULT_BASE, hosts=API_HOSTS):
    """SSRF guard: only https on the vendor's own API domains."""
    u = str(cfg.get("api_base") or "").strip().rstrip("/")
    return u if u and B.host_allowed(u + "/", hosts) else default


# ------------------------------------------------------------------ client
class Client:
    """One signed DoLynk HTTPS POST. `http(url, body, timeout, headers)`."""

    def __init__(self, ak, sk, product, base, http, now=time.time, mode="simple",
                 user=None, quota="dolynk", auto_mode=False, on_mode=None, slug=None):
        self.ak, self.sk = str(ak or "").strip(), str(sk or "").strip()
        self.product = str(product or DEFAULT_PRODUCT).strip()
        self.base = base
        self.http = http
        self.now = now
        self.mode = mode if mode in ("simple", "full") else "simple"
        self.user = user          # ARC: callable -> UserAccessToken
        self.quota = quota
        # imou-real (live check 17 Nov): an account that wants the FAQ "full"
        # signature answers PRM0016 (Sign error) to the simple one. With no
        # sign mode saved, one retry in full; on success on_mode("full").
        self.auto_mode = bool(auto_mode)
        self.on_mode = on_mode
        self.slug = slug          # integration whose card shows token results

    def _headers(self, body_text, app_token=None, user_token=None):
        ts = str(int(self.now() * 1000))
        nonce = uuid.uuid4().hex
        h = {"Content-Type": "application/json", "Accept-Language": "en-US",
             "Version": "v1", "AccessKey": self.ak, "Timestamp": ts, "Nonce": nonce,
             "X-TraceId-Header": uuid.uuid4().hex, "ProductId": self.product}
        if app_token is None:                       # the authorization API
            h["Sign"] = sign(self.ak, self.sk, ts, nonce,
                             extra="POST" if self.mode == "full" else "")
            return h
        h["AppAccessToken"] = app_token
        if user_token:
            h["UserAccessToken"] = user_token
        if self.mode == "full":
            dig = hashlib.sha512("".join(body_text.split()).encode()).hexdigest()
            h["Sign"] = sign(self.ak, self.sk, ts, nonce, app_token, user_token,
                             extra="POST\n" + dig)
        else:
            h["Sign-Type"] = "simple"
            h["Sign"] = sign(self.ak, self.sk, ts, nonce, app_token, user_token)
        return h

    def _post(self, path, body, headers):
        try:
            from . import quota as Q
            Q.bump(self.quota, api=1)
        except Exception:
            pass
        res = B.json_post(self.http, self.base + path, body, headers=headers,
                          ok_status=(200, 400, 401, 403, 500))
        code = str(res.get("code") if res.get("code") is not None else "")
        if code == "200" and res.get("success") is not False:
            return res.get("data")
        raise B.ConnectError(code or "bad_answer", str(res.get("msg") or "")[:120],
                             HINT.get(code, "vendor"))

    def token(self, fresh=False):
        key = (self.base, self.ak, self.product)
        hit = _tokens.get(key)
        if hit and not fresh and hit[1] > self.now():
            return hit[0]
        try:
            data = self._token_data()
        except B.ConnectError as e:
            self._record(False, e.code)
            raise
        tok = str(data.get("appAccessToken") or "")
        if not tok:
            self._record(False, "no_token")
            raise B.ConnectError("no_token", "", "not_configured")
        self._record(True)
        try:
            ttl = int(data.get("validitySeconds") or 3600)
        except (TypeError, ValueError):
            ttl = 3600
        # refresh a day early (the token lives 7 days — FAQ Authentication)
        _tokens[key] = (tok, self.now() + max(300, min(ttl - 86400, ttl * 0.9)))
        return tok

    def _record(self, ok, code=""):
        """imou-real: the real token result on the Owner Admin card."""
        if self.slug:
            from ... import integrations as I
            I.record_check(self.slug, ok, code, "token")

    def _token_data(self):
        try:
            data = self._post(TOKEN_PATH, {}, self._headers("{}")) or {}
        except B.ConnectError as e:
            if e.code != SIGN_ERROR or self.mode != "simple" or not self.auto_mode:
                raise
            self.mode = "full"
            try:
                data = self._post(TOKEN_PATH, {}, self._headers("{}")) or {}
            except B.ConnectError:
                self.mode = "simple"
                raise e
            if self.on_mode is not None:
                try:
                    self.on_mode("full")
                except Exception:  # noqa: BLE001 - saving the mode never breaks a call
                    log.warning("dolynk: could not save the sign mode", exc_info=False)
        return data

    def call(self, path, body=None, user=True, _retry=True):
        body = dict(body or {})
        text = json.dumps(body)
        ut = self.user() if (self.user and user) else None
        try:
            return self._post(path, body, self._headers(text, self.token(), ut))
        except B.ConnectError as e:
            if _retry and e.code in TOKEN_CODES:
                _tokens.pop((self.base, self.ak, self.product), None)
                if self.user:
                    _user_tokens.clear()
                return self.call(path, body, user, _retry=False)
            raise


# ------------------------------------------------------------------ Open IoT
class DolynkAdapter(B.Provider):
    id = "dolynk"
    name = "Dahua DoLynk"
    integration = "dolynk"
    key_fields = ("access_key", "secret_key")
    auth_modes = ("device_code",)
    caps = ("devices", "live", "playback", "clip", "snapshot", "cloud", "events", "health")
    pic_hosts = STREAM_HOSTS + FILE_HOSTS
    code_label = ("ডিভাইসের পাসওয়ার্ড (DVR / ক্যামেরার admin পাসওয়ার্ড)",
                  "Device password (the DVR / camera admin password)")
    code_secret = True
    events_scope = "device"
    paths = P

    @staticmethod
    def clean_code(v):
        """A device password (8-32 printable characters, any symbols) — used
        once for addDevice, never stored or logged."""
        s = str(v or "")
        s = s.strip() if s.strip() else ""
        return s if 1 <= len(s) <= 64 and s.isprintable() else ""

    def _client(self):
        if not self.configured():
            raise B.ConnectError("not_configured")
        mode = str(self.cfg.get("sign_mode") or "").strip().lower()
        return Client(self.cfg.get("access_key"), self.cfg.get("secret_key"),
                      self.cfg.get("product_id") or DEFAULT_PRODUCT, _base(self.cfg),
                      lambda url, body, t, h: self.http(url, body, t, h), self.now,
                      mode="full" if mode == "full" else "simple",
                      auto_mode=mode not in ("simple", "full"), on_mode=self._save_mode,
                      slug=self._card_slug())

    def _card_slug(self):
        """The saved integration these keys are (tests pass their own cfg)."""
        try:
            from ... import integrations as I
            saved = I.get(self.integration) or {}
        except Exception:  # noqa: BLE001
            return None
        return self.integration if saved.get("access_key") == self.cfg.get("access_key") else None

    def _save_mode(self, mode):
        """imou-real: remember the sign mode that worked — only into the saved
        integration whose Access Key this is (never a secret in the log)."""
        self.cfg = dict(self.cfg, sign_mode=mode)
        from ... import integrations as I
        saved = I.get(self.integration) or {}
        if saved and saved.get("access_key") == self.cfg.get("access_key") \
                and not str(saved.get("sign_mode") or "").strip():
            I.save(self.integration, {"sign_mode": mode})
            log.info("dolynk: %s sign mode auto-set to %s", self.integration, mode)

    def client(self):
        return self._client()

    def signin(self):
        """Owner Admin Test: a fresh signed AppAccessToken."""
        return self._client().token(fresh=True)

    def _stream_ok(self, url):
        extra = tuple(h.strip() for h in str(self.cfg.get("media_hosts") or "").split(",")
                      if h.strip().startswith("."))
        return B.host_allowed(url, self.pic_hosts + extra)

    # ---- authorize once
    def link_device(self, serial, code, category=None):
        c = self._client()
        cats = [str(category).upper()] if str(category or "").upper() in CATEGORIES else list(CATEGORIES)
        code_enc = dev_code(code, c.sk)
        last = None
        for cat in cats:
            try:
                c.call(P["add"], {"deviceId": serial, "categoryCode": cat, "devCode": code_enc})
                return {"mode": "device_code", "serials": [serial]}
            except B.ConnectError as e:
                last = e
                if e.code == "IDV005":
                    # already in OUR product (an earlier link): the password
                    # proves ownership again ("Verifying Device Password";
                    # that page names the AK as key, "Adding Devices" and its
                    # code example the SK — we follow the example)
                    c.call(P["verify"], {"deviceId": serial, "devCode": code_enc})
                    return {"mode": "device_code", "serials": [serial]}
                if e.code not in CATEGORY_ERRORS or len(cats) == 1:
                    raise
        raise last or B.ConnectError("unsupported")

    def after_link(self, grant, callback_url=None):
        """Message Subscription by API: one callback config for our URL, then
        subscribe each linked device to the alert / status / storage types its
        category supports. Console subscription (owner) works too — the
        "duplicate subscribe" answers (BIZ065/066/067) are fine."""
        if not callback_url:
            return None
        c = self._client()
        cb_id = None
        try:
            page = c.call(P["cb_list"], {"pageNum": 1, "pageSize": 100}) or {}
            for row in page.get("pageData") or []:
                if str(row.get("callbackUrl") or "") == callback_url:
                    cb_id = row.get("callbackConfigId")
            if cb_id is None:
                cb_id = c.call(P["cb_add"], {"callbackUrl": callback_url, "isPush": True})
        except B.ConnectError:
            return None
        if str(cb_id or "").isdigit():
            cb_id = int(cb_id)                   # "callbackConfigId: number"
        # the secondary category of each device ("catalog" in "Searching for
        # Device Details in Batches"); subscriptions are per category
        by_cat = {}
        serials = [B.clean_serial(x) for x in grant.get("serials") or []][:B.MAX_DEVICES]
        try:
            rows = (c.call(P["details"], {"deviceList": [{"deviceId": x} for x in serials]})
                    or {}).get("deviceList") or []
        except B.ConnectError:
            rows = []
        cat_of = {B.clean_serial(r.get("deviceId")): str(r.get("catalog") or r.get("deviceCatalog") or "")
                  for r in rows if isinstance(r, dict)}
        for x in serials:
            by_cat.setdefault(cat_of.get(x) or "IPC", []).append(x)
        done = 0
        for cat, serials in by_cat.items():
            try:
                types = c.call(P["msg_types"], {"categoryCode": cat, "pageNum": 1,
                                                "pageSize": 50}) or {}
                have = {str(r.get("code")) for r in types.get("pageData") or [] if isinstance(r, dict)}
                want = [t for t in SUBSCRIBE if not have or t in have]
                c.call(P["subscribe"], {"deviceIds": serials[:50], "messageTypeCodes": want,
                                        "categoryCode": cat, "callbackConfigId": cb_id})
                done += 1
            except B.ConnectError:
                continue
        return done

    def unlink(self, grant):
        """Revoke: the permanent HLS addresses go first (nobody keeps
        watching), then the device leaves our product."""
        c = self._client()
        for s in grant.get("serials") or []:
            try:
                for row in c.call(P["hls_list"], {"deviceId": s}) or []:
                    if row.get("liveToken"):
                        c.call(P["hls_delete"], {"liveToken": row["liveToken"]})
            except B.ConnectError:
                pass
            try:
                c.call(P["delete"], {"deviceId": s})
            except B.ConnectError:
                pass

    # ---- what the site sees
    @staticmethod
    def _parse_device(d, serials):
        s = B.clean_serial(d.get("deviceId"))
        if not s or s not in serials:
            return None
        chans = []
        for ch in d.get("channels") or []:
            if not isinstance(ch, dict):
                continue
            st = str(ch.get("channelStatus") or "").lower()
            chans.append({"no": ch.get("channelId"), "name": ch.get("channelName"),
                          "online": True if st == "online" else (False if st else None)})
        st = str(d.get("deviceStatus") or "").lower()
        cat = str(d.get("catalog") or d.get("deviceCatalog") or "").upper()
        kind = "nvr" if cat in ("NVR", "DVR", "HCVR", "XVR") or len(chans) > 1 else "camera"
        return B.device(s, d.get("deviceName") or s, d.get("deviceModel") or "", kind,
                        True if st == "online" else (False if st else None), chans)

    def devices(self, grant):
        serials = [B.clean_serial(s) for s in (grant.get("serials") or [])][:B.MAX_DEVICES]
        if not serials:
            return []
        data = self._client().call(self.paths["details"],
                                   {"deviceList": [{"deviceId": s} for s in serials]}) or {}
        out = []
        for d in data.get("deviceList") or []:
            if isinstance(d, dict):
                row = self._parse_device(d, serials)
                if row:
                    out.append(row)
        return out

    def live(self, grant, serial, channel, hd=False):
        """"Creating Device HLS Address" (permanent until deleted — revoke
        deletes it); an existing one is read back ("Searching Device HLS
        Address"). 0 = HD main stream, 1 = SD sub stream."""
        c = self._client()
        want = 0 if hd else 1
        body = {"deviceId": serial, "channelId": str(channel or 0)}
        try:
            data = c.call(P["hls_create"], dict(body, streamType=want)) or {}
            rows = [data]
        except B.ConnectError as e:
            if e.code != "IDV0055":                 # "The live video already exists"
                raise
            rows = c.call(P["hls_list"], body) or []
        for row in rows:
            if not isinstance(row, dict) or str(row.get("liveStatus") or "1") not in ("1",):
                continue
            streams = row.get("streamList") or []
            pick = [x for x in streams if str(x.get("streamType")) == str(want)] or streams
            for x in pick:
                url = str(x.get("hls") or "")
                if url.startswith("https://") and self._stream_ok(url):
                    cover = str(x.get("coverUrl") or "")
                    return {"url": url, "proto": "hls", "expires_s": 600,
                            "token": str(row.get("liveToken") or ""),
                            "cover": cover if cover.startswith("https://") and self._stream_ok(cover) else ""}
        raise B.ConnectError("no_stream")

    def _records(self, c, serial, channel, start_epoch, end_epoch):
        recs = c.call(self.paths["records"], {
            "deviceId": serial, "channelId": str(channel or 0),
            "beginTime": _local(start_epoch), "endTime": _local(end_epoch), "count": 100}) or {}
        return [r for r in recs.get("records") or [] if isinstance(r, dict)]

    def playback(self, grant, serial, channel, start_epoch, end_epoch):
        """SD / HDD recordings: "Searching for Local Device Videos" lists the
        segments; "Generate HLS Live Stream Based on Device Recordings" plays
        ONE segment (begin / end must equal the segment's own times, start
        within 10 s). No local recording -> the cloud recording list."""
        c = self._client()
        try:
            recs = self._records(c, serial, channel, start_epoch, end_epoch)
        except B.ConnectError as e:
            if e.hint != "no_stream":
                raise
            recs = []
        if recs:
            seg = recs[0]
            for r in recs:
                b = _epoch(r.get("beginTime"))
                if b is not None and b <= float(start_epoch):
                    seg = r
            data = c.call(P["record_hls"], {"deviceId": serial, "channelId": str(channel or 0),
                                            "beginTime": seg.get("beginTime"),
                                            "endTime": seg.get("endTime")}) or {}
            url = str(data.get("url") or "")
            if url.startswith("https://") and self._stream_ok(url):
                b = _epoch(seg.get("beginTime")) or float(start_epoch)
                return {"url": url, "proto": "hls", "expires_s": 10, "token": "",
                        "seek_s": max(0, int(float(start_epoch) - b)),
                        "records": [{"begin": r.get("beginTime"), "end": r.get("endTime")}
                                    for r in recs[:50]]}
            raise B.ConnectError("no_stream")
        cloud = self.cloud_records(grant, serial, channel, start_epoch, end_epoch)
        if not cloud:
            raise B.ConnectError("no_stream")
        # cloud clips play only in Dahua's player SDK (FAQ "Video Play"):
        # honest list with thumbnails for the timeline
        return {"url": "", "proto": "sdk_only", "expires_s": 0, "token": "", "cloud": cloud}

    def clip(self, grant, serial, channel, start_epoch, end_epoch, task=None):
        """Evidence MP4 from the SD / HDD recording: "Create a Dump Task By
        Time" -> "Search Dump File List" (status 1 waiting, 2 done, 3 failed,
        4 combining) -> "Get the File Download Address"."""
        c = self._client()
        if not task:
            data = c.call(P["dump_by_time"], {"deviceId": serial, "channelId": int(channel or 0),
                                              "beginTime": _local(start_epoch),
                                              "endTime": _local(end_epoch)}) or {}
            task = str(data.get("taskId") or "")
            if not task:
                raise B.ConnectError("no_stream")
            return {"url": "", "proto": "mp4", "pending": True, "task": task, "expires_s": 0,
                    "token": ""}
        page = c.call(P["dump_list"], {"pageNum": 1, "pageSize": 10, "taskIds": [str(task)]}) or {}
        rows = [r for r in page.get("pageData") or [] if isinstance(r, dict)
                and str(r.get("taskId")) == str(task) and B.clean_serial(r.get("deviceId")) == serial]
        if not rows:
            raise B.ConnectError("no_stream")
        st = int(rows[0].get("status") or 0)
        if st == 3:
            raise B.ConnectError("dump_failed", str(rows[0].get("errMsg") or "")[:80], "no_stream")
        files = [str(f.get("fileId")) for f in rows[0].get("files") or [] if isinstance(f, dict)]
        if st != 2 or not files:
            return {"url": "", "proto": "mp4", "pending": True, "task": str(task),
                    "expires_s": 0, "token": ""}
        urls = c.call(P["dump_url"], {"fileIds": files[:10]}) or []
        out = [str(u.get("fileUrl") or "") for u in urls if isinstance(u, dict)]
        out = [u for u in out if u.startswith("https://") and self._stream_ok(u)]
        if not out:
            raise B.ConnectError("no_stream")
        return {"url": out[0], "files": out, "proto": "mp4", "pending": False,
                "task": str(task), "expires_s": 3600, "token": ""}

    def snapshot(self, grant, serial, channel):
        data = self._client().call(self.paths["snapshot"], {"deviceId": serial,
                                                            "channelId": str(channel or 0)}) or {}
        url = str(data.get("url") or "")
        if url.startswith("https://") and self._stream_ok(url):
            # the picture is uploaded a few seconds later (FAQ Device #4)
            return {"url": url, "proto": "jpeg", "ready_after_s": 10, "expires_s": 3600, "token": ""}
        raise B.ConnectError("no_stream")

    def picture_url(self, url, serial):
        """Alarm thumbnails in Dahua's ".dav" form are encrypted: "Cloud
        Image Decryption" gives a readable link (valid 30 min)."""
        from urllib.parse import urlparse
        if ".dav" not in (urlparse(str(url)).path or "").lower():
            return url
        data = self._client().call(P["decrypt"], {"imageUrl": url, "deviceId": serial,
                                                  "isTcmDevice": False}) or {}
        u = str(data.get("url") or "")
        return u if u.startswith("https://") and self._stream_ok(u) else ""

    def cloud_records(self, grant, serial, channel, start_epoch, end_epoch):
        try:
            data = self._client().call(P["cloud_records"], {
                "deviceId": serial, "channelId": str(channel or 0),
                "beginTime": _local(start_epoch), "endTime": _local(end_epoch),
                "queryRange": "1-30"}) or {}
        except B.ConnectError as e:
            if e.hint in ("network", "reauth", "revoked"):
                raise
            return []
        out = []
        for r in data.get("records") or []:
            if not isinstance(r, dict):
                continue
            th = str(r.get("thumbUrl") or "")
            out.append({"begin": r.get("beginTime"), "end": r.get("endTime"),
                        "size": r.get("size"), "encrypted": str(r.get("encryptMode")) == "1",
                        "thumb": th if th.startswith("https://") and self._stream_ok(th) else ""})
        return out

    def cloud(self, grant, serial, channel=0):
        """"Get the Cloud Storage Service Information That the Device is
        Using" + the last 24 h of cloud clips."""
        c = self._client()
        try:
            svc = c.call(P["cloud_service"], {"deviceId": serial}) or {}
        except B.ConnectError as e:
            if e.hint in ("network", "reauth", "revoked"):
                raise
            svc = {}
        rows = svc if isinstance(svc, list) else [svc]
        plan = None
        for r in rows:
            if isinstance(r, dict) and str(r.get("channelId", channel)) == str(channel or 0):
                plan = {"name": r.get("name"), "until": r.get("endTime"),
                        "days": r.get("recordSaveDays"),
                        "type": {"1": "event", "2": "continuous"}.get(str(r.get("storageType")), ""),
                        "status": r.get("cloudStatus")}
        now = self.now()
        return {"plan": plan, "clips": self.cloud_records(grant, serial, channel, now - 86400, now)}

    def events(self, grant, serial, since_epoch, channels=None):
        """Poll fallback ("Searching for Messages by Page", kept 7 days);
        the push callback is the main path."""
        body = {"deviceList": [{"deviceId": serial,
                                "channelIdList": [str(x) for x in (channels or [])][:16]}],
                "beginTime": int(float(since_epoch) * 1000), "endTime": int(self.now() * 1000),
                "sortOrder": "asc", "pageNum": 1, "pageSize": 50}
        if not channels:
            body["deviceList"][0].pop("channelIdList")
        data = self._client().call(P["messages"], body) or {}
        out = []
        for m in data.get("pageData") or []:
            ev = self.to_event(m, since_epoch)
            if ev and ev["serial"] == serial:
                out.append(ev)
        return out

    def to_event(self, m, since_epoch=0):
        """One DoLynk message (pushed or polled) -> a normalised alert event,
        or None (status / storage / face / unknown types)."""
        if not isinstance(m, dict):
            return None
        what, kind, obj = classify(m.get("msgType"))
        if what != "alert":
            return None
        serial = B.clean_serial(m.get("deviceId"))
        if not serial:
            return None
        at = _ms(m.get("utcTime") or m.get("time")) or self.now()
        if at < float(since_epoch or 0):
            return None
        pics = m.get("picUrls") or ([m.get("thumbUrl")] if m.get("thumbUrl") else [])
        if isinstance(pics, str):                     # one doc example sends a string
            pics = [pics.strip("[]")]
        pic = ""
        for p in pics or []:
            if isinstance(p, str) and p.startswith("https://") and self._stream_ok(p):
                pic = p
                break
        ch = m.get("channelId")
        return B.event(serial, 0 if ch in (None, "") else ch, at, kind, obj,
                       m.get("msgType") or "", pic, str(m.get("id") or ""))

    def health(self, grant, serial):
        """"Get Device SD Card Status" + "Search Device SD Card Capacity" +
        "Obtaining the Online/Offline Status of Devices"."""
        c = self._client()
        disk = {"id": "1", "state": "unknown"}
        try:
            st = str((c.call(P["sd_status"], {"deviceId": serial}) or {}).get("status") or "").lower()
            disk["state"] = {"normal": "ok", "abnormal": "error", "empty": "none",
                             "recovering": "formatting"}.get(st, "unknown")
        except B.ConnectError as e:
            if e.hint in ("network", "reauth", "revoked"):
                raise
        try:
            stor = c.call(P["sd_storage"], {"deviceId": serial}) or {}
            tot, used = float(stor.get("totalBytes") or 0), float(stor.get("usedBytes") or 0)
            if tot > 0:
                disk["total_gb"] = round(tot / 1e9, 1)
                disk["free_gb"] = round(max(0.0, tot - used) / 1e9, 1)
        except (B.ConnectError, TypeError, ValueError):
            pass
        chans = []
        try:
            on = c.call(P["online"], {"deviceId": serial}) or {}
            for ch in on.get("channels") or []:
                try:
                    chans.append({"no": int(ch.get("channelId")),
                                  "online": str(ch.get("onLine")) == "1"})
                except (TypeError, ValueError):
                    continue
            if not chans:
                chans = [{"no": 0, "online": str(on.get("onLine")) == "1"}]
        except B.ConnectError:
            chans = [{"no": 0, "online": None}]
        return {"source": self.id, "device": serial, "at": self.now(), "disks": [disk],
                "channels": chans}


# ------------------------------------------------------------------ Open ARC
ARC_OK = "DoLynk ARC sign-in OK"


def _masked_match(typed, shown):
    """The ARC device list shows the DMSS account that shared the device,
    sometimes masked ("ab***@mail.com"). Every visible character must match
    and the length must be the same."""
    a, b = str(typed or "").strip().lower(), str(shown or "").strip().lower()
    if not a or not b:
        return False
    if "*" not in b:
        return hmac.compare_digest(a, b)
    if len(a) != len(b):
        head, _, tail = b.partition("*")
        tail = tail.lstrip("*")
        return len(a) > len(head) + len(tail) and a.startswith(head) and a.endswith(tail)
    return all(y == "*" or x == y for x, y in zip(a, b))


class DolynkArcAdapter(DolynkAdapter):
    """The user keeps DMSS: he shares the device with Assisto's ARC company
    in DMSS, then types the serial + the DMSS account he shared from. Live
    video on Open ARC is only the SDK websocket stream (FAQ "Video Play"), so
    this path gives devices, alarms, snapshot and the recording list."""
    id = "dolynk_arc"
    name = "Dahua DMSS (share with Assisto)"
    integration = "dolynk_arc"
    key_fields = ("access_key", "secret_key", "product_id", "arc_email", "arc_password")
    caps = ("devices", "snapshot", "events", "playback_list")
    code_label = ("DMSS অ্যাকাউন্ট (যে ইমেইল / ফোন থেকে Assisto-কে শেয়ার করেছেন)",
                  "DMSS account (the email / phone you shared with Assisto from)")
    code_secret = False
    events_scope = "account"
    paths = dict(P, details=ARC["details"], records=ARC["records"], snapshot=ARC["snapshot"])

    @staticmethod
    def clean_code(v):
        s = str(v or "").strip()
        return s if 3 <= len(s) <= 80 and s.isprintable() and " " not in s else ""

    def configured(self):
        return super().configured() and str(self.cfg.get("arc_on") or "").strip().lower() in (
            "on", "1", "yes", "true")

    def _client(self):
        if not self.configured():
            raise B.ConnectError("not_configured")
        c = Client(self.cfg.get("access_key"), self.cfg.get("secret_key"),
                   self.cfg.get("product_id"), _base(self.cfg),
                   lambda url, body, t, h: self.http(url, body, t, h), self.now)
        c.user = lambda: self._user_token(c)
        return c

    def _user_token(self, c, fresh=False):
        email = str(self.cfg.get("arc_email") or "").strip().lower()
        key = (c.base, c.ak, email)
        hit = _user_tokens.get(key)
        if hit and not fresh and hit[1] > self.now():
            return hit[0]
        pw = str(self.cfg.get("arc_password") or "")
        salt = c.call(ARC["salt"], {"accountEmail": email, "saltType": "2"}, user=False) or {}
        try:
            data = c.call(ARC["login"], {"accountEmail": email, "password": arc_password(
                pw, salt.get("salt") or "", salt.get("random") or "")}, user=False) or {}
        except B.ConnectError as e:
            if e.hint in ("network", "not_configured"):
                raise
            # FAQ Account #5: some regions take the plain password here
            data = c.call(ARC["login"], {"accountEmail": email, "password": pw}, user=False) or {}
        tok = str(data.get("userAccessToken") or "")
        if not tok:
            raise B.ConnectError("arc_login", "", "not_configured")
        try:
            ttl = int(data.get("validitySeconds") or 3600)
        except (TypeError, ValueError):
            ttl = 3600
        _user_tokens[key] = (tok, self.now() + max(300, ttl * 0.9))
        return tok

    def signin(self):
        c = self._client()
        c.token(fresh=True)
        return self._user_token(c, fresh=True)

    def _arc_rows(self, c, serials=None):
        body = {"deviceTypes": [1]}
        if serials:
            body["deviceIds"] = list(serials)[:1000]
        rows = c.call(ARC["devices"], body) or []
        return [r for r in rows if isinstance(r, dict)]

    def link_device(self, serial, code, category=None):
        c = self._client()
        rows = [r for r in self._arc_rows(c, [serial]) if B.clean_serial(r.get("deviceId")) == serial]
        if not rows:
            raise B.ConnectError("not_shared", "", "wrong_code")
        if not _masked_match(code, rows[0].get("account")):
            raise B.ConnectError("account_mismatch", "", "wrong_code")
        c.call(ARC["activate"], {"deviceIds": [serial], "activationStatus": 1})
        return {"mode": "device_code", "serials": [serial]}

    def after_link(self, grant, callback_url=None):
        if not callback_url:
            return None
        try:
            self._client().call(ARC["callback"], {"isPush": 1, "callbackUrl": callback_url})
            return True
        except B.ConnectError:
            return None

    def unlink(self, grant):
        """Revoke: monitoring off and the share released (the user can share
        again in DMSS any time)."""
        c = self._client()
        serials = list(grant.get("serials") or [])
        if not serials:
            return
        for path, body in ((ARC["activate"], {"deviceIds": serials, "activationStatus": 0}),
                           (ARC["unbind"], {"deviceIds": serials})):
            try:
                c.call(path, body)
            except B.ConnectError:
                pass

    def devices(self, grant):
        serials = [B.clean_serial(s) for s in (grant.get("serials") or [])][:B.MAX_DEVICES]
        if not serials:
            return []
        try:
            return super().devices(grant)
        except B.ConnectError as e:
            if e.hint in ("network", "reauth", "revoked"):
                raise
        out = []
        for r in self._arc_rows(self._client(), serials):
            s = B.clean_serial(r.get("deviceId"))
            if s in serials:
                st = r.get("status")
                out.append(B.device(s, r.get("name") or s, "", "camera",
                                    True if st == 1 else (False if st == 0 else None)))
        return out

    def live(self, grant, serial, channel, hd=False):
        raise B.ConnectError("arc_sdk_only", "Open ARC live is SDK-only", "no_stream")

    def playback(self, grant, serial, channel, start_epoch, end_epoch):
        recs = self._records(self._client(), serial, channel, start_epoch, end_epoch)
        if not recs:
            raise B.ConnectError("no_stream")
        return {"url": "", "proto": "sdk_only", "expires_s": 0, "token": "",
                "records": [{"begin": r.get("beginTime"), "end": r.get("endTime")}
                            for r in recs[:50]]}

    def clip(self, *a, **k):
        raise B.ConnectError("unsupported")

    def cloud(self, *a, **k):
        raise B.ConnectError("unsupported")

    def account_events(self, since_epoch):
        """"Get ARC Messages" for the whole ARC company (kept 7 days)."""
        data = self._client().call(ARC["messages"], {
            "beginTime": int(float(since_epoch) * 1000), "endTime": int(self.now() * 1000),
            "pageNum": 1, "pageSize": 50}) or {}
        out = []
        for m in data.get("pageData") or []:
            ev = self.to_event(m, since_epoch)
            if ev:
                out.append(ev)
        return out

    def to_event(self, m, since_epoch=0):
        if isinstance(m, dict) and m.get("picUrl") and not m.get("picUrls"):
            m = dict(m, picUrls=[m.get("picUrl")])
        return super().to_event(m, since_epoch)

    def ack(self, msg_id):
        """"Send the Ack message when event is received" (else re-pushed)."""
        try:
            self._client().call(ARC["ack"], {"id": int(str(msg_id))})
            return True
        except (B.ConnectError, ValueError):
            return False

    def health(self, grant, serial):
        rows = self._arc_rows(self._client(), [serial])
        st = rows[0].get("status") if rows else None
        return {"source": self.id, "device": serial, "at": self.now(),
                "disks": [{"id": "1", "state": "unknown"}],
                "channels": [{"no": 0, "online": True if st == 1 else (False if st == 0 else None)}]}
