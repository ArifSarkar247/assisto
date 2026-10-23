"""a6-leftovers: annual-plan margin check, AdMob config/validator, paid
opt-in rewarded ads, app-open flag, uptime_check alert paths."""
import json
import tempfile
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import ads as A
from core.logic import pricing as P
from core.models import User

REAL_APP = "ca-app-pub-1234567890123456~1234567890"
REAL_REW = "ca-app-pub-1234567890123456/1111111111"
REAL_AO = "ca-app-pub-1234567890123456/2222222222"


# --------------------------------------------------------------- pricing
class AnnualMarginTests(SimpleTestCase):
    def test_report_has_monthly_and_annual_rows(self):
        rows = P.plan_margin_report(P.DEFAULTS())
        keys = [(r["plan"], r["period"]) for r in rows]
        self.assertIn(("premium", "mo"), keys)
        self.assertIn(("business", "mo"), keys)
        self.assertIn(("premium", "yr"), keys)

    def test_annual_net_math(self):
        c = P.DEFAULTS()
        yr = next(r for r in P.plan_margin_report(c) if r["period"] == "yr")
        # 199 * 12 * 0.80 = 1910.4 -> 1910; NET = 1910 * 0.83
        self.assertEqual(yr["price"], 1910)
        self.assertAlmostEqual(yr["net"], round(1910 * 0.83, 2))
        self.assertEqual(yr["pool_face"], 90 * 12)
        self.assertAlmostEqual(yr["pool_cap"], round(0.60 * 1910 * 0.83, 2))
        # storage: 5 GB * ৳3 * 12
        self.assertAlmostEqual(yr["storage_cost"], 180.0)

    def test_shipped_20pct_discount_is_reported_not_blocked(self):
        c = P.DEFAULTS()
        self.assertEqual(c["annual_discount_pct"], 20)      # price unchanged
        self.assertEqual(P.validate_edit(c), [])            # not blocking
        w = P.margin_warnings(c)
        self.assertEqual([x["code"] for x in w], ["annual_pool_exceeds_net"])
        self.assertEqual(w[0]["plan"], "premium")
        self.assertEqual(w[0]["max_safe_discount_pct"], 9)

    def test_safe_discount_clears_the_warning(self):
        c = P.DEFAULTS()
        c["annual_discount_pct"] = 9
        self.assertEqual(P.margin_warnings(c), [])
        c["annual_discount_pct"] = 10
        self.assertTrue(P.margin_warnings(c))

    def test_fees_and_vat_lower_the_safe_discount(self):
        c = P.DEFAULTS()
        c["vat"] = 0.05
        self.assertLess(P.max_safe_annual_discount_pct("premium", c), 9)

    def test_storage_cost_check(self):
        c = P.DEFAULTS()
        c["annual_discount_pct"] = 0
        c["storage_cost_bdt_per_gb_month"] = 50.0   # absurd storage price
        codes = {w["code"] for w in P.margin_warnings(c)}
        self.assertIn("annual_cost_exceeds_net", codes)
        self.assertIn("monthly_cost_exceeds_net", codes)

    def test_storage_cost_is_normalized_and_editable(self):
        n = P.normalize({"storage_cost_bdt_per_gb_month": -4})
        self.assertEqual(n["storage_cost_bdt_per_gb_month"], 0.0)
        self.assertEqual(P.normalize({})["storage_cost_bdt_per_gb_month"],
                         P.DEFAULT_STORAGE_COST_BDT_PER_GB_MONTH)

    def test_public_annual_price_unchanged(self):
        ann = next(p for p in P.plan_public("en", P.DEFAULTS())
                   if p["id"] == "annual")
        self.assertEqual(ann["price"], 1910)


class AdminPricingCheckTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(
            name="Owner", phone="01830000001", password="x123456",
            is_staff=True, is_superuser=True)

    def test_get_surfaces_margin_check_and_warning(self):
        self.client.force_authenticate(self.owner)
        r = self.client.get("/api/v1/admin/pricing")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(any(x["period"] == "yr" for x in r.data["margin_check"]))
        self.assertEqual(r.data["warnings"][0]["code"], "annual_pool_exceeds_net")

    def test_edit_still_saves_and_warning_clears_at_safe_discount(self):
        self.client.force_authenticate(self.owner)
        r = self.client.post("/api/v1/admin/pricing",
                             {"config": {"annual_discount_pct": 9,
                                         "storage_cost_bdt_per_gb_month": 2.5}},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["warnings"], [])
        self.assertEqual(r.data["config"]["storage_cost_bdt_per_gb_month"], 2.5)


# --------------------------------------------------------------- ads (pure)
class AdmobValidatorTests(SimpleTestCase):
    def test_real_ids_pass(self):
        ok, _ = A.validate_admob_ids({"app_id": REAL_APP, "rewarded_unit": REAL_REW})
        self.assertTrue(ok)

    def test_test_ids_refused(self):
        ok, why = A.validate_admob_ids({"app_id": A.TEST_APP_ID,
                                        "rewarded_unit": A.TEST_UNITS["rewarded"]})
        self.assertFalse(ok)
        self.assertIn("TEST", why)

    def test_bad_format_mixed_publisher_and_no_units(self):
        self.assertFalse(A.validate_admob_ids({"app_id": "abc"})[0])
        self.assertFalse(A.validate_admob_ids({"app_id": REAL_APP})[0])
        self.assertFalse(A.validate_admob_ids(
            {"app_id": REAL_APP,
             "rewarded_unit": "ca-app-pub-9999999999999999/1111111111"})[0])
        self.assertFalse(A.validate_admob_ids(
            {"app_id": REAL_APP, "rewarded_unit": "ca-app-pub-1234567890123456~1"})[0])

    def test_client_config_unconfigured_uses_no_real_ids(self):
        c = A.client_config(plan="free", paid=False, admob_cfg={},
                            admob_working=False, flag_rewarded=True,
                            flag_app_open=True,
                            ad_caps=P.DEFAULTS()["ad_rewards"])
        self.assertFalse(c["configured"])
        self.assertEqual(c["app_id"], "")
        self.assertEqual(set(c["units"].values()), {""})
        self.assertEqual(c["test_units"]["rewarded"], A.TEST_UNITS["rewarded"])
        self.assertGreaterEqual(c["appopen_min_gap_sec"], 3 * 3600)
        for s in ("sos", "payment", "topup", "login", "otp", "call"):
            self.assertIn(s, c["blocked_screens"])

    def test_client_config_paid_never_app_open(self):
        c = A.client_config(plan="premium", paid=True,
                            admob_cfg={"app_id": REAL_APP, "app_open_unit": REAL_AO},
                            admob_working=True, flag_rewarded=True,
                            flag_app_open=True,
                            ad_caps=P.DEFAULTS()["ad_rewards"])
        self.assertTrue(c["configured"])
        self.assertFalse(c["app_open_enabled"])
        self.assertTrue(c["rewarded_enabled"])      # opt-in only
        self.assertEqual(c["units"]["app_open"], REAL_AO)

    def test_gap_never_below_3h(self):
        caps = dict(P.DEFAULTS()["ad_rewards"], appopen_min_gap_sec=60)
        c = A.client_config(plan="free", paid=False, admob_cfg={},
                            admob_working=False, flag_rewarded=True,
                            flag_app_open=True, ad_caps=caps)
        self.assertEqual(c["appopen_min_gap_sec"], 3 * 3600)


# --------------------------------------------------------------- ads (api)
class AdsApiTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(
            name="Owner", phone="01830000011", password="x123456",
            is_staff=True, is_superuser=True)
        self.free = User.objects.create_user(
            name="Free", phone="01830000012", password="x123456")
        self.free.trial_until = timezone.now() - timedelta(days=1)
        self.free.plan = "free"
        self.free.save()
        self.paid = User.objects.create_user(
            name="Paid", phone="01830000013", password="x123456")
        self.paid.plan = "premium"
        self.paid.plan_until = timezone.now() + timedelta(days=30)
        self.paid.ai_credits = 0
        self.paid.save()

    def _admob(self, real=True):
        from core import integrations
        from core.models import Integration
        integrations.save("admob", {"app_id": REAL_APP if real else A.TEST_APP_ID,
                                    "rewarded_unit": REAL_REW,
                                    "app_open_unit": REAL_AO})
        st, _ = integrations.test("admob")
        return st

    def _ecpm(self, v):
        self.client.force_authenticate(self.owner)
        self.client.post("/api/v1/admin/pricing",
                         {"config": {"ad_rewards": {"ecpm_bdt": v}}}, format="json")

    def test_config_unconfigured(self):
        self.client.force_authenticate(self.free)
        r = self.client.get("/api/v1/ads/config")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["configured"])
        self.assertEqual(r.data["plan"], "free")
        self.assertFalse(r.data["paid"])

    def test_integration_test_refuses_test_ids_and_accepts_real(self):
        self.assertEqual(self._admob(real=False), "failing")
        self.assertEqual(self._admob(real=True), "working")
        self.client.force_authenticate(self.free)
        r = self.client.get("/api/v1/ads/config")
        self.assertTrue(r.data["configured"])
        self.assertEqual(r.data["units"]["rewarded"], REAL_REW)
        self.assertTrue(r.data["app_open_enabled"])

    def test_app_open_flag_kill_switch(self):
        from core.models import AdminFlagState
        self._admob()
        AdminFlagState.objects.update_or_create(
            key="global", defaults={"state": {"ads_app_open": False}})
        self.client.force_authenticate(self.free)
        r = self.client.get("/api/v1/ads/config")
        self.assertFalse(r.data["app_open_enabled"])

    def test_paid_user_config(self):
        self._admob()
        self.client.force_authenticate(self.paid)
        r = self.client.get("/api/v1/ads/config")
        self.assertTrue(r.data["paid"])
        self.assertFalse(r.data["app_open_enabled"])

    def test_paid_opt_in_rewarded_credits_balance(self):
        self._admob()
        self._ecpm(3000.0)        # 210 paisa per impression -> 2 credits
        self.client.force_authenticate(self.paid)
        r = self.client.post("/api/v1/ads/event", {"kind": "rewarded"},
                             format="json")
        self.assertTrue(r.data["ok"], r.data)
        self.assertEqual(r.data["moved_to_balance"], 2)
        self.paid.refresh_from_db()
        self.assertEqual(self.paid.ai_credits, 2)
        from core.models import AdWallet, CreditLedger
        self.assertEqual(AdWallet.objects.get(user=self.paid).balance_paisa, 10)
        self.assertTrue(CreditLedger.objects.filter(
            user=self.paid, reason="rewarded", delta=2).exists())

    def test_paid_user_gets_no_other_ad_kinds(self):
        self._admob()
        self.client.force_authenticate(self.paid)
        for kind in ("app_open", "interstitial", "native"):
            r = self.client.post("/api/v1/ads/event", {"kind": kind},
                                 format="json")
            self.assertEqual(r.data["reason"], "not_free", kind)

    def test_paid_rewarded_not_credited_without_admob(self):
        self.client.force_authenticate(self.paid)
        r = self.client.post("/api/v1/ads/event", {"kind": "rewarded"},
                             format="json")
        self.assertEqual(r.data["reason"], "ads_not_configured")
        self.paid.refresh_from_db()
        self.assertEqual(self.paid.ai_credits, 0)


# --------------------------------------------------------------- uptime
def _du(total, used):
    import shutil as _sh
    g = 10 ** 9
    return _sh._ntuple_diskusage(total * g, used * g, (total - used) * g)


class UptimeCheckTests(TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        User.objects.create_user(name="Owner", phone="01830000021",
                                 password="x123456", email="o@example.com",
                                 is_staff=True, is_superuser=True)

    def _run(self, ok):
        m = "core.management.commands.uptime_check"
        with override_settings(BASE_DIR=self.tmp), \
                mock.patch(m + "._http_ok", return_value=(ok, "200" if ok else "URLError")), \
                mock.patch(m + "._cert_days", return_value=60), \
                mock.patch("core.disk_alert.disk_usage",
                           return_value=_du(100, 30)):
            out = StringIO()
            call_command("uptime_check", stdout=out)
            return out.getvalue()

    def test_alerts_once_after_two_failures_then_recovery(self):
        with mock.patch("core.push.notify_owner",
                        return_value={"push_sent": 1}) as n:
            self._run(False)
            self.assertEqual(n.call_count, 0)        # 1 failure: no alert
            self._run(False)
            self.assertEqual(n.call_count, 1)        # 2nd: alert
            self._run(False)
            self.assertEqual(n.call_count, 1)        # no spam while down
            self._run(True)
            self.assertEqual(n.call_count, 2)        # recovered
            self.assertIn("recovered", n.call_args[0][0])

    def test_push_path_when_firebase_configured(self):
        with mock.patch("core.push.is_available", return_value=True), \
                mock.patch("core.push.push_to_user", return_value=1) as p:
            self._run(False)
            self._run(False)
        self.assertEqual(p.call_count, 1)
        self.assertEqual(p.call_args[0][1], "owner_alert")

    @override_settings(EMAIL_BACKEND="django.core.mail.backends.smtp.EmailBackend")
    def test_email_path_when_no_firebase(self):
        with mock.patch("core.push.is_available", return_value=False), \
                mock.patch("django.core.mail.send_mail") as sm:
            self._run(False)
            out = self._run(False)
        self.assertEqual(sm.call_count, 1)
        self.assertIn("o@example.com", sm.call_args[0][3])
        self.assertIn("'email': True", out)

    def test_never_crashes_when_alerting_fails(self):
        with mock.patch("core.push.notify_owner", side_effect=RuntimeError):
            self._run(False)
            out = self._run(False)
        self.assertIn("ALERT", out)
        state = json.load(open(self.tmp + "/logs/uptime_state.json"))
        self.assertTrue(state["alerted_down"])


# --------------------------------------------------------------- call history
class CallHistoryNamesTests(APITestCase):
    """QA a6: /circle/calls carried no peer, so every row showed '?'."""

    def setUp(self):
        from core.models import CircleMember, CallRecord
        self.a = User.objects.create_user(name="Amina", phone="01830000031",
                                          password="x123456")
        self.b = User.objects.create_user(name="Babu", phone="01830000032",
                                          password="x123456")
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Brother", relation="sibling",
            state="accepted", phone="01830000032")
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Apu", relation="sibling",
            state="accepted", phone="01830000031")
        CallRecord.objects.create(caller=self.a, callee=self.b, circle=self.ab,
                                  kind="voice", state="ended", duration_sec=65)

    def test_caller_sees_own_edge_name_and_member_id(self):
        self.client.force_authenticate(self.a)
        row = self.client.get("/api/v1/circle/calls").data["calls"][0]
        self.assertEqual(row["name"], "Brother")
        self.assertEqual(row["member_id"], self.ab.id)
        self.assertEqual(row["relation"], "sibling")
        self.assertTrue(row["outgoing"])

    def test_callee_sees_their_own_edge(self):
        self.client.force_authenticate(self.b)
        row = self.client.get("/api/v1/circle/calls").data["calls"][0]
        self.assertEqual(row["name"], "Apu")
        self.assertEqual(row["member_id"], self.ba.id)
        self.assertFalse(row["outgoing"])

    def test_falls_back_to_account_name_without_edge(self):
        self.ba.delete()
        self.client.force_authenticate(self.b)
        row = self.client.get("/api/v1/circle/calls").data["calls"][0]
        self.assertEqual(row["name"], "Amina")
        self.assertIsNone(row["member_id"])
