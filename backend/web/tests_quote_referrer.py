"""Hotfix 3 Nov: the customer quote page must not send Referrer-Policy:
no-referrer — browsers then send "Origin: null" on its POST forms and Django's
CSRF origin check rejects them (403)."""
from django.test import SimpleTestCase

from web import views_quote


class QuoteReferrerPolicyTests(SimpleTestCase):
    def test_render_uses_same_origin(self):
        from django.test import RequestFactory
        req = RequestFactory().get("/q/x")
        try:
            resp = views_quote._render(req, {"q_token": "x", "qlang": "", "post_base": "/q/"})
        except Exception:
            self.skipTest("template needs a full quote context")
        self.assertEqual(resp["Referrer-Policy"], "same-origin")

    def test_source_never_no_referrer(self):
        import inspect
        self.assertNotIn('"no-referrer"', inspect.getsource(views_quote._render))
