"""
Core tests — the agent brain (rule-based parser) and the /agent endpoint.

These run with NO AI key: they prove Assisto understands Bangla + English
commands and only ever creates the user's OWN data. Kept deterministic
(no network, no AI).
"""
from decimal import Decimal

from django.test import TestCase
from django.utils import timezone
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


class JobP9Tests(TestCase):
    def test_job_match_from_own_skills(self):
        from core import jobs
        from core.models import MemoryItem
        u = User.objects.create_user(name="J", phone="01911112222", password="x123456")
        MemoryItem.objects.create(user=u, title="Python Django backend developer", source="manual")
        skills = jobs.user_skills(u)
        score, reason = jobs.match("Looking for a Python Django backend developer", skills)
        self.assertGreater(score, 40)
        self.assertIn("python", reason.lower())

    def test_tailor_needs_key_without_ai(self):
        from core import jobs
        u = User.objects.create_user(name="K", phone="01911113333", password="x123456")
        res = jobs.tailor_documents(u, "some job")
        self.assertTrue(res.get("needs_key"))   # no fake CV without a key


class LocalizationTests(APITestCase):
    """Backend user-facing strings must follow the selected language (bn/en)."""

    def test_all_plans_bilingual(self):
        from core import plans
        for pid, spec in plans.PLANS.items():
            for f in ("name_bn", "name_en", "desc_bn", "desc_en",
                      "benefits_bn", "benefits_en"):
                self.assertIn(f, spec, f"{pid} missing {f}")
            self.assertTrue(spec["name_en"] and spec["desc_en"])
            self.assertTrue(len(spec["benefits_en"]) == len(spec["benefits_bn"]))

    def test_i18n_pick_and_reqlang(self):
        from core.i18n import pick
        self.assertEqual(pick("en", "বাংলা", "English"), "English")
        self.assertEqual(pick("bn", "বাংলা", "English"), "বাংলা")

    def test_plan_endpoint_follows_accept_language(self):
        u = User.objects.create_user(name="LocTest", phone="01955500000", password="x123456")
        self.client.force_authenticate(user=u)
        en = self.client.get("/api/v1/me/plan", HTTP_ACCEPT_LANGUAGE="en")
        bn = self.client.get("/api/v1/me/plan", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(en.json()["name"], "Free")
        self.assertEqual(bn.json()["name"], "ফ্রি")

    def test_guides_localized_both_languages(self):
        from core.logic import guides
        en = guides.localized("en")
        self.assertTrue(en["services"])
        for s in en["services"]:
            self.assertIn("name", s)
            self.assertNotRegex(str(s.get("steps", "")), r"[ঀ-৿]")


# ---------------------------------------------------------------------------
# Medicine & family-care module (Phase B) — pure logic + API + a 30-day scenario
# ---------------------------------------------------------------------------
from datetime import date, datetime, time, timedelta  # noqa: E402

from core.logic import medicine as mlogic  # noqa: E402
from core.models import FamilyMember, Medicine, MedicineLog, Doctor, Prescription  # noqa: E402


class MedicineLogicTests(TestCase):
    """Pure functions — no DB, no AI."""

    def test_doses_per_day(self):
        self.assertEqual(mlogic.doses_per_day(["08:00", "20:00"]), 2)
        self.assertEqual(mlogic.doses_per_day([]), 0)
        self.assertEqual(mlogic.doses_per_day(["08:00", "", "  "]), 1)

    def test_active_on_course_window(self):
        s, e = date(2026, 1, 1), date(2026, 1, 7)
        self.assertTrue(mlogic.active_on(s, e, date(2026, 1, 1)))
        self.assertTrue(mlogic.active_on(s, e, date(2026, 1, 7)))
        self.assertFalse(mlogic.active_on(s, e, date(2026, 1, 8)))
        self.assertFalse(mlogic.active_on(s, e, date(2025, 12, 31)))

    def test_prn_never_scheduled(self):
        self.assertEqual(
            mlogic.scheduled_slots_for_day(["08:00"], None, None,
                                           date(2026, 1, 1), prn=True), [])

    def test_days_left_and_refill(self):
        # 20 pills, 2/day → 10 days
        self.assertEqual(mlogic.days_left(20, ["08:00", "20:00"]), 10)
        d = mlogic.predicted_refill_date(20, ["08:00", "20:00"],
                                         today=date(2026, 1, 1))
        self.assertEqual(d, date(2026, 1, 11))
        # open-ended (no schedule) → None
        self.assertIsNone(mlogic.days_left(20, []))

    def test_refill_warning_levels(self):
        self.assertEqual(mlogic.refill_warning(20, ["08:00", "20:00"])[0], "ok")
        self.assertEqual(mlogic.refill_warning(6, ["08:00", "20:00"])[0], "soon")  # 3 days
        self.assertEqual(mlogic.refill_warning(0, ["08:00"])[0], "out")

    def test_dose_qty_burn(self):
        # 2 pills per dose, 2 doses/day = 4/day → 20 pills = 5 days
        self.assertEqual(mlogic.days_left(20, ["08:00", "20:00"], dose_qty=2), 5)
        self.assertEqual(mlogic.apply_dose_to_stock(10, dose_qty=2), 8)

    def test_fractional_dose_stock(self):
        # P6: dose_qty=0.5 must decrement half a pill, not 0 (old int-round bug).
        self.assertEqual(mlogic.apply_dose_to_stock(10, dose_qty=0.5), 9.5)
        self.assertEqual(mlogic.apply_dose_to_stock(0.5, dose_qty=0.5), 0.0)
        # never below zero
        self.assertEqual(mlogic.apply_dose_to_stock(0, dose_qty=0.5), 0.0)
        # restore is the inverse
        self.assertEqual(mlogic.restore_dose_to_stock(9.5, dose_qty=0.5), 10.0)
        # half a pill once a day → 10 pills last 20 days
        self.assertEqual(mlogic.days_left(10, ["08:00"], dose_qty=0.5), 20)

    def test_predicted_refill_and_prn_burn(self):
        # P1: run-out date from stock + burn
        d = mlogic.predicted_refill_date(20, ["08:00", "20:00"],
                                         today=date(2026, 1, 1))
        self.assertEqual(d, date(2026, 1, 11))
        # PRN with a per-day estimate burns stock too (but never schedules)
        self.assertEqual(
            mlogic.days_left(10, [], prn=True, prn_per_day=2), 5)
        self.assertEqual(
            mlogic.predicted_refill_date(10, [], today=date(2026, 1, 1),
                                         prn=True, prn_per_day=2),
            date(2026, 1, 6))
        # PRN with no per-day estimate → no prediction
        self.assertIsNone(mlogic.days_left(10, [], prn=True, prn_per_day=0))

    def test_streak_prn_is_zero(self):
        # PRN meds have no scheduled doses → streak is not meaningful.
        self.assertEqual(
            mlogic.streak_days([], None, None, set(),
                               today=date(2026, 1, 10), prn=True), 0)

    def test_adherence_ratio(self):
        self.assertEqual(mlogic.adherence(10, 8)[0], 80)
        self.assertEqual(mlogic.adherence(0, 0)[0], 100)  # nothing scheduled

    def test_quiet_hours_overnight_wrap(self):
        self.assertTrue(mlogic.in_quiet_hours(time(23, 0), "22:00", "07:00"))
        self.assertTrue(mlogic.in_quiet_hours(time(2, 0), "22:00", "07:00"))
        self.assertFalse(mlogic.in_quiet_hours(time(12, 0), "22:00", "07:00"))
        self.assertFalse(mlogic.in_quiet_hours(time(12, 0), "", ""))

    def test_escalation_plan_ladder_and_quiet(self):
        plan = mlogic.escalation_plan(
            "23:00", followup_repeat_min=15, followup_retries=2,
            caregiver_alert_min=30, quiet_start="22:00", quiet_end="07:00",
            base_day=date(2026, 1, 1))
        kinds = [e["kind"] for e in plan]
        self.assertEqual(kinds, ["reminder", "reremind", "reremind", "caregiver_alert"])
        # all land in quiet hours (after 22:00) → suppressed
        self.assertTrue(all(e["suppressed"] for e in plan))
        # a daytime dose is NOT suppressed
        day = mlogic.escalation_plan("10:00", 15, 1, 30,
                                     "22:00", "07:00", base_day=date(2026, 1, 1))
        self.assertFalse(any(e["suppressed"] for e in day))

    def test_next_escalation_action(self):
        plan = mlogic.escalation_plan("10:00", 15, 2, 30, base_day=date(2026, 1, 1))
        now = datetime(2026, 1, 1, 10, 40)  # past the 30-min caregiver mark
        act = mlogic.next_escalation_action(plan, now, acknowledged=False)
        self.assertEqual(act["kind"], "caregiver_alert")
        # acknowledged → nothing fires
        self.assertIsNone(mlogic.next_escalation_action(plan, now, acknowledged=True))


class MedicineApiTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            name="Care", phone="01966600000", password="x123456")
        self.client.force_authenticate(user=self.user)

    def test_create_medicine_with_dose_semantics(self):
        r = self.client.post("/api/v1/medicines/", {
            "name": "Napa", "dosage": "1 tab", "times": ["08:00", "20:00"],
            "food_relation": "after", "dose_qty": "1", "stock_count": 20,
            "duration_days": 7}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        body = r.json()
        self.assertEqual(body["days_left"], 10)
        self.assertEqual(body["refill_status"], "ok")
        self.assertEqual(body["food_relation"], "after")

    def test_taken_decrements_inventory_and_undo_restores(self):
        med = Medicine.objects.create(user=self.user, name="X",
                                      times=["08:00"], stock_count=10, dose_qty=1)
        r = self.client.post(f"/api/v1/medicines/{med.id}/taken",
                             {"slot": "08:00", "taken": True}, format="json")
        self.assertEqual(r.json()["stock_count"], 9)
        # idempotent — taking same slot again does not double-decrement
        self.client.post(f"/api/v1/medicines/{med.id}/taken",
                        {"slot": "08:00", "taken": True}, format="json")
        med.refresh_from_db()
        self.assertEqual(med.stock_count, 9)
        # undo restores
        r = self.client.post(f"/api/v1/medicines/{med.id}/taken",
                            {"slot": "08:00", "taken": False}, format="json")
        self.assertEqual(r.json()["stock_count"], 10)

    def test_prn_in_today_and_not_in_adherence(self):
        Medicine.objects.create(user=self.user, name="PRN", times=[],
                                as_needed=True)
        today = self.client.get("/api/v1/medicines/today").json()
        self.assertTrue(any(d["prn"] for d in today))
        hist = self.client.get("/api/v1/medicines/history").json()
        # PRN contributes 0 scheduled → overall stays 100 with no other meds
        self.assertEqual(hist["overall"], 100)

    def test_prn_can_be_logged_multiple_times_per_day(self):
        # P4: a painkiller logged twice in one day → two distinct PRN events.
        med = Medicine.objects.create(user=self.user, name="Painkiller",
                                      times=[], as_needed=True,
                                      stock_count=Decimal("10"), dose_qty=1)
        r1 = self.client.post(f"/api/v1/medicines/{med.id}/taken",
                              {"slot": "prn", "taken": True}, format="json")
        r2 = self.client.post(f"/api/v1/medicines/{med.id}/taken",
                              {"slot": "prn", "taken": True}, format="json")
        self.assertEqual(r1.status_code, 200)
        s1, s2 = r1.json()["slot"], r2.json()["slot"]
        self.assertTrue(s1.startswith("prn-") and s2.startswith("prn-"))
        # two separate rows (not a single unique_together collision)
        self.assertEqual(
            MedicineLog.objects.filter(medicine=med, taken=True).count(), 2)
        # each logged event appears in today's list, plus a 'log another' row
        today = self.client.get("/api/v1/medicines/today").json()
        prn_rows = [d for d in today if d["medicine_id"] == med.id]
        taken_rows = [d for d in prn_rows if d["taken"]]
        open_rows = [d for d in prn_rows if d["slot"] == "prn"]
        self.assertEqual(len(taken_rows), 2)
        self.assertEqual(len(open_rows), 1)
        # adherence still excludes PRN (0 scheduled → 100 overall)
        hist = self.client.get("/api/v1/medicines/history").json()
        self.assertEqual(hist["overall"], 100)

    def test_fractional_dose_decrements_half_pill(self):
        # P6: dose_qty=0.5 → stock 10 goes to 9.5, not 10.
        med = Medicine.objects.create(user=self.user, name="HalfPill",
                                      times=["08:00"], stock_count=Decimal("10"),
                                      dose_qty=Decimal("0.5"))
        r = self.client.post(f"/api/v1/medicines/{med.id}/taken",
                             {"slot": "08:00", "taken": True}, format="json")
        self.assertEqual(Decimal(r.json()["stock_count"]), Decimal("9.5"))
        # undo restores to 10.0
        r = self.client.post(f"/api/v1/medicines/{med.id}/taken",
                             {"slot": "08:00", "taken": False}, format="json")
        self.assertEqual(Decimal(r.json()["stock_count"]), Decimal("10.0"))

    def test_predicted_refill_surfaced_in_serializer(self):
        # P1: predicted_refill present even with no manual refill_date.
        med = Medicine.objects.create(user=self.user, name="Pred",
                                      times=["08:00", "20:00"],
                                      stock_count=Decimal("20"), dose_qty=1)
        body = self.client.get(f"/api/v1/medicines/{med.id}/").json()
        self.assertIsNotNone(body["predicted_refill"])  # 20 pills, 2/day → +10d
        self.assertEqual(body["days_left"], 10)

    def test_stock_only_refill_alert_fires(self):
        # P1: no refill_date, but low stock → refill alert still surfaces.
        from core.views import _build_alerts
        Medicine.objects.create(user=self.user, name="LowStock",
                                times=["08:00", "20:00"],
                                stock_count=Decimal("4"), dose_qty=1,
                                refill_warn_days=5)   # 2 days left
        alerts = _build_alerts(self.user, "en")
        self.assertTrue(any(a["type"] == "refill" and "LowStock" in a["text"]
                            for a in alerts))

    def test_next_due_is_after_now(self):
        # P6: next_due is the next pending slot AFTER the current time.
        from django.utils import timezone
        now = timezone.localtime()
        past = (now - timedelta(hours=2)).strftime("%H:%M")
        future = (now + timedelta(hours=2)).strftime("%H:%M")
        Medicine.objects.create(user=self.user, name="TwoSlots",
                                times=[past, future])
        dash = self.client.get("/api/v1/medicines/caregiver").json()
        me = next(p for p in dash["people"] if p["relation"] == "self")
        self.assertEqual(me["next_due"], future)

    def test_escalation_endpoint(self):
        med = Medicine.objects.create(
            user=self.user, name="E", times=["23:00"],
            followup_repeat_min=15, followup_retries=2, caregiver_alert_min=30,
            quiet_start="22:00", quiet_end="07:00")
        r = self.client.get(f"/api/v1/medicines/{med.id}/escalation?slot=23:00")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["push_ready"])  # no Firebase key
        self.assertTrue(all(e["suppressed"] for e in r.json()["events"]))

    def test_caregiver_dashboard_multi_person(self):
        mom = FamilyMember.objects.create(user=self.user, name="Ma", relation="mother")
        Medicine.objects.create(user=self.user, member=mom, name="BP",
                                times=["08:00"], stock_count=3, dose_qty=1)
        Medicine.objects.create(user=self.user, name="Self med", times=["09:00"])
        r = self.client.get("/api/v1/medicines/caregiver").json()
        names = {p["relation"] for p in r["people"]}
        self.assertIn("mother", names)
        self.assertIn("self", names)
        mblock = next(p for p in r["people"] if p["relation"] == "mother")
        self.assertEqual(mblock["doses_today"], 1)
        self.assertTrue(mblock["low_stock"])  # 3 pills, 1/day → soon

    def test_doctor_pdf_renders(self):
        doc = Doctor.objects.create(user=self.user, name="Dr Rahman",
                                    specialty="Medicine")
        Prescription.objects.create(user=self.user, doctor=doc,
                                    date=date.today(), diagnosis="Fever",
                                    meds=[{"name": "Napa", "times": ["08:00"]}])
        Medicine.objects.create(user=self.user, name="Napa", times=["08:00"])
        r = self.client.get("/api/v1/medicines/doctor-pdf")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "application/pdf")
        self.assertTrue(r.content[:4] == b"%PDF")

    def test_prescription_per_doctor_filter(self):
        d1 = Doctor.objects.create(user=self.user, name="A")
        d2 = Doctor.objects.create(user=self.user, name="B")
        Prescription.objects.create(user=self.user, doctor=d1, date=date.today())
        Prescription.objects.create(user=self.user, doctor=d2, date=date.today())
        r = self.client.get(f"/api/v1/prescriptions/?doctor={d1.id}").json()
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0]["doctor_display"], "A")


class MedicineScenarioTests(APITestCase):
    """Simulate ~30 days of a parent's medicine use: some taken, some missed.
    Asserts adherence %, refill prediction, and escalation all behave."""

    def setUp(self):
        self.user = User.objects.create_user(
            name="Child", phone="01977700000", password="x123456")
        self.client.force_authenticate(user=self.user)
        self.mom = FamilyMember.objects.create(
            user=self.user, name="Amma", relation="mother")

    def test_thirty_day_adherence_refill_escalation(self):
        today = date.today()
        start = today - timedelta(days=29)
        # BP med: twice a day, 2 pills/dose, started 30 days ago, 100 pills bought.
        med = Medicine.objects.create(
            user=self.user, member=self.mom, name="Amlodipine",
            dosage="1 tab", times=["08:00", "20:00"], dose_qty=2,
            start_date=start, stock_count=100, refill_warn_days=5,
            followup_repeat_min=15, followup_retries=2, caregiver_alert_min=30,
            quiet_start="22:00", quiet_end="07:00")

        # 30 days * 2 slots = 60 scheduled doses. Miss every 5th morning dose.
        taken = 0
        for i in range(30):
            day = start + timedelta(days=i)
            for slot in ("08:00", "20:00"):
                missed = (slot == "08:00" and i % 5 == 0)
                if not missed:
                    MedicineLog.objects.create(
                        medicine=med, date=day, slot=slot, taken=True)
                    taken += 1
        # 30 days → 6 missed morning doses → 54/60 = 90%
        self.assertEqual(taken, 54)

        hist = self.client.get(
            f"/api/v1/medicines/history?member={self.mom.id}").json()
        self.assertEqual(hist["scheduled"], 60)
        self.assertEqual(hist["taken"], 54)
        self.assertEqual(hist["overall"], 90)
        self.assertEqual(len(hist["medicines"][0]["weeks"]), 4)

        # Refill prediction: 100 pills, 4/day → 25 days left from today.
        ser = self.client.get(
            f"/api/v1/medicines/?member={self.mom.id}").json()[0]
        self.assertEqual(ser["days_left"], 25)
        self.assertEqual(ser["refill_status"], "ok")
        self.assertEqual(ser["adherence_30d"], 90)

        # Drain stock to a low level, confirm 'soon' warning surfaces on dashboard.
        med.stock_count = 12  # 3 days left at 4/day
        med.save()
        dash = self.client.get("/api/v1/medicines/caregiver").json()
        mblock = next(p for p in dash["people"] if p["relation"] == "mother")
        self.assertEqual(mblock["adherence_30d"], 90)
        self.assertTrue(any(ls["status"] == "soon" for ls in mblock["low_stock"]))

        # Escalation for the evening dose (20:00) — caregiver alert is NOT in
        # quiet hours (quiet starts 22:00); reminder+reremind+alert all fire.
        esc = self.client.get(
            f"/api/v1/medicines/{med.id}/escalation?slot=20:00").json()
        self.assertEqual([e["kind"] for e in esc["events"]],
                         ["reminder", "reremind", "reremind", "caregiver_alert"])
        # 20:00 + 30 min = 20:30, before 22:00 → not suppressed
        self.assertFalse(any(e["suppressed"] for e in esc["events"]))
        self.assertFalse(esc["push_ready"])  # cross-device needs Firebase key


# ===========================================================================
# Module 5 (P13+) — fold the pure-logic *_tests_snippets into real Django
# TestCases. Each snippet module exposes test_* functions (plain asserts); we
# generate one TestCase method per function so failures surface individually.
# ===========================================================================
import importlib  # noqa: E402


def _make_snippet_case(module_path, class_name):
    mod = importlib.import_module(module_path)
    fns = {n: getattr(mod, n) for n in dir(mod)
           if n.startswith("test_") and callable(getattr(mod, n))}

    def _wrap(fn):
        def method(self):
            fn()
        return method

    attrs = {f"test_{name}": _wrap(fn) for name, fn in fns.items()}
    return type(class_name, (TestCase,), attrs)


HealthTipsSnippetTests = _make_snippet_case(
    "core.logic.health_tips_tests_snippets", "HealthTipsSnippetTests")
MedicineDbSnippetTests = _make_snippet_case(
    "core.logic.medicine_db_tests_snippets", "MedicineDbSnippetTests")
BirthdaysSnippetTests = _make_snippet_case(
    "core.logic.birthdays_tests_snippets", "BirthdaysSnippetTests")
MeetingsSnippetTests = _make_snippet_case(
    "core.logic.meetings_tests_snippets", "MeetingsSnippetTests")
DictionarySnippetTests = _make_snippet_case(
    "core.logic.dictionary_tests_snippets", "DictionarySnippetTests")
RamadanSnippetTests = _make_snippet_case(
    "core.logic.ramadan_tests_snippets", "RamadanSnippetTests")
ExamSnippetTests = _make_snippet_case(
    "core.logic.exam_tests_snippets", "ExamSnippetTests")
CircleSnippetTests = _make_snippet_case(
    "core.logic.circle_tests_snippets", "CircleSnippetTests")
ParentLinkSnippetTests = _make_snippet_case(
    "core.logic.parent_link_tests_snippets", "ParentLinkSnippetTests")
LaunchGapsSnippetTests = _make_snippet_case(
    "core.launch_gaps_tests_snippets", "LaunchGapsSnippetTests")
# build-61 wave (Messenger M1 + Safe Journey)
CircleMessagingSnippetTests = _make_snippet_case(
    "core.logic.circle_messaging_tests_snippets", "CircleMessagingSnippetTests")
CircleMediaSnippetTests = _make_snippet_case(
    "core.logic.circle_media_tests_snippets", "CircleMediaSnippetTests")
CircleCallsSnippetTests = _make_snippet_case(
    "core.logic.circle_calls_tests_snippets", "CircleCallsSnippetTests")
CirclePrivacySnippetTests = _make_snippet_case(
    "core.logic.circle_privacy_tests_snippets", "CirclePrivacySnippetTests")
# Status / Stories (#88, §21) — per-viewer visibility, 24h expiry, viewer list
# (reciprocal receipts), honest tray/expired states, conservative default.
CircleStatusSnippetTests = _make_snippet_case(
    "core.logic.circle_status_tests_snippets", "CircleStatusSnippetTests")
ReferralSnippetTests = _make_snippet_case(
    "core.logic.referral_tests_snippets", "ReferralSnippetTests")
SafetyJourneySnippetTests = _make_snippet_case(
    "core.logic.safety_journey_tests_snippets", "SafetyJourneySnippetTests")
# Watch Feed (advanced) — pure aggregation/grouping/priority helper.
WatchFeedSnippetTests = _make_snippet_case(
    "core.logic.watch_feed_tests_snippets", "WatchFeedSnippetTests")
# Voice mood sensing (#15, advanced §21) — on-device, opt-in, NON-CLINICAL mood
# check-in: deterministic fold/7-day-trend/supportive-suggestion-keys helper.
# No audio, no server, no AI, no clock (today passed in). Never diagnoses.
VoiceMoodSnippetTests = _make_snippet_case(
    "core.logic.voice_mood_tests_snippets", "VoiceMoodSnippetTests")
# Proactive AI (#6, advanced §21) — deterministic rules over the user's OWN
# signals (built on watch_feed) → urgency-grouped nudges + dismissals + "why".
# Never fabricates; AI-personalised proactivity is a documented key-gated seam.
ProactiveAiSnippetTests = _make_snippet_case(
    "core.logic.proactive_ai_tests_snippets", "ProactiveAiSnippetTests")
# AI Inbox (advanced §21) — pure triage/priority/summary/bulk helper.
AiInboxSnippetTests = _make_snippet_case(
    "core.logic.ai_inbox_tests_snippets", "AiInboxSnippetTests")
# Job Hunter (advanced §21) — pure pipeline/reminder/filter/salary helper.
JobHunterSnippetTests = _make_snippet_case(
    "core.logic.job_hunter_tests_snippets", "JobHunterSnippetTests")
# Agent Studio (advanced §21) — deterministic WHEN/IF/THEN automation engine.
AgentStudioSnippetTests = _make_snippet_case(
    "core.logic.agent_studio_tests_snippets", "AgentStudioSnippetTests")
# Social-media post & caption composer (#135, advanced §21) — deterministic
# MOCK draft generator (platform/tone/length/lang), per-platform char limits,
# hashtags/emoji, share intent. Key-free; never auto-posts.
SocialComposeSnippetTests = _make_snippet_case(
    "core.logic.social_tests_snippets", "SocialComposeSnippetTests")
RtcSnippetTests = _make_snippet_case(
    "core.logic.rtc_tests_snippets", "RtcSnippetTests")
TelegramBotSnippetTests = _make_snippet_case(
    "core.logic.telegram_bot_tests_snippets", "TelegramBotSnippetTests")
# Encrypted backup & phone transfer (#197, advanced §21) — PURE manifest /
# checksum / integrity / chunk / transfer-code bookkeeping. NO crypto or secrets
# here: encryption is on-device (app/lib/crypto/e2e.dart PBKDF2 + ChaCha20-
# Poly1305). Phone transfer is honest (encrypted file + out-of-band code);
# Google-Drive cloud backup is a documented key-gated seam (never fakes a sync).
BackupTransferSnippetTests = _make_snippet_case(
    "core.logic.backup_transfer_tests_snippets", "BackupTransferSnippetTests")
# Qurbani & Eid planner (#190, §20) — deterministic share/cost math (no drift),
# three-part meat distribution (traditional split, neutral), checklist progress.
# Pure, holds no money/animal. Mirror of app/lib/screens/qurbani_screen.dart.
QurbaniSnippetTests = _make_snippet_case(
    "core.logic.qurbani_tests_snippets", "QurbaniSnippetTests")
# Probashi corner (#191, §20) — remittance log totals/effective-rate,
# deterministic time-zone pair (time passed in, no live clock), document
# expiry from a passed-in today (reminder seam documented, not wired). Pure,
# holds no money. Mirror of app/lib/screens/probashi_screen.dart.
ProbashiSnippetTests = _make_snippet_case(
    "core.logic.probashi_tests_snippets", "ProbashiSnippetTests")
# In-chat AI helper (#97, §21) — deterministic MOCK summarise-thread /
# translate-message / adjust-tone. Key-free, honest marker on every result;
# translate honestly needs the key-gated route and never fabricates a
# translation. Never auto-sends. Mirror of app/lib/widgets/in_chat_ai_engine.dart.
InChatAiSnippetTests = _make_snippet_case(
    "core.logic.in_chat_ai_tests_snippets", "InChatAiSnippetTests")
# PA Secretary Mode · Call & email handling (#106, §14) + Letters/notices/memos
# (#107, §14), ADVANCED. Pure deterministic engines: a call/email task inbox
# (order/counts) + template reply drafter by category; a formal-document
# assembler (letter/notice/memo/application) from the owner's own words. Both
# honest MOCK (marker on every result), key-gated full-AI seams (ai_required,
# never fabricates), never auto-send. Mirrors call_email_screen.dart +
# letters_screen.dart.
PaCallEmailSnippetTests = _make_snippet_case(
    "core.logic.pa_callemail_tests_snippets", "PaCallEmailSnippetTests")
PaLettersSnippetTests = _make_snippet_case(
    "core.logic.pa_letters_tests_snippets", "PaLettersSnippetTests")
# PA Secretary Mode · CORPORATE tier (§14 #116/#117/#118), ADVANCED. Pure
# deterministic engines: a board-meeting pack assembler (agenda/documents/
# attendees/resolutions + counted quorum & roll-ups), a departmental-update
# roll-up (highlights/blockers/metrics counted; metrics reported never computed),
# and a VIP & stakeholder tracker (overdue/due-soon/on-track from a passed-in
# `now`; privacy roll-up never leaks notes/log). Honest MOCK markers; documented
# key-gated AI-draft seams (ai_required, never fabricates); conservative privacy.
# Mirror board_pack_screen.dart / dept_update_screen.dart / vip_stakeholder_screen.dart.
PaBoardSnippetTests = _make_snippet_case(
    "core.logic.pa_board_tests_snippets", "PaBoardSnippetTests")
PaDeptSnippetTests = _make_snippet_case(
    "core.logic.pa_dept_tests_snippets", "PaDeptSnippetTests")
PaVipSnippetTests = _make_snippet_case(
    "core.logic.pa_vip_tests_snippets", "PaVipSnippetTests")
# Mock interview (#131, §21) + Language-learning partner (#132, §21), both
# ADVANCED & KEY-GATED. Pure deterministic engines: a bilingual question bank +
# rule-based (NOT AI) feedback rubric + model-answer outlines; a bilingual deck
# + Leitner spaced-repetition (clock passed in) + deterministic quizzes. Each
# has a documented key-gated live-AI seam (ai_required=True, never fabricates).
# Mirror of app/lib/screens/mock_interview_screen.dart + language_partner_screen.dart.
MockInterviewSnippetTests = _make_snippet_case(
    "core.logic.mock_interview_tests_snippets", "MockInterviewSnippetTests")
LanguagePartnerSnippetTests = _make_snippet_case(
    "core.logic.language_partner_tests_snippets", "LanguagePartnerSnippetTests")
# In-app updater (#180, §21) — pure version-compare helper. Fail-closed: never
# claims an update on ambiguous/garbage input; never returns a url unless an
# update is genuinely available and the link is a usable http(s) one.
AppUpdateSnippetTests = _make_snippet_case(
    "core.logic.app_update_tests_snippets", "AppUpdateSnippetTests")
# Contract / agreement analyzer (#30, §8) + Cost / time estimator (#36, §8),
# both ADVANCED. Pure deterministic engines: rule-based risk-clause detection
# (bn+en seeds, worst-first, review-helper never legal advice) and integer-
# poisha cost/time math (no float drift). Both carry honest mock/disclaimer
# flags and a documented key-gated AI seam (Integrations `anthropic`). Mirror
# of app/lib/screens/contract_analyzer_screen.dart + cost_estimator_screen.dart.
ContractAnalyzerSnippetTests = _make_snippet_case(
    "core.logic.contract_analyzer_tests_snippets", "ContractAnalyzerSnippetTests")
CostEstimatorSnippetTests = _make_snippet_case(
    "core.logic.cost_estimator_tests_snippets", "CostEstimatorSnippetTests")
# Mess & bachelor accounting (#182, §20) + Expense splitting (#183, §20) —
# pure deterministic meal-rate / dues / split / debt-simplification math. All
# integer poisha, exact (shares sum to total; nets sum to 0); holds no money.
# Mirrors app/lib/screens/mess_accounting_screen.dart + expense_split_screen.dart.
MessAccountingSnippetTests = _make_snippet_case(
    "core.logic.mess_accounting_tests_snippets", "MessAccountingSnippetTests")
ExpenseSplitSnippetTests = _make_snippet_case(
    "core.logic.expense_split_tests_snippets", "ExpenseSplitSnippetTests")
# Blood-donor network (#188, §20) + Electricity & gas prepaid-meter tracker
# (#193, §20) — pure deterministic eligibility date-math / privacy-safe donor
# search + integer-poisha consumption projection & low-balance warning. No DB,
# no AI, no external key, no money-holding. Conservative donor-contact opt-in.
# Mirrors app/lib/screens/blood_donor_screen.dart + prepaid_meter_screen.dart.
BloodDonorSnippetTests = _make_snippet_case(
    "core.logic.blood_donor_tests_snippets", "BloodDonorSnippetTests")
PrepaidMeterSnippetTests = _make_snippet_case(
    "core.logic.prepaid_meter_tests_snippets", "PrepaidMeterSnippetTests")
# Payment / auto-pay ladder (advanced §21) — deterministic escalation engine for
# receivables (chase dues) + payables (bill/EMI reminders). Never holds money,
# never auto-charges; `pay_key` is gated on a licensed payment key.
PaymentLadderSnippetTests = _make_snippet_case(
    "core.logic.payment_ladder_tests_snippets", "PaymentLadderSnippetTests")
# Wave-D batch-5 (money/reminders): advanced Budget, Tax & Zakat, Money-by-voice
# parse, Family accounting, and the money engine (incl. Monthly Wrapped) — all
# pure, deterministic, integer-poisha / Decimal helpers with no AI, no DB.
BudgetSnippetTests = _make_snippet_case(
    "core.logic.budget_tests_snippets", "BudgetSnippetTests")
TaxZakatSnippetTests = _make_snippet_case(
    "core.logic.tax_zakat_tests_snippets", "TaxZakatSnippetTests")
MoneyVoiceSnippetTests = _make_snippet_case(
    "core.logic.moneyvoice_tests_snippets", "MoneyVoiceSnippetTests")
FamAcctSnippetTests = _make_snippet_case(
    "core.logic.famacct_tests_snippets", "FamAcctSnippetTests")
# money_tests_snippets carries the Monthly Wrapped (feature #63) scenarios
# (test_wrapped_*) alongside the broader money-engine asserts.
MoneyEngineSnippetTests = _make_snippet_case(
    "core.logic.money_tests_snippets", "MoneyEngineSnippetTests")
# Wave-D batch-6 (FAMILY advanced bundle §21 #67) — selective-sharing pure
# logic: grant/revoke/default-deny, consent-summary, audit entries, probashi
# two-timezone math, remittance reminder (never a wallet).
FamilySharingSnippetTests = _make_snippet_case(
    "core.logic.family_sharing_tests_snippets", "FamilySharingSnippetTests")
# Cost kill-switch & feature flags (admin, advanced §21 #178) — deterministic
# flag catalog + confirm-gate + append-only audit builder. Pure: no DB, no
# clock, no money; the owner/superuser console classifies every flip through it.
AdminFlagsSnippetTests = _make_snippet_case(
    "core.logic.admin_flags_tests_snippets", "AdminFlagsSnippetTests")
# Messenger chat-organise + message-action gates (reviewer-pass #86/#87, §21) —
# pure pin-cap/ordering, archive partition, duration-mute expiry, honest chat
# search state, and the edit/delete-scope/forward-hop gates. No DB, no AI.
MsgOrganiseSnippetTests = _make_snippet_case(
    "core.logic.msg_organise_tests_snippets", "MsgOrganiseSnippetTests")
# Message requests (#95) + message-level privacy (#96, §21 reviewer-pass) —
# pure stranger-gate routing (held-in-requests, never notifies), accept/decline/
# block/report resolution (silent decline, harsh-reason auto-block), and the
# conservative who-can-message / phone-hidden defaults + loosening confirm gate.
# No DB, no AI. Lives alongside the existing contacts/invite/connection logic.
MsgContactsSnippetTests = _make_snippet_case(
    "core.logic.msg_contacts_tests_snippets", "MsgContactsSnippetTests")
# Messenger COMMUNITIES (#93, §21) + CHANNELS (#94, §21) — pure server-side
# authority behind the reviewer-pass UI. Community: join FSM, admin approve/
# remove gates (non-admin refused, last-admin protected), message-request FSM +
# consent flow + rate limit, phone-hidden-by-default. Channel: follower privacy
# with count_only as the DEFAULT (never listed, even to the owner), a verified
# badge that requires a RECORDED operator approver (a forged flag reads as NOT
# verified), PII-free analytics, and the NOT-E2E guards. No DB, no AI.
MsgCommunitySnippetTests = _make_snippet_case(
    "core.logic.msg_community_tests_snippets", "MsgCommunitySnippetTests")
MsgChannelSnippetTests = _make_snippet_case(
    "core.logic.msg_channel_tests_snippets", "MsgChannelSnippetTests")
# PA Secretary mode (§14 #103 schedule control + #104 meeting reminder & 1-page
# brief, advanced §21) — pure deterministic schedule/conflict/next-up logic and
# deterministic brief assembly + reminder-lead math. No DB, no clock (now passed
# in), no AI; the AI-enhanced brief is a documented key-gated seam, not built.
PaScheduleSnippetTests = _make_snippet_case(
    "core.logic.pa_schedule_tests_snippets", "PaScheduleSnippetTests")
PaBriefSnippetTests = _make_snippet_case(
    "core.logic.pa_brief_tests_snippets", "PaBriefSnippetTests")
# PA Secretary mode (§14 #105 visitor/appointment filter + #108 liaison &
# follow-up, advanced §21) — pure deterministic engines, no DB/clock (now passed
# in)/AI. Visitor: triage (approve/decline/suggest), computed expiry, VIP/normal
# priority ordering, status/priority filter, privacy-minimised view. Liaison:
# waiting/replied/done, computed overdue, nudge cadence, urgency ordering.
PaVisitorSnippetTests = _make_snippet_case(
    "core.logic.pa_visitor_tests_snippets", "PaVisitorSnippetTests")
PaLiaisonSnippetTests = _make_snippet_case(
    "core.logic.pa_liaison_tests_snippets", "PaLiaisonSnippetTests")
# PA Secretary mode (§14 #111 role-based delegate access + #115 personal-task
# oversight, advanced §21) — pure deterministic scope model (LEAST-PRIVILEGE
# default, default-DENY can_access so a forged client scope reads as NOT granted,
# confirm gate on sensitive grants, append-only audit builder) and task
# priority/overdue(from passed-in now)/progress logic. No DB, no clock, no AI;
# server-side scope enforcement is the documented seam (up_pa3_integration.md).
PaDelegateSnippetTests = _make_snippet_case(
    "core.logic.pa_delegate_tests_snippets", "PaDelegateSnippetTests")
PaTasksSnippetTests = _make_snippet_case(
    "core.logic.pa_tasks_tests_snippets", "PaTasksSnippetTests")
# PA filing cabinet (#109) + meeting minutes (#110), §14 ADVANCED §21 — pure
# deterministic organiser/formatter; honest key-gated OCR/transcription seams.
PaFilingSnippetTests = _make_snippet_case("core.logic.pa_filing_tests_snippets", "PaFilingSnippetTests"); PaMinutesSnippetTests = _make_snippet_case("core.logic.pa_minutes_tests_snippets", "PaMinutesSnippetTests")
# PA travel & itinerary (#112) + expense voucher (#113) + research & presentation (#114), §14 ADVANCED §21 — pure deterministic builders; honest key-gated booking/OCR/AI seams.
PaTravelSnippetTests = _make_snippet_case("core.logic.pa_travel_tests_snippets", "PaTravelSnippetTests"); PaExpenseSnippetTests = _make_snippet_case("core.logic.pa_expense_tests_snippets", "PaExpenseSnippetTests"); PaResearchSnippetTests = _make_snippet_case("core.logic.pa_research_tests_snippets", "PaResearchSnippetTests")
# PA Secretary — CELEBRITY/STAR tier (§14 #121 brand-deal pipeline + #122 PR &
# press tracker + #123 unified social-inbox DM triage + #124 shoot/concert
# call-sheet + #125 personal lifestyle manager), ADVANCED §21 — pure deterministic
# engines; no DB/clock(now passed in)/AI; honest key-gated seams (IG+FB-Page DM
# fetch #123, opt-in reminders #125); holds no money; conservative privacy.
PaDealsSnippetTests = _make_snippet_case("core.logic.pa_deals_tests_snippets", "PaDealsSnippetTests"); PaPrSnippetTests = _make_snippet_case("core.logic.pa_pr_tests_snippets", "PaPrSnippetTests"); PaSocialInboxSnippetTests = _make_snippet_case("core.logic.pa_socialinbox_tests_snippets", "PaSocialInboxSnippetTests"); PaShootSnippetTests = _make_snippet_case("core.logic.pa_shoot_tests_snippets", "PaShootSnippetTests"); PaLifestyleSnippetTests = _make_snippet_case("core.logic.pa_lifestyle_tests_snippets", "PaLifestyleSnippetTests")
# Task Manager (#21, §21 ADVANCED) — projects + board engine. Pure, no DB/AI/
# clock (now passed in): normalize/validate, honest overdue, deterministic
# ordering + board bucketing, status-move (done⇄active progress honesty),
# status/assignee filters, per-project progress rollups. Backed by two owner-
# scoped REST collections (see up_taskmgr_integration.md); mirrors
# app/lib/screens/task_manager_screen.dart.
TaskManagerSnippetTests = _make_snippet_case(
    "core.logic.task_manager_tests_snippets", "TaskManagerSnippetTests")
# Section-20 thin modules (advanced §21): Samity/committee (#184) — rotating-
# savings tracker (members, per-cycle contributions, payout rotation, honest
# collected/pending); Landlord-tenant (#185) — rent/utility-share tracking,
# paid/due per month, receipt note, arrears. Both PURE, deterministic, hold no
# money (holds_money/charges_money constant False); mirrors of samity_engine.dart
# / rent_engine.dart. Persist via generic owned collections (see
# .phaseB/up_samityrent_integration.md).
SamitySnippetTests = _make_snippet_case(
    "core.logic.samity_tests_snippets", "SamitySnippetTests")
LandlordTenantSnippetTests = _make_snippet_case(
    "core.logic.landlord_tenant_tests_snippets", "LandlordTenantSnippetTests")
# Student corner (#192, §20) + Wedding & events (#189, §20) — pure deterministic
# tools: credit-weighted CGPA on the UGC Bangladeshi 4.00 scale (transparent
# per-course math, F counts in credits), class-routine grouping with honest
# overlap flags, assignment/task overdue from a passed-in `now`, event-budget
# estimated-vs-actual with an honest over-budget warning (integer poisha), guest
# RSVP head-count, and a reproducible countdown. No DB/AI/clock; holds no money.
# Persist via generic owned collections (see .phaseB/up_studwed_integration.md).
StudentCornerSnippetTests = _make_snippet_case(
    "core.logic.student_corner_tests_snippets", "StudentCornerSnippetTests")
WeddingEventsSnippetTests = _make_snippet_case(
    "core.logic.wedding_events_tests_snippets", "WeddingEventsSnippetTests")
SecurityCheckupSnippetTests = _make_snippet_case(
    "core.logic.security_checkup_tests_snippets", "SecurityCheckupSnippetTests")
# Farmer / village mode (#199, §20 ADVANCED) — pure deterministic farm engine:
# per-record lifecycle status (planned/growing/harvested/sold) + profit math
# (never invents a price), farm-wide ledger totals, a FIXED cropping-season
# almanac lookup (Rabi/Kharif-1/Kharif-2 — NOT live weather), and vaccination-
# due (due/soon/ok/unknown) from a passed-in `now` as the reminder SEAM. No
# DB/AI/wall-clock; holds no money. Mirrors app/lib/widgets/farmer_engine.dart;
# persists via generic owned collections farmer/records + farmer/livestock (see
# .phaseB/up_farmtrust_integration.md).
FarmerModeSnippetTests = _make_snippet_case(
    "core.logic.farmer_mode_tests_snippets", "FarmerModeSnippetTests")
# Domestic staff / driver tracker (#186, §20 ADVANCED) + Savings challenge
# (#171, ADVANCED). Both pure, deterministic, integer-poisha; hold no money;
# all time-based values from a passed-in `now`. Staff: pro-rated monthly due
# (full month always pays the full salary EXACTLY; partial floored, a bad
# attendance entry never deducts), per-month paid/due/outstanding, advance/loan
# balance, honest net-dues (unpaid wages minus advance held) with dignity-first
# copy. Savings: deterministic schedule (52-week rising / fixed-period / open
# round-up jar), progress %/streak, projected-at-pace final (never inflated past
# goal), and behind/on-track/ahead vs what the plan EXPECTED by `now`. Mirror
# app/lib/screens/domestic_staff_screen.dart + savings_challenge_screen.dart;
# persist via generic owned collections (see .phaseB/up_staffsave_integration.md).
DomesticStaffSnippetTests = _make_snippet_case(
    "core.logic.domestic_staff_tests_snippets", "DomesticStaffSnippetTests")
SavingsChallengeSnippetTests = _make_snippet_case(
    "core.logic.savings_challenge_tests_snippets", "SavingsChallengeSnippetTests")
# Health timeline (#69, §10, advanced) + Water/sleep/diet tracker (#71, §10,
# advanced). Pure deterministic RECORD/TRACKER logic (chronological grouping;
# goal-progress, 7-day trend, honest streaks — time passed in). Never diagnose;
# "not medical advice" disclaimer returned. No DB, no AI, no external key.
# Mirrors app/lib/screens/health_timeline_screen.dart + wellness_tracker_screen.
HealthTimelineSnippetTests = _make_snippet_case(
    "core.logic.health_timeline_tests_snippets", "HealthTimelineSnippetTests")
WellnessTrackerSnippetTests = _make_snippet_case(
    "core.logic.wellness_tracker_tests_snippets", "WellnessTrackerSnippetTests")
# Kid's school corner (#27, §21 advanced) + Fitness partner (#72, §21 advanced) —
# pure deterministic logic: manual notice keyword→type routing (fee/exam/ptm/
# event/other, parent-confirmed, NO AI/scan), honest upcoming/overdue per child
# from a passed-in `now`, a documented reminder seam; and gentle non-medical
# fitness goal/workout progress, weekly summary + streak, honest behind/on-track/
# ahead status — AI coaching only as a documented key-gated seam (NOT built).
# No DB, no AI, no clock, no money-holding. Mirror the Dart engines in
# app/lib/screens/kid_school_screen.dart + fitness_partner_screen.dart.
KidSchoolSnippetTests = _make_snippet_case(
    "core.logic.kid_school_tests_snippets", "KidSchoolSnippetTests")
FitnessPartnerSnippetTests = _make_snippet_case(
    "core.logic.fitness_partner_tests_snippets", "FitnessPartnerSnippetTests")
# Daily challenges / quiz (#173, §21) — deterministic date->bank rotation (same
# day => same item), accurate bilingual Q&A bank (finance/health/safety/general),
# quiz scoring + streak + points summary. Points COUNT only; redemption to
# Premium is the documented referral seam (holds no money). Saved / bookmarks
# (#18, §21) — pure search / tag + kind filter / recent-sort / honest empty vs
# no-results states; cross-app "save this" via make_item + 'saved/items'.
DailyChallengesSnippetTests = _make_snippet_case(
    "core.logic.daily_challenges_tests_snippets", "DailyChallengesSnippetTests")
SavedItemsSnippetTests = _make_snippet_case(
    "core.logic.saved_items_tests_snippets", "SavedItemsSnippetTests")
# AI spending advice (#51, §21) — deterministic, rule-based OBSERVATIONS over
# the user's OWN summarised category totals (top category, share of spend,
# month-over-month change, overspend vs the user's budgets, factual savings
# pointer). NEVER financial advice (advice=False + disclaimer_key); never
# invents transactions. Deeper written AI advice is the documented, key-gated
# ai_seam (Integrations: anthropic / core.ai.generate). Pure, holds no money.
# Mirror of app/lib/screens/spending_advice_screen.dart.
SpendingAdviceSnippetTests = _make_snippet_case(
    "core.logic.spending_advice_tests_snippets", "SpendingAdviceSnippetTests")
# Market price radar (#34, §21) — manual bazar/material price tracker over the
# user's OWN logged prices (item, ৳, date, market): per-item trend, high/low/avg,
# %-change between the two latest logs. NEVER fabricates a live price; a live
# market-data feed is the documented, key-gated feed_seam (no price-feed key in
# the REGISTRY yet). Pure, holds no money. Mirror of
# app/lib/screens/price_radar_screen.dart.
PriceRadarSnippetTests = _make_snippet_case(
    "core.logic.price_radar_tests_snippets", "PriceRadarSnippetTests")
# Blog & script writing (#130, §21, ADVANCED) + Document scanner / organiser
# (#29, §21, ADVANCED). Both pure, deterministic, key-free: a template-assembled
# blog/script/caption/outline scaffold (placeholder prompts, never fabricated
# facts) and a manual document organiser (tag/type/search/filter). AI and OCR
# are honest, documented key-gated seams (Integrations `anthropic` / `ocr`) —
# the mock never fabricates AI text or extracted OCR text. Mirrors of
# app/lib/screens/blog_writer_screen.dart + doc_scanner_screen.dart.
BlogWriterSnippetTests = _make_snippet_case(
    "core.logic.blog_writer_tests_snippets", "BlogWriterSnippetTests")
DocScannerSnippetTests = _make_snippet_case(
    "core.logic.doc_scanner_tests_snippets", "DocScannerSnippetTests")
# Call & voice-note transcription organiser (#92, §21, ADVANCED, KEY-GATED) +
# Travel planner (#35, §21, ADVANCED, KEY-GATED). Both pure, deterministic,
# key-free organisers: a voice-note store (normalize/search/stats + manual
# transcript, never fabricated) and a trip planner (inclusive date math,
# passed-in-today countdown, integer-poisha estimated-vs-actual budget with no
# drift, packing %, itinerary counts). Auto speech-to-text, AI itinerary
# suggestions, and live booking/prices are honest documented key-gated seams
# (Integrations `transcription` / `anthropic` / booking) — the engines never
# fabricate a transcript, a suggestion, a price, or a booking. Mirrors of
# app/lib/screens/transcription_screen.dart + travel_planner_screen.dart.
TranscriptionSnippetTests = _make_snippet_case(
    "core.logic.transcription_tests_snippets", "TranscriptionSnippetTests")
TravelPlannerSnippetTests = _make_snippet_case(
    "core.logic.travel_planner_tests_snippets", "TravelPlannerSnippetTests")
# Quick tools (#17, §6, built to §21) + Morning brief & night summary (#7, §6,
# built to §21). Both pure, deterministic, key-free. Quick tools is a toolbox
# over entered text (extractive summarise / rule-based grammar fix / honest
# translate with a tiny common-phrase fallback / template tone-change /
# make-shareable) — every result an honest MOCK, translate never fabricates a
# sentence translation (key-gated `anthropic` seam via ai_plan()). The daily
# brief assembles a morning + night card DETERMINISTICALLY from the user's OWN
# data (reminders / payments / birthdays / events), inventing nothing; weather
# & news are honest key-gated placeholders (Integrations `weather` / `news`),
# never fabricated. Mirrors of app/lib/screens/quick_tools_screen.dart +
# daily_brief_screen.dart.
QuickToolsSnippetTests = _make_snippet_case(
    "core.logic.quick_tools_tests_snippets", "QuickToolsSnippetTests")
DailyBriefSnippetTests = _make_snippet_case(
    "core.logic.daily_brief_tests_snippets", "DailyBriefSnippetTests")
# PA CORPORATE tier (§14 #119 business travel & events + #120 project tracking)
# — pure deterministic event/travel/budget assembly & project/portfolio rollup
# (overdue from a passed-in `now`); honest {required, mock} booking/AI seams.
PaBizTravelSnippetTests = _make_snippet_case(
    "core.logic.pa_biztravel_tests_snippets", "PaBizTravelSnippetTests")
PaProjectsSnippetTests = _make_snippet_case(
    "core.logic.pa_projects_tests_snippets", "PaProjectsSnippetTests")
# Business #144 Supplier & wholesale market + #145 Demand map (§21, advanced) —
# pure deterministic supplier filter/compare/reorder + demand heat aggregation;
# honest {required, mock} partner-directory / live trade-data seams (no key yet).
SupplierMarketSnippetTests = _make_snippet_case(
    "core.logic.supplier_market_tests_snippets", "SupplierMarketSnippetTests")
DemandMapSnippetTests = _make_snippet_case(
    "core.logic.demand_map_tests_snippets", "DemandMapSnippetTests")
# Section-20 #194 Area/neighbourhood board + #187 Doctor appointment tracker
# (§21, advanced) — pure deterministic area-scoped post filter (conservative
# privacy: precise-location fields dropped) + appointment upcoming/past + derived
# missed + reminder-due from a passed-in `now`; honest key-gated {required, mock}
# live-booking partner seam (never fabricates a serial/booking). No DB, no clock.
AreaCommunitySnippetTests = _make_snippet_case(
    "core.logic.area_community_tests_snippets", "AreaCommunitySnippetTests")
DoctorSerialSnippetTests = _make_snippet_case(
    "core.logic.doctor_serial_tests_snippets", "DoctorSerialSnippetTests")


# ---------------------------------------------------------------------------
# Module 5 API wiring tests (endpoints + the CC enforcement reviewers flagged).
# ---------------------------------------------------------------------------
class Module5ApiTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(name="A", email="a@example.com",
                                              password="pw-abc-123")
        self.client.force_authenticate(self.user)

    def _accepted_member(self, name, relation, phone):
        # Real accepted relationship: sender sends to a peer account, the
        # RECEIVER accepts their incoming mirror (senders cannot accept their
        # own outgoing request), which converges the sender's row to accepted.
        peer = User.objects.create_user(name=name, phone=phone,
                                        password="pw-peer-002")
        m = self.client.post("/api/v1/circle/request",
                             {"name": name, "relation": relation, "phone": phone},
                             format="json").json()
        from .models import CircleMember
        incoming = CircleMember.objects.get(user=peer, direction="incoming")
        self.client.force_authenticate(peer)
        self.client.post(f"/api/v1/circle/request/{incoming.pk}/act",
                         {"event": "accept"}, format="json")
        self.client.force_authenticate(self.user)
        return m["id"]

    def test_health_and_medicine_and_unseen(self):
        self.assertEqual(self.client.get("/api/v1/health/tips").status_code, 200)
        r = self.client.get("/api/v1/medicine-db/search?q=para")
        self.assertEqual(r.status_code, 200)
        self.assertIn("meta", r.json())
        self.assertEqual(self.client.get("/api/v1/unseen").status_code, 200)

    def test_birthday_crud_and_drafts(self):
        r = self.client.post("/api/v1/birthdays",
                             {"name": "Ma", "date": "1970-05-01", "kind": "birthday"},
                             format="json")
        self.assertEqual(r.status_code, 201)
        bid = r.json()["id"]
        lst = self.client.get("/api/v1/birthdays").json()
        self.assertTrue(any(o["id"] == bid for o in lst["all"]))
        d = self.client.post("/api/v1/birthdays/drafts",
                            {"name": "Ma", "kind": "birthday"}, format="json")
        self.assertEqual(d.status_code, 200)
        self.assertTrue(d.json()["drafts"])
        self.assertEqual(
            self.client.post(f"/api/v1/birthdays/{bid}/delete").status_code, 200)

    def test_appointments_bulk_replace(self):
        body = {"items": [
            {"title": "Dentist", "start": "2099-01-01T10:00:00"},
            {"title": "", "start": "2099-01-01T11:00:00"},  # dropped (no title)
        ]}
        r = self.client.post("/api/v1/appointments/", body, format="json")
        self.assertEqual(r.status_code, 201)
        got = self.client.get("/api/v1/appointments/").json()
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["title"], "Dentist")

    def test_dictionary_and_ramadan_and_exam(self):
        self.assertEqual(
            self.client.get("/api/v1/dictionary/lookup?q=water").status_code, 200)
        rt = self.client.get("/api/v1/ramadan/times?lat=23.8&lon=90.4")
        self.assertEqual(rt.status_code, 200)
        self.assertIn("sehri_end", rt.json())
        ew = self.client.post("/api/v1/exam/watcher",
                            {"label": "SSC", "url": "https://x.example/r"},
                            format="json")
        self.assertEqual(ew.status_code, 201)

    def test_reset_neutral_no_enumeration(self):
        self.client.force_authenticate(None)
        r1 = self.client.post("/api/v1/auth/reset/request",
                            {"email": "a@example.com"}, format="json")
        r2 = self.client.post("/api/v1/auth/reset/request",
                            {"email": "nobody@example.com"}, format="json")
        self.assertEqual(r1.status_code, 200)
        # Same neutral message whether or not the account exists.
        self.assertEqual(r1.json()["message"], r2.json()["message"])

    def test_reset_confirm_single_use(self):
        from .models import PasswordResetToken
        from . import reset as R
        from django.utils import timezone as tz
        raw, token_hash = R.generate_token()
        PasswordResetToken.objects.create(
            user=self.user, token_hash=token_hash,
            expires_at=R.expiry(tz.now()))
        self.client.force_authenticate(None)
        ok = self.client.post("/api/v1/auth/reset/confirm",
                            {"token": raw, "password": "newpass123"}, format="json")
        self.assertEqual(ok.status_code, 200)
        # second use of the same token fails (single-use enforced via DB flag)
        again = self.client.post("/api/v1/auth/reset/confirm",
                            {"token": raw, "password": "newpass999"}, format="json")
        self.assertEqual(again.status_code, 400)

    def test_legal_and_name_public(self):
        self.assertEqual(self.client.get("/api/v1/legal").status_code, 200)
        self.assertEqual(self.client.get("/api/v1/legal/privacy").status_code, 200)
        self.assertEqual(self.client.get("/api/v1/legal/nope").status_code, 404)
        self.assertEqual(self.client.get("/api/v1/name/about").status_code, 200)

    def test_photo_plan_honours_declared_document_kind(self):
        # Even with own-photo attested, a DECLARED document is hard-blocked
        # server-side (defence-in-depth — GAP-1).
        r = self.client.post("/api/v1/photo/plan",
                           {"kind": "document", "ops": ["denoise"], "own_photo": True},
                           format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["allowed"])
        ok = self.client.post("/api/v1/photo/plan",
                           {"kind": "personal", "ops": ["denoise"], "own_photo": True},
                           format="json")
        self.assertTrue(ok.json()["allowed"])

    def test_analytics_ingest_hashes_and_no_pii(self):
        r = self.client.post("/api/v1/analytics/ingest",
                           {"events": [{"name": "app_open", "props": {"feature": "x"}}]},
                           format="json")
        self.assertEqual(r.status_code, 200)
        from .models import AnalyticsEvent
        ev = AnalyticsEvent.objects.first()
        self.assertIsNotNone(ev)
        self.assertNotEqual(ev.uid_hash, str(self.user.id))
        self.assertEqual(len(ev.uid_hash), 32)

    def test_circle_message_rejects_plaintext_envelope(self):
        # add a member (accepted) then try to persist a non-ciphertext envelope.
        mid = self._accepted_member("B", "friend", "123")
        # forbidden plaintext field -> validate_envelope rejects before persist
        bad = self.client.post(f"/api/v1/circle/{mid}/messages",
                            {"content_type": "text", "plaintext": "hi",
                             "recipient_ids": [mid]}, format="json")
        self.assertEqual(bad.status_code, 400)
        # valid ciphertext envelope persists
        good = self.client.post(f"/api/v1/circle/{mid}/messages",
                            {"content_type": "text", "ciphertext": "AAAA",
                             "nonce": "BBBB", "recipient_ids": [mid]}, format="json")
        self.assertEqual(good.status_code, 201)

    def test_circle_report_auto_blocks(self):
        m = self.client.post("/api/v1/circle/request",
                          {"name": "C", "relation": "friend", "phone": "9"},
                          format="json").json()
        mid = m["id"]
        self.client.post(f"/api/v1/circle/request/{mid}/act",
                       {"event": "accept"}, format="json")
        rep = self.client.post(f"/api/v1/circle/{mid}/report",
                            {"reason": "harassment"}, format="json")
        self.assertEqual(rep.status_code, 200)
        self.assertTrue(rep.json()["auto_block"])
        from .models import CircleMember
        self.assertEqual(CircleMember.objects.get(pk=mid).state, "blocked")

    def test_circle_scoped_read_gate(self):
        mid = self._accepted_member("D", "friend", "7")
        # friend default does NOT share medicines -> 403
        denied = self.client.get(f"/api/v1/circle/{mid}/see/medicines")
        self.assertEqual(denied.status_code, 403)
        # grant it, then allowed
        self.client.post(f"/api/v1/circle/{mid}/sharing",
                       {"sharing": {"medicines": True}}, format="json")
        allowed = self.client.get(f"/api/v1/circle/{mid}/see/medicines")
        self.assertEqual(allowed.status_code, 200)


# ===========================================================================
# build-61 wave API tests — referral, journey, calls (video gate), privacy.
# ===========================================================================
class Build61ApiTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(name="Mina", email="mina@example.com",
                                              password="pw-abc-123")
        self.client.force_authenticate(self.user)

    def _accepted_member(self):
        # Build a real accepted relationship the way the accept flow does:
        # sender creates an OUTGOING request to a peer account, the RECEIVER
        # accepts their INCOMING mirror, which converges the sender's row to
        # accepted. (Senders may not accept their own outgoing request.)
        peer = User.objects.create_user(name="Ammu", phone="1",
                                        password="pw-peer-001")
        m = self.client.post("/api/v1/circle/request",
                             {"name": "Ammu", "relation": "mother", "phone": "1"},
                             format="json").json()
        from .models import CircleMember
        incoming = CircleMember.objects.get(user=peer, direction="incoming")
        self.client.force_authenticate(peer)
        self.client.post(f"/api/v1/circle/request/{incoming.pk}/act",
                         {"event": "accept"}, format="json")
        self.client.force_authenticate(self.user)
        return m["id"]

    def test_referral_balance_history_redeem(self):
        from .models import ReferralGrant
        ReferralGrant.objects.create(user=self.user, kind="grant", points=100,
                                     reason="referral_accept")
        bal = self.client.get("/api/v1/referral/balance")
        self.assertEqual(bal.status_code, 200)
        self.assertEqual(bal.json()["points"], 100)
        self.assertIn("invite_link", bal.json())
        hist = self.client.get("/api/v1/referral/history")
        self.assertEqual(hist.status_code, 200)
        self.assertTrue(hist.json()["history"])
        # redeem 50 points -> 2 Premium days (25/day), plan becomes premium.
        red = self.client.post("/api/v1/referral/redeem", {"points": 50},
                               format="json")
        self.assertEqual(red.status_code, 200)
        self.assertEqual(red.json()["days"], 2)
        self.user.refresh_from_db()
        self.assertEqual(self.user.plan, "premium")
        self.assertIsNotNone(self.user.plan_until)

    def test_video_call_gate_blocks_free_caller(self):
        mid = self._accepted_member()
        # free user: voice allowed, video requires premium (server-enforced).
        voice = self.client.post(f"/api/v1/circle/{mid}/call", {"kind": "voice"},
                                 format="json")
        self.assertTrue(voice.json()["allowed"])
        video = self.client.post(f"/api/v1/circle/{mid}/call", {"kind": "video"},
                                 format="json")
        self.assertFalse(video.json()["allowed"])
        self.assertTrue(video.json()["upgrade_required"])

    def test_privacy_roundtrip(self):
        r = self.client.get("/api/v1/circle/privacy")
        self.assertEqual(r.status_code, 200)
        s = self.client.post("/api/v1/circle/privacy",
                             {"read_receipts": False, "call_policy": "nobody"},
                             format="json")
        self.assertEqual(s.status_code, 200)
        self.assertFalse(s.json()["read_receipts"])
        self.assertEqual(s.json()["call_policy"], "nobody")

    def test_journey_start_arrive_and_webtoken(self):
        mid = self._accepted_member()
        start = self.client.post("/api/v1/journey/start", {
            "destination": {"name": "Office", "lat": 23.81, "lng": 90.41},
            "eta": "2099-01-01T10:00:00Z", "watcher_ids": [mid],
            "location_retention_hours": 24}, format="json")
        self.assertEqual(start.status_code, 201)
        jid = start.json()["id"]
        self.assertIsNotNone(start.json()["web_link"])
        active = self.client.get("/api/v1/journey/active")
        self.assertEqual(active.json()["id"], jid)
        link = self.client.get(f"/api/v1/journey/{jid}/web-link")
        self.assertEqual(link.status_code, 200)
        arr = self.client.post(f"/api/v1/journey/{jid}/arrived", {}, format="json")
        self.assertEqual(arr.status_code, 200)

    def test_duress_pin_rejects_equal_pins(self):
        bad = self.client.post("/api/v1/journey/duress-pin",
                               {"pin": "1234", "duress_pin": "1234"},
                               format="json")
        self.assertEqual(bad.status_code, 400)
        ok = self.client.post("/api/v1/journey/duress-pin",
                              {"pin": "1234", "duress_pin": "9999"},
                              format="json")
        self.assertEqual(ok.status_code, 200)

    def test_wellness_requires_parent_opt_in(self):
        # enabled stays False without parent_opt_in (arming GATE).
        r = self.client.post("/api/v1/journey/wellness",
                             {"enabled": True}, format="json")
        self.assertFalse(r.json()["enabled"])
        r2 = self.client.post("/api/v1/journey/wellness",
                             {"enabled": True, "parent_opt_in": True},
                             format="json")
        self.assertTrue(r2.json()["enabled"])

    def test_message_action_star_and_pin(self):
        mid = self._accepted_member()
        send = self.client.post(f"/api/v1/circle/{mid}/messages",
                               {"ciphertext": "x", "nonce": "n",
                                "sender_key_id": "k", "scheme": "s"},
                               format="json")
        self.assertEqual(send.status_code, 201)
        msg_id = send.json()["id"]
        star = self.client.post(f"/api/v1/circle/messages/{msg_id}/star", {},
                               format="json")
        self.assertTrue(star.json()["starred"])
        pin = self.client.post(f"/api/v1/circle/messages/{msg_id}/pin", {},
                              format="json")
        self.assertTrue(pin.json()["pinned"])


class FamilySharingApiTests(APITestCase):
    """#67 Selective sharing endpoints — owner-scoped, default-deny, audited.

    The FamilySharing model is NEW (migration surface: core 0030, created by the
    integrator via makemigrations). Until that migration exists the table is
    absent in the test DB, so this suite skips rather than erroring — it runs in
    full once the integrator has run makemigrations."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        from django.db import connection
        from .models import FamilySharing
        table = FamilySharing._meta.db_table
        if table not in connection.introspection.table_names():
            import unittest
            raise unittest.SkipTest(
                "FamilySharing table absent — run makemigrations (core 0030)")

    def setUp(self):
        self.user = User.objects.create_user(
            name="মালিক", phone="01710000000", password="secret123")
        self.client.force_authenticate(user=self.user)
        from .models import FamilyMember
        self.m = FamilyMember.objects.create(
            user=self.user, name="বাবা", relation="father")

    def test_default_deny_consent_empty(self):
        r = self.client.get("/api/v1/family/sharing/consent/")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["total_shared"], 0)
        row = next(x for x in r.json()["rows"] if x["member_id"] == self.m.id)
        self.assertFalse(any(row["items"].values()))

    def test_grant_then_revoke_and_audit(self):
        g = self.client.post("/api/v1/family/sharing/grant/",
                             {"member_id": self.m.id, "item": "location",
                              "on": True}, format="json")
        self.assertEqual(g.status_code, 200)
        self.assertEqual(g.json()["total_shared"], 1)
        # server-enforced read: granted item is visible
        ok = self.client.get(
            f"/api/v1/family/shared/{self.m.id}/location/")
        self.assertEqual(ok.status_code, 200)
        self.assertTrue(ok.json()["shared"])
        # ungranted item is default-deny (403)
        no = self.client.get(
            f"/api/v1/family/shared/{self.m.id}/documents/")
        self.assertEqual(no.status_code, 403)
        # revoke the member
        rm = self.client.post("/api/v1/family/sharing/revoke-member/",
                              {"member_id": self.m.id}, format="json")
        self.assertEqual(rm.status_code, 200)
        self.assertEqual(rm.json()["total_shared"], 0)
        after = self.client.get(
            f"/api/v1/family/shared/{self.m.id}/location/")
        self.assertEqual(after.status_code, 403)
        # audit log records both actions
        a = self.client.get("/api/v1/family/sharing/audit/")
        actions = [e["action"] for e in a.json()["entries"]]
        self.assertIn("grant", actions)
        self.assertIn("revoke_member", actions)

    def test_revoke_all(self):
        self.client.post("/api/v1/family/sharing/grant/",
                         {"member_id": self.m.id, "item": "medicine",
                          "on": True}, format="json")
        r = self.client.post("/api/v1/family/sharing/revoke-all/", {},
                            format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["total_shared"], 0)

    def test_unknown_item_rejected(self):
        r = self.client.post("/api/v1/family/sharing/grant/",
                            {"member_id": self.m.id, "item": "bank_pin",
                             "on": True}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_requires_auth(self):
        self.client.force_authenticate(user=None)
        r = self.client.get("/api/v1/family/sharing/consent/")
        self.assertIn(r.status_code, (401, 403))


# ===========================================================================
# Stolen-While-Unlocked Protection — scenario tests
#   Prove a thief with an UNLOCKED phone still cannot quietly transfer/disarm:
#   untrusted actions are delayed (24h) and cancelable; a theft signal freezes
#   (blocks) transfers; 5 wrong PINs lock + signal + alert; an approver gates
#   sell/disarm; the real owner at a trusted SavedPlace acts immediately.
# ===========================================================================
from django.utils import timezone as _tz
from datetime import timedelta as _td

from .models import (ProtectedPhone, PendingSensitiveAction, CircleMember,
                     FamilyAlert, SavedPlace)


class StolenProtectionScenarioTests(APITestCase):
    PIN = "2468"

    def setUp(self):
        self.user = User.objects.create_user(
            name="মালিক", phone="01799999999", password="secret123",
            email="owner@example.com")
        self.client.force_authenticate(user=self.user)
        # Provision the handset + set a PIN through the real endpoint.
        r = self.client.post("/api/v1/security/pin/set",
                             {"new_pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 200)
        self.phone = ProtectedPhone.objects.get(owner=self.user)
        self.phone.armed = True
        self.phone.save()
        # A trusted place at (23.80, 90.40).
        self.home = SavedPlace.objects.create(
            user=self.user, label="home", name="Home", lat=23.80, lng=90.40)

    # -- helpers ----------------------------------------------------------
    def _action(self, action, pin=None, lat=None, lng=None):
        body = {"action": action, "pin": pin if pin is not None else self.PIN}
        if lat is not None:
            body["lat"] = lat
            body["lng"] = lng
        return self.client.post("/api/v1/security/action", body, format="json")

    # -- scenarios --------------------------------------------------------
    def test_thief_disarm_untrusted_is_delayed_and_cancelable(self):
        # Untrusted location (far from home) -> delayed ~24h, NOT applied.
        r = self._action("disarm", lat=22.0, lng=88.0)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["state"], "pending")
        eff = r.data["effective_at"]
        self.assertIsNotNone(eff)
        pending = PendingSensitiveAction.objects.get(id=r.data["id"])
        delta = pending.effective_at - pending.requested_at
        self.assertTrue(_td(hours=23) < delta < _td(hours=25))
        # Still armed (not applied yet) + owner alerted.
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.armed)
        self.assertTrue(FamilyAlert.objects.filter(user=self.user).exists())
        # Cancel with the token, no auth ("this wasn't me").
        self.client.force_authenticate(user=None)
        c = self.client.post(f"/api/v1/security/action/{pending.id}/cancel",
                             {"token": pending.cancel_token}, format="json")
        self.assertEqual(c.status_code, 200)
        pending.refresh_from_db()
        self.assertEqual(pending.state, "cancelled")

    def test_sell_transfer_while_frozen_is_blocked_423(self):
        # Simulate a prior theft signal -> frozen.
        self.phone.frozen_until = _tz.now() + _td(hours=10)
        self.phone.save()
        r = self._action("sell_transfer", lat=23.80, lng=90.40)
        self.assertEqual(r.status_code, 423)
        self.assertEqual(r.data["state"], "blocked")
        self.assertEqual(r.data["reason"], "frozen")

    def test_five_wrong_pins_locks_and_signals_and_alerts(self):
        last = None
        for _ in range(5):
            last = self.client.post("/api/v1/security/pin/verify",
                                    {"pin": "0000"}, format="json")
        self.assertEqual(last.status_code, 200)
        self.assertFalse(last.data["ok"])
        self.assertTrue(last.data.get("locked"))
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.frozen_until and
                        self.phone.frozen_until > _tz.now())
        kinds = [s["kind"] for s in self.phone.signals]
        self.assertIn("wrong_pin", kinds)
        self.assertTrue(FamilyAlert.objects.filter(user=self.user).exists())

    def test_change_pin_and_remove_admin_untrusted_are_delayed(self):
        for action in ("change_pin", "remove_admin"):
            r = self._action(action, lat=1.0, lng=1.0)
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.data["state"], "pending", action)
            self.assertIsNotNone(r.data["effective_at"])

    def test_owner_at_trusted_place_is_immediate(self):
        r = self._action("disarm", lat=23.8001, lng=90.4001)  # ~15m from home
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["state"], "applied")
        self.phone.refresh_from_db()
        self.assertFalse(self.phone.armed)  # disarm actually applied

    def test_family_approver_sell_disarm_awaits_approval_until_approve(self):
        approver_user = User.objects.create_user(
            name="বাবা", phone="01788888888", password="x",
            email="dad@example.com")
        member = CircleMember.objects.create(
            user=self.user, peer_user=approver_user, state="accepted",
            name="Dad", relation="family")
        self.phone.family_approver = member
        self.phone.save()
        # sell_transfer from a TRUSTED place still awaits approval.
        r = self._action("sell_transfer", lat=23.80, lng=90.40)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["state"], "awaiting_approval")
        pid = r.data["id"]
        # A non-approver cannot approve.
        other = User.objects.create_user(name="x", phone="01700000001", password="x")
        self.client.force_authenticate(user=other)
        bad = self.client.post(f"/api/v1/security/action/{pid}/approve", {}, format="json")
        self.assertEqual(bad.status_code, 403)
        # The approver can.
        self.client.force_authenticate(user=approver_user)
        good = self.client.post(f"/api/v1/security/action/{pid}/approve", {}, format="json")
        self.assertEqual(good.status_code, 200)
        self.assertEqual(good.data["state"], "applied")


# ===========================================================================
# Anti-theft Batch 4 — stolen-IMEI registry + used-phone check + sell transfer.
#   Proves: gd_number is required; a check never leaks the reporter but DOES
#   alert them (coarse area only); ownership moves ONLY through buyer-accept;
#   a theft signal / active stolen report blocks the transfer; checks are
#   rate-limited.
# ===========================================================================
from .models import StolenReport, ImeiCheckLog, SaleReceipt  # noqa: E402
from .logic import security as _sec  # noqa: E402


class RegistryTransferScenarioTests(APITestCase):
    IMEI = "357219087654321"

    def setUp(self):
        self.seller = User.objects.create_user(
            name="বিক্রেতা", phone="01811111111", password="x",
            email="seller@example.com")
        self.buyer = User.objects.create_user(
            name="ক্রেতা", phone="01822222222", password="x",
            email="buyer@example.com")
        self.phone = ProtectedPhone.objects.create(
            owner=self.seller, imei1=self.IMEI, model_name="Pixel")

    def _as(self, user):
        self.client.force_authenticate(user=user)

    # -- report-stolen ----------------------------------------------------
    def test_report_without_gd_is_400_with_gd_flags_phone(self):
        self._as(self.seller)
        bad = self.client.post("/api/v1/registry/report-stolen",
                               {"imei": self.IMEI}, format="json")
        self.assertEqual(bad.status_code, 400)
        self.assertFalse(StolenReport.objects.exists())

        ok = self.client.post(
            "/api/v1/registry/report-stolen",
            {"imei": self.IMEI, "gd_number": "GD-123/2026",
             "area": "Dhaka, Mirpur"}, format="json")
        self.assertEqual(ok.status_code, 200)
        rep = StolenReport.objects.get(id=ok.data["report_id"])
        self.assertEqual(rep.status, "active")
        self.phone.refresh_from_db()
        self.assertEqual(self.phone.status, "reported_stolen")

    # -- check: clean / reported_stolen (reporter alerted, identity hidden)
    def test_check_clean(self):
        self._as(self.buyer)
        r = self.client.post("/api/v1/registry/check",
                             {"imei": self.IMEI}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["result"], "clean")
        self.assertEqual(r.data["advice_key"], "buy_ok")

    def test_check_reported_stolen_alerts_reporter_hides_identity(self):
        self._as(self.seller)
        self.client.post(
            "/api/v1/registry/report-stolen",
            {"imei": self.IMEI, "gd_number": "GD-9/2026",
             "area": "Dhaka, Mirpur"}, format="json")
        # A DIFFERENT user checks the IMEI.
        self._as(self.buyer)
        r = self.client.post("/api/v1/registry/check",
                             {"imei": self.IMEI}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["result"], "reported_stolen")
        self.assertEqual(r.data["advice_key"], "contact_police_dont_confront")
        # Response never names the reporter.
        self.assertNotIn("reporter", r.data)
        self.assertNotIn("seller@example.com", str(r.data))
        # The REPORTER (seller) got an alert; it carries coarse area, not the
        # checker's identity/location.
        alert = FamilyAlert.objects.filter(user=self.seller).order_by("-id").first()
        self.assertIsNotNone(alert)
        self.assertEqual(alert.payload.get("area"), "Dhaka, Mirpur")
        self.assertNotIn("buyer@example.com", str(alert.payload))
        self.assertNotIn("ক্রেতা", alert.body)

    def test_recover_clears_status_and_check_clean_again(self):
        self._as(self.seller)
        self.client.post(
            "/api/v1/registry/report-stolen",
            {"imei": self.IMEI, "gd_number": "GD-1/2026"}, format="json")
        rec = self.client.post("/api/v1/registry/recover",
                               {"imei": self.IMEI}, format="json")
        self.assertEqual(rec.status_code, 200)
        self.phone.refresh_from_db()
        self.assertEqual(self.phone.status, "owned")
        self._as(self.buyer)
        r = self.client.post("/api/v1/registry/check",
                             {"imei": self.IMEI}, format="json")
        self.assertEqual(r.data["result"], "clean")

    # -- full sale: create -> authorize -> buyer accept -> ownership moved -
    def test_full_sale_moves_ownership_and_verifies(self):
        self._as(self.seller)
        cr = self.client.post(
            "/api/v1/sale/create",
            {"imei": self.IMEI, "price": 15000, "buyer_name": "ক্রেতা"},
            format="json")
        self.assertEqual(cr.status_code, 200)
        self.assertEqual(cr.data["state"], "draft")
        token = cr.data["token"]

        au = self.client.post("/api/v1/sale/authorize",
                              {"id": cr.data["id"]}, format="json")
        self.assertEqual(au.status_code, 200)
        self.assertEqual(au.data["state"], "authorized")
        self.phone.refresh_from_db()
        self.assertEqual(self.phone.status, "transfer_pending")

        # The BUYER (different user) accepts via the QR token.
        self._as(self.buyer)
        ac = self.client.post("/api/v1/sale/accept",
                              {"token": token}, format="json")
        self.assertEqual(ac.status_code, 200)
        self.assertEqual(ac.data["state"], "accepted")

        # Ownership moved server-side.
        self.phone.refresh_from_db()
        self.assertEqual(self.phone.status, "transferred")
        buyer_phone = ProtectedPhone.objects.filter(
            owner=self.buyer, imei1=self.IMEI).first()
        self.assertIsNotNone(buyer_phone)
        self.assertEqual(buyer_phone.status, "owned")

        # Registry now returns verified_transfer.
        chk = self.client.post("/api/v1/registry/check",
                               {"imei": self.IMEI}, format="json")
        self.assertEqual(chk.data["result"], "verified_transfer")
        self.assertEqual(chk.data["advice_key"], "verified_ok")

    # -- authorize BLOCKED when a theft signal is recent ------------------
    def test_authorize_blocked_by_recent_theft_signal(self):
        self._as(self.seller)
        cr = self.client.post(
            "/api/v1/sale/create", {"imei": self.IMEI, "price": 1},
            format="json")
        # A recent theft signal lands (and freezes).
        _sec.register_signal(self.phone, "snatch", _tz.now())
        self.phone.save()
        au = self.client.post("/api/v1/sale/authorize",
                              {"id": cr.data["id"]}, format="json")
        self.assertIn(au.status_code, (409, 423))
        self.assertFalse(au.data.get("ok", False))
        SaleReceipt.objects.get(id=cr.data["id"]).refresh_from_db()
        self.assertEqual(
            SaleReceipt.objects.get(id=cr.data["id"]).state, "draft")

    # -- accept BLOCKED if reported_stolen --------------------------------
    def test_accept_blocked_if_reported_stolen_after_authorize(self):
        self._as(self.seller)
        cr = self.client.post(
            "/api/v1/sale/create", {"imei": self.IMEI, "price": 1},
            format="json")
        au = self.client.post("/api/v1/sale/authorize",
                              {"id": cr.data["id"]}, format="json")
        self.assertEqual(au.status_code, 200)
        # Now the phone is reported stolen (e.g. snatched mid-sale).
        StolenReport.objects.create(
            imei=self.IMEI, reporter=self.seller, gd_number="GD-77", status="active")
        self._as(self.buyer)
        ac = self.client.post("/api/v1/sale/accept",
                              {"token": cr.data["token"]}, format="json")
        self.assertIn(ac.status_code, (409, 423))
        self.assertFalse(ac.data.get("ok", False))
        self.assertEqual(
            SaleReceipt.objects.get(id=cr.data["id"]).state, "authorized")

    # -- rate-limit: 21st check in an hour -> 429 -------------------------
    def test_rate_limit_21st_check_is_429(self):
        self._as(self.buyer)
        for i in range(20):
            r = self.client.post("/api/v1/registry/check",
                                 {"imei": self.IMEI}, format="json")
            self.assertEqual(r.status_code, 200, f"check {i}")
        r21 = self.client.post("/api/v1/registry/check",
                               {"imei": self.IMEI}, format="json")
        self.assertEqual(r21.status_code, 429)
        self.assertEqual(ImeiCheckLog.objects.filter(checker=self.buyer).count(), 20)

    # -- NEIR placeholder is disabled, never fakes a block ----------------
    def test_neir_status_disabled_placeholder(self):
        self._as(self.buyer)
        r = self.client.get("/api/v1/registry/neir-status")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["available"])
        self.assertEqual(r.data["message_key"], "neir_not_available")


# ===========================================================================
# Anti-theft Batch 5 — lost/stolen server-side + recovery helpers
# ===========================================================================
from .models import PhoneHeartbeat, CapturedEvent  # noqa: E402
from django.core.management import call_command as _call_command  # noqa: E402


class LostPhoneRecoveryTests(APITestCase):
    PIN = "1357"

    def setUp(self):
        self.owner = User.objects.create_user(
            name="মালিক", phone="01700000001", password="x",
            email="lostowner@example.com")
        self.helper = User.objects.create_user(
            name="সহায়ক", phone="01700000002", password="x",
            email="helper@example.com")
        self.stranger = User.objects.create_user(
            name="অপরিচিত", phone="01700000003", password="x",
            email="stranger@example.com")
        self.client.force_authenticate(user=self.owner)
        self.client.post("/api/v1/security/pin/set",
                         {"new_pin": self.PIN}, format="json")
        self.phone = ProtectedPhone.objects.get(owner=self.owner)
        self.phone.armed = True
        self.phone.imei1 = "351111111111111"
        self.phone.imei2 = "352222222222222"
        self.phone.model_name = "Realme 9i"
        self.phone.save()
        # helper is an accepted circle member of owner (can help track)
        self.member = CircleMember.objects.create(
            user=self.owner, peer_user=self.helper, name="সহায়ক",
            state="accepted", direction="outgoing")

    def _as(self, u):
        self.client.force_authenticate(user=u)

    # -- heartbeat updates last location + clears went-dark latch ---------
    def test_heartbeat_updates_location_and_clears_dark(self):
        self.phone.went_dark_alerted = True
        self.phone.save()
        r = self.client.post("/api/v1/security/heartbeat",
                             {"lat": 23.78, "lng": 90.41, "battery": 55,
                              "network": "mobile"}, format="json")
        self.assertEqual(r.status_code, 200)
        # Device gets its actionable state back.
        self.assertIn("lost_mode", r.data)
        self.assertIn("frozen", r.data)
        self.phone.refresh_from_db()
        self.assertEqual(self.phone.last_lat, 23.78)
        self.assertEqual(self.phone.last_lng, 90.41)
        self.assertIsNotNone(self.phone.last_heartbeat_at)
        self.assertFalse(self.phone.went_dark_alerted)
        self.assertEqual(PhoneHeartbeat.objects.filter(phone=self.phone).count(), 1)

    # -- events store, and a sim_change freezes the handset ---------------
    def test_events_store_and_sim_change_freezes(self):
        r = self.client.post(
            "/api/v1/security/events",
            {"events": [
                {"kind": "failed_unlock", "data": {"count": 3}},
                {"kind": "sim_change",
                 "data": {"new_sim": "01911112222", "operator": "GP"}},
            ]}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["stored"], 2)
        self.assertTrue(r.data["frozen"])
        self.assertEqual(CapturedEvent.objects.filter(phone=self.phone).count(), 2)
        self.phone.refresh_from_db()
        self.assertTrue(_sec.is_frozen(self.phone, _tz.now()))
        # one alert batch for the owner
        self.assertTrue(FamilyAlert.objects.filter(user=self.owner).exists())

    # -- lost-mode ON is protective; OFF must use security/action (409) ---
    def test_lost_mode_on_protective_off_via_action_409(self):
        on = self.client.post("/api/v1/security/lost-mode",
                              {"on": True, "message": "Please call me",
                               "contact": "01700000001",
                               "reward": "1000 taka"}, format="json")
        self.assertEqual(on.status_code, 200)
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.lost_mode)
        self.assertIsNotNone(self.phone.lost_since)
        self.assertEqual(self.phone.lost_message, "Please call me")
        # Turning OFF directly is refused -> directed to security/action.
        off = self.client.post("/api/v1/security/lost-mode",
                               {"on": False}, format="json")
        self.assertEqual(off.status_code, 409)
        self.assertEqual(off.data["action"], "turn_off_lost")
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.lost_mode)  # still on
        # The real path: security/action turn_off_lost (trusted => immediate).
        SavedPlace.objects.create(user=self.owner, label="home",
                                  lat=23.80, lng=90.40)
        act = self.client.post(
            "/api/v1/security/action",
            {"action": "turn_off_lost", "pin": self.PIN,
             "lat": 23.80, "lng": 90.40}, format="json")
        self.assertEqual(act.status_code, 200)

    # -- lost-phone view: trail; readable by circle only while lost/dark --
    def test_lost_phone_view_and_circle_scope(self):
        # seed a short trail
        for la, ln in [(23.70, 90.40), (23.71, 90.41)]:
            self.client.post("/api/v1/security/heartbeat",
                             {"lat": la, "lng": ln}, format="json")
        # Owner always sees it.
        r = self.client.get("/api/v1/security/lost-phone")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["imei1"], "351111111111111")
        self.assertTrue(len(r.data["trail"]) >= 2)
        self.assertEqual(r.data["last_location"]["lat"], 23.71)

        # Helper (circle) BLOCKED while not lost/dark.
        self._as(self.helper)
        blk = self.client.get(f"/api/v1/security/lost-phone?phone_id={self.phone.id}")
        self.assertEqual(blk.status_code, 403)
        self.assertEqual(blk.data["reason"], "not_active")

        # Owner turns on lost mode -> helper can now read ONLY this.
        self._as(self.owner)
        self.client.post("/api/v1/security/lost-mode", {"on": True}, format="json")
        self._as(self.helper)
        ok = self.client.get(f"/api/v1/security/lost-phone?phone_id={self.phone.id}")
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(ok.data["viewer"], "circle")
        self.assertTrue(ok.data["lost_mode"])

        # A stranger (no relationship) is always forbidden, even while lost.
        self._as(self.stranger)
        no = self.client.get(f"/api/v1/security/lost-phone?phone_id={self.phone.id}")
        self.assertEqual(no.status_code, 403)

    # -- went-dark command alerts once, idempotent ------------------------
    def test_went_dark_command_alerts_once(self):
        # Last heartbeat long ago -> dark.
        self.phone.last_heartbeat_at = _tz.now() - _td(hours=5)
        self.phone.last_lat = 23.70
        self.phone.last_lng = 90.40
        self.phone.went_dark_alerted = False
        self.phone.save()
        before = FamilyAlert.objects.filter(user=self.owner).count()
        _call_command("check_went_dark")
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.went_dark_alerted)
        after1 = FamilyAlert.objects.filter(user=self.owner).count()
        self.assertEqual(after1, before + 1)
        # Second run is a no-op (idempotent).
        _call_command("check_went_dark")
        after2 = FamilyAlert.objects.filter(user=self.owner).count()
        self.assertEqual(after2, after1)

    # -- recovery text drafts: non-empty + localized ---------------------
    def test_gd_and_sp_drafts_localized(self):
        en = self.client.get("/api/v1/recovery/gd-draft",
                             HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(en.status_code, 200)
        self.assertTrue(en.data["text"].strip())
        self.assertIn("351111111111111", en.data["text"])
        self.assertIn("General Diary", en.data["text"])
        bn = self.client.get("/api/v1/recovery/gd-draft",
                             HTTP_ACCEPT_LANGUAGE="bn")
        self.assertIn("সাধারণ ডায়েরি", bn.data["text"])

        sp_en = self.client.get("/api/v1/recovery/sp-letter",
                                HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(sp_en.status_code, 200)
        self.assertIn("Superintendent of Police", sp_en.data["text"])
        sp_bn = self.client.get("/api/v1/recovery/sp-letter",
                                HTTP_ACCEPT_LANGUAGE="bn")
        self.assertIn("পুলিশ সুপার", sp_bn.data["text"])

    # -- evidence.pdf returns a PDF --------------------------------------
    def test_evidence_pdf(self):
        self.client.post("/api/v1/security/heartbeat",
                         {"lat": 23.70, "lng": 90.40, "battery": 40,
                          "network": "wifi"}, format="json")
        r = self.client.get("/api/v1/recovery/evidence.pdf")
        self.assertEqual(r.status_code, 200)
        body = r.getvalue() if hasattr(r, "getvalue") else b"".join(r.streaming_content)
        self.assertEqual(r["Content-Type"], "application/pdf")
        self.assertTrue(body.startswith(b"%PDF"))

    # -- police-stations honest: no location -> available:false ----------
    def test_police_stations_honest(self):
        none = self.client.get("/api/v1/recovery/police-stations")
        self.assertEqual(none.status_code, 200)
        self.assertFalse(none.data["available"])
        with_loc = self.client.get(
            "/api/v1/recovery/police-stations?lat=23.739&lng=90.395")
        self.assertEqual(with_loc.status_code, 200)
        self.assertEqual(with_loc.data["source"], "mock")
        self.assertTrue(with_loc.data["available"])


class ProfilePhotoTests(APITestCase):
    """Regression: the profile picture did not save. The app PATCHes /me with
    `photo` as a BASE64 string (not a multipart file); the old plain ImageField
    rejected it and the whole PATCH 400'd. These prove base64 upload sets the
    photo, returns a reachable ABSOLUTE url, and the authed avatar view streams
    the bytes — and that the visibility-token `show_phone` no longer 400s."""

    def setUp(self):
        import base64
        import io
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", (4, 4), (10, 120, 200)).save(buf, "PNG")
        self._png = buf.getvalue()
        self.PNG_B64 = base64.b64encode(self._png).decode()
        self.user = User.objects.create_user(
            name="Pic", phone="01900000009", password="x123456")
        self.client.force_authenticate(user=self.user)

    def tearDown(self):
        self.user.refresh_from_db()
        if self.user.photo:
            self.user.photo.delete(save=False)

    def test_base64_photo_upload_sets_and_returns_absolute_url(self):
        # Send exactly what the app sends: JSON PATCH with show_phone as a
        # visibility token AND photo as a bare base64 string.
        resp = self.client.patch(
            "/api/v1/me",
            {"name": "Pic", "show_phone": "circle",
             "photo": self.PNG_B64},
            format="json")
        self.assertEqual(resp.status_code, 200, resp.data)
        url = resp.data["photo_url"]
        self.assertTrue(url, "photo_url should be non-empty after upload")
        # Absolute + points at the authed avatar view (cache-busted).
        self.assertTrue(url.startswith("http"), url)
        self.assertIn("/api/v1/me/avatar", url)
        # Visibility token mapped to a bool, not rejected.
        self.user.refresh_from_db()
        self.assertTrue(self.user.show_phone)
        self.assertTrue(self.user.photo)

    def test_avatar_view_streams_bytes_authed(self):
        self.client.patch("/api/v1/me", {"photo": self.PNG_B64},
                           format="json")
        got = self.client.get("/api/v1/me/avatar")
        self.assertEqual(got.status_code, 200)
        body = b"".join(got.streaming_content)
        self.assertEqual(body[:8], self._png[:8])  # PNG signature

    def test_avatar_view_requires_auth(self):
        self.client.patch("/api/v1/me", {"photo": self.PNG_B64},
                           format="json")
        self.client.force_authenticate(user=None)
        self.assertIn(self.client.get("/api/v1/me/avatar").status_code,
                      (401, 403))

    def test_empty_string_removes_photo(self):
        self.client.patch("/api/v1/me", {"photo": self.PNG_B64},
                           format="json")
        self.user.refresh_from_db()
        self.assertTrue(self.user.photo)
        resp = self.client.patch("/api/v1/me", {"photo": ""}, format="json")
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data["photo_url"], "")
        self.user.refresh_from_db()
        self.assertFalse(self.user.photo)

    def test_get_me_round_trips_url(self):
        self.client.patch("/api/v1/me", {"photo": self.PNG_B64},
                           format="json")
        me = self.client.get("/api/v1/me")
        self.assertEqual(me.status_code, 200)
        self.assertIn("/api/v1/me/avatar", me.data["photo_url"])


# ===========================================================================
# Secure "Delete my profile & all data" — Play-compliant, Section-8-gated.
# ===========================================================================

class AccountDeletionScenarioTests(APITestCase):
    """A thief must NOT be able to wipe the owner's account; the 7-day grace +
    cancel-from-anywhere protect against malicious deletion; deletion is real
    and complete only after the grace period (Play-compliant)."""

    PIN = "4321"
    PW = "x123456"

    def setUp(self):
        from django.contrib.auth.hashers import make_password
        from .models import ProtectedPhone, SavedPlace, MemoryItem
        self.user = User.objects.create_user(
            name="Owner", phone="01970000001", password=self.PW)
        self.client.force_authenticate(user=self.user)
        # Primary protected phone WITH a Security PIN set.
        self.phone = ProtectedPhone.objects.create(
            owner=self.user, security_pin_hash=make_password(self.PIN))
        # A trusted place (home) so trusted/untrusted paths are testable.
        self.home = SavedPlace.objects.create(
            user=self.user, label="Home", lat=23.80, lng=90.40)
        # Some data to prove the cascade.
        MemoryItem.objects.create(user=self.user, title="secret note")

    def _request(self, **over):
        body = {"password": self.PW, "security_pin": self.PIN,
                # inside the trusted radius unless overridden
                "lat": 23.80, "lng": 90.40}
        body.update(over)
        return self.client.post("/api/v1/account/delete/request", body,
                                format="json")

    # -- auth factors -------------------------------------------------------

    def test_request_rejected_without_correct_password(self):
        r = self._request(password="wrong")
        self.assertEqual(r.status_code, 403, r.data)
        self.assertEqual(r.data["reason"], "bad_password")

    def test_request_rejected_without_correct_pin(self):
        r = self._request(security_pin="0000")
        self.assertEqual(r.status_code, 403, r.data)

    def test_request_rejected_with_bad_otp_when_code_issued(self):
        from .models import OTPCode
        from datetime import timedelta
        OTPCode.objects.create(identifier=self.user.phone, code="999999",
                               purpose="login",
                               expires_at=timezone.now() + timedelta(minutes=5))
        r = self._request(otp="000000")
        self.assertEqual(r.status_code, 403, r.data)
        self.assertEqual(r.data["reason"], "bad_otp")
        # correct code passes
        ok = self._request(otp="999999")
        self.assertEqual(ok.status_code, 200, ok.data)

    # -- happy path at a trusted place -> ~7-day grace ----------------------

    def test_request_all_factors_trusted_gives_7_day_grace(self):
        from .models import AccountDeletionRequest
        before = timezone.now()
        r = self._request()
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["state"], "pending")
        req = AccountDeletionRequest.objects.get(user=self.user)
        delta = req.effective_at - before
        # ~7 days (allow a minute of test slack).
        self.assertGreaterEqual(delta.total_seconds(), 7 * 86400 - 60)
        self.assertLess(delta.total_seconds(), 7 * 86400 + 120)

    # -- theft signal blocks (the thief cannot delete) ----------------------

    def test_request_blocked_while_theft_signal_active(self):
        from .logic import security as sec
        from .models import AccountDeletionRequest
        sec.register_signal(self.phone, "snatch", timezone.now())
        self.phone.save()
        r = self._request()
        self.assertEqual(r.status_code, 423, r.data)
        self.assertEqual(r.data["reason"], "theft_signal")
        self.assertFalse(AccountDeletionRequest.objects.filter(
            user=self.user).exists())

    # -- untrusted place respects BOTH grace and 24h delay ------------------

    def test_untrusted_respects_grace_and_24h_delay(self):
        from .models import AccountDeletionRequest
        before = timezone.now()
        # far from home -> untrusted
        r = self._request(lat=10.0, lng=10.0)
        self.assertEqual(r.status_code, 200, r.data)
        req = AccountDeletionRequest.objects.get(user=self.user)
        # must be at least the 7-day grace (which already exceeds the 24h delay)
        self.assertGreaterEqual((req.effective_at - before).total_seconds(),
                                7 * 86400 - 60)

    # -- cancel by token ----------------------------------------------------

    def test_cancel_by_token_works_unauthenticated(self):
        from .models import AccountDeletionRequest
        self._request()
        req = AccountDeletionRequest.objects.get(user=self.user)
        token = req.cancel_token
        self.assertTrue(token)
        self.client.force_authenticate(user=None)  # "this wasn't me", no login
        c = self.client.post("/api/v1/account/delete/cancel",
                             {"token": token}, format="json")
        self.assertEqual(c.status_code, 200, c.data)
        self.assertEqual(c.data["state"], "cancelled")
        req.refresh_from_db()
        self.assertEqual(req.state, "cancelled")

    def test_cancel_rejects_wrong_token_unauthenticated(self):
        self._request()
        self.client.force_authenticate(user=None)
        c = self.client.post("/api/v1/account/delete/cancel",
                             {"token": "nope"}, format="json")
        self.assertIn(c.status_code, (403, 404))

    # -- status + preview ---------------------------------------------------

    def test_status_and_preview(self):
        pv = self.client.post("/api/v1/account/delete/preview", {},
                              format="json")
        self.assertEqual(pv.status_code, 200, pv.data)
        self.assertTrue(pv.data["export_first"])
        self.assertIn("memories", pv.data["counts"])
        self._request()
        st = self.client.get("/api/v1/account/delete/status")
        self.assertEqual(st.status_code, 200, st.data)
        self.assertEqual(st.data["state"], "pending")

    # -- purge command ------------------------------------------------------

    def test_purge_deletes_only_past_due_pending_and_cascades(self):
        from django.core.management import call_command
        from datetime import timedelta
        from .models import AccountDeletionRequest, MemoryItem
        self._request()
        req = AccountDeletionRequest.objects.get(user=self.user)
        uid = self.user.id
        # Not yet due -> purge is a no-op.
        call_command("purge_deletions")
        self.assertTrue(User.objects.filter(id=uid).exists())
        # Make it due.
        req.effective_at = timezone.now() - timedelta(minutes=1)
        req.save(update_fields=["effective_at"])
        call_command("purge_deletions")
        # User + their data gone (cascade).
        self.assertFalse(User.objects.filter(id=uid).exists())
        self.assertFalse(MemoryItem.objects.filter(user_id=uid).exists())
        self.assertFalse(AccountDeletionRequest.objects.filter(
            user_id=uid).exists())
        # Idempotent: running again is a clean no-op.
        call_command("purge_deletions")

    def test_purge_never_touches_a_cancelled_request(self):
        from django.core.management import call_command
        from datetime import timedelta
        from .models import AccountDeletionRequest
        self._request()
        req = AccountDeletionRequest.objects.get(user=self.user)
        req.state = "cancelled"
        req.effective_at = timezone.now() - timedelta(days=1)  # past-due but cancelled
        req.save(update_fields=["state", "effective_at"])
        uid = self.user.id
        call_command("purge_deletions")
        self.assertTrue(User.objects.filter(id=uid).exists())
        req.refresh_from_db()
        self.assertEqual(req.state, "cancelled")
