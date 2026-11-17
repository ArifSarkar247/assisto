"""cctvprice — the owner's 4 CCTV decisions (17 Nov 2026 12:35):

  1. Premium AI = 400 Tk per camera per month (30-day clips, smart alerts)
  2. the free trial stays 7 days
  3. installer commission 10 %, ONLY on Premium AI sites, of the NET Premium
     AI part — never on the base 500 Tk / 2-camera plan; a ledger row per
     paid Premium AI order, never paid automatically
  4. EZVIZ cameras are NOT in the free trial (server-side), every other
     brand keeps the 7-day trial

THE 40 % CI CHECK (CctvFortyPercentTests): fails if ANY row is under 40 % —
Premium AI 400 with the 10 % commission, the base plan without commission,
and the trial rows (which must contain no EZVIZ row any more).
"""
from django.core.cache import cache
from django.test import SimpleTestCase
from django.utils import timezone

from core import cctv_plan_service as CPS
from core.logic import cctv_partner as CPT
from core.logic import cctv_plan as CP
from core.logic import cctv_premium_ai as PA
from core.logic import plan_book as PB
from core.models import (CctvCommissionEntry, CctvInstallerLink, CctvPartner, PlayPurchase,
                         ShopCamera, ShopSite, User)

from .tests_pay1 import PlayBase, sub_body


class OwnerDecisionNumbersTests(SimpleTestCase):
    def test_the_four_decisions_live_in_plan_book_and_are_read_not_copied(self):
        d = PB.CCTV_DECIDED
        self.assertEqual(d["premium_ai_bdt_per_camera"], 400)
        self.assertEqual(d["premium_ai_clip_days"], 30)
        self.assertEqual(d["trial_days"], 7)
        self.assertEqual(d["installer_commission_pct"], 10)
        self.assertEqual(d["installer_commission_applies_to"], "premium_ai")
        self.assertEqual(d["base_plan_commission_pct"], 0)
        self.assertEqual(tuple(d["trial_excluded_vendors"]), ("ezviz",))
        self.assertTrue(PB.CCTV_DECIDED_AT.startswith("2026-11-17 12:35"))
        # one source: every module reads plan_book
        self.assertEqual(PA.AI_ADDON_BDT_PER_CAMERA, 400)
        self.assertEqual(CP.PREMIUM_AI_BDT_PER_CAMERA, 400)
        self.assertEqual(CP.TRIAL_DAYS, 7)
        self.assertEqual(CPT.COMMISSION_RULES["pct_of_net"], 10)
        self.assertTrue(CPT.COMMISSION_RULES["approved"])
        # the base plan is unchanged
        self.assertEqual((CP.monthly_price(2), CP.monthly_price(3)), (500, 750))

    def test_premium_ai_plan_ids_and_prices(self):
        self.assertEqual(CP.premium_ai_price(2), 800)
        self.assertEqual(CP.premium_plan_id(3), "ai-c03")
        self.assertEqual(CP.parse_premium_plan("ai-c10"), 10)
        self.assertIsNone(CP.parse_premium_plan("ai-c11"))
        self.assertIsNone(CP.parse_premium_plan("c02-monthly"))
        self.assertEqual(len(CP.all_premium_plans()), 10)
        c = CP.normalize_cfg({"premium_ai_product_id": "cctv_plan", "premium_ai_on_sale": "yes"})
        self.assertEqual(c["premium_ai_product_id"], "cctv_premium_ai")   # never collides
        self.assertFalse(c["premium_ai_on_sale"])                        # Play freeze

    def test_commission_is_10pct_of_the_premium_ai_net_only(self):
        net = 800 * CP.net_share(CP.defaults())            # 2 cameras of Premium AI
        self.assertEqual(PB.cctv_commission_bdt(net), 59)
        self.assertEqual(PB.cctv_commission_bdt(0), 0)
        self.assertEqual(PB.cctv_commission_bdt("x"), 0)
        self.assertEqual(CPT.proposed_commission(net, 1, False, premium_ai=False), 0)
        self.assertEqual(CPT.proposed_commission(net, 1, True), 0)      # trial month

    def test_ezviz_is_the_only_brand_out_of_the_trial(self):
        self.assertFalse(CP.trial_vendor_ok("ezviz"))
        self.assertFalse(CP.trial_vendor_ok("EZVIZ"))
        for v in ("imou", "phone", "hikvision", "dahua", "tapo", "onvif", "rtsp", ""):
            self.assertTrue(CP.trial_vendor_ok(v), v)


class CctvFortyPercentTests(SimpleTestCase):
    """The CCTV 40 % CI check — CI fails if any row is under 40 %."""

    def test_every_row_at_least_40_percent(self):
        t = PA.forty_check()
        self.assertTrue(t["ok"], {k: t[k]["min_pct"] for k in ("premium_ai", "base", "trial")})
        for part in ("premium_ai", "base", "trial"):
            self.assertTrue(t[part]["rows"], part)
            for r in t[part]["rows"]:
                self.assertGreaterEqual(r["pct"], 40.0, (part, r))

    def test_premium_ai_400_with_the_10pct_commission(self):
        t = PA.forty_check()["premium_ai"]
        self.assertEqual(t["commission_pct_of_ai_net"], 10)
        self.assertEqual([r["cameras"] for r in t["rows"]], list(range(1, 11)))
        two = t["rows"][1]
        self.assertEqual(two["price"], 1300)                    # 500 + 2 x 400
        self.assertGreater(two["commission"], 0)
        self.assertEqual(t["min_pct"], 40.4)                    # documented worst row
        # without the commission it is the documented 45.0 %
        self.assertEqual(PA.profit_table()["min_pct"], 45.0)

    def test_base_plan_has_no_commission(self):
        t = PA.forty_check()["base"]
        self.assertEqual(t["commission_pct"], 0)
        self.assertEqual(t["min_pct"], 40.9)
        # a 10 % base commission would break the rule (why it is not allowed)
        self.assertFalse(PA.base_with_commission(commission_pct_of_net=10)["ok"])

    def test_the_ezviz_trial_row_is_gone(self):
        t = PA.forty_check()["trial"]
        self.assertEqual(t["ezviz_rows"], 0)
        vendors = {r["vendor"] for r in t["rows"]}
        self.assertNotIn("ezviz", vendors)
        self.assertEqual(vendors, {"imou", "phone"})
        self.assertGreaterEqual(t["min_pct"], 40.0)

    def test_check_fails_when_a_row_drops_below_40(self):
        # a dearer world (traffic x10) must turn the check red, not pass silently
        bad = PA.forty_check({"imou_traffic_usd_gb": 5.0, "ezviz_traffic_usd_gb": 5.0})
        self.assertFalse(bad["ok"])


# ------------------------------------------------------------------ DB / Play
class _Base(PlayBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.site = ShopSite.objects.create(owner=self.u, name="Dokan")

    def cam(self, vendor, **kw):
        return ShopCamera.objects.create(site=self.site, name="c", vendor=vendor, **kw)

    def trial(self, token="tr"):
        b = sub_body(self.u, product="cctv_plan", base_plan="c02-monthly")
        b["lineItems"][0]["offerDetails"]["offerId"] = "trial-7d"
        b["lineItems"][0]["offerPhase"] = {"freeTrial": {}}
        self.g.subs[token] = b
        return self.verify(token, product="cctv_plan")


class EzvizTrialExclusionTests(_Base):
    def test_plan_api_offers_the_trial_without_ezviz(self):
        self.cam("imou")
        d = self.api.get("/api/v1/shop/cctv-plan").json()
        self.assertTrue(d["trial_available"])
        self.assertEqual(d["trial_block"], "")
        self.assertEqual(d["trial_excluded_vendors"], ["ezviz"])
        self.assertEqual(d["trial_days"], 7)

    def test_plan_api_never_offers_the_trial_to_an_ezviz_owner(self):
        self.cam("imou")
        self.cam("ezviz")
        d = self.api.get("/api/v1/shop/cctv-plan").json()
        self.assertFalse(d["trial_available"])
        self.assertEqual(d["trial_block"], "ezviz")
        self.assertEqual(d["status"]["trial_block"], "ezviz")

    def test_a_trial_started_with_an_ezviz_camera_gives_no_free_service(self):
        self.cam("ezviz")
        r = self.trial()
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(r.json()["entitled"])
        self.assertTrue(PlayPurchase.objects.get(user=self.u).raw["trial_ezviz"])
        self.assertEqual(CPS.plan_cameras(self.u, now=timezone.now()), 0)

    def test_other_brands_keep_the_trial(self):
        self.cam("imou")
        self.cam("phone")
        r = self.trial()
        self.assertTrue(r.json()["entitled"])
        self.assertTrue(r.json()["cctv"]["in_trial"])
        self.assertEqual(CPS.plan_cameras(self.u, now=timezone.now()), 2)

    def test_no_ezviz_camera_can_be_added_during_the_trial(self):
        self.trial()
        r = self.api.post("/api/v1/shop/sites/%d/cameras" % self.site.id,
                          {"name": "gate", "vendor": "ezviz"}, format="json")
        self.assertEqual(r.status_code, 402, r.content)
        self.assertEqual(r.json()["error"], "cctv_trial_no_ezviz")
        self.assertFalse(ShopCamera.objects.filter(vendor="ezviz").exists())
        r = self.api.post("/api/v1/shop/sites/%d/cameras" % self.site.id,
                          {"name": "till", "vendor": "imou"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)

    def test_one_trial_per_account_still_holds(self):
        self.cam("imou")
        self.trial()
        self.assertEqual(CPS.trial_block(self.u), "used")


class PremiumAiCommissionLedgerTests(_Base):
    def setUp(self):
        super().setUp()
        tech = User.objects.create_user(name="Rana", phone="01710009401", password="pw")
        self.partner = CctvPartner.objects.create(user=tech, name="Rana CCTV", area="Mirpur",
                                                  status="approved")
        CctvInstallerLink.objects.create(site=self.site, partner=self.partner,
                                         code_hash="c" * 64, status="active",
                                         accepted_at=timezone.now(), expires_at=timezone.now())

    def premium(self, token="ai", order="GPA.4100-0000-0000-00000", cams=2):
        self.g.subs[token] = sub_body(self.u, product="cctv_premium_ai",
                                      base_plan="ai-c%02d" % cams, order=order,
                                      price_units=str(400 * cams))
        return self.verify(token, product="cctv_premium_ai")

    def test_paid_premium_ai_order_writes_one_owed_ledger_row(self):
        r = self.premium()
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.json()["entitled"])
        self.assertEqual(r.json()["cctv"]["premium_ai"]["status"], "active")
        self.assertEqual(r.json()["cctv"]["premium_ai"]["cameras"], 2)
        self.assertTrue(CPS.premium_ai_active(self.u))
        e = CctvCommissionEntry.objects.get()
        self.assertEqual((e.partner_id, e.site_id, e.status), (self.partner.id, self.site.id, "owed"))
        self.assertEqual((e.amount_bdt, e.pct, e.cameras, e.paid_month_no), (59, 10, 2, 1))
        self.assertEqual(PlayPurchase.objects.get(product_id="cctv_premium_ai").sku, "cctvai_c02")
        # a replayed verify / RTDN never pays twice
        self.premium()
        self.assertEqual(CctvCommissionEntry.objects.count(), 1)
        # a renewal (new order id) is the 2nd paid month
        self.g.subs["ai"]["latestOrderId"] = "GPA.4100-0000-0000-00000..0"
        self.verify("ai", product="cctv_premium_ai")
        self.assertEqual(sorted(CctvCommissionEntry.objects.values_list("paid_month_no", flat=True)),
                         [1, 2])

    def test_base_plan_never_earns_a_commission(self):
        self.g.subs["b"] = sub_body(self.u, product="cctv_plan", base_plan="c02-monthly",
                                    price_units="500")
        r = self.verify("b", product="cctv_plan")
        self.assertTrue(r.json()["entitled"])
        self.assertEqual(CctvCommissionEntry.objects.count(), 0)

    def test_no_commission_without_an_approved_installer_or_for_a_test_purchase(self):
        self.partner.status = "suspended"
        self.partner.save()
        self.premium()
        self.assertEqual(CctvCommissionEntry.objects.count(), 0)
        self.partner.status = "approved"
        self.partner.save()
        self.g.subs["t"] = sub_body(self.u, product="cctv_premium_ai", base_plan="ai-c01",
                                    order="GPA.TEST-1", price_units="400", test=True)
        self.verify("t", product="cctv_premium_ai")
        self.assertEqual(CctvCommissionEntry.objects.count(), 0)

    def test_only_the_first_12_paid_months(self):
        for i in range(12):
            CctvCommissionEntry.objects.create(partner=self.partner, site=self.site,
                                               order_id="GPA.OLD-%d" % i, amount_bdt=59)
        self.premium()
        self.assertEqual(CctvCommissionEntry.objects.count(), 12)

    def test_partner_sees_only_own_totals(self):
        self.premium()
        from core.cctv_partner_views import _commission_json
        other = CctvPartner.objects.create(
            user=User.objects.create_user(name="Kamal", phone="01710009402", password="pw"),
            name="Kamal", area="Uttara", status="approved")
        me = _commission_json(self.partner)
        self.assertEqual((me["owed_bdt"], me["paid_bdt"]), (59, 0))
        self.assertEqual((me["pct"], me["applies_to"]), (10, "premium_ai"))
        self.assertEqual(_commission_json(other)["owed_bdt"], 0)
