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
