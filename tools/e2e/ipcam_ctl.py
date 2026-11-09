"""cctvbox — control side of the Guard Box emulator E2E (ipcam-e2e.yml).

    python ipcam_ctl.py seed                # owner + home site + flags, token
    python ipcam_ctl.py serve               # :18799 for the emulator test
    python ipcam_ctl.py check               # DB proof -> $E2E_DIR/ipcam_proof.json

`serve` answers the app test running on the emulator (it reaches the runner
as 10.0.2.2):
    GET /mint         -> {code, rtsp}: a fresh phone-camera pairing code from
                         the real owner API + the RTSP URL of the mediamtx
                         camera (as the emulator sees it);
    GET /live_status  -> the owner-side live probe's result so far.
Once the first Guard Box alert is in the DB, `serve` starts the LIVE probe:
the owner opens live view through the real API and an aiortc viewer offers
the same data channel the app viewer offers ("ipcam-jpeg"); it must receive
JPEG pictures from the guard phone (each acked like the app does).

Made-up sample data only; scratch sqlite DB (settings_e2e).
"""
import asyncio
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import requests

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
E2E_DIR = os.environ.get("E2E_DIR", "/tmp/assisto-ipcam-e2e")
API = os.environ.get("IPCAM_API", "http://127.0.0.1:18700/api/v1")
RTSP_FOR_PHONE = os.environ.get("IPCAM_RTSP", "rtsp://viewer:viewpw@10.0.2.2:18554/cam1")
SEED = os.path.join(E2E_DIR, "ipcam_seed.json")
OWNER_PHONE = "01710009101"
LIVE = {"done": False, "started": False}


def django_setup():
    sys.path.insert(0, os.path.join(ROOT, "backend"))
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "assisto_backend.settings_e2e")
    import django
    django.setup()


def seed():
    django_setup()
    from datetime import timedelta

    from django.utils import timezone
    from rest_framework.authtoken.models import Token

    from core import feature_flags as FF
    from core.models import FeatureFlag, ShopSite, User
    FF.ensure_seeded()
    for k in ("cctv_watchman", "home_watchman", "guard_box_mode"):
        FeatureFlag.objects.filter(key=k).update(enabled_all=True, enabled_play=True, rollout_pct=100)
    u = User.objects.filter(phone=OWNER_PHONE).first() or User.objects.create_user(
        name="Owner", phone=OWNER_PHONE, password="e2e-pass-123")
    u.language = "en"
    u.plan = "business"
    u.plan_until = timezone.now() + timedelta(days=30)
    u.ai_credits = 1000
    u.save()
    site = ShopSite.objects.filter(owner=u).first() or ShopSite.objects.create(
        owner=u, name="Sample shop", kind="shop")
    out = {"token": Token.objects.get_or_create(user=u)[0].key, "site": site.id}
    with open(SEED, "w") as f:
        json.dump(out, f)
    print("seeded", out["site"])


def _seed():
    with open(SEED) as f:
        return json.load(f)


def _h():
    return {"Authorization": "Token %s" % _seed()["token"]}


def mint():
    r = requests.get("%s/shop/phonecam/pair" % API, params={"site": _seed()["site"]},
                     headers=_h(), timeout=10)
    r.raise_for_status()
    return {"code": r.json()["code"], "rtsp": RTSP_FOR_PHONE}


def _events():
    django_setup()
    from core.models import ShopCamera, ShopEvent
    site = _seed()["site"]
    cams = list(ShopCamera.objects.filter(site_id=site, vendor="phone").values(
        "id", "name", "device_info"))
    evs = []
    for e in ShopEvent.objects.filter(site_id=site).order_by("id"):
        evs.append({"id": e.id, "type": e.type, "camera": e.camera_id,
                    "source": (e.signals or {}).get("source"),
                    "detector": (e.signals or {}).get("detector"),
                    "conf": (e.signals or {}).get("conf"),
                    "snapshot": bool(e.snapshot), "created": e.created.isoformat()})
    return cams, evs


# ------------------------------------------------------------------ live probe
async def _live_probe(cam_id):
    from aiortc import RTCPeerConnection, RTCSessionDescription
    from aiortc.sdp import candidate_from_sdp
    h = _h()
    r = requests.post("%s/shop/live/start" % API, json={"camera": cam_id}, headers=h, timeout=15)
    LIVE["start_status"] = r.status_code
    if r.status_code >= 300:
        LIVE["error"] = r.text[:300]
        return
    sid = r.json()["id"]
    LIVE["session"] = sid
    pc = RTCPeerConnection()
    pc.addTransceiver("video", direction="recvonly")
    ch = pc.createDataChannel("ipcam-jpeg", ordered=True)
    got = []
    t_offer = time.time()

    @ch.on("message")
    def on_msg(m):
        if isinstance(m, (bytes, bytearray)):
            got.append(bytes(m))
            if len(got) == 1:
                LIVE["first_picture_s"] = round(time.time() - t_offer, 1)
                with open(os.path.join(E2E_DIR, "live_first.jpg"), "wb") as f:
                    f.write(bytes(m))
            ch.send("ack")

    offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    while pc.iceGatheringState != "complete":
        await asyncio.sleep(0.1)
    requests.post("%s/shop/live/%d/signal" % (API, sid), headers=h, timeout=10,
                  json={"kind": "offer", "payload": {"type": "offer", "sdp": pc.localDescription.sdp}})
    after = 0
    answered = False
    end = time.time() + 120
    while time.time() < end and len(got) < 5:
        q = requests.get("%s/shop/live/%d/signal" % (API, sid), params={"after": after},
                         headers=h, timeout=10)
        if q.status_code == 200:
            b = q.json()
            after = b.get("seq", after)
            for m in b.get("messages") or []:
                p = m.get("payload")
                if m.get("side") == "owner":
                    continue
                if m.get("kind") == "answer" and isinstance(p, dict) and not answered:
                    await pc.setRemoteDescription(RTCSessionDescription(sdp=p["sdp"], type="answer"))
                    answered = True
                    LIVE["answer_s"] = round(time.time() - t_offer, 1)
                elif m.get("kind") == "candidate" and isinstance(p, dict) and answered:
                    try:
                        line = (p.get("candidate") or "").split(":", 1)[-1]
                        c = candidate_from_sdp(line)
                        c.sdpMid = p.get("sdpMid")
                        c.sdpMLineIndex = p.get("sdpMLineIndex")
                        await pc.addIceCandidate(c)
                    except Exception as e:  # noqa: BLE001
                        LIVE.setdefault("cand_errors", []).append(str(e)[:80])
        await asyncio.sleep(1.0)
    LIVE["pictures"] = len(got)
    LIVE["jpeg_ok"] = bool(got) and got[0][:2] == b"\xff\xd8"
    LIVE["bytes"] = sum(len(g) for g in got)
    try:
        requests.post("%s/shop/live/%d/end" % (API, sid), headers=h, timeout=10, json={})
    except Exception:  # noqa: BLE001
        pass
    await pc.close()


def _live_thread():
    cam_id = None
    for _ in range(1800):  # the APK build + emulator boot come first (up to 60 min)
        try:
            cams, evs = _events()
            if evs and cams:
                cam_id = cams[0]["id"]
                break
        except Exception:  # noqa: BLE001
            pass
        time.sleep(2)
    if cam_id is None:
        LIVE["error"] = "no alert, no live probe"
        LIVE["done"] = True
        return
    LIVE["started"] = True
    try:
        asyncio.run(_live_probe(cam_id))
    except Exception as e:  # noqa: BLE001
        LIVE["error"] = "%s: %s" % (type(e).__name__, str(e)[:200])
    LIVE["done"] = True
    with open(os.path.join(E2E_DIR, "ipcam_live.json"), "w") as f:
        json.dump(LIVE, f)


class _H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):  # noqa: N802
        try:
            if self.path.startswith("/mint"):
                return self._json(200, mint())
            if self.path.startswith("/live_status"):
                return self._json(200, {k: v for k, v in LIVE.items()})
            return self._json(404, {})
        except Exception as e:  # noqa: BLE001
            return self._json(500, {"error": str(e)[:200]})


def serve():
    threading.Thread(target=_live_thread, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 18799), _H).serve_forever()


def check():
    cams, evs = _events()
    live = {}
    p = os.path.join(E2E_DIR, "ipcam_live.json")
    if os.path.exists(p):
        with open(p) as f:
            live = json.load(f)
    ours = [e for e in evs if e["source"] == "ip_camera_via_phone"]
    proof = {
        "phone_cameras": [{"id": c["id"], "caps": (c["device_info"] or {}).get("caps")} for c in cams],
        "events": evs,
        "alert_with_photo": any(e["snapshot"] for e in ours),
        "live": live,
        "live_pictures_ok": bool(live.get("pictures", 0) >= 3 and live.get("jpeg_ok")),
    }
    with open(os.path.join(E2E_DIR, "ipcam_proof.json"), "w") as f:
        json.dump(proof, f, indent=1)
    print(json.dumps(proof, indent=1))
    print("ALERT_WITH_PHOTO=%s LIVE_PICTURES=%s" % (proof["alert_with_photo"], proof["live_pictures_ok"]))
    return 0 if proof["alert_with_photo"] else 1


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "seed":
        seed()
    elif cmd == "serve":
        serve()
    elif cmd == "check":
        sys.exit(check())
    else:
        print(__doc__)
        sys.exit(2)
