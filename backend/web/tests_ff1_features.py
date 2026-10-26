"""feature-flags: Owner Admin → Features (EN/BN, edit, DONE needs 9/9,
validation, audit log, owner-only)."""
from core import feature_flags as FF
from core.models import FeatureFlag, OwnerAudit
from web.tests_o2_owner_admin import OwnerBase, SClient


def _form(**kw):
    d = {"enabled_all": "1", "enabled_play": "1", "rollout_pct": "100",
         "allow_user_ids": "", "dod_status": "in_progress", "note": "", "note_bn": ""}
    d.update(kw)
    return {k: v for k, v in d.items() if v is not None}


class FeaturesPageTests(OwnerBase):
    def tearDown(self):
        FF.invalidate()

    def test_page_en_bn_seeds_rows(self):
        self.ready()
        r = self.c.get("/owner/features?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(FeatureFlag.objects.count(), len(FF.KEYS))
        for s in ("Features", "CCTV watchman (Shop Box)", "Hide in Play",
                  "Definition of Done (9 checks)", 'href="/owner/features"',
                  "IN PROGRESS", "HIDDEN", "Change log"):
            self.assertContains(r, s)
        r = self.c.get("/owner/features?lang=bn")
        for s in ("ফিচার", "সিসিটিভি ওয়াচম্যান", "Play-তে লুকান", "লুকানো",
                  "/৯", "পরিবর্তনের লগ"):
            self.assertContains(r, s)
        r = self.c.get("/owner/features?lang=en&section=business&q=crm")
        self.assertContains(r, "<code>crm</code>")
        self.assertNotContains(r, "<code>money</code>")

    def test_edit_saves_audits_and_reaches_api(self):
        self.ready()
        self.c.get("/owner/features")
        r = self.post("/owner/features/crm", _form(enabled_play=None, rollout_pct="30",
                                                    allow_user_ids="7, 9",
                                                    note="Hide until email", note_bn="ইমেইল পর্যন্ত লুকান",
                                                    dod_0="1", dod_1="1"))
        self.assertEqual(r.status_code, 302)
        f = FeatureFlag.objects.get(key="crm")
        self.assertFalse(f.enabled_play)
        self.assertEqual(f.rollout_pct, 30)
        self.assertEqual(f.allow_user_ids, [7, 9])
        self.assertEqual(f.note_bn, "ইমেইল পর্যন্ত লুকান")
        self.assertEqual(f.dod_checks[:3], [True, True, False])
        self.assertEqual(f.updated_by, self.owner)
        a = OwnerAudit.objects.filter(action="feature_flag", target="crm").first()
        self.assertTrue(a.ok)
        self.assertEqual(a.before["enabled_play"], True)
        self.assertEqual(a.after["enabled_play"], False)
        # the API sees it at once (saving worker drops its cache)
        self.assertFalse(FF.resolve(None, play=True)[0]["crm"])
        r = self.c.get("/owner/features?lang=en")
        self.assertContains(r, "Hide until email")
        self.assertContains(r, "enabled_play = False")
        # nothing changed -> no new audit row
        n = OwnerAudit.objects.filter(action="feature_flag").count()
        self.post("/owner/features/crm", _form(enabled_play=None, rollout_pct="30",
                                               allow_user_ids="7,9", note="Hide until email",
                                               note_bn="ইমেইল পর্যন্ত লুকান", dod_0="1", dod_1="1"))
        self.assertEqual(OwnerAudit.objects.filter(action="feature_flag").count(), n)

    def test_done_needs_all_nine(self):
        self.ready()
        r = self.post("/owner/features/money", _form(dod_status="done", dod_0="1"))
        self.assertIn("m=ff_dod", r["Location"])
        self.assertNotEqual(FeatureFlag.objects.get(key="money").dod_status, "done")
        self.assertTrue(OwnerAudit.objects.filter(action="feature_flag", ok=False).exists())
        r = self.c.get(r["Location"] + "&lang=en")
        self.assertContains(r, "DONE needs all 9 checks")
        all9 = {"dod_%d" % i: "1" for i in range(9)}
        self.post("/owner/features/money", _form(dod_status="done", **all9))
        self.assertEqual(FeatureFlag.objects.get(key="money").dod_status, "done")

    def test_invalid_and_unknown(self):
        self.ready()
        r = self.post("/owner/features/crm", _form(rollout_pct="500"))
        self.assertIn("m=invalid", r["Location"])
        self.assertEqual(self.post("/owner/features/nope", _form()).status_code, 404)

    def test_requires_owner(self):
        self.assertIn(SClient().get("/owner/features").status_code, (302, 403))
