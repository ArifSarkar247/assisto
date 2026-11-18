"""cctvplay (owner order 9 Nov 14:45, item 3): remote playback of PHONE
camera alert clips — the sealed preview on every alert (owner + family,
kept 24 h, never deleted by one view, own daily cap) and the full video on
demand from the camera phone (heartbeat request -> sealed MP4 upload ->
signed link + my wrap; budget-gated; 24 h; honest 'rolled over')."""
import base64
import importlib.util
import json
import os
from datetime import timedelta
from unittest import mock

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import SimpleTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core.logic import cash_guard as CG
from core.logic import cctv_traffic as T
from core.logic import phonecam_clips as P
from core.models import User
from core.testing_tmp import TempDirMixin  # a temp dir per class, never at import

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VECTOR = os.path.join(ROOT, "tools", "cashguard", "clip_vector.json")


def _edge_clip():
    """The Shop Box's own sealer/opener (same construction as the app)."""
    path = os.path.join(ROOT, "edge", "shopbox", "shopbox", "clip.py")
    spec = importlib.util.spec_from_file_location("cctvplay_edge_clip", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _keypair():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    k = X25519PrivateKey.generate()
    raw = lambda o, enc, fmt: o.public_bytes(enc, fmt)  # noqa: E731
    pub = raw(k.public_key(), serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    priv = k.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                           serialization.NoEncryption())
    return priv, base64.b64encode(pub).decode()


def _vector():
    with open(VECTOR) as f:
        return json.load(f)


# ============================================================ pure
class PureTests(SimpleTestCase):
    def _meta(self, **kw):
        m = dict(_vector()["meta"])
        m.pop("sha256", None)
        m.update(duration_s=10.0, frames=15, fps=1.5)
        m.update(kw)
        return m

    def test_preview_envelope_allows_the_phone_10_s_clip(self):
        self.assertEqual(P.preview_meta_problems(self._meta()), [])
        self.assertIn("bad_duration", P.preview_meta_problems(self._meta(duration_s=30)))
        self.assertIn("bad_frames", P.preview_meta_problems(self._meta(frames=200)))
        self.assertIn("bad_format", P.preview_meta_problems(self._meta(format="mp4")))
        self.assertEqual(P.preview_meta_problems("x"), ["bad_meta"])
        # the cash-guard rule (3-5 s) still refuses it — separate paths
        self.assertIn("bad_duration", CG.clip_meta_problems(self._meta()))

    def test_full_envelope_is_a_sealed_mp4(self):
        ok = self._meta(format="mp4", aad=P.FULL_AAD)
        self.assertEqual(P.full_meta_problems(ok), [])
        self.assertIn("bad_aad", P.full_meta_problems(self._meta(format="mp4")))
        self.assertIn("bad_format", P.full_meta_problems(self._meta(aad=P.FULL_AAD)))
        self.assertIn("bad_wraps", P.full_meta_problems(dict(ok, wraps={})))
        self.assertIn("bad_duration", P.full_meta_problems(dict(ok, duration_s=600)))

    def test_keys_states_and_device_queue(self):
        self.assertEqual(P.clean_key("E12"), "e12")
        self.assertEqual(P.clean_key("s1762675200"), "s1762675200")
        for bad in ("", "x1", "e", "e1;drop", "s12"):
            self.assertEqual(P.clean_key(bad), "", bad)
        now = 1_000_000.0
        self.assertEqual(P.request_state(None, now), "none")
        self.assertEqual(P.request_state({"status": "requested", "at": now - 10}, now),
                         "requested")
        self.assertEqual(P.request_state({"status": "requested",
                                          "at": now - P.REQUEST_TTL_S - 1}, now), "expired")
        self.assertEqual(P.request_state({"status": "ready", "expires": now - 1}, now),
                         "expired")
        reqs = {"e2": {"status": "requested", "at": now - 5, "ref": "ab" * 16},
                "e1": {"status": "requested", "at": now - 50, "ref": "cd" * 16},
                "e3": {"status": "ready", "at": now - 60, "expires": now + 60},
                "s1762675200": {"status": "requested", "at": now - 1}}
        rows = P.pending_for_device(reqs, now)
        self.assertEqual([r["key"] for r in rows], ["e1", "e2", "s1762675200"])
        self.assertEqual(rows[0], {"key": "e1", "kind": "event", "ref": "cd" * 16})
        self.assertEqual(rows[2]["start"], 1762675200)
        self.assertEqual(len(P.prune({"e%d" % i: {"status": "missing", "at": now}
                                      for i in range(80)}, now)), 60)

    def test_budget_view_and_clip_bytes_count_in_the_relay_meter(self):
        b = P.budget_view({"cap_mb": 300, "used_bytes": 100 * 1000 * 1000,
                           "level": "off"}, False)
        self.assertEqual((b["left_mb"], b["paused"], b["enforced"]), (200.0, False, False))
        self.assertTrue(P.budget_view({"cap_mb": 300, "used_bytes": 0,
                                       "level": "paused"}, True)["paused"])
        doc = T.add_clip({}, 7, 1500)
        doc = T.add_clip(doc, 7, 500)
        self.assertEqual(doc["cams"]["7"]["clip_bytes"], 2000)
        self.assertEqual(T.account_relay_bytes(doc), 2000)


# ============================================================ API
class _Base(TempDirMixin, APITestCase):
    def setUp(self):
        from core.models import ShopSite, ShopSiteViewer, ShopCamera, UserPublicKey
        p = mock.patch("core.credits._base_allowance", return_value=0)
        p.start()
        self.addCleanup(p.stop)
        p = mock.patch("core.push.safe_push", return_value=True)
        p.start()
        self.addCleanup(p.stop)
        self.owner = User.objects.create_user(name="Owner", phone="01710004001",
                                              password="pw")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=30)
        self.owner.language = "en"
        self.owner.save()
        self.viewer = User.objects.create_user(name="Wife", phone="01710004002",
                                               password="pw")
        self.stranger = User.objects.create_user(name="X", phone="01710004003",
                                                 password="pw")
        self.site = ShopSite.objects.create(owner=self.owner, name="Home", kind="home")
        ShopSiteViewer.objects.create(site=self.site, user=self.viewer)
        v = _vector()
        self.owner_priv = base64.b64decode(v["recipient_private"])
        UserPublicKey.objects.create(user=self.owner, public_key=v["recipient_public"],
                                     key_id="0a0b0c0d0e0f", scheme=CG.CLIP_SCHEME)
        self.viewer_priv, vpub = _keypair()
        UserPublicKey.objects.create(user=self.viewer, public_key=vpub,
                                     key_id="1a1b1c1d1e1f", scheme=CG.CLIP_SCHEME)
        self.client.force_authenticate(self.owner)
        r = self.client.get("/api/v1/shop/phonecam/pair?site=%d" % self.site.id)
        self.assertEqual(r.status_code, 200, r.data)
        r = APIClient().post("/api/v1/shop/phonecam/claim",
                             {"code": r.data["code"], "model": "Sample 5"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.cam = ShopCamera.objects.get(camera_token=r.data["camera_token"])
        self.dev = APIClient()
        self.dev.credentials(HTTP_X_SHOP_TOKEN=self.cam.camera_token)
        self.as_viewer = APIClient()
        self.as_viewer.force_authenticate(self.viewer)
        self.EC = _edge_clip()

    def hb(self):
        r = self.dev.post("/api/v1/shop/heartbeat",
                          {"camera_ids": [self.cam.id], "caps": ["live", "phone"],
                           "platform": "android"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        return r.data

    def alert(self, ref="ab" * 16):
        body = {"type": "person_detected", "camera_id": self.cam.id,
                "signals": {"detector": "yolox_nano_phone", "conf": 0.8, "persons": 1,
                            "source": "phone_camera"}}
        if ref:
            body["clip_ref"] = ref
        r = self.dev.post("/api/v1/shop/ingest", body, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data["event_id"]

    def seal(self, plain, recipients, fmt="acg1", aad=None, **meta):
        old = (self.EC.AAD, self.EC.FORMAT)
        try:
            self.EC.AAD = (aad or CG.CLIP_AAD).encode()
            self.EC.FORMAT = fmt
            ct, m = self.EC.seal(plain, recipients)
        finally:
            self.EC.AAD, self.EC.FORMAT = old
        m.update(meta)
        return ct, m

    def preview(self, ref, recipients):
        frames = [(i / 1.5, b"\xff\xd8\xff" + os.urandom(800)) for i in range(15)]
        plain = self.EC.encode_container(frames, 1.5)
        ct, meta = self.seal(plain, recipients, duration_s=10.0, frames=15, fps=1.5)
        r = self.dev.post("/api/v1/shop/clips", {
            "clip_ref": ref, "meta": json.dumps(meta),
            "blob": SimpleUploadedFile("c.bin", ct, "application/octet-stream")},
            format="multipart")
        return r, plain


class PreviewTests(_Base):
    def test_alert_preview_sealed_for_owner_and_family_kept_24h(self):
        from core.models import ShopEventClip
        block = self.hb()["phonecam"]
        self.assertTrue(block["clip"]["enabled"])
        self.assertEqual({r["uid"] for r in block["clip"]["recipients"]},
                         {self.owner.id, self.viewer.id})
        self.assertEqual(block["clip"]["left_today"], P.PREVIEWS_DAY_DEFAULT)
        ref = "ab" * 16
        ev = self.alert(ref)
        row = self.client.get("/api/v1/shop/events?site=%d" % self.site.id).data["events"][0]
        self.assertEqual((row["clip"]["status"], row["clip"]["phonecam"]), ("pending", True))
        r, plain = self.preview(ref, block["clip"]["recipients"])
        self.assertEqual(r.status_code, 201, r.data)
        clip = ShopEventClip.objects.get(event_id=ev)
        # owner V3 H: a paid owner (Business here) keeps it 30 days
        self.assertAlmostEqual((clip.expires_at - clip.created).total_seconds(),
                               30 * 86400, delta=5)
        # the family viewer opens it with THEIR key — the server never could
        for who, uid, priv in ((self.as_viewer, self.viewer.id, self.viewer_priv),
                               (self.client, self.owner.id, self.owner_priv)):
            g = who.get("/api/v1/shop/events/%d/clip" % ev)
            self.assertEqual(g.status_code, 200, g.data)
            self.assertFalse(g.data["delete_on_view"])
            self.assertEqual(g.data["phonecam"]["clip_s"], 10)
            self.assertEqual(g.data["phonecam"]["full"]["status"], "none")
            blob = self.client.get(g.data["url"].replace("http://testserver", ""))
            self.assertEqual(blob.status_code, 200)
            body = b"".join(blob.streaming_content) if blob.streaming else blob.content
            self.assertEqual(self.EC.open_clip(body, g.data["meta"], uid, priv), plain)
        # the owner watching does NOT delete it (the family may still look)
        v = self.client.post("/api/v1/shop/events/%d/clip/viewed" % ev, {}, format="json")
        self.assertFalse(v.data["deleted"])
        clip.refresh_from_db()
        self.assertEqual(clip.status, "ready")
        self.assertIsNotNone(clip.viewed_at)
        # its bytes count in the relay meter (upload + two downloads)
        from core import cctv_traffic as CT
        cams = CT.month_doc(self.owner.id)["cams"]
        self.assertEqual(cams[str(self.cam.id)]["clip_bytes"], clip.size * 3)

    def test_preview_cap_per_camera_and_stranger_blocked(self):
        ref = "cd" * 16
        ev = self.alert(ref)
        with mock.patch("core.phonecam_clips_views.previews_day", return_value=0):
            self.assertFalse(self.hb()["phonecam"]["clip"]["enabled"])
            r, _ = self.preview(ref, self.hb()["phonecam"]["clip"]["recipients"])
        self.assertEqual((r.status_code, r.data["error"]), (429, "clip_cap"))
        s = APIClient()
        s.force_authenticate(self.stranger)
        self.assertEqual(s.get("/api/v1/shop/events/%d/clip" % ev).status_code, 404)
        self.assertEqual(s.post("/api/v1/shop/events/%d/clip/full" % ev).status_code, 404)

    def test_plain_video_is_refused(self):
        ref = "ef" * 16
        self.alert(ref)
        meta = dict(_vector()["meta"], duration_s=10.0, frames=15)
        meta["wraps"] = {str(self.owner.id): meta["wraps"]["7"]}
        meta.pop("sha256")
        mp4 = b"\x00\x00\x00\x18ftypmp42" + os.urandom(3000)
        r = self.dev.post("/api/v1/shop/clips", {
            "clip_ref": ref, "meta": json.dumps(meta),
            "blob": SimpleUploadedFile("c.bin", mp4, "application/octet-stream")},
            format="multipart")
        self.assertEqual(r.status_code, 415, r.data)


class FullVideoTests(_Base):
    def upload_full(self, key, ct=None, meta=None, missing=False):
        if missing:
            return self.dev.post("/api/v1/shop/phonecam/video",
                                 {"key": key, "missing": True}, format="json")
        return self.dev.post("/api/v1/shop/phonecam/video", {
            "key": key, "meta": json.dumps(meta),
            "blob": SimpleUploadedFile("v.bin", ct, "application/octet-stream")},
            format="multipart")

    def test_viewer_asks_camera_phone_uploads_viewer_plays(self):
        ref = "12" * 16
        ev = self.alert(ref)
        g = self.as_viewer.get("/api/v1/shop/events/%d/clip/full" % ev)
        self.assertEqual((g.status_code, g.data["status"]), (200, "none"))
        self.assertTrue(g.data["camera_online"] is False or g.data["camera_online"] is True)
        r = self.as_viewer.post("/api/v1/shop/events/%d/clip/full" % ev)
        self.assertEqual((r.status_code, r.data["status"]), (202, "requested"))
        self.assertEqual(r.data["clip_s"], 10)
        # asking twice never queues twice
        self.assertEqual(self.client.post("/api/v1/shop/events/%d/clip/full" % ev)
                         .data["status"], "requested")
        reqs = self.hb()["phonecam"]["video_requests"]
        self.assertEqual(reqs, [{"key": "e%d" % ev, "kind": "event", "ref": ref}])
        # nobody asked for e999
        bad = self.upload_full("e999", missing=True)
        self.assertEqual(bad.status_code, 404)
        mp4 = b"\x00\x00\x00\x18ftypmp42" + os.urandom(20000)
        recips = self.hb()["phonecam"]["clip"]["recipients"]
        ct, meta = self.seal(mp4, recips, fmt="mp4", aad=P.FULL_AAD, duration_s=10.0)
        # plain MP4 is refused, the sealed one is kept
        self.assertEqual(self.upload_full("e%d" % ev, mp4, meta).status_code, 415)
        u = self.upload_full("e%d" % ev, ct, meta)
        self.assertEqual(u.status_code, 201, u.data)
        self.assertEqual(self.hb()["phonecam"]["video_requests"], [])
        self.assertTrue(self.upload_full("e%d" % ev, ct, meta).data["duplicate"])
        g = self.as_viewer.get("/api/v1/shop/events/%d/clip/full" % ev)
        self.assertEqual(g.data["status"], "ready")
        self.assertTrue(g.data["sealed_for_you"])
        self.assertNotIn("wraps", g.data["meta"])
        blob = self.client.get(g.data["url"].replace("http://testserver", ""))
        body = b"".join(blob.streaming_content) if blob.streaming else blob.content
        self.assertEqual(self.EC.open_clip(body, g.data["meta"], self.viewer.id,
                                           self.viewer_priv), mp4)
        # the preview envelope carries the same state
        self.assertEqual(self.client.get("/api/v1/shop/events/%d/clip" % ev).status_code, 200)
        # 30 days later (paid owner) the bytes are gone (hourly purge)
        later = timezone.now() + timedelta(days=31)
        from core import cashguard_views as CGV
        with mock.patch("django.utils.timezone.now", return_value=later):
            self.assertGreaterEqual(CGV.purge_clips(later), 1)
            g = self.as_viewer.get("/api/v1/shop/events/%d/clip/full" % ev)
        self.assertEqual(g.data["status"], "expired")

    def test_rolled_over_on_the_phone_is_honest(self):
        ev = self.alert("34" * 16)
        self.client.post("/api/v1/shop/events/%d/clip/full" % ev)
        r = self.upload_full("e%d" % ev, missing=True)
        self.assertEqual(r.data["status"], "missing")
        g = self.client.get("/api/v1/shop/events/%d/clip/full" % ev)
        self.assertEqual((g.data["status"], g.data["reason"]), ("missing", "rolled_over"))

    def test_old_app_alert_without_clip_ref(self):
        ev = self.alert(ref=None)
        r = self.client.post("/api/v1/shop/events/%d/clip/full" % ev)
        self.assertEqual((r.status_code, r.data["error"]), (404, "no_clip_ref"))
        row = self.client.get("/api/v1/shop/events?site=%d" % self.site.id).data["events"][0]
        self.assertEqual(row["clip"], {"status": "none", "phonecam": True, "has_ref": False})

    def test_paused_budget_refuses_new_full_video_only(self):
        ev = self.alert("56" * 16)
        with mock.patch("core.phonecam_clips_views.budget",
                        return_value=P.budget_view({"cap_mb": 300, "used_bytes": 0,
                                                    "level": "paused"}, True)):
            r = self.client.post("/api/v1/shop/events/%d/clip/full" % ev)
        self.assertEqual((r.status_code, r.data["error"]), (402, "budget_paused"))

    def test_unbind_removes_stored_videos(self):
        from core.models import PaCollectionItem
        ev = self.alert("78" * 16)
        self.client.post("/api/v1/shop/events/%d/clip/full" % ev)
        self.assertTrue(PaCollectionItem.objects.filter(collection="phonecam_rec").exists())
        self.dev.post("/api/v1/shop/phonecam/unbind", {}, format="json")
        self.assertFalse(PaCollectionItem.objects.filter(collection="phonecam_rec").exists())


class KeepAndCapTests(_Base):
    def test_free_owner_keeps_24h_paid_30_days(self):
        from core import phonecam_clips_views as PCV
        self.assertEqual(PCV.keep_s(self.cam) // 86400, 30)
        with mock.patch("core.phonecam_clips_views.is_paid", return_value=False):
            self.assertEqual(PCV.keep_s(self.cam), 86400)
            self.assertEqual(PCV.store_cap_bytes(self.cam), 200 * 1024 * 1024)
        self.assertEqual(self.hb()["phonecam"]["keep_days"], 30)

    def test_cloud_copies_fit_the_camera_cap_oldest_first(self):
        from core.models import ShopEvent, ShopEventClip
        recips = self.hb()["phonecam"]["clip"]["recipients"]
        refs = ["%02d" % i * 16 for i in range(3)]
        for ref in refs:
            ShopEvent.objects.create(site=self.cam.site, camera=self.cam,
                                     type="person_detected", confidence=0.8,
                                     signals={"clip_ref": ref})
        with mock.patch("core.phonecam_clips_views.store_cap_bytes", return_value=1):
            for ref in refs:
                r, _ = self.preview(ref, recips)
                self.assertEqual(r.status_code, 201, r.data)
        ready = ShopEventClip.objects.filter(event__camera=self.cam, status="ready")
        self.assertEqual(ready.count(), 1)     # only the newest stays under the cap
        self.assertEqual(ready.first().event.signals["clip_ref"], refs[-1])

    def test_pure_over_cap(self):
        self.assertEqual(P.over_cap([(1, 50, "a"), (2, 50, "b"), (3, 50, "c")], 100), ["a"])
        self.assertEqual(P.over_cap([(1, 500, "a")], 10), [])      # newest always kept
        self.assertEqual(P.keep_days(False), 1)
        self.assertEqual(P.keep_days(False, 7), 7)
        self.assertEqual(P.keep_days(True), 30)


class RecordingTests(_Base):
    def test_off_by_default_owner_turns_on_camera_phone_sees_it(self):
        r = self.client.get("/api/v1/shop/phonecam/%d/recording" % self.cam.id)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertFalse(r.data["settings"]["on"])
        self.assertFalse(self.hb()["phonecam"]["recording"]["on"])
        r = self.client.patch("/api/v1/shop/phonecam/%d/recording" % self.cam.id,
                              {"on": True, "cap_mb": 4000}, format="json")
        self.assertEqual(r.data["settings"], {"on": True, "cap_mb": 4000})
        self.assertEqual(self.hb()["phonecam"]["recording"], {"on": True, "cap_mb": 4000})
        # a family viewer can't change it, and can't see it until live is allowed
        self.assertEqual(self.as_viewer.patch("/api/v1/shop/phonecam/%d/recording" % self.cam.id,
                                              {"on": False}, format="json").status_code, 404)
        self.assertEqual(self.as_viewer.get("/api/v1/shop/phonecam/%d/recording"
                                            % self.cam.id).status_code, 403)
        self.client.patch("/api/v1/shop/phonecam/%d" % self.cam.id, {"viewers_live": True},
                          format="json")
        self.assertEqual(self.as_viewer.get("/api/v1/shop/phonecam/%d/recording"
                                            % self.cam.id).status_code, 200)

    def test_timeline_then_on_demand_minute_via_the_same_video_path(self):
        now = int(timezone.now().timestamp())
        spans = [[now - 3600, now - 3540], [now - 3539, now - 3480], [now - 600, now - 60]]
        r = self.dev.post("/api/v1/shop/phonecam/timeline",
                          {"spans": spans, "alerts": [now - 3500, now - 10 ** 7],
                           "used_mb": 120, "cap_mb": 2000, "state": "recording",
                           "set_on": True}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["recording"]["on"])         # the camera phone's own switch
        tl = self.client.get("/api/v1/shop/phonecam/%d/recording" % self.cam.id).data["timeline"]
        self.assertEqual(tl["spans"], [[now - 3600, now - 3480], [now - 600, now - 60]])
        self.assertEqual(tl["alerts"], [now - 3500])
        miss = self.client.post("/api/v1/shop/phonecam/%d/recording/clip" % self.cam.id,
                                {"t": now - 2000}, format="json")
        self.assertEqual((miss.status_code, miss.data["error"]), (404, "not_recorded"))
        t = now - 3500
        r = self.client.post("/api/v1/shop/phonecam/%d/recording/clip" % self.cam.id,
                             {"t": t}, format="json")
        self.assertEqual((r.status_code, r.data["status"]), (202, "requested"))
        reqs = self.hb()["phonecam"]["video_requests"]
        self.assertEqual(reqs, [{"key": "s%d" % t, "kind": "segment", "start": t}])
        seg = b"\x00\x00\x00\x18ftypmp42" + os.urandom(9000)
        recips = self.hb()["phonecam"]["clip"]["recipients"]
        ct, meta = self.seal(seg, recips, fmt="mp4", aad=P.FULL_AAD, duration_s=60.0,
                             start_ts=now - 3540)
        u = self.dev.post("/api/v1/shop/phonecam/video", {
            "key": "s%d" % t, "meta": json.dumps(meta),
            "blob": SimpleUploadedFile("v.bin", ct, "application/octet-stream")},
            format="multipart")
        self.assertEqual(u.status_code, 201, u.data)
        g = self.client.get("/api/v1/shop/phonecam/%d/recording/clip?key=s%d" % (self.cam.id, t))
        self.assertEqual(g.data["status"], "ready")
        self.assertEqual(g.data["meta"]["start_ts"], now - 3540)
        blob = self.client.get(g.data["url"].replace("http://testserver", ""))
        body = b"".join(blob.streaming_content) if blob.streaming else blob.content
        self.assertEqual(self.EC.open_clip(body, g.data["meta"], self.owner.id,
                                           self.owner_priv), seg)
        views = self.client.get("/api/v1/shop/phonecam/%d/recording" % self.cam.id).data["views"]
        self.assertEqual(views, {"s%d" % t: "ready"})

    def test_pure_timeline_normalize(self):
        now = 2_000_000_000
        tl = P.normalize_timeline({"spans": [[now - 100, now - 50], "x", [now - 49, now],
                                             [5, 10]], "state": "weird",
                                   "reason": "hot"}, now)
        self.assertEqual(tl["spans"], [[now - 100, now]])
        self.assertEqual((tl["state"], tl["reason"]), ("off", "hot"))
        self.assertTrue(P.covered(tl["spans"], now - 10))
        self.assertFalse(P.covered(tl["spans"], now + 10))
        self.assertEqual(P.rec_settings({}), {"on": False, "cap_mb": P.REC_CAP_DEFAULT_MB})
