"""cashguard — CCTV Smart Cash Guard (owner order 28 Oct, part A).

Pure rules (wording, away mode, plan caps, clip envelope, server box check),
then the API end to end on the real views: cash zone -> cash event with the
never-accusing wording -> edge-sealed clip upload (ciphertext only) -> owner
fetch (only their wrap) -> viewed = deleted -> 24 h purge; owner-away mode;
plan caps; Hikvision/Dahua target boxes; EZVIZ (mocked); the shared crypto
vector (tools/cashguard/clip_vector.json) that the edge and the app also pin.
"""
import base64
import io
import json
import os
import shutil
import atexit
import tempfile
from datetime import datetime, timedelta, timezone as dtz
from unittest import mock

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import SimpleTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core.logic import cash_guard as CG
from core.models import User

_MEDIA = tempfile.mkdtemp(prefix="cg-media-")
atexit.register(shutil.rmtree, _MEDIA, True)
FF_KEY = "home_watchman"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VECTOR = os.path.join(ROOT, "tools", "cashguard", "clip_vector.json")
CASH = [[0.1, 0.5], [0.5, 0.5], [0.5, 0.9], [0.1, 0.9]]


def _jpeg(w=640, h=360):
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (w, h), (30, 80, 140)).save(b, "JPEG")
    return b.getvalue()


def _vector():
    with open(VECTOR) as f:
        return json.load(f)


# ============================================================ pure
class WordingTests(SimpleTestCase):
    def test_titles_never_accuse_and_say_the_owner_decides(self):
        for lang in ("bn", "en"):
            for clip in (True, False):
                for away in (True, False):
                    t = CG.cash_title(lang, clip, away)
                    self.assertFalse(CG.accuses(t), t)
        self.assertEqual(CG.cash_title("bn"),
                         "সন্দেহজনক ক্যাশ সরানো — ক্লিপ দেখে আপনি সিদ্ধান্ত নিন")
        self.assertEqual(CG.cash_title("en"),
                         "Possible cash removal — watch the clip and decide")
        self.assertTrue(CG.cash_title("en", away=True).startswith("You are away — "))
        for w in ("চুরি", "Theft", "thief"):
            self.assertTrue(CG.accuses("x %s y" % w))

    def test_hand_to_pocket_label_is_off_until_measured(self):
        self.assertFalse(CG.HAND_TO_POCKET_LABEL)
        self.assertGreaterEqual(CG.HAND_TO_POCKET_MIN_PRECISION, 0.9)

    def test_cash_event_kinds(self):
        self.assertTrue(CG.is_cash_event("hand_in_cash_zone"))
        self.assertTrue(CG.is_cash_event("after_hours", {"person_in_zone": True}))
        self.assertFalse(CG.is_cash_event("after_hours", {}))
        self.assertFalse(CG.is_cash_event("person_detected"))


class AwayAndCapsTests(SimpleTestCase):
    def test_away_until_and_schedule(self):
        from core.logic import watchman as WM
        now = datetime(2026, 10, 28, 12, 0, tzinfo=dtz.utc)
        local = datetime(2026, 10, 28, 18, 0)        # a Wednesday
        self.assertFalse(CG.away_active({}, now, local, WM.is_armed))
        soon = (now + timedelta(hours=1)).isoformat()
        past = (now - timedelta(hours=1)).isoformat()
        self.assertTrue(CG.away_active({"until": soon}, now, local, WM.is_armed))
        self.assertFalse(CG.away_active({"until": past}, now, local, WM.is_armed))
        sched = {"days": [2], "start": "17:00", "end": "20:00"}
        self.assertTrue(CG.away_active({"schedule": sched}, now, local, WM.is_armed))
        self.assertFalse(CG.away_active({"schedule": dict(sched, days=[3])}, now,
                                        local, WM.is_armed))
        self.assertFalse(CG.away_active({"until": "garbage"}, now, local, WM.is_armed))

    def test_away_hours_are_bounded(self):
        now = datetime(2026, 10, 28, tzinfo=dtz.utc)
        self.assertEqual(CG.away_until_from_hours(0.2, now), now + timedelta(hours=1))
        self.assertEqual(CG.away_until_from_hours(10 ** 6, now),
                         now + timedelta(hours=CG.AWAY_MAX_HOURS))
        self.assertIsNone(CG.away_until_from_hours("x", now))
        self.assertIsNone(CG.away_until_from_hours(-3, now))

    def test_plan_caps_defaults_and_bounds(self):
        f = CG.caps_for("free", {})
        self.assertEqual((f["cameras"], f["alerts_day"], f["clips_day"]), (1, 5, 1))
        p = CG.caps_for("premium", {})
        self.assertEqual((p["cameras"], p["alerts_day"], p["clips_day"]), (2, 12, 2))
        b = CG.caps_for("business", {}, business_cameras=4)
        self.assertEqual((b["cameras"], b["alerts_day"], b["clips_day"]), (4, 30, 10))
        # nothing is unlimited: an owner typo is clamped
        self.assertEqual(CG.caps_for("free", {"cashguard_free_alerts_day": 10 ** 6})
                         ["alerts_day"], 50)
        self.assertEqual(CG.caps_for("free", {"cashguard_free_clips_day": True})
                         ["clips_day"], 1)
        self.assertEqual(CG.caps_for("nope", {})["tier"], "free")

    def test_40_percent_rule_holds_at_the_default_caps(self):
        for tier in ("premium", "business"):
            caps = CG.caps_for(tier, {})
            self.assertTrue(CG.inside_40_rule(tier, caps),
                            (tier, CG.monthly_cost_bdt(caps)))
        # Plus ৳199 leaves ৳4.38 of headroom; the premium caps cost ৳3.96
        self.assertEqual(CG.monthly_cost_bdt(CG.caps_for("premium", {})), 3.96)
        self.assertEqual(CG.monthly_cost_bdt(CG.caps_for("business", {})), 14.4)
        self.assertEqual(CG.monthly_cost_bdt(CG.caps_for("free", {})), 1.8)
        # raising a cap past the headroom is visible to the check
        self.assertFalse(CG.inside_40_rule(
            "premium", CG.caps_for("premium", {"cashguard_premium_clips_day": 20})))


class EnvelopeTests(SimpleTestCase):
    def test_shared_vector_meta_is_valid(self):
        v = _vector()
        self.assertEqual(CG.clip_meta_problems(v["meta"]), [])
        self.assertEqual(v["meta"]["scheme"], CG.CLIP_SCHEME)

    def test_bad_meta_codes(self):
        meta = _vector()["meta"]
        cases = [(dict(meta, alg="aes"), "bad_alg"),
                 (dict(meta, nonce="AAAA"), "bad_nonce"),
                 (dict(meta, duration_s=12), "bad_duration"),
                 (dict(meta, frames=1), "bad_frames"),
                 (dict(meta, wraps={}), "bad_wraps"),
                 (dict(meta, wraps={"x": {}}), "bad_wraps"),
                 (dict(meta, eph_pub="AA=="), "bad_eph_pub"),
                 (dict(meta, format="mp4"), "bad_format")]
        for m, code in cases:
            self.assertIn(code, CG.clip_meta_problems(m), code)
        self.assertEqual(CG.clip_meta_problems(None), ["bad_meta"])

    def test_meta_for_hands_out_only_my_wrap(self):
        meta = dict(_vector()["meta"])
        meta["wraps"] = {"7": meta["wraps"]["7"], "8": meta["wraps"]["7"]}
        mine = CG.meta_for(meta, 7)
        self.assertNotIn("wraps", mine)
        self.assertEqual(mine["wrap"], meta["wraps"]["7"])
        self.assertIsNone(CG.meta_for(meta, 9)["wrap"])

    def test_plain_media_is_detected(self):
        self.assertTrue(CG.looks_like_plain_media(_jpeg()))
        self.assertTrue(CG.looks_like_plain_media(b"ACG1" + b"\x00" * 100))
        self.assertTrue(CG.looks_like_plain_media(b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 64))
        self.assertFalse(CG.looks_like_plain_media(os.urandom(2048)[:0] + b"\x37" * 2048))

    def test_the_server_cannot_open_the_vector(self):
        """Ciphertext + public envelope only: without a recipient's PRIVATE
        key the clip stays closed (the server never has one)."""
        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
        v = _vector()
        ct = base64.b64decode(v["ciphertext"])
        self.assertNotIn(b"ACG1", ct)
        self.assertNotIn(b"FAKEJPEG", ct)
        with self.assertRaises(Exception):
            ChaCha20Poly1305(b"\x00" * 32).decrypt(
                base64.b64decode(v["meta"]["nonce"]), ct, CG.CLIP_AAD.encode())


class BoxCheckTests(SimpleTestCase):
    def test_box_in_zone(self):
        self.assertTrue(CG.box_in_zone((0.15, 0.55, 0.45, 0.85), CASH))
        self.assertFalse(CG.box_in_zone((0.6, 0.1, 0.9, 0.4), CASH))
        self.assertFalse(CG.box_in_zone((0.1, 0.1, 0.2), CASH))
        self.assertFalse(CG.box_in_zone((0.2, 0.6, 0.3, 0.7), []))

    def test_hikvision_target_rect_in_cash_zone_is_a_cash_event(self):
        from core.logic import camera_hooks as CH
        xml = (b'<?xml version="1.0"?><EventNotificationAlert><eventType>fielddetection'
               b'</eventType><eventState>active</eventState><detectionTarget>human'
               b'</detectionTarget><targetRect><x>0.15</x><y>0.55</y><width>0.3</width>'
               b'<height>0.3</height></targetRect></EventNotificationAlert>')
        ev = CH.parse_hikvision("application/xml", xml)[0]
        self.assertEqual(ev["box"], (0.15, 0.55, 0.45, 0.85))
        zc = {"v": 2, "zones": [{"type": "cash", "points": CASH}]}
        etype, sig = CH.map_event(ev, zc, datetime(2026, 10, 28, 12, 0))
        self.assertEqual(etype, "hand_in_cash_zone")
        self.assertTrue(sig["camera_box_in_zone"])
        # outside the zone -> the old restricted-zone path, never a cash event
        far = dict(ev, box=(0.6, 0.1, 0.9, 0.3))
        self.assertEqual(CH.map_event(far, zc, datetime(2026, 10, 28, 12, 0))[0], "motion")
        # 0..1000 integer firmware variant
        xml2 = xml.replace(b"<x>0.15</x>", b"<x>150</x>").replace(b"<y>0.55</y>", b"<y>550</y>") \
            .replace(b"<width>0.3</width>", b"<width>300</width>").replace(b"<height>0.3</height>", b"<height>300</height>")
        self.assertEqual(CH.parse_hikvision("application/xml", xml2)[0]["box"],
                         (0.15, 0.55, 0.45, 0.85))

    def test_dahua_bounding_box_8192_and_after_hours(self):
        from core.logic import camera_hooks as CH
        body = json.dumps({"Code": "CrossRegionDetection", "Action": "Start",
                           "Data": {"Object": {"ObjectType": "Human",
                                               "BoundingBox": [1229, 4506, 3686, 7373]}}})
        ev = CH.parse_dahua("application/json", body.encode())[0]
        self.assertAlmostEqual(ev["box"][0], 0.1501, places=3)
        zc = {"hours": {"open": "09:00", "close": "21:00"},
              "zones": [{"type": "cash", "points": CASH}], "v": 2}
        etype, sig = CH.map_event(ev, zc, datetime(2026, 10, 28, 23, 0))
        self.assertEqual(etype, "after_hours")
        self.assertTrue(sig["person_in_zone"])

    def test_after_hours_person_in_zone_is_a_third_signal(self):
        from core.logic import shop_guard as SG
        a = SG.combine({"type": "after_hours", "signals": {"after_hours": True}}, [])
        b = SG.combine({"type": "after_hours", "signals": {"after_hours": True,
                                                           "person_in_zone": True}}, [])
        self.assertGreater(b["confidence"], a["confidence"])
        self.assertIn("person_in_cash_zone", b["reason_signals"])

    def test_clip_ref_and_away_never_inflate_confidence(self):
        from core.logic import shop_guard as SG
        a = SG.combine({"type": "hand_in_cash_zone", "signals": {}}, [])
        b = SG.combine({"type": "hand_in_cash_zone",
                        "signals": {"clip_ref": "ab" * 16, "away": True,
                                    "server_check": "box_in_zone"}}, [])
        self.assertEqual(a["confidence"], b["confidence"])

    def test_server_detector_is_off_by_default(self):
        from core import cashguard_detect as CD
        self.assertFalse(CD.enabled())
        self.assertIsNone(CD.check_snapshot(_jpeg(), CASH))


# ============================================================ API
@override_settings(MEDIA_ROOT=_MEDIA)
class _Base(APITestCase):
    @classmethod
    def tearDownClass(cls):
        # never wipe _MEDIA here: tests_cctvx imports the same folder and the
        # --parallel workers share it after fork, so a class finishing in one
        # worker deleted clips another worker was about to check (flaky
        # tests_cctvx share test, 28 Oct). Removed once at process exit below.
        super().tearDownClass()

    def setUp(self):
        from core import feature_flags as FF
        from core.models import FeatureFlag, UserPublicKey
        self.owner = User.objects.create_user(name="Rahim", phone="01710003001",
                                              password="pw")
        self.owner.ai_credits = 500
        self.owner.language = "en"
        self.owner.save()
        self.family = User.objects.create_user(name="Karima", phone="01710003002",
                                               password="pw")
        self.client.force_authenticate(self.owner)
        v = _vector()
        UserPublicKey.objects.create(user=self.owner, public_key=v["recipient_public"],
                                     key_id=v["meta"]["wraps"]["7"]["key_id"],
                                     scheme=CG.CLIP_SCHEME)
        self.pushes = []
        p = mock.patch("core.push.safe_push",
                       side_effect=lambda *a, **k: self.pushes.append((a, k)) or True)
        p.start()
        self.addCleanup(p.stop)
        FF.ensure_seeded()
        FeatureFlag.objects.filter(key=FF_KEY).update(enabled_all=True, enabled_play=True)
        FF.invalidate()
        self.addCleanup(FF.invalidate)
        r = self.client.post("/api/v1/shop/watchman/setup",
                             {"kind": "home", "gateway": "pc", "name": "Shop"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.site = r.data
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % self.site["id"],
                             {"name": "Till", "kind": "shopbox", "vendor": "onvif",
                              "source": {"host": "192.168.1.20", "port": 554}},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.cam = r.data
        self.assertEqual(r.data["charged_credits"], 0)     # Free includes 1 camera
        z = self.client.put("/api/v1/shop/cameras/%d/zones" % self.cam["id"],
                            {"zone_config": {"zones": [{"type": "cash", "points": CASH}],
                                             "schedule": None, "sensitivity": "medium",
                                             "quiet_hours": None}}, format="json")
        self.assertEqual(z.status_code, 200, z.data)
        from core.models import ShopCamera
        self.camobj = ShopCamera.objects.get(pk=self.cam["id"])
        self.dev = APIClient()
        self.dev.credentials(HTTP_X_SHOP_TOKEN=self.camobj.camera_token)

    def ingest(self, etype="hand_in_cash_zone", ref=None, **sig):
        body = {"type": etype, "signals": dict({"detector": "yolox_nano",
                                                "motion_in_zone": True}, **sig)}
        if ref:
            body["clip_ref"] = ref
        return self.dev.post("/api/v1/shop/ingest", body, format="json")

    def meta(self, uid=None):
        m = dict(_vector()["meta"])
        m["wraps"] = {str(uid or self.owner.id): m["wraps"]["7"]}
        m.pop("sha256", None)
        return m

    def upload(self, ref, blob=None, meta=None, dev=None):
        blob = blob if blob is not None else os.urandom(4096)
        return (dev or self.dev).post("/api/v1/shop/clips", {
            "clip_ref": ref, "meta": json.dumps(meta or self.meta()),
            "blob": SimpleUploadedFile("c.bin", blob, "application/octet-stream")},
            format="multipart")


class CashEventClipTests(_Base):
    def test_cash_event_wording_clip_upload_fetch_view_delete(self):
        from core.models import ShopEvent, ShopEventClip, FamilyAlert
        ref = "a1" * 16
        r = self.ingest(ref=ref)
        self.assertEqual(r.status_code, 201, r.data)
        self.assertTrue(r.data["clip_wanted"])
        ev = ShopEvent.objects.get(pk=r.data["event_id"])
        self.assertEqual(ev.signals["clip_ref"], ref)
        self.assertNotIn("clip_ref", ev.signals["inputs"])
        # never an accusation; the owner decides
        a, k = self.pushes[0]
        self.assertTrue(a[3].startswith("Possible cash removal — watch the clip and decide"))
        self.assertTrue(a[2].startswith("সন্দেহজনক ক্যাশ সরানো — ক্লিপ দেখে আপনি সিদ্ধান্ত নিন"))
        self.assertFalse(CG.accuses(" ".join(a[2:6])))
        self.assertTrue(k["data"]["cash"] and k["data"]["clip"])
        fa = FamilyAlert.objects.get(user=self.owner, kind="shop_guard")
        self.assertIn("please check", fa.body.lower())
        # the app sees "pending" until the edge's clip arrives
        g = self.client.get("/api/v1/shop/events/%d/clip" % ev.id)
        self.assertEqual(g.data["status"], "pending")
        row = self.client.get("/api/v1/shop/events?site=%d" % self.site["id"]).data["events"][0]
        self.assertEqual((row["cash"], row["clip"]["status"]), (True, "pending"))
        # the edge uploads CIPHERTEXT
        blob = os.urandom(5000)
        u = self.upload(ref, blob)
        self.assertEqual(u.status_code, 201, u.data)
        clip = ShopEventClip.objects.get(event=ev)
        self.assertEqual(clip.size, 5000)
        self.assertAlmostEqual((clip.expires_at - clip.created).total_seconds(),
                               24 * 3600, delta=5)
        with open(clip.blob.path, "rb") as f:
            self.assertEqual(f.read(), blob)
        self.assertEqual(self.upload(ref).data.get("duplicate"), True)
        # owner fetch: a signed link + ONLY my wrap
        g = self.client.get("/api/v1/shop/events/%d/clip" % ev.id)
        self.assertEqual(g.status_code, 200, g.data)
        self.assertIn("/api/v1/m/", g.data["url"])
        self.assertNotIn("wraps", g.data["meta"])
        self.assertEqual(g.data["meta"]["wrap"]["key_id"], self.meta()["wraps"][str(self.owner.id)]["key_id"])
        self.assertTrue(g.data["delete_on_view"])
        # owner watched it -> bytes deleted now; the photo stays
        path = clip.blob.path
        v = self.client.post("/api/v1/shop/events/%d/clip/viewed" % ev.id, {}, format="json")
        self.assertTrue(v.data["deleted"])
        self.assertFalse(os.path.exists(path))
        clip.refresh_from_db()
        self.assertEqual(clip.status, "viewed")
        self.assertNotIn("wraps", clip.meta)
        gone = self.client.get("/api/v1/shop/events/%d/clip" % ev.id)
        self.assertEqual((gone.status_code, gone.data["status"]), (410, "viewed"))
        ev.refresh_from_db()
        self.assertTrue(ev.snapshot is not None)

    def test_24h_purge_deletes_the_bytes(self):
        from core.cashguard_views import purge_clips
        from core.models import ShopEventClip
        ref = "b2" * 16
        self.ingest(ref=ref)
        self.assertEqual(self.upload(ref).status_code, 201)
        clip = ShopEventClip.objects.get()
        path = clip.blob.path
        self.assertEqual(purge_clips(timezone.now() + timedelta(hours=23)), 0)
        self.assertEqual(purge_clips(timezone.now() + timedelta(hours=25)), 1)
        clip.refresh_from_db()
        self.assertEqual(clip.status, "expired")
        self.assertFalse(os.path.exists(path))
        # the hourly command is registered for ops-watch
        from core import ops_health as H
        self.assertIn("shop_clip_purge", H.JOB_BY_NAME)

    def test_lazy_expiry_on_fetch(self):
        from core.models import ShopEventClip
        ref = "c3" * 16
        r = self.ingest(ref=ref)
        self.upload(ref)
        ShopEventClip.objects.update(expires_at=timezone.now() - timedelta(seconds=1))
        g = self.client.get("/api/v1/shop/events/%d/clip" % r.data["event_id"])
        self.assertEqual((g.status_code, g.data["status"]), (410, "expired"))

    def test_plain_media_and_bad_envelopes_are_refused(self):
        ref = "d4" * 16
        self.ingest(ref=ref)
        for blob in (_jpeg(), b"ACG1" + os.urandom(3000),
                     b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 3000):
            r = self.upload(ref, blob)
            self.assertEqual((r.status_code, r.data["error"]), (415, "not_encrypted"))
        r = self.upload(ref, meta=dict(self.meta(), alg="none"))
        self.assertEqual((r.status_code, r.data["error"]), (422, "bad_clip_meta"))
        # sealed only for a stranger -> refused (must be the owner's)
        r = self.upload(ref, meta=self.meta(uid=self.family.id))
        self.assertEqual((r.status_code, r.data["error"]), (422, "bad_recipients"))
        r = self.upload(ref, blob=os.urandom(2 * 1024 * 1024))
        self.assertEqual(r.status_code, 413)
        from core.models import ShopEventClip
        self.assertEqual(ShopEventClip.objects.count(), 0)

    def test_clip_before_its_alert_is_retryable_and_late_clip_refused(self):
        r = self.upload("e5" * 16)
        self.assertEqual((r.status_code, r.data["error"]), (404, "no_event"))
        ref = "f6" * 16
        res = self.ingest(ref=ref)
        from core.models import ShopEvent
        ShopEvent.objects.filter(pk=res.data["event_id"]).update(
            created=timezone.now() - timedelta(minutes=20),
            last_at=timezone.now() - timedelta(minutes=20))
        r = self.upload(ref)
        self.assertEqual(r.status_code, 410)

    def test_bad_token_and_ref(self):
        bad = APIClient()
        bad.credentials(HTTP_X_SHOP_TOKEN="nope")
        self.assertEqual(self.upload("a1" * 16, dev=bad).status_code, 401)
        self.assertEqual(self.upload("not-hex").data["error"], "bad_clip_ref")

    def test_viewer_without_a_wrap_is_told_honestly_and_cannot_delete(self):
        from core.models import ShopSiteViewer
        ShopSiteViewer.objects.create(site_id=self.site["id"], user=self.family)
        ref = "a7" * 16
        r = self.ingest(ref=ref)
        self.upload(ref)
        fam = APIClient()
        fam.force_authenticate(self.family)
        g = fam.get("/api/v1/shop/events/%d/clip" % r.data["event_id"])
        self.assertEqual((g.status_code, g.data["error"]), (409, "not_sealed_for_you"))
        v = fam.post("/api/v1/shop/events/%d/clip/viewed" % r.data["event_id"], {},
                     format="json")
        self.assertFalse(v.data["deleted"])
        stranger = User.objects.create_user(name="S", phone="01710003009", password="pw")
        s = APIClient()
        s.force_authenticate(stranger)
        self.assertEqual(s.get("/api/v1/shop/events/%d/clip" % r.data["event_id"]).status_code, 404)

    def test_free_plan_clip_cap(self):
        with mock.patch("core.shop_views.owner_caps",
                        return_value=CG.caps_for("free", {"cashguard_free_clips_day": 1})):
            r1 = self.ingest(ref="aa" * 16)
            self.assertEqual(self.upload("aa" * 16).status_code, 201)
            from core.models import ShopEvent
            ShopEvent.objects.update(status="checked")       # next one is not grouped
            r2 = self.ingest(ref="bb" * 16)
            self.assertFalse(r2.data["clip_wanted"])
            r = self.upload("bb" * 16)
            self.assertEqual((r.status_code, r.data["error"]), (429, "clip_cap"))
        self.assertNotEqual(r1.data["event_id"], r2.data["event_id"])

    def test_device_config_names_the_recipients_public_keys_only(self):
        r = self.dev.get("/api/v1/shop/config")
        self.assertEqual(r.status_code, 200, r.data)
        clip = r.data["clip"]
        self.assertTrue(clip["enabled"])
        self.assertEqual(clip["recipients"][0]["uid"], self.owner.id)
        self.assertEqual(clip["recipients"][0]["pub"], _vector()["recipient_public"])
        self.assertNotIn("recipient_private", json.dumps(r.data))
        self.assertEqual(clip["scheme"], CG.CLIP_SCHEME)


class AwayModeTests(_Base):
    def _sched_not_now(self):
        now = timezone.localtime()
        s = (now + timedelta(hours=3)).strftime("%H:%M")
        e = (now + timedelta(hours=4)).strftime("%H:%M")
        return {"days": [0, 1, 2, 3, 4, 5, 6], "start": s, "end": e}

    def test_away_arms_every_camera_ignores_quiet_hours_high_priority(self):
        now = timezone.localtime()
        quiet = {"start": (now - timedelta(hours=1)).strftime("%H:%M"),
                 "end": (now + timedelta(hours=1)).strftime("%H:%M")}
        z = self.client.put("/api/v1/shop/cameras/%d/zones" % self.cam["id"],
                            {"zone_config": {"zones": [{"type": "cash", "points": CASH}],
                                             "schedule": self._sched_not_now(),
                                             "sensitivity": "medium",
                                             "quiet_hours": quiet}}, format="json")
        self.assertEqual(z.status_code, 200, z.data)
        # not armed now -> a person is ignored
        r = self.ingest("person_detected", person=True, conf=0.8)
        self.assertFalse(r.data["raised"])
        # owner taps "I'm away" for 2 hours
        a = self.client.put("/api/v1/shop/sites/%d/away" % self.site["id"],
                            {"on": True, "hours": 2}, format="json")
        self.assertEqual(a.status_code, 200, a.data)
        self.assertTrue(a.data["active"])
        r = self.ingest("person_detected", person=True, conf=0.8)
        self.assertTrue(r.data["raised"], r.data)
        args, kw = self.pushes[-1]
        self.assertTrue(kw["high_priority"])               # despite quiet hours
        self.assertTrue(kw["data"]["away"])
        # a device can never claim away mode
        self.client.put("/api/v1/shop/sites/%d/away" % self.site["id"], {"on": False},
                        format="json")
        from core.models import ShopEvent
        ShopEvent.objects.update(status="checked")
        r = self.ingest("person_detected", person=True, conf=0.8, away=True)
        self.assertFalse(r.data["raised"])

    def test_away_cash_alert_title_and_schedule(self):
        self.client.put("/api/v1/shop/sites/%d/away" % self.site["id"],
                        {"on": True, "hours": 1}, format="json")
        self.ingest()
        self.assertTrue(self.pushes[-1][0][3].startswith("You are away — Possible cash removal"))
        bad = self.client.put("/api/v1/shop/sites/%d/away" % self.site["id"],
                              {"schedule": {"days": [9], "start": "1:00", "end": "2:00"}},
                              format="json")
        self.assertEqual((bad.status_code, bad.data["error"]), (422, "bad_schedule"))
        ok = self.client.put("/api/v1/shop/sites/%d/away" % self.site["id"],
                             {"on": False, "schedule": {"days": [0, 1], "start": "13:00",
                                                        "end": "15:00"}}, format="json")
        self.assertEqual(ok.data["schedule"]["days"], [0, 1])
        self.assertIsNone(ok.data["until"])
        fam = APIClient()
        fam.force_authenticate(self.family)
        self.assertEqual(fam.put("/api/v1/shop/sites/%d/away" % self.site["id"],
                                 {"on": True}, format="json").status_code, 404)


class PlanCapTests(_Base):
    def test_overview_caps_and_honest_labels(self):
        r = self.client.get("/api/v1/shop/cashguard")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["caps"]["tier"], "free")
        self.assertEqual(r.data["caps"]["cameras"], 1)
        self.assertEqual(r.data["usage"]["cameras"], 1)
        self.assertFalse(r.data["hand_to_pocket"]["enabled"])
        self.assertFalse(r.data["hand_to_pocket"]["measured"])
        self.assertIsNone(r.data["hand_to_pocket"]["precision"])
        self.assertFalse(r.data["ads"])
        self.assertTrue(r.data["clip"]["end_to_end"])

    def test_free_second_camera_costs_credits(self):
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % self.site["id"],
                             {"name": "Door", "kind": "shopbox", "vendor": "onvif"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertGreater(r.data["charged_credits"], 0)

    def test_daily_alert_cap_follows_the_plan(self):
        from core.models import ShopEvent
        with mock.patch("core.shop_views.owner_caps",
                        return_value=dict(CG.caps_for("free", {}), alerts_day=2)):
            for i in range(3):
                ShopEvent.objects.update(status="checked")
                r = self.ingest()
            self.assertEqual(r.data.get("held"), "daily_cap")
        self.assertEqual(ShopEvent.objects.count(), 2)


class EzvizTests(_Base):
    def setUp(self):
        super().setUp()
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % self.site["id"],
                             {"name": "Counter", "kind": "shopbox", "vendor": "ezviz"},
                             format="json")
        self.ez = r.data

    def _http(self, calls, add_code="200", alarms=None):
        def http(url, form, timeout):
            calls.append((url, dict(form)))
            if url.endswith("/api/lapp/token/get"):
                return 200, json.dumps({"code": "200", "data": {
                    "accessToken": "AT", "expireTime": int((timezone.now().timestamp() + 3600) * 1000),
                    "areaDomain": "https://isgpopen.ezvizlife.com"}})
            if url.endswith("/api/lapp/device/add"):
                return 200, json.dumps({"code": add_code, "msg": "x"})
            if url.endswith("/api/lapp/alarm/device/list"):
                return 200, json.dumps({"code": "200", "data": alarms or []})
            return 404, ""
        return http

    def test_honest_without_keys(self):
        r = self.client.post("/api/v1/shop/cameras/%d/ezviz" % self.ez["id"],
                             {"device_serial": "E1234", "verification_code": "ABCDEF"},
                             format="json")
        self.assertEqual((r.status_code, r.data["error"]), (503, "ezviz_not_configured"))

    def test_link_poll_alarm_becomes_alert_code_never_stored(self):
        from core.logic import ezviz as EZ
        from core.cashguard_views import poll_ezviz
        from core.models import ShopCamera, ShopEvent
        EZ._token_cache.clear()
        calls = []
        client = EZ.EzvizClient("KEY", "SECRET", http=self._http(calls))
        with mock.patch("core.cashguard_views.ezviz_on", return_value=True), \
                mock.patch("core.logic.ezviz.EzvizClient.from_integration",
                           return_value=client):
            r = self.client.post("/api/v1/shop/cameras/%d/ezviz" % self.ez["id"],
                                 {"device_serial": "e1234", "verification_code": "abcdef"},
                                 format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["delivery"], "poll_60s")
        cam = ShopCamera.objects.get(pk=self.ez["id"])
        self.assertEqual(cam.vendor_ref, "EZ:E1234:1")
        self.assertNotIn("ABCDEF", json.dumps([cam.source, cam.compat]))
        # regional domain from the token answer is used for later calls
        self.assertTrue(calls[1][0].startswith("https://isgpopen.ezvizlife.com"))
        now_ms = int(timezone.now().timestamp() * 1000)
        alarms = [{"deviceSerial": "E1234", "channelNo": 1, "alarmId": "A1",
                   "alarmName": "Human detection", "alarmTime": now_ms + 1000,
                   "alarmPicUrl": "https://pic.ezvizlife.com/a.jpg", "isEncrypt": 0},
                  {"deviceSerial": "E1234", "channelNo": 1, "alarmId": "A2",
                   "alarmName": "Motion", "alarmTime": now_ms + 2000,
                   "alarmPicUrl": "https://pic.ezvizlife.com/b.jpg", "isEncrypt": 1}]
        client2 = EZ.EzvizClient("KEY", "SECRET", http=self._http([], alarms=alarms))
        fetched = []
        n = poll_ezviz(client=client2, now=timezone.now() + timedelta(seconds=5),
                       getter=lambda u: fetched.append(u) or _jpeg())
        self.assertEqual(n, 2)
        self.assertEqual(fetched, ["https://pic.ezvizlife.com/a.jpg"])   # encrypted pic skipped
        ev = ShopEvent.objects.filter(camera=cam).order_by("created").first()
        self.assertEqual(ev.type, "camera_alarm")
        self.assertTrue(ev.snapshot)
        # the same alarms again are not re-ingested
        self.assertEqual(poll_ezviz(client=client2, now=timezone.now() + timedelta(seconds=6),
                                    getter=lambda u: _jpeg()), 0)

    def test_wrong_code_is_explained(self):
        from core.logic import ezviz as EZ
        EZ._token_cache.clear()
        client = EZ.EzvizClient("KEY2", "S", http=self._http([], add_code="20010"))
        with mock.patch("core.cashguard_views.ezviz_on", return_value=True), \
                mock.patch("core.logic.ezviz.EzvizClient.from_integration",
                           return_value=client):
            r = self.client.post("/api/v1/shop/cameras/%d/ezviz" % self.ez["id"],
                                 {"device_serial": "E1234", "verification_code": "BAD"},
                                 format="json")
        self.assertEqual((r.status_code, r.data["hint"]), (502, "wrong_code"))
        self.assertIn("Verification Code", r.data["detail"])

    def test_integration_registered(self):
        from core import integrations as I
        from core.logic import ezviz as EZ
        self.assertIn("ezviz", I.REGISTRY)
        ok, _ = I.test_ezviz({"app_key": "A", "app_secret": "B"}, http=self._http([]))
        self.assertTrue(ok)
        self.assertFalse(EZ.snapshot_url_allowed("https://evil.io/x.jpg"))
        self.assertFalse(EZ.snapshot_url_allowed("http://pic.ezvizlife.com/x.jpg"))


class HookCashTests(_Base):
    def test_hikvision_box_in_cash_zone_raises_cash_alert(self):
        xml = (b'<?xml version="1.0"?><EventNotificationAlert><eventType>fielddetection'
               b'</eventType><eventState>active</eventState><detectionTarget>human'
               b'</detectionTarget><targetRect><x>0.15</x><y>0.55</y><width>0.3</width>'
               b'<height>0.3</height></targetRect></EventNotificationAlert>')
        r = APIClient().generic("POST", "/api/v1/shop/hook/hikvision/%s" % self.camobj.camera_token,
                                xml, content_type="application/xml")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.data["events"][0]["type"], "hand_in_cash_zone")
        self.assertTrue(r.data["events"][0]["raised"])
        self.assertIn("Possible cash removal", self.pushes[-1][0][3])


class PrecisionHarnessTests(SimpleTestCase):
    """item 6: the hand-to-pocket metric harness (no real clips -> OFF)."""

    def test_metrics_and_the_bar(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "precision_report", os.path.join(ROOT, "tools", "cashguard", "precision_report.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.self_test()
        r = mod.metrics([True] * 10, [0.9] * 10)
        self.assertEqual(r["precision"], 1.0)
        self.assertFalse(r["label_allowed"])          # too few clips to trust
        self.assertEqual(mod.MIN_PRECISION, CG.HAND_TO_POCKET_MIN_PRECISION)
