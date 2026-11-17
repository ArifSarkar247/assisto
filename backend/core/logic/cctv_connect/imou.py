"""Imou Open Platform adapter (open.imoulife.com). Reuses logic/imou.py.
(Dahua DoLynk has its own documented API: see dolynk.py — dolynkreal.)

Request shapes follow Imou's public Open API docs (bindDevice,
listDeviceDetailsByIds, getAlarmMessage, bindDeviceLive, deviceSdcardStatus,
deviceStorage, queryLocalRecords, createDeviceRecordHls, setMessageCallback)."""
import base64
from datetime import datetime, timedelta
from urllib.parse import urlencode, urlparse

from . import base as B
from .. import imou as IM

BD = timedelta(hours=6)
OAUTH_FIELDS = ("oauth_ak", "oauth_sk", "oauth_h5_url")
AUTH_DAYS = 90            # Imou: an end-user authorization lasts 90 days


class _OauthClient(IM.ImouClient):
    """Open API calls on behalf of an end user who authorized our OAuth
    project (Imou docs: system.appId = the project Access Key, signed with the
    project Secret Key, params.token = the user's Ot_ token). Signed with the
    current HMAC-SHA256 form; one retry with the legacy md5 form on SN1001."""

    def __init__(self, ak, sk, base, ot_token, http, now):
        super().__init__(ak, sk, base, http=http, now=now)
        self.signer = IM.sign_v2
        self._ot = ot_token

    def token(self):
        return self._ot

    def call(self, method, params=None):
        try:
            return super().call(method, params)
        except IM.ImouError as e:
            if e.code != "SN1001" or self.signer is IM.sign:
                raise
            self.signer = IM.sign
            return super().call(method, params)


class ImouAdapter(B.Provider):
    id = "imou"
    name = "Imou"
    integration = "imou"
    key_fields = ("app_id", "app_secret")
    auth_modes = ("device_code", "oauth")
    pic_hosts = IM.SNAPSHOT_HOST_SUFFIXES
    code_label = ("লেবেলের Safety Code", "Safety Code on the label")
    default_base = IM.DEFAULT_API_BASE
    # registered in the Imou console (owner 9 Nov): never change
    oauth_redirect_path = "/api/v1/cctv/imou/oauth/callback"

    # ---------------------------------------------------------- OAuth 2.0
    def oauth_ready(self):
        return all(str(self.cfg.get(k) or "").strip() for k in OAUTH_FIELDS)

    def oauth_url(self, state, redirect_uri):
        """The console's "User Authorization H5 Page" + our one-time state
        (the docs do not say whether Imou echoes it; the views also keep it
        in a short secure cookie)."""
        if not self.oauth_ready():
            raise B.ConnectError("not_configured")
        u = str(self.cfg["oauth_h5_url"]).strip()
        if urlparse(u).scheme != "https":
            raise B.ConnectError("not_configured")
        return "%s%s%s" % (u, "&" if "?" in u else "?", urlencode({"state": state}))

    def _base(self):
        return str(self.cfg.get("api_base") or self.default_base).rstrip("/")

    def _token_call(self, form):
        """POST <base>/oauthTokenV2, form body, Basic base64(AK:SK) (Imou docs)."""
        ak, sk = str(self.cfg["oauth_ak"]).strip(), str(self.cfg["oauth_sk"]).strip()
        auth = base64.b64encode(("%s:%s" % (ak, sk)).encode()).decode()
        try:
            from . import quota as Q
            Q.bump(self.id, api=1)
        except Exception:
            pass
        res = B.json_post(self.http, self._base() + "/oauthTokenV2", form,
                          headers={"Authorization": "Basic " + auth}, form=True,
                          ok_status=(200, 400, 401))
        if res.get("error"):
            raise B.ConnectError("oauth_" + str(res.get("error"))[:30],
                                 res.get("error_description") or "")
        tok = str(res.get("access_token") or "")
        if not tok:
            raise B.ConnectError("no_token")
        try:
            ttl = int(res.get("expires_in") or 7200)
        except (TypeError, ValueError):
            ttl = 7200
        return tok, str(res.get("refresh_token") or ""), ttl

    def oauth_finish(self, code, redirect_uri):
        if not self.oauth_ready():
            raise B.ConnectError("not_configured")
        tok, ref, ttl = self._token_call({"grant_type": "authorization_code", "code": code,
                                          "redirect_uri": redirect_uri})
        now = self.now()
        return {"mode": "oauth", "access_token": tok, "refresh_token": ref,
                "expires_at": now + ttl, "auth_until": now + AUTH_DAYS * 86400, "serials": []}

    def oauth_refresh(self, grant):
        if not grant.get("refresh_token") or not self.oauth_ready():
            raise B.ConnectError("token_expired")
        if float(grant.get("auth_until") or 0) and float(grant["auth_until"]) < self.now():
            raise B.ConnectError("token_expired", "authorization older than 90 days")
        tok, ref, ttl = self._token_call({"grant_type": "refresh_token",
                                          "refresh_token": grant["refresh_token"]})
        return dict(grant, access_token=tok, refresh_token=ref or grant["refresh_token"],
                    expires_at=self.now() + ttl)

    def _client(self, grant):
        """The app client (device_code) or the end-user client (oauth)."""
        if (grant or {}).get("mode") == "oauth":
            if not self.oauth_ready():
                raise B.ConnectError("not_configured")
            c = _OauthClient(self.cfg["oauth_ak"], self.cfg["oauth_sk"], self._base(),
                             grant.get("access_token") or "",
                             http=lambda url, body, t: self.http(url, body, t, {}), now=self.now)
            c.quota_provider = self.id
            return c
        c = self.client()
        c.quota_provider = self.id
        return c

    def after_link(self, grant, callback_url=None):
        """Ask Imou to PUSH alarms, device status and people counting
        (numberstat) to our callback — push costs no API polling. Falls back
        to alarms + status when the account does not offer numberstat."""
        if not callback_url:
            return None
        clients = [self.client()]
        if (grant or {}).get("mode") == "oauth":
            clients.append(self._client(grant))
        for c in clients:
            # imou-real: capabilityEvent = person / motion on current models
            for flags in (IM.CALLBACK_FLAGS + ",numberstat", IM.CALLBACK_FLAGS,
                          "alarm,deviceStatus"):
                try:
                    c.set_callback(callback_url, flags)
                    break
                except IM.ImouError:
                    continue
        return True

    def client(self):
        if not self.configured():
            raise B.ConnectError("not_configured")
        return IM.ImouClient(self.cfg.get("app_id"), self.cfg.get("app_secret"),
                             self.cfg.get("api_base") or self.default_base,
                             http=lambda url, body, t: self.http(url, body, t, {}),
                             now=self.now)

    @staticmethod
    def _map(e):
        code = {"DV1001": "taken", "DV1003": "wrong_code", "DV1007": "offline",
                "DV1014": "wrong_code", "OP1009": "token_expired",
                "TK1002": "token_expired", "LV1002": "offline"}.get(e.code, e.code)
        return B.ConnectError(code, e.msg)

    def _call(self, fn, *a):
        try:
            return fn(*a)
        except IM.ImouError as e:
            raise self._map(e)

    def _tok(self, c):
        return self._call(c.token)

    def link_device(self, serial, code):
        c = self.client()
        try:
            c.bind_device(serial, code)
        except IM.ImouError as e:
            if e.code == "network":
                raise self._map(e)
            try:                      # already in our account? proven by a query
                c.device_online(serial)
            except IM.ImouError:
                raise self._map(e)
        return {"mode": "device_code", "serials": [serial]}

    def unlink(self, grant):
        if (grant or {}).get("mode") == "oauth":
            # Imou documents no revoke call: we drop the tokens; the device
            # stays the user's own (he can also remove Assisto in Imou Life)
            return None
        c = self.client()
        for s in grant.get("serials") or []:
            try:
                c.unbind_device(s)
            except IM.ImouError:
                pass

    def devices(self, grant):
        c = self._client(grant)
        if grant.get("mode") == "oauth":
            return self._oauth_devices(c)
        serials = (grant.get("serials") or [])[:B.MAX_DEVICES]
        if not serials:
            return []
        data = self._call(c.call, "listDeviceDetailsByIds", {
            "token": self._tok(c), "deviceList": [{"deviceId": s} for s in serials]})
        out = []
        for d in (data.get("deviceList") or []):
            if not isinstance(d, dict):
                continue
            s = B.clean_serial(d.get("deviceId"))
            if s not in serials:
                continue                          # scope: only this site's devices
            chans = [{"no": ch.get("channelId"), "name": ch.get("channelName"),
                      "online": str(ch.get("channelStatus") or "").lower() == "online"
                      if ch.get("channelStatus") else None}
                     for ch in d.get("channelList") or [] if isinstance(ch, dict)]
            st = str(d.get("deviceStatus") or "").lower()
            out.append(B.device(s, d.get("deviceName") or s, d.get("deviceModel") or "",
                                "nvr" if len(chans) > 1 else "camera",
                                True if st == "online" else (False if st else None), chans))
        return out

    def _oauth_devices(self, c):
        """Every device the end user authorized: v2 device.detail.page (Imou
        docs), legacy deviceBaseList as a fallback. Shapes parsed tolerantly."""
        rows = []
        try:
            for page in range(1, 4):
                d = self._call(c.call, "v2/device.detail.page", {
                    "token": c.token(), "page": page, "pageSize": 50, "source": "bindAndShare"})
                got = d.get("deviceList") or []
                rows.extend(got)
                if len(got) < 50:
                    break
        except B.ConnectError as e:
            if e.hint in ("network", "reauth"):
                raise
            d = self._call(c.call, "deviceBaseList", {
                "token": c.token(), "bindId": -1, "limit": 50, "type": "bindAndShare",
                "needApInfo": False})
            rows = d.get("deviceList") or []
        out = []
        for d in rows[:B.MAX_DEVICES]:
            if not isinstance(d, dict):
                continue
            s = B.clean_serial(d.get("deviceId"))
            if not s:
                continue
            chans = []
            for ch in d.get("channelList") or d.get("channels") or []:
                if not isinstance(ch, dict):
                    continue
                st = str(ch.get("channelStatus", ch.get("status", ch.get("channelOnline", ""))) or "").lower()
                chans.append({"no": ch.get("channelId"), "name": ch.get("channelName"),
                              "online": True if st in ("online", "1", "true") else
                              (False if st in ("offline", "0", "false") else None)})
            st = str(d.get("deviceStatus", d.get("status", d.get("onLine", ""))) or "").lower()
            out.append(B.device(s, d.get("deviceName") or d.get("name") or s,
                                d.get("deviceModel") or d.get("productId") or "",
                                "nvr" if len(chans) > 1 else "camera",
                                True if st in ("online", "1", "true") else
                                (False if st in ("offline", "0", "false") else None), chans))
        return out

    def _stream_ok(self, url):
        return B.host_allowed(url, self.pic_hosts)

    def _rtsp_ok(self, url):
        try:
            u = urlparse(str(url or ""))
        except ValueError:
            return False
        host = (u.hostname or "").lower()
        return u.scheme in ("rtsp", "rtsps") and any(
            host == h.lstrip(".") or host.endswith(h) for h in self.pic_hosts)

    def live(self, grant, serial, channel, hd=False):
        c = self._client(grant)
        want = 0 if hd else 1
        if grant.get("mode") == "oauth":
            try:
                return self._hls(c, serial, channel, want)
            except B.ConnectError as e:
                if e.hint in ("offline", "network"):
                    raise
            d = self._call(c.call, "getStreamUrl", {"token": c.token(), "deviceId": serial,
                                                    "channelId": int(channel or 0),
                                                    "streamId": want})
            url = str(d.get("url") or "")
            if url and self._rtsp_ok(url):
                return {"url": url, "proto": "rtsp", "expires_s": 600, "token": ""}
            raise B.ConnectError("no_stream")
        return self._hls(c, serial, channel, want)

    def _hls(self, c, serial, channel, want):
        try:
            data = c.call("bindDeviceLive", {"token": self._tok(c), "deviceId": serial,
                                             "channelId": str(channel or 0), "streamId": want})
        except IM.ImouError as e:
            if e.code != "LV1001":
                raise self._map(e)
            data = self._call(c.call, "getLiveStreamInfo", {
                "token": self._tok(c), "deviceId": serial, "channelId": str(channel or 0)})
        streams = data.get("streams") or []
        pick = [x for x in streams if str(x.get("streamId")) == str(want)] or streams
        for x in pick:
            url = str(x.get("hls") or "")
            if url and self._stream_ok(url):
                return {"url": url, "proto": "hls", "expires_s": 600,
                        "token": str(x.get("liveToken") or data.get("liveToken") or "")}
        raise B.ConnectError("no_stream")

    def playback(self, grant, serial, channel, start_epoch, end_epoch, hd=False):
        """imou-real: the recording list (queryLocalRecords) + an HLS playback
        address from createDeviceRecordHls (SD card first, then Imou cloud
        storage). The window must sit inside ONE device day, so a window
        crossing midnight starts at 00:00 of the end day. When Imou gives no
        address (old firmware DV1026 / no cloud plan) the list still comes
        back with proto "sdk_only" — said honestly in the app."""
        c = self._client(grant)
        fmt = "%Y-%m-%d %H:%M:%S"
        bdt = datetime.utcfromtimestamp(start_epoch) + BD
        edt = datetime.utcfromtimestamp(end_epoch) + BD
        if bdt.date() != edt.date():
            bdt = datetime(edt.year, edt.month, edt.day)
        b, e = bdt.strftime(fmt), edt.strftime(fmt)
        ch = str(channel or 0)
        recs = self._call(c.local_records, serial, ch, b, e)
        rows = [{"begin": r.get("beginTime"), "end": r.get("endTime")}
                for r in (recs or [])[:50] if isinstance(r, dict)]
        for rtype in (("localRecord", "cloudRecord") if rows else ("cloudRecord",)):
            try:
                url = c.record_hls(serial, ch, b, e, rtype, hd)
            except IM.ImouError as err:
                if err.code in ("network", "DV1007", "LV1002"):
                    raise self._map(err)
                continue
            if self._stream_ok(url):
                return {"url": url, "proto": "hls", "expires_s": 600, "token": "",
                        "source": "sd" if rtype == "localRecord" else "cloud",
                        "records": rows}
        if not rows:
            raise B.ConnectError("no_stream")
        return {"url": "", "proto": "sdk_only", "expires_s": 0, "token": "", "records": rows}

    def events(self, grant, serial, since_epoch, channels=None):
        from .. import cctv_rules as CR
        c = self._client(grant)
        minutes = max(1, min(60, int((self.now() - float(since_epoch)) // 60) + 1))
        rows = []
        for ch in [str(x) for x in (channels or ["0"])][:16]:
            rows.extend(self._call(c.alarms, serial, ch, minutes, 20) or [])
        out = []
        for m in rows:
            a = IM.parse_alarm(m)
            if a is None:
                continue
            cls = CR.classify_imou(m)
            kind = cls.get("kind") or ("person" if a["human"] else "")
            try:
                at = float(m.get("time") or 0) or self.now()
            except (TypeError, ValueError):
                at = self.now()
            if at < float(since_epoch):
                continue
            pic = a["pic"] if a["pic"] and self._stream_ok(a["pic"]) else ""
            out.append(B.event(a["device_id"].upper(), a["channel"], at, kind,
                               cls.get("object") or ("person" if a["human"] else None),
                               m.get("msgType") or m.get("type") or "", pic, a["alarm_id"]))
        return out

    def health(self, grant, serial):
        c = self._client(grant)
        st = IM.sd_state(self._call(c.sd_status, serial))
        disk = {"id": "1", "state": {"ok": "ok", "error": "error", "none": "none",
                                     "formatting": "formatting"}.get(st, "unknown")}
        try:
            stor = c.sd_storage(serial) or {}
            tot, used = float(stor.get("totalBytes") or 0), float(stor.get("usedBytes") or 0)
            if tot > 0:
                disk["total_gb"] = round(tot / 1e9, 1)
                disk["free_gb"] = round(max(0.0, tot - used) / 1e9, 1)
        except (IM.ImouError, TypeError, ValueError):
            pass
        online = None
        try:
            online = c.is_online(serial)
        except IM.ImouError:
            pass
        return {"source": self.id, "device": serial, "at": self.now(), "disks": [disk],
                "channels": [{"no": 0, "online": online}]}

