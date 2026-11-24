"""owner 24 Nov: HalalAdz ads on the public website only — ads.txt line, the
tag once in <head> of public pages, never on payment / account / safety pages."""
from django.test import TestCase

TAG = ('<script async src="https://cdn.halaladz.com/ad.js" data-hz-auto="on" '
       'data-hz-auto-key="pk_live_5c034bb3694f531794b6282a"></script>')  # gitleaks:allow (public site key)


class HalalAdzWebTests(TestCase):
    def test_ads_txt(self):
        r = self.client.get("/ads.txt")
        self.assertEqual(r.status_code, 200)
        self.assertIn("halaladz.com, pub-12, DIRECT", r.content.decode())
        self.assertTrue(r["Content-Type"].startswith("text/plain"))

    def _html(self, path):
        r = self.client.get(path, follow=True)
        self.assertEqual(r.status_code, 200, path)
        return r.content.decode()

    def test_tag_once_in_head_of_public_pages(self):
        for path in ("/", "/pricing", "/privacy", "/blog"):
            h = self._html(path)
            self.assertEqual(h.count(TAG), 1, path)
            self.assertLess(h.index(TAG), h.index("</head>"), path)

    def test_no_tag_on_payment_account_pages(self):
        for path in ("/premium", "/pay/return", "/delete-account"):
            self.assertNotIn("cdn.halaladz.com", self._html(path), path)
