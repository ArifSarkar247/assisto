"""Private uploads are only reachable through short-lived signed links."""
import os
import time
from urllib.parse import urlparse, parse_qs

from django.conf import settings
from django.core.files.base import ContentFile
from django.core.files.storage import default_storage
from django.test import TestCase

from core import media_sign as MS


class SignedMediaTests(TestCase):
    def setUp(self):
        self.name = default_storage.save("vault/test_signed.txt", ContentFile(b"secret-doc"))

    def tearDown(self):
        default_storage.delete(self.name)

    def test_field_url_is_signed_and_serves(self):
        url = default_storage.url(self.name)
        self.assertTrue(url.startswith("/api/v1/m/vault/"))
        self.assertNotIn("/media/", url)
        r = self.client.get(url)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(b"".join(r.streaming_content), b"secret-doc")
        self.assertIn("private", r["Cache-Control"])

    def test_url_stable_within_hour(self):
        t = 1_800_000_000
        self.assertEqual(MS.signed_url(self.name, t), MS.signed_url(self.name, t + 60))

    def test_tampered_missing_expired_404(self):
        url = default_storage.url(self.name)
        q = parse_qs(urlparse(url).query)
        base = urlparse(url).path
        self.assertEqual(self.client.get(base).status_code, 404)
        self.assertEqual(self.client.get(base + "?e=%s&s=%s" % (q["e"][0], "0" * 32)).status_code, 404)
        other = base.replace("test_signed", "other")
        self.assertEqual(self.client.get(other + "?e=%s&s=%s" % (q["e"][0], q["s"][0])).status_code, 404)
        old = int(time.time()) - 3 * 3600
        self.assertFalse(MS.verify(self.name, old, MS._sig(self.name, old)))

    def test_traversal_rejected(self):
        exp = int(time.time()) + 3600
        for bad in ("../settings.py", "vault/../../manage.py"):
            r = self.client.get("/api/v1/m/%s?e=%d&s=%s" % (bad, exp, MS._sig(bad, exp)))
            self.assertEqual(r.status_code, 404)

    def test_x_accel_in_production(self):
        with self.settings(MEDIA_X_ACCEL=True):
            r = self.client.get(default_storage.url(self.name))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["X-Accel-Redirect"], "/protected-media/" + self.name)
