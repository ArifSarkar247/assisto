"""
cctvevidence (W7) — sealed CCTV storage (AES-GCM per object, S3 seam,
encrypted local fallback, legacy migration), the per-camera video add-on
(prices, 40 % rule, entitlement, daily cap), the 10-s SD clip fetch (EZVIZ
official playback / honest Imou limit), SD health, lifecycle delete and the
evidence-pack facts (address, privacy warning, SD clip).
"""
import os
from datetime import timedelta
from unittest import mock

from django.core.files.base import ContentFile
from django.core.management import call_command
from django.test import SimpleTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core.logic import cctv_store as S
from core.logic import cctv_video_addon as VA
from core.models import User
from core.tests_cashguard import _Base, _MEDIA, _jpeg

HLS = "https://hls01open.ys7.com/openlive/abc.m3u8"


def _getter(segment_bytes=4096, segments=3):
    def get(url, limit):
        if url.endswith(".m3u8"):
            body = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n" + "".join(
                "#EXTINF:4.0,\nseg%d.ts\n" % i for i in range(segments))
            return body.encode()
        return (b"\x47" + os.urandom(segment_bytes - 1))[:limit]
    return get


class _FakeEz:
    def __init__(self, url=HLS, sd=None):
        self.url, self.sd = url, sd
        self.calls = []

    def playback_hls(self, serial, ch, start, stop):
        self.calls.append((serial, ch, start, stop))
        return self.url

    def sd_status(self, serial):
        return self.sd if self.sd is not None else [{"index": 0, "status": 0}]


class _FakeImou:
    def sd_status(self, did):
        return "normal"

    def sd_storage(self, did):
        return {"totalBytes": 64 * 10 ** 9, "usedBytes": 30 * 10 ** 9}


# ============================================================ pure
class SealTests(SimpleTestCase):
    def test_round_trip_name_binding_and_tamper(self):
        b1 = S.seal(b"hello photo", "shop/a.jpg")
        b2 = S.seal(b"hello photo", "shop/a.jpg")
        self.assertTrue(S.is_sealed(b1))
        self.assertNotEqual(b1, b2)                       # per-object salt + nonce
        self.assertNotIn(b"hello photo", b1)
        self.assertEqual(S.open_blob(b1, "shop/a.jpg"), b"hello photo")
        with self.assertRaises(S.StoreError):
            S.open_blob(b1, "shop/b.jpg")                 # copied onto another name
        bad = bytearray(b1)
        bad[-1] ^= 1
        with self.assertRaises(S.StoreError):
            S.open_blob(bytes(bad), "shop/a.jpg")

    def test_owner_key_from_settings(self):
        import base64
        with override_settings(CCTV_STORE_KEY=base64.b64encode(b"k" * 32).decode()):
            b = S.seal(b"x" * 50, "shop/k.jpg")
            self.assertEqual(S.open_blob(b, "shop/k.jpg"), b"x" * 50)
        with self.assertRaises(S.StoreError):            # another key does not open it
            S.open_blob(b, "shop/k.jpg")

    def test_names_outside_shop_are_refused(self):
        for n in ("vault/x.jpg", "shop/../etc/passwd", "/shop/x", "shop\\x"):
            self.assertFalse(S.valid_name(n), n)

    def test_s3_sigv4_put_get_delete(self):
        store, seen = {}, []

        def http(method, url, headers, body, timeout):
            seen.append((method, url, headers))
            key = url.split("/assisto-cctv/", 1)[1]
            if method == "PUT":
                store[key] = body
                return 200, b""
            if method == "GET":
                return (200, store[key]) if key in store else (404, b"")
            if method == "HEAD":
                return (200 if key in store else 404), b""
            store.pop(key, None)
            return 204, b""
        cfg = {"endpoint": "https://acc.r2.cloudflarestorage.com", "bucket": "assisto-cctv",
               "key_id": "AKID", "secret": "SECRET", "region": "auto"}
        s3 = S.S3Backend(cfg, http=http)
        s3.put("shop/x.jpg", b"sealed")
        self.assertEqual(s3.get("shop/x.jpg"), b"sealed")
        self.assertTrue(s3.exists("shop/x.jpg"))
        s3.delete("shop/x.jpg")
        self.assertIsNone(s3.get("shop/x.jpg"))
        auth = seen[0][2]["Authorization"]
        self.assertTrue(auth.startswith("AWS4-HMAC-SHA256 Credential=AKID/"))
        self.assertIn("/auto/s3/aws4_request", auth)
        self.assertNotIn("SECRET", auth)

    def test_s3_needs_all_four_settings_and_https(self):
        self.assertIsNone(S.s3_config())
        with override_settings(CCTV_S3_ENDPOINT="http://x", CCTV_S3_BUCKET="b",
                               CCTV_S3_KEY_ID="k", CCTV_S3_SECRET="s"):
            self.assertIsNone(S.s3_config())               # never plain http
        with override_settings(CCTV_S3_ENDPOINT="https://x", CCTV_S3_BUCKET="b",
                               CCTV_S3_KEY_ID="k", CCTV_S3_SECRET="s"):
            self.assertEqual(S.backend_name(), "s3")


class AddonRuleTests(SimpleTestCase):
    def test_prices_days_and_caps(self):
        self.assertEqual(VA.TIERS["7d"], {"days": 7, "price_tk": 100})
        self.assertEqual(VA.TIERS["30d"], {"days": 30, "price_tk": 150})
        self.assertEqual((VA.CLIP_SECONDS, VA.MAX_CLIPS_PER_CAMERA_DAY), (10, 30))
        self.assertEqual(VA.credits_for("7d", 1.0), 100)
        self.assertEqual(VA.credits_for("30d", 1.0, months=2), 300)
        self.assertEqual(VA.credits_for("bogus", 1.0), 0)
        self.assertTrue(VA.can_add_clip(29))
        self.assertFalse(VA.can_add_clip(30))
        s, e = VA.clip_window(1000.0)
        self.assertEqual((s, e), (996.0, 1006.0))

    def test_photo_retention_base_7_days(self):
        self.assertEqual(VA.photo_days(30), 7)
        self.assertEqual(VA.photo_days(30, "7d"), 7)
        self.assertEqual(VA.photo_days(30, "30d"), 30)
        self.assertEqual(VA.photo_days(3, "30d"), 3)       # the owner's shorter wish wins
        self.assertEqual(VA.photo_days(0), 0)

    def test_forty_percent_rule_worst_case(self):
        for tier in VA.TIERS:
            self.assertTrue(VA.profit_ok(tier), VA.cost_table())
        rows = {r["tier"]: r for r in VA.cost_table()}
        self.assertGreater(rows["7d"]["worst_cost_tk"], 30)   # real costs, not zero
        self.assertLess(rows["7d"]["margin"], rows["30d"]["margin"])

    def test_person_alert_kinds(self):
        self.assertTrue(VA.is_person_alert("person_detected"))
        self.assertTrue(VA.is_person_alert("camera_alarm", {"inputs": {"human": True}}))
        self.assertFalse(VA.is_person_alert("camera_alarm", {"inputs": {"human": False}}))
        self.assertFalse(VA.is_person_alert("motion"))
        self.assertFalse(VA.is_person_alert("hand_in_cash_zone"))

    def test_sd_days_and_vendor_states(self):
        from core.logic import ezviz as EZ, imou as IM
        self.assertAlmostEqual(VA.sd_days_estimate(64 * 10 ** 9), 5.8, places=1)
        self.assertIsNone(VA.sd_days_estimate(0))
        self.assertEqual(EZ.sd_state([{"status": 0}]), "ok")
        self.assertEqual(EZ.sd_state([{"status": 1}]), "error")
        self.assertEqual(EZ.sd_state([]), "none")
        self.assertEqual(IM.sd_state("empty"), "none")
        self.assertEqual(IM.sd_state("abnormal"), "error")
        self.assertEqual(IM.sd_state("weird"), "unknown")


class HlsTests(SimpleTestCase):
    def test_fetch_concatenates_and_caps(self):
        from core import cctv_evidence as CE
        from core.logic import ezviz as EZ
        data = CE.fetch_hls_clip(HLS, getter=_getter(), allowed=EZ.snapshot_url_allowed)
        self.assertEqual(len(data), 3 * 4096)
        big = CE.fetch_hls_clip(HLS, getter=_getter(segment_bytes=600 * 1024),
                                allowed=EZ.snapshot_url_allowed)
        self.assertLessEqual(len(big), VA.MAX_CLIP_BYTES)

    def test_foreign_hosts_refused(self):
        from core import cctv_evidence as CE
        from core.logic import ezviz as EZ
        self.assertIsNone(CE.fetch_hls_clip("https://evil.example/x.m3u8", getter=_getter(),
                                            allowed=EZ.snapshot_url_allowed))

        def get(url, limit):
            return b"#EXTM3U\n#EXTINF:4,\nhttp://169.254.169.254/latest\n"
        self.assertIsNone(CE.fetch_hls_clip(HLS, getter=get, allowed=EZ.snapshot_url_allowed))


# ============================================================ API / DB
@override_settings(MEDIA_ROOT=_MEDIA)
class _E(_Base):
    def setUp(self):
        super().setUp()
        from core.models import ShopSite
        self.sobj = ShopSite.objects.get(pk=self.site["id"])
        S._http_override = None

    def event(self, etype="person_detected", days_old=0, **sig):
        from core.models import ShopEvent
        ev = ShopEvent.objects.create(site=self.sobj, camera=self.camobj, type=etype,
                                      signals={"inputs": sig}, confidence=0.9)
        if days_old:
            ShopEvent.objects.filter(pk=ev.pk).update(
                created=timezone.now() - timedelta(days=days_old))
            ev.refresh_from_db()
        return ev

    def ezviz_cam(self):
        self.camobj.vendor, self.camobj.vendor_ref = "ezviz", "EZ:ABC123:1"
        self.camobj.save()

    def grant(self, tier="7d"):
        from core import cctv_evidence as CE
        return CE.grant_addon(self.camobj, tier, source="test")


class SealedStorageTests(_E):
    def test_snapshot_is_sealed_at_rest_and_served_only_by_signed_link(self):
        ev = self.event()
        jpg = _jpeg()
        ev.snapshot.save("a.jpg", ContentFile(jpg), save=True)
        with open(os.path.join(_MEDIA, ev.snapshot.name), "rb") as f:
            raw = f.read()
        self.assertTrue(raw.startswith(S.MAGIC))
        self.assertNotIn(jpg[:64], raw)                    # no plain JPEG on disk
        url = ev.snapshot.url
        self.assertIn("/api/v1/m/shop/", url)
        r = APIClient().get(url)                           # signed link: no auth header
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.content, jpg)
        self.assertEqual(r["Content-Type"], "image/jpeg")
        bad = APIClient().get(url[:-4] + "0000")
        self.assertEqual(bad.status_code, 404)

    def test_legacy_plain_file_is_sealed_on_first_access(self):
        ev = self.event()
        jpg = _jpeg(320, 200)
        os.makedirs(os.path.join(_MEDIA, "shop"), exist_ok=True)
        with open(os.path.join(_MEDIA, "shop", "legacy1.jpg"), "wb") as f:
            f.write(jpg)
        ev.snapshot.name = "shop/legacy1.jpg"
        ev.save(update_fields=["snapshot"])
        self.assertEqual(S.local_state("shop/legacy1.jpg"), "plain")
        r = APIClient().get(ev.snapshot.url)
        self.assertEqual(r.content, jpg)
        self.assertEqual(S.local_state("shop/legacy1.jpg"), "sealed")
        self.assertEqual(S.get("shop/legacy1.jpg"), jpg)

    def test_migrate_command_dry_run_then_real(self):
        from io import StringIO
        ev = self.event()
        os.makedirs(os.path.join(_MEDIA, "shop"), exist_ok=True)
        with open(os.path.join(_MEDIA, "shop", "legacy2.jpg"), "wb") as f:
            f.write(b"\xff\xd8plain-jpeg" * 20)
        ev.snapshot.name = "shop/legacy2.jpg"
        ev.save(update_fields=["snapshot"])
        out = StringIO()
        call_command("cctv_store_migrate", "--dry-run", stdout=out)
        self.assertIn("plain=1", out.getvalue())
        self.assertEqual(S.local_state("shop/legacy2.jpg"), "plain")   # nothing written
        out = StringIO()
        call_command("cctv_store_migrate", stdout=out)
        self.assertIn("done=1", out.getvalue())
        self.assertIn("failed=0", out.getvalue())
        self.assertEqual(S.get("shop/legacy2.jpg"), b"\xff\xd8plain-jpeg" * 20)

    def test_s3_backend_used_when_configured(self):
        store = {}

        def http(method, url, headers, body, timeout):
            key = url.split("/bkt/", 1)[1]
            if method == "PUT":
                store[key] = body
                return 200, b""
            if method in ("GET", "HEAD"):
                return (200, store[key]) if key in store else (404, b"")
            store.pop(key, None)
            return 204, b""
        S._http_override = http
        self.addCleanup(setattr, S, "_http_override", None)
        with override_settings(CCTV_S3_ENDPOINT="https://acc.r2.cloudflarestorage.com",
                               CCTV_S3_BUCKET="bkt", CCTV_S3_KEY_ID="k", CCTV_S3_SECRET="s"):
            ev = self.event()
            ev.snapshot.save("s3.jpg", ContentFile(b"jpegbytes" * 30), save=True)
            name = ev.snapshot.name
            self.assertIn(name, store)
            self.assertTrue(store[name].startswith(S.MAGIC))
            self.assertFalse(os.path.exists(os.path.join(_MEDIA, name)))   # not on server disk
            r = APIClient().get(ev.snapshot.url)
            self.assertEqual(r.content, b"jpegbytes" * 30)
            ev.snapshot.delete(save=True)
            self.assertNotIn(name, store)


class AddonApiTests(_E):
    def test_recording_state_and_buy_with_credits(self):
        cid = self.camobj.id
        r = self.client.get("/api/v1/shop/cameras/%d/recording" % cid)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertFalse(r.data["addon"]["active"])
        self.assertEqual([t["price_tk"] for t in r.data["addon"]["tiers"]], [100, 150])
        self.assertEqual(r.data["addon"]["tiers"][0]["play_product"], "cctv_video_7d")
        self.assertEqual(r.data["clips"]["max_per_day"], 30)
        self.assertFalse(r.data["clip_support"]["supported"])          # onvif: honest
        self.assertTrue(r.data["clip_support"]["text"])
        with mock.patch("core.shop_views._debit_camera_credits", return_value=0):
            r = self.client.post("/api/v1/shop/cameras/%d/video-addon" % cid,
                                 {"tier": "7d"}, format="json")
        self.assertEqual(r.status_code, 402)
        with mock.patch("core.shop_views._debit_camera_credits", side_effect=lambda u, n, note="": n):
            r = self.client.post("/api/v1/shop/cameras/%d/video-addon" % cid,
                                 {"tier": "30d"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertTrue(r.data["addon"]["active"])
        self.assertEqual(r.data["addon"]["tier"], "30d")
        self.assertEqual(r.data["addon"]["photo_days"], 7)              # site default 7
        r = self.client.post("/api/v1/shop/cameras/%d/video-addon" % cid,
                             {"tier": "90d"}, format="json")
        self.assertEqual(r.status_code, 422)

    def test_other_people_cannot_see_or_buy(self):
        stranger = User.objects.create_user(name="X", phone="01710009999", password="pw")
        c = APIClient()
        c.force_authenticate(stranger)
        self.assertEqual(c.get("/api/v1/shop/cameras/%d/recording" % self.camobj.id)
                         .status_code, 404)
        self.assertEqual(c.post("/api/v1/shop/cameras/%d/video-addon" % self.camobj.id,
                                {"tier": "7d"}, format="json").status_code, 404)

    def test_grant_extends_paid_days(self):
        a = self.grant("7d")
        first = a.active_until
        a = self.grant("7d")
        self.assertAlmostEqual((a.active_until - first).days, 30, delta=1)


class SdClipTests(_E):
    def setUp(self):
        super().setUp()
        p = mock.patch("core.cashguard_views.ezviz_on", return_value=True)
        p.start()
        self.addCleanup(p.stop)

    def test_person_alert_queues_fetches_seals_and_serves_clip(self):
        from core import cctv_evidence as CE
        self.ezviz_cam()
        self.grant("7d")
        ev = self.event()
        clip = CE.on_event(ev)
        self.assertEqual(clip.status, "pending")
        self.assertEqual(CE.run_sd_clips(timezone.now()), 0)           # not due yet
        ez = _FakeEz()
        n = CE.run_sd_clips(timezone.now() + timedelta(minutes=2), ezviz=ez, getter=_getter())
        self.assertEqual(n, 1)
        clip.refresh_from_db()
        self.assertEqual(clip.status, "ready", clip.reason)
        self.assertEqual(ez.calls[0][:2], ("ABC123", "1"))
        self.assertEqual(clip.size, 3 * 4096)
        self.assertAlmostEqual((clip.expires_at - timezone.now()).days, 7, delta=1)
        with open(os.path.join(_MEDIA, clip.name), "rb") as f:
            self.assertTrue(f.read().startswith(S.MAGIC))
        r = self.client.get("/api/v1/shop/events/%d/sd-clip" % ev.id)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["status"], "ready")
        body = APIClient().get(r.data["url"]).content
        import hashlib
        self.assertEqual(hashlib.sha256(body).hexdigest(), r.data["sha256"])
        # a stranger gets nothing
        c = APIClient()
        c.force_authenticate(User.objects.create_user(name="Y", phone="01710009998",
                                                      password="pw"))
        self.assertEqual(c.get("/api/v1/shop/events/%d/sd-clip" % ev.id).status_code, 404)
        # lifecycle delete after 7 days: bytes go, the hash stays
        name = clip.name
        self.assertTrue(S.exists(name))
        self.assertEqual(CE.purge_sd_clips(timezone.now() + timedelta(days=8)), 1)
        clip.refresh_from_db()
        self.assertEqual(clip.status, "expired")
        self.assertTrue(clip.sha256)
        self.assertFalse(S.exists(name))

    def test_no_recording_retries_then_fails_honestly(self):
        from core import cctv_evidence as CE
        self.ezviz_cam()
        self.grant()
        clip = CE.on_event(self.event())
        t = timezone.now()
        for i in range(CE.MAX_TRIES):
            t += timedelta(minutes=3)
            CE.run_sd_clips(t, ezviz=_FakeEz(url=""), getter=_getter())
        clip.refresh_from_db()
        self.assertEqual((clip.status, clip.reason), ("failed", "no_recording"))

    def test_imou_is_honestly_unsupported_and_no_addon_no_clip(self):
        from core import cctv_evidence as CE
        self.assertIsNone(CE.on_event(self.event()))                    # no add-on
        self.grant()
        self.camobj.vendor, self.camobj.vendor_ref = "imou", "6C0A1B:0"
        self.camobj.save()
        clip = CE.on_event(self.event())
        self.assertEqual((clip.status, clip.reason), ("unsupported", "imou_no_download"))
        r = self.client.get("/api/v1/shop/events/%d/sd-clip" % clip.event_id)
        self.assertIn("Imou", r.data["reason_text"])
        self.assertIsNone(CE.on_event(self.event("motion")))           # not a person alert

    def test_daily_cap_30_per_camera(self):
        from core import cctv_evidence as CE
        from core.models import ShopSdClip
        self.ezviz_cam()
        self.grant()
        for _ in range(30):
            ShopSdClip.objects.create(event=self.event(), camera=self.camobj, status="ready")
        clip = CE.on_event(self.event())
        self.assertEqual((clip.status, clip.reason), ("unsupported", "daily_cap"))

    def test_sd_health_ezviz_and_imou(self):
        from core import cctv_evidence as CE
        self.ezviz_cam()
        h = CE.sd_health(self.camobj, refresh=True, ezviz=_FakeEz())
        self.assertEqual(h["state"], "ok")
        self.assertIsNone(h["days"])                                    # EZVIZ: size not reported
        self.assertEqual(h["reason"], "size_not_reported")
        self.camobj.vendor, self.camobj.vendor_ref = "imou", "6C0A1B:0"
        self.camobj.save()
        h = CE.sd_health(self.camobj, refresh=True, imou=_FakeImou())
        self.assertEqual(h["state"], "ok")
        self.assertAlmostEqual(h["days"], 5.8, places=1)
        self.camobj.vendor, self.camobj.vendor_ref = "onvif", ""
        self.camobj.save()
        h = CE.sd_health(self.camobj, refresh=True)
        self.assertEqual((h["state"], h["reason"]), ("unknown", "vendor_no_api"))


class LifecycleTests(_E):
    def test_photos_base_7_days_30_with_addon(self):
        from core.management.commands.shop_prune_snapshots import prune
        self.sobj.snapshot_retention_days = 30
        self.sobj.save()
        ev = self.event(days_old=8)
        ev.snapshot.save("old.jpg", ContentFile(_jpeg(64, 64)), save=True)
        self.grant("30d")
        prune()
        ev.refresh_from_db()
        self.assertTrue(ev.snapshot)                                    # 30-day add-on keeps it
        self.camobj.video_addon.delete()
        name = ev.snapshot.name
        prune()
        ev.refresh_from_db()
        self.assertFalse(ev.snapshot)                                   # base: 7 days
        self.assertFalse(S.exists(name))

    def test_cash_clip_kept_for_addon_days_and_not_dropped_on_view(self):
        from core.models import ShopEventClip
        self.grant("7d")
        ref = "c3" * 16
        r = self.ingest(ref=ref)
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(self.upload(ref).status_code, 201)
        clip = ShopEventClip.objects.get()
        self.assertAlmostEqual((clip.expires_at - clip.created).total_seconds(),
                               7 * 86400, delta=5)
        v = self.client.post("/api/v1/shop/events/%d/clip/viewed" % clip.event_id, {},
                             format="json")
        self.assertFalse(v.data["deleted"])
        with open(clip.blob.path, "rb") as f:
            self.assertTrue(f.read().startswith(S.MAGIC))               # sealed at rest too


class EvidenceFactsTests(_E):
    def test_address_privacy_and_sd_clip_in_evidence(self):
        r = self.client.put("/api/v1/shop/sites/%d/address" % self.sobj.id,
                            {"address": "  12 Mirpur Road,\n Dhaka  "}, format="json")
        self.assertEqual(r.data["address"], "12 Mirpur Road, Dhaka")
        ev = self.event()
        r = self.client.get("/api/v1/shop/events/%d/evidence" % ev.id)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["facts"]["address"], "12 Mirpur Road, Dhaka")
        self.assertIn("12 Mirpur Road", r.data["gd_draft"])
        self.assertIn("police", r.data["privacy_en"])
        self.assertIn("পুলিশ", r.data["privacy_bn"])
        self.assertIsNone(r.data["sd_clip"])
        other = APIClient()
        other.force_authenticate(self.family)
        self.assertEqual(other.put("/api/v1/shop/sites/%d/address" % self.sobj.id,
                                   {"address": "x"}, format="json").status_code, 404)
