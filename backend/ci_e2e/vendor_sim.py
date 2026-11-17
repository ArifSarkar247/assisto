"""camflows — the FAKE VENDOR CLOUDS for the CCTV brand-cloud E2E
(.github/workflows/camflows.yml, settings_e2eproof + E2E_VENDOR_SIM=1).

Everything from the app to the vendor seam is the real code: the app's
add-camera screens, the server's cctv_connect views, the adapters, the older
Imou / EZVIZ clients, the Imou push callback, the EZVIZ poll job, the
brand-cloud tick, the alert path (snapshot, push), the daily numbers. Only
what would leave the runner for a vendor is replaced:

  * vendor Open APIs (EZVIZ, Imou, Imou OAuth, Dahua DoLynk)
      -> core.logic.cctv_connect.mocks.VendorSims (one instance per server
         process; the same simulator the unit tests use). The three transport
         seams: cctv_connect.base.default_http, logic.ezviz._default_http,
         logic.imou._default_http.
  * vendor picture CDN (https://pic.<vendor>/...)
      -> a generated JPEG ("CI FAKE" written on it) for requests.get on those
         hosts only; every other URL goes to the real requests.get.
  * vendor live HLS (https://hls.<vendor>/...)
      -> a REAL HLS stream (ffmpeg test pattern, E2E_HLS_DIR) served by this
         server under /api/v1/ci-e2e/hls/<vendor>/<serial>/; the phone plays
         it through the normal player. The vendor-domain allow-lists accept
         exactly that CI prefix in addition to the vendor domains.
  * the Imou "User Authorization H5 Page" -> /api/v1/ci-e2e/imou/h5 (a fake
    consent page; "Allow" sends the browser to OUR real redirect URI).

Honest limits: the vendors' real servers are not reached (no keys in CI).
Imou's docs do not say whether HLS live works with an end user's OAuth token;
this simulator answers HLS for it (CAMFLOWS_OAUTH_HLS) so the player path is
proven — the real answer is checked on the owner's first real camera.
"""
import io
import json
import os
import secrets
import threading
from urllib.parse import urlparse

from django.conf import settings

_LOCK = threading.RLock()
SIM = None
HITS = {"hls": [], "pic": [], "hls_bytes": {}}  # what the phone / server fetched from the fakes
# flag-cctv-e2e: + the DoLynk alarm-picture CDN (mocks.PIC["dolynk"])
PIC_HOSTS = ("pic.ezvizlife.com", "pic.easy4ip.com", "pic.dolynkcloud.com", "pic.hik-connect.com",
             "cloudreadproxy-online-sg.imoulife.com")


def hls_prefix():
    return "%s/api/v1/ci-e2e/hls/" % str(getattr(settings, "ASSISTO_BASE_URL", "")).rstrip("/")


def _sim_class():
    from core.logic.cctv_connect import mocks as M

    class CamflowsSims(M.VendorSims):
        oauth_hls = os.environ.get("CAMFLOWS_OAUTH_HLS", "1") == "1"

        def _imou_oauth_api(self, method, p):
            # see the module doc: HLS for an OAuth user's device (unconfirmed
            # in Imou's docs) — the adapter tries HLS first, RTSP after
            if method == "bindDeviceLive" and self.oauth_hls and p.get("token") in ("Ot_sim", "Ot_sim2"):
                d = self.devs["imou"].get(str(p.get("deviceId") or ""))
                if d is not None and d.oauth_user:
                    url = M.STREAM["imou"] % (d.serial, "ch%s" % p.get("channelId"))
                    return {"result": {"code": "0", "msg": "ok", "data": {"streams": [
                        {"streamId": p.get("streamId"), "hls": url, "liveToken": "lt-" + d.serial}]}}}
            return super()._imou_oauth_api(method, p)

    return CamflowsSims


def sim():
    global SIM
    with _LOCK:
        if SIM is None:
            SIM = _sim_class()()
        return SIM


def sim_http(url, body, timeout, headers=None):
    with _LOCK:
        return sim().http(url, body, timeout, headers or {})


# ------------------------------------------------------------------ pictures
def fake_jpeg(text):
    from PIL import Image, ImageDraw
    im = Image.new("RGB", (640, 360), (40, 52, 70))
    d = ImageDraw.Draw(im)
    d.rectangle((0, 300, 640, 360), fill=(90, 90, 90))
    d.ellipse((300, 110, 340, 150), fill=(230, 190, 160))       # a simple "person"
    d.rectangle((295, 150, 345, 260), fill=(30, 110, 200))
    d.text((12, 12), "CI FAKE " + text[:40], fill=(255, 255, 0))
    out = io.BytesIO()
    im.save(out, "JPEG", quality=80)
    return out.getvalue()


class _Raw(io.BytesIO):
    def read(self, n=-1, decode_content=True):  # noqa: ARG002 - urllib3 signature
        return super().read(n)


def _fake_pic_response(url):
    import requests
    r = requests.Response()
    r.status_code = 200
    r.headers["Content-Type"] = "image/jpeg"
    r.url = url
    r.raw = _Raw(fake_jpeg(urlparse(url).path.rsplit("/", 1)[-1]))
    return r


# ------------------------------------------------------------------ install
def install():
    """Swap the vendor seams (called from ci_e2e.fakes.install when
    E2E_VENDOR_SIM=1)."""
    import requests
    from core.logic import ezviz as EZ
    from core.logic import imou as IM
    from core.logic.cctv_connect import base as B
    from core.logic.cctv_connect import mocks as M

    pre = hls_prefix()
    for v in list(M.STREAM):
        M.STREAM[v] = pre + v + "/%s/%s.m3u8"

    B.default_http = sim_http
    EZ._default_http = lambda url, form, timeout: sim_http(url, form, timeout, {})
    IM._default_http = lambda url, body, timeout: sim_http(url, body, timeout, {})

    def _ci_ok(url):
        return str(url or "").startswith(pre)

    orig_host_allowed = B.host_allowed
    B.host_allowed = lambda url, suffixes: _ci_ok(url) or orig_host_allowed(url, suffixes)
    orig_domain_ok = EZ._domain_ok
    EZ._domain_ok = lambda url: _ci_ok(url) or orig_domain_ok(url)

    orig_get = requests.get

    def _get(url, *a, **kw):
        host = (urlparse(str(url)).hostname or "").lower()
        if host in PIC_HOSTS:
            HITS["pic"].append(str(url)[-80:])
            return _fake_pic_response(str(url))
        return orig_get(url, *a, **kw)
    requests.get = _get


# ------------------------------------------------------------------ helpers
def callback_url_local(url):
    """The vendor pushes to our public URL; on the runner that is :8700."""
    u = urlparse(url)
    return "http://127.0.0.1:8700" + u.path


def push_alarm(vendor, serial, channel, kind, deliver):
    """A camera alarm in the vendor cloud. deliver="callback": the vendor
    also PUSHES it to our callback (Imou message service), over real HTTP."""
    import requests
    with _LOCK:
        s = sim()
        aid = s.push_alarm(vendor, serial, channel, kind)
        row = dict(s.devs[vendor][serial].alarms[-1])
    out = {"alarm_id": aid, "at": row["at"], "pic": row["pic"]}
    if deliver == "callback" and vendor == "imou":
        from core import integrations as I
        from core.watchman_views import imou_callback_url
        msg = {"msgType": row["type"], "did": serial, "cid": str(channel), "alarmId": aid,
               "time": int(row["at"]), "picurlArray": [row["pic"]], "labelType": row["type"]}
        url = callback_url_local(imou_callback_url((I.get("imou") or {}).get("app_id")))
        r = requests.post(url, data=json.dumps(msg), timeout=20,
                          headers={"Content-Type": "application/json"})
        out["callback"] = {"status": r.status_code, "body": r.text[:400]}
    elif deliver == "callback" and vendor == "dolynk":
        out.update(dolynk_push(serial, channel, aid, row))
    return out


# flag-cctv-e2e: DoLynk Open IoT "Message Subscription" — the vendor cloud
# PUSHES a SIGNED message (sign = HMAC-SHA512(id, secretKey)) to our PUBLIC
# callback link (the same link the owner registers), over real HTTP.
_DL_SEQ = [1880000000000000000]


def dolynk_message(serial, channel, aid, row, msg_id=None):
    import hashlib
    import hmac
    from core import integrations as I
    cfg = I.get("dolynk") or {}
    with _LOCK:
        if msg_id is None:
            _DL_SEQ[0] += 1
            msg_id = str(_DL_SEQ[0])
    sk = str(cfg.get("secret_key") or "")
    return {"id": msg_id, "msgType": row["type"], "deviceId": serial, "channelId": str(channel),
            "utcTime": int(float(row["at"]) * 1000), "picUrls": [row["pic"]],
            "accessKey": str(cfg.get("access_key") or ""), "alarmId": aid,
            "sign": hmac.new(sk.encode(), str(msg_id).encode(), hashlib.sha512).hexdigest().upper()}


def dolynk_post(msg):
    """POST one message to our public callback (rewritten to the runner's
    :8700). -> {status, body, sent_at, answered_at} (epoch seconds)."""
    import time
    import requests
    from core import integrations as I
    from core.cctv_connect_views import dolynk_callback_url
    url = callback_url_local(dolynk_callback_url((I.get("dolynk") or {}).get("access_key")))
    t0 = time.time()
    r = requests.post(url, data=json.dumps([msg]), timeout=20,
                      headers={"Content-Type": "application/json"})
    return {"status": r.status_code, "body": r.text[:400], "sent_at": t0, "answered_at": time.time()}


def dolynk_push(serial, channel, aid, row, msg_id=None):
    msg = dolynk_message(serial, channel, aid, row, msg_id)
    out = {"msg_id": msg["id"], "callback": dolynk_post(msg)}
    out["webhook_at"] = out["callback"]["sent_at"]
    return out


def dolynk_repush(serial, msg_id):
    """The vendor pushes the SAME message again (it thinks we missed it)."""
    with _LOCK:
        d = sim().devs["dolynk"][serial]
        row = dict(d.alarms[-1])
    return dolynk_push(serial, row["channel"], row["id"], row, msg_id=msg_id)


def state(vendor, serial):
    with _LOCK:
        d = sim().devs.get(vendor, {}).get(serial)
        if d is None:
            return {"exists": False}
        return {"exists": True, "owner": d.owner, "oauth_user": d.oauth_user,
                "alarms": len(d.alarms), "online": d.online,
                "hls_hits": [h for h in HITS["hls"] if "/%s/" % serial in h][-20:],
                # flag-cctv-e2e: bytes the phone downloaded from the live stream
                "hls_bytes": int(HITS["hls_bytes"].get(serial.upper(), 0)),
                "pic_hits": len(HITS["pic"])}


def add_device(vendor, serial, code, channels=1, name=None, oauth_user=False):
    with _LOCK:
        d = sim().add_device(vendor, serial, code, channels=channels, name=name)
        d.oauth_user = bool(oauth_user)
        return {"serial": d.serial, "channels": d.channels, "name": d.name}


def new_oauth_code():
    code = "cf-" + secrets.token_urlsafe(12)
    with _LOCK:
        sim().oauth_codes[code] = "Ot_sim"
    return code
