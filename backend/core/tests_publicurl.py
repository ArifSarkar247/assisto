"""publicurl (owner P0, 17 Nov): the Owner Admin DoLynk card showed the
Message Subscription callback as http://127.0.0.1:8700/... — DoLynk (and
Imou, and every email / recovery link) could never reach it, because
settings.ASSISTO_BASE_URL defaulted to localhost in production.

Proves:
1. production default = https://api.lifeassisto.com (DEBUG off, env unset);
   DEBUG keeps the local default; the guard (system check) refuses http /
   localhost in production and is off in tests;
2. every vendor callback link (DoLynk, ARC, Imou) and the email / recovery /
   retention links are https://api.lifeassisto.com/...;
3. rotation: the new link works, the old one answers 404 at once; only the
   callback salt changes, never the vendor API keys; nothing secret printed;
4. a SIGNED DoLynk push (Event message format, sign = HMAC-SHA512(id, SK))
   to the rotated link raises the alert end to end;
5. cctv_callback_selftest: a signed TEST message is received and marked as
   a test (no alert, no push, no event);
6. Owner Admin: the card shows the https link and an owner-only Rotate
   button (with an "I understand" tick), audited.
7. no link builder reads settings.ASSISTO_BASE_URL directly any more.
Synthetic data only.
"""
import io
import json
import os
import re
import runpy
import time
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet
from django.core.management import call_command
from django.test import SimpleTestCase, TestCase, override_settings
from rest_framework.test import APIClient

from core import callback_links as CL
from core import integrations
from core import public_url as PU
from core import tests_dolynkreal as TR
from core import tests_e2e_cctv as E2E
from core.logic.cctv_connect import mocks as M

PUB = "https://api.lifeassisto.com"
_KEY = Fernet.generate_key().decode()


def setUpModule():
    os.environ["INTEGRATIONS_FERNET_KEY"] = _KEY
    integrations._FERNET = None


def tearDownModule():
    integrations._FERNET = None


def _enable(slug, cfg):
    TR._enable(slug, cfg)


def _poster(url, body):
    """cctv_callback_selftest's HTTP post, routed to the test server."""
    path = url[url.index("/api/v1/"):]
    r = APIClient().post(path, json.dumps([body]), content_type="application/json")
    try:
        data = r.json()
    except ValueError:
        data = {}
    return r.status_code, data


def _path(url):
    return url[url.index("/api/v1/"):]


class SettingsDefaultTests(SimpleTestCase):
    def _load(self, env):
        keep = {k: v for k, v in os.environ.items()
                if k not in ("ASSISTO_BASE_URL", "DJANGO_DEBUG", "ASSISTO_PUBLIC_URL_GUARD",
                             "DJANGO_CSRF_TRUSTED_ORIGINS")}
        keep.update(env)
        path = Path(__file__).resolve().parent.parent / "assisto_backend" / "settings.py"
        with mock.patch.dict(os.environ, keep, clear=True), \
                mock.patch("dotenv.load_dotenv", return_value=False):
            return runpy.run_path(str(path))

    def test_production_default_is_public_https(self):
        s = self._load({})
        self.assertFalse(s["DEBUG"])
        self.assertEqual(s["ASSISTO_BASE_URL"], PUB)
        self.assertTrue(s["PUBLIC_URL_GUARD"])
        self.assertIn(PUB, s["CSRF_TRUSTED_ORIGINS"])
        self.assertIn("http://127.0.0.1:8700", s["CSRF_TRUSTED_ORIGINS"])   # nothing lost
        self.assertIsNone(PU.problem(s["ASSISTO_BASE_URL"]))

    def test_debug_keeps_local_and_env_wins(self):
        s = self._load({"DJANGO_DEBUG": "1"})
        self.assertEqual(s["ASSISTO_BASE_URL"], "http://127.0.0.1:8700")
        self.assertFalse(s["PUBLIC_URL_GUARD"])
        s = self._load({"ASSISTO_BASE_URL": "https://example.test"})
        self.assertEqual(s["ASSISTO_BASE_URL"], "https://example.test")


class GuardTests(SimpleTestCase):
    def test_problem(self):
        for bad in ("", "http://127.0.0.1:8700", "https://127.0.0.1:8700", "https://localhost",
                    "http://api.lifeassisto.com", "https://10.0.2.2:8700", "https://0.0.0.0"):
            self.assertTrue(PU.problem(bad), bad)
        self.assertIsNone(PU.problem(PUB))
        self.assertIsNone(PU.problem(PUB + "/"))

    @override_settings(PUBLIC_URL_GUARD=True, ASSISTO_BASE_URL="http://127.0.0.1:8700")
    def test_check_fails_loudly_in_production(self):
        errs = PU.check_public_base()
        self.assertEqual([e.id for e in errs], ["assisto.E_PUBLIC_URL"])
        with self.assertLogs("core.public_url", level="CRITICAL"):
            PU.log_at_start()
        from django.core.checks import run_checks
        self.assertIn("assisto.E_PUBLIC_URL", [e.id for e in run_checks()])

    @override_settings(PUBLIC_URL_GUARD=True, ASSISTO_BASE_URL=PUB)
    def test_check_passes_with_public_https(self):
        self.assertEqual(PU.check_public_base(), [])

    @override_settings(PUBLIC_URL_GUARD=False, ASSISTO_BASE_URL="http://127.0.0.1:8700")
    def test_guard_off_in_tests(self):
        self.assertEqual(PU.check_public_base(), [])

    def test_no_direct_base_url_link_builders(self):
        """Every outgoing link goes through public_base_url()."""
        root = Path(__file__).resolve().parent
        hits = []
        for p in root.rglob("*.py"):
            name = p.name
            if name.startswith("tests") or name in ("public_url.py",) or "migrations" in p.parts:
                continue
            for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
                if re.search(r"""settings\.ASSISTO_BASE_URL|["']ASSISTO_BASE_URL["']""", line):
                    hits.append("%s:%d" % (p.relative_to(root), i))
        self.assertEqual(hits, [])


@override_settings(ASSISTO_BASE_URL=PUB)
class LinksArePublicTests(TestCase):
    def setUp(self):
        integrations._FERNET = None
        _enable("dolynk", M.VendorSims().cfg("dolynk"))
        _enable("dolynk_arc", M.VendorSims().cfg("dolynk_arc"))
        _enable("imou", M.VendorSims().cfg("imou"))

    def test_every_vendor_callback_is_public_https(self):
        from core import cctv_connect_views as V
        from core import watchman_views as W
        for slug in CL.CALLBACK_SLUGS:
            self.assertTrue(CL.url(slug).startswith(PUB + CL.PATHS[slug]), slug)
        self.assertEqual(V.dolynk_callback_url("dlak"), CL.url("dolynk"))
        self.assertEqual(V.dolynk_callback_url("arcak", arc=True), CL.url("dolynk_arc"))
        self.assertEqual(W.imou_callback_url("imid"), CL.url("imou"))
        rows = {r["slug"]: r for r in integrations.list_all("en")}
        for slug in CL.CALLBACK_SLUGS:
            self.assertTrue(rows[slug]["callback_url"].startswith(PUB + "/api/v1/"), slug)
        self.assertIn(PUB + "/api/v1/cctv/dolynk/callback/", rows["dolynk"]["usage"])
        for slug in ("ezviz", "hikconnect"):            # polled, no push callback
            self.assertEqual(rows[slug]["callback_url"], "")
        # no "paste this URL" text on any card points at localhost / the old domain
        blob = json.dumps(integrations.list_all("en") + integrations.list_all("bn"),
                          ensure_ascii=False)
        for bad in ("127.0.0.1", "localhost", "http://", "assisto.asalify.com/api",
                    "assisto.asalify.com/webhooks"):
            self.assertNotIn(bad, blob, bad)

    def test_email_recovery_retention_links(self):
        from core import account_recovery, email_sender, retention_service
        self.assertTrue(email_sender.unsubscribe_url("someone@example.test").startswith(
            PUB + "/api/v1/email/unsubscribe?t="))
        self.assertEqual(account_recovery.base_url(), PUB)
        self.assertEqual(retention_service._stop_base(), PUB + "/api/v1/retention/u/")
        r = APIClient().get("/api/v1/version")
        if r.status_code == 200:
            self.assertEqual(r.data["base_url"], PUB)

    def test_selftest_all_vendors_and_rotation_old_404(self):
        from core.management.commands import cctv_callback_selftest as ST
        from core.models import ShopEvent
        for slug in CL.CALLBACK_SLUGS:
            old = CL.url(slug)
            ok, line = ST.run(slug, poster=_poster)
            self.assertTrue(ok, line)
            self.assertNotIn(old.rsplit("/", 1)[1], line)          # never the token
            keys_before = {k: v for k, v in integrations.get(slug).items() if k != CL.SALT_KEY}
            out = io.StringIO()
            call_command("cctv_callback_rotate", vendor=[slug], no_register=True, stdout=out)
            self.assertIn("rotated", out.getvalue())
            new = CL.url(slug)
            self.assertNotEqual(new, old)
            self.assertNotIn(new.rsplit("/", 1)[1], out.getvalue())
            self.assertTrue(new.startswith(PUB + CL.PATHS[slug]))
            # only the callback salt changed, never the vendor API keys
            self.assertEqual({k: v for k, v in integrations.get(slug).items()
                              if k != CL.SALT_KEY}, keys_before)
            st, _ = _poster(old, ST._message(slug, integrations.get(slug)))
            self.assertEqual(st, 404, slug)
            ok, line = ST.run(slug, poster=_poster)
            self.assertTrue(ok, line)
        self.assertEqual(ShopEvent.objects.count(), 0)          # tests never alert

    def test_selftest_bad_signature_fails(self):
        from core.management.commands import cctv_callback_selftest as ST
        good = ST._message

        def bad(slug, cfg):
            m = good(slug, cfg)
            m["sign"] = "0" * 128
            return m
        with mock.patch.object(ST, "_message", bad):
            ok, line = ST.run("dolynk", poster=_poster)
        self.assertFalse(ok)
        self.assertIn("bad_sign", line)


@override_settings(ASSISTO_BASE_URL=PUB)
class DolynkSignedPushAfterRotationTests(E2E._Base):
    """The real alert path end to end on the ROTATED public link."""
    S = "SIMDODVR1"

    def setUp(self):
        super().setUp()
        integrations._FERNET = None
        TR._clear()
        self.sim = M.VendorSims()
        self.sim.add_device("dolynk", self.S, "Adm!n#2025", channels=4)
        for target, kw in (("core.logic.cctv_connect.base.default_http", {"new": self.sim.http}),
                           ("core.shop_views._included_cameras", {"return_value": 10}),
                           ("core.cctv_connect_views._fetch_picture",
                            {"return_value": E2E._jpeg()})):
            p = mock.patch(target, **kw)
            p.start()
            self.addCleanup(p.stop)
        self.sid = self.site["id"]
        self.owner.is_staff = True
        self.owner.save(update_fields=["is_staff"])
        from datetime import timedelta
        from django.utils import timezone
        from core.models import ShopSite
        ShopSite.objects.filter(pk=self.sid).update(
            away={"until": (timezone.now() + timedelta(days=1)).isoformat()})

    def test_signed_push_on_rotated_link_raises_alert(self):
        from core.management.commands import cctv_callback_selftest as ST
        from core.models import ShopEvent
        link, cam = TR.DolynkApiE2ETests.link_iot(self)
        old = CL.url("dolynk")
        self.assertTrue(old.startswith(PUB + "/api/v1/cctv/dolynk/callback/"))
        call_command("cctv_callback_rotate", vendor=["dolynk"], no_register=True,
                     stdout=io.StringIO())
        new = CL.url("dolynk")
        human = self.sim.dl_msg(self.S, {"id": "x-41", "channel": 1, "type": "smdHuman",
                                         "at": time.time(), "pic": ""})
        r = APIClient().post(_path(old), json.dumps(human), content_type="application/json")
        self.assertEqual(r.status_code, 404)
        before = ShopEvent.objects.count()
        r = APIClient().post(_path(new), json.dumps(human), content_type="application/json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["events"], [{"result": "raised"}], r.data)
        self.assertEqual((r.data["code"], r.data["msg"]), (200, "success"))
        self.assertEqual(ShopEvent.objects.count(), before + 1)
        self.assertEqual(ShopEvent.objects.order_by("-id").first().camera_id, cam["id"])
        # the self-test on the same link: received, marked test, no alert / push
        pushes, events = len(self.pushes), ShopEvent.objects.count()
        ok, line = ST.run("dolynk", poster=_poster)
        self.assertTrue(ok, line)
        self.assertEqual((len(self.pushes), ShopEvent.objects.count()), (pushes, events))

    def test_reregister_tells_arc_the_new_link(self):
        _enable("dolynk_arc", self.sim.cfg("dolynk_arc"))
        self.assertTrue(CL.rotate("dolynk_arc"))
        self.assertEqual(CL.reregister("dolynk_arc"), "registered")
        new = CL.url("dolynk_arc")
        self.assertTrue(new.startswith(PUB + "/api/v1/cctv/dolynk/arc/"))
        self.assertTrue(str(self.sim.arc_cb).endswith(_path(new)), self.sim.arc_cb)


@override_settings(ASSISTO_BASE_URL=PUB)
class OwnerRotateButtonTests(TestCase):
    def setUp(self):
        from web import tests_o2_owner_admin as OT
        self.OT = OT
        integrations._FERNET = None
        self.owner = OT.User.objects.create_superuser(name="Owner", phone=OT.OWNER_PHONE,
                                                      password=OT.OWNER_PW)
        self.c = OT.SClient()
        OT.OwnerBase.enrol(self)
        _enable("dolynk", M.VendorSims().cfg("dolynk"))

    def password_login(self, client=None):
        return self.OT.OwnerBase.password_login(self, client)

    def post(self, data):
        d = dict(data)
        d.setdefault("_ot", self.OT._ot(self.c))
        return self.c.post("/owner/integrations", d)

    def test_card_shows_https_link_and_rotates(self):
        from core.models import OwnerAudit
        old = CL.url("dolynk")
        page = self.c.get("/owner/integrations?lang=en").content.decode()
        self.assertIn(old, page)
        self.assertIn("Rotate callback link", page)
        self.assertNotIn("127.0.0.1", page)
        r = self.post({"slug": "dolynk", "action": "rotate_cb"})        # no tick
        self.assertIn("m=rotate_confirm", r["Location"])
        self.assertEqual(CL.url("dolynk"), old)
        with mock.patch("core.callback_links.reregister", return_value="failed"):
            r = self.post({"slug": "dolynk", "action": "rotate_cb", "rotate_ok": "1"})
        self.assertIn("m=rotated_manual", r["Location"])
        new = CL.url("dolynk")
        self.assertNotEqual(new, old)
        page = self.c.get("/owner/integrations?lang=en").content.decode()
        self.assertIn(new, page)
        self.assertNotIn(old, page)
        a = OwnerAudit.objects.get(action="integration.rotate_callback")
        self.assertNotIn(new.rsplit("/", 1)[1], json.dumps(a.after))
        r = self.post({"slug": "ezviz", "action": "rotate_cb", "rotate_ok": "1"})
        self.assertEqual(r.status_code, 404)                    # no callback to rotate
