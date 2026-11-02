"""admobump (owner 2 Nov) — lifeassisto.com/app-ads.txt built ONLY from the
AdMob publisher id stored in Owner Admin -> Integrations (never from git),
validated on save (owner-only), text/plain, short cache, 404 when unset."""
import os
from unittest import mock

from django.test import Client, SimpleTestCase, TestCase

from core.logic.ads import normalize_publisher_id
from web.tests_o2_owner_admin import OwnerBase

LINE = "google.com, {}, DIRECT, f08c47fec0942fa0"


class NormalizePublisherIdTests(SimpleTestCase):
    def test_valid_forms(self):
        self.assertEqual(normalize_publisher_id("pub-1234567890123456"), "pub-1234567890123456")
        self.assertEqual(normalize_publisher_id("  pub-1234567890123456 "), "pub-1234567890123456")
        self.assertEqual(normalize_publisher_id("ca-app-pub-1234567890123456"),
                         "pub-1234567890123456")

    def test_invalid_forms(self):
        for raw in ("", None, "pub-123", "pub-12345678901234567", "PUB-1234567890123456",
                    "pub-1234567890123456~123", "ca-app-pub-1234567890123456/99",
                    "google.com, pub-1234567890123456, DIRECT, f08c47fec0942fa0",
                    "pub-3940256099942544",            # Google's public test publisher
                    "hello"):
            self.assertEqual(normalize_publisher_id(raw), "", raw)


class AppAdsViewTests(TestCase):
    def setUp(self):
        self.c = Client()

    def get(self, cfg):
        with mock.patch("core.integrations.get", return_value=cfg):
            return self.c.get("/app-ads.txt")

    def test_unset_is_404_text_plain_not_empty_200(self):
        r = self.get({})
        self.assertEqual(r.status_code, 404)
        self.assertTrue(r["Content-Type"].startswith("text/plain"))
        self.assertEqual(r["Cache-Control"], "no-store")
        self.assertNotIn("google.com", r.content.decode())

    def test_publisher_id_line_exact(self):
        r = self.get({"publisher_id": "pub-4545454545454545"})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "text/plain; charset=utf-8")
        self.assertEqual(r["Cache-Control"], "public, max-age=600")
        rows = [l for l in r.content.decode().splitlines() if l and not l.startswith("#")]
        self.assertEqual(rows, [LINE.format("pub-4545454545454545")])

    def test_publisher_id_wins_over_app_id(self):
        r = self.get({"publisher_id": "pub-4545454545454545",
                      "app_id": "ca-app-pub-7777777777777777~1234567"})
        body = r.content.decode()
        self.assertIn("pub-4545454545454545", body)
        self.assertNotIn("7777777777777777", body)

    def test_derived_from_stored_app_id(self):
        r = self.get({"app_id": "ca-app-pub-7777777777777777~1234567"})
        self.assertIn(LINE.format("pub-7777777777777777"), r.content.decode())

    def test_owner_panel_beats_server_env(self):
        with mock.patch.dict(os.environ, {"ADMOB_PUBLISHER_ID": "pub-1111111111111111"}):
            r = self.get({"publisher_id": "pub-4545454545454545"})
        self.assertIn("pub-4545454545454545", r.content.decode())
        self.assertNotIn("1111111111111111", r.content.decode())

    def test_no_fernet_key_falls_back_to_404(self):
        with mock.patch("core.integrations.get", side_effect=RuntimeError("no key")):
            r = self.c.get("/app-ads.txt")
        self.assertEqual(r.status_code, 404)

    def test_no_publisher_id_in_git(self):
        # the old hard-coded fallback is gone for good
        import core.logic.ads as A
        import web.views_legal as V
        self.assertFalse(hasattr(A, "OWNER_PUBLISHER"))
        src = open(V.__file__, encoding="utf-8").read()
        self.assertNotIn("2506398550427515", src)


class PublisherFieldOwnerTests(OwnerBase):
    """Owner Admin -> Integrations -> Google AdMob -> Publisher ID."""

    def setUp(self):
        super().setUp()
        from cryptography.fernet import Fernet
        from core import integrations as I
        self._env = mock.patch.dict(os.environ,
                                    {"INTEGRATIONS_FERNET_KEY": Fernet.generate_key().decode()})
        self._env.start()
        I._FERNET = None
        self.addCleanup(self._cleanup)
        self.ready()

    def _cleanup(self):
        from core import integrations as I
        self._env.stop()
        I._FERNET = None

    def save(self, pub):
        return self.post("/owner/integrations",
                         {"slug": "admob", "action": "save", "publisher_id": pub})

    def test_valid_id_saved_and_served(self):
        from core import integrations as I
        r = self.save("ca-app-pub-9898989898989898")
        self.assertEqual(r.status_code, 302)
        self.assertNotIn("m=invalid", r["Location"])
        self.assertEqual(I.get("admob")["publisher_id"], "pub-9898989898989898")
        body = Client().get("/app-ads.txt").content.decode()
        self.assertIn(LINE.format("pub-9898989898989898"), body)

    def test_bad_format_refused_nothing_stored(self):
        from core import integrations as I
        for bad in ("pub-123", "hello", "pub-3940256099942544"):
            r = self.save(bad)
            self.assertEqual(r.status_code, 302)
            self.assertIn("m=invalid", r["Location"], bad)
        self.assertNotIn("publisher_id", I.get("admob"))
        self.assertEqual(Client().get("/app-ads.txt").status_code, 404)

    def test_owner_only(self):
        # a signed-out visitor cannot set it
        r = Client().post("/owner/integrations",
                          {"slug": "admob", "action": "save",
                           "publisher_id": "pub-9898989898989898"}, secure=True)
        self.assertIn(r.status_code, (302, 403))
        from core import integrations as I
        self.assertNotIn("publisher_id", I.get("admob"))
