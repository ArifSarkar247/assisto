"""preview-testers (owner 17 Nov "nothing stays hidden from me"): a global
list of tester accounts in Owner Admin → Features. Every OFF feature is a
preview for them exactly like for the owner; everyone else sees nothing new.
The owner adds testers by phone / email (resolved server-side to user ids),
the page and the audit log never show a full phone or email, and every
hidden feature has a "where in the app" line (core.feature_where)."""
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import feature_where as FW
from core.models import FeatureFlag, OwnerAudit, User
from web.tests_o2_owner_admin import OwnerBase

TESTER_PHONE = "01710009911"
TESTER_EMAIL = "tester.sample@example.com"


def _off(*keys):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key__in=keys).update(enabled_all=False, enabled_play=False)
    FF.invalidate()


class PreviewTesterResolveTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.tester = User.objects.create_user(name="T", phone=TESTER_PHONE, password="pw-123456")
        self.other = User.objects.create_user(name="O", phone="01710009912", password="pw-123456")

    def tearDown(self):
        FF.invalidate()

    def test_tester_sees_every_off_flag_as_preview_others_do_not(self):
        _off("train_tracker", "vehicle_engine_cut", "child_emergency_audio", "crm")
        FF.save_preview_testers([self.tester.pk])
        feats, preview = FF.resolve(self.tester, play=True)
        _, owner_preview = FF.resolve(self.owner, play=True)
        self.assertEqual(sorted(preview), sorted(owner_preview))   # exactly like the owner
        for k in ("train_tracker", "vehicle_engine_cut", "child_emergency_audio", "crm"):
            self.assertTrue(feats[k], k)
            self.assertIn(k, preview)
        feats, preview = FF.resolve(self.other, play=True)
        self.assertEqual(preview, [])
        for k in ("train_tracker", "vehicle_engine_cut", "child_emergency_audio", "crm"):
            self.assertFalse(feats[k], k)
        self.assertFalse(FF.is_on("train_tracker", None, play=True))   # signed out
        # an inactive tester gets nothing
        self.tester.is_active = False
        self.tester.save()
        self.assertEqual(FF.resolve(self.tester, play=True)[1], [])

    def test_api_payload_and_removal(self):
        _off("train_tracker")
        FF.save_preview_testers([self.tester.pk])
        api = APIClient()
        api.force_authenticate(self.tester)
        r = api.get("/api/v1/features?fv=2")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["features"]["train_tracker"])
        self.assertIn("train_tracker", r.json()["preview"])
        FF.save_preview_testers([])
        r = api.get("/api/v1/features?fv=2")
        self.assertFalse(r.json()["features"]["train_tracker"])
        self.assertNotIn("train_tracker", r.json()["preview"])

    def test_reserved_row_is_never_a_feature(self):
        FF.save_preview_testers([self.tester.pk])
        self.assertNotIn(FF.PREVIEW_TESTERS_KEY, FF.KEYS)
        self.assertNotIn(FF.PREVIEW_TESTERS_KEY, FF.rows())
        self.assertNotIn(FF.PREVIEW_TESTERS_KEY, FF.resolve(self.other)[0])
        self.assertEqual(FF.preview_testers(), (self.tester.pk,))

    def test_find_accounts_phone_email_and_missing(self):
        e = User.objects.create_user(name="E", email=TESTER_EMAIL, password="pw-123456")
        ids, missing = FF.find_accounts("+880 1710-009911;\n%s, nobody@example.com,"
                                        " 01710009911" % TESTER_EMAIL.upper())
        self.assertEqual(ids, [self.tester.pk, e.pk])
        self.assertEqual(missing, 1)

    def test_masking(self):
        m = FF.mask_account(self.tester)
        self.assertIn("•", m)
        self.assertNotIn(self.tester.phone[6:-2], m)
        e = User.objects.create_user(name="E", email=TESTER_EMAIL, password="pw-123456")
        m = FF.mask_account(e)
        self.assertIn("•", m)
        self.assertNotIn(TESTER_EMAIL, m)


class PreviewTesterOwnerPageTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.tester = User.objects.create_user(name="T", phone=TESTER_PHONE, password="pw-123456")

    def tearDown(self):
        FF.invalidate()

    def test_owner_adds_and_removes_testers_masked_and_audited(self):
        self.ready()
        r = self.c.get("/owner/features?lang=en")
        self.assertContains(r, "Preview testers")
        self.assertContains(r, "No preview testers yet")
        r = self.post("/owner/features/preview-testers", {"add": TESTER_PHONE})
        self.assertEqual(r.status_code, 302)
        self.assertNotIn("m=", r["Location"].replace("m=saved", ""))
        self.assertEqual(FF.preview_testers(), (self.tester.pk,))
        r = self.c.get("/owner/features?lang=en")
        body = r.content.decode()
        self.assertNotIn(self.tester.phone, body)          # masked
        self.assertNotIn(TESTER_PHONE, body)
        self.assertIn(FF.mask_account(self.tester), body)
        a = OwnerAudit.objects.filter(action="feature_flag", target="preview_testers", ok=True).first()
        self.assertEqual(a.after, {"user_ids": [self.tester.pk]})
        self.assertNotIn(TESTER_PHONE[-6:], str(a.before) + str(a.after))
        # the tester now sees an off feature through the API
        _off("train_tracker")
        api = APIClient()
        api.force_authenticate(self.tester)
        self.assertIn("train_tracker", api.get("/api/v1/features?fv=2").json()["preview"])
        # adding the same account again changes nothing
        r = self.post("/owner/features/preview-testers", {"add": TESTER_PHONE})
        self.assertIn("m=nothing", r["Location"])
        # remove
        r = self.post("/owner/features/preview-testers", {"remove": str(self.tester.pk)})
        self.assertEqual(FF.preview_testers(), ())
        self.assertNotIn("train_tracker", api.get("/api/v1/features?fv=2").json()["preview"])

    def test_unknown_account_is_rejected_and_nothing_saved(self):
        self.ready()
        r = self.post("/owner/features/preview-testers",
                      {"add": "%s, 01999999999" % TESTER_PHONE})
        self.assertIn("m=ff_pt_notfound", r["Location"])
        self.assertEqual(FF.preview_testers(), ())
        r = self.c.get(r["Location"] + "&lang=en")
        self.assertContains(r, "matches no active Assisto account")
        self.assertTrue(OwnerAudit.objects.filter(target="preview_testers", ok=False).exists())

    def test_requires_owner_session(self):
        from web.tests_o2_owner_admin import SClient
        r = SClient().post("/owner/features/preview-testers", {"add": TESTER_PHONE})
        self.assertIn(r.status_code, (302, 403))
        self.assertEqual(FF.preview_testers(), ())

    def test_where_line_shown_for_hidden_feature(self):
        self.ready()
        r = self.c.get("/owner/features?lang=en&q=train_tracker")
        self.assertContains(r, "Where in the app")
        self.assertContains(r, FW.where("train_tracker", "en"))
        r = self.c.get("/owner/features?lang=bn&q=train_tracker")
        self.assertContains(r, FW.where("train_tracker", "bn"))


class WhereTextTests(OwnerBase):
    def test_every_entry_is_a_known_feature_with_both_languages(self):
        for k, (en, bn) in FW.WHERE.items():
            self.assertTrue(FF.is_known(k), k)
            self.assertTrue(en.strip() and bn.strip(), k)
        self.assertEqual(FW.where("no_such_key", "bn"), "")

    def test_every_default_hidden_feature_has_a_where_line(self):
        hidden = [r[0] for r in FF.REGISTRY if not r[4]] + list(FF.SOURCE_REQUIRED)
        missing = [k for k in hidden if k not in FW.WHERE]
        self.assertEqual(missing, [])
