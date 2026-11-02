"""cctvprice — CCTV plan on Google Play (owner's CCTV order 3 Nov, H1-H6 + G7).

  * prices: 500 tk = 2 cameras, +250 per camera, 10 max, yearly = 12x
  * PROFIT RULE: every tier 1..10 and both video add-ons keep >= 40 % worst
    case after Play fee + VAT with the CURRENT default cost guards — this test
    FAILS if anyone loosens a default (or raises a vendor cost) too far
  * Play: a CCTV token is verified through the existing pipeline (verify +
    RTDN), acknowledged, revenue once per order, trial is not revenue, a
    count change (replacement) moves the camera count
  * the camera cap: the plan's count is the included count; phone cameras
    count; beyond the plan -> raise the count (never credits); >10 contact us
  * unpaid end: notice -> reminder -> unbind (Imou + EZVIZ, once per device)
    -> keep 30 days -> reminder -> delete; payment again -> restore
  * video add-on seam: video_addon_days(camera)
"""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from core import cctv_plan_service as CPS
from core.logic import cctv_plan as CP
from core.models import PaymentEvent, PlayPurchase, ShopCamera, ShopSite, User
from core.payments import play

from .tests_pay1 import PlayBase, sub_body


class PriceTests(TestCase):
    def test_owner_prices_exact(self):
        want = {1: 500, 2: 500, 3: 750, 4: 1000, 5: 1250, 6: 1500, 7: 1750,
                8: 2000, 9: 2250, 10: 2500}
        for n, p in want.items():
            self.assertEqual(CP.monthly_price(n), p)
            self.assertEqual(CP.price(n, "yearly"), 12 * p)   # no free months
        self.assertIsNone(CP.monthly_price(11))               # contact us
        self.assertIsNone(CP.price(25, "yearly"))
        with self.assertRaises(ValueError):
            CP.monthly_price(0)

    def test_base_plan_ids_round_trip(self):
        self.assertEqual(CP.base_plan_id(1, "monthly"), "c02-monthly")
        self.assertEqual(CP.base_plan_id(10, "yearly"), "c10-yearly")
        self.assertEqual(CP.parse_base_plan("c03-yearly"), (3, "yearly"))
        self.assertIsNone(CP.parse_base_plan("c11-monthly"))
        self.assertIsNone(CP.parse_base_plan("monthly"))
        self.assertEqual(len(CP.all_base_plans()), 18)
        self.assertEqual(CP.parse_addon_plan("d30-c04"), (30, 4))
        self.assertEqual(len(CP.all_addon_plans()), 20)
        self.assertEqual(CP.addon_price(7, 3), 300)
        self.assertEqual(CP.addon_price(30, 1), 150)
        for bp in CP.all_base_plans() + CP.all_addon_plans():
            self.assertRegex(bp, r"^[a-z0-9][a-z0-9-]{0,62}$")   # Play's id rule

    def test_cfg_bounds_and_ids(self):
        c = CP.normalize_cfg({"product_id": "assisto_cctv", "relay_mb_per_camera": 10 ** 9,
                              "ai_checks_per_camera": "x", "keep_days": 1,
                              "on_sale": "yes"})
        self.assertEqual(c["product_id"], "cctv_plan")      # never assisto_*
        self.assertEqual(c["relay_mb_per_camera"], 5000)
        self.assertEqual(c["ai_checks_per_camera"], 50)
        self.assertEqual(c["keep_days"], 30)
        self.assertFalse(c["on_sale"])
        self.assertFalse(c["limits_owner_confirmed"])          # pending owner yes


class ProfitRuleTests(TestCase):
    def test_every_tier_and_addon_at_least_40_pct_with_current_defaults(self):
        t = CP.profit_table()
        for r in t["tiers"] + t["addons"]:
            self.assertGreaterEqual(r["pct"], 40.0, r)
        self.assertTrue(t["ok"])
        self.assertEqual([r["cameras"] for r in t["tiers"]], list(range(1, 11)))
        self.assertAlmostEqual(t["net_share"], 0.85 / 1.15, places=3)

    def test_documented_numbers(self):
        t = CP.profit_table()
        self.assertAlmostEqual(t["per_camera_cost"], 82.58, places=1)   # EZVIZ worst
        self.assertEqual(t["tiers"][0]["pct"], 57.4)
        self.assertEqual(t["tiers"][1]["pct"], 40.9)
        self.assertEqual(t["tiers"][9]["pct"], 40.9)
        self.assertEqual(t["addons"][0]["pct"], 44.7)
        self.assertEqual(t["addons"][1]["pct"], 53.6)

    def test_unguarded_relay_fails_the_rule_and_warns_owner(self):
        from core.logic import pricing as P
        t = CP.profit_table({"relay_mb_per_camera": 3300, "ai_checks_per_camera": 100})
        self.assertFalse(t["ok"])
        cfg = P.normalize({"cctv_plan": {"relay_mb_per_camera": 3300}})
        self.assertIn("cctv_below_40", [w["code"] for w in P.margin_warnings(cfg)])
        self.assertNotIn("cctv_below_40",
                         [w["code"] for w in P.margin_warnings(P.normalize({}))])


def _cctv_body(user, base_plan="c03-monthly", product="cctv_plan", **kw):
    b = sub_body(user, product=product, base_plan=base_plan, **kw)
    return b


class CctvPlayTests(PlayBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.site = ShopSite.objects.create(owner=self.u, name="Dokan")

    def cam(self, **kw):
        return ShopCamera.objects.create(site=self.site, name="c", **kw)

    def test_verify_cctv_token_sets_camera_count_once_revenue(self):
        self.g.subs["ct1"] = _cctv_body(self.u, "c03-monthly", price_units="750")
        r = self.verify("ct1", product="cctv_plan")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.json()["entitled"])
        self.assertEqual(r.json()["cctv"]["cameras"], 3)
        pp = PlayPurchase.objects.get(user=self.u)
        self.assertEqual((pp.sku, pp.base_plan_id), ("cctv_c03_m", "c03-monthly"))
        self.assertTrue(pp.acknowledged)
        self.assertEqual(CPS.plan_cameras(self.u), 3)
        from core import shop_views as SV
        self.assertEqual(SV.owner_caps(self.u)["cameras"], 3)
        self.verify("ct1", product="cctv_plan")          # restore: idempotent
        self.assertEqual(PaymentEvent.objects.filter(kind="play.charge").count(), 1)
        # the app plan is untouched (CCTV is not Premium)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "free")

    def test_free_trial_is_not_revenue_and_trial_used_is_remembered(self):
        self.assertFalse(CPS.trial_used(self.u))
        b = _cctv_body(self.u, "c02-monthly")
        b["lineItems"][0]["offerDetails"]["offerId"] = "trial-7d"
        b["lineItems"][0]["offerPhase"] = {"freeTrial": {}}
        self.g.subs["tr"] = b
        r = self.verify("tr", product="cctv_plan")
        self.assertTrue(r.json()["entitled"])
        self.assertTrue(r.json()["cctv"]["in_trial"])
        self.assertEqual(PaymentEvent.objects.filter(kind="play.charge").count(), 0)
        self.assertTrue(CPS.trial_used(self.u))
        api = self.api.get("/api/v1/shop/cctv-plan").json()
        self.assertFalse(api["trial_available"])

    def test_change_count_any_time_via_replacement(self):
        self.g.subs["a"] = _cctv_body(self.u, "c02-monthly")
        self.verify("a", product="cctv_plan")
        self.g.subs["b"] = _cctv_body(self.u, "c05-yearly", linked="a",
                                      order="GPA.3300-0000-0000-00009")
        self.g.subs["a"]["subscriptionState"] = "SUBSCRIPTION_STATE_EXPIRED"
        self.verify("b", product="cctv_plan")
        self.assertEqual(CPS.plan_cameras(self.u, now=timezone.now()), 5)
        self.assertEqual(CPS.status(self.u)["period"], "yearly")

    def test_rtdn_reaches_cctv_branch(self):
        self.g.subs["rt"] = _cctv_body(self.u, "c04-monthly")
        out = play._dispatch({"subscriptionNotification": {
            "purchaseToken": "rt", "notificationType": 4}}, timezone.now())
        self.assertTrue(out.startswith("sub:PURCHASED"))
        self.assertEqual(CPS.plan_cameras(self.u, now=timezone.now()), 4)

    def test_camera_cap_plan_full_and_contact_us(self):
        self.g.subs["p"] = _cctv_body(self.u, "c02-monthly")
        self.verify("p", product="cctv_plan")
        self.cam()
        self.cam(vendor="phone")          # a phone camera counts as a camera
        self.assertEqual(CPS.counted_cameras(self.u), 2)
        r = self.api.post("/api/v1/shop/sites/%d/cameras" % self.site.id,
                          {"name": "third"}, format="json")
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["error"], "cctv_plan_full")
        self.assertEqual(ShopCamera.objects.count(), 2)
        self.g.subs["p10"] = _cctv_body(self.u, "c10-monthly", linked="p",
                                        order="GPA.3300-0000-0000-00010")
        self.verify("p10", product="cctv_plan")
        for _ in range(8):
            self.cam()
        r = self.api.post("/api/v1/shop/sites/%d/cameras" % self.site.id,
                          {"name": "eleventh"}, format="json")
        self.assertEqual(r.json()["error"], "cctv_contact_us")

    def test_video_addon_seam(self):
        self.g.subs["p"] = _cctv_body(self.u, "c03-monthly")
        self.verify("p", product="cctv_plan")
        c1, c2 = self.cam(), self.cam()
        self.assertEqual(CPS.video_addon_days(c1), 0)
        self.g.subs["v"] = _cctv_body(self.u, "d7-c01", product="cctv_video",
                                      order="GPA.3300-0000-0000-00077")
        r = self.verify("v", product="cctv_video")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(CPS.video_addon_days(c1), 7)     # oldest first
        self.assertEqual(CPS.video_addon_days(c2), 0)
        r = self.api.post("/api/v1/shop/cctv-plan/addon-cameras",
                          {"ids": [c2.id]}, format="json")
        self.assertEqual(r.json()["addon_cameras"], [c2.id])
        self.assertEqual(CPS.video_addon_days(c2), 7)
        self.assertEqual(CPS.video_addon_days(c1), 0)

    def test_plan_api_and_switch(self):
        r = self.api.get("/api/v1/shop/cctv-plan")
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertEqual([t["monthly"] for t in d["tiers"]][:3], [500, 500, 750])
        self.assertEqual(d["max_cameras"], 10)
        self.assertTrue(d["trial_available"])
        self.assertEqual(d["trial_base_plan"], "c02-monthly")
        self.assertFalse(d["on_sale"])
        self.assertFalse(d["limits"]["owner_confirmed"])
        self.assertEqual(d["play_account_id"], play.account_id(self.u))
        from core import feature_flags as FF
        from core.models import FeatureFlag
        FF.ensure_seeded()
        FeatureFlag.objects.filter(key="cctv_watchman").update(enabled_all=False)
        FF.invalidate()
        self.addCleanup(FF.invalidate)
        self.assertEqual(self.api.get("/api/v1/shop/cctv-plan").status_code, 403)


class _Cloud:
    def __init__(self):
        self.calls = []

    def unbind_device(self, dev):
        self.calls.append(("imou", dev))

    def delete_device(self, serial):
        self.calls.append(("ezviz", serial))


class LifecycleTests(PlayBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.site = ShopSite.objects.create(owner=self.u, name="Dokan")
        self.imou_a = ShopCamera.objects.create(site=self.site, vendor="imou",
                                                vendor_ref="IMOU1:0")
        self.imou_b = ShopCamera.objects.create(site=self.site, vendor="imou",
                                                vendor_ref="IMOU1:1")   # same NVR
        self.ez = ShopCamera.objects.create(site=self.site, vendor="ezviz",
                                            vendor_ref="EZ:SER9:1")
        self.phone = ShopCamera.objects.create(site=self.site, vendor="phone")
        self.cloud = _Cloud()
        p = mock.patch.object(CPS, "_clients", return_value={"imou": self.cloud,
                                                             "ezviz": self.cloud})
        p.start()
        self.addCleanup(p.stop)
        # no other plan covers any camera (worst case for the user)
        q = mock.patch.object(CPS, "_covered_by_other_plan", return_value=0)
        q.start()
        self.addCleanup(q.stop)
        self.g.subs["t"] = _cctv_body(self.u, "c05-monthly")
        self.verify("t", product="cctv_plan")
        self.push.reset_mock()

    def _end(self):
        self.g.subs["t"]["subscriptionState"] = "SUBSCRIPTION_STATE_EXPIRED"
        self.g.subs["t"]["lineItems"][0]["expiryTime"] = (
            timezone.now() - timedelta(minutes=1)).isoformat().replace("+00:00", "Z")
        play.sync_subscription("t", self.u)

    def test_full_unpaid_path_with_notices_before_each_step(self):
        now = timezone.now()
        self._end()                       # sync runs the first step itself
        st = CPS.get_state(self.u)
        self.assertIn("ended", st["sent"])
        self.assertEqual(CPS.lifecycle_for(self.u, now + timedelta(hours=1)), "none")
        self.assertEqual(CPS.lifecycle_for(self.u, now + timedelta(days=2, hours=1)),
                         "notice_unbind_soon")
        self.assertEqual(ShopCamera.objects.filter(enabled=True).count(), 4)
        self.assertEqual(CPS.lifecycle_for(self.u, now + timedelta(days=3, hours=1)),
                         "unbind")
        # one call per DEVICE (the NVR with two channels is unbound once)
        self.assertEqual(sorted(self.cloud.calls), [("ezviz", "SER9"), ("imou", "IMOU1")])
        self.assertEqual(ShopCamera.objects.filter(enabled=True).count(), 0)
        self.imou_a.refresh_from_db()
        self.assertEqual(self.imou_a.vendor_ref, "")
        self.assertEqual(self.imou_a.compat["unbound_ref"], "IMOU1:0")
        self.assertTrue(ShopSite.objects.filter(owner=self.u).exists())   # kept
        t27 = now + timedelta(days=3 + 27, hours=2)
        self.assertEqual(CPS.lifecycle_for(self.u, t27), "notice_delete_soon")
        self.assertEqual(CPS.lifecycle_for(self.u, now + timedelta(days=33, hours=2)),
                         "delete")
        self.assertFalse(ShopSite.objects.filter(owner=self.u).exists())
        self.assertEqual(CPS.lifecycle_for(self.u, now + timedelta(days=40)), "none")
        steps = [c.kwargs.get("data", {}).get("step") or c.args[6]["step"]
                 for c in self.push.call_args_list]
        self.assertEqual(steps, ["notice_ended", "notice_unbind_soon", "unbind",
                                 "notice_delete_soon", "delete"])

    def test_payment_after_unbind_restores_gateway_and_phone_cameras(self):
        now = timezone.now()
        self._end()
        CPS.lifecycle_for(self.u, now + timedelta(days=3, hours=1))
        self.assertEqual(ShopCamera.objects.filter(enabled=True).count(), 0)
        self.g.subs["t2"] = _cctv_body(self.u, "c05-monthly", order="GPA.3300-0000-0000-00055")
        self.verify("t2", product="cctv_plan")
        self.phone.refresh_from_db()
        self.ez.refresh_from_db()
        self.assertTrue(self.phone.enabled)
        self.assertFalse(self.ez.enabled)                  # must be added again
        self.assertTrue(self.ez.compat["needs_rebind"])
        self.assertEqual(CPS.get_state(self.u).get("ended_at"), None)

    def test_hold_notice_then_recovery(self):
        self.g.subs["t"]["subscriptionState"] = "SUBSCRIPTION_STATE_ON_HOLD"
        play.sync_subscription("t", self.u)
        self.assertEqual(CPS.status(self.u)["status"], "hold")
        self.assertEqual(CPS.plan_cameras(self.u, now=timezone.now()), 0)
        self.assertIn("hold", CPS.get_state(self.u)["sent"])
        self.assertIsNotNone(CPS.notice_for(self.u))
        self.g.subs["t"]["subscriptionState"] = "SUBSCRIPTION_STATE_ACTIVE"
        self.g.subs["t"]["lineItems"][0]["expiryTime"] = (
            timezone.now() + timedelta(days=30)).isoformat().replace("+00:00", "Z")
        play.sync_subscription("t", self.u)
        self.assertEqual(CPS.plan_cameras(self.u, now=timezone.now()), 5)
        self.assertIsNone(CPS.get_state(self.u).get("hold_at"))
        self.assertEqual(ShopCamera.objects.filter(enabled=True).count(), 4)

    def test_cameras_covered_by_other_plan_are_kept(self):
        now = timezone.now()
        self._end()
        with mock.patch.object(CPS, "_covered_by_other_plan", return_value=2):
            CPS.lifecycle_for(self.u, now + timedelta(days=3, hours=1))
        kept = list(ShopCamera.objects.filter(enabled=True).order_by("id"))
        self.assertEqual(kept, [self.imou_a, self.imou_b])
        self.assertEqual(self.cloud.calls, [("ezviz", "SER9")])

    def test_sweep_and_daily_job_step(self):
        self._end()
        out = CPS.lifecycle_sweep(timezone.now() + timedelta(days=3, hours=1))
        self.assertEqual(out["errors"], 0)
        self.assertEqual(out["actions"], 1)
        other = User.objects.create_user(name="Nobody", phone="01711000077", password="x")
        self.assertEqual(CPS.lifecycle_for(other), "none")   # never had the plan
