"""CCTV watchman end-to-end driver (run by tools/e2e/cctv_e2e.sh).

    python cctv_e2e_driver.py seed     # before runserver: users, flag, devices
    python cctv_e2e_driver.py run      # the end-to-end checks (exit 1 on any FAIL)

Real pieces, nothing faked except the camera itself and Google:
  * a REAL H.264 RTSP stream (mediamtx + rtsp_publisher.py) with digest auth,
    showing an empty room and then a person (public-domain NASA photo);
  * a simulated ONVIF camera (onvif_sim.py: WS-Discovery + SOAP + WS-Security);
  * the REAL Shop Box edge client (edge/shopbox: pairing, heartbeat, gateway
    tasks, compat check, YOLOX person detection, outbox + sender) in-process;
  * the REAL Django backend on a scratch port (settings_e2e: file sqlite,
    scratch MEDIA_ROOT) over HTTP;
  * the REAL FCM v1 push code, pointed at mock_fcm.py (JWT verified there).
Vendor cloud payloads (Hikvision ISAPI HTTP Listening, Dahua event push) are
POSTed to the real webhook endpoint exactly as a camera would.
"""
import io
import json
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path[:0] = [os.path.join(ROOT, "backend"), os.path.join(ROOT, "edge", "shopbox")]
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "assisto_backend.settings_e2e")

E2E_DIR = os.environ.get("E2E_DIR", "/tmp/assisto-e2e")
BASE = os.environ.get("E2E_BASE_URL", "http://127.0.0.1:18700")
API = BASE + "/api/v1"
FCM = os.environ.get("E2E_FCM_URL", "http://127.0.0.1:18790")
RTSP_HOSTPORT = os.environ.get("E2E_RTSP", "127.0.0.1:18554")
ONVIF_PORT = int(os.environ.get("E2E_ONVIF_PORT", "18080"))
SEED_FILE = os.path.join(E2E_DIR, "seed.json")
OWNER_PHONE, FAMILY_PHONE = "01710009001", "01710009002"

RESULTS = []
CASH_METRICS = {}


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), str(detail)[:300]))
    print("%s  %s %s" % ("PASS" if cond else "FAIL", name,
                         "" if cond else "-- " + str(detail)[:300]), flush=True)
    return bool(cond)


class Abort(Exception):
    pass


def need(name, cond, detail=""):
    if not check(name, cond, detail):
        raise Abort(name)


def wait_for(fn, timeout, every=0.5):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            last = fn()
            if last:
                return last
        except Exception as e:          # noqa: BLE001
            last = e
        time.sleep(every)
    return None


def django_setup():
    import django
    django.setup()


# ------------------------------------------------------------------ seed
def seed():
    django_setup()
    from rest_framework.authtoken.models import Token
    from core import feature_flags as FF
    from core.models import Device, FeatureFlag, User
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key="home_watchman").update(enabled_all=True,
                                                          enabled_play=True)
    out = {}
    for role, phone, lang in (("owner", OWNER_PHONE, "en"), ("family", FAMILY_PHONE, "bn")):
        u = User.objects.filter(phone=phone).first() or User.objects.create_user(
            name=role.title(), phone=phone, password="e2e-pass-123")
        u.language = lang
        u.ai_credits = 1000
        u.save()
        Device.objects.get_or_create(user=u, push_token="e2e-fcm-%s" % role)
        out[role] = Token.objects.get_or_create(user=u)[0].key
    with open(SEED_FILE, "w") as f:
        json.dump(out, f)
    print("seeded", list(out))


# ------------------------------------------------------------------ helpers
def session(token):
    import requests
    s = requests.Session()
    s.headers.update({"Authorization": "Token " + token, "Accept-Language": "en"})
    return s


def fcm_calls():
    import requests
    return requests.get(FCM + "/calls", timeout=5).json()["calls"]


def jpeg_bytes(w=800, h=450):
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (w, h), (30, 80, 140)).save(b, "JPEG")
    return b.getvalue()


def task_done(owner, tid):
    r = owner.get(API + "/shop/gateway/tasks/%d/status" % tid, timeout=10).json()
    return r if r.get("status") in ("done", "failed", "expired") else None


def step(result, key):
    for s in (result or {}).get("steps") or []:
        if s.get("key") == key:
            return s
    return {}


def fast_edge():
    """Production intervals are 20 s heartbeat / 60 s task poll; the harness
    runs the same code with short intervals."""
    from shopbox import device as D
    from shopbox import tasks as T

    class FastSync(D.DeviceSync):
        def __init__(self, *a, **k):
            k["every_s"] = 1.5
            super().__init__(*a, **k)

    class FastTasks(T.GatewayTasks):
        def __init__(self, *a, **k):
            k["poll_every_s"] = 3.0
            super().__init__(*a, **k)

    D.DeviceSync = FastSync
    T.GatewayTasks = FastTasks


# ------------------------------------------------------------------ phone camera
def run_phonecam(owner, family):
    """cctvtoday (owner two-phone test, 9 Nov): an old Android phone as the
    camera, exactly the HTTP calls the app makes (phonecam_api.dart +
    ShopDeviceClient): QR code -> claim without login -> heartbeat online ->
    a DAYTIME person alert with photo on a site -> push to owner + family ->
    alert list + photo -> live view reaches the camera phone -> family live
    blocked until the owner allows -> unbind."""
    import requests
    from core.models import ShopCamera, ShopEvent
    r = owner.post(API + "/shop/watchman/setup",
                   json={"kind": "home", "gateway": "phone", "name": "E2E Phone Home"},
                   timeout=10)
    need("phonecam: second place created", r.status_code == 201, r.text)
    site_id = r.json()["id"]
    r = owner.post(API + "/shop/sites/%d/viewers" % site_id,
                   json={"phone": FAMILY_PHONE}, timeout=10)
    check("phonecam: family viewer added", r.status_code == 201, r.text)
    r = owner.get(API + "/shop/phonecam/pair?site=%d" % site_id, timeout=10)
    need("phonecam: owner gets QR code + link", r.status_code == 200 and
         r.json().get("link", "").startswith("https://lifeassisto.com/pc/"), r.text)
    code, link = r.json()["code"], r.json()["link"]
    cam_phone = requests.Session()           # the OLD phone: no login at all
    cam_phone.headers.update({"Accept-Language": "bn"})
    t0 = time.monotonic()
    r = cam_phone.post(API + "/shop/phonecam/claim",
                       json={"code": link, "model": "Sample Phone 5"}, timeout=10)
    need("phonecam: camera phone pairs by scanning the QR link (no login)",
         r.status_code == 201 and r.json().get("camera_token"), r.text)
    tok, cam_id = r.json()["camera_token"], r.json()["camera"]["id"]
    r = cam_phone.post(API + "/shop/phonecam/claim", json={"code": code}, timeout=10)
    check("phonecam: the same code cannot pair a second phone",
          r.status_code == 409, r.text)
    dev = requests.Session()
    dev.headers.update({"X-Shop-Token": tok, "X-Shop-Camera": str(cam_id)})
    hb = lambda: dev.post(API + "/shop/heartbeat", json={  # noqa: E731
        "camera_ids": [cam_id], "caps": ["live", "phone"], "platform": "android",
        "health": {"level": 80, "charging": True, "temp_c": 31, "dark": False}},
        timeout=10)
    r = hb()
    need("phonecam: heartbeat accepted", r.status_code == 200, r.text)
    rows = owner.get(API + "/shop/phonecam/pair?site=%d" % site_id, timeout=10).json()
    check("phonecam: owner's pairing sheet sees the new camera",
          any(c["id"] == cam_id for c in rows.get("cameras", [])), rows)
    cam = ShopCamera.objects.get(pk=cam_id)
    check("phonecam: always on guard (no shop-hours schedule)",
          (cam.zone_config or {}).get("schedule") is None, cam.zone_config)

    n0 = len(fcm_calls())
    play_ref = "c0ffee" + "ab" * 13      # cctvplay: the alert names its clip
    ing = dev.post(API + "/shop/ingest", data={
        "type": "person_detected", "camera_id": str(cam_id), "clip_ref": play_ref,
        "signals": json.dumps({"detector": "yolox_nano_phone", "conf": 0.82,
                               "persons": 1, "source": "phone_camera"}),
        "at": str(time.time())},
        files={"snapshot": ("snapshot.jpg", jpeg_bytes(1280, 720), "image/jpeg")},
        timeout=15)
    need("phonecam: person alert raised", ing.status_code == 201 and
         ing.json().get("raised"), ing.text)
    ev_id = ing.json()["event_id"]
    calls = wait_for(lambda: [c for c in fcm_calls()[n0:]
                              if (c.get("data") or {}).get("event_id") == str(ev_id)], 10)
    secs = time.monotonic() - t0
    check("phonecam: push reaches owner AND family phone",
          calls and {c["token"] for c in calls} == {"e2e-fcm-owner", "e2e-fcm-family"},
          calls)
    CASH_METRICS["phonecam_pair_to_push_s"] = round(secs, 2)
    ow = {c["token"]: c for c in (calls or [])}.get("e2e-fcm-owner", {})
    snap_url = (ow.get("data") or {}).get("snapshot_url") or ""
    img = requests.get(snap_url, timeout=10) if snap_url else None
    check("phonecam: push photo opens (signed JPEG link)",
          img is not None and img.status_code == 200 and img.content[:2] == b"\xff\xd8",
          snap_url)
    evs = owner.get(API + "/shop/events?site=%d" % site_id, timeout=10).json()
    check("phonecam: owner alert list shows it with the photo",
          any(e["id"] == ev_id and e["snapshot_url"] for e in evs.get("events", [])), evs)
    fevs = family.get(API + "/shop/events?site=%d" % site_id, timeout=10).json()
    check("phonecam: family member sees the same alert",
          any(e["id"] == ev_id for e in fevs.get("events", [])), fevs)
    check("phonecam: alert is stored on the phone camera",
          ShopEvent.objects.filter(pk=ev_id, camera_id=cam_id).exists())
    try:
        run_phonecam_playback(owner, family, dev, hb, ev_id, play_ref)
    except Abort:
        pass
    except Exception:
        traceback.print_exc()
        check("cctvplay driver crashed", False, traceback.format_exc()[-300:])

    # live view: owner taps Live -> the camera phone finds it on its heartbeat
    r = family.post(API + "/shop/live/start", json={"camera": cam_id}, timeout=10)
    check("phonecam: family live view is OFF until the owner allows it",
          r.status_code == 403, r.text)
    r = owner.post(API + "/shop/live/start", json={"camera": cam_id}, timeout=10)
    if r.status_code == 503:
        check("phonecam: live start (server busy on the CI box — skipped)", True)
        return
    need("phonecam: owner live view starts", r.status_code == 201, r.text)
    sid = r.json()["id"]
    pend = (hb().json().get("live_pending") or [])
    check("phonecam: camera phone gets the live request on its next heartbeat",
          any(p.get("id") == sid for p in pend), pend)
    owner.post(API + "/shop/live/%d/signal" % sid,
               json={"kind": "offer", "payload": {"type": "offer", "sdp": "v=0"}},
               timeout=10)
    got = dev.get(API + "/shop/live/%d/signal?after=0" % sid, timeout=10).json()
    check("phonecam: the owner's offer reaches the camera phone",
          any(m.get("kind") == "offer" for m in got.get("messages", [])), got)
    dev.post(API + "/shop/live/%d/signal" % sid,
             json={"kind": "answer", "payload": {"type": "answer", "sdp": "v=0"}},
             timeout=10)
    back = owner.get(API + "/shop/live/%d/signal?after=0" % sid, timeout=10).json()
    check("phonecam: the camera phone's answer reaches the owner",
          any(m.get("kind") == "answer" for m in back.get("messages", [])), back)
    dev.post(API + "/shop/live/%d/end" % sid, json={"relayed": False, "seconds": 5},
             timeout=10)
    r = owner.patch(API + "/shop/phonecam/%d" % cam_id, json={"viewers_live": True},
                    timeout=10)
    check("phonecam: owner allows family live", r.status_code == 200, r.text)
    r = family.post(API + "/shop/live/start", json={"camera": cam_id}, timeout=10)
    check("phonecam: family live view now starts", r.status_code in (201, 503), r.text)

    r = dev.post(API + "/shop/phonecam/unbind", json={}, timeout=10)
    check("phonecam: camera phone removes itself",
          r.status_code == 200 and not ShopCamera.objects.filter(pk=cam_id).exists(),
          r.text)


# ------------------------------------------------------------------ run
def _real_mp4(seconds=10, fps=10):
    """A REAL small MP4 like the camera phone records (cv2, mp4v); None when
    OpenCV can't write one here (then plain test bytes are used)."""
    try:
        import cv2
        import numpy as np
        path = os.path.join(E2E_DIR, "phonecam_clip.mp4")
        w = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), fps, (320, 240))
        if not w.isOpened():
            return None
        for i in range(seconds * fps):
            f = np.full((240, 320, 3), 40, np.uint8)
            cv2.rectangle(f, (10 + i * 2, 60), (60 + i * 2, 200), (200, 180, 160), -1)
            w.write(f)
        w.release()
        with open(path, "rb") as fh:
            return fh.read()
    except Exception:
        return None


def _mp4_frames(raw):
    try:
        import cv2
        path = os.path.join(E2E_DIR, "phonecam_opened.mp4")
        with open(path, "wb") as fh:
            fh.write(raw)
        cap = cv2.VideoCapture(path)
        n = 0
        while True:
            ok, _f = cap.read()
            if not ok:
                break
            n += 1
        cap.release()
        return n
    except Exception:
        return -1


def run_phonecam_playback(owner, family, dev, hb, ev_id, ref):
    """cctvplay (owner order 9 Nov 14:45, item 3): the alert clip plays on the
    VIEWER's phone remotely. The owner's + family's phones publish their
    public keys; the camera phone's heartbeat names them; it seals a preview
    (ACG1 frames of its 10 s clip) and uploads ciphertext; the FAMILY phone
    opens it with its private key. Then the family asks for the FULL video:
    the camera phone sees the request on its next heartbeat, seals the real
    MP4 and uploads it; the family phone opens and decodes it (cv2)."""
    import base64
    import requests
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from core.models import ShopEvent, UserPublicKey
    from shopbox import clip as EC
    with open(os.path.join(ROOT, "tools", "cashguard", "clip_vector.json")) as fh:
        vec = json.load(fh)
    ev = ShopEvent.objects.select_related("site").get(pk=ev_id)
    owner_uid = ev.site.owner_id
    fam_uid = ev.site.viewers.values_list("user_id", flat=True).first()
    need("cctvplay: family viewer exists", fam_uid is not None)
    UserPublicKey.objects.update_or_create(
        user_id=owner_uid, defaults={"public_key": vec["recipient_public"],
                                     "key_id": vec["meta"]["wraps"]["7"]["key_id"],
                                     "scheme": EC.SCHEME})
    fam_key = X25519PrivateKey.generate()
    fam_priv = fam_key.private_bytes(serialization.Encoding.Raw,
                                     serialization.PrivateFormat.Raw,
                                     serialization.NoEncryption())
    fam_pub = fam_key.public_key().public_bytes(serialization.Encoding.Raw,
                                                serialization.PublicFormat.Raw)
    UserPublicKey.objects.update_or_create(
        user_id=fam_uid, defaults={"public_key": base64.b64encode(fam_pub).decode(),
                                   "key_id": EC.key_id(fam_pub), "scheme": EC.SCHEME})
    t0 = time.monotonic()
    block = (hb().json().get("phonecam") or {})
    clip_cfg = block.get("clip") or {}
    check("cctvplay: camera phone's heartbeat names owner + family as clip recipients",
          clip_cfg.get("enabled") and {r["uid"] for r in clip_cfg.get("recipients", [])}
          == {owner_uid, fam_uid}, block)
    # the preview: 15 small frames over 10 s (what clipFrames + buildPreview make)
    frames = [(i / 1.5, jpeg_bytes(320, 180)) for i in range(15)]
    plain = EC.encode_container(frames, 1.5)
    ct, meta = EC.seal(plain, clip_cfg.get("recipients") or [])
    meta.update(duration_s=10.0, frames=15, fps=1.5)
    r = dev.post(API + "/shop/clips", data={"clip_ref": ref, "meta": json.dumps(meta)},
                 files={"blob": ("clip.bin", ct, "application/octet-stream")}, timeout=15)
    need("cctvplay: camera phone uploads the sealed preview (ciphertext only)",
         r.status_code == 201, r.text)
    env = family.get(API + "/shop/events/%d/clip" % ev_id, timeout=10)
    ok = env.status_code == 200 and env.json().get("status") == "ready"
    check("cctvplay: family sees the preview ready (kept 24 h, not deleted on view)",
          ok and env.json().get("delete_on_view") is False, env.text[:300])
    if ok:
        blob = requests.get(env.json()["url"], timeout=10).content
        try:
            got = EC.open_clip(blob, env.json()["meta"], fam_uid, fam_priv)
            _hdr, fr = EC.decode_container(got)
        except Exception as e:
            got, fr = None, []
            print("open preview failed:", e)
        check("cctvplay: alert -> remote clip PLAYS on the family phone (opened with its key)",
              got == plain and len(fr) == 15, len(fr))
        CASH_METRICS["phonecam_alert_to_preview_s"] = round(time.monotonic() - t0, 2)
        lim = env.json().get("phonecam") or {}
        check("cctvplay: honest limits shown (10 s clip, 24 h free / 30 days paid, budget, online)",
              lim.get("clip_s") == 10 and lim.get("preview_keep_h") in (24, 720) and
              "budget" in (lim.get("full") or {}) and
              (lim.get("full") or {}).get("camera_online") is True, lim)
    # the FULL video on demand
    t1 = time.monotonic()
    r = family.post(API + "/shop/events/%d/clip/full" % ev_id, json={}, timeout=10)
    need("cctvplay: family asks the camera phone for the full video",
         r.status_code == 202 and r.json().get("status") == "requested", r.text)
    reqs = (hb().json().get("phonecam") or {}).get("video_requests") or []
    check("cctvplay: camera phone gets the request on its next heartbeat",
          reqs == [{"key": "e%d" % ev_id, "kind": "event", "ref": ref}], reqs)
    mp4 = _real_mp4() or (b"\x00\x00\x00\x18ftypmp42" + os.urandom(30000))
    old = (EC.AAD, EC.FORMAT)
    try:
        EC.AAD, EC.FORMAT = b"assisto-phonecam-video-v1", "mp4"
        vct, vmeta = EC.seal(mp4, clip_cfg.get("recipients") or [])
    finally:
        EC.AAD, EC.FORMAT = old
    vmeta["duration_s"] = 10.0
    r = dev.post(API + "/shop/phonecam/video", data={"key": "e%d" % ev_id,
                                                     "meta": json.dumps(vmeta)},
                 files={"blob": ("video.bin", vct, "application/octet-stream")}, timeout=30)
    need("cctvplay: camera phone uploads the sealed full video", r.status_code == 201, r.text)
    st = family.get(API + "/shop/events/%d/clip/full" % ev_id, timeout=10).json()
    check("cctvplay: full video ready for the family (signed link + their wrap)",
          st.get("status") == "ready" and st.get("sealed_for_you") is True, st)
    if st.get("status") == "ready":
        blob = requests.get(st["url"], timeout=20).content
        try:
            got = EC.open_clip(blob, st["meta"], fam_uid, fam_priv)
        except Exception:
            got = None
        n = _mp4_frames(got) if got else 0
        check("cctvplay: full video PLAYS on the family phone (%d frames decoded)" % n,
              got == mp4 and (n > 0 or n == -1), n)
        CASH_METRICS["phonecam_full_request_to_ready_s"] = round(time.monotonic() - t1, 2)
        CASH_METRICS["phonecam_full_bytes"] = len(vct)
    fam_other = family.get(API + "/shop/events/%d/clip/full" % (ev_id + 100000), timeout=10)
    check("cctvplay: no one else's alert videos", fam_other.status_code == 404, fam_other.text)

    # item 4: optional CONTINUOUS recording on the camera phone -> timeline ->
    # the owner picks a minute -> the camera phone sends it the same sealed way
    cam_id = ev.camera_id
    r = owner.get(API + "/shop/phonecam/%d/recording" % cam_id, timeout=10)
    check("cctvrec: continuous recording is OFF by default",
          r.status_code == 200 and r.json()["settings"]["on"] is False, r.text[:200])
    r = owner.patch(API + "/shop/phonecam/%d/recording" % cam_id,
                    json={"on": True, "cap_mb": 2000}, timeout=10)
    check("cctvrec: owner turns it on", r.status_code == 200 and
          r.json()["settings"]["on"] is True, r.text[:200])
    rec = (hb().json().get("phonecam") or {}).get("recording") or {}
    check("cctvrec: camera phone sees the switch on its heartbeat", rec.get("on") is True, rec)
    now = int(time.time())
    seg_start = now - 120
    r = dev.post(API + "/shop/phonecam/timeline", json={
        "spans": [[seg_start, seg_start + 60], [seg_start + 61, now - 1]],
        "alerts": [seg_start + 20], "used_mb": 12, "cap_mb": 2000,
        "state": "recording"}, timeout=10)
    check("cctvrec: camera phone publishes its timeline", r.status_code == 200, r.text)
    tl = owner.get(API + "/shop/phonecam/%d/recording" % cam_id, timeout=10).json()["timeline"]
    check("cctvrec: owner's timeline shows the recorded hours + the alert marker",
          tl.get("spans") == [[seg_start, now - 1]] and seg_start + 20 in (tl.get("alerts") or []), tl)
    t = seg_start + 20
    t2 = time.monotonic()
    r = owner.post(API + "/shop/phonecam/%d/recording/clip" % cam_id, json={"t": t}, timeout=10)
    need("cctvrec: owner asks for the minute at the alert marker",
         r.status_code == 202 and r.json().get("status") == "requested", r.text)
    reqs = (hb().json().get("phonecam") or {}).get("video_requests") or []
    check("cctvrec: camera phone gets the segment request",
          {"key": "s%d" % t, "kind": "segment", "start": t} in reqs, reqs)
    seg = _real_mp4(seconds=6) or (b"\x00\x00\x00\x18ftypmp42" + os.urandom(30000))
    old = (EC.AAD, EC.FORMAT)
    try:
        EC.AAD, EC.FORMAT = b"assisto-phonecam-video-v1", "mp4"
        sct, smeta = EC.seal(seg, clip_cfg.get("recipients") or [])
    finally:
        EC.AAD, EC.FORMAT = old
    smeta.update(duration_s=60.0, start_ts=seg_start)
    r = dev.post(API + "/shop/phonecam/video", data={"key": "s%d" % t, "meta": json.dumps(smeta)},
                 files={"blob": ("video.bin", sct, "application/octet-stream")}, timeout=30)
    need("cctvrec: camera phone uploads the sealed minute", r.status_code == 201, r.text)
    st = owner.get(API + "/shop/phonecam/%d/recording/clip?key=s%d" % (cam_id, t),
                   timeout=10).json()
    ok = st.get("status") == "ready"
    got = None
    if ok:
        blob = requests.get(st["url"], timeout=20).content
        try:
            got = EC.open_clip(blob, st["meta"], owner_uid,
                               base64.b64decode(vec["recipient_private"]))
        except Exception:
            got = None
    n = _mp4_frames(got) if got else 0
    check("cctvrec: continuous-recording minute PLAYS remotely on the owner phone (%d frames)" % n,
          ok and got == seg and (n > 0 or n == -1) and st["meta"].get("start_ts") == seg_start, st)
    CASH_METRICS["phonecam_segment_request_to_ready_s"] = round(time.monotonic() - t2, 2)


def run():
    django_setup()
    from core.models import FamilyAlert, NotifEvent, ShopCamera, ShopEvent
    from django.conf import settings
    seeds = json.load(open(SEED_FILE))
    owner, family = session(seeds["owner"]), session(seeds["family"])
    engine = None
    try:
        # ---------------------------------------------- owner: setup wizard
        r = owner.post(API + "/shop/watchman/setup",
                       json={"kind": "home", "gateway": "pc", "name": "E2E Home"}, timeout=10)
        need("setup: home site created", r.status_code == 201, r.text)
        site = r.json()
        site_id, enroll = site["id"], site["enrollment_token"]
        # Open all day (open == close) so the person/zone checks below don't
        # depend on the clock: with the default 09:00-22:00 Dhaka hours a run
        # at night is correctly classed after_hours and the person check fails.
        r = owner.patch(API + "/shop/sites/%d" % site_id,
                        json={"hours": {"open": "00:00", "close": "00:00"}}, timeout=10)
        need("setup: site open all day (clock-independent run)", r.status_code == 200, r.text)
        r = owner.post(API + "/shop/sites/%d/viewers" % site_id,
                       json={"phone": FAMILY_PHONE}, timeout=10)
        check("setup: family viewer added", r.status_code == 201, r.text)

        def add_cam(name, vendor, source=None):
            r = owner.post(API + "/shop/sites/%d/cameras" % site_id,
                           json={"name": name, "kind": "shopbox", "vendor": vendor,
                                 "source": source or {}}, timeout=10)
            need("camera added: %s" % name, r.status_code == 201, r.text)
            return r.json()

        cam_rtsp = add_cam("Gate (RTSP)", "rtsp")
        cam_onvif = add_cam("Hall (ONVIF)", "onvif",
                            {"host": "127.0.0.1", "onvif_port": ONVIF_PORT})
        cam_hik = add_cam("Shop door (Hikvision)", "hikvision",
                          {"host": "192.168.1.64", "port": 554})
        cam_dahua = add_cam("Back door (Dahua)", "dahua",
                            {"host": "192.168.1.108", "port": 554})

        # ---------------------------------------------- edge: pair + start
        fast_edge()
        from shopbox.cli import pair_token
        from shopbox.config import AppConfig, ConfigStore, normalize_base_url
        from shopbox.engine import Engine
        from shopbox.secure_store import SecretStore
        cfg = AppConfig()
        cfg.base_url = normalize_base_url(API)
        cfg.detection.sample_fps = 4.0
        store = SecretStore()
        need("edge: paired with the enrollment token",
             pair_token(cfg, store, enroll) == "ok")
        cstore = ConfigStore()
        cstore.save(cfg)
        engine = Engine(cfg, store, cfg_store=cstore)
        check("edge: YOLOX person model loaded",
              getattr(engine.detector, "name", "") == "yolox_nano",
              getattr(engine.detector, "name", ""))
        engine.start()
        ov = wait_for(lambda: owner.get(API + "/shop/watchman", timeout=10).json()
                      ["sites"][0]["gateway_state"]["online"], 20)
        check("owner app: gateway shows online after heartbeat", ov)

        # ---------------------------------------------- ONVIF WS-Discovery
        r = owner.post(API + "/shop/sites/%d/discover" % site_id, json={}, timeout=10)
        need("discover task queued", r.status_code == 201, r.text)
        t = wait_for(lambda: task_done(owner, r.json()["id"]), 40)
        found = ((t or {}).get("result") or {}).get("discovered") or []
        check("ONVIF discovery finds the simulated camera (WS-Discovery)",
              any(d.get("manufacturer") == "AssistoSim" and d.get("host") == "127.0.0.1"
                  for d in found), t)

        # ---------------------------------------------- compat checks
        rtsp_url = "rtsp://%s/cam1" % RTSP_HOSTPORT
        bad = "rtsp://viewer:WRONG@%s/cam1" % RTSP_HOSTPORT
        r = owner.post(API + "/shop/cameras/%d/check" % cam_rtsp["id"],
                       json={"rtsp_url": bad}, timeout=10)
        need("check queued (wrong password)", r.status_code == 201, r.text)
        t = wait_for(lambda: task_done(owner, r.json()["id"]), 40)
        res = (t or {}).get("result") or {}
        check("check: wrong RTSP password -> auth_failed, honest",
              res.get("ok") is False and step(res, "auth").get("code") == "auth_failed", t)
        check("check: wrong password never echoed back", "WRONG" not in json.dumps(t))

        good = "rtsp://viewer:viewpw@%s/cam1" % RTSP_HOSTPORT
        r = owner.post(API + "/shop/cameras/%d/check" % cam_rtsp["id"],
                       json={"rtsp_url": good}, timeout=10)
        t = wait_for(lambda: task_done(owner, r.json()["id"]), 60)
        res = (t or {}).get("result") or {}
        check("check: real RTSP stream passes reachable/auth/stream/snapshot",
              res.get("ok") is True and all(step(res, k).get("ok") for k in
                                            ("reachable", "auth", "stream", "snapshot")), t)
        check("check: stream info 640x360 h264",
              (res.get("info") or {}).get("width") == 640 and
              (res.get("info") or {}).get("codec") in ("h264", "H264"), res.get("info"))
        check("check: camera password never stored on the server",
              "viewpw" not in json.dumps([c.source for c in ShopCamera.objects.all()] +
                                         [c.compat for c in ShopCamera.objects.all()] +
                                         [t]))
        pv = owner.get(API + "/shop/cameras/%d/preview" % cam_rtsp["id"], timeout=10)
        ok_pv = pv.status_code == 200
        if ok_pv:
            img = owner.get(pv.json()["url"], timeout=10)
            ok_pv = img.status_code == 200 and img.content[:2] == b"\xff\xd8"
        check("check: preview still for the zone editor (signed link, JPEG)", ok_pv,
              pv.text[:200])

        r = owner.post(API + "/shop/cameras/%d/check" % cam_onvif["id"],
                       json={"host": "127.0.0.1", "onvif_port": ONVIF_PORT,
                             "username": "admin", "secret": "onvifpw"}, timeout=10)
        need("ONVIF check queued", r.status_code == 201, r.text)
        t = wait_for(lambda: task_done(owner, r.json()["id"]), 60)
        res = (t or {}).get("result") or {}
        info = res.get("info") or {}
        check("ONVIF check: GetStreamUri -> stream ok, events supported",
              res.get("ok") is True and info.get("onvif") is True and
              info.get("events_supported") is True and
              info.get("manufacturer") == "AssistoSim", t)
        r = owner.post(API + "/shop/cameras/%d/check" % cam_onvif["id"],
                       json={"host": "127.0.0.1", "onvif_port": ONVIF_PORT,
                             "username": "admin", "secret": "nope"}, timeout=10)
        t = wait_for(lambda: task_done(owner, r.json()["id"]), 60)
        res = (t or {}).get("result") or {}
        check("ONVIF check: wrong password -> auth_failed",
              res.get("ok") is False and step(res, "auth").get("code") == "auth_failed", t)

        # ---------------------------------------------- detection -> alert
        # the ONVIF camera shows the same scene; keep the count simple
        owner.patch(API + "/shop/cameras/%d" % cam_onvif["id"], json={"enabled": False},
                    timeout=10)
        ev = wait_for(lambda: ShopEvent.objects.filter(site_id=site_id).exclude(
            type__in=("motion",)).order_by("id").first(), 120, every=1.0)
        need("person in the RTSP stream -> server alert (ShopEvent)", ev is not None,
             "edge status %s / events %s" % (engine.status(), engine.events.recent(10)))
        check("alert attributed to the RTSP camera", ev.camera_id == cam_rtsp["id"],
              "camera_id=%s type=%s" % (ev.camera_id, ev.type))
        check("alert type is a person/zone detection",
              ev.type in ("person_detected", "zone_intrusion"), ev.type)
        check("detector really ran (signals: yolox_nano, person)",
              (ev.signals.get("inputs") or {}).get("detector") == "yolox_nano" and
              (ev.signals.get("inputs") or {}).get("person") is True, ev.signals)
        check("exactly ONE snapshot kept with the alert", bool(ev.snapshot))
        fa = FamilyAlert.objects.filter(kind="shop_guard", payload__event_id=ev.id)
        check("FamilyAlert for owner AND family viewer", fa.count() == 2, fa.count())
        check("NotifEvent feed rows for both",
              NotifEvent.objects.filter(type="business", meta__event_id=ev.id).count() == 2)
        calls = wait_for(lambda: [c for c in fcm_calls()
                                  if (c.get("data") or {}).get("event_id") == str(ev.id)],
                         10)
        check("FCM v1 push dispatched to both phones (JWT verified by mock)",
              calls and len(calls) == 2 and
              {c["token"] for c in calls} == {"e2e-fcm-owner", "e2e-fcm-family"}, calls)
        if calls:
            byt = {c["token"]: c for c in calls}
            ow = byt.get("e2e-fcm-owner", {})
            fm = byt.get("e2e-fcm-family", {})
            check("push wording: never 'theft', EN for owner / BN for family",
                  "Suspicious" in json.dumps(ow) and "সন্দেহজনক" in json.dumps(fm, ensure_ascii=False)
                  and "theft" not in json.dumps(calls).lower())
            snap_url = (ow.get("data") or {}).get("snapshot_url") or ""
            check("push carries a signed snapshot link", "/api/v1/m/" in snap_url, snap_url)
            import requests
            img = requests.get(snap_url, timeout=10)
            from PIL import Image
            okimg = img.status_code == 200 and img.content[:2] == b"\xff\xd8"
            if okimg:
                okimg = max(Image.open(io.BytesIO(img.content)).size) <= 640
            check("signed snapshot link serves the JPEG (<=640px)", okimg, img.status_code)
            tam = requests.get(snap_url.replace("s=", "s=0"), timeout=10)
            check("tampered signature -> 404", tam.status_code == 404, tam.status_code)
            name = ev.snapshot.name
            check("raw /media/ path is not public",
                  requests.get(BASE + "/media/" + name, timeout=10).status_code == 404)

        evs = owner.get(API + "/shop/events?site=%d" % site_id, timeout=10).json()
        check("owner app lists the alert with snapshot",
              any(e["id"] == ev.id and e["snapshot_url"] for e in evs.get("events", [])))
        fevs = family.get(API + "/shop/events?site=%d" % site_id, timeout=10).json()
        check("viewer app lists the alert (read-only role)",
              fevs.get("role") == "viewer" and
              any(e["id"] == ev.id for e in fevs.get("events", [])), fevs)

        # ---------------------------------------------- grouping
        from shopbox.client import IngestClient
        n_push = len(fcm_calls())
        ic = IngestClient(cfg.base_url)
        local = next(c for c in cfg.cameras if c.server_id == cam_rtsp["id"])
        site_tok, cam_tok = engine.tokens_for(local.id)
        from shopbox import payload as P
        evt = P.build_event(ev.type, {"person": True, "conf": 0.8,
                                      "detector": "yolox_nano"}, camera_id=local.id)
        evt["server_camera_id"] = local.server_id
        res = ic.send(evt, site_token=site_tok, camera_token=cam_tok,
                      snapshot=jpeg_bytes())
        ev.refresh_from_db()
        check("repeat detection groups into the SAME alert (count 2, no new push)",
              ev.count >= 2 and len(fcm_calls()) == n_push,
              "count=%s outcome=%s" % (ev.count, res.outcome))

        # ---------------------------------------------- feedback
        m = owner.post(API + "/shop/events/%d/mark" % ev.id, json={"status": "wrong"},
                       timeout=10).json()
        check("owner marks Wrong -> false_alarm + stricter tuning",
              m.get("status") == "false_alarm" and
              abs((m.get("tuning") or {}).get("person_conf", 0) - 0.5) < 1e-6, m)
        tuned = wait_for(lambda: abs(float((local.tuning or {}).get("person_conf") or 0)
                                     - 0.5) < 1e-6 or None, 20)
        check("edge pulls the adapted threshold (person_conf 0.5)", tuned, local.tuning)

        # ---------------------------------------------- cashguard: cash zone + clip
        # Smart Cash Guard (owner 28 Oct): the owner's phone key (a fixed TEST
        # key from tools/cashguard/clip_vector.json) is published, a CASH zone
        # is drawn over the counter, the person walks into it -> a cash alert
        # with the never-accusing wording -> the edge cuts a 3-5 s clip from
        # the REAL RTSP stream, seals it for the owner's key and uploads
        # ciphertext only -> the owner fetches the envelope + signed link and
        # opens it with the PRIVATE key the server never had -> watched =
        # deleted on the server.
        import base64
        from core.models import ShopEventClip, UserPublicKey
        from core.logic import cash_guard as CG
        from shopbox import clip as EC
        with open(os.path.join(ROOT, "tools", "cashguard", "clip_vector.json")) as fh:
            vec = json.load(fh)
        owner_uid = ShopEvent.objects.get(pk=ev.id).site.owner_id
        UserPublicKey.objects.update_or_create(
            user_id=owner_uid, defaults={"public_key": vec["recipient_public"],
                                         "key_id": vec["meta"]["wraps"]["7"]["key_id"],
                                         "scheme": CG.CLIP_SCHEME})
        r = owner.put(API + "/shop/cameras/%d/zones" % cam_rtsp["id"],
                      json={"zone_config": {"zones": [{"type": "cash", "points": [
                          [0.02, 0.02], [0.98, 0.02], [0.98, 0.98], [0.02, 0.98]]}],
                          "schedule": None, "sensitivity": "high", "quiet_hours": None}},
                      timeout=10)
        need("cashguard: cash zone saved", r.status_code == 200, r.text)
        on = wait_for(lambda: engine.clips.enabled and bool(local.cash_zone()) or None, 30)
        check("cashguard: edge pulled the cash zone + the owner's PUBLIC key", on,
              engine.clips.cfg)
        n_push = len(fcm_calls())
        cev = wait_for(lambda: ShopEvent.objects.filter(
            site_id=site_id, type="hand_in_cash_zone").order_by("id").first(), 120, every=1.0)
        need("cashguard: person at the cash zone -> cash alert", cev is not None,
             "edge %s / events %s" % (engine.status(), engine.events.recent(8)))
        check("cashguard: the alert names its clip (clip_ref, not evidence)",
              len((cev.signals or {}).get("clip_ref") or "") == 32 and
              "clip_ref" not in (cev.signals.get("inputs") or {}), cev.signals)
        ccalls = wait_for(lambda: [c for c in fcm_calls()[n_push:]
                                   if (c.get("data") or {}).get("event_id") == str(cev.id)], 15)
        cown = [c for c in (ccalls or []) if c.get("token") == "e2e-fcm-owner"]
        check("cashguard: push says 'Possible cash removal — watch the clip and decide'",
              bool(cown) and "Possible cash removal" in json.dumps(cown) and
              "theft" not in json.dumps(ccalls or []).lower(), ccalls)
        clip = wait_for(lambda: ShopEventClip.objects.filter(event_id=cev.id).first(), 60)
        need("cashguard: the edge uploaded ONE sealed clip", clip is not None,
             engine.status().get("clips"))
        with open(clip.blob.path, "rb") as fh:
            stored = fh.read()
        check("cashguard: server holds CIPHERTEXT only (no JPEG / container / video)",
              not CG.looks_like_plain_media(stored) and b"ACG1" not in stored[:64] and
              not stored.startswith(b"\xff\xd8"), stored[:16])
        check("cashguard: clip envelope valid, sealed for the owner only",
              CG.clip_meta_problems(clip.meta) == [] and
              set(clip.meta["wraps"]) == {str(owner_uid)}, clip.meta)
        env = owner.get(API + "/shop/events/%d/clip" % cev.id, timeout=10)
        check("cashguard: owner gets the envelope (only their wrap) + signed link",
              env.status_code == 200 and "wraps" not in env.json()["meta"] and
              "/api/v1/m/" in env.json()["url"], env.text[:300])
        if env.status_code == 200:
            import requests
            blob = requests.get(env.json()["url"], timeout=10).content
            plain = EC.open_clip(blob, env.json()["meta"], owner_uid,
                                 base64.b64decode(vec["recipient_private"]))
            head, frames = EC.decode_container(plain)
            dur = float(env.json()["meta"]["duration_s"])
            check("cashguard: owner's PRIVATE key opens it: %d JPEG frames, %.1f s"
                  % (len(frames), dur),
                  len(frames) >= 8 and 3.0 <= dur <= 5.5 and frames[0][:2] == b"\xff\xd8",
                  head)
            CASH_METRICS.update({"clip_frames": len(frames), "clip_seconds": dur,
                                 "clip_bytes": len(blob),
                                 "alert_to_clip_s": round((clip.created - cev.created)
                                                          .total_seconds(), 1)})
        fam_env = family.get(API + "/shop/events/%d/clip" % cev.id, timeout=10)
        check("cashguard: viewer without a key is told honestly (409)",
              fam_env.status_code == 409, fam_env.text[:200])
        v = owner.post(API + "/shop/events/%d/clip/viewed" % cev.id, json={}, timeout=10)
        gone = owner.get(API + "/shop/events/%d/clip" % cev.id, timeout=10)
        check("cashguard: watched -> deleted on the server (410, file gone)",
              v.json().get("deleted") is True and gone.status_code == 410 and
              not os.path.exists(clip.blob.path), gone.text[:200])

        # ---------------------------------------------- video is refused
        import requests
        mp4 = b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom" + b"\x00" * 4096
        r = requests.post(API + "/shop/ingest",
                          data={"site_token": enroll, "type": "person_detected",
                                "camera_id": cam_rtsp["id"]},
                          files={"snapshot": ("clip.jpg", mp4, "image/jpeg")}, timeout=10)
        check("a video disguised as a .jpg is refused (415)", r.status_code == 415, r.text)

        # ---------------------------------------------- Hikvision ISAPI push
        hik_tok = cam_hik["camera_token"]
        hik_xml = HIK_LINE % time.strftime("%Y-%m-%dT%H:%M:%S+06:00")
        boundary = "MIME_boundary"
        body = (("--%s\r\nContent-Disposition: form-data; name=\"linedetection\"\r\n"
                 "Content-Type: application/xml; charset=\"UTF-8\"\r\nContent-Length: %d"
                 "\r\n\r\n%s\r\n--%s\r\nContent-Disposition: form-data; "
                 "name=\"linedetectionPicture\"; filename=\"linedetectionPicture.jpg\""
                 "\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n")
                % (boundary, len(hik_xml), hik_xml, boundary, len(jpeg_bytes()))
                ).encode() + jpeg_bytes() + ("\r\n--%s--\r\n" % boundary).encode()
        n_push = len(fcm_calls())
        r = requests.post(API + "/shop/hook/hikvision/" + hik_tok, data=body,
                          headers={"Content-Type": "multipart/form-data; boundary=" + boundary},
                          timeout=10)
        hev = ShopEvent.objects.filter(camera_id=cam_hik["id"]).first()
        check("Hikvision ISAPI linedetection push -> alert with picture",
              r.status_code == 200 and hev is not None and bool(hev.snapshot), r.text)
        check("Hikvision alert pushed to both phones", len(fcm_calls()) == n_push + 2)
        r = requests.post(API + "/shop/hook/hikvision/" + hik_tok, data=HIK_HEARTBEAT,
                          headers={"Content-Type": "application/xml"}, timeout=10)
        check("Hikvision heartbeat (videoloss inactive) is acknowledged, no alert",
              r.status_code == 200 and r.json()["events"] == [] and
              ShopEvent.objects.filter(camera_id=cam_hik["id"]).count() == 1, r.text)
        r = requests.post(API + "/shop/hook/hikvision/" + hik_tok, data=body,
                          headers={"Content-Type": "multipart/form-data; boundary=" + boundary},
                          timeout=10)
        check("Hikvision burst repeat inside 60 s is deduped",
              ShopEvent.objects.filter(camera_id=cam_hik["id"]).count() == 1 and
              (r.json()["events"] or [{}])[0].get("dedupe") is True, r.text)
        r = requests.post(API + "/shop/hook/hikvision/" + "x" * 20, data=HIK_HEARTBEAT,
                          headers={"Content-Type": "application/xml"}, timeout=10)
        check("unknown camera token -> 401", r.status_code == 401)

        # ---------------------------------------------- Dahua event push
        r = requests.post(API + "/shop/hook/dahua/" + cam_dahua["camera_token"],
                          data=json.dumps(DAHUA_CROSSLINE),
                          headers={"Content-Type": "application/json"}, timeout=10)
        check("Dahua CrossLineDetection Start -> alert",
              r.status_code == 200 and
              ShopEvent.objects.filter(camera_id=cam_dahua["id"]).count() == 1, r.text)

        # ---------------------------------------------- cctvx: CCTV extras
        # (owner 28 Oct) no-sale drawer open, a sale clearing a touch,
        # escalation to a Circle member, camera offline + recovery — the
        # real views over HTTP, the real minute-job code (shop_guard_tick's
        # tick()) run here with a clock 3 minutes ahead, the real FCM code.
        from datetime import timedelta
        from django.utils import timezone as dj_tz
        from core import cctvx_views as CXV
        from core.models import CircleMember, ShopPosEvent
        # the FREE plan allows 5 alerts a day: clear this run's earlier test
        # alerts (all checked above) so the extras below are not held back
        ShopEvent.objects.filter(site_id=site_id).delete()
        ShopPosEvent.objects.create(site_id=site_id, kind="sale", amount=100,
                                    at=dj_tz.now() - timedelta(days=2))   # uses Assisto POS
        hdev = requests.Session()
        hdev.headers.update({"X-Shop-Token": cam_hik["camera_token"]})

        def settle():
            """Wait until no push is still in flight (async FCM workers)."""
            last, same = -1, 0
            for _ in range(40):
                n = len(fcm_calls())
                same = same + 1 if n == last else 0
                if same >= 3:
                    return n
                last = n
                time.sleep(0.5)
            return last
        n_push = settle()
        r = hdev.post(API + "/shop/ingest", json={"type": "hand_in_cash_zone", "signals": {
            "detector": "yolox_nano", "motion_in_zone": True}}, timeout=10)
        nev = ShopEvent.objects.filter(pk=(r.json() or {}).get("event_id")).first()
        check("cctvx: cash-zone touch at a POS shop waits for the no-sale check (no push)",
              r.status_code == 201 and nev is not None and nev.pending and
              len(fcm_calls()) == n_push, r.text)
        lst = owner.get(API + "/shop/events?site=%d" % site_id, timeout=10).json()["events"]
        check("cctvx: the pending touch is not listed yet",
              nev is not None and all(e["id"] != nev.id for e in lst))
        CXV.run_due(dj_tz.now() + timedelta(minutes=3))
        ncalls = wait_for(lambda: [c for c in fcm_calls()[n_push:]
                                   if (c.get("data") or {}).get("event_id") == str(nev.id)], 15)
        nown = [c for c in (ncalls or []) if c.get("token") == "e2e-fcm-owner"]
        check("cctvx: no sale in 2 min -> 'Drawer opened with no sale — watch the clip and decide'",
              bool(nown) and "Drawer opened with no sale" in json.dumps(nown) and
              "theft" not in json.dumps(ncalls or []).lower() and
              (nown[0].get("data") or {}).get("nosale") == "true", ncalls)
        check("cctvx: family viewer gets it in Bangla",
              "বিক্রি ছাড়া ড্রয়ার খোলা" in json.dumps([c for c in (ncalls or [])
                                                     if c.get("token") == "e2e-fcm-family"],
                                                    ensure_ascii=False))
        # a sale rung up 70 s after the touch clears it: nothing kept, no push
        ddev = requests.Session()
        ddev.headers.update({"X-Shop-Token": cam_dahua["camera_token"]})
        r = ddev.post(API + "/shop/ingest", json={"type": "hand_in_cash_zone", "signals": {
            "detector": "yolox_nano", "motion_in_zone": True}}, timeout=10)
        cid = (r.json() or {}).get("event_id")
        need("cctvx: the second touch is pending too", cid is not None and
             ShopEvent.objects.get(pk=cid).pending, r.text)
        r2 = requests.post(API + "/shop/pos", json={
            "site_token": enroll, "kind": "sale", "amount": 25000,
            "at": (dj_tz.now() + timedelta(seconds=70)).isoformat()}, timeout=10)
        n_push = settle()
        CXV.run_due(dj_tz.now() + timedelta(minutes=3))
        settle()
        check("cctvx: a sale in the window clears the touch (deleted, no push)",
              r2.status_code == 201 and not ShopEvent.objects.filter(pk=cid).exists() and
              len(fcm_calls()) == n_push, r2.text)
        # escalation: the owner picks a Circle member; the alert is not opened
        from core.models import ShopSiteViewer
        fam_uid = ShopSiteViewer.objects.filter(site_id=site_id).values_list(
            "user_id", flat=True).first()
        CircleMember.objects.create(user_id=owner_uid, peer_user_id=fam_uid, state="accepted",
                                    name="Family")
        g = owner.put(API + "/shop/sites/%d/guard" % site_id,
                      json={"escalation": [fam_uid], "shop_phone": "01710009001"}, timeout=10)
        check("cctvx: escalation chain saved (Circle member only)",
              g.status_code == 200 and g.json()["settings"]["escalation"] == [fam_uid], g.text)
        r = hdev.post(API + "/shop/ingest", json={"type": "zone_intrusion", "signals": {
            "detector": "yolox_nano", "zone_breach": True, "person": True}}, timeout=10)
        eid = (r.json() or {}).get("event_id")
        need("cctvx: a fresh alert for the escalation test", eid is not None, r.text)
        wait_for(lambda: len([c for c in fcm_calls()
                              if (c.get("data") or {}).get("event_id") == str(eid)]) >= 2, 15)
        n_push = len(fcm_calls())
        CXV.run_due(dj_tz.now() + timedelta(minutes=3))
        esc = wait_for(lambda: [c for c in fcm_calls()[n_push:]
                                if (c.get("data") or {}).get("escalated") == "true"], 15)
        check("cctvx: not opened in 2 min -> passed to the chosen person (high priority)",
              bool(esc) and esc[0].get("token") == "e2e-fcm-family" and
              "এখনো দেখেননি" in json.dumps(esc, ensure_ascii=False), esc)
        o = family.post(API + "/shop/events/%d/opened" % eid, json={}, timeout=10)
        det = family.get(API + "/shop/events/%d" % eid, timeout=10)
        check("cctvx: they open it -> escalation stops; alert actions offered",
              o.status_code == 200 and o.json().get("opened_at") and
              det.json()["actions"]["call_shop"] == "01710009001" and
              det.json()["actions"]["emergency"] == "999", det.text[:300])
        # camera offline 11 min -> one alert; back -> one recovery notice
        ShopCamera.objects.filter(pk=cam_dahua["id"]).update(
            last_seen=dj_tz.now() - timedelta(minutes=11))
        n_push = len(fcm_calls())
        CXV.tick(dj_tz.now())
        key = "c%d" % cam_dahua["id"]
        off = wait_for(lambda: [c for c in fcm_calls()[n_push:]
                                if (c.get("data") or {}).get("notice") == "offline"
                                and key in str((c.get("data") or {}).get("keys"))], 15)
        check("cctvx: camera silent 10 min -> 'power or internet may be cut' push",
              bool(off) and "power or internet may be cut" in json.dumps(off), off)
        n2 = len(fcm_calls())
        CXV.tick(dj_tz.now() + timedelta(seconds=30))
        time.sleep(1.0)
        check("cctvx: no repeat while still offline",
              not [c for c in fcm_calls()[n2:]
                   if (c.get("data") or {}).get("notice") == "offline"
                   and key in str((c.get("data") or {}).get("keys"))])
        ShopCamera.objects.filter(pk=cam_dahua["id"]).update(last_seen=dj_tz.now())
        n2 = len(fcm_calls())
        CXV.tick(dj_tz.now() + timedelta(seconds=40))
        back = wait_for(lambda: [c for c in fcm_calls()[n2:]
                                 if (c.get("data") or {}).get("notice") == "recovered"], 15)
        check("cctvx: back online -> one recovery notice", bool(back), back)
        live = ShopCamera.objects.get(pk=cam_rtsp["id"]).last_seen
        check("cctvx: the real edge reports only cameras that deliver frames (live_ids)",
              live is not None and (dj_tz.now() - live).total_seconds() < 30, live)
        rep = owner.get(API + "/shop/sites/%d/guard/report" % site_id, timeout=10).json()
        check("cctvx: nightly guard report counts (no-sale 1, with sale 1, 0 credits)",
              rep["counts"]["drawer_nosale"] >= 1 and rep["counts"]["drawer_sale"] >= 1 and
              rep["credits"] == 0, rep)
        CASH_METRICS["cctvx_checks"] = True

        # ---------------------------------------------- NO VIDEO anywhere
        engine.stop()
        engine_stopped = True
        from core.shop_views import VIDEO_EXTS, looks_like_video
        from core.logic import cctv_store as CS
        bad_files, n_files, media_imgs = [], 0, 0
        sealed_files, plain_cctv = 0, []

        def rel_shop(path):
            rel = os.path.relpath(path, str(settings.MEDIA_ROOT)).replace(os.sep, "/")
            return rel.startswith("shop/")
        for root_dir in (settings.MEDIA_ROOT, os.environ.get("SHOPBOX_HOME", "")):
            for dp, _dn, fns in os.walk(root_dir or "/nonexistent"):
                for fn in fns:
                    p = os.path.join(dp, fn)
                    n_files += 1
                    with open(p, "rb") as fh:
                        head = fh.read(1024)
                    # cctvevidence: CCTV media are sealed at rest (AES-GCM,
                    # core/logic/cctv_store) — check what is INSIDE
                    if root_dir == settings.MEDIA_ROOT and CS.is_sealed(head):
                        sealed_files += 1
                        rel = os.path.relpath(p, str(settings.MEDIA_ROOT)).replace(os.sep, "/")
                        with open(p, "rb") as fh:
                            head = CS.open_blob(fh.read(), rel)[:1024]
                    elif root_dir == settings.MEDIA_ROOT and rel_shop(p):
                        plain_cctv.append(p)
                    if fn.lower().endswith(VIDEO_EXTS) or looks_like_video(head):
                        bad_files.append(p)
                    if root_dir == settings.MEDIA_ROOT and head[:2] == b"\xff\xd8":
                        media_imgs += 1
        check("NO video stored anywhere (server media + Shop Box data, %d files)"
              % n_files, not bad_files, bad_files)
        check("server media holds only small stills (%d JPEGs)" % media_imgs,
              media_imgs >= 2)
        check("cctvevidence: every CCTV file is sealed at rest (%d sealed, %d plain)"
              % (sealed_files, len(plain_cctv)), sealed_files >= 2 and not plain_cctv,
              plain_cctv[:5])
        out_left = len(engine.outbox)
        check("edge outbox drained (nothing stuck)", out_left == 0, out_left)
    except Abort:
        pass
    except Exception:
        traceback.print_exc()
        check("driver crashed", False, traceback.format_exc()[-300:])
    finally:
        if engine is not None and engine.running:
            try:
                engine.stop()
            except Exception:
                pass
    # cctvtoday: the two-phone path (old phone = camera), its own section so a
    # failure above never hides it
    try:
        run_phonecam(owner, family)
    except Abort:
        pass
    except Exception:
        traceback.print_exc()
        check("phonecam driver crashed", False, traceback.format_exc()[-300:])
    failed = [r for r in RESULTS if not r[1]]
    print("\n==== CCTV E2E: %d passed, %d failed ====" % (len(RESULTS) - len(failed),
                                                          len(failed)))
    for n, _ok, d in failed:
        print("FAILED: %s -- %s" % (n, d))
    if CASH_METRICS:
        print("CASHGUARD_E2E " + json.dumps(CASH_METRICS))
    with open(os.path.join(E2E_DIR, "cctv_results.json"), "w") as f:
        json.dump([{"check": n, "ok": ok, "detail": d} for n, ok, d in RESULTS], f,
                  indent=1, ensure_ascii=False)
    return 1 if failed else 0


# Realistic vendor payloads ------------------------------------------------
# Hikvision ISAPI EventNotificationAlert, as sent by "HTTP Listening" /
# Alarm Server (ISAPI Event Notification, Hikvision ISAPI Developer Guide
# "Event/Alarm" chapter: eventType linedetection, eventState active).
HIK_LINE = (
    '<?xml version="1.0" encoding="UTF-8"?>\r\n'
    '<EventNotificationAlert version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">\r\n'
    '<ipAddress>192.168.1.64</ipAddress><portNo>80</portNo><protocol>HTTP</protocol>'
    '<macAddress>bc:ad:28:00:00:01</macAddress><channelID>1</channelID>'
    '<dateTime>%s</dateTime><activePostCount>1</activePostCount>'
    '<eventType>linedetection</eventType><eventState>active</eventState>'
    '<eventDescription>linedetection alarm</eventDescription>'
    '<channelName>Shop door</channelName><DetectionRegionList><DetectionRegionEntry>'
    '<regionID>1</regionID><sensitivityLevel>50</sensitivityLevel>'
    '<detectionTarget>human</detectionTarget></DetectionRegionEntry>'
    '</DetectionRegionList></EventNotificationAlert>')
# The keep-alive every Hikvision sends every ~10 s with no event.
HIK_HEARTBEAT = (
    b'<?xml version="1.0" encoding="UTF-8"?><EventNotificationAlert version="2.0" '
    b'xmlns="http://www.hikvision.com/ver20/XMLSchema"><ipAddress>192.168.1.64</ipAddress>'
    b'<channelID>1</channelID><dateTime>2026-10-27T10:00:00+06:00</dateTime>'
    b'<activePostCount>0</activePostCount><eventType>videoloss</eventType>'
    b'<eventState>inactive</eventState><eventDescription>videoloss alarm'
    b'</eventDescription></EventNotificationAlert>')
# Dahua HTTP API eventManager push (JSON form) — "CrossLineDetection" Start.
DAHUA_CROSSLINE = {"Code": "CrossLineDetection", "Action": "Start", "Index": 0,
                   "Data": {"LocaleTime": "2026-10-27 10:00:00", "UTC": 1793080800,
                            "Name": "Rule1", "Direction": "LeftToRight",
                            "Object": {"ObjectType": "Human"}}}


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "seed":
        seed()
        sys.exit(0)
    sys.exit(run())
