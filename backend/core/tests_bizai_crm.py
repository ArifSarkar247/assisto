"""bizai pillar 2 — CRM automation: segments (recency / value / interest),
the 30 / 60 / 90 win-back ladder (one-tap approve, no double message across
stages, sends through the guarded retention pipeline), AI drafts that may
never add a number, and real outcomes (customers back, sales brought back)."""
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone

from core import ai
from core import bizai_crm as C
from core import bizai_service as BA
from core import retention_service as RS
from core.logic import retention as R
from core.models import Customer, RetentionAutomation, RetentionSend, Sale, SaleLine
from core.tests_retention import _Base

API = "/api/v1/"


class PureTests(SimpleTestCase):
    def test_segment_rules(self):
        self.assertEqual(C.segment_of(3, 5), "champion")
        self.assertEqual(C.segment_of(10, 2), "loyal")
        self.assertEqual(C.segment_of(5, 1), "new")
        self.assertEqual(C.segment_of(40, 3), "at_risk_30")
        self.assertEqual(C.segment_of(40, 1), "one_time")
        self.assertEqual(C.segment_of(70, 9), "at_risk_60")
        self.assertEqual(C.segment_of(120, 9), "lost_90")

    def test_value_cut_top_20_percent(self):
        self.assertEqual(C.value_cut([100, 200, 300, 400, 500]), 500)
        self.assertEqual(C.value_cut([0, 0]), None)
        self.assertEqual(C.value_cut(list(range(1, 11))), 9)

    def test_ladder_windows_do_not_overlap(self):
        now = timezone.now()
        s = [{"key": "k", "last_sale_id": 1, "at": now - timedelta(days=65)}]
        got = [st for st, lo, hi in C.LADDER if R.due_winback(s, now, lo, hi)]
        self.assertEqual(got, ["wb60"])          # 65 days: ONLY the 60-day stage
        s[0]["at"] = now - timedelta(days=200)
        self.assertEqual([st for st, lo, hi in C.LADDER if R.due_winback(s, now, lo, hi)],
                         ["wb90"])
        self.assertEqual(R.normalize_params("winback", {"days_without": 30, "days_until": 60}),
                         {"days_without": 30, "days_until": 60, "daily_cap": 50})


class CrmTests(_Base):
    def sale(self, cust, days_ago, total=50000, product="Saree"):
        s = Sale.objects.create(user=self.owner, business=self.biz, customer=cust, total=total)
        Sale.objects.filter(pk=s.pk).update(created_at=timezone.now() - timedelta(days=days_ago))
        SaleLine.objects.create(sale=s, product_name=product, qty=1, unit_price=total,
                                sell_price=total)
        return s

    def cust_(self, name, phone):
        return Customer.objects.create(user=self.owner, business=self.biz, name=name,
                                       phone=phone, phone_key=phone)

    def test_segments_from_real_sales_with_interest_and_value(self):
        for d in (2, 9, 15, 20):
            self.sale(self.cust, d, 90000, "Panjabi")
        b = self.cust_("Babu", "01710000003")
        self.sale(b, 45)
        self.sale(b, 50)
        lost = self.cust_("Lina", "01710000004")
        self.sale(lost, 120, 10000)
        r = self.oc.get(API + "bizai/crm/segments").data
        seg = {s["key"]: s for s in r["segments"]}
        self.assertEqual(seg["champion"]["count"], 1)
        top = seg["champion"]["members"][0]
        self.assertEqual((top["name"], top["interest"], top["high_value"]),
                         ("Karim", "Panjabi", True))
        self.assertNotIn("01710000002", str(r))          # phones are masked
        self.assertEqual(seg["at_risk_30"]["count"], 1)
        self.assertEqual(seg["lost_90"]["count"], 1)
        self.assertEqual(r["total"], 3)

    def test_ladder_one_tap_approve_then_sends_once_per_stage(self):
        self.sale(self.cust, 40)        # Karim (on Assisto) — silent 40 days
        r = self.oc.get(API + "bizai/crm/ladder").data
        st = {s["stage"]: s for s in r["stages"]}
        self.assertEqual([s["enabled"] for s in r["stages"]], [False, False, False])
        self.assertEqual((st["wb30"]["audience"], st["wb60"]["audience"]), (1, 0))
        r = self.oc.post(API + "bizai/crm/ladder", {"channel": "in_app"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual([s["enabled"] for s in r.data["stages"]], [True, True, True])
        self.assertEqual(RetentionAutomation.objects.filter(business=self.biz,
                                                            kind="winback").count(), 3)
        # approving twice never duplicates the stages
        self.oc.post(API + "bizai/crm/ladder", {}, format="json")
        self.assertEqual(RetentionAutomation.objects.filter(business=self.biz).count(), 3)
        from zoneinfo import ZoneInfo
        noon = timezone.now().astimezone(ZoneInfo("Asia/Dhaka")).replace(hour=12, minute=0)
        for a in RetentionAutomation.objects.filter(business=self.biz):
            RS.run_automation(a, noon)
            RS.run_automation(a, noon)
        names = list(RetentionSend.objects.values_list("automation__name", flat=True))
        self.assertEqual(names, ["Win-back 30"])          # one stage, one message
        r = self.oc.post(API + "bizai/crm/ladder", {"on": False}, format="json")
        self.assertEqual([s["enabled"] for s in r.data["stages"]], [False, False, False])

    def test_owner_drafts_are_validated(self):
        r = self.oc.post(API + "bizai/crm/ladder",
                         {"drafts": {"wb30": {"bn": "{name} {bogus}"}}}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertFalse(RetentionAutomation.objects.exists())

    def test_ai_draft_never_adds_a_number(self):
        with mock.patch.object(ai, "generate", return_value=("{name}, ৫০% ছাড়! {shop}", 0)):
            r = self.oc.post(API + "bizai/crm/draft", {"stage": "wb30"}, format="json")
        self.assertEqual(r.data["reason"], "ai_changed_numbers")
        with mock.patch.object(ai, "generate",
                               return_value=("{name}, {shop}-এ আবার আসুন, নতুন জিনিস এসেছে।", 0)):
            r = self.oc.post(API + "bizai/crm/draft", {"stage": "wb30"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertIn("{shop}", r.data["text"])
        with mock.patch.object(ai, "generate", side_effect=ai.AIUnavailable("no_key")):
            r = self.oc.post(API + "bizai/crm/draft", {"stage": "wb30"}, format="json")
        self.assertTrue(r.data["reason"].startswith("ai_"))

    def test_staff_and_flag_off_refused(self):
        from core.models import FeatureFlag
        from core import feature_flags as FF
        FeatureFlag.objects.filter(key="retention_auto").update(enabled_all=False,
                                                               enabled_play=False)
        FF.invalidate()
        self.assertIn(self.oc.get(API + "bizai/crm/ladder").status_code, (403, 404))

    def test_customers_back_reach_the_outcome_card(self):
        auto = RetentionAutomation.objects.create(business=self.biz, kind="winback",
                                                  name="Win-back 30", enabled=True)
        snd = RetentionSend.objects.create(automation=auto, business=self.biz,
                                           audience_key=self.cust.phone_key, ref_key="wb:1",
                                           customer=self.cust, status="sent")
        RetentionSend.objects.filter(pk=snd.pk).update(created_at=timezone.now() - timedelta(days=1))
        s = Sale.objects.create(user=self.owner, business=self.biz, customer=self.cust,
                                total=120000)
        out = BA.outcomes(self.biz)
        row = {r["key"]: r for r in out["rows"]}["customers_back"]
        self.assertEqual((row["count"], row["bdt"]), (1, "1200"))
        self.assertTrue(RetentionSend.objects.filter(purchase_sale=s).exists())
