"""pricing-40 (owner decision 27 Oct, "STRONG AI WITH PROFIT"):

  * the pure calculator: the 24 % AI budget, the owner's proposal FAILS the
    40 % rule, the final proposal PASSES at ৳120 and ৳125 (annual 10x
    credits), annual 12x fails, the agent cap sits under the boundary;
  * the input fitter never exceeds its cap; the credit_model block is OFF by
    default and bounded;
  * merging changes nothing live: with credit_model disabled a chat `mode` is
    ignored (same model, same credits);
  * the preset (dry run saves nothing; --apply needs --backup-done; applied
    -> modes charge their credits, quick is free up to the daily quota, Sonnet
    runs with thinking off and a hard output cap, annual = 10x credits);
  * the daily cost-per-credit alert: safe level, once per day per breach,
    owner-only, banner, editable bounded thresholds, never fires on free calls;
  * ai_token_audit refuses tests/CI unless --offline.
No real AI call is made anywhere (providers mocked at the call seam)."""
import io
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import ai, ai_cost_alert as A, billing, credits as CR
from core.logic import billing_cfg, pricing as P, pricing_40 as P40
from core.models import AIUsage, FamilyAlert, User

ALL = [("anthropic", "ka")]


# ================================================================== pure
class V2CalculatorTests(SimpleTestCase):
    """Owner final structure (27 Oct night)."""

    def test_every_plan_pack_and_annual_keeps_40pct_at_120_and_125(self):
        for rate in (120.0, 125.0):
            for annual in (False, True):
                bad = [(r["id"], r["margin_pct"]) for r in P40.v2_rows(rate, annual) if not r["ok"]]
                self.assertEqual(bad, [], (rate, annual))

    def test_guaranteed_counts(self):
        cr = P40.v2_plan_credits()
        self.assertEqual(cr, {"plus": 70, "premium": 150, "premium_pro": 380, "business": 480})
        self.assertEqual(P40.v2_messages("premium", cr["premium"])["smart"], 75)
        self.assertEqual(P40.v2_messages("premium_pro", cr["premium_pro"])["opus"], 76)

    def test_owner_targets_need_these_prices(self):
        # 200 smart messages on Premium / 165 Opus on Pro, guaranteed
        ai = P40.v2_worst_ai_usd("premium", 400) * P40.STRICT_RATE
        self.assertGreater(ai / 0.24, 449)

    def test_agent_cap_never_above_limit_and_fits_a_typical_task(self):
        for rate in (120.0, 125.0):
            self.assertLessEqual(P40.v2_agent_cap_usd(rate), P40.v2_agent_cap_limit_usd(rate))
        self.assertLess(P40.agent_cost_usd(4), P40.v2_agent_cap_usd())

    def test_preset_passes_legacy_net_floor(self):
        merged = P.normalize({**P40.PRESETS["pricing_27oct"]})
        for aid in P40.PRESETS["pricing_27oct"]["action_costs"]:
            self.assertGreaterEqual(merged["action_costs"][aid]["credits"],
                                    P.action_credit_floor(aid, merged), aid)

    def test_hard_question_rules(self):
        H = P40.is_hard_question
        self.assertFalse(H("হ্যালো, কেমন আছো?"))
        self.assertFalse(H("মাকে জন্মদিনের শুভেচ্ছা লিখে দাও"))
        self.assertTrue(H("আমার ব্যবসার পরিকল্পনা ধাপে ধাপে বানিয়ে দাও"))
        self.assertTrue(H("Compare these two loans for me"))
        self.assertTrue(H("৩৫০০০ আয়, ১২০০০ ভাড়া, ৯০০০ খাবার, ৫০০০ সঞ্চয় — কত থাকে"))
        self.assertTrue(H("ক" * 400))
        self.assertTrue(H("এটা কী? আর ওটা কী?"))

    def test_plan_text_never_names_a_model(self):
        cfg = P.normalize(P40.PRESETS["pricing_27oct"])
        for pid in ("plus", "premium", "premium_pro", "business"):
            for bn in (True, False):
                line = P40.plan_message_line(pid, cfg["plans"][pid]["credits"], cfg, bn)
                self.assertTrue(line)
                for name in ("opus", "sonnet", "haiku", "claude", "anthropic"):
                    self.assertNotIn(name, line.lower())
        self.assertIsNone(P40.plan_message_line("premium", 150, P.normalize({}), True))

    def test_plan_modes(self):
        cm = P40.normalize_credit_model(P40.PRESETS["pricing_27oct"]["credit_model"])
        self.assertEqual(P40.plan_modes(cm, "premium_pro")[0], "pro")
        self.assertNotIn("pro", P40.plan_modes(cm, "premium"))
        self.assertEqual(P40.upgrades_allowed(cm, "premium"), 10)
        self.assertEqual(P40.upgrades_allowed(cm, "plus"), 0)


class CalculatorTests(SimpleTestCase):
    def test_budget_interpretations(self):
        self.assertAlmostEqual(P40.ai_budget_pct(), 0.24)
        self.assertAlmostEqual(P40.ai_budget_pct(base="net"), 0.344)

    def _costs(self, rate, ax):
        capped = {"smart": P40.mode_cap_cost_usd("smart"), "pro": P40.mode_cap_cost_usd("pro"),
                  "agent": P40.final_agent_cap_usd(ax, rate)}
        return capped.get

    def test_final_proposal_passes_everywhere_at_120_and_125(self):
        q = P40.mode_cap_cost_usd("quick")
        for rate in (120.0, 125.0):
            rows = P40.table(P40.FINAL_PROPOSAL, self._costs(rate, 10), q, 10, rate)
            bad = [(r["id"], r["margin_pct"]) for r in rows if not r["ok"]]
            self.assertEqual(bad, [], rate)

    def test_preset_agent_cap_holds_at_both_rates(self):
        cap = P40.PRESETS["pricing_27oct"]["credit_model"]["agent_cap_usd"]
        self.assertLessEqual(cap, P40.final_agent_cap_usd(10, 125.0))
        self.assertLessEqual(cap, P40.final_agent_cap_usd(10, 120.0))
        # a typical 4-step Opus task fits under it
        self.assertLess(P40.agent_cost_usd(4), cap)

    def test_annual_12x_credits_breaks_the_rule(self):
        q = P40.mode_cap_cost_usd("quick")
        rows = {r["id"]: r for r in P40.table(P40.FINAL_PROPOSAL, self._costs(120.0, 12), q, 12)}
        self.assertFalse(rows["premium_annual"]["ok"])

    def test_owner_proposal_fails_on_todays_code(self):
        sc = P40.today_chat_scenarios()["typical"]
        cost = {"smart": P40.call_cost_usd(P40.SONNET, sc["in"], sc["out"]),
                "pro": P40.call_cost_usd(P40.OPUS, sc["in"], sc["out"]),
                "agent": P40.agent_cost_usd(4)}
        rows = P40.table(P40.OWNER_PROPOSAL, cost.get, 0.0005, 12)
        self.assertTrue(all(not r["ok"] for r in rows))

    def test_agent_step_guard(self):
        self.assertTrue(P40.agent_step_allowed(0.0, 3000, 0, 900, 0.119))
        self.assertFalse(P40.agent_step_allowed(0.11, 3000, 0, 900, 0.119))

    def test_fit_input_never_exceeds_cap(self):
        hist = [{"role": "user", "content": "ক" * 500},
                {"role": "assistant", "content": "খ" * 400}] * 10
        for cap in (1500, 2000, 2400):
            prompt, h = P40.fit_input("s" * 1125, "ক" * 6000, hist, cap, 8)
            total = P40.est_tokens("s" * 1125) + P40.est_tokens(prompt) + sum(
                P40.est_tokens(x["content"]) for x in h)
            self.assertLessEqual(total, cap)
            self.assertTrue(not h or h[0]["role"] == "user")

    def test_fit_keeps_newest_history(self):
        hist = [{"role": "user", "content": "old"}, {"role": "assistant", "content": "a1"},
                {"role": "user", "content": "new"}, {"role": "assistant", "content": "a2"}]
        _, h = P40.fit_input("s", "p", hist, 2000, 2)
        self.assertEqual([x["content"] for x in h], ["new", "a2"])

    def test_credit_model_default_off_and_bounded(self):
        d = P.normalize({})["credit_model"]
        self.assertFalse(d["enabled"])
        self.assertEqual(d["annual_credit_months"], 12)
        cm = P40.normalize_credit_model({"enabled": "yes", "annual_credit_months": 40,
                                         "modes": {"smart": {"in_cap": 10**6, "out_cap": -5}},
                                         "default_chat_mode": "opus", "agent_cap_usd": True})
        self.assertFalse(cm["enabled"])                       # only a real True enables
        self.assertEqual(cm["annual_credit_months"], 12)
        self.assertEqual(cm["modes"]["smart"], {"in_cap": 8000, "out_cap": 100, "history_turns": 6})
        self.assertEqual(cm["default_chat_mode"], "smart")
        self.assertEqual(cm["agent_cap_usd"], 0.115)

    def test_safe_level_from_config(self):
        cfg = P.normalize({"plans": {"premium": {"price": 449, "credits": 150, "annual_price": 4490}},
                           "topup_packs": [{"id": "c300", "price": 949, "credits": 300}],
                           "credit_model": {"enabled": True, "annual_credit_months": 10}})
        rows = dict(P40.bdt_per_credit_rows(cfg))
        self.assertAlmostEqual(rows["premium"], 449 / 150)
        self.assertAlmostEqual(rows["premium_annual"], 4490 / 1500)
        self.assertLessEqual(P40.safe_bdt_per_credit(cfg), round(449 / 150 * 0.24, 4))

    def test_anthropic_request_modes(self):
        b = ai.anthropic_request("claude-sonnet-5-5", "s", [], 450, "low", thinking="off",
                                 hard_cap=True)
        self.assertEqual((b["thinking"], b["max_tokens"]), ({"type": "between_tools"}, 450))
        b = ai.anthropic_request("claude-haiku-5-5", "s", [], 300, "low", thinking="off",
                                 hard_cap=True)
        self.assertEqual(b["thinking"], {"type": "disabled"})
        b = ai.anthropic_request("claude-opus-5-5", "s", [], 750, "low", thinking="off",
                                 hard_cap=True)
        self.assertEqual((b["thinking"], b["max_tokens"]), ({"type": "adaptive"}, 750))
        b = ai.anthropic_request("claude-sonnet-5-5", "sys", [
            {"role": "user", "content": "a"}, {"role": "assistant", "content": "b"},
            {"role": "user", "content": "c"}], 400, "low", thinking="off", hard_cap=True,
            cache=True)
        self.assertEqual(b["system"][0]["cache_control"], {"type": "ephemeral"})
        self.assertEqual(b["messages"][1]["content"][0]["cache_control"], {"type": "ephemeral"})
        self.assertEqual(b["messages"][2]["content"], "c")           # newest never marked
        # unchanged default: adaptive + thinking headroom
        b = ai.anthropic_request("claude-opus-5-5", "s", [], 700, "low")
        self.assertEqual((b["thinking"], b["max_tokens"]), ({"type": "adaptive"}, 1724))

    def test_billing_knobs_bounded(self):
        k = billing_cfg.normalize({"cost_alert_budget_pct": 99, "cost_alert_min_credits": -1,
                                   "cost_alert_safe_paisa": 5000, "cost_alert_enabled": "0"})
        self.assertEqual((k["cost_alert_budget_pct"], k["cost_alert_min_credits"],
                          k["cost_alert_safe_paisa"], k["cost_alert_enabled"]), (40, 0, 1000, False))
        self.assertTrue(billing_cfg.defaults()["cost_alert_enabled"])
        self.assertIn("bad_billing", billing_cfg.problems({"cost_alert_budget_pct": 5}))


# ================================================================== django
class Base(TestCase):
    def setUp(self):
        cache.clear()
        from core.payments import play_verify
        play_verify._clear()
        mock.patch("core.ai._providers", return_value=list(ALL)).start()
        self.notify = mock.patch("core.push.notify_owner", return_value={}).start()
        self.addCleanup(mock.patch.stopall)
        self.calls = []

        def fake(key, model, system, prompt, max_tokens, history=None):
            self.calls.append({"model": model, "max_tokens": max_tokens,
                               "opts": dict(ai._opts()), "prompt": prompt,
                               "history": list(history or [])})
            return "উত্তর", 1000, 300
        mock.patch("core.ai._call_anthropic", side_effect=fake).start()
        self.u = User.objects.create_user(phone="+8801711400001", password="x")
        CR.grant(self.u, CR.PACK, 100, note="test", key="t40:%d" % self.u.pk)
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def apply_preset(self):
        out = io.StringIO()
        call_command("apply_pricing_preset", "pricing_27oct", "--apply", "--backup-done",
                     stdout=out)
        return out.getvalue()

    def send(self, text="হ্যালো", **extra):
        sid = self.c.post("/api/v1/chat/sessions", {}, format="json").json()["id"]
        return self.c.post("/api/v1/chat/sessions/%s/send" % sid, {"text": text, **extra},
                           format="json")

    def balance(self):
        self.u.refresh_from_db()
        return self.u.ai_credits


class MergeChangesNothingTests(Base):
    def test_mode_ignored_while_disabled(self):
        before = self.balance()
        r = self.send(mode="pro")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.calls[0]["model"], "claude-opus-5-5")   # today's chat model
        self.assertEqual(self.calls[0]["max_tokens"], 700)
        self.assertNotIn("hard_cap", self.calls[0]["opts"])
        self.assertEqual(before - self.balance(), P.credit_cost("ai_msg_cheap", billing.cfg()))
        self.assertEqual(AIUsage.objects.get().feature, "chat")

    def test_preset_dry_run_saves_nothing(self):
        before = billing.cfg()
        out = io.StringIO()
        call_command("apply_pricing_preset", "pricing_27oct", stdout=out)
        self.assertIn("Dry run", out.getvalue())
        self.assertIn("plans.premium.price: 199 -> 449", out.getvalue())
        self.assertEqual(billing.cfg(), before)

    def test_apply_needs_backup_flag(self):
        with self.assertRaises(CommandError):
            call_command("apply_pricing_preset", "pricing_27oct", "--apply", stdout=io.StringIO())
        self.assertFalse(billing.cfg()["credit_model"]["enabled"])
        with self.assertRaises(CommandError):
            call_command("apply_pricing_preset", "nope", stdout=io.StringIO())


class PresetAppliedTests(Base):
    def setUp(self):
        super().setUp()
        self.assertIn("APPLIED", self.apply_preset())

    def set_plan(self, plan):
        self.u.plan = plan
        self.u.plan_until = timezone.now() + timedelta(days=30)
        self.u.save()
        billing.ensure_monthly_pool(self.u)        # the plan month lands first
        self.balance()

    def test_config_after_apply(self):
        c = billing.cfg()
        got = {p: (c["plans"][p]["price"], c["plans"][p]["credits"])
               for p in ("plus", "premium", "premium_pro", "business")}
        self.assertEqual(got, {"plus": (199, 70), "premium": (449, 150),
                               "premium_pro": (999, 380), "business": (1299, 480)})
        self.assertEqual([p["id"] for p in c["topup_packs"]], ["c50", "c120", "c300"])
        self.assertEqual({a: c["action_costs"][a]["credits"] for a in
                          ("ai_chat_smart", "ai_chat_pro", "ai_agent_task")},
                         {"ai_chat_smart": 2, "ai_chat_pro": 5, "ai_agent_task": 25})
        self.assertTrue(c["credit_model"]["enabled"])
        cheapest = min(v for _, v in P40.bdt_per_credit_rows(c))
        self.assertAlmostEqual(A.safe_level(c), round(cheapest * 0.24, 4))

    def verify_all(self):
        from core.payments import play_verify

        def api(method, path):
            if path.startswith("subscriptions/"):
                return {"basePlans": [{"basePlanId": "monthly", "state": "ACTIVE"},
                                      {"basePlanId": "annual", "state": "ACTIVE"}]}
            return {"status": "active"}
        return play_verify.check_all(api=api)

    def test_new_products_not_sold_until_play_verifies_them(self):
        from core import plans
        from core.payments import catalog, play_verify
        skus = catalog.all_skus()
        for sku in ("plus_monthly", "plus_yearly", "premium_pro_monthly", "premium_pro_yearly",
                    "pack_c50", "pack_c300"):
            self.assertIn(sku, skus)                       # configured …
            self.assertIsNone(catalog.price(sku, "play"))   # … but NOT for sale
            self.assertIsNone(catalog.price(sku, "gateway"))
        self.assertEqual(catalog.price("premium_monthly", "play"), 449)   # existing: not gated
        self.assertNotIn("premium_pro", [p["id"] for p in plans.plans_public("bn")])
        self.assertEqual(catalog.base_price("premium_pro_yearly"), 9990)
        self.assertEqual(catalog.play_product("premium_pro_monthly"),
                         ("assisto_premium_pro", "monthly"))
        # Play says the Pro monthly base plan is still a DRAFT -> stays off sale
        out = play_verify.check_all(api=lambda m, p: (
            {"basePlans": [{"basePlanId": "monthly", "state": "DRAFT"}]}
            if p.startswith("subscriptions/") else {"status": "inactive"}))
        self.assertEqual(out["verified"], 0)
        self.assertIsNone(catalog.price("premium_pro_monthly", "play"))
        out = self.verify_all()
        self.assertEqual(out["verified"], out["checked"])
        self.assertEqual(catalog.price("premium_pro_monthly", "play"), 999)
        self.assertEqual(catalog.price("pack_c300", "play"), 949)
        self.assertIn("premium_pro", [p["id"] for p in plans.plans_public("bn")])

    def test_not_configured_play_verifies_nothing(self):
        from core.payments import play_verify
        out = play_verify.check_all()
        self.assertEqual(out["verified"], 0)
        self.assertTrue(all(r["state"] == "NOT_CONFIGURED" for r in out["rows"]))

    def test_owner_admin_status_rows(self):
        from core.payments import play_verify
        rows = play_verify.status_rows()
        self.assertIn("premium_pro_monthly", [r["sku"] for r in rows])
        self.assertIn("pack_c50", [r["sku"] for r in rows])
        self.assertNotIn("premium_monthly", [r["sku"] for r in rows])   # existing: not gated
        self.assertTrue(all(not r["ok"] for r in rows))

    def test_existing_subscriber_sees_their_own_price(self):
        from core import plans
        from core.models import PaidOrder
        with mock.patch("core.payments.play.active_sub_skus", return_value={"premium_monthly"}):
            PaidOrder.objects.create(channel="play", order_id="GPA.1", user=self.u,
                                     sku="premium_monthly", kind="sub", plan="premium",
                                     months=1, price=199, purchased_at=timezone.now())
            rows = {r["id"]: r for r in plans.mark_your_price(self.u, plans.plans_public("en"))}
        self.assertEqual(rows["premium"]["your_price"], 199.0)
        self.assertEqual(rows["premium"]["price"], 449)          # new buyers
        self.assertNotIn("your_price", rows["business"])

    def test_smart_default_two_credits_sonnet_thinking_off_cached(self):
        before = self.balance()
        r = self.send()
        self.assertEqual(r.status_code, 200)
        call = self.calls[0]
        self.assertEqual(call["model"], "claude-sonnet-5-5")
        self.assertEqual(call["max_tokens"], 400)
        self.assertEqual((call["opts"]["thinking"], call["opts"]["hard_cap"], call["opts"]["cache"]),
                         ("off", True, True))
        self.assertEqual(before - self.balance(), 2)
        u = AIUsage.objects.get()
        self.assertEqual((u.feature, u.credits_charged), ("chat.smart", 2))
        self.assertEqual(r.json()["message"]["meta"]["credits"], 2)

    def test_pro_only_on_premium_pro(self):
        before = self.balance()
        self.send(mode="pro")                       # free user: not allowed -> smart
        self.assertEqual(self.calls[-1]["model"], "claude-sonnet-5-5")
        free_spent = before - self.balance()
        self.set_plan("premium_pro")
        mid = self.balance()
        self.send()                                 # Pro plan default = pro
        self.assertEqual(self.calls[-1]["model"], "claude-opus-5-5")
        self.assertEqual(self.calls[-1]["max_tokens"], 700)
        self.assertEqual((free_spent, mid - self.balance()), (2, 5))

    def test_premium_hard_question_auto_upgrade_capped(self):
        self.set_plan("premium")
        CR.grant(self.u, CR.PACK, 100, note="more", key="t40b:%d" % self.u.pk)
        before = self.balance()
        hard = "আমার ব্যবসার পরিকল্পনা ধাপে ধাপে বানিয়ে দাও"
        self.send(text=hard)
        self.assertEqual(self.calls[-1]["model"], "claude-opus-5-5")
        self.assertEqual(before - self.balance(), 2)              # charged as smart
        self.assertEqual(AIUsage.objects.filter(feature="chat.upgrade").count(), 1)
        self.send(text="হ্যালো")
        self.assertEqual(self.calls[-1]["model"], "claude-sonnet-5-5")
        for _ in range(9):
            self.send(text=hard)
        self.send(text=hard)                                       # 11th: cap reached
        self.assertEqual(self.calls[-1]["model"], "claude-sonnet-5-5")
        self.assertEqual(AIUsage.objects.filter(feature="chat.upgrade").count(), 10)

    def test_quick_free_up_to_daily_quota_then_one_credit(self):
        before = self.balance()
        for _ in range(10):
            self.send(mode="quick")
        self.assertEqual(self.balance(), before)
        self.assertTrue(all(c["model"] == "claude-haiku-5-5" for c in self.calls))
        self.assertTrue(all(c["max_tokens"] == 300 for c in self.calls))
        self.send(mode="quick")
        self.assertEqual(before - self.balance(), 1)
        self.assertEqual(AIUsage.objects.filter(credits_charged=0).count(), 10)

    def test_long_paste_is_capped(self):
        self.send(text="ক" * 50000)
        self.assertLessEqual(P40.est_tokens(self.calls[0]["prompt"]), 1800)

    def test_l4_needs_key_text_not_sent_as_data(self):
        self.send(text="আজ আবহাওয়া কেমন হবে?")
        self.assertNotIn("key", self.calls[0]["prompt"].lower())

    def test_annual_grants_ten_twelfths(self):
        self.assertEqual(CR.plan_credits("premium", months=12), 125)
        self.assertEqual(CR.plan_credits("premium", months=1), 150)
        self.assertEqual(CR.plan_credits("business", months=12), 400)

    def test_plan_texts_show_message_counts(self):
        from core import plans
        self.verify_all()
        rows = {p["id"]: p for p in plans.plans_public("bn")}
        self.assertIn("৭৬টি প্রো মেসেজ", rows["premium_pro"]["benefits"][0])
        self.assertIn("১০টি পর্যন্ত প্রো", rows["premium"]["benefits"][0])
        self.assertIn("দিনে ১০টি ফ্রি দ্রুত উত্তর", rows["premium"]["benefits"][0])
        self.assertIn("৭৫টি স্মার্ট মেসেজ", rows["premium"]["benefits"][0])
        self.assertIn("বছরে ৭৫০টি স্মার্ট মেসেজ", rows["annual"]["benefits"][0])
        self.assertEqual(rows["annual"]["credits"], 125)
        self.assertIn("প্রো মেসেজ", rows["premium_pro"]["benefits"][0])
        blob = repr(rows).lower()
        for name in ("opus", "sonnet", "haiku", "claude"):
            self.assertNotIn(name, blob)


class MonthlyUsageTests(Base):
    def setUp(self):
        super().setUp()
        self.owner = User.objects.create_user(phone="+8801711400003", password="x")
        self.owner.is_superuser = True
        self.owner.save()

    def test_report_suggests_more_when_real_cost_is_low(self):
        AIUsage.objects.bulk_create([AIUsage(user=self.u, feature="chat.smart", model="claude-sonnet-5-5",
                                             input_tokens=300, cache_read_tokens=900, output_tokens=250,
                                             cost_usd=0.003, credits_charged=2) for _ in range(250)])
        out = A.monthly_report()
        self.assertTrue(out["sent"])
        sug = out["report"]["suggested_credits"]
        self.assertGreater(sug["premium"], 150)
        self.assertIn("বেশি মেসেজ", out["body"])
        self.assertFalse(A.monthly_report()["sent"])               # once a month

    def test_report_without_data_is_honest(self):
        out = A.monthly_report(notify=False)
        self.assertEqual(out["report"]["suggested_credits"], {})
        self.assertIn("নেই", out["body"])


class CostAlertTests(Base):
    def setUp(self):
        super().setUp()
        self.owner = User.objects.create_user(phone="+8801711400002", password="x")
        self.owner.is_superuser = True
        self.owner.is_staff = True
        self.owner.save()

    def usage(self, usd, credits, model="claude-opus-5-5", **kw):
        return AIUsage.objects.create(user=self.u, feature="chat", model=model, cost_usd=usd,
                                      credits_charged=credits, tier="cheap", **kw)

    def test_safe_level_default_config(self):
        c = billing.cfg()
        cheapest = min(v for _, v in P40.bdt_per_credit_rows(c))
        self.assertAlmostEqual(A.safe_level(c), round(cheapest * 0.24, 4))

    def test_owner_override(self):
        cfg = billing.cfg()
        cfg["billing"]["cost_alert_safe_paisa"] = 55
        self.assertEqual(A.safe_level(cfg), 0.55)

    def test_breach_alerts_owner_once_per_day(self):
        # 200 credits, ৳1.20 per credit (> any safe level)
        for _ in range(4):
            self.usage(0.5, 50)
        r1 = A.check()
        self.assertGreaterEqual(r1["breaches"], 1)
        self.assertEqual(r1["sent"], r1["breaches"])
        self.assertEqual(self.notify.call_count, r1["sent"])
        self.assertTrue(FamilyAlert.objects.filter(user=self.owner, kind=A.KIND).exists())
        self.assertFalse(FamilyAlert.objects.filter(user=self.u, kind=A.KIND).exists())
        r2 = A.check()                                  # same day: no second push
        self.assertEqual(r2["sent"], 0)
        self.assertEqual(self.notify.call_count, r1["sent"])
        keys = [b["key"] for b in A.banner()]
        self.assertIn("1d:all", keys)

    def test_below_min_credits_or_free_calls_never_alert(self):
        self.usage(0.5, 10)                              # 10 credits < min 100
        for _ in range(50):
            self.usage(0.05, 0, model="claude-haiku-5-5")   # free quota calls
        r = A.check()
        self.assertEqual((r["breaches"], r["sent"]), (0, 0))
        rep = A.compute(1)
        self.assertEqual(rep["free_calls"], 50)
        self.assertEqual(rep["credits"], 10)

    def test_healthy_cost_no_alert(self):
        for _ in range(4):
            self.usage(0.0001, 50)
        self.assertEqual(A.check()["breaches"], 0)

    def test_disabled_knob(self):
        cfg = billing.cfg()
        cfg["billing"]["cost_alert_enabled"] = False
        for _ in range(4):
            self.usage(0.5, 50)
        self.assertEqual(A.check(cfg=cfg)["sent"], 0)

    def test_old_window_ignored(self):
        u = self.usage(0.5, 500)
        AIUsage.objects.filter(pk=u.pk).update(created_at=timezone.now() - timedelta(days=9))
        self.assertEqual(A.check()["breaches"], 0)

    def test_billing_daily_runs_the_step(self):
        out = io.StringIO()
        with mock.patch("core.payments.reconcile.reconcile", return_value={}), \
                mock.patch("core.payments.refunds.voided_poll", return_value={}), \
                mock.patch("core.payments.reconcile.credits_verify", return_value={}), \
                mock.patch("core.payments.reconcile.profit_guard_users", return_value={}):
            call_command("billing_daily", stdout=out)
        self.assertIn("ai_cost_per_credit", out.getvalue())

    def test_banner_after_breach(self):
        for _ in range(4):
            self.usage(0.5, 50)
        A.check()
        self.assertTrue(A.banner())


class TokenAuditTests(TestCase):
    def test_refuses_in_tests_without_offline(self):
        with self.assertRaises(CommandError):
            call_command("ai_token_audit", stdout=io.StringIO())

    def test_offline_prints_every_path(self):
        out = io.StringIO()
        call_command("ai_token_audit", "--offline", stdout=out)
        s = out.getvalue()
        for name in ("chat_bn_first_turn", "chat_bn_full_window", "mode_smart_full_window_capped",
                     "eval_prompt_10"):
            self.assertIn(name, s)

    def test_capped_paths_fit(self):
        from core.management.commands.ai_token_audit import build_paths, offline_estimate
        caps = {"mode_quick_full_window_capped": 1500, "mode_smart_full_window_capped": 2000,
                "mode_pro_full_window_capped": 2400}
        for name, system, msgs in build_paths():
            if name in caps:
                self.assertLessEqual(offline_estimate(system, msgs), caps[name] + 4 * len(msgs))
