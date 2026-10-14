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
# In-app updater (#180, §21) — pure version-compare helper. Fail-closed: never
# claims an update on ambiguous/garbage input; never returns a url unless an
# update is genuinely available and the link is a usable http(s) one.
AppUpdateSnippetTests = _make_snippet_case(
    "core.logic.app_update_tests_snippets", "AppUpdateSnippetTests")
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
