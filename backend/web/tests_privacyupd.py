"""privacyupd: owner Play decision 5 (9 Nov) — the server switch
money_notif_sms (SMS-app part of Money from notifications). Default ON in
both builds; Owner Admin → Features shows it with a one-line explanation and
turning it off reaches GET /api/v1/features at once."""
from core import feature_audit as FA
from core import feature_flags as FF
from core.models import FeatureFlag
from web.tests_o2_owner_admin import OwnerBase

KEY = "money_notif_sms"


def _form(**kw):
    d = {"enabled_all": "1", "enabled_play": "1", "rollout_pct": "100",
         "allow_user_ids": "", "dod_status": "in_progress", "note": "", "note_bn": ""}
    d.update(kw)
    return {k: v for k, v in d.items() if v is not None}


class SmsSwitchTests(OwnerBase):
    def tearDown(self):
        FF.invalidate()

    def test_default_on_both_builds_owns_no_route(self):
        FF.invalidate()
        self.assertTrue(FF.meta(KEY)["default_on"])
        self.assertEqual(FF.meta(KEY)["routes"], [])
        self.assertTrue(FF.resolve(None, play=True)[0][KEY])
        self.assertTrue(FF.resolve(None, play=False)[0][KEY])

    def test_owner_admin_explains_and_turns_off(self):
        self.ready()
        r = self.c.get("/owner/features?lang=en&q=money_notif_sms")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "<code>money_notif_sms</code>")
        self.assertContains(r, "Turn OFF if a Play reviewer objects")
        r = self.c.get("/owner/features?lang=bn&q=money_notif_sms")
        self.assertContains(r, "Play রিভিউয়ার আপত্তি করলে বন্ধ করুন")
        r = self.post("/owner/features/" + KEY, _form(enabled_all=None))
        self.assertEqual(r.status_code, 302)
        self.assertFalse(FeatureFlag.objects.get(key=KEY).enabled_all)
        # every normal phone sees OFF on its next /features read
        self.assertFalse(FF.resolve(None, play=True)[0][KEY])
        self.assertFalse(FF.resolve(None, play=False)[0][KEY])
        # the owner's own answer marks it "preview" — the app treats that as OFF
        feats, preview = FF.resolve(self.owner, play=True)
        self.assertIn(KEY, preview)

    def test_audit_line_present(self):
        a = FA.AUDIT[KEY]
        self.assertEqual(a["play"], "show")
        self.assertIn("wallet-app notifications keep working", a["reason_en"])


# ------------------------------------------------- privacy policy v2 (preview)
from pathlib import Path  # noqa: E402

from django.test import Client, TestCase  # noqa: E402

from core.models import OwnerAudit  # noqa: E402
from web import legal_content as LC  # noqa: E402
from web import views_legal as VL  # noqa: E402
from web.tests_site_v3 import no_network  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OLD_AI = "whichever we have switched on at the time"
NEW_IDS = ("money_notif", "carecall", "train", "city_trips", "silent_watch")


class PrivacyPreviewTests(TestCase):
    def test_live_policy_unchanged_until_owner_ok(self):
        self.assertFalse(VL.privacy_v2_live())
        html = Client().get("/privacy?lang=en").content.decode()
        self.assertIn(OLD_AI, html)
        for sid in NEW_IDS:
            self.assertNotIn('id="%s"' % sid, html)
        self.assertIn('content="index, follow"', html)
        self.assertNotIn("preview-note", html)
        self.assertEqual([s["id"] for s in LC.PRIVACY].count("money_notif"), 0)

    def test_preview_en_bn_noindex_with_every_new_section(self):
        r = Client().get("/preview/privacy?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["X-Robots-Tag"], "noindex, nofollow")
        html = r.content.decode()
        self.assertIn('content="noindex, nofollow"', html)
        self.assertIn("PREVIEW — not live yet.", html)
        for sid in NEW_IDS:
            self.assertIn('id="%s"' % sid, html)
        self.assertIn("Anthropic (Claude) now", html)
        self.assertIn("Google (Gemini) — switched off now", html)
        self.assertNotIn(OLD_AI, html)
        self.assertIn("BIND_NOTIFICATION_LISTENER_SERVICE", html)
        self.assertEqual(html.count('class="perm"'), len(LC.PERMISSIONS) + 1)
        self.assertIn("2026-11-09", html)
        bn = Client().get("/preview/privacy").content.decode()
        self.assertIn("প্রিভিউ — এখনো লাইভ নয়।", bn)
        self.assertIn("নোটিফিকেশন থেকে টাকার হিসাব", bn)
        self.assertNotIn("/preview/privacy", Client().get("/sitemap.xml").content.decode())

    def test_policy_numbers_match_the_code(self):
        """Every retention number in the new text comes from the code."""
        from core import carecall as CC
        from core import train_service as TS
        self.assertEqual(TS.PURGE_AFTER_H, 6)
        self.assertEqual(TS.REPORT_KEEP_DAYS, 30)
        self.assertEqual(CC.LIMIT_DEFAULTS["carecall_voice_max_seconds"], 30)
        kt = ROOT / "app/android_overlay/app/src/main/kotlin/com/assisto/assisto/notiflisten"
        core = (kt / "NotifListenCore.kt").read_text()
        self.assertIn("const val MAX_Q = 40", core)
        self.assertIn("MAX_AGE_MS = 30L * 24 * 3600 * 1000", core)
        allow = (kt / "NotifAllow.kt").read_text()
        for pkg in ("com.bKash.customerapp", "com.konasl.nagad", "com.dbbl.mbs.apps.main",
                    "com.dbbl.nexus.pay", "com.ibbl.cellfin", "com.thecitybank.citytouch"):
            self.assertIn('"%s"' % pkg, allow)
        # the listener is added to the manifest with NO uses-permission (no READ_SMS)
        ci = (ROOT / ".github/workflows/android.yml").read_text()
        block = ci[ci.index("# ---- callmoney ----"):ci.index("# ---- /callmoney ----")]
        self.assertNotIn("uses-permission", block)


class PrivacyGoLiveTests(OwnerBase):
    def setUp(self):
        super().setUp()
        no_network(self)
        self.ready()

    def tearDown(self):
        FF.invalidate()

    def test_owner_publishes_and_rolls_back_in_one_tap(self):
        r = self.c.get("/owner/website?lang=en")
        self.assertContains(r, "Publish the updated policy")
        self.assertContains(r, "/preview/privacy")
        self.assertEqual(self.post("/owner/website", {"action": "privacy_golive"}).status_code, 302)
        self.assertTrue(VL.privacy_v2_live())
        html = Client().get("/privacy?lang=en").content.decode()
        self.assertIn('id="money_notif"', html)
        self.assertNotIn("preview-note", html)
        self.assertIn('content="index, follow"', html)
        self.assertEqual(self.post("/owner/website", {"action": "privacy_rollback"}).status_code, 302)
        self.assertFalse(VL.privacy_v2_live())
        self.assertIn(OLD_AI, Client().get("/privacy?lang=en").content.decode())
        self.assertEqual(OwnerAudit.objects.filter(action="flag.flip",
                                                   target="flag:privacy_v2_live").count(), 2)
