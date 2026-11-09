"""Hik-Connect for Teams / Hik-Partner Pro OpenAPI adapter (Hikvision cloud).

Protocol (Hikvision "hccgw" OpenAPI, public developer portal; the account
is approved by Hikvision — see owner_actions/CCTV_DEV_ACCOUNTS_BN.md):
  token    POST <base>/api/hccgw/platform/v1/token/get {appKey, secretKey}
           -> {"errorCode": "0", "data": {"accessToken", "expireTime" (epoch s),
               "areaDomain"}}; later calls go to areaDomain with header
           "Token: <accessToken>".
  add      POST /api/hccgw/resource/v1/devices/add
           {"deviceList": [{"deviceSerial", "verifyCode", "name"}]}
  devices  POST /api/hccgw/resource/v1/devices/get {"pageIndex", "pageSize",
           "filter": {"deviceSerial"}} -> data.device[{serialNo, name, type,
           onlineStatus}]
  cameras  POST /api/hccgw/resource/v1/areas/cameras/get {"pageIndex", "pageSize",
           "filter": {"deviceSerial"}} -> data.camera[{id, name, channelNo,
           online, device: {serialNo}}]
  live     POST /api/hccgw/video/v1/live/address/get {"resourceId", "protocol": 2
           (HLS), "quality", "expireTime"} -> data.url
  playback same call with "type": 2 (device recording) + startTime / stopTime
  alarms   POST /api/hccgw/alarm/v1/mq/subscribe {"subscribeType": 1} once, then
           /api/hccgw/alarm/v1/mq/messages {} -> data.alarmMsg[{guid, eventType,
           alarmTime, deviceSerial, channelNo, pictureUrl, ruleTarget}]
  delete   POST /api/hccgw/resource/v1/devices/delete {"deviceSerial"}
  storage  POST /api/hccgw/resource/v1/devices/hdd/get {"deviceSerial"} ->
           data.hddList[{id, status, capacity, freeSpace}] (where the model
           reports it; otherwise only online status is used)

Paths come from the public OpenAPI reference as read on 9 Nov 2026; they are
NOT yet proven against a live account (Hikvision approval pending). The
connector stays OFF until the owner saves the AppKey/Secret and Test passes.
"""
from . import base as B

DEFAULT_BASE = "https://ieu.hik-connect.com"
BASE_HOSTS = (".hik-connect.com", ".hik-partner.com", ".hikvision.com",
              ".hikcentralconnect.com")

_token_cache = {}     # appKey -> (token, area, expires)


class HikConnectAdapter(B.Provider):
    id = "hikconnect"
    name = "Hikvision Hik-Connect"
    integration = "hikconnect"
    key_fields = ("app_key", "app_secret")
    auth_modes = ("device_code", "oauth")
    pic_hosts = BASE_HOSTS + (".ezvizlife.com", ".ys7.com")
    code_label = ("লেবেলের ৬ অক্ষরের Verification Code", "6-letter Verification Code on the label")
    events_scope = "account"

    # ---- transport ----
    def _base(self):
        b = str(self.cfg.get("api_base") or DEFAULT_BASE).rstrip("/")
        return b if B.host_allowed(b + "/", BASE_HOSTS) else DEFAULT_BASE

    def _post(self, base, path, payload, token=None):
        res = B.json_post(self.http, base + path, payload,
                          headers={"Token": token} if token else None)
        code = str(res.get("errorCode", res.get("code", "")))
        if code not in ("0", "200"):
            raise B.ConnectError(HIK_CODES.get(code, code or "unknown"),
                                 res.get("message") or res.get("msg"))
        return res.get("data") or {}

    def token(self):
        if not self.configured():
            raise B.ConnectError("not_configured")
        key = self.cfg["app_key"]
        hit = _token_cache.get(key)
        if hit and hit[2] > self.now() + 60:
            return hit[0], hit[1]
        d = self._post(self._base(), "/api/hccgw/platform/v1/token/get",
                       {"appKey": key, "secretKey": self.cfg["app_secret"]})
        tok = d.get("accessToken")
        if not tok:
            raise B.ConnectError("no_token")
        area = str(d.get("areaDomain") or self._base()).rstrip("/")
        if not B.host_allowed(area + "/", BASE_HOSTS):
            area = self._base()
        try:
            exp = float(d.get("expireTime"))
            exp = exp / 1000.0 if exp > 1e11 else exp
        except (TypeError, ValueError):
            exp = self.now() + 3600
        _token_cache[key] = (tok, area, exp)
        return tok, area

    def call(self, path, payload):
        tok, area = self.token()
        try:
            return self._post(area, path, payload, tok)
        except B.ConnectError as e:
            if e.code != "token_expired":
                raise
            _token_cache.pop(self.cfg.get("app_key"), None)
            tok, area = self.token()
            return self._post(area, path, payload, tok)

    # ---- authorize once ----
    def link_device(self, serial, code):
        try:
            self.call("/api/hccgw/resource/v1/devices/add", {
                "deviceList": [{"deviceSerial": serial, "verifyCode": code,
                                "name": serial}]})
        except B.ConnectError as e:
            if e.code != "already_mine":
                raise
        return {"mode": "device_code", "serials": [serial]}

    def unlink(self, grant):
        for s in grant.get("serials") or []:
            try:
                self.call("/api/hccgw/resource/v1/devices/delete", {"deviceSerial": s})
            except B.ConnectError:
                pass

    # ---- read ----
    def _cameras(self, serial):
        d = self.call("/api/hccgw/resource/v1/areas/cameras/get", {
            "pageIndex": 1, "pageSize": B.MAX_CHANNELS, "filter": {"deviceSerial": serial}})
        out = []
        for c in d.get("camera") or []:
            if not isinstance(c, dict):
                continue
            dev = c.get("device") or {}
            if B.clean_serial(dev.get("serialNo") or serial) != serial:
                continue
            out.append({"no": c.get("channelNo"), "name": c.get("name"),
                        "online": {1: True, 0: False, "1": True, "0": False,
                                   True: True, False: False}.get(c.get("online")),
                        "rid": str(c.get("id") or "")[:64]})
        return out

    def devices(self, grant):
        out = []
        for s in (grant.get("serials") or [])[:B.MAX_DEVICES]:
            d = self.call("/api/hccgw/resource/v1/devices/get", {
                "pageIndex": 1, "pageSize": 10, "filter": {"deviceSerial": s}})
            row = next((x for x in d.get("device") or []
                        if isinstance(x, dict) and B.clean_serial(x.get("serialNo")) == s), {})
            chans = self._cameras(s)
            on = row.get("onlineStatus")
            out.append(B.device(s, row.get("name") or s, row.get("type") or "",
                                "nvr" if len(chans) > 1 else "camera",
                                {1: True, 0: False, "1": True, "0": False}.get(on), chans))
        return out

    def _rid(self, serial, channel):
        for c in self._cameras(serial):
            if str(c["no"]) == str(channel):
                return c["rid"]
        raise B.ConnectError("no_channel")

    def live(self, grant, serial, channel, hd=False):
        d = self.call("/api/hccgw/video/v1/live/address/get", {
            "resourceId": self._rid(serial, channel), "protocol": 2,
            "quality": 1 if hd else 2, "expireTime": 300})
        url = str(d.get("url") or "")
        if not url or not B.host_allowed(url, self.pic_hosts):
            raise B.ConnectError("no_stream")
        return {"url": url, "proto": "hls", "expires_s": 300, "token": ""}

    def playback(self, grant, serial, channel, start_epoch, end_epoch):
        d = self.call("/api/hccgw/video/v1/live/address/get", {
            "resourceId": self._rid(serial, channel), "protocol": 2, "type": 2,
            "quality": 2, "expireTime": 300,
            "startTime": int(start_epoch), "stopTime": int(end_epoch)})
        url = str(d.get("url") or "")
        if not url or not B.host_allowed(url, self.pic_hosts):
            raise B.ConnectError("no_stream")
        return {"url": url, "proto": "hls", "expires_s": 300, "token": "",
                "source": "device_storage"}

    def subscribe(self):
        self.call("/api/hccgw/alarm/v1/mq/subscribe", {"subscribeType": 1})

    def poll_messages(self):
        """All new alarm messages of the account (one queue per developer
        account); the caller routes them to sites by serial."""
        d = self.call("/api/hccgw/alarm/v1/mq/messages", {})
        return [m for m in (d.get("alarmMsg") or []) if isinstance(m, dict)]

    def parse(self, m):
        from .. import cctv_rules as CR
        serial = B.clean_serial(m.get("deviceSerial"))
        if not serial:
            return None
        ev = {"event": str(m.get("eventType") or "").lower(),
              "target": str(m.get("ruleTarget") or m.get("targetType") or "")}
        cls = CR.classify_hook(ev)
        try:
            at = float(m.get("alarmTime") or 0)
            at = at / 1000.0 if at > 1e11 else at
        except (TypeError, ValueError):
            at = self.now()
        pic = m.get("pictureUrl") or ""
        return B.event(serial, m.get("channelNo") or 1, at or self.now(),
                       cls.get("kind") or "", cls.get("object"), m.get("eventType"),
                       pic if B.host_allowed(pic, self.pic_hosts) else "", m.get("guid"))

    def account_events(self, since_epoch):
        out = []
        for m in self.poll_messages():
            e = self.parse(m)
            if e and e["at"] >= since_epoch - 300:
                out.append(e)
        return out

    def health(self, grant, serial):
        chans = [{"no": c["no"], "name": c["name"], "online": c["online"]}
                 for c in self._cameras(serial)]
        disks = []
        try:
            d = self.call("/api/hccgw/resource/v1/devices/hdd/get", {"deviceSerial": serial})
            for h in d.get("hddList") or []:
                st = str(h.get("status") or "").lower()
                disks.append({"id": str(h.get("id") or len(disks) + 1),
                              "state": {"normal": "ok", "ok": "ok", "error": "error",
                                        "abnormal": "error", "unformatted": "unformatted",
                                        "full": "full", "none": "none"}.get(st, "unknown"),
                              "total_gb": _gb(h.get("capacity")),
                              "free_gb": _gb(h.get("freeSpace"))})
        except B.ConnectError:
            pass                       # model / account without HDD status
        return {"source": self.id, "device": serial, "at": self.now(),
                "disks": disks, "channels": chans}


def _gb(mb):
    try:
        return round(float(mb) / 1024.0, 1)
    except (TypeError, ValueError):
        return None


HIK_CODES = {"OPEN000001": "token_expired", "OPEN000002": "token_expired",
             "EVZ20010": "wrong_code", "EVZ20013": "taken", "EVZ20017": "already_mine",
             "EVZ20007": "offline", "20010": "wrong_code", "20013": "taken",
             "20017": "already_mine"}
