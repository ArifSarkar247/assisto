"""Imou Open Platform adapter (open.imoulife.com) + DoLynk (Dahua's
professional cloud, same Open-API protocol family: POST <base>/<method> with
the md5 "time:,nonce:,appSecret:" signature). Reuses logic/imou.py.

Request shapes follow Imou's public Open API docs (bindDevice,
listDeviceDetailsByIds, getAlarmMessage, bindDeviceLive, deviceSdcardStatus,
deviceStorage, queryLocalRecords). DoLynk's method names are assumed to
match until the owner's DoLynk developer account shows its own docs — the
adapter is OFF until that key exists and its Test passes (honest).
NOT yet run against either real platform (keys pending)."""
from datetime import datetime, timedelta

from . import base as B
from .. import imou as IM

BD = timedelta(hours=6)


class ImouAdapter(B.Provider):
    id = "imou"
    name = "Imou"
    integration = "imou"
    key_fields = ("app_id", "app_secret")
    auth_modes = ("device_code", "oauth")
    pic_hosts = IM.SNAPSHOT_HOST_SUFFIXES
    code_label = ("লেবেলের Safety Code", "Safety Code on the label")
    default_base = IM.DEFAULT_API_BASE

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
        c = self.client()
        for s in grant.get("serials") or []:
            try:
                c.unbind_device(s)
            except IM.ImouError:
                pass

    def devices(self, grant):
        c = self.client()
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

    def _stream_ok(self, url):
        return B.host_allowed(url, self.pic_hosts)

    def live(self, grant, serial, channel, hd=False):
        c = self.client()
        want = 0 if hd else 1
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

    def playback(self, grant, serial, channel, start_epoch, end_epoch):
        """The Open HTTP API lists SD-card / DVR recordings but gives no
        playable URL for them (that needs the vendor's player SDK): we say so
        honestly and hand back the recording list for the timeline."""
        c = self.client()
        fmt = "%Y-%m-%d %H:%M:%S"
        b = (datetime.utcfromtimestamp(start_epoch) + BD).strftime(fmt)
        e = (datetime.utcfromtimestamp(end_epoch) + BD).strftime(fmt)
        recs = self._call(c.local_records, serial, str(channel or 0), b, e)
        if not recs:
            raise B.ConnectError("no_stream")
        return {"url": "", "proto": "sdk_only", "expires_s": 0, "token": "",
                "records": [{"begin": r.get("beginTime"), "end": r.get("endTime")}
                            for r in recs[:50] if isinstance(r, dict)]}

    def events(self, grant, serial, since_epoch, channels=None):
        from .. import cctv_rules as CR
        c = self.client()
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
        c = self.client()
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


class DolynkAdapter(ImouAdapter):
    id = "dolynk"
    name = "Dahua DoLynk"
    integration = "dolynk"
    # the base URL is REQUIRED: it comes from the owner's DoLynk developer
    # console (region-specific); we never guess a production host
    key_fields = ("app_id", "app_secret", "api_base")
    auth_modes = ("device_code", "oauth")
    pic_hosts = (".dolynkcloud.com", ".dolynk.com", ".easy4ip.com",
                 ".easy4ipcloud.com", ".dahuasecurity.com", ".imoulife.com")
    code_label = ("লেবেলের Safety Code / ডিভাইস কোড", "Safety Code / device code on the label")
    default_base = ""

    def _stream_ok(self, url):
        extra = tuple(h.strip() for h in str(self.cfg.get("media_hosts") or "").split(",")
                      if h.strip().startswith("."))
        return B.host_allowed(url, self.pic_hosts + extra)
