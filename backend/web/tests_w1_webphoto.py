"""w1-webphoto: lifeassisto.com/photo funnel — watermarked web preview, clean
file only via the logged-in app (Photo Studio export gate), <= 1 hour expiry."""
import base64
import io
import os
import re
import shutil
import tempfile
from datetime import timedelta

from django.core.management import call_command
from django.test import Client, TestCase, override_settings
from django.urls import URLPattern, get_resolver
from django.utils import timezone
from PIL import Image, ImageChops, ImageStat
from rest_framework.test import APIClient

from core.models import PhotoStudioJob, ToolUsage, User, WebPhotoDrop
from web.logic import photo as photologic
from web.logic import webphoto as W
from web import views as webviews

ANDROID_UA = ("Mozilla/5.0 (Linux; Android 13; RMX3491) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/129.0 Mobile Safari/537.36")


def _face_img(w=900, h=1200):
    """A synthetic portrait with real detail (gradient + 'face' ellipse)."""
    from PIL import ImageDraw
    im = Image.new("RGB", (w, h), (235, 235, 235))
    d = ImageDraw.Draw(im)
    for y in range(0, h, 6):
        d.line([(0, y), (w, y)], fill=(200 + y % 40, 190, 180 - y % 30))
    d.ellipse([w * 0.3, h * 0.2, w * 0.7, h * 0.6], fill=(190, 140, 110))
    d.ellipse([w * 0.4, h * 0.33, w * 0.45, h * 0.37], fill=(30, 30, 30))
    d.ellipse([w * 0.55, h * 0.33, w * 0.6, h * 0.37], fill=(30, 30, 30))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=95)
    return buf.getvalue()


def _upload(name="me.jpg"):
    from django.core.files.uploadedfile import SimpleUploadedFile
    return SimpleUploadedFile(name, _face_img(), content_type="image/jpeg")


def _data_uris(html):
    return re.findall(r"data:image/[a-z]+;base64,([A-Za-z0-9+/=]+)", html)


class _Media(TestCase):
    def setUp(self):
        self.media = tempfile.mkdtemp(prefix="w1wp-")
        self._o = override_settings(MEDIA_ROOT=self.media)
        self._o.enable()
        self.addCleanup(self._o.disable)
        self.addCleanup(shutil.rmtree, self.media, True)
        self.c = Client(HTTP_USER_AGENT=ANDROID_UA)

    def make(self, preset="bd_passport", lang=""):
        url = "/photo" + ("?lang=en" if lang == "en" else "")
        r = self.c.post(url, {"photo": _upload(), "preset": preset})
        self.assertEqual(r.status_code, 200)
        return r, WebPhotoDrop.objects.order_by("-id").first()

    def media_files(self):
        return [os.path.join(dp, f) for dp, _d, fs in os.walk(self.media) for f in fs]


class WebPreviewTests(_Media):
    def test_result_shows_only_a_small_watermarked_preview(self):
        r, drop = self.make()
        html = r.content.decode()
        clean = bytes(drop.image)
        clean_im = Image.open(io.BytesIO(clean))
        self.assertEqual(clean_im.size, (413, 531))           # BD e-passport, 300 dpi
        uris = _data_uris(html)
        self.assertEqual(len(uris), 1, "exactly one inline image: the preview")
        prev = base64.b64decode(uris[0])
        self.assertNotEqual(prev, clean)
        pim = Image.open(io.BytesIO(prev)).convert("RGB")
        self.assertLessEqual(max(pim.size), W.PREVIEW_MAX_PX)
        self.assertLess(pim.size[0], clean_im.size[0])
        # watermark across the face area: compare with a plain resize of the clean file
        ref = clean_im.convert("RGB").resize(pim.size, Image.LANCZOS)
        w, h = pim.size
        band = (0, int(h * 0.36), w, int(h * 0.48))
        diff = ImageStat.Stat(ImageChops.difference(pim.crop(band), ref.crop(band))).mean
        self.assertGreater(sum(diff) / 3, 25, "visible watermark band over the face")
        self.assertIn("ASSISTO PREVIEW", W.WATERMARK)
        # no download of anything, no print sheet, no clean bytes
        self.assertNotIn("download=", html)
        self.assertNotIn(base64.b64encode(clean).decode()[:200], html)
        self.assertNotIn("/media/", html)

    def test_clean_file_never_on_disk_or_in_media(self):
        self.make()
        self.assertEqual(self.media_files(), [])

    def test_no_web_route_ever_serves_the_clean_bytes(self):
        r, drop = self.make()
        clean = bytes(drop.image)
        needle_b64 = base64.b64encode(clean).decode()[:120]
        needle_raw = clean[200:400]
        token = drop.token
        checked = 0
        for p in get_resolver("web.urls").url_patterns:
            if not isinstance(p, URLPattern):
                continue
            route = "/" + str(p.pattern)
            if "<" in route or route.startswith("/owner"):
                continue
            for q in ("", "?t=%s" % token, "?t=%s&lang=en" % token):
                for method in ("get", "post"):
                    resp = getattr(self.c, method)(route + q)
                    body = resp.content if not getattr(resp, "streaming", False) \
                        else b"".join(resp.streaming_content)
                    self.assertNotIn(needle_raw, body, route + q)
                    self.assertNotIn(needle_b64.encode(), body, route + q)
                    for u in _data_uris(body.decode("utf-8", "ignore")):
                        self.assertNotEqual(base64.b64decode(u), clean, route)
                    checked += 1
        self.assertGreater(checked, 20)
        # the drop is still there (only the logged-in app may take it)
        self.assertTrue(WebPhotoDrop.objects.filter(token=token).exists())

    def test_deep_link_android_intent_and_https(self):
        r, drop = self.make()
        html = r.content.decode()
        self.assertIn("intent://lifeassisto.com/photo/app?t=%s" % drop.token, html)
        self.assertIn("package=com.assisto.assisto", html)
        self.assertIn("S.browser_fallback_url=https%3A%2F%2Flifeassisto.com%2Fphoto%2Fapp", html)
        desk = Client().post("/photo", {"photo": _upload(), "preset": "us_visa"})
        d2 = WebPhotoDrop.objects.order_by("-id").first()
        self.assertContains(desk, 'href="https://lifeassisto.com/photo/app?t=%s"' % d2.token)
        self.assertEqual(r["Referrer-Policy"], "no-referrer")
        self.assertEqual(r["Cache-Control"], "no-store")

    def test_token_is_unguessable_and_expires_within_an_hour(self):
        _r, drop = self.make()
        self.assertGreaterEqual(len(drop.token), 43)
        self.assertLessEqual(drop.expires_at - drop.created_at, timedelta(hours=1))
        self.assertLessEqual(W.ttl(), timedelta(hours=1))
        with mock_ttl(500):
            self.assertLessEqual(W.ttl(), timedelta(hours=1))

    def test_app_page_valid_then_expired_deletes_on_access(self):
        _r, drop = self.make()
        r = self.c.get("/photo/app?t=%s" % drop.token)
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Photo Studio")
        self.assertContains(r, "intent://")
        self.assertContains(r, 'name="robots" content="noindex"')
        WebPhotoDrop.objects.filter(pk=drop.pk).update(
            expires_at=timezone.now() - timedelta(seconds=1))
        r = self.c.get("/photo/app?t=%s&lang=en" % drop.token)
        self.assertContains(r, "expired")
        self.assertFalse(WebPhotoDrop.objects.filter(pk=drop.pk).exists())

    def test_purge_command_deletes_only_expired(self):
        old = WebPhotoDrop.objects.create(token="a" * 43, preset="bd_passport", image=b"x",
                                          expires_at=timezone.now() - timedelta(minutes=1))
        fresh = WebPhotoDrop.objects.create(token="b" * 43, preset="bd_passport", image=b"y",
                                            expires_at=timezone.now() + timedelta(minutes=30))
        out = io.StringIO()
        call_command("purge_web_photos", stdout=out)
        self.assertIn("deleted 1", out.getvalue())
        self.assertFalse(WebPhotoDrop.objects.filter(pk=old.pk).exists())
        self.assertTrue(WebPhotoDrop.objects.filter(pk=fresh.pk).exists())
        # ... and an hour later nothing is left
        call_command("purge_web_photos", stdout=io.StringIO())
        n = W.purge_expired(now=timezone.now() + timedelta(hours=1, seconds=1))
        self.assertEqual(n, 1)
        self.assertEqual(WebPhotoDrop.objects.count(), 0)

    def test_new_upload_sweeps_expired(self):
        WebPhotoDrop.objects.create(token="c" * 43, preset="bd_passport", image=b"x",
                                    expires_at=timezone.now() - timedelta(minutes=1))
        self.make()
        self.assertFalse(WebPhotoDrop.objects.filter(token="c" * 43).exists())

    def test_rate_limit_per_ip(self):
        h = webviews._ip_hash(self.c.get("/photo").wsgi_request)
        for _ in range(webviews.PHOTO_RATE_PER_HOUR):
            ToolUsage.objects.create(tool="w3", ip_hash=h)
        r = self.c.post("/photo", {"photo": _upload(), "preset": "bd_passport"})
        self.assertEqual(r.status_code, 429)
        self.assertEqual(WebPhotoDrop.objects.count(), 0)
        # another IP is unaffected
        other = Client(REMOTE_ADDR="10.9.8.7")
        self.assertEqual(other.post("/photo", {"photo": _upload()}).status_code, 200)

    def test_bad_preset_falls_back(self):
        _r, drop = self.make(preset="nope")
        self.assertEqual(drop.preset, "bd_passport")


class mock_ttl:
    def __init__(self, v):
        self.v = v

    def __enter__(self):
        self.old = W.TTL_MIN
        W.TTL_MIN = self.v

    def __exit__(self, *a):
        W.TTL_MIN = self.old


class SeoTests(TestCase):
    def test_bn_page(self):
        r = Client().get("/photo")
        html = r.content.decode()
        self.assertIn('<html lang="bn">', html)
        self.assertIn("<title>পাসপোর্ট সাইজ ছবি", html)
        self.assertIn('<meta name="description" content="বাংলাদেশ পাসপোর্ট', html)
        self.assertIn('<link rel="canonical" href="https://lifeassisto.com/photo">', html)
        self.assertIn('hreflang="bn" href="https://lifeassisto.com/photo"', html)
        self.assertIn('hreflang="en" href="https://lifeassisto.com/photo?lang=en"', html)
        self.assertIn('hreflang="x-default"', html)
        self.assertEqual(html.count("<h1"), 1)
        self.assertGreaterEqual(html.count("<h2"), 4)
        self.assertIn("গোপনীয়তা", html)
        self.assertIn("১ ঘণ্টা", html)
        for size in ("35×45 mm", "45×55 mm", "2×2 inch", "600×600", "413×531", "531×650"):
            self.assertIn(size, html)
        self.assertNotIn("<script", html)        # no JS at all: fast, mobile-first
        self.assertIn('name="viewport"', html)

    def test_en_page(self):
        r = Client().get("/photo?lang=en")
        html = r.content.decode()
        self.assertIn('<html lang="en">', html)
        self.assertIn("Passport Photo Bangladesh", html)
        self.assertIn('<meta name="description" content="Make a passport photo for Bangladesh', html)
        self.assertIn('<link rel="canonical" href="https://lifeassisto.com/photo?lang=en">', html)
        self.assertIn('hreflang="bn"', html)
        self.assertIn("Privacy", html)
        self.assertIn("1 hour", html)
        self.assertIn("Bangladesh passport &amp; visa photo sizes", html)

    def test_presets_match_their_pixels(self):
        # 300 dpi: 35x45 mm = 413x531, 45x55 mm = 531x650, 2 in = 600 px
        mm = lambda v: round(v / 25.4 * 300)  # noqa: E731
        p = photologic.PRESETS
        self.assertEqual((p["bd_passport"][2], p["bd_passport"][3]), (mm(35), mm(45)))
        self.assertEqual((p["schengen"][2], p["schengen"][3]), (mm(35), mm(45)))
        self.assertEqual((p["bd_mrp"][2], p["bd_mrp"][3]), (mm(45), mm(55)))
        self.assertEqual((p["passport_2x2"][2], p["passport_2x2"][3]), (600, 600))
        for k in p:
            self.assertIn(k, photologic.PRESET_NOTES["bn"])
            self.assertIn(k, photologic.PRESET_NOTES["en"])


class AssetLinksTests(TestCase):
    def test_empty_without_fingerprint(self):
        with override_settings(ANDROID_CERT_SHA256=""):
            os.environ.pop("ANDROID_CERT_SHA256", None)
            r = Client().get("/.well-known/assetlinks.json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json(), [])

    def test_with_fingerprint(self):
        fp = "AB:CD:" + ":".join(["00"] * 30)
        with override_settings(ANDROID_CERT_SHA256=fp.lower()):
            r = Client().get("/.well-known/assetlinks.json")
        j = r.json()
        self.assertEqual(j[0]["target"]["package_name"], "com.assisto.assisto")
        self.assertEqual(j[0]["target"]["sha256_cert_fingerprints"], [fp])


class ClaimTests(_Media):
    def setUp(self):
        super().setUp()
        self.free = User.objects.create_user(name="F", phone="01710000951", password="pw")
        self.free.plan = "free"
        self.free.trial_until = None
        self.free.save()
        self.prem = User.objects.create_user(name="P", phone="01710000952", password="pw")
        self.prem.plan = "premium"
        self.prem.plan_until = timezone.now() + timedelta(days=30)
        self.prem.save()
        self.api = APIClient()

    def claim(self, token, user=None):
        if user is not None:
            self.api.force_authenticate(user)
        return self.api.post("/api/v1/web-photo/claim", {"token": token}, format="json")

    def test_login_required(self):
        _r, drop = self.make()
        r = APIClient().post("/api/v1/web-photo/claim", {"token": drop.token}, format="json")
        self.assertIn(r.status_code, (401, 403))
        self.assertTrue(WebPhotoDrop.objects.filter(pk=drop.pk).exists())

    def test_free_user_claims_once_and_export_stays_gated(self):
        _r, drop = self.make()
        clean = bytes(drop.image)
        r = self.claim(drop.token, self.free)
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertTrue(j["ok"])
        self.assertEqual(j["preset"], "bd_passport")
        self.assertEqual(j["studio_option"], "passport_bd")
        job = PhotoStudioJob.objects.get(pk=j["job"]["id"])
        self.assertEqual(job.user, self.free)
        self.assertEqual(job.feature, "enhance_hd")
        self.assertEqual(job.status, "awaiting_funds")
        self.assertEqual(job.funding, "ads")
        self.assertGreater(job.ads_required, 0)
        self.assertEqual(job.options["source"], "web_photo")
        self.assertEqual(job.options["options"], ["passport_bd"])
        self.assertTrue(j["job"].get("preview"))
        self.assertNotIn(base64.b64encode(clean).decode()[:120], r.content.decode())
        self.assertNotIn("result", j["job"])
        # gone from the web store; a second claim is refused
        self.assertFalse(WebPhotoDrop.objects.filter(pk=drop.pk).exists())
        self.assertEqual(self.claim(drop.token).status_code, 410)
        # THE export gate: locked until ads/credits
        u = self.api.post("/api/v1/photo-studio/jobs/%d/unlock" % job.pk,
                          {"kind": "save"}, format="json")
        self.assertEqual(u.status_code, 402)
        # the stored result is the same clean photo
        with open(os.path.join(self.media, job.result_name), "rb") as fh:
            self.assertEqual(fh.read(), clean)
        # the free preview is watermarked (not the clean file)
        with open(os.path.join(self.media, job.preview_name), "rb") as fh:
            pv = Image.open(io.BytesIO(fh.read())).convert("RGB")
        self.assertLessEqual(max(pv.size), W.APP_PREVIEW_MAX_PX)
        ref = Image.open(io.BytesIO(clean)).convert("RGB").resize(pv.size)
        w, h = pv.size
        band = (0, int(h * 0.36), w, int(h * 0.48))
        diff = ImageStat.Stat(ImageChops.difference(pv.crop(band), ref.crop(band))).mean
        self.assertGreater(sum(diff) / 3, 25)

    def test_premium_user_exports_clean_through_the_gate(self):
        _r, drop = self.make(preset="us_visa")
        r = self.claim(drop.token, self.prem)
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertEqual(j["studio_option"], "visa_bd")
        job = PhotoStudioJob.objects.get(pk=j["job"]["id"])
        self.assertEqual(job.status, "funded")
        u = self.api.post("/api/v1/photo-studio/jobs/%d/unlock" % job.pk,
                          {"kind": "save"}, format="json")
        self.assertEqual(u.status_code, 200)
        self.assertFalse(u.json()["corner_mark"])
        self.assertTrue(u.json()["result"].startswith("/api/v1/m/"))

    def test_expired_token_refused_and_deleted(self):
        _r, drop = self.make()
        WebPhotoDrop.objects.filter(pk=drop.pk).update(
            expires_at=timezone.now() - timedelta(seconds=1))
        r = self.claim(drop.token, self.free)
        self.assertEqual(r.status_code, 410)
        self.assertEqual(r.json()["reason"], "expired")
        self.assertTrue(r.json()["message"])
        self.assertFalse(WebPhotoDrop.objects.filter(pk=drop.pk).exists())
        self.assertEqual(PhotoStudioJob.objects.count(), 0)

    def test_unknown_or_bad_token(self):
        self.assertEqual(self.claim("nope", self.free).status_code, 410)
        self.assertEqual(self.claim("x" * 500).status_code, 410)
        self.assertEqual(self.claim("").status_code, 410)
