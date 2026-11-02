"""crmauto — CRM automation (owner Part 1 h).

New rules on top of retention automation: reorder reminder (from the
customer's own purchase gap), after-delivery feedback (1-5, a low rating
alerts the owner), quote follow-up; per-rule daily cap; cost shown before
turning on; audit log; transparent customer score. Every rule: off until the
owner turns it on, quiet hours, STOP honoured, Meta 24 h window.
"""
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone

from core import retention_service as S
from core.logic import customer_score as CS
from core.logic import msg_guard as MG
from core.logic import retention as R
from core.models import (BizAuditLog, BizOptOut, ChatThread, Customer, KhataEntry,
                         KhataParty, Order, RetentionSend, SaleLine, SellerChannel, User)
from core.tests_retention import DAY1, _Base, dhaka


# ============================================================ pure
class ReorderPureTests(SimpleTestCase):
    def buys(self, *days_ago, base=DAY1):
        return [(i + 1, base - timedelta(days=d)) for i, d in enumerate(days_ago)]

    def test_gap_is_median_of_distinct_days(self):
        self.assertIsNone(R.purchase_gap_days([DAY1]))
        self.assertIsNone(R.purchase_gap_days([DAY1, DAY1 + timedelta(hours=1)]))
        ds = [DAY1 - timedelta(days=d) for d in (40, 30, 20, 9)]
        self.assertEqual(R.purchase_gap_days(ds), 10)     # gaps 10,10,11 -> 10

    def test_window_once_per_customer(self):
        row = {"key": "017", "product": "চাল", "purchases": self.buys(30, 20, 10)}
        # gap 10, last 10 days ago, days_before 1 -> due from day 9 to day 20
        ev = R.due_reorder([row], DAY1, 2, 1)
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["values"], {"product": "চাল", "days": 10})
        self.assertEqual(ev[0]["ref"], "ro:3")             # the last purchase
        # not yet: last purchase 5 days ago
        row2 = {"key": "017", "product": "চাল", "purchases": self.buys(25, 15, 5)}
        self.assertEqual(R.due_reorder([row2], DAY1, 2, 1), [])
        # too late (> 2 x gap): winback's job
        row3 = {"key": "017", "product": "চাল", "purchases": self.buys(45, 35, 25)}
        self.assertEqual(R.due_reorder([row3], DAY1, 2, 1), [])

    def test_min_purchases_and_gap_bounds(self):
        row = {"key": "017", "product": "x", "purchases": self.buys(20, 10)}
        self.assertEqual(len(R.due_reorder([row], DAY1, 2, 1)), 1)
        self.assertEqual(R.due_reorder([row], DAY1, 3, 1), [])           # needs 3 buys
        daily = {"key": "017", "product": "x", "purchases": self.buys(3, 2, 1)}
        self.assertEqual(R.due_reorder([daily], DAY1, 2, 0), [])        # gap 1 < 3: no nudge

    def test_one_event_per_customer_most_overdue(self):
        a = {"key": "017", "product": "চাল", "purchases": self.buys(30, 20, 10)}
        b = {"key": "017", "product": "তেল", "purchases": self.buys(36, 24, 12)}
        ev = R.due_reorder([a, b], DAY1, 2, 0)
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["values"]["product"], "চাল")    # a tie keeps the first row
        c = {"key": "018", "product": "দুধ", "purchases": self.buys(28, 21, 14)}
        keys = sorted(e["key"] for e in R.due_reorder([a, c], DAY1, 2, 0))
        self.assertEqual(keys, ["017", "018"])


class DeliveryQuotePureTests(SimpleTestCase):
    def test_delivery_window(self):
        o = {"order_id": 7, "key": "017", "delivered_at": DAY1 - timedelta(days=1, hours=1),
             "product": "শাড়ি"}
        self.assertEqual(R.due_delivery([o], DAY1, 1)[0]["ref"], "dl:7")
        self.assertEqual(R.due_delivery([o], DAY1, 2), [])
        self.assertEqual(R.due_delivery([dict(o, delivered_at=DAY1 - timedelta(days=5))], DAY1, 1), [])
        self.assertEqual(R.due_delivery([dict(o, delivered_at=None)], DAY1, 0), [])

    def test_quote_open_only_not_expired(self):
        q = {"quote_id": 3, "key": "017", "created_at": DAY1 - timedelta(days=2, hours=1),
             "state": "viewed", "valid_until": DAY1 + timedelta(days=3), "link": "L",
             "total_poisha": 125000}
        ev = R.due_quote([q], DAY1, 2)
        self.assertEqual((ev[0]["ref"], ev[0]["values"]["total_poisha"]), ("qf:3", 125000))
        for bad in (dict(q, state="accepted"), dict(q, state="declined"),
                    dict(q, valid_until=DAY1 - timedelta(minutes=1)),
                    dict(q, created_at=DAY1 - timedelta(hours=5))):
            self.assertEqual(R.due_quote([bad], DAY1, 2), [])

    def test_parse_rating(self):
        for txt, want in (("৪", 4), ("4/5", 4), ("5 ধন্যবাদ", 5), ("⭐⭐", 2), ("খারাপ", 2),
                          ("Good!", 4), ("১", 1)):
            self.assertEqual(R.parse_rating(txt), want, txt)
        for txt in ("", "10", "পেয়েছি, কাল আরেকটা লাগবে", "0", "6"):
            self.assertIsNone(R.parse_rating(txt), txt)

    def test_daily_cap_param_on_every_kind(self):
        for k in R.KINDS:
            self.assertEqual(R.normalize_params(k, {})["daily_cap"], 50)
        self.assertEqual(R.normalize_params("reorder", {"daily_cap": 99999})["daily_cap"], 1000)
        self.assertEqual(R.normalize_params("reorder", {"daily_cap": 0})["daily_cap"], 1)
        for k in R.KINDS:   # every default template only uses its own variables
            for t in R.DEFAULT_TEMPLATES[k]:
                self.assertEqual(R.template_problems(k, t), [], k)


class ScorePureTests(SimpleTestCase):
    def test_every_point_has_a_written_reason(self):
        r = CS.score({"days_since_last": 12, "purchases": 4, "spend_poisha": 600000,
                      "replied_recent": True, "due_poisha": 20000}, "bn")
        ids = [p["id"] for p in r["parts"]]
        self.assertEqual(ids, ["recent_30", "freq_3", "spend_5k", "replied", "due"])
        self.assertEqual(r["score"], 30 + 18 + 12 + 10 - 10)
        self.assertEqual(r["band"], "warm")
        self.assertEqual(r["parts"][0]["value"], "১২")
        self.assertTrue(all(p["rule"] for p in r["parts"]))
        self.assertEqual(sum(p["points"] for p in r["parts"]), r["score"])

    def test_bounds_bands_and_flags(self):
        self.assertEqual(CS.score({})["score"], 0)
        self.assertEqual(CS.score({})["parts"], [])          # nothing known -> nothing invented
        low = CS.score({"purchases": 1, "returns": 2, "last_rating": 1})
        self.assertEqual((low["score"], low["band"]), (0, "cold"))     # never below 0
        self.assertTrue(CS.score({"opted_out": True})["do_not_message"])
        self.assertLessEqual(CS.max_possible(), 100)
        book = CS.rule_book("en")
        self.assertEqual(len(book["rules"]), len(CS.RULES))
        self.assertEqual(CS.score({"days_since_last": 60}, "en")["parts"][0]["rule"],
                         "Bought 31-90 days ago")


# ============================================================ DB / API
class _CrmBase(_Base):
    def line_sale(self, cust, at, product="চাল", total=50000):
        s = self.sale(cust, at, total=total)
        SaleLine.objects.create(sale=s, product_name=product, qty=1, unit_price=total)
        return s

    def more_customers(self, n):
        out = []
        for i in range(n):
            ph = "0171000010%d" % i
            User.objects.create_user(name="C%d" % i, phone=ph, password="pw-123456")
            out.append(Customer.objects.create(user=self.owner, business=self.biz,
                                               name="C%d" % i, phone=ph, phone_key=ph))
        return out

    def reorder_rule(self, **kw):
        d = {"kind": "reorder", "template_bn": R.DEFAULT_TEMPLATES["reorder"][0],
             "template_en": R.DEFAULT_TEMPLATES["reorder"][1],
             "params": {"min_purchases": 2, "days_before": 1}}
        d.update(kw)
        return self.create(**d)


class ReorderFlowTests(_CrmBase):
    def setUp(self):
        super().setUp()
        for d in (30, 20, 10):
            self.line_sale(self.cust, DAY1 - timedelta(days=d))

    def test_off_by_default_nothing_sends(self):
        a = self.reorder_rule(enabled=False)
        self.assertFalse(a["enabled"])
        self.assertEqual(S.run_all(now=DAY1)["sent"], 0)
        self.assertEqual(RetentionSend.objects.count(), 0)

    def test_sends_once_with_own_gap_in_bangla(self):
        self.reorder_rule()
        self.assertEqual(S.run_all(now=DAY1)["sent"], 1)
        s = RetentionSend.objects.get()
        self.assertIn("১০", s.text)
        self.assertIn("চাল", s.text)
        self.assertIn("বন্ধ করুন", s.text)          # STOP path in every message
        self.assertEqual(S.run_all(now=DAY1 + timedelta(hours=2))["sent"], 0)

    def test_quiet_hours_and_send_hour(self):
        self.reorder_rule(send_hour=14)
        self.assertEqual(S.run_all(now=dhaka(2026, 10, 27, 22, 0))["sent"], 0)
        self.assertEqual(S.run_all(now=dhaka(2026, 10, 27, 11, 0))["sent"], 0)   # before 14:00
        self.assertEqual(S.run_all(now=dhaka(2026, 10, 27, 14, 5))["sent"], 1)

    def test_stop_respected(self):
        BizOptOut.objects.create(business=self.biz, key="01710000002", source="in_app")
        self.reorder_rule()
        self.assertEqual(S.run_all(now=DAY1)["sent"], 0)

    def _sales_relative_to_now(self):
        # preview runs on the real clock: rebuild the habit around "now"
        from core.models import Sale
        Sale.objects.all().delete()
        now = timezone.now()
        for d in (30, 20, 10):
            self.line_sale(self.cust, now - timedelta(days=d))

    def test_preview_shows_cost_cap_and_sample(self):
        self._sales_relative_to_now()
        r = self.oc.post("/api/v1/retention/preview", {
            "kind": "reorder", "channel": "in_app", "params": {"daily_cap": 5},
            "template_bn": R.DEFAULT_TEMPLATES["reorder"][0]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.data["cost"]["basis"], "in_app")
        self.assertEqual(r.data["cost"]["per_message"], 0)
        self.assertEqual(r.data["daily_cap"], 5)
        self.assertEqual(r.data["audience"], 1)
        self.assertIn("চাল", r.data["sample_text"])

    def test_sms_preview_cost_counts_parts(self):
        self._sales_relative_to_now()
        from core import billing
        per = int(billing.cfg()["action_costs"]["sms"]["credits"])
        r = self.oc.post("/api/v1/retention/preview", {
            "kind": "reorder", "channel": "sms",
            "template_bn": R.DEFAULT_TEMPLATES["reorder"][0]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        c = r.data["cost"]
        self.assertEqual(c["basis"], "sms_parts")
        self.assertEqual(c["per_message"], per * c["segments"])
        self.assertGreaterEqual(c["segments"], 2)        # Bangla = 70 chars a part


class DailyCapAndAuditTests(_CrmBase):
    def test_rule_daily_cap_stops_and_is_audited(self):
        for c in [self.cust] + self.more_customers(2):
            self.sale(c, DAY1 - timedelta(days=2, hours=2))
        a = self.create(params={"days_after": 2, "daily_cap": 2})
        st = S.run_all(now=DAY1)
        self.assertEqual(st["sent"], 2)
        self.assertEqual(S.run_all(now=DAY1 + timedelta(hours=1))["sent"], 0)   # same day
        self.assertEqual(S.run_all(now=DAY1 + timedelta(days=1))["sent"], 1)    # next day
        row = BizAuditLog.objects.filter(business=self.biz, action="auto_run").order_by("id").first()
        self.assertEqual((row.detail["sent"], row.detail["rule_cap"], row.detail["id"]),
                         (2, True, a["id"]))

    def test_owner_actions_audited(self):
        a = self.create(enabled=False)
        url = "/api/v1/retention/automations/%d" % a["id"]
        self.assertEqual(self.oc.patch(url, {"enabled": True}, format="json").status_code, 200)
        self.assertEqual(self.oc.patch(url, {"template_bn": "{name} ধন্যবাদ"},
                                       format="json").status_code, 200)
        self.assertEqual(self.oc.patch(url, {"enabled": False}, format="json").status_code, 200)
        self.assertEqual(self.oc.patch("/api/v1/retention/settings", {"business_daily": 20},
                                       format="json").status_code, 200)
        self.assertEqual(self.oc.delete(url).status_code, 204)
        acts = list(BizAuditLog.objects.filter(business=self.biz).order_by("id")
                    .values_list("action", flat=True))
        self.assertEqual(acts, ["auto_create", "auto_on", "auto_edit", "auto_off", "caps_edit",
                                "auto_delete"])
        r = self.oc.get("/api/v1/retention/audit")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.data["rows"]), 6)
        self.assertTrue(r.data["rows"][0]["text"].startswith("মুছলেন"))
        self.assertEqual(r.data["rows"][0]["by"], "Rina")
        self.assertNotIn("01710000002", str(r.data))      # never a full phone

    def test_toggle_alone_is_not_an_edit(self):
        a = self.create(enabled=False)
        self.oc.patch("/api/v1/retention/automations/%d" % a["id"], {"enabled": True},
                      format="json")
        self.assertFalse(BizAuditLog.objects.filter(action="auto_edit").exists())


class DeliveryFeedbackTests(_CrmBase):
    def setUp(self):
        super().setUp()
        sale = self.sale(self.cust, DAY1 - timedelta(days=1, hours=2), total=150000)
        self.order = Order.objects.create(user=self.owner, business=self.biz, customer_name="Karim",
                                          customer_phone="01710000002", status="delivered",
                                          items=[{"name": "শাড়ি", "qty": 1, "price": 1500}],
                                          sale=sale)
        self.create(kind="delivery_feedback", template_bn=R.DEFAULT_TEMPLATES["delivery_feedback"][0],
                    template_en="", params={"days_after": 1})

    def _reply(self, text):
        S.run_all(now=DAY1)
        s = RetentionSend.objects.get()
        self.assertIn("শাড়ি", s.text)
        self.assertEqual(s.ref_key, "dl:%d" % self.order.id)
        with mock.patch("core.bizagent_service.notify_seller") as ns:
            r = self.cc.post("/api/v1/retention/inbox/%d/reply" % s.id, {"text": text},
                             format="json")
            self.assertEqual(r.status_code, 200)
        return ns

    def test_low_rating_alerts_owner(self):
        ns = self._reply("২")
        fb = BizAuditLog.objects.get(business=self.biz, action="feedback")
        self.assertEqual(fb.detail["rating"], 2)
        kinds = [c.args[1] for c in ns.call_args_list]
        self.assertIn("unhappy_customer", kinds)

    def test_good_rating_logged_no_alert(self):
        ns = self._reply("5")
        self.assertEqual(BizAuditLog.objects.get(action="feedback").detail["rating"], 5)
        self.assertNotIn("unhappy_customer", [c.args[1] for c in ns.call_args_list])

    def test_not_delivered_not_asked(self):
        Order.objects.filter(pk=self.order.pk).update(status="shipped")
        self.assertEqual(S.run_all(now=DAY1)["sent"], 0)


class QuoteFollowupTests(_CrmBase):
    def setUp(self):
        super().setUp()
        from crm import shop_quote as SQ
        from crm.models import ShopQuote
        self.q = ShopQuote.objects.create(
            business=self.biz, customer_name="Karim", customer_phone="01710000002",
            phone_key="01710000002", total_poisha=125000, nonce=SQ.new_nonce(),
            valid_until=DAY1 + timedelta(days=5), state="viewed")
        ShopQuote.objects.filter(pk=self.q.pk).update(created_at=DAY1 - timedelta(days=2, hours=1))
        self.create(kind="quote_followup", template_bn=R.DEFAULT_TEMPLATES["quote_followup"][0],
                    template_en="", params={"days_after": 2})

    def test_one_reminder_with_link(self):
        self.assertEqual(S.run_all(now=DAY1)["sent"], 1)
        s = RetentionSend.objects.get()
        self.assertIn("/q/", s.text)
        self.assertIn("১,২৫০", s.text)
        self.assertEqual(S.run_all(now=DAY1 + timedelta(days=1))["sent"], 0)

    def test_accepted_quote_not_chased(self):
        type(self.q).objects.filter(pk=self.q.pk).update(state="accepted")
        self.assertEqual(S.run_all(now=DAY1)["sent"], 0)


class MetaWindowNewKindsTests(_CrmBase):
    def test_reorder_on_whatsapp_outside_24h_needs_template(self):
        ch = SellerChannel.objects.create(business=self.biz, kind="whatsapp_cloud",
                                          external_id="pn-1", status="connected", test_mode=True)
        t = ChatThread.objects.create(user=self.owner, business=self.biz, channel="whatsapp_cloud",
                                      seller_channel=ch, customer_phone="8801710000002",
                                      external_user_id="8801710000002", lang="bn")
        ChatThread.objects.filter(pk=t.pk).update(last_inbound_at=DAY1 - timedelta(days=3))
        for d in (30, 20, 10):
            self.line_sale(self.cust, DAY1 - timedelta(days=d))
        self.reorder_rule(channel="whatsapp")
        S.run_all(now=DAY1)
        s = RetentionSend.objects.get()
        self.assertEqual((s.status, s.reason), ("blocked", "outside_24h_window_template_required"))

    def test_new_kinds_refuse_utility_template(self):
        SellerChannel.objects.create(business=self.biz, kind="whatsapp_cloud",
                                     external_id="pn-1", status="connected", test_mode=True)
        for k in ("reorder", "delivery_feedback", "quote_followup"):
            r = self.oc.post("/api/v1/retention/automations", {
                "kind": k, "channel": "whatsapp", "template_bn": "x",
                "wa_template": {"name": "t", "category": "utility", "approved": True}},
                format="json")
            self.assertEqual(r.status_code, 400, k)
            self.assertEqual(r.data["error"], "promo_in_utility_template")


class ScoreApiTests(_CrmBase):
    def test_scores_with_reasons(self):
        now = timezone.now()
        for d in (40, 20, 5):
            self.sale(self.cust, now - timedelta(days=d), total=300000)
        party = KhataParty.objects.create(business=self.biz, book="customer", name="Karim",
                                          phone="01710000002")
        KhataEntry.objects.create(party=party, direction="gave", amount_poisha=50000,
                                  at=now - timedelta(days=3))
        Customer.objects.create(user=self.owner, business=self.biz, name="Never", phone="01710000099",
                                phone_key="01710000099")
        r = self.oc.get("/api/v1/retention/scores")
        self.assertEqual(r.status_code, 200, r.content)
        people = r.data["people"]
        self.assertEqual(len(people), 1)             # "Never" has no signal: no fake score
        p = people[0]
        ids = [x["id"] for x in p["parts"]]
        self.assertEqual(ids, ["recent_30", "freq_3", "spend_5k", "due"])
        self.assertEqual(p["score"], 30 + 18 + 12 - 10)
        self.assertNotIn("01710000002", str(r.data))
        self.assertTrue(r.data["rule_book"]["rules"])

    def test_staff_refused(self):
        from rest_framework.test import APIClient

        from core.models import BusinessStaff
        staff = User.objects.create_user(name="S", phone="01710000077", password="pw-123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="cashier", active=True)
        c = APIClient()
        c.force_authenticate(staff)
        for u in ("scores", "audit"):
            self.assertEqual(c.get("/api/v1/retention/%s?business=%d" % (u, self.biz.id))
                             .status_code, 403, u)
