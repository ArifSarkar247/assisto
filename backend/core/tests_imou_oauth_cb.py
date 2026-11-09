from django.core.cache import cache
from django.test import TestCase


class ImouOAuthCallbackTests(TestCase):
    URL = "/api/v1/cctv/imou/oauth/callback"

    def test_keeps_code_under_state(self):
        r = self.client.get(self.URL, {"code": "abc123", "state": "st-1_x"})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(cache.get("imou_oauth:st-1_x"), "abc123")
        self.assertEqual(r["Cache-Control"], "no-store")

    def test_missing_or_bad_state(self):
        self.assertEqual(self.client.get(self.URL, {"code": "abc"}).status_code, 400)
        self.assertEqual(self.client.get(self.URL, {"code": "a", "state": "x;y"}).status_code, 400)
