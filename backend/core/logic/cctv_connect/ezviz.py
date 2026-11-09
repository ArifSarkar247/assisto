"""EZVIZ Open Platform adapter (open.ezvizlife.com). Reuses the proven
logic/ezviz.py client (token, add, alarms, live, playback, SD status) and
adds the device + channel list. Request shapes follow EZVIZ's public HTTP
API docs; NOT yet run against the real platform (keys pending)."""
import time

from . import base as B
from .. import ezviz as EZ

LOCAL_OFFSET_S = 6 * 3600     # Bangladesh time: the DVR's own clock


def _local(epoch):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(float(epoch) + LOCAL_OFFSET_S))


class EzvizAdapter(B.Provider):
    id = "ezviz"
    name = "EZVIZ"
    integration = "ezviz"
    key_fields = ("app_key", "app_secret")
    auth_modes = ("device_code", "oauth")
    pic_hosts = EZ.SNAPSHOT_HOST_SUFFIXES
    code_label = ("লেবেলের ৬ অক্ষরের Verification Code", "6-letter Verification Code on the label")

    def client(self):
        if not self.configured():
            raise B.ConnectError("not_configured")
        c = EZ.EzvizClient(self.cfg.get("app_key"), self.cfg.get("app_secret"),
                           self.cfg.get("api_base"),
                           http=lambda url, form, t: self.http(url, form, t, {}),
                           now=self.now)
        return c

    @staticmethod
    def _map(e):
        code = {"20010": "wrong_code", "20013": "taken", "10002": "token_expired",
                "20007": "offline", "20002": "wrong_code"}.get(e.code, e.code)
        return B.ConnectError(code, e.msg)

    def _call(self, fn, *a):
        try:
            return fn(*a)
        except EZ.EzvizError as e:
            raise self._map(e)

    def link_device(self, serial, code):
        c = self.client()
        try:
            c.add_device(serial, code)
        except EZ.EzvizError as e:
            if e.code != "20017":          # 20017 = already in this account: fine
                raise self._map(e)
        return {"mode": "device_code", "serials": [serial]}

    def unlink(self, grant):
        c = self.client()
        for s in grant.get("serials") or []:
            try:
                c.delete_device(s)
            except EZ.EzvizError:
                pass

    def devices(self, grant):
        c = self.client()
        out = []
        for s in (grant.get("serials") or [])[:B.MAX_DEVICES]:
            info = self._call(c.call, "/api/lapp/device/info", {"deviceSerial": s}) or {}
            rows = self._call(c.call, "/api/lapp/device/camera/list", {"deviceSerial": s}) or []
            chans = [{"no": r.get("channelNo"), "name": r.get("channelName"),
                      "online": {1: True, 0: False}.get(r.get("status"))}
                     for r in rows if isinstance(r, dict)]
            st = info.get("status") if isinstance(info, dict) else None
            out.append(B.device(s, (info or {}).get("deviceName") or s,
                                (info or {}).get("model") or "",
                                "nvr" if len(chans) > 1 else "camera",
                                {1: True, 0: False}.get(st), chans))
        return out

    def live(self, grant, serial, channel, hd=False):
        url = self._call(self.client().live_address, serial, int(channel or 1), hd, 300)
        return {"url": url, "proto": "hls", "expires_s": 300, "token": ""}

    def playback(self, grant, serial, channel, start_epoch, end_epoch):
        url = self._call(self.client().playback_hls, serial, int(channel or 1),
                         _local(start_epoch), _local(end_epoch))
        if not url:
            raise B.ConnectError("no_stream")
        return {"url": url, "proto": "hls", "expires_s": 300, "token": "",
                "source": "device_storage"}

    def events(self, grant, serial, since_epoch, channels=None):
        from .. import cctv_rules as CR
        rows = self._call(self.client().alarms, serial, int(since_epoch * 1000),
                          int(self.now() * 1000) + 1000)
        out = []
        for row in rows:
            a = EZ.parse_alarm(row)
            if a is None:
                continue
            cls = CR.classify_ezviz(row)
            kind = cls.get("kind") or ("person" if a["human"] else "")
            out.append(B.event(a["serial"], a["channel"], a["at_ms"] / 1000.0, kind,
                               cls.get("object") or ("person" if a["human"] else None),
                               row.get("alarmType"), a["pic"] or "", a["alarm_id"]))
        return out

    def health(self, grant, serial):
        c = self.client()
        rows = self._call(c.sd_status, serial)
        st = EZ.sd_state(rows)
        disks = [{"id": str((r or {}).get("index") or i + 1),
                  "state": {"0": "ok", "1": "error", "2": "unformatted",
                            "3": "formatting"}.get(str((r or {}).get("status")), "unknown")}
                 for i, r in enumerate(rows or [])] if st != "none" else [{"id": "1", "state": "none"}]
        online = self._call(c.is_online, serial)
        chans = []
        try:
            for r in self._call(c.call, "/api/lapp/device/camera/list", {"deviceSerial": serial}) or []:
                chans.append({"no": r.get("channelNo"), "name": r.get("channelName"),
                              "online": {1: True, 0: False}.get(r.get("status"))})
        except B.ConnectError:
            chans = [{"no": 1, "online": online}]
        return {"source": "ezviz", "device": serial, "at": self.now(), "disks": disks,
                "channels": chans}
