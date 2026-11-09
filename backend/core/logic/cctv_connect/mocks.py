"""
mocks.py — in-memory simulations of the four vendor clouds (EZVIZ, Imou,
Hik-Connect, DoLynk) for CI and the E2E proof. Each `http` callable has the
adapters' transport signature http(url, body, timeout, headers) and answers
like the vendor's public API docs describe (shapes, error codes) — synthetic
data only (no real serials, no real people).

    sim = VendorSims()
    sim.add_device("ezviz", "BD1234567", "ABCDEF", channels=4)
    adapter = cctv_connect.adapter("ezviz", http=sim.http, cfg=sim.cfg("ezviz"))
    sim.push_alarm("ezviz", "BD1234567", 1, "human")       # an AI event
    sim.set_disk("ezviz", "BD1234567", "error")             # a failed disk
"""
import json
import time
from urllib.parse import urlparse

HOSTS = {"ezviz": "https://open.ezvizlife.com", "imou": "https://openapi.easy4ip.com/openapi",
         "hikconnect": "https://ieu.hik-connect.com", "dolynk": "https://openapi.dolynkcloud.com/openapi"}
PIC = {"ezviz": "https://pic.ezvizlife.com/a/%s.jpg", "imou": "https://pic.easy4ip.com/a/%s.jpg",
       "hikconnect": "https://pic.hik-connect.com/a/%s.jpg",
       "dolynk": "https://pic.dolynkcloud.com/a/%s.jpg"}
STREAM = {"ezviz": "https://hls.ezvizlife.com/live/%s/%s.m3u8",
          "imou": "https://hls.easy4ip.com/live/%s/%s.m3u8",
          "hikconnect": "https://hls.hik-connect.com/live/%s/%s.m3u8",
          "dolynk": "https://hls.dolynkcloud.com/live/%s/%s.m3u8"}
ALARM_TYPES = {"ezviz": {"human": "humanDetection", "motion": 10000, "cover": 10011,
                         "vehicle": "vehicleDetection"},
               "imou": {"human": "human", "motion": "videoMotion", "cover": "videoBlind",
                        "vehicle": "vehicle"},
               "hikconnect": {"human": "fielddetection", "motion": "vmd",
                              "cover": "shelteralarm", "vehicle": "linedetection"},
               "dolynk": {"human": "human", "motion": "videoMotion", "cover": "videoBlind",
                          "vehicle": "vehicle"}}


class _Dev:
    def __init__(self, serial, code, channels, name):
        self.serial, self.code, self.channels, self.name = serial, code, channels, name
        self.owner = None            # the developer account it is bound to
        self.oauth_user = False      # in the END USER's own Imou Life account
        self.online = True
        self.offline_channels = set()
        self.disk = "ok"
        self.alarms = []
        self.total_gb, self.free_gb = 1000.0, 400.0


class VendorSims:
    def __init__(self, now=None):
        self.now = now or time.time
        self.devs = {v: {} for v in HOSTS}
        self.calls = []
        self.hik_queue = []
        self.fail_network = set()     # vendors that "lose internet"
        self.oauth_codes = {"good-code": "Ot_sim"}   # Imou OAuth: code -> token
        self.oauth_refresh = {"rt-sim": "Ot_sim2"}

    # ---------------- scenario helpers
    def cfg(self, vendor):
        base = {"ezviz": {"app_key": "ezk", "app_secret": "ezs"},
                "imou": {"app_id": "imid", "app_secret": "ims", "oauth_ak": "imak",
                         "oauth_sk": "imsk",
                         "oauth_h5_url": "https://open.imoulife.com/oauth/h5?project=sim"},
                "hikconnect": {"app_key": "hck", "app_secret": "hcs"},
                "dolynk": {"access_key": "dlid", "secret_key": "dls",
                           "api_base": "https://openapi.dolynkcloud.com", "api_path": "/openapi"}}[vendor]
        return dict(base)

    def add_device(self, vendor, serial, code, channels=1, name=None):
        d = _Dev(serial, code, channels, name or "%s %s" % (vendor.upper(), serial[-4:]))
        self.devs[vendor][serial] = d
        return d

    def push_alarm(self, vendor, serial, channel=1, kind="human", at=None):
        d = self.devs[vendor][serial]
        at = at if at is not None else self.now()
        aid = "%s-%d" % (serial, len(d.alarms) + len(self.hik_queue) + 1)
        row = {"id": aid, "channel": channel, "type": ALARM_TYPES[vendor][kind],
               "at": at, "pic": PIC[vendor] % aid}
        d.alarms.append(row)
        if vendor == "hikconnect":
            self.hik_queue.append(dict(row, serial=serial))
        return aid

    def set_disk(self, vendor, serial, state, free_gb=None):
        d = self.devs[vendor][serial]
        d.disk = state
        if free_gb is not None:
            d.free_gb = free_gb

    # ---------------- transport
    def http(self, url, body, timeout, headers=None):
        u = urlparse(url)
        vendor = self._vendor(u.hostname or "")
        self.calls.append((vendor, u.path))
        if vendor in self.fail_network:
            raise OSError("network down (simulated)")
        if isinstance(body, (str, bytes)):
            try:
                payload = json.loads(body or "{}")
            except ValueError:
                payload = {}
        else:
            payload = dict(body or {})
        fn = getattr(self, "_" + vendor)
        return 200, json.dumps(fn(u.path, payload, headers or {}))

    def _vendor(self, host):
        if "ezviz" in host:
            return "ezviz"
        if "hik" in host:
            return "hikconnect"
        if "dolynk" in host:
            return "dolynk"
        return "imou"

    # ---------------- EZVIZ
    def _ezviz(self, path, f, headers):
        devs = self.devs["ezviz"]
        ok = lambda data=None: {"code": "200", "msg": "Operation succeeded", "data": data}  # noqa: E731
        if path == "/api/lapp/token/get":
            if f.get("appKey") != "ezk" or f.get("appSecret") != "ezs":
                return {"code": "10017", "msg": "appKey not exist"}
            return ok({"accessToken": "at.sim", "expireTime": int((self.now() + 7 * 86400) * 1000),
                       "areaDomain": "https://isgpopen.ezvizlife.com"})
        s = str(f.get("deviceSerial") or "")
        d = devs.get(s)
        if path == "/api/lapp/device/add":
            if d is None or d.code != f.get("validateCode"):
                return {"code": "20010", "msg": "verify code error"}
            if d.owner and d.owner != "sim":
                return {"code": "20013", "msg": "added by others"}
            if d.owner == "sim":
                return {"code": "20017", "msg": "already added"}
            d.owner = "sim"
            return ok()
        if d is None or d.owner != "sim":
            return {"code": "20002", "msg": "device not exist"}
        if path == "/api/lapp/device/delete":
            d.owner = None
            return ok()
        if path == "/api/lapp/device/info":
            return ok({"deviceSerial": s, "deviceName": d.name, "model": "DVR-SIM",
                       "status": 1 if d.online else 0})
        if path == "/api/lapp/device/camera/list":
            return ok([{"channelNo": i, "channelName": "Camera %d" % i,
                        "status": 0 if (i in d.offline_channels or not d.online) else 1}
                       for i in range(1, d.channels + 1)])
        if path == "/api/lapp/alarm/device/list":
            lo, hi = int(f.get("startTime") or 0), int(f.get("endTime") or 0)
            return ok([{"alarmId": a["id"], "deviceSerial": s, "channelNo": a["channel"],
                        "alarmType": a["type"], "alarmName": "%s(%s)" % (d.name, s),
                        "alarmTime": int(a["at"] * 1000), "alarmPicUrl": a["pic"],
                        "isEncrypt": 0} for a in d.alarms if lo <= int(a["at"] * 1000) <= hi])
        if path == "/api/lapp/device/format/status":
            return ok([{"index": 1, "name": "HDD1",
                        "status": {"ok": 0, "error": 1, "unformatted": 2}.get(d.disk, 0)}])
        if path == "/api/lapp/v2/live/address/get":
            if not d.online:
                return {"code": "20007", "msg": "device offline"}
            kind = "pb" if int(f.get("type") or 1) == 2 else "live"
            return ok({"url": STREAM["ezviz"] % (s, "%s%s" % (kind, f.get("channelNo")))})
        return {"code": "10001", "msg": "unknown path %s" % path}

    # ---------------- Imou / DoLynk (same protocol family)
    def _imou(self, path, body, headers, vendor="imou"):
        devs = self.devs[vendor]
        method = path.rsplit("/", 1)[-1]
        if path.endswith("/v2/device.detail.page"):
            method = "v2/device.detail.page"
        if method == "oauthTokenV2":
            return self._imou_oauth_token(body, headers)
        p = body.get("params") or {}
        sysd = body.get("system") or {}
        from ..imou import sign, sign_v2
        if vendor == "imou" and sysd.get("appId") == "imak":       # OAuth project
            if sysd.get("sign") != sign_v2(sysd.get("time"), sysd.get("nonce"), "imsk"):
                return {"result": {"code": "SN1001", "msg": "sign error"}}
            return self._imou_oauth_api(method, p)
        want = {"imou": ("imid", "ims"), "dolynk": ("dlid", "dls")}[vendor]
        if sysd.get("appId") != want[0] or sysd.get("sign") != sign(
                sysd.get("time"), sysd.get("nonce"), want[1]):
            return {"result": {"code": "SN1001", "msg": "sign error"}}

        def ok(data=None):
            return {"result": {"code": "0", "msg": "ok", "data": data or {}}}

        def err(code, msg=""):
            return {"result": {"code": code, "msg": msg}}
        if method == "accessToken":
            return ok({"accessToken": "tk.sim", "expireTime": 259200})
        if p.get("token") != "tk.sim":
            return err("TK1002", "token expired")
        if method == "setMessageCallback":
            self.callbacks = getattr(self, "callbacks", []) + [(vendor, p.get("callbackFlag"))]
            return ok()
        did = str(p.get("deviceId") or "")
        d = devs.get(did)
        if method == "bindDevice":
            if d is None or d.code != p.get("code"):
                return err("DV1003", "safety code error")
            if d.owner and d.owner != "sim":
                return err("DV1001", "bound by others")
            d.owner = "sim"
            return ok()
        if method == "listDeviceDetailsByIds":
            rows = []
            for x in p.get("deviceList") or []:
                dd = devs.get(x.get("deviceId"))
                if dd and dd.owner == "sim":
                    rows.append({"deviceId": dd.serial, "deviceName": dd.name,
                                 "deviceModel": "NVR-SIM",
                                 "deviceStatus": "online" if dd.online else "offline",
                                 "channelList": [{"channelId": str(i), "channelName": "Cam %d" % (i + 1),
                                                  "channelStatus": "offline" if (
                                                      i in dd.offline_channels or not dd.online) else "online"}
                                                 for i in range(dd.channels)]})
            return ok({"count": len(rows), "deviceList": rows})
        if d is None or d.owner != "sim":
            return err("DV1007", "device not found")
        if method == "unBindDevice":
            d.owner = None
            return ok()
        if method == "deviceOnline":
            return ok({"onLine": "1" if d.online else "0"})
        if method == "getAlarmMessage":
            ch = str(p.get("channelId") or "0")
            return ok({"alarms": [{"alarmId": a["id"], "deviceId": did, "channelId": str(a["channel"]),
                                   "type": a["type"], "msgType": a["type"], "time": int(a["at"]),
                                   "picurlArray": [a["pic"]]}
                                  for a in d.alarms if str(a["channel"]) == ch]})
        if method == "deviceSdcardStatus":
            return ok({"status": {"ok": "normal", "error": "abnormal", "none": "empty"}.get(d.disk, "normal")})
        if method == "deviceStorage":
            return ok({"totalBytes": int(d.total_gb * 1e9),
                       "usedBytes": int((d.total_gb - d.free_gb) * 1e9)})
        if method == "bindDeviceLive":
            if not d.online:
                return err("LV1002", "offline")
            host = STREAM[vendor] % (did, "ch%s" % p.get("channelId"))
            return ok({"streams": [{"streamId": p.get("streamId"), "hls": host,
                                    "liveToken": "lt-%s" % did}]})
        if method == "queryLocalRecords":
            return ok({"records": [{"beginTime": p.get("beginTime"), "endTime": p.get("endTime")}]})
        return err("OP1000", "unknown method %s" % method)

    def _imou_oauth_token(self, f, headers):
        import base64
        if headers.get("Authorization") != "Basic " + base64.b64encode(b"imak:imsk").decode():
            return {"error": "invalid_client"}
        if f.get("grant_type") == "authorization_code":
            tok = self.oauth_codes.pop(f.get("code"), None)
            if not tok:
                return {"error": "invalid_grant"}
            return {"access_token": tok, "token_type": "bearer", "expires_in": 7200,
                    "refresh_token": "rt-sim", "scope": "all"}
        if f.get("grant_type") == "refresh_token":
            tok = self.oauth_refresh.get(f.get("refresh_token"))
            if not tok:
                return {"error": "invalid_grant"}
            return {"access_token": tok, "token_type": "bearer", "expires_in": 7200,
                    "refresh_token": "rt-sim", "scope": "all"}
        return {"error": "unsupported_grant_type"}

    def _imou_oauth_api(self, method, p):
        devs = self.devs["imou"]

        def ok(data=None):
            return {"result": {"code": "0", "msg": "ok", "data": data or {}}}
        if p.get("token") not in ("Ot_sim", "Ot_sim2"):
            return {"result": {"code": "TK1002", "msg": "token expired"}}
        mine = {k: d for k, d in devs.items() if d.oauth_user}
        if method == "v2/device.detail.page":
            return ok({"count": len(mine), "deviceList": [
                {"deviceId": d.serial, "deviceName": d.name, "productId": "IPC-SIM",
                 "deviceStatus": "online" if d.online else "offline",
                 "channelList": [{"channelId": str(i), "channelName": "Cam %d" % (i + 1),
                                  "channelStatus": "online"} for i in range(d.channels)]}
                for d in mine.values()]})
        d = mine.get(str(p.get("deviceId") or ""))
        if d is None:
            return {"result": {"code": "OP1009", "msg": "permission denied"}}
        if method == "bindDeviceLive":
            return {"result": {"code": "OP1009", "msg": "not for OAuth (simulated)"}}
        if method == "getStreamUrl":
            return ok({"url": "rtsp://live.lechange.com/live/%s/%s" % (d.serial, p.get("channelId"))})
        if method == "getAlarmMessage":
            ch = str(p.get("channelId") or "0")
            return ok({"alarms": [{"alarmId": a["id"], "deviceId": d.serial, "channelId": str(a["channel"]),
                                   "type": a["type"], "msgType": a["type"], "time": int(a["at"]),
                                   "picurlArray": [a["pic"]]} for a in d.alarms if str(a["channel"]) == ch]})
        if method == "setMessageCallback":
            return ok()
        if method == "deviceSdcardStatus":
            return ok({"status": {"ok": "normal", "error": "abnormal"}.get(d.disk, "normal")})
        if method in ("deviceStorage", "deviceOnline"):
            return ok({"totalBytes": 64e9, "usedBytes": 10e9, "onLine": "1"})
        return {"result": {"code": "OP1000", "msg": "unknown method %s" % method}}

    def _dolynk(self, path, body, headers):
        return self._imou(path, body, headers, vendor="dolynk")

    # ---------------- Hik-Connect (hccgw)
    def _hikconnect(self, path, f, headers):
        devs = self.devs["hikconnect"]

        def ok(data=None):
            return {"errorCode": "0", "message": "success", "data": data or {}}
        if path == "/api/hccgw/platform/v1/token/get":
            if f.get("appKey") != "hck" or f.get("secretKey") != "hcs":
                return {"errorCode": "OPEN000100", "message": "app key invalid"}
            return ok({"accessToken": "hc.sim", "expireTime": int(self.now() + 7 * 86400),
                       "areaDomain": "https://isgp.hik-connect.com"})
        if headers.get("Token") != "hc.sim":
            return {"errorCode": "OPEN000001", "message": "token invalid"}
        if path == "/api/hccgw/resource/v1/devices/add":
            x = (f.get("deviceList") or [{}])[0]
            d = devs.get(x.get("deviceSerial"))
            if d is None or d.code != x.get("verifyCode"):
                return {"errorCode": "EVZ20010", "message": "verify code error"}
            if d.owner and d.owner != "sim":
                return {"errorCode": "EVZ20013", "message": "added by others"}
            d.owner = "sim"
            return ok()
        flt = (f.get("filter") or {}).get("deviceSerial") or f.get("deviceSerial")
        d = devs.get(flt)
        mine = d is not None and d.owner == "sim"
        if path == "/api/hccgw/resource/v1/devices/delete":
            if mine:
                d.owner = None
            return ok()
        if path == "/api/hccgw/resource/v1/devices/get":
            return ok({"totalCount": 1 if mine else 0, "device": [
                {"serialNo": d.serial, "name": d.name, "type": "NVR-SIM",
                 "onlineStatus": 1 if d.online else 0}] if mine else []})
        if path == "/api/hccgw/resource/v1/areas/cameras/get":
            return ok({"camera": [{"id": "cam-%s-%d" % (d.serial, i), "name": "Camera %d" % i,
                                   "channelNo": i, "online": 0 if (i in d.offline_channels or not d.online) else 1,
                                   "device": {"serialNo": d.serial}}
                                  for i in range(1, d.channels + 1)] if mine else []})
        if path == "/api/hccgw/video/v1/live/address/get":
            rid = str(f.get("resourceId") or "")
            serial = rid.split("-")[1] if rid.count("-") >= 2 else ""
            dd = devs.get(serial)
            if dd is None or dd.owner != "sim" or not dd.online:
                return {"errorCode": "EVZ20007", "message": "offline"}
            kind = "pb" if int(f.get("type") or 1) == 2 else "live"
            return ok({"url": STREAM["hikconnect"] % (serial, kind + rid.split("-")[-1])})
        if path == "/api/hccgw/alarm/v1/mq/subscribe":
            return ok()
        if path == "/api/hccgw/alarm/v1/mq/messages":
            q = [m for m in self.hik_queue if devs.get(m["serial"]) and devs[m["serial"]].owner == "sim"]
            self.hik_queue = []
            return ok({"alarmMsg": [{"guid": m["id"], "eventType": m["type"],
                                     "alarmTime": int(m["at"] * 1000), "deviceSerial": m["serial"],
                                     "channelNo": m["channel"], "pictureUrl": m["pic"],
                                     "ruleTarget": "human" if m["type"] == "fielddetection" else (
                                         "vehicle" if m["type"] == "linedetection" else "")}
                                    for m in q]})
        if path == "/api/hccgw/resource/v1/devices/hdd/get":
            if not mine:
                return {"errorCode": "EVZ20002", "message": "no device"}
            return ok({"hddList": [{"id": 1, "status": {"ok": "normal"}.get(d.disk, d.disk),
                                    "capacity": d.total_gb * 1024, "freeSpace": d.free_gb * 1024}]})
        return {"errorCode": "OPEN000404", "message": "unknown path %s" % path}
