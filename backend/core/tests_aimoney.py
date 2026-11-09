"""aimoney (owner final order 10 Nov 03:45, part G): free AI money rules.

* AdFundedNoLossCiTests is part of the 40 % CI check (with
  tests_plansprep.FortyPercentCiTests): the build FAILS if an ad-funded AI
  answer can run at a loss under the configured worst case (the lowest
  per-ad income WORST_AD_INCOME_BDT, the longest allowed answer = the ad
  answer at its hard caps + one free Continue at the dearest free level),
  and it covers the new ৳49 = 15 credits pack.
* no welcome AI credits for new users (code default + pricing_welcome_off).
* the daily dynamic ads-per-answer number (minute_jobs ad_money_tick).
* an answer paid with rewarded-ad credits runs at Normal, shorter output,
  prompt caching on, no web search.
* Owner Admin -> Money (daily)."""
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from core import ad_money_service as AMS, ai, ai_levels_service as ALS, billing, credits as CR
from core.logic import ad_money as AM, ai_levels as AL, plan_book as BOOK
from core.models import AdMoneyDay, AdPlacementStat, AIUsage

from .tests_plansprep import v2_full, v2_on


def _user(phone="+8801900000881"):
    return get_user_model().objects.create_user(name="am", phone=phone, password="pw12345!")


# ------------------------------------------------------------------ pure formula
class FormulaTests(TestCase):
    def test_minimum_two_and_owner_formula(self):
        self.assertEqual(AM.ads_per_answer(0.01, 0.40, 0.0), 2)
        # ceil(0.50 x 1.2 / 0.40) = ceil(1.5) = 2 ; ceil(1.0 x 1.2 / 0.4) = 3
        self.assertEqual(AM.ads_per_answer(0.50, 0.40, 0.0), 2)
        self.assertEqual(AM.ads_per_answer(1.00, 0.40, 0.0), 3)
        # no AdMob data -> ৳0.40 an ad
        self.assertEqual(AM.ads_per_answer(1.00, 0, 0.0), 3)

    def test_never_below_the_longest_answer_break_even(self):
        # real answers are cheap but the longest one costs ৳0.9 -> 3 ads at ৳0.40
        self.assertEqual(AM.ads_per_answer(0.05, 0.40, 0.9), 3)

    def test_paisa_rounded_up_so_n_ads_make_the_answer(self):
        self.assertEqual(AM.paisa_per_ad(2), 50)
        self.assertEqual(AM.paisa_per_ad(3), 34)          # 3 x 34 >= 100
        for n in range(1, AM.MAX_ADS + 1):
            self.assertGreaterEqual(n * AM.paisa_per_ad(n), 100, n)

    def test_income_from_admob_rows(self):
        rows = [{"fmt": "rewarded", "currency": "USD", "paid_events": 60,
                 "revenue_micros": 60 * 2000}]                 # $0.002 an ad
        inc, n, src = AM.income_per_ad_bdt(rows, 125.0)
        self.assertEqual((round(inc, 3), n, src), (0.25, 60, "admob"))
        inc, n, src = AM.income_per_ad_bdt(rows[:0], 125.0)
        self.assertEqual((inc, src), (0.40, "default"))
        few = [dict(rows[0], paid_events=10)]
        self.assertEqual(AM.income_per_ad_bdt(few, 125.0)[2], "default")

    def test_ad_row_is_shorter_than_normal(self):
        n = {"model": "claude-haiku-5-5", "in_cap": 5000, "out_cap": 1500,
             "fallback_out_cap": 0}
        self.assertEqual(AM.ad_row(n)["out_cap"], AM.AD_OUT_CAP)
        self.assertEqual(AM.ad_row(dict(n, out_cap=600))["out_cap"], 600)
        self.assertEqual(AL.defaults()["ad_out_cap"], AM.AD_OUT_CAP)
        self.assertFalse(AL.defaults()["ad_dynamic"])          # fresh DB: today's rule
        self.assertTrue(BOOK.v2_settings_patch()["ai_levels"]["ad_dynamic"])
        self.assertTrue(BOOK.WELCOME_OFF_PATCH["ai_levels"]["ad_dynamic"])


# ------------------------------------------------------------------ 40 % CI check
class AdFundedNoLossCiTests(TestCase):
    """CI FAILS if ad-funded AI can run at a loss under the configured worst
    case. Runs on the live code config (pricing v2 + owner settings), with
    Gemini on AND off (Better on Haiku has the longest Continue)."""

    def _check(self):
        c = billing.cfg()
        worst = AMS.worst_bdt(c)
        self.assertGreater(worst, 0)
        # the dearest the formula can ever be asked for still fits the bound
        need = AM.ads_per_answer(None, AM.WORST_AD_INCOME_BDT, worst)
        self.assertLess(need, AM.MAX_ADS, "ad answers too long for the lowest ad income")
        incomes = [AM.WORST_AD_INCOME_BDT, 0.15, 0.25, AM.DEFAULT_AD_INCOME_BDT, 0.6, 1.0]
        for inc in incomes:
            for real in (None, 0.0, worst * 0.1, worst * 0.5, worst):
                n = AM.ads_per_answer(real, inc, worst)
                got = AM.ads_really_needed(n) * inc
                self.assertGreaterEqual(got + 1e-9, worst, (inc, real, n))     # never a loss
                self.assertGreaterEqual(got + 1e-9, (worst if real is None else real) * AM.SAFETY,
                                        (inc, real, n))                        # owner x 1.2
                self.assertGreaterEqual(n, AM.MIN_ADS)
        # what the app shows today (no AdMob data yet) is profitable
        n = ALS.ads_per_answer(c)
        self.assertGreaterEqual(AM.profit_pct(n, AM.DEFAULT_AD_INCOME_BDT, worst), 0.0)
        self.assertEqual(ALS.ad_paisa(c), AM.paisa_per_ad(n))
        return worst, n

    def test_code_config(self):
        v2_full()
        worst, n = self._check()
        self.assertEqual(n, 2)                         # ৳0.80 vs the longest answer

    def test_gemini_off_config(self):
        v2_on({k: v for k, v in BOOK.v2_settings_patch(gemini_off=True).items()
               if k != "pricing_v2"})
        self._check()

    def test_49_taka_15_credit_pack_keeps_40_percent(self):
        rows = BOOK.worst_case_rows({"plans": {}, "topup_packs": [
            {"id": "c15", "price": 49, "credits": 15}]})
        self.assertEqual(len(rows), 1)
        self.assertGreaterEqual(rows[0]["profit_pct"], 40.0, rows)
        self.assertGreaterEqual(49 / 15, BOOK.MIN_BDT_PER_CREDIT)
        # once adcontrol adds it to plan_book, its formula number passes too
        for p in BOOK.V2_PACKS:
            if int(p["price"]) == 49:
                n = BOOK.credits_for_price(49)
                r = BOOK.worst_case_rows({"plans": {}, "topup_packs": [dict(p, credits=n)]})
                self.assertGreaterEqual(r[0]["profit_pct"], 40.0, r)

    def test_a_longer_ad_answer_raises_n_not_the_loss(self):
        v2_full()
        row = billing.get_config()
        d = dict(row.data)
        d["ai_levels"] = dict(d["ai_levels"], ad_out_cap=4000)
        row.data = d
        row.save()
        worst, n = self._check()
        self.assertGreaterEqual(AM.ads_really_needed(n) * AM.DEFAULT_AD_INCOME_BDT, worst)


# ------------------------------------------------------------------ welcome off
class WelcomeOffTests(TestCase):
    def test_code_default_and_v2_patch_give_no_welcome(self):
        self.assertFalse(AL.defaults()["welcome_on"])
        self.assertFalse(BOOK.v2_settings_patch()["ai_levels"]["welcome_on"])
        v2_full()
        u = _user()
        self.assertEqual(ALS.grant_welcome(u, "dev-1"), (0, "off"))

    def test_command_dry_run_apply_idempotent_balances_stay(self):
        v2_on({"ai_levels": dict(BOOK.v2_settings_patch()["ai_levels"], welcome_on=True)})
        u = _user()
        CR.grant(u, CR.FREE, 30, reason="trial", note="ai_welcome",
                 source_type="ai_welcome", source_id="ai_welcome")
        u.refresh_from_db()
        bal = u.ai_credits
        out = StringIO()
        call_command("pricing_welcome_off", "--dry-run", stdout=out)
        self.assertIn("ai_levels.welcome_on: True -> False", out.getvalue())
        self.assertIn("Dry run", out.getvalue())
        self.assertTrue(billing.cfg()["ai_levels"]["welcome_on"])
        n0 = len(billing.get_config().audit or [])
        out = StringIO()
        call_command("pricing_welcome_off", "--apply", stdout=out)
        self.assertIn("APPLIED", out.getvalue())
        self.assertFalse(billing.cfg()["ai_levels"]["welcome_on"])
        self.assertEqual(len(billing.get_config().audit or []), n0 + 1)
        out = StringIO()
        call_command("pricing_welcome_off", "--apply", stdout=out)
        self.assertIn("Already applied", out.getvalue())
        self.assertEqual(len(billing.get_config().audit or []), n0 + 1)
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, bal)                       # existing balances stay


# ------------------------------------------------------------------ daily number
class DailyNumberTests(TestCase):
    def setUp(self):
        v2_full()

    def test_no_data_uses_worst_case_and_040(self):
        row = AMS.recompute()
        self.assertEqual(row.ads_per_answer, 2)
        self.assertEqual(row.data["income_source"], "default")
        self.assertEqual(row.data["cost_source"], "worst_case")
        self.assertEqual(ALS.ads_per_answer(), 2)
        self.assertEqual(ALS.ad_paisa(), 50)

    def test_real_cost_and_admob_income_raise_n(self):
        u = _user()
        for _ in range(AM.MIN_COST_SAMPLES):
            AIUsage.objects.create(user=u, feature="chat.normal", model="claude-haiku-5-5",
                                   cost_usd=0.004, ok=True, level="normal",
                                   attempts="anthropic:ok|adfund")   # ৳0.50 each
        AdPlacementStat.objects.create(date=timezone.localdate(), placement="chat",
                                       fmt="rewarded", currency="USD", paid_events=100,
                                       revenue_micros=100 * 1600)   # $0.0016 an ad
        inc = 0.0016 * float(billing.cfg()["usd_bdt"])                  # ~৳0.19
        n, data = AMS.compute()
        self.assertEqual(data["cost_source"], "ad_answers")
        self.assertAlmostEqual(data["real_cost_bdt"], 0.50, places=2)
        self.assertEqual(data["income_source"], "admob")
        self.assertAlmostEqual(data["income_bdt"], inc, places=3)
        # ceil(0.50 x 1.2 / ~0.19) = 4; the longest answer never needs more here
        self.assertEqual(n, AM.ads_per_answer(data["real_cost_bdt"], data["income_bdt"],
                                              data["worst_bdt"]))
        self.assertGreaterEqual(n, 3)
        AMS.recompute()
        self.assertEqual(ALS.ads_per_answer(), n)
        self.assertEqual(ALS.ad_paisa(), AM.paisa_per_ad(n))
        st = billing.ad_wallet_state(u)
        self.assertEqual(st["ads_per_answer"], n)
        self.assertEqual(ALS.app_payload(u)["ads_per_answer"], n)

    def test_tick_once_a_day_inside_minute_jobs(self):
        from core import ops_health as H
        self.assertIn("ad_money_tick", H.MINUTE_JOB_NAMES)
        self.assertEqual(H.MINUTE_JOB_NAMES[-1], "agent_core_run")
        call_command("ad_money_tick", "--quiet", stdout=StringIO())
        self.assertEqual(AdMoneyDay.objects.count(), 1)
        self.assertIsNone(AMS.tick())                      # already done today
        later = timezone.now() + timedelta(days=1)
        self.assertIsNotNone(AMS.tick(later))
        self.assertEqual(AdMoneyDay.objects.count(), 2)

    def test_static_when_dynamic_off(self):
        row = billing.get_config()
        d = dict(row.data)
        d["ai_levels"] = dict(d["ai_levels"], ad_dynamic=False, ads_per_answer=4)
        row.data = d
        row.save()
        self.assertEqual(ALS.ads_per_answer(), 4)
        self.assertEqual(ALS.ad_paisa(), 25)


# ------------------------------------------------------------------ ad-funded answer
class AdFundedAnswerTests(TestCase):
    def setUp(self):
        v2_full()
        self.u = _user()

    def _ask(self, level):
        seen = []

        def ant(k, m, system, prompt, max_tokens, history=None):
            seen.append({"model": m, "max": max_tokens, "cache": ai._opts().get("cache"),
                         "web": ai._opts().get("web")})
            return ("A full answer.", 10, 5)
        with mock.patch.object(ai, "_providers", return_value=[("anthropic", "a")]), \
                mock.patch.object(ai, "_call_anthropic", side_effect=ant):
            meta = {}
            ai.generate("q", user=self.u, feature="chat." + level, level=level, web=True,
                        out_meta=meta)
        return seen, meta

    def test_rewarded_credits_run_normal_short_cached_no_web(self):
        CR.grant(self.u, CR.REWARDED, 3, reason="rewarded", note="ad", source_type="ad",
                 source_id="ad:rewarded")
        self.u.refresh_from_db()
        self.assertTrue(AMS.ad_funded(self.u, 1))
        seen, meta = self._ask("better")
        self.assertEqual(seen[0]["model"], "claude-haiku-5-5")
        self.assertEqual(seen[0]["max"], AM.AD_OUT_CAP)
        self.assertTrue(seen[0]["cache"])                  # prompt caching on
        self.assertFalse(seen[0]["web"])
        self.assertTrue(meta.get("ad_funded"))
        row = AIUsage.objects.filter(ok=True).latest("id")
        self.assertIn(AMS.AD_TAG, row.attempts)

    def test_bought_credits_keep_the_full_answer(self):
        CR.grant(self.u, CR.PACK, 3, reason="topup", source_type="test", source_id="p",
                 key="p-am")
        self.u.refresh_from_db()
        self.assertFalse(AMS.ad_funded(self.u, 1))
        seen, meta = self._ask("normal")
        self.assertEqual(seen[0]["max"], ALS.spec("normal")["out_cap"])
        self.assertFalse(meta.get("ad_funded"))

    def test_system_prompt_carries_cache_control(self):
        body = ai.anthropic_request("claude-haiku-5-5", "SYSTEM", [{"role": "user", "content": "q"}],
                                    900, "low", hard_cap=True, cache=True)
        self.assertEqual(body["system"][0]["cache_control"], {"type": "ephemeral"})


# ------------------------------------------------------------------ dashboard
class MoneyTableTests(TestCase):
    def test_rows_free_pnl_per_answer_ads_and_credits_sold(self):
        v2_full()
        u = _user()
        AIUsage.objects.create(user=u, feature="chat.normal", model="claude-haiku-5-5",
                               cost_usd=0.002, ok=True, level="normal")
        AdPlacementStat.objects.create(date=timezone.localdate(), placement="home",
                                       fmt="native", currency="BDT", paid_events=10,
                                       revenue_micros=3_000_000)
        CR.grant(u, CR.PACK, 15, reason="topup", source_type="test", source_id="c15",
                 key="c15-am")
        t = AMS.money_table(days=3)
        self.assertEqual(len(t["rows"]), 3)
        r = t["rows"][0]
        self.assertEqual(r["date"], timezone.localdate())
        self.assertEqual(r["ad_by_fmt"]["native"], 3.0)
        self.assertAlmostEqual(r["free_ai_bdt"], 0.25, places=2)
        self.assertAlmostEqual(r["free_pnl"], 2.75, places=2)
        self.assertAlmostEqual(r["per_answer"]["normal"], 0.25, places=2)
        self.assertEqual(r["packs"], 15)
        self.assertEqual(t["ads_per_answer"], 2)
