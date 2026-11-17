"""cctvtoday: the Shop Box PC program download path (GitHub release
manifest -> API + lifeassisto.com/get), never trusting odd manifest fields."""
from unittest import mock

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core.logic import shopbox_release as SBR

GOOD = {"version": "0.1.0+57", "sha256": "a" * 64, "size_bytes": 157286400,
        "built_at": "2026-11-09T09:00Z", "signed": False}


class CleanTests(SimpleTestCase):
    def test_good_manifest(self):
        c = SBR.clean(GOOD)
        self.assertTrue(c["available"])
        self.assertEqual((c["version"], c["sha256"], c["size_mb"]), ("0.1.0+57", "a" * 64, 150.0))
        self.assertEqual(c["url"], SBR.ZIP_URL)

    def test_bad_fields_never_shown(self):
        for bad in (None, [], {"version": "<script>", "sha256": "a" * 64},
                    {"version": "1", "sha256": "xyz"}, dict(GOOD, sha256="A" * 63)):
            c = SBR.clean(bad)
            self.assertFalse(c["available"], bad)
            self.assertNotIn("sha256", c)
            self.assertEqual(c["url"], SBR.ZIP_URL)   # the plain link always stays


class EndpointAndPageTests(TestCase):
    def setUp(self):
        cache.delete(SBR.CACHE_KEY)
        self.addCleanup(cache.delete, SBR.CACHE_KEY)

    def test_api_without_login(self):
        with mock.patch.object(SBR, "latest", return_value=SBR.clean(GOOD)):
            r = APIClient().get("/api/v1/shop/shopbox/download")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["sha256"], "a" * 64)
        self.assertTrue(r.data["page"].endswith("/get#shopbox"))

    def test_fetch_failure_keeps_the_link(self):
        def boom():
            raise OSError("offline")
        c = SBR.latest(fetch=boom)
        self.assertFalse(c["available"])
        self.assertEqual(c["url"], SBR.ZIP_URL)

    def test_get_page_shows_download_sha_and_smartscreen_note(self):
        cache.set(SBR.CACHE_KEY, SBR.clean(GOOD), 60)
        for q, words in (("?lang=en", ["Download for Windows PC", "SmartScreen"]),
                         ("", ["Windows পিসির জন্য ডাউনলোড", "SmartScreen"])):
            r = self.client.get("/get" + q)
            self.assertEqual(r.status_code, 200)
            html = r.content.decode()
            self.assertIn('id="shopbox"', html)
            self.assertIn(SBR.ZIP_URL, html)
            self.assertIn("a" * 64, html)
            for w in words:
                self.assertIn(w, html)
