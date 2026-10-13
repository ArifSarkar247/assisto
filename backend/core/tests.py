"""
Core tests — the agent brain (rule-based parser) and the /agent endpoint.

These run with NO AI key: they prove Assisto understands Bangla + English
commands and only ever creates the user's OWN data. Kept deterministic
(no network, no AI).
"""
from decimal import Decimal

from django.test import TestCase
from rest_framework.test import APITestCase

from . import agent
from .models import (User, Transaction, Loan, Medicine, Reminder,
                     MemoryItem, Account)


class AgentParseTests(TestCase):
    """Pure parser tests — no DB, no auth."""

    def test_expense_bangla_digits(self):
        p = agent.parse("৫০০ টাকা খরচ খাবার")
        self.assertEqual(p["intent"], "expense")
        self.assertEqual(p["amount"], "500")
        self.assertIn("খাবার", p["category"])

    def test_income(self):
        p = agent.parse("বেতন পেলাম ২০০০০")
        self.assertEqual(p["intent"], "income")
        self.assertEqual(p["amount"], "20000")

    def test_loan_given(self):
        p = agent.parse("রহিম ভাইকে ৫০০ টাকা ধার দিলাম")
        self.assertEqual(p["intent"], "loan")
        self.assertEqual(p["kind"], "given")
        self.assertEqual(p["amount"], "500")

    def test_loan_taken(self):
        p = agent.parse("করিম থেকে ১০০০ টাকা ধার নিলাম")
        self.assertEqual(p["intent"], "loan")
        self.assertEqual(p["kind"], "taken")
        self.assertEqual(p["amount"], "1000")

    def test_medicine_with_time(self):
        p = agent.parse("ওষুধ নাপা সকাল ৮টা")
        self.assertEqual(p["intent"], "medicine")
        self.assertTrue(p["due"].endswith("08:00:00") or "08:00" in p["due"])

    def test_reminder_tomorrow_evening(self):
        p = agent.parse("কাল বিকেল ৫টায় মিটিং মনে করিয়ে দিও")
        self.assertEqual(p["intent"], "reminder")
        self.assertIn("17:00", p["due"])

    def test_query_money(self):
        self.assertEqual(agent.parse("আমার কত টাকা আছে?")["intent"], "query_money")

    def test_query_today(self):
        self.assertEqual(agent.parse("আজ কী কী আছে?")["intent"], "query_today")

    def test_english_expense(self):
        p = agent.parse("spent 300 on transport")
        self.assertEqual(p["intent"], "expense")
        self.assertEqual(p["amount"], "300")

    def test_bare_amount_is_expense(self):
        self.assertEqual(agent.parse("২৫০ বাজার")["intent"], "expense")

    def test_free_text_is_memory(self):
        self.assertEqual(agent.parse("আমার পাসপোর্ট ড্রয়ারে আছে")["intent"], "memory")

    def test_empty(self):
        self.assertEqual(agent.parse("")["intent"], "unknown")


class AgentViewTests(APITestCase):
    """End-to-end: POST /api/v1/agent creates only the user's own data."""

    def setUp(self):
        self.user = User.objects.create_user(
            name="পরীক্ষা", phone="01700000000", password="secret123")
        self.client.force_authenticate(user=self.user)
        self.url = "/api/v1/agent"

    def _post(self, text):
        return self.client.post(self.url, {"text": text}, format="json")

    def test_expense_creates_txn_and_account(self):
        r = self._post("৫০০ টাকা খরচ খাবার")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["intent"], "expense")
        self.assertFalse(r.data["ai_used"])
        t = Transaction.objects.get(user=self.user)
        self.assertEqual(t.kind, "expense")
        self.assertEqual(t.amount, Decimal("500"))
        self.assertEqual(t.source, "ai")
        self.assertTrue(Account.objects.filter(user=self.user).exists())
        card = r.data["cards"][0]
        self.assertEqual(card["model"], "txn")
        self.assertTrue(card["undo"])

    def test_loan_creates_loan(self):
        r = self._post("রহিম ভাইকে ৫০০ টাকা ধার দিলাম")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Loan.objects.filter(user=self.user, kind="given").count(), 1)

    def test_medicine_creates_medicine(self):
        r = self._post("ওষুধ নাপা সকাল ৮টা")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Medicine.objects.filter(user=self.user).count(), 1)

    def test_reminder_creates_reminder(self):
        r = self._post("কাল বিকেল ৫টায় মিটিং মনে করিয়ে দিও")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Reminder.objects.filter(user=self.user).count(), 1)

    def test_memory_needs_review_and_marked_ai(self):
        r = self._post("আমার পাসপোর্ট ড্রয়ারে আছে")
        self.assertEqual(r.status_code, 200)
        m = MemoryItem.objects.get(user=self.user)
        self.assertTrue(m.needs_review)
        self.assertEqual(m.source, "ai")

    def test_query_money_reply(self):
        self._post("৫০০ টাকা খরচ খাবার")
        r = self._post("আমার কত টাকা আছে?")
        self.assertEqual(r.status_code, 200)
        self.assertIn("ব্যালেন্স", r.data["reply"])

    def test_empty_text(self):
        r = self._post("")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["cards"], [])

    def test_requires_auth(self):
        self.client.force_authenticate(user=None)
        r = self._post("৫০০ টাকা খরচ")
        self.assertIn(r.status_code, (401, 403))

    def test_data_isolation(self):
        """Another user never sees this user's data."""
        self._post("৫০০ টাকা খরচ খাবার")
        other = User.objects.create_user(
            name="অন্য", phone="01800000000", password="secret123")
        self.client.force_authenticate(user=other)
        self.assertEqual(Transaction.objects.filter(user=other).count(), 0)


class IntegrationsStoreTests(TestCase):
    """Keystone: encrypted store, masking, feature-flag, honest test states."""

    def test_encrypt_roundtrip_and_at_rest(self):
        from core import integrations as I
        from core.models import Integration
        I.save('admob', {'app_id': 'ca-pub-xyz', 'banner_unit': 'b', 'rewarded_unit': 'r'})
        self.assertEqual(I.get('admob')['app_id'], 'ca-pub-xyz')
        blob = Integration.objects.get(slug='admob').enc_blob
        self.assertNotIn('ca-pub-xyz', blob)  # encrypted at rest

    def test_feature_flag_after_test(self):
        from core import integrations as I
        self.assertFalse(I.is_enabled('admob'))
        I.save('admob', {'app_id': 'x'})
        st, _ = I.test('admob')  # no-test integration -> working (saved)
        self.assertEqual(st, 'working')
        self.assertTrue(I.is_enabled('admob'))

    def test_list_masks_secrets(self):
        from core import integrations as I
        I.save('anthropic', {'api_key': 'sk-ant-secret-abcd1234'})
        row = next(r for r in I.list_all('en') if r['slug'] == 'anthropic')
        masked = [f['masked'] for f in row['fields'] if f['key'] == 'api_key'][0]
        self.assertNotIn('secret', masked)
        self.assertTrue(masked.endswith('1234'))

    def test_registry_nonempty_and_unknown_rejected(self):
        from core import integrations as I
        self.assertGreaterEqual(len(I.list_all()), 15)
        with self.assertRaises(ValueError):
            I.save('does-not-exist', {'x': 'y'})


class AILayerP2Tests(TestCase):
    """Multi-provider selection + graceful degrade + bill-template cache."""

    def test_no_provider_raises_no_key(self):
        from core import ai
        self.assertEqual(ai._providers(), [])          # no keys configured in tests
        self.assertFalse(ai.available())
        with self.assertRaises(ai.AIUnavailable) as c:
            ai.generate(task="hi", user=None)
        self.assertEqual(c.exception.reason, "no_key")

    def test_bill_cache_second_scan_no_ai(self):
        from core import bills
        from core.models import BillTemplate
        u = User.objects.create_user(name="B", phone="01911111111", password="x123456")
        BillTemplate.objects.create(user=u, biller="DPDC",
                                    fields={"account_no": "123", "amount": "850", "where_to_pay": "bKash"})
        res, used_ai, from_cache = bills.parse_bill(u, "raw bill text", biller_hint="DPDC")
        self.assertFalse(used_ai)
        self.assertTrue(from_cache)
        self.assertEqual(res["account_no"], "123")

    def test_bill_first_scan_without_key_is_honest(self):
        from core import bills
        u = User.objects.create_user(name="C", phone="01922222222", password="x123456")
        res, used_ai, from_cache = bills.parse_bill(u, "some bill", biller_hint="WASA")
        self.assertTrue(res.get("needs_key"))          # no fake data without a key
        self.assertFalse(used_ai)


class MonetizationP3Tests(TestCase):
    def test_trial_gives_premium_entitlement(self):
        from core import plans
        u = User.objects.create_user(name="T", phone="01933333333", password="x123456")
        plans.start_trial(u)
        e = plans.entitlements(u)
        self.assertEqual(e["plan"], "premium")
        self.assertTrue(e["trial_active"])
        self.assertFalse(e["ads"])

    def test_free_plan_credit_consume_and_quota(self):
        from core import plans
        from django.utils import timezone
        from datetime import timedelta
        u = User.objects.create_user(name="F", phone="01944444444", password="x123456")
        u.trial_until = timezone.now() - timedelta(days=1)  # expired trial -> free
        u.save()
        self.assertEqual(plans.effective_plan(u), "free")
        plans.grant_monthly_if_due(u)
        self.assertEqual(u.ai_credits, plans.PLANS["free"]["credits"])
        self.assertTrue(plans.has_ai_quota(u))
        before = u.ai_credits
        plans.consume_credit(u)
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, before - 1)

    def test_rewarded_ad_daily_cap(self):
        from core import plans
        u = User.objects.create_user(name="R", phone="01955555555", password="x123456")
        for _ in range(plans.REWARDED_DAILY_CAP):
            ok, _ = plans.reward_ad(u)
            self.assertTrue(ok)
        ok, _ = plans.reward_ad(u)   # over cap
        self.assertFalse(ok)


class WatcherP4Tests(TestCase):
    def test_change_detection_ai_only_on_change(self):
        from core import watcher
        from core.models import Watcher, WatchHit
        u = User.objects.create_user(name="W", phone="01966666666", password="x123456")
        w = Watcher.objects.create(user=u, kind="usd_bdt", label="USD রেট", config={})
        seq = iter(["122.50", "122.50", "123.10"])
        watcher.extract_value = lambda _w: next(seq)   # patch: no network
        self.assertIsNone(watcher.check(w))            # first = baseline, no hit
        self.assertIsNone(watcher.check(w))            # unchanged, no hit
        hit = watcher.check(w)                         # changed -> hit
        self.assertIsNotNone(hit)
        self.assertEqual(WatchHit.objects.filter(watcher=w).count(), 1)
        self.assertIn("123.10", hit.new_value)

    def test_plan_watcher_limit(self):
        from core import watcher, plans
        u = User.objects.create_user(name="L", phone="01977777777", password="x123456")
        self.assertEqual(watcher.max_watchers(u), 2)


class VoiceP5Tests(TestCase):
    def test_voice_intents(self):
        from core import agent
        self.assertEqual(agent.parse("গান চালাও arijit singh")["intent"], "music")
        self.assertEqual(agent.parse("রহিম কে কল করো")["intent"], "call")
        self.assertEqual(agent.parse("গুলশান এ রাস্তা দেখাও")["intent"], "navigate")
        n = agent.parse("কাছে ফার্মেসি কোথায়")
        self.assertEqual(n["intent"], "nearby")
        self.assertEqual(n["place_type"], "pharmacy")

    def test_nearby_osm_fallback_structure(self):
        from core import nearby
        nearby._osm = lambda lat, lon, t, radius=2500: [
            {"name": "Test Pharmacy", "distance_m": 120, "rating": None, "open_now": None,
             "lat": lat, "lon": lon, "maps": "x", "address": ""}]
        res, src = nearby.search(23.8, 90.4, "pharmacy")
        self.assertEqual(src, "osm")
        self.assertIsNone(res[0]["rating"])   # never invented


class FinanceP6Tests(TestCase):
    def test_zakat_2_5_percent(self):
        from core import finance
        r = finance.zakat(cash=100000, gold_value=0, debts=0, nisab=0)
        self.assertEqual(r["zakat_due"], "2500.00")

    def test_zakat_below_nisab(self):
        from core import finance
        r = finance.zakat(cash=1000, nisab=100000)
        self.assertFalse(r["above_nisab"])
        self.assertEqual(r["zakat_due"], "0")

    def test_emi_formula(self):
        from core import finance
        r = finance.emi(principal=100000, annual_rate_pct=12, months=12)
        # ~8884.88/month for 100k @12% over 12m
        self.assertTrue(8800 < float(r["emi"]) < 8950)
        self.assertEqual(r["months"], 12)

    def test_invest_projection_is_estimate(self):
        from core import finance
        r = finance.invest_projection(principal=10000, annual_rate_pct=10, years=1)
        self.assertTrue(r["estimate"])
        self.assertGreater(float(r["future_value"]), 10000)


class InboxP6Tests(TestCase):
    def test_triage_rules(self):
        from core.views import classify_inbox_item
        self.assertEqual(classify_inbox_item("URGENT: payment failed", ""), "red")
        self.assertEqual(classify_inbox_item("Meeting reminder", "please reply"), "yellow")
        self.assertEqual(classify_inbox_item("Newsletter", "monthly update"), "green")


class BusinessP7Tests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Shop", phone="01988888888", password="x123456")

    def test_reply_uses_real_catalog_no_ai(self):
        from core import business
        from core.models import Product
        Product.objects.create(user=self.u, name="Panjabi", price=1200, stock=5)
        reply, handoff, used_ai = business.reply_for(self.u, "panjabi er dam koto?")
        self.assertFalse(used_ai)          # no AI key in tests
        self.assertFalse(handoff)
        self.assertIn("1200", reply)       # real price, not invented

    def test_out_of_stock_is_honest(self):
        from core import business
        from core.models import Product
        Product.objects.create(user=self.u, name="Saree", price=2000, stock=0)
        reply, handoff, _ = business.reply_for(self.u, "saree ache?")
        self.assertIn("স্টক", reply)

    def test_no_match_hands_off(self):
        from core import business
        reply, handoff, _ = business.reply_for(self.u, "random unrelated question")
        self.assertTrue(handoff)

    def test_order_capture_creates_order(self):
        from core import business
        from core.models import Product, Order
        Product.objects.create(user=self.u, name="Shirt", price=800, stock=3)
        order, draft = business.capture_order(self.u, "ami shirt nebo")
        self.assertIsNotNone(order)
        self.assertEqual(Order.objects.filter(user=self.u).count(), 1)
