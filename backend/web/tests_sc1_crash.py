"""sc1: /client/crash-report → ClientErrorReport (auth, scrubbing, dedupe,
rate limit, v1 StartupGuard body, retention) and Owner Admin → Reports → App
errors (render bn/en, filters, detail, i18n)."""
from datetime import timedelta
from io import StringIO

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core.logic import crash_scrub as CS
from core.models import ClientErrorReport
from web.tests_o2_owner_admin import OwnerBase

User = get_user_model()

FRAMES = [
    "KeyService._run (package:assisto/crypto/key_service.dart:171)",
    "SafeStore.read (package:assisto/storage/safe_store.dart:200)",
    "_rootRun (dart:async/zone.dart:1525)",
]
DEV = {"brand": "OPPO", "manufacturer": "OPPO", "model": "CPH2637", "android": "14",
       "sdk": 34, "rom": "ColorOS", "display": "CPH2637_14.0.0.900(EX01)"}


def body(**kw):
    b = {"v": 2, "error_type": "PlatformException",
         "message": "Keystore operation failed", "frames": FRAMES, "fatal": False,
         "where": "storage.secure.read", "version": "1.0.190", "build": "190", "device": DEV}
    b.update(kw)
    return b


class ScrubTests(TestCase):
    def test_message_scrubbing(self):
        raw = ('FormatException: Unexpected "Hello Rahim, call me" at +880 1712-345678, '
               'mail rahim@example.com, see https://lifeassisto.com/x?t=secret123&p=1 '
               'file /data/user/0/com.assisto.assisto/files/Rahim_passport.jpg '
               'token abcdefghijklmnopqrstuvwxyz0123 otp 482913')
        s = CS.message(raw)
        for bad in ("Hello", "Rahim", "1712", "345678", "example.com", "secret123",
                    "passport", "abcdefghij", "482913"):
            self.assertNotIn(bad, s)
        for ph in ("<num>", "<email>", "<url>", "<path>", "<token>"):
            self.assertIn(ph, s)
        self.assertLessEqual(len(CS.message("x" * 2000 + " y")), CS.MAX_MESSAGE + 1)

    def test_frames_only_code_locations(self):
        frs = CS.frames(FRAMES + ["Rahim's secret note", "fn (/data/user/0/x/Rahim.txt:1)"])
        self.assertEqual(frs, FRAMES)

    def test_v1_log_parsing(self):
        log = ("StateError: Bad state: token 01712345678 missing\n"
               "#0      AppState.init (package:assisto/state.dart:197:7)\n"
               "#1      main (package:assisto/main.dart:60:3)\n")
        t, m = CS.type_and_message_from_log(log)
        self.assertEqual(t, "StateError")
        self.assertNotIn("01712345678", m)
        self.assertEqual(CS.frames_from_text(log)[0], "AppState.init (package:assisto/state.dart:197)")

    def test_fingerprint_ignores_line_numbers(self):
        moved = [f.replace(":171)", ":180)") for f in FRAMES]
        self.assertEqual(CS.fingerprint("E", FRAMES), CS.fingerprint("E", moved))
        self.assertNotEqual(CS.fingerprint("E", FRAMES), CS.fingerprint("F", FRAMES))


class CrashEndpointTests(TestCase):
    def setUp(self):
        cache.clear()
        self.u = User.objects.create_user(phone="+8801700000555", password="pw-12345678", name="T")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_requires_auth(self):
        r = APIClient().post("/api/v1/client/crash-report", body(), format="json")
        self.assertIn(r.status_code, (401, 403))
        self.assertEqual(ClientErrorReport.objects.count(), 0)

    def test_stores_scrubbed_and_dedupes_per_phone_per_day(self):
        msg = 'bad "Rahim" 01712345678 rahim@example.com'
        for _ in range(3):
            r = self.c.post("/api/v1/client/crash-report", body(message=msg), format="json")
            self.assertEqual(r.status_code, 200)
            self.assertTrue(r.json()["stored"])
        self.assertEqual(ClientErrorReport.objects.count(), 1)
        e = ClientErrorReport.objects.get()
        self.assertEqual(e.count, 3)
        self.assertEqual((e.brand, e.model, e.rom, e.sdk, e.build), ("oppo", "CPH2637", "ColorOS", 34, "190"))
        for bad in ("Rahim", "01712345678", "example.com"):
            self.assertNotIn(bad, e.message)
        self.assertEqual(e.user_hash, CS.user_hash(self.u.id))
        self.assertEqual(e.fingerprint, CS.fingerprint("PlatformException", FRAMES))
        # a different phone model = its own row
        self.c.post("/api/v1/client/crash-report",
                    body(device={**DEV, "model": "RMX3491"}), format="json")
        self.assertEqual(ClientErrorReport.objects.count(), 2)

    def test_client_fingerprint_is_ignored(self):
        self.c.post("/api/v1/client/crash-report", body(fingerprint="evil"), format="json")
        self.assertNotEqual(ClientErrorReport.objects.get().fingerprint, "evil")

    def test_rate_limit_per_phone(self):
        from core.views_build61 import ClientCrashReportView as V
        for i in range(V.RATE_PER_HOUR):
            self.c.post("/api/v1/client/crash-report", body(error_type="E%d" % i), format="json")
        r = self.c.post("/api/v1/client/crash-report", body(error_type="Late"), format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["stored"])
        self.assertFalse(ClientErrorReport.objects.filter(error_type="Late").exists())

    def test_v1_startup_body_and_bad_payloads(self):
        r = self.c.post("/api/v1/client/crash-report",
                        {"log": "ANR in main\n#0 x (package:assisto/main.dart:1:1)",
                         "version": "1.0", "platform": "android", "device": DEV}, format="json")
        self.assertEqual(r.status_code, 200)
        e = ClientErrorReport.objects.get()
        self.assertTrue(e.fatal)
        self.assertEqual(e.source, "startup")
        for junk in ({"frames": "notalist", "device": "x", "sdk": "abc"}, {"error_type": "<script>"}, {}):
            r = self.c.post("/api/v1/client/crash-report", junk, format="json")
            self.assertEqual(r.status_code, 200)

    def test_retention_30_days(self):
        old = ClientErrorReport.objects.create(
            fingerprint="a" * 20, day=timezone.localdate(), user=self.u,
            first_at=timezone.now() - timedelta(days=40), last_at=timezone.now() - timedelta(days=31))
        new = ClientErrorReport.objects.create(
            fingerprint="b" * 20, day=timezone.localdate(), user=self.u,
            first_at=timezone.now(), last_at=timezone.now() - timedelta(days=29))
        call_command("purge_l1_retention", stdout=StringIO())
        self.assertFalse(ClientErrorReport.objects.filter(pk=old.pk).exists())
        self.assertTrue(ClientErrorReport.objects.filter(pk=new.pk).exists())


class AppErrorsPanelTests(OwnerBase):
    def _seed(self):
        u = User.objects.create_user(phone="+8801700000777", password="pw-12345678", name="P")
        now = timezone.now()
        fp = CS.fingerprint("PlatformException", FRAMES)
        ClientErrorReport.objects.create(
            fingerprint=fp, day=timezone.localdate(), user=u, user_hash=CS.user_hash(u.id),
            error_type="PlatformException", message="Keystore operation failed",
            frames=FRAMES, brand="oppo", model="CPH2637", android="14", sdk=34, rom="ColorOS",
            build="190", version="1.0.190", count=4, first_at=now, last_at=now)
        ClientErrorReport.objects.create(
            fingerprint="c" * 20, day=timezone.localdate(), user=u, error_type="StateError",
            brand="xiaomi", model="23053RN02A", rom="HyperOS", build="189", count=1,
            fatal=True, first_at=now, last_at=now)
        return fp, u

    def test_requires_login(self):
        r = self.c.get("/owner/reports/errors")
        self.assertEqual(r.status_code, 302)

    def test_empty_state_bn_en(self):
        self.ready()
        self.assertContains(self.c.get("/owner/reports/errors?lang=en"), "No app errors in this period.")
        self.assertContains(self.c.get("/owner/reports/errors?lang=bn"), "অ্যাপের ত্রুটি")
        self.assertContains(self.c.get("/owner/reports?lang=en"), "/owner/reports/errors")

    def test_list_filter_detail(self):
        fp, u = self._seed()
        self.ready()
        r = self.c.get("/owner/reports/errors?lang=en")
        self.assertContains(r, "PlatformException")
        self.assertContains(r, "CPH2637")
        self.assertContains(r, "ColorOS")
        self.assertContains(r, "StateError")
        r = self.c.get("/owner/reports/errors?lang=en&brand=oppo")
        self.assertContains(r, "CPH2637")
        self.assertNotContains(r, "23053RN02A")
        r = self.c.get("/owner/reports/errors?lang=en&build=189")
        self.assertNotContains(r, "CPH2637")
        r = self.c.get("/owner/reports/errors/%s?lang=en" % fp)
        self.assertContains(r, "key_service.dart")
        self.assertContains(r, "/owner/users/%d" % u.id)   # owner-only user link
        self.assertEqual(self.c.get("/owner/reports/errors/nope0000?lang=en").status_code, 404)
        self.assertEqual(self.c.get("/owner/reports/errors/bad!fp").status_code, 404)

    def test_sc1_i18n_complete(self):
        from web.owner.i18n import BN, EN
        keys = {k for k in EN if k.startswith("ae_")}
        self.assertTrue(keys)
        self.assertEqual(keys - set(BN), set())
        for k in keys:
            self.assertNotEqual(BN[k], EN[k], k)
