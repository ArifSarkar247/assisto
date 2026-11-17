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
         "hikconnect": "https://ieu.hik-connect.com", "dolynk": "https://open-api-sg.dolynkcloud.com"}
PIC = {"ezviz": "https://pic.ezvizlife.com/a/%s.jpg", "imou": "https://pic.easy4ip.com/a/%s.jpg",
       "hikconnect": "https://pic.hik-connect.com/a/%s.jpg",
       "dolynk": "https://cloudreadproxy-online-sg.imoulife.com/%s_img/Alarm/0/a.jpg"}
STREAM = {"ezviz": "https://hls.ezvizlife.com/live/%s/%s.m3u8",
          "imou": "https://hls.easy4ip.com/live/%s/%s.m3u8",
          "hikconnect": "https://hls.hik-connect.com/live/%s/%s.m3u8",
          "dolynk": "https://cmgw-online-sg.lechange.com/LCO/%s/%s/0/x.m3u8?source=open"}
ALARM_TYPES = {"ezviz": {"human": "humanDetection", "motion": 10000, "cover": 10011,
                         "vehicle": "vehicleDetection"},
               "imou": {"human": "human", "motion": "videoMotion", "cover": "videoBlind",
                        "vehicle": "vehicle"},
               "hikconnect": {"human": "fielddetection", "motion": "vmd",
                              "cover": "shelteralarm", "vehicle": "linedetection"},
               "dolynk": {"human": "smdHuman", "motion": "videoMotion", "cover": "videoBlind",
                          "vehicle": "smdVehicle", "face": "rtFaceDetect"}}


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
        self.arc_account = ""        # DoLynk ARC: the DMSS account that shared it
        self.arc_active = None


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
                "dolynk": {"access_key": "dlak", "secret_key": "dlsk", "product_id": "212808822",
                           "api_base": "https://open-api-sg.dolynkcloud.com"},
                "dolynk_arc": {"access_key": "arcak", "secret_key": "arcsk", "product_id": "900000001",
                               "api_base": "https://open-api-sg.dolynkcloud.com",
                               "arc_email": "arc@assisto.test", "arc_password": "Arc#Pass1",
                               "arc_on": "on"}}[vendor]
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

    # ---------------- Dahua DoLynk (Doc Center shapes: Open IoT + Open ARC)
    DL_KEYS = {"dlak": ("dlsk", "212808822"), "arcak": ("arcsk", "900000001")}

    @staticmethod
    def _dl_hmac(key, text):
        import hashlib
        import hmac
        return hmac.new(key.encode(), text.encode(), hashlib.sha512).hexdigest()

    @staticmethod
    def _dl_decrypt(dev_code, sk):
        """The SERVER side of "Adding Devices" method 2 (AES-256-CBC/PKCS7,
        key = UPPER(MD5(UPPER(sk))), iv "86E2DB6D77B5E9CD") — written here
        independently of the adapter."""
        import base64
        import hashlib
        from cryptography.hazmat.primitives import padding
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        try:
            key = hashlib.md5(sk.upper().encode()).hexdigest().upper().encode()
            dec = Cipher(algorithms.AES(key), modes.CBC(b"86E2DB6D77B5E9CD")).decryptor()
            raw = dec.update(base64.b64decode(dev_code)) + dec.finalize()
            u = padding.PKCS7(128).unpadder()
            return (u.update(raw) + u.finalize()).decode()
        except Exception:
            return None

    def dl_msg(self, serial, a, ak="dlak", sk="dlsk"):
        """One alarm as Open IoT pushes it (Event message format), signed."""
        mid = 1685822754353311744 + int(str(a["id"]).rsplit("-", 1)[-1])
        m = {"accessKey": ak, "productId": 212808822, "category": "NVR",
             "msgType": a["type"], "deviceId": serial, "channelId": int(a["channel"]),
             "utcTime": int(a["at"] * 1000), "localTime": int(a["at"] * 1000), "id": mid,
             "picUrls": [a["pic"]]}
        m["sign"] = self._dl_hmac(sk, str(mid))
        return m

    def _dolynk(self, path, f, headers):
        devs = self.devs["dolynk"]
        self.dl_calls = getattr(self, "dl_calls", []) + [path]

        def ok(data=None):
            return {"code": "200", "success": True, "data": data, "msg": "Operation is successful."}

        def err(code, msg=""):
            return {"code": code, "success": False, "data": None, "msg": msg}
        for h in ("Version", "AccessKey", "Timestamp", "Nonce", "Sign", "X-TraceId-Header",
                  "ProductId"):
            if not headers.get(h):
                return err("PRM006", "%s is required" % h)
        ak = headers["AccessKey"]
        if ak not in self.DL_KEYS:
            return err("PRM032", "AccessKey is not correct or not exist")
        sk, prod = self.DL_KEYS[ak]
        if str(headers["ProductId"]) != prod:
            return err("BIZ010", "AccessKey or productId error")
        ts, nonce = headers["Timestamp"], headers["Nonce"]
        if len(ts) != 13 or abs(int(ts) / 1000.0 - self.now()) > 300:
            return err("AUT003", "Request exceeds validity period")
        if path == "/open-api/api-base/auth/getAppAccessToken":
            if headers["Sign"] != self._dl_hmac(sk, ak + ts + nonce).upper():
                return err("PRM0016", "Sign error")
            return ok({"appAccessToken": "eyJ.sim." + ak, "validitySeconds": 604800})
        tok = headers.get("AppAccessToken") or ""
        if tok != "eyJ.sim." + ak:
            return err("AUT001", "Authentication failure")
        ut = headers.get("UserAccessToken") or ""
        if headers.get("Sign-Type") != "simple" or headers["Sign"] != self._dl_hmac(
                sk, ak + tok + ut + ts + nonce).upper():
            return err("PRM0016", "Sign error")
        if ak == "arcak":
            return self._dolynk_arc(path, f, ut, ok, err)
        s = str(f.get("deviceId") or "")
        d = devs.get(s)
        cat = lambda dd: "NVR" if dd.channels > 1 else "IPC"   # noqa: E731
        if path == "/open-api/api-iot/device/addDevice":
            if d is None:
                return err("IDV001", "Device not exist")
            if f.get("categoryCode") != cat(d):
                return err("IDV0022", "The device model is not supported or the device category is incorrect")
            if self._dl_decrypt(f.get("devCode") or "", sk) != d.code:
                return err("IDV006", "The device password is incorrect.")
            if d.owner and d.owner != "sim":
                return err("IDV004", "The device has been bound to another account")
            if d.owner == "sim":
                return err("IDV005", "The device is bound to the current account.")
            d.owner = "sim"
            return ok(None)
        if path == "/open-api/api-iot/device/listDeviceDetailsByIds":
            rows = []
            for x in f.get("deviceList") or []:
                dd = devs.get(x.get("deviceId"))
                if dd and dd.owner == "sim":
                    rows.append({"deviceId": dd.serial, "deviceName": dd.name, "accessType": "PaaS",
                                 "deviceStatus": "online" if dd.online else "offline",
                                 "deviceModel": "DHI-NVR-SIM", "catalog": cat(dd), "source": "bind",
                                 "channels": [{"channelId": str(i), "channelName": "Cam %d" % (i + 1),
                                               "csStatus": "notExist", "channelStatus": "offline" if (
                                                   i in dd.offline_channels or not dd.online) else "online"}
                                              for i in range(dd.channels)]})
            return ok({"count": len(rows), "deviceList": rows})
        if path == "/open-api/api-message/getAllCallbackConfigId":
            cbs = getattr(self, "dl_cbs", {})
            if not cbs:      # the real cloud answers an EMPTY list as an error (live 17 Nov)
                return err("BIZ054", "No new configuration callback ID is added to the product.")
            return ok({"currentPage": 1, "totalPage": 1, "pageSize": 100, "totalRows": len(cbs),
                       "pageData": [{"callbackConfigId": k, "callbackUrl": v} for k, v in cbs.items()]})
        if path == "/open-api/api-message/addCallbackConfig":
            self.dl_cbs = getattr(self, "dl_cbs", {})
            cid = str(39875492375432451 + len(self.dl_cbs))
            self.dl_cbs[cid] = f.get("callbackUrl")
            return ok(cid)
        if path == "/open-api/api-message/getMessageTypePage":
            return ok({"totalPage": 1, "pageSize": 50, "pageData": [
                {"code": c, "memo": c, "type": c} for c in (
                    "videoMotion", "smdHuman", "smdVehicle", "videoBlind", "CrossLineDetection",
                    "CrossRegionDetection", "online", "offline", "storageFailure", "rtFaceDetect")]})
        if path == "/open-api/api-message/messageSubscribeByDeviceIds":
            self.dl_subs = getattr(self, "dl_subs", []) + [dict(f)]
            return ok(None)
        if path == "/open-api/api-message/getMessage":
            lo, hi = int(f.get("beginTime") or 0), int(f.get("endTime") or 0)
            rows = []
            for x in f.get("deviceList") or []:
                dd = devs.get(x.get("deviceId"))
                if not dd or dd.owner != "sim":
                    continue
                chs = [str(c) for c in x.get("channelIdList") or []]
                for a in dd.alarms:
                    if lo <= int(a["at"] * 1000) <= hi and (not chs or str(a["channel"]) in chs):
                        m = self.dl_msg(dd.serial, a)
                        row = {k: m[k] for k in ("accessKey", "productId", "category", "msgType",
                                                 "deviceId", "channelId", "picUrls")}
                        row.update({"time": m["utcTime"], "thumbUrl": None, "id": str(m["id"])})
                        rows.append(row)
            return ok({"pageData": rows[:50], "currentPage": 1, "totalPage": 1, "pageSize": 50,
                       "totalRows": len(rows)})
        if path == "/open-api/api-decrypto/image/decrypto":
            u = str(f.get("imageUrl") or "")
            return ok({"url": u.replace(".dav", ".jpg")})
        if path == "/open-api/api-biz/cloudDump/dumpTimeTaskPageList":
            tid = (f.get("taskIds") or [""])[0]
            t = getattr(self, "dl_dumps", {}).get(tid)
            if not t:
                return ok({"pageData": [], "currentPage": 1, "totalPage": 0, "pageSize": 10, "totalRows": 0})
            t["polls"] += 1
            done = t["polls"] >= 2
            return ok({"pageData": [{"taskId": tid, "deviceId": t["serial"], "channelId": "0",
                                     "status": 2 if done else 1, "errMsg": None,
                                     "files": [{"fileId": 1875093833943998465, "seq": 0,
                                                "fileName": "%s_0_1_20250103034200.mp4" % t["serial"],
                                                "fileSize": 127394880}] if done else []}],
                       "currentPage": 1, "totalPage": 1, "pageSize": 10, "totalRows": 1})
        if path == "/open-api/api-iot/cloudDump/getRecordDumpUrl":
            return ok([{"fileId": int(x), "fileName": "clip.mp4", "fileSize": 1,
                        "fileUrl": "https://paas-sim-obs.obs.ap-southeast-1.myhuaweicloud.com/%s.mp4?x=1" % x}
                       for x in f.get("fileIds") or []])
        if path == "/open-api/api-iot/device/delDeviceHlsLive":
            live = getattr(self, "dl_lives", {})
            for k, v in list(live.items()):
                if v == f.get("liveToken"):
                    live.pop(k)
            return ok(None)
        if d is None or d.owner != "sim":
            return err("BIZ004", "No permission to operate the device")
        if path == "/open-api/api-iot/device/verifyDevCode":
            if self._dl_decrypt(f.get("devCode") or "", sk) != d.code:
                return err("IDV006", "The device password is incorrect.")
            return ok(None)
        if path == "/open-api/api-iot/device/deleteDevice":
            d.owner = None
            return ok(None)
        if path == "/open-api/api-iot/device/deviceOnline":
            return ok({"deviceId": s, "onLine": "1" if d.online else "0",
                       "status": "online" if d.online else "offline",
                       "channels": [{"channelId": str(i), "onLine": "0" if (
                           i in d.offline_channels or not d.online) else "1"} for i in range(d.channels)]})
        if path in ("/open-api/api-iot/device/createDeviceHlsLive", "/open-api/api-iot/device/getHlsLiveList"):
            ch = str(f.get("channelId") or "0")
            self.dl_lives = getattr(self, "dl_lives", {})
            key = (s, ch)

            def row():
                url = STREAM["dolynk"] % (s, ch)
                return {"deviceId": s, "channelId": ch, "liveToken": self.dl_lives[key], "liveStatus": 1,
                        "streamList": [{"streamType": t, "hls": u, "coverUrl": u.replace(".m3u8", ".jpg")}
                                       for t in (0, 1) for u in (url, url.replace("https://", "http://"))]}
            if path.endswith("getHlsLiveList"):
                return ok([row()] if key in self.dl_lives else [])
            if not d.online:
                return err("IDV002", "Device is offline.")
            if key in self.dl_lives:
                return err("IDV0055", "The live video already exists")
            self.dl_lives[key] = "%s%s-live-token" % (s, ch)
            return ok(row())
        if path == "/open-api/api-iot/device/queryLocalRecords":
            from datetime import datetime, timedelta
            b = datetime.strptime(f["beginTime"], "%Y-%m-%d %H:%M:%S")
            b = b.replace(second=0, minute=b.minute - b.minute % 2)
            recs = []
            for k in range(2):
                x = b + timedelta(minutes=2 * k)
                y = x + timedelta(minutes=2)
                recs.append({"recordFileName": "/mnt/sd/x/%s.dav" % x.strftime("%H.%M.%S"),
                             "fileLength": 5354930, "channelId": str(f.get("channelId")),
                             "beginTime": x.strftime("%Y-%m-%d %H:%M:%S"),
                             "endTime": y.strftime("%Y-%m-%d %H:%M:%S"), "streamType": "main"})
            self.dl_records = {(r["beginTime"], r["endTime"]) for r in recs}
            return ok({"records": recs})
        if path == "/open-api/api-iot/device/createDeviceRecordHls":
            if (f.get("beginTime"), f.get("endTime")) not in getattr(self, "dl_records", set()):
                return err("IDV0127", "Record video does not exist")
            return ok({"url": "https://mes502-online-sg.lechange.com:7080/localvod/%s.m3u8?proto=https" % s})
        if path == "/open-api/api-iot/device/setDeviceSnapEnhanced":
            return ok({"url": "https://cloudreadproxy-online-sg.imoulife.com/%s_snap.jpg" % s})
        if path == "/open-api/api-biz/cloudDump/createTaskByTime":
            self.dl_dumps = getattr(self, "dl_dumps", {})
            tid = str(1875091690247806977 + len(self.dl_dumps))
            self.dl_dumps[tid] = {"serial": s, "polls": 0}
            return ok({"taskId": tid})
        if path == "/open-api/api-aiot/device/getSDCardStatus":
            return ok({"status": {"ok": "normal", "error": "abnormal", "none": "Empty"}.get(d.disk, "normal")})
        if path == "/open-api/api-aiot/device/getSDCardStorage":
            return ok({"totalBytes": int(d.total_gb * 1e9), "usedBytes": int((d.total_gb - d.free_gb) * 1e9)})
        if path == "/open-api/api-biz/cloudStorage/getDeviceCloud":
            return ok({"deviceCloudId": "1", "strategyId": 7, "name": "7-day event", "deviceId": s,
                       "channelId": "0", "storageType": "1", "recordSaveDays": 7,
                       "beginTime": "2026-11-01 00:00:00", "endTime": "2026-12-01 00:00:00",
                       "cloudStatus": 1, "useStatus": 1})
        if path == "/open-api/api-aiot/device/queryCloudRecords":
            return ok({"records": [{"recordId": "2181124612393111111", "deviceId": s, "channelId": "0",
                                    "beginTime": f.get("beginTime"), "endTime": f.get("endTime"),
                                    "size": "4336368", "encryptMode": 0, "recordPath": "",
                                    "thumbUrl": "https://lechange-online-record.tos-s3-cn-shanghai.volces.com/t.dav",
                                    "recordRegionId": "x"}]})
        return err("UNK001", "unknown path %s" % path)

    def _dolynk_arc(self, path, f, ut, ok, err):
        devs = self.devs["dolynk"]
        if path == "/open-api/api-converter/user/getSalt":
            self.arc_random = "sim-random-%d" % len(self.calls)
            return ok({"salt": "sim-salt", "random": self.arc_random})
        if path == "/open-api/api-converter/user/login":
            want = self._dl_hmac(getattr(self, "arc_random", ""), self._dl_hmac("sim-salt", "Arc#Pass1"))
            if f.get("accountEmail") != "arc@assisto.test" or f.get("password") != want:
                return err("BIZ029", "Invalid password")
            return ok({"userAccessToken": "eyJ.arcuser", "validitySeconds": 1296000,
                       "userId": "1668099767630202641", "username": "arc@assisto.test"})
        if ut != "eyJ.arcuser":
            return err("PRM0022", "UserAccessToken is required")
        shared = {k: d for k, d in devs.items() if d.arc_account}
        if path == "/open-api/api-converter/device/getDeviceList":
            want = set(f.get("deviceIds") or shared)
            return ok([{"bindTime": "1724836900", "name": d.name, "deviceId": d.serial,
                        "status": 1 if d.online else 0, "activationStatus": 1 if d.arc_active else 0,
                        "account": d.arc_account[:2] + "***" + d.arc_account[d.arc_account.index("@"):]}
                       for k, d in shared.items() if k in want])
        if path == "/open-api/api-converter/device/setActivationStatus":
            for x in f.get("deviceIds") or []:
                if x in shared:
                    shared[x].arc_active = bool(f.get("activationStatus"))
            return ok({})
        if path == "/open-api/api-converter/device/unbindDevices":
            for x in f.get("deviceIds") or []:
                if x in shared:
                    shared[x].arc_account = ""
            return ok(None)
        if path == "/open-api/api-converter/message/setCallbackConfig":
            self.arc_cb = f.get("callbackUrl")
            return ok(None)
        if path == "/open-api/api-message/notice/messageAck":
            self.arc_acks = getattr(self, "arc_acks", []) + [f.get("id")]
            return ok(None)
        if path == "/open-api/api-message/converter/getMessage":
            lo, hi = int(f.get("beginTime") or 0), int(f.get("endTime") or 0)
            rows = []
            for d in shared.values():
                for a in d.alarms:
                    if lo <= int(a["at"] * 1000) <= hi:
                        rows.append({"id": str(1910316040315727872 + len(rows)), "msgType": a["type"],
                                     "deviceId": d.serial, "channelId": a["channel"],
                                     "utcTime": int(a["at"] * 1000), "localTime": int(a["at"] * 1000),
                                     "companyId": "1668099767630202276", "accessKey": "arcak",
                                     "picUrl": a["pic"]})
            return ok({"pageData": rows[:50], "currentPage": 1, "totalPage": 1, "pageSize": 50,
                       "totalRows": len(rows)})
        if path == "/open-api/api-converter/device/listDeviceDetailsByIds":
            rows = [{"deviceId": d.serial, "deviceName": d.name, "deviceStatus": "online",
                     "catalog": "IPC", "channels": [{"channelId": "0", "channelName": d.name,
                                                      "channelStatus": "online"}]}
                    for x in f.get("deviceList") or [] for d in [shared.get(x.get("deviceId"))] if d]
            return ok({"count": len(rows), "deviceList": rows})
        if path == "/open-api/api-converter/device/setDeviceSnapEnhanced":
            return ok({"url": "https://cloudreadproxy-online-sg.imoulife.com/%s_snap.jpg" % f.get("deviceId")})
        return err("UNK001", "unknown path %s" % path)

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
