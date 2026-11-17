"""buyinside (owner order 10 Nov 00:50 + add-on 00:52): one free trial per
shop AND per person / Google purchase chain (server trial + CCTV Play
trial), where each purchase started (no personal data), the plan
recommendation from real usage, the trial cost inside the 40 % check, and
the paid-gate inventory guard (every 402 gate in the code has a row; the
app's in-place buy list has the same keys)."""
import os
import re
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase
from django.utils import timezone

from core import buy_origin, cctv_plan_service as CPS, plans, trial_guard
from core.logic import cctv_plan as CP, entitlements as E, paid_gates as PG, plan_book as BOOK
from core.models import (AnalyticsEvent, BusinessProfile, BusinessStaff, PaymentEvent,
                         PlayPurchase, User)

from .tests_cctvprice import _cctv_body
from .tests_pay1 import PlayBase, _client

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _trial_body(user):
    b = _cctv_body(user, "c02-monthly")
    b["lineItems"][0]["offerDetails"]["offerId"] = "trial-7d"
    b["lineItems"][0]["offerPhase"] = {"freeTrial": {}}
    return b


# ------------------------------------------------------------ server trial
class ServerTrialOncePerShopTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Karim", phone="01711000101", password="x")
        self.staff = User.objects.create_user(name="Sumi", phone="01811000102", password="x")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Sample Store")
        BusinessStaff.objects.create(business=self.biz, member=self.staff)

    def test_second_member_of_the_same_shop_gets_no_trial(self):
        ok, why = plans.start_trial_button(self.owner)
        self.assertTrue(ok, why)
        self.assertFalse(plans.trial_available(self.staff))
        ok, why = plans.start_trial_button(self.staff)
        self.assertEqual((ok, why), (False, "trial_used_shop"))

    def test_another_shop_still_gets_its_trial(self):
        other = User.objects.create_user(name="Rafi", phone="01911000103", password="x")
        BusinessProfile.objects.create(user=other, shop_name="Another Store")
        self.assertTrue(plans.start_trial_button(self.owner)[0])
        self.assertTrue(plans.trial_available(other))
        self.assertTrue(plans.start_trial_button(other)[0])

    def test_shop_keys_are_hashes_never_raw_ids(self):
        keys = trial_guard.shop_keys(self.staff)
        self.assertTrue(keys)
        for k in keys:
            self.assertNotIn("shop:", k)
            self.assertGreaterEqual(len(k), 16)

    def test_refusal_message_names_the_shop_rule(self):
        plans.start_trial_button(self.owner)
        r = _client(self.staff).post("/api/v1/plans/trial/start", {"origin": "crm_write"},
                                     format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "trial_used_shop")


# ------------------------------------------------------------ CCTV Play trial
class CctvTrialOncePerShopTests(PlayBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.biz = BusinessProfile.objects.create(user=self.u, shop_name="Sample Store")
        self.staff = User.objects.create_user(name="Sumi", phone="01811000202", password="x")
        BusinessStaff.objects.create(business=self.biz, member=self.staff)

    def test_trial_then_a_second_trial_of_the_same_shop_is_not_entitled(self):
        self.g.subs["t1"] = _trial_body(self.u)
        r = self.verify("t1", product="cctv_plan")
        self.assertTrue(r.json()["entitled"], r.content)
        self.assertTrue(r.json()["cctv"]["in_trial"])
        # the staff member's OWN Google account, same shop
        self.assertTrue(CPS.trial_used(self.staff))  # the app offers no trial
        self.g.subs["t2"] = _trial_body(self.staff)
        r2 = self.verify("t2", product="cctv_plan", api=_client(self.staff))
        self.assertEqual(r2.status_code, 200, r2.content)
        self.assertFalse(r2.json()["entitled"])
        self.assertNotEqual(CPS.status(self.staff)["status"], "active")
        self.assertTrue(PlayPurchase.objects.get(user=self.staff).raw.get("trial_dup"))
        # a free trial is never revenue
        self.assertEqual(PaymentEvent.objects.filter(kind="play.charge").count(), 0)

    def test_paid_purchase_without_trial_still_works_for_the_shop(self):
        self.g.subs["t1"] = _trial_body(self.u)
        self.verify("t1", product="cctv_plan")
        self.g.subs["p2"] = _cctv_body(self.staff, "c02-monthly", price_units="500")
        r = self.verify("p2", product="cctv_plan", api=_client(self.staff))
        self.assertTrue(r.json()["entitled"])

    def test_trial_guards_are_lower_while_in_trial(self):
        self.g.subs["t1"] = _trial_body(self.u)
        self.verify("t1", product="cctv_plan")
        cache.clear()
        self.assertTrue(CPS.in_trial_owner(self.u.pk))
        from core import cctv_cap
        with mock.patch.object(cctv_cap.CT, "n_cameras", return_value=2):
            self.assertEqual(cctv_cap.ai_cap(self.u.pk, doc={}), 2 * 10)


# ------------------------------------------------------------ origin analytics
class BuyOriginTests(PlayBase):
    def test_purchase_origin_is_counted_without_personal_data(self):
        self.g.subs["s1"] = _cctv_body(self.u, "c02-monthly", price_units="500")
        r = self.api.post("/api/v1/payments/play/verify",
                          {"kind": "sub", "product_id": "cctv_plan", "purchase_token": "s1",
                           "origin": "cctv"}, format="json")
        self.assertTrue(r.json()["entitled"])
        ev = AnalyticsEvent.objects.get(name="upgrade_completed")
        self.assertEqual(ev.props["source"], "cctv")
        from core import analytics
        self.assertNotEqual(ev.uid_hash, analytics.uid_hash(self.u.pk))  # never the user's
        self.assertEqual(buy_origin.origin_counts()["cctv"]["completed"], 1)

    def test_bad_origin_is_dropped(self):
        self.assertFalse(buy_origin.record("<script>", "x"))
        self.assertFalse(buy_origin.record("", "x"))
        self.assertFalse(buy_origin.record("cctv", "x", stage="other"))


# ------------------------------------------------------------ recommendation
class RecommendTests(SimpleTestCase):
    PLANS = {"plus": (199, 70), "premium": (449, 160), "premium_pro": (999, 350),
             "business": (1299, 440)}

    def test_free_user_buying_packs_is_shown_the_cheaper_plan(self):
        r = BOOK.recommend("free", self.PLANS, used_30d=150, spent_packs_30d=578, account_days=60)
        self.assertEqual((r["plan"], r["saves_bdt"]), ("premium", 129))

    def test_only_when_it_truly_saves_money(self):
        self.assertIsNone(BOOK.recommend("free", self.PLANS, 150, 179 + 179, 60))  # 358 < 449
        self.assertIsNone(BOOK.recommend("free", self.PLANS, 0, 949, 60))        # no real use
        self.assertIsNone(BOOK.recommend("free", self.PLANS, 150, 578, 10))      # too new
        self.assertIsNone(BOOK.recommend("business", self.PLANS, 20, 0, 90))     # not credits

    def test_paying_too_much_gets_a_smaller_plan_with_room(self):
        r = BOOK.recommend("premium_pro", self.PLANS, used_30d=30, spent_packs_30d=0,
                           account_days=90)
        self.assertEqual(r["plan"], "plus")
        self.assertEqual(r["kind"], "smaller_plan")
        # tight use (no 2x room in the smaller plan) -> no downgrade advice
        self.assertIsNone(BOOK.recommend("premium", self.PLANS, 60, 0, 90))


class RecommendViewTests(TestCase):
    def test_endpoint_answers_null_without_data(self):
        u = User.objects.create_user(name="Nila", phone="01711000301", password="x")
        r = _client(u).get("/api/v1/plans/recommend")
        self.assertEqual(r.status_code, 200)
        self.assertIsNone(r.json()["recommend"])


# ------------------------------------------------------------ 40 % with trial
class TrialCostFortyPercentTests(SimpleTestCase):
    def test_cctv_trial_cost_keeps_40_percent_on_every_row(self):
        t = CP.trial_profit_rows()
        self.assertTrue(t["ok"], t["below"])
        # cctvprice (owner 17 Nov 12:35): EZVIZ is out of the trial, so the
        # one owner-decision row (EZVIZ 2 cameras, 38.2 %) is gone and NO row
        # may be under 40 % any more
        self.assertEqual(t["below"], [])
        self.assertEqual(CP.TRIAL_OWNER_DECISION, set())
        self.assertNotIn("ezviz", {r["vendor"] for r in t["rows"]})
        for r in t["rows"]:
            self.assertGreater(r["trial_cost"], 0)
            if not r["owner_decision"]:
                self.assertGreaterEqual(r["pct"], 40.0, r)

    def test_trial_is_7_days(self):
        self.assertEqual(CP.TRIAL_DAYS, 7)

    def test_server_trial_cost_keeps_40_percent(self):
        """The live trial (plans-v2) is 7 days of Business. Premium has NO
        headroom above 40 % (40.05 %), so a Premium trial would break the
        rule — the trial plan must stay Business."""
        from core.logic import pricing as P
        cfg = {"plans": {"business": {"price": 1299, "credits": 440},
                         "premium": {"price": 449, "credits": 160}}}
        self.assertEqual(E.defaults()["trial_plan"], "business")
        rows = BOOK.trial_rows(cfg, "business", 7, P.DEFAULT_TRIAL_CREDITS)
        self.assertEqual(len(rows), 1)
        self.assertGreaterEqual(rows[0]["profit_pct"], 40.0, rows[0])
        prem = BOOK.trial_rows(cfg, "premium", 7, P.DEFAULT_TRIAL_CREDITS)[0]
        self.assertLess(prem["profit_pct"], 40.0)  # why the trial is Business


# ------------------------------------------------------------ inventory guard
class PaidGateInventoryTests(SimpleTestCase):
    def test_every_entitlement_cap_is_in_the_inventory(self):
        for cap in E.CAPS:
            self.assertIn(cap, PG.PAID_GATES, cap)

    def test_every_listed_gate_file_exists(self):
        for f in PG.gated_files():
            self.assertTrue(os.path.exists(os.path.join(BACKEND, f)), f)

    def test_every_402_in_the_server_code_is_a_listed_gate(self):
        """A NEW paid gate (any file answering 402) must get its inventory row
        + its in-place buy entry in the app before it can ship."""
        pat = re.compile(r"HTTP_402|status=402|402 if")
        known = PG.gated_files()
        missing = []
        for top in ("core", "crm", "web", "tracker"):
            for root, _dirs, files in os.walk(os.path.join(BACKEND, top)):
                if "migrations" in root:
                    continue
                for name in files:
                    if not name.endswith(".py") or name.startswith("tests"):
                        continue
                    path = os.path.join(root, name)
                    rel = os.path.relpath(path, BACKEND).replace(os.sep, "/")
                    with open(path, encoding="utf-8") as fh:
                        if pat.search(fh.read()) and rel not in known:
                            missing.append(rel)
        self.assertEqual(missing, [], "402 gate without an inventory row + buy entry")

    def test_app_buy_list_has_the_same_keys(self):
        dart = os.path.join(os.path.dirname(BACKEND), "app", "lib", "plans_v2", "buy_inside.dart")
        if not os.path.exists(dart):
            self.skipTest("app not checked out next to backend/")
        with open(dart, encoding="utf-8") as fh:
            app = set(re.findall(r"PaidFeature\('([a-z0-9_]+)'", fh.read()))
        self.assertEqual(app, set(PG.PAID_GATES))

    def test_safety_files_are_never_a_paid_gate(self):
        for f in PG.gated_files():
            for word in ("sos", "emergency", "journey", "blood", "quran"):
                self.assertNotIn(word, os.path.basename(f), f)


class CctvTrialReplacementTests(PlayBase):
    def test_changing_camera_count_during_the_trial_is_not_a_second_trial(self):
        cache.clear()
        self.g.subs["t1"] = _trial_body(self.u)
        self.verify("t1", product="cctv_plan")
        b = _cctv_body(self.u, "c03-monthly", linked="t1", order="GPA.3300-0000-0000-00011")
        b["lineItems"][0]["offerDetails"]["offerId"] = "trial-7d"
        b["lineItems"][0]["offerPhase"] = {"freeTrial": {}}
        self.g.subs["t2"] = b
        self.g.subs["t1"]["subscriptionState"] = "SUBSCRIPTION_STATE_EXPIRED"
        r = self.verify("t2", product="cctv_plan")
        self.assertTrue(r.json()["entitled"], r.content)
        self.assertFalse(PlayPurchase.objects.get(sku__startswith="cctv_c03").raw.get("trial_dup"))
