"""retention1 — Retention automation (big-week H).

Two-account end-to-end on the backend: a Business-plan shop owner creates an
automation, the customer (another Assisto account) receives it in-app,
replies, buys again (honest attribution) and STOPs — and the STOP is honoured
by every other automation of that shop. Plus: caps across automations, quiet
hours, daily business cap, owner may only lower caps, Meta 24 h window and
template rules on WhatsApp, Messenger outside 24 h refused, SMS credits
charged / refused at zero / refunded on gateway failure, the flag gate (403),
the plan gate (402), staff refused, the SMS stop link, and the pure guard.
"""
from datetime import date, datetime, timedelta
from datetime import timezone as dt_tz
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core import retention_service as S
from core.logic import msg_guard as MG
from core.logic import retention as R
from core.models import (BizOptOut, BusinessProfile, ChatThread, Customer, KhataEntry,
                         KhataParty, NotifEvent, RetentionSend, Sale, SellerChannel, User)

FF_KEY = "retention_auto"


def dhaka(y, m, d, hh, mm=0):
    return datetime(y, m, d, hh, mm, tzinfo=MG.DHAKA)


DAY1 = dhaka(2026, 10, 27, 11, 30)


# ============================================================ pure guard
class GuardPureTests(SimpleTestCase):
    def test_quiet_hours_boundaries(self):
        self.assertTrue(MG.in_quiet_hours(dhaka(2026, 10, 27, 21, 0)))
        self.assertTrue(MG.in_quiet_hours(dhaka(2026, 10, 27, 8, 59)))
        self.assertFalse(MG.in_quiet_hours(dhaka(2026, 10, 27, 9, 0)))
        self.assertFalse(MG.in_quiet_hours(dhaka(2026, 10, 27, 20, 59)))
        # UTC input is converted (15:30 UTC = 21:30 Dhaka)
        self.assertTrue(MG.in_quiet_hours(datetime(2026, 10, 27, 15, 30, tzinfo=dt_tz.utc)))
        nxt = MG.next_allowed_at(dhaka(2026, 10, 27, 22, 0))
        self.assertEqual((nxt.day, nxt.hour), (28, 9))
        nxt = MG.next_allowed_at(dhaka(2026, 10, 28, 3, 0))
        self.assertEqual((nxt.day, nxt.hour), (28, 9))

    def test_caps_owner_can_only_lower(self):
        smax = MG.server_caps({})
        self.assertEqual(smax, {"per_customer_day": 1, "per_customer_week": 2, "business_daily": 100})
        # the pricing block can lower, never exceed the hard max
        self.assertEqual(MG.server_caps({"max_per_customer_week": 9})["per_customer_week"], 2)
        self.assertEqual(MG.server_caps({"max_business_daily": 20})["business_daily"], 20)
        self.assertEqual(MG.effective_caps({"per_customer_week": 9, "business_daily": 5}, smax),
                         {"per_customer_day": 1, "per_customer_week": 2, "business_daily": 5})
        self.assertEqual(MG.validate_owner_caps({"per_customer_week": 3}, smax),
                         ["cap_above_server_max"])
        self.assertEqual(MG.validate_owner_caps({"business_daily": 0}, smax), ["cap_too_low"])
        self.assertEqual(MG.validate_owner_caps({"per_customer_week": 1}, smax), [])

    def test_decide_order(self):
        caps = {"per_customer_day": 1, "per_customer_week": 2, "business_daily": 10}
        kw = dict(now=DAY1, sent_customer_day=0, sent_customer_week=0,
                  sent_business_day=0, caps=caps)
        self.assertEqual(MG.decide(opted_out=False, **kw).reason, "ok")
        self.assertEqual(MG.decide(opted_out=True, **kw).reason, "opted_out")
        self.assertEqual(MG.decide(opted_out=False, **dict(kw, now=dhaka(2026, 10, 27, 23))).reason,
                         "quiet_hours")
        self.assertEqual(MG.decide(opted_out=False, **dict(kw, sent_business_day=10)).reason,
                         "business_daily_cap")
        self.assertEqual(MG.decide(opted_out=False, **dict(kw, sent_customer_day=1)).reason,
                         "customer_daily_cap")
        self.assertEqual(MG.decide(opted_out=False, **dict(kw, sent_customer_week=2)).reason,
                         "customer_weekly_cap")
        # a reminder the customer asked for skips only the weekly marketing cap
        self.assertTrue(MG.decide(opted_out=False, transactional=True,
                                  **dict(kw, sent_customer_week=2)).ok)
        self.assertFalse(MG.decide(opted_out=True, transactional=True, **kw).ok)

    def test_meta_plan_matrix(self):
        ok_t = {"name": "miss_you", "approved": True, "category": "marketing", "has_stop": True}
        self.assertEqual(MG.meta_plan("whatsapp", True), ("free_form", "ok"))
        self.assertEqual(MG.meta_plan("whatsapp", False, {}),
                         ("blocked", "outside_24h_window_template_required"))
        self.assertEqual(MG.meta_plan("whatsapp", False, dict(ok_t, approved=False)),
                         ("blocked", "template_not_approved"))
        self.assertEqual(MG.meta_plan("whatsapp", False, dict(ok_t, category="utility")),
                         ("blocked", "promo_in_utility_template"))
        self.assertEqual(MG.meta_plan("whatsapp", False, dict(ok_t, category="utility"),
                                      purpose="utility"), ("template", "ok"))
        self.assertEqual(MG.meta_plan("whatsapp", False, dict(ok_t, has_stop=False)),
                         ("blocked", "template_needs_stop_option"))
        self.assertEqual(MG.meta_plan("whatsapp", False, ok_t), ("template", "ok"))
        self.assertEqual(MG.meta_plan("messenger", False, ok_t), ("blocked", "outside_24h_window"))
        self.assertEqual(MG.meta_plan("in_app", False), ("free_form", "ok"))

    def test_stop_words_and_footer(self):
        for t in ("STOP", "stop", "স্টপ", "বন্ধ করুন", "আর মেসেজ দিবেন না", "Unsubscribe"):
            self.assertTrue(MG.is_stop_text(t), t)
        for t in ("", "thanks", "কত দাম?", "stopwatch ache?"):
            self.assertFalse(MG.is_stop_text(t), t)
        for ch in ("in_app", "sms", "whatsapp", "messenger"):
            for lang in ("bn", "en"):
                self.assertTrue(MG.stop_footer(lang, ch, "https://x/u/1-a"))
        self.assertIn("https://x/u/1-a", MG.stop_footer("bn", "sms", "https://x/u/1-a"))


class RetentionPureTests(SimpleTestCase):
    def test_render_fallbacks_and_footer(self):
        txt = R.compose("{name}, ধন্যবাদ {shop}!", {"name": "", "shop": "Rina Store"}, "bn", "in_app")
        self.assertTrue(txt.startswith("গ্রাহক, ধন্যবাদ Rina Store!"))
        self.assertIn("বন্ধ করুন", txt)
        self.assertNotIn("{", R.compose("Hi {name} {product}", {}, "en", "whatsapp"))

    def test_validation(self):
        clean, p = R.validate({"kind": "winback", "template_bn": "{name} {coupon}"})
        self.assertIn("unknown_variable", p)
        clean, p = R.validate({"kind": "winback"})
        self.assertIn("template_required", p)
        clean, p = R.validate({"kind": "winback", "template_en": "x", "channel": "sms"},
                              channels_ready=["in_app"])
        self.assertIn("channel_not_connected", p)
        clean, p = R.validate({"kind": "winback", "template_en": "x", "send_hour": 22})
        self.assertIn("bad_send_hour", p)
        clean, p = R.validate({"kind": "winback", "template_en": "x", "channel": "whatsapp",
                               "wa_template": {"name": "t", "category": "utility"}})
        self.assertIn("promo_in_utility_template", p)
        clean, p = R.validate({"kind": "khata_due", "template_en": "x", "channel": "whatsapp",
                               "wa_template": {"name": "t", "category": "utility"},
                               "params": {"every_days": 1, "min_due_taka": "50"}})
        self.assertEqual(p, [])
        self.assertEqual(clean["params"], {"min_due_taka": 50, "every_days": 7})   # clamped
        self.assertEqual(R.validate({"kind": "spam"})[1], ["bad_kind"])

    def test_sms_segments_and_money(self):
        self.assertEqual(R.sms_segments("a" * 160), 1)
        self.assertEqual(R.sms_segments("a" * 161), 2)
        self.assertEqual(R.sms_segments("ক" * 70), 1)
        self.assertEqual(R.sms_segments("ক" * 71), 2)
        self.assertEqual(R.money_text(123450, "bn"), "১,২৩৪")
        self.assertEqual(R.money_text(123450, "en"), "1,234")

    def test_attribution_last_touch_each_sale_once(self):
        t0 = DAY1
        sends = [{"id": 1, "key": "a", "at": t0}, {"id": 2, "key": "a", "at": t0 + timedelta(days=2)},
                 {"id": 3, "key": "b", "at": t0}]
        sales = [{"id": 10, "key": "a", "at": t0 + timedelta(days=3), "total": 500},
                 {"id": 11, "key": "a", "at": t0 + timedelta(days=4), "total": 700},
                 {"id": 12, "key": "b", "at": t0 + timedelta(days=9), "total": 900}]
        got = R.attribute(sends, sales, 7)
        self.assertEqual(got, {2: (10, 500)})     # latest touch; b is outside 7 days

    def test_triggers(self):
        now = DAY1
        self.assertEqual(len(R.due_thanks([{"sale_id": 1, "key": "k", "at": now - timedelta(days=2, hours=1)}],
                                          now, 2)), 1)
        self.assertEqual(R.due_thanks([{"sale_id": 1, "key": "k", "at": now - timedelta(days=6)}], now, 2), [])
        self.assertEqual(len(R.due_winback([{"key": "k", "last_sale_id": 3, "at": now - timedelta(days=50)}],
                                           now, 45)), 1)
        self.assertEqual(R.due_winback([{"key": "k", "last_sale_id": 3, "at": now - timedelta(days=400)}],
                                       now, 45), [])
        self.assertEqual(len(R.due_birthday([{"key": "k", "birthday": date(1990, 10, 27)}], now)), 1)
        self.assertEqual(R.due_birthday([{"key": "k", "birthday": date(1990, 10, 26)}], now), [])
        self.assertEqual(len(R.due_khata([{"party_id": 1, "key": "k", "due_poisha": 20000}], now, 100, 14)), 1)
        self.assertEqual(R.due_khata([{"party_id": 1, "key": "k", "due_poisha": 5000}], now, 100, 14), [])


# ============================================================ API / service
def _flag_on():
    from core import feature_flags as FF
    from core.models import FeatureFlag
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=FF_KEY).update(enabled_all=True, enabled_play=True)
    FF.invalidate()


class _Base(APITestCase):
    def setUp(self):
        _flag_on()
        from core import feature_flags as FF
        self.addCleanup(FF.invalidate)
        self.owner = User.objects.create_user(name="Rina", phone="01710000001", password="pw-123456")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=300)
        self.owner.save()
        # the Business plan's monthly pool lands first; tests start from 0
        from core import billing
        billing.ensure_monthly_pool(self.owner)
        User.objects.filter(pk=self.owner.pk).update(ai_credits=0)
        self.owner.refresh_from_db()
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rina Store")
        self.cust_user = User.objects.create_user(name="Karim", phone="01710000002",
                                                  password="pw-123456")
        self.cust_user.language = "bn"
        self.cust_user.save()
        self.cust = Customer.objects.create(user=self.owner, business=self.biz, name="Karim",
                                            phone="01710000002", phone_key="01710000002")
        self.oc = APIClient()
        self.oc.force_authenticate(self.owner)
        self.cc = APIClient()
        self.cc.force_authenticate(self.cust_user)

    def sale(self, cust, at, total=50000):
        s = Sale.objects.create(user=self.owner, business=self.biz, customer=cust, total=total)
        Sale.objects.filter(pk=s.pk).update(created_at=at)
        return s

    def create(self, **body):
        d = {"kind": "thanks_review", "channel": "in_app", "enabled": True,
             "template_bn": R.DEFAULT_TEMPLATES["thanks_review"][0],
             "template_en": R.DEFAULT_TEMPLATES["thanks_review"][1],
             "params": {"days_after": 2}, "send_hour": 10}
        d.update(body)
        r = self.oc.post("/api/v1/retention/automations", d, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.data


class EndToEndTests(_Base):
    def test_two_accounts_create_receive_reply_buy_stop(self):
        # empty overview first (first-run state)
        r = self.oc.get("/api/v1/retention")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["plan_ok"])
        self.assertEqual(r.data["automations"], [])
        self.assertEqual(r.data["caps"]["per_customer_week"], 2)
        self.assertIn("in_app", r.data["channels_ready"])
        self.assertEqual(len(r.data["kinds"]), 5)

        self.sale(self.cust, DAY1 - timedelta(days=2, hours=2))
        # draft preview: honest count + rendered sample with STOP footer
        r = self.oc.post("/api/v1/retention/preview",
                         {"kind": "thanks_review", "channel": "in_app", "params": {"days_after": 2},
                          "template_bn": "{name}, ধন্যবাদ!"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["audience"], 1)
        self.assertEqual(r.data["on_assisto"], 1)
        self.assertIn("বন্ধ করুন", r.data["sample_text"])

        a = self.create()
        st = S.run_all(now=DAY1)
        self.assertEqual(st["sent"], 1)
        snd = RetentionSend.objects.get()
        self.assertEqual(snd.recipient, self.cust_user)
        self.assertIn("Rina Store", snd.text)
        self.assertIn("বন্ধ করুন", snd.text)           # STOP path in every message
        self.assertTrue(NotifEvent.objects.filter(user=self.cust_user, route="retention_inbox").exists())
        # once-only per event
        self.assertEqual(S.run_all(now=DAY1 + timedelta(hours=1))["sent"], 0)

        # customer side: inbox -> delivered, reply
        r = self.cc.get("/api/v1/retention/inbox")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.data["messages"]), 1)
        mid = r.data["messages"][0]["id"]
        self.assertEqual(r.data["messages"][0]["shop"], "Rina Store")
        r = self.cc.post("/api/v1/retention/inbox/%d/reply" % mid, {"text": "খুব ভালো!"}, format="json")
        self.assertEqual(r.status_code, 200)
        # the owner cannot read someone else's inbox row
        self.assertEqual(self.oc.post("/api/v1/retention/inbox/%d/reply" % mid, {"text": "x"},
                                      format="json").status_code, 404)

        # a purchase after the message (inside 7 days) is attributed
        self.sale(self.cust, DAY1 + timedelta(days=1), total=80000)
        r = self.oc.get("/api/v1/retention/automations/%d/results" % a["id"])
        self.assertEqual(r.status_code, 200)
        d = r.data
        self.assertEqual((d["sent"], d["delivered"], d["replied"], d["purchases"]), (1, 1, 1, 1))
        self.assertEqual(d["revenue_poisha"], 80000)
        self.assertEqual(d["recent"][0]["reply_text"], "খুব ভালো!")

        # STOP from the customer: instant, across every automation of this shop
        r = self.cc.post("/api/v1/retention/inbox/%d/stop" % mid)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(BizOptOut.objects.filter(business=self.biz, key="01710000002").exists())
        self.cust.birthday = date(1990, 11, 5)
        self.cust.save()
        self.create(kind="birthday", template_bn="শুভ জন্মদিন {name}", template_en="")
        st = S.run_all(now=dhaka(2026, 11, 5, 11))
        self.assertEqual(st["sent"], 0)
        self.assertEqual(RetentionSend.objects.count(), 1)
        r = self.cc.get("/api/v1/retention/inbox")
        self.assertTrue(r.data["messages"][0]["stopped"])
        r = self.oc.get("/api/v1/retention/automations/%d/results" % a["id"])
        self.assertEqual(r.data["opted_out"], 1)

    def test_caps_across_automations_and_quiet_hours(self):
        self.sale(self.cust, DAY1 - timedelta(days=2, hours=2))
        party = KhataParty.objects.create(business=self.biz, book="customer", name="Karim",
                                          phone="+8801710000002")
        KhataEntry.objects.create(party=party, direction="gave", amount_poisha=30000, at=DAY1 - timedelta(days=20))
        self.create()                                                     # thanks
        self.create(kind="khata_due", template_bn="{name}, ৳{due} বাকি", template_en="",
                    params={"min_due_taka": 100, "every_days": 30})
        self.cust.birthday = date(1991, 10, 29)
        self.cust.save()
        self.create(kind="birthday", template_bn="শুভ জন্মদিন {name}", template_en="")

        # quiet hours: nothing at 22:00 or 07:00
        self.assertEqual(S.run_all(now=dhaka(2026, 10, 26, 22))["sent"], 0)
        self.assertEqual(S.run_all(now=dhaka(2026, 10, 27, 7))["sent"], 0)
        self.assertEqual(RetentionSend.objects.count(), 0)
        # day 1: thanks goes, khata held by the 1-per-day cap
        self.assertEqual(S.run_all(now=DAY1)["sent"], 1)
        # day 2: the khata reminder
        self.assertEqual(S.run_all(now=DAY1 + timedelta(days=1))["sent"], 1)
        # day 3: birthday due but the weekly cap (2) is reached
        self.assertEqual(S.run_all(now=DAY1 + timedelta(days=2))["sent"], 0)
        kinds = list(RetentionSend.objects.order_by("created_at").values_list("automation__kind", flat=True))
        self.assertEqual(kinds, ["thanks_review", "khata_due"])
        self.assertIn("৩০০", RetentionSend.objects.get(automation__kind="khata_due").text)

    def test_business_daily_cap_and_owner_can_only_lower(self):
        r = self.oc.patch("/api/v1/retention/settings", {"per_customer_week": 3}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["error"], "cap_above_server_max")
        r = self.oc.patch("/api/v1/retention/settings", {"business_daily": 1}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["caps"]["business_daily"], 1)
        u3 = User.objects.create_user(name="Mita", phone="01710000003", password="pw-123456")
        c3 = Customer.objects.create(user=self.owner, business=self.biz, name="Mita",
                                     phone="01710000003", phone_key="01710000003")
        self.sale(self.cust, DAY1 - timedelta(days=2, hours=2))
        self.sale(c3, DAY1 - timedelta(days=2, hours=3))
        self.create()
        self.assertEqual(S.run_all(now=DAY1)["sent"], 1)
        self.assertEqual(RetentionSend.objects.filter(status__in=MG.SENT_STATES).count(), 1)
        self.assertTrue(u3)
        # next day the second customer is still inside the 3-day window
        self.assertEqual(S.run_all(now=DAY1 + timedelta(days=1))["sent"], 1)

    def test_customer_not_on_assisto_is_skipped_honestly(self):
        c = Customer.objects.create(user=self.owner, business=self.biz, name="Nobody",
                                    phone="01799999999", phone_key="01799999999")
        self.sale(c, DAY1 - timedelta(days=2, hours=2))
        a = self.create()
        self.assertEqual(S.run_all(now=DAY1)["sent"], 0)
        r = self.oc.get("/api/v1/retention/automations/%d/results" % a["id"])
        self.assertEqual(r.data["not_sent_reasons"], {"not_on_assisto": 1})

    def test_stop_said_in_whatsapp_chat_stops_automations(self):
        t = ChatThread.objects.create(user=self.owner, business=self.biz, channel="whatsapp_cloud",
                                      customer_phone="8801710000002", external_user_id="8801710000002")
        S.on_inbound(t, "STOP")
        self.assertTrue(MG.is_opted_out(self.biz.id, "01710000002"))
        self.sale(self.cust, DAY1 - timedelta(days=2, hours=2))
        self.create()
        self.assertEqual(S.run_all(now=DAY1)["sent"], 0)

    def test_owner_records_stop_and_other_shop_unaffected(self):
        r = self.oc.post("/api/v1/retention/opt-outs", {"phone": "+880 1710-000002"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(MG.is_opted_out(self.biz.id, "01710000002"))
        other = User.objects.create_user(name="O2", phone="01710000009", password="pw-123456")
        b2 = BusinessProfile.objects.create(user=other)
        self.assertFalse(MG.is_opted_out(b2.id, "01710000002"))


class MetaChannelTests(_Base):
    def setUp(self):
        super().setUp()
        self.ch = SellerChannel.objects.create(business=self.biz, kind="whatsapp_cloud",
                                               external_id="pn-1", status="connected",
                                               test_mode=True)
        self.thread = ChatThread.objects.create(
            user=self.owner, business=self.biz, channel="whatsapp_cloud", seller_channel=self.ch,
            customer_phone="8801710000002", external_user_id="8801710000002", lang="bn")
        self.sale(self.cust, DAY1 - timedelta(days=50))

    def winback(self, **kw):
        d = {"kind": "winback", "channel": "whatsapp", "template_bn": "{name}, ফিরে আসুন",
             "template_en": "", "params": {"days_without": 45}}
        d.update(kw)
        return self.create(**d)

    def test_outside_24h_needs_template(self):
        ChatThread.objects.filter(pk=self.thread.pk).update(last_inbound_at=DAY1 - timedelta(days=2))
        self.winback()
        S.run_all(now=DAY1)
        s = RetentionSend.objects.get()
        self.assertEqual((s.status, s.reason), ("blocked", "outside_24h_window_template_required"))

    def test_inside_24h_free_form_with_stop(self):
        ChatThread.objects.filter(pk=self.thread.pk).update(last_inbound_at=DAY1 - timedelta(hours=3))
        self.winback()
        S.run_all(now=DAY1)
        s = RetentionSend.objects.get()
        self.assertEqual(s.status, "sent")
        self.assertIn("STOP", s.chat_message.text)
        # the customer's reply on WhatsApp counts as replied
        S.on_inbound(self.thread, "আসছি কাল", now=DAY1 + timedelta(hours=1))
        s.refresh_from_db()
        self.assertTrue(s.replied_at)

    def test_promo_in_utility_template_refused(self):
        r = self.oc.post("/api/v1/retention/automations", {
            "kind": "winback", "channel": "whatsapp", "template_bn": "x",
            "wa_template": {"name": "due_note", "category": "utility", "approved": True,
                            "has_stop": True}}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["error"], "promo_in_utility_template")

    def test_approved_marketing_template_and_credit_precheck(self):
        ChatThread.objects.filter(pk=self.thread.pk).update(last_inbound_at=DAY1 - timedelta(days=2))
        tpl = {"name": "miss_you", "lang": "bn", "category": "marketing", "approved": True,
               "has_stop": True}
        self.winback(wa_template=tpl)
        from core import billing
        row = billing.get_config()
        data = dict(row.data)
        sa = dict(data.get("seller_agent") or {})
        sa["wa_cost_bdt"] = {"marketing": 1.2, "utility": 0.4, "service": 0.0, "authentication": 0.4}
        data["seller_agent"] = sa
        row.data = data
        row.save()
        S.run_all(now=DAY1)                                  # 0 credits -> refused up front
        s = RetentionSend.objects.get()
        self.assertEqual((s.status, s.reason), ("blocked", "insufficient_credits"))
        RetentionSend.objects.all().delete()
        User.objects.filter(pk=self.owner.pk).update(ai_credits=50)
        S.run_all(now=DAY1)
        s = RetentionSend.objects.get()
        self.assertEqual(s.status, "sent")
        self.assertEqual(s.chat_message.kind, "template")

    def test_messenger_outside_24h_refused(self):
        mch = SellerChannel.objects.create(business=self.biz, kind="messenger", external_id="pg-1",
                                           status="connected", test_mode=True)
        ChatThread.objects.create(user=self.owner, business=self.biz, channel="messenger",
                                  seller_channel=mch, customer_phone="01710000002",
                                  external_user_id="psid-1",
                                  last_inbound_at=DAY1 - timedelta(days=3))
        self.winback(channel="messenger")
        S.run_all(now=DAY1)
        s = RetentionSend.objects.get()
        self.assertEqual((s.status, s.reason), ("blocked", "outside_24h_window"))


class _FakeSms:
    def __init__(self, ok=True):
        self.ok, self.sent = ok, []

    def send(self, to, text, secret=""):
        self.sent.append((to, text))
        return (self.ok, "HTTP 200" if self.ok else "HTTP 500: down")


class SmsCreditTests(_Base):
    def setUp(self):
        super().setUp()
        self.sale(self.cust, DAY1 - timedelta(days=2, hours=2))

    def test_refused_at_zero_then_charged_then_refunded_on_failure(self):
        fake = _FakeSms()
        with mock.patch("core.sms_gateway.adapter", return_value=fake):
            a = self.create(channel="sms", template_bn="{name}, ধন্যবাদ!", template_en="")
            S.run_all(now=DAY1)
            s = RetentionSend.objects.get()
            self.assertEqual((s.status, s.reason), ("blocked", "insufficient_credits"))
            self.assertEqual(fake.sent, [])
            RetentionSend.objects.all().delete()
            User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
            S.run_all(now=DAY1)
            s = RetentionSend.objects.get()
            self.assertEqual(s.status, "sent")
            self.assertEqual(fake.sent[0][0], "+8801710000002")
            self.assertIn("/api/v1/retention/u/%d-" % s.pk, fake.sent[0][1])   # stop link
            self.owner.refresh_from_db()
            self.assertEqual(self.owner.ai_credits, 10 - s.credits)
            self.assertGreaterEqual(s.credits, 1)
            # gateway down -> refunded
            RetentionSend.objects.all().delete()
            fake.ok = False
            before = self.owner.ai_credits
            S.run_all(now=DAY1)
            s = RetentionSend.objects.get()
            self.assertEqual(s.status, "failed")
            self.owner.refresh_from_db()
            self.assertEqual(self.owner.ai_credits, before)
            self.assertTrue(a)

    def test_sms_channel_needs_gateway(self):
        r = self.oc.post("/api/v1/retention/automations",
                         {"kind": "thanks_review", "channel": "sms", "template_bn": "x"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["error"], "channel_not_connected")

    def test_public_stop_link(self):
        fake = _FakeSms()
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        with mock.patch("core.sms_gateway.adapter", return_value=fake):
            self.create(channel="sms", template_bn="{name}, ধন্যবাদ!", template_en="")
            S.run_all(now=DAY1)
        s = RetentionSend.objects.get()
        url = "/api/v1/retention/u/%d-%s" % (s.pk, S._stop_sig(s.pk))
        anon = APIClient()
        r = anon.get(url)
        self.assertEqual(r.status_code, 200)
        self.assertIn(b"<form", r.content)
        self.assertFalse(MG.is_opted_out(self.biz.id, "01710000002"))   # GET never stops
        r = anon.post(url)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(MG.is_opted_out(self.biz.id, "01710000002"))
        self.assertEqual(anon.get("/api/v1/retention/u/%d-bad" % s.pk).status_code, 404)


class GateTests(_Base):
    def test_flag_off_403_but_stop_still_works(self):
        from core import feature_flags as FF
        from core.models import FeatureFlag
        self.sale(self.cust, DAY1 - timedelta(days=2, hours=2))
        self.create()
        S.run_all(now=DAY1)
        sid = RetentionSend.objects.get().pk
        FeatureFlag.objects.filter(key=FF_KEY).update(enabled_all=False, enabled_play=False)
        FF.invalidate()
        for path in ("/api/v1/retention", "/api/v1/retention/automations", "/api/v1/retention/inbox"):
            r = self.oc.get(path)
            self.assertEqual(r.status_code, 403, path)
            self.assertEqual(r.data["error"], "feature_off")
        self.assertEqual(self.cc.post("/api/v1/retention/inbox/%d/stop" % sid).status_code, 200)
        # hidden -> the scheduler sends nothing for this shop
        RetentionSend.objects.all().delete()
        self.assertEqual(S.run_all(now=DAY1)["sent"], 0)
        # the owner (superuser) previews a hidden feature
        boss = User.objects.create_superuser(name="Boss", phone="01710000077", password="pw-123456")
        bc = APIClient()
        bc.force_authenticate(boss)
        self.assertEqual(bc.get("/api/v1/retention").status_code, 200)

    def test_default_off(self):
        from core import feature_flags as FF
        self.assertFalse(FF.default_row(FF_KEY)["enabled_all"])

    def test_plan_gate_and_staff(self):
        free = User.objects.create_user(name="F", phone="01710000055", password="pw-123456")
        fc = APIClient()
        fc.force_authenticate(free)
        r = fc.get("/api/v1/retention")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["plan_ok"])
        r = fc.post("/api/v1/retention/automations", {"kind": "winback", "template_bn": "x"},
                    format="json")
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.data["error"], "upgrade_required")
        from core.models import BusinessStaff
        staff = User.objects.create_user(name="S", phone="01710000066", password="pw-123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="cashier", active=True)
        sc = APIClient()
        sc.force_authenticate(staff)
        r = sc.get("/api/v1/retention?business=%d" % self.biz.id)
        self.assertEqual(r.status_code, 403)

    def test_max_automations_and_crud(self):
        a = self.create(enabled=False)
        r = self.oc.patch("/api/v1/retention/automations/%d" % a["id"], {"enabled": True,
                          "send_hour": 22}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.oc.patch("/api/v1/retention/automations/%d" % a["id"], {"enabled": True},
                          format="json")
        self.assertTrue(r.data["enabled"])
        for _ in range(9):
            self.create(enabled=False)
        r = self.oc.post("/api/v1/retention/automations", {"kind": "winback", "template_bn": "x"},
                         format="json")
        self.assertEqual(r.data["error"], "too_many")
        self.assertEqual(self.oc.delete("/api/v1/retention/automations/%d" % a["id"]).status_code, 204)

    def test_birthday_and_stock_ask(self):
        from core.models import Product
        r = self.oc.post("/api/v1/retention/customers/%d/birthday" % self.cust.id,
                         {"birthday": "1990-10-27"}, format="json")
        self.assertEqual(r.status_code, 200)
        r = self.oc.post("/api/v1/retention/customers/%d/birthday" % self.cust.id,
                         {"birthday": "2099-01-01"}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.oc.get("/api/v1/retention/customers?q=kar")
        self.assertEqual(r.data["customers"][0]["birthday"], "1990-10-27")
        p = Product.objects.create(user=self.owner, business=self.biz, name="Blue saree", stock=0)
        r = self.oc.post("/api/v1/retention/stock-asks", {"product_id": p.id, "customer_id": self.cust.id},
                         format="json")
        self.assertEqual(r.status_code, 201)
        self.create(kind="back_in_stock", template_bn="{product} এসেছে", template_en="", params={})
        self.assertEqual(S.run_all(now=DAY1)["sent"], 0)          # still out of stock
        Product.objects.filter(pk=p.pk).update(stock=4)
        self.assertEqual(S.run_all(now=DAY1)["sent"], 1)
        self.assertIn("Blue saree", RetentionSend.objects.get().text)
        r = self.oc.get("/api/v1/retention/stock-asks")
        self.assertTrue(r.data["asks"][0]["notified"])
        # another shop's customer cannot be used
        other = User.objects.create_user(name="O2", phone="01710000009", password="pw-123456")
        b2 = BusinessProfile.objects.create(user=other)
        c2 = Customer.objects.create(user=other, business=b2, name="X", phone_key="01710000010")
        r = self.oc.post("/api/v1/retention/customers/%d/birthday" % c2.id,
                         {"birthday": "1990-01-01"}, format="json")
        self.assertEqual(r.status_code, 404)
