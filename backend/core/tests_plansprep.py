"""plansprep (owner pricing decisions 9 Nov 10:20): the one source of plan
numbers, the 40 % worst-case CI check over every plan / pack / level, the
pricing_v2 switch (default OFF = nothing changes), the apply command, and
every Google Play lifecycle case with fakes (buy, renew, upgrade, downgrade,
cancel, grace, on hold, recovered, refund with used credits deducted,
restore, two devices, another account)."""
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from core import ai, ai_levels_service as ALS, billing, credits as CR, plans
from core.logic import ai_levels as AL, plan_book as BOOK, pricing as P
from core.ai_config import DEFAULT_PRICES
from core.models import PaidOrder, PaymentEvent, PlanPeriod, PlayPurchase
from core.payments import catalog, play

from .tests_pay1 import PlayBase, _client, sub_body


def v2_on(extra=None, prices=False):
    """Turn pricing_v2 on in the (test) PricingConfig row, optionally with
    the owner's settings patch and the approved proposal prices."""
    row = billing.get_config()
    d = dict(P.normalize(row.data))
    d["pricing_v2"] = {"on": True}
    if extra:
        for k, v in extra.items():
            d[k] = BOOK.deep_merge(d.get(k) or {}, v) if isinstance(v, dict) else v
    if prices:
        for pid, (price, _) in BOOK.APPROVED.items():
            if pid in d["plans"]:
                d["plans"][pid]["price"] = price
        d["topup_packs"] = [dict(p, credits=0) for p in BOOK.V2_PACKS] + [
            p for p in d["topup_packs"] if p["id"] in BOOK.LEGACY_PACKS]
    row.data = d
    row.save()


def v2_full(prices=False):
    v2_on({k: v for k, v in BOOK.v2_settings_patch().items() if k != "pricing_v2"}, prices)


# ------------------------------------------------------------------ formula
class FormulaTests(TestCase):
    def test_formula_reproduces_every_approved_number(self):
        for pid, (price, credits) in BOOK.APPROVED.items():
            self.assertEqual(BOOK.credits_for_price(price, BOOK.OTHER_COST_BDT.get(pid, 0)),
                             credits, pid)
        usd, rate, pool = BOOK.APPROVED_PROBASHI
        self.assertEqual(BOOK.credits_for_price(usd * rate), pool)

    def test_level_credits_normal_better_1_best_11(self):
        for lid, want in BOOK.APPROVED_LEVEL_CREDITS.items():
            row = BOOK.V2_LEVELS[lid]
            self.assertEqual(BOOK.level_credits(AL.worst_cost_usd(row, DEFAULT_PRICES)), want, lid)

    def test_haiku_prompts_stay_under_90k(self):
        self.assertLess(AL.BOUNDS["in_cap"][1], BOOK.HAIKU_PROMPT_MAX_TOKENS)
        for row in BOOK.V2_LEVELS.values():
            self.assertLess(row["in_cap"], BOOK.HAIKU_PROMPT_MAX_TOKENS)

    def test_off_by_default_nothing_changes(self):
        c = P.normalize(P.DEFAULTS())
        self.assertFalse(c["pricing_v2"]["on"])
        self.assertEqual(c["plans"]["premium"]["credits"], 90)
        self.assertEqual(c["plans"]["business"]["credits"], 240)
        self.assertEqual((c["billing"]["unlock_pct"], c["billing"]["unlock_hours"]), (20, 48))
        self.assertEqual(c["billing"]["pack_expiry_months"], 0)
        self.assertEqual([p["id"] for p in c["topup_packs"]], ["p20", "p50", "p100", "p200"])
        self.assertEqual(BOOK.packs_off(c), set())
        self.assertEqual(c["action_costs"]["vehicle_tracking_month"]["credits"], 50)

    def test_normalize_is_idempotent_with_v2(self):
        d = P.DEFAULTS()
        d["pricing_v2"] = {"on": True}
        once = P.normalize(d)
        self.assertEqual(P.normalize(once), once)
        self.assertEqual(once["plans"]["premium"]["credits"], 70)        # ৳199 (code price)
        self.assertEqual((once["billing"]["unlock_pct"], once["billing"]["unlock_hours"]), (100, 0))
        self.assertEqual(once["billing"]["pack_expiry_months"], 12)
        self.assertEqual(BOOK.packs_off(once), set(BOOK.LEGACY_PACKS))
        packs = {p["id"]: p["credits"] for p in once["topup_packs"]}
        self.assertEqual((packs["c50"], packs["c120"], packs["c300"]), (60, 140, 330))

    def test_credits_are_never_typed_under_v2(self):
        d = P.DEFAULTS()
        d["pricing_v2"] = {"on": True}
        d["plans"]["premium"]["credits"] = 999          # a typed number is ignored
        self.assertEqual(P.normalize(d)["plans"]["premium"]["credits"], 70)

    def test_low_credit_rule(self):
        self.assertTrue(BOOK.low_credit(3, 0)["low"])
        self.assertFalse(BOOK.low_credit(50, 0)["low"])
        self.assertTrue(BOOK.low_credit(15, 160)["low"])         # under 10 % of the pool
        self.assertTrue(BOOK.low_credit(0, 160)["empty"])

    def test_pnl(self):
        out = BOOK.plan_pnl({"premium": 1000.0}, {"premium": 200.0}, {"premium": 3})
        self.assertEqual(out["premium"]["users"], 3)
        self.assertAlmostEqual(out["premium"]["net_bdt"], 739.0)
        self.assertAlmostEqual(out["premium"]["profit_bdt"], 539.0)


# ------------------------------------------------------------------ 40 % CI check
class FortyPercentCiTests(TestCase):
    """Owner 9 Nov: the 40 % worst-case profit check is a CI test over every
    plan, pack and AI level — at the code prices AND the approved prices."""

    def _check(self):
        c = billing.cfg()
        rows = BOOK.worst_case_rows(c)
        self.assertTrue(rows)
        for r in rows:
            self.assertGreaterEqual(r["profit_pct"], 40.0, r)
        lv, _ = ALS.cfg(c)
        prices, rate, safe, _ = ALS._economics(c)
        lrows = BOOK.level_rows(lv["levels"], prices, AL.worst_cost_usd,
                                lambda row: AL.credits_for(row, prices, rate, safe))
        for r in lrows:
            self.assertGreaterEqual(r["profit_pct"], 40.0, r)
        return c, lrows

    def test_code_prices(self):
        v2_full()
        c, lrows = self._check()
        self.assertEqual({r["id"]: r["credits"] for r in lrows},
                         {"normal": 1, "better": 1, "best": 11})

    def test_approved_prices(self):
        v2_full(prices=True)
        c, _ = self._check()
        self.assertEqual(c["plans"]["premium"]["credits"], 160)
        self.assertEqual(c["plans"]["business"]["credits"], 440)
        self.assertEqual(c["plans"]["plus"]["credits"], 70)
        self.assertEqual(c["plans"]["premium_pro"]["credits"], 350)
        self.assertEqual(c["probashi_plan"]["pool_credits"], 210)

    def test_every_credit_sold_at_or_above_floor(self):
        from core.logic import pricing_40 as P40
        v2_full(prices=True)
        for pid, per in P40.bdt_per_credit_rows(billing.cfg()):
            self.assertGreaterEqual(per + 1e-9, BOOK.MIN_BDT_PER_CREDIT, pid)


# ------------------------------------------------------------------ switch effects
def _user(phone="+8801900000777"):
    return get_user_model().objects.create_user(name="pp", phone=phone, password="pw12345!")


class SwitchEffectTests(TestCase):
    def test_legacy_packs_not_sold_but_still_sync(self):
        self.assertIsNotNone(catalog.price("pack_p20", "gateway", gate=False))
        v2_on()
        self.assertIsNone(catalog.price("pack_p20", "gateway"))
        self.assertIsNotNone(catalog.price("pack_p20", "play", gate=False))

    def test_no_drip_and_existing_locked_credits_open(self):
        u = _user()
        CR.grant(u, CR.PLAN, 100, reason="grant", source_type="test", source_id="a",
                 key="a1", staged=True)
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 20)                 # old rule: 20 % now
        v2_on()
        CR.settle(u)
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 100)                # the rest opens at once
        CR.grant(u, CR.PLAN, 50, reason="grant", source_type="test", source_id="b",
                 key="b1", staged=True)
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 150)                # 100 % at purchase

    def test_pack_expires_after_12_months_with_7_day_warning(self):
        v2_on()
        u = _user()
        now = timezone.now()
        lot = CR.grant(u, CR.PACK, 60, reason="topup", source_type="test", source_id="p",
                       key="p1", now=now)
        self.assertIsNotNone(lot.expires_at)
        self.assertGreater(lot.expires_at, now + timedelta(days=360))
        st = CR.state(u, now=now)
        self.assertFalse(st["pack_expiring"])
        self.assertEqual(st["pack_expires_at"], lot.expires_at.isoformat())
        st = CR.state(u, now=lot.expires_at - timedelta(days=3))
        self.assertTrue(st["pack_expiring"])
        self.assertEqual(st["pack_expiring_credits"], 60)
        CR.settle(u, now=lot.expires_at + timedelta(seconds=1))
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 0)

    def test_pack_never_expires_with_switch_off(self):
        u = _user()
        lot = CR.grant(u, CR.PACK, 20, reason="topup", source_type="test", source_id="p",
                       key="p2")
        self.assertIsNone(lot.expires_at)

    def test_low_credit_in_state(self):
        u = _user()
        CR.grant(u, CR.PACK, 3, reason="topup", source_type="test", source_id="p", key="p3")
        st = CR.state(u)
        self.assertTrue(st["low_credit"]["low"])
        self.assertFalse(st["low_credit"]["empty"])

    def test_two_ads_buy_one_normal_answer(self):
        v2_full()
        self.assertEqual(ALS.credits("normal"), 1)
        self.assertEqual(ALS.ad_paisa(), 50)
        self.assertEqual(ALS.cfg()[0]["welcome_credits"], 30)
        self.assertEqual(ALS.cfg()[0]["free_credit_levels"], ["normal", "better"])

    def test_web_search_costs_3_credits(self):
        v2_full()
        self.assertEqual(ALS.web_credits(), 3)

    def test_plan_texts_carry_no_typed_numbers(self):
        v2_full(prices=True)
        en = {r["id"]: r for r in plans.plans_public("en")}
        self.assertIn("160 AI credits a month", en["premium"]["benefits"][0])
        self.assertIn("14 Best", en["premium"]["benefits"][0])
        u = _user()
        e = plans.entitlements(u, "en")
        self.assertNotIn("90", e["desc"])

    def test_cctv_extra_packs_cost_formula_credits(self):
        from core import cctv_cap as CC
        v2_on()
        self.assertEqual(CC.credit_bdt(), BOOK.MIN_BDT_PER_CREDIT)
        st = CC.status(_user())
        got = {p["kind"]: p["credits"] for p in st["packs"]}
        self.assertEqual(got, {"relay": 54, "ai": 29})
        self.assertTrue(all(p["pay_play"] for p in st["packs"]))
        self.assertTrue(st["play_account_id"])

    def test_care_call_schedules_by_safety_plan(self):
        from core import carecall as CC, safe_plans as SP
        u = _user()
        self.assertEqual(CC.limits(u)["carecall_active_per_setter"], 10)   # switch off
        v2_on()
        for plan, n, rings in (("free", 3, 90), ("child", 5, 0), ("family", 20, 0)):
            with mock.patch.object(SP, "current_plan", return_value=(plan, "", None)):
                lim = CC.limits(u)
            self.assertEqual(lim["carecall_active_per_setter"], n, plan)
            self.assertEqual(lim["carecall_rings_per_setter_month"], rings, plan)


# ------------------------------------------------------------------ web search
class WebSearchChargeTests(TestCase):
    def setUp(self):
        v2_full()
        self.u = _user()
        self.u.ai_credits = 100
        self.charges = []

        def charge(user, action, qty=1, note="", min_credits=0, exact=None, paid_only=False):
            self.charges.append((action, exact))
            return {"ok": True, "charged": exact or 0, "balance": 50, "spend_ref": "sp:%d" %
                    len(self.charges)}
        self.p = [mock.patch.object(ai, "_providers",
                                    return_value=[("anthropic", "a"), ("gemini", "g")]),
                  mock.patch("core.billing.charge", side_effect=charge)]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in self.p:
            p.stop()

    def test_gemini_quota_first_and_paid_only_when_search_ran(self):
        seen = []

        def gem(k, m, *a, **kw):
            seen.append((m, ai._opts().get("web")))
            return ("ok", 10, 5, {"web_ran": True})
        with mock.patch.object(ai, "_call_gemini", side_effect=gem):
            ai.generate("q", user=self.u, feature="chat.normal", level="normal", web=True)
        self.assertEqual(seen[0][1], True)
        self.assertEqual(self.charges, [("ai_level_normal", 1), ("ai_web_search", 3)])

    def test_no_search_no_extra_charge(self):
        with mock.patch.object(ai, "_call_gemini",
                               side_effect=lambda *a, **kw: ("ok", 10, 5, {"web_ran": False})):
            ai.generate("q", user=self.u, feature="chat.normal", level="normal", web=True)
        self.assertEqual(self.charges, [("ai_level_normal", 1)])

    def test_claude_web_search_after_the_free_quota(self):
        v2_full()
        row = billing.get_config()
        d = dict(row.data)
        d["ai_levels"] = dict(d["ai_levels"], web_free_per_day=0)
        row.data = d
        row.save()
        seen = []

        def ant(k, m, *a, **kw):
            seen.append((m, ai._opts().get("web")))
            return ("ok", 10, 5, {"web_ran": True})
        gem = mock.Mock()
        with mock.patch.object(ai, "_call_anthropic", side_effect=ant), \
                mock.patch.object(ai, "_call_gemini", side_effect=gem):
            ai.generate("q", user=self.u, feature="chat.normal", level="normal", web=True)
        gem.assert_not_called()
        self.assertEqual(seen, [("claude-haiku-5-5", True)])
        self.assertEqual(self.charges[-1], ("ai_web_search", 3))

    def test_anthropic_body_gets_the_web_tool(self):
        captured = {}

        class FakeClient:
            class messages:   # noqa: N801
                @staticmethod
                def create(**body):
                    captured.update(body)
                    u = mock.Mock(input_tokens=1, output_tokens=1, cache_read_input_tokens=0,
                                  cache_creation_input_tokens=0)
                    u.server_tool_use = mock.Mock(web_search_requests=1)
                    return mock.Mock(content=[mock.Mock(type="text", text="hi")], usage=u,
                                     stop_reason="end_turn", model="claude-haiku-5-5")
        tok = ai._CALL_OPTS.set({"web": True, "timeout": 5})
        try:
            with mock.patch.object(ai, "_anthropic_client", return_value=FakeClient()):
                out = ai._call_anthropic("k", "claude-haiku-5-5", "s", "p", 100)
        finally:
            ai._CALL_OPTS.reset(tok)
        self.assertEqual(captured["tools"][0]["name"], "web_search")
        self.assertTrue(out[3]["web_ran"])


# ------------------------------------------------------------------ apply command
class ApplyCommandTests(TestCase):
    def test_dry_run_saves_nothing_apply_is_idempotent_and_audited(self):
        out = StringIO()
        call_command("pricing_v2_apply", "--dry-run", stdout=out)
        self.assertIn("pricing_v2.on: False -> True", out.getvalue())
        self.assertIn("Dry run", out.getvalue())
        self.assertFalse(billing.cfg()["pricing_v2"]["on"])
        n0 = len(billing.get_config().audit or [])
        out = StringIO()
        call_command("pricing_v2_apply", "--apply", stdout=out)
        self.assertIn("APPLIED", out.getvalue())
        c = billing.cfg()
        self.assertTrue(c["pricing_v2"]["on"])
        self.assertEqual(c["ai_levels"]["levels"]["normal"]["model"], "claude-haiku-5-5")
        self.assertEqual(c["ai_levels"]["levels"]["better"]["model"], "gemini-3.6-flash")
        self.assertTrue(c["ai_levels"]["web_on"])
        self.assertEqual(c["plans"]["premium"]["price"], 199)        # no live price change
        self.assertEqual(len(billing.get_config().audit or []), n0 + 1)
        out = StringIO()
        call_command("pricing_v2_apply", "--apply", stdout=out)
        self.assertIn("Already applied", out.getvalue())
        self.assertEqual(len(billing.get_config().audit or []), n0 + 1)


# ------------------------------------------------------------------ Play lifecycle
class PlayLifecycleV2Tests(PlayBase):
    """Every Play case with the fake Google (tests_pay1.FakeGoogle), pricing_v2
    ON: credits arrive 100 % at purchase and never double."""

    def setUp(self):
        super().setUp()
        v2_on()
        self.prem = billing.cfg()["plans"]["premium"]["credits"]        # 70 at ৳199
        self.biz = billing.cfg()["plans"]["business"]["credits"]

    def plan(self):
        self.u.refresh_from_db()
        return plans.effective_plan(self.u)

    def bal(self):
        self.u.refresh_from_db()
        return int(self.u.ai_credits or 0)

    def buy(self, tok="tok1", **kw):
        self.g.subs[tok] = sub_body(self.u, **kw)
        r = self.verify(tok, product=kw.get("product", "assisto_premium"))
        self.assertEqual(r.status_code, 200, r.content)
        return r

    def test_buy_gives_all_credits_at_once(self):
        self.buy()
        self.assertEqual(self.plan(), "premium")
        self.assertEqual(self.bal(), self.prem)

    def test_restore_and_second_device_never_double(self):
        self.buy()
        self.buy()                                           # restore / reinstall
        other_device = _client(self.u)
        r = self.verify("tok1", api=other_device)            # same account, 2nd phone
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["entitled"])
        self.assertEqual(self.bal(), self.prem)
        self.assertEqual(PaymentEvent.objects.filter(kind="play.charge").count(), 1)

    def test_other_account_refused(self):
        self.buy()
        b = get_user_model().objects.create_user(name="B", phone="01811000099", password="x")
        r = self.verify("tok1", api=_client(b))
        self.assertEqual(r.status_code, 403)
        b.refresh_from_db()
        self.assertEqual(b.ai_credits, 0)

    def test_upgrade_replaces_credits_no_doubling(self):
        self.buy()
        self.g.subs["tok1"]["subscriptionState"] = "SUBSCRIPTION_STATE_EXPIRED"
        self.buy("tok2", product="assisto_business", price_units="499", linked="tok1",
                 order="GPA.3300-0000-0000-00002")
        self.assertEqual(self.plan(), "business")
        self.assertEqual(self.bal(), self.biz)               # old allowance expired

    def test_downgrade_replaces_credits(self):
        self.buy("tokB", product="assisto_business", price_units="499")
        self.g.subs["tokB"]["subscriptionState"] = "SUBSCRIPTION_STATE_EXPIRED"
        self.buy("tokP", linked="tokB", order="GPA.3300-0000-0000-00003")
        self.assertEqual(self.plan(), "premium")
        self.assertEqual(self.bal(), self.prem)

    def test_renewal_is_a_new_paid_period(self):
        self.buy()
        self.g.subs["tok1"] = sub_body(self.u, ack=True, expiry_days=60,
                                       order="GPA.3300-0000-0000-00000..0")
        self.rtdn_push(self.sn("tok1", 2), mid="r")
        self.assertEqual(PaidOrder.objects.filter(kind="sub").count(), 2)
        self.assertEqual(self.plan(), "premium")

    def test_cancel_keeps_access_and_credits_until_expiry(self):
        self.buy()
        self.g.subs["tok1"] = sub_body(self.u, state="SUBSCRIPTION_STATE_CANCELED", ack=True)
        self.rtdn_push(self.sn("tok1", 3), mid="c")
        self.assertEqual(self.plan(), "premium")
        self.assertEqual(self.bal(), self.prem)
        self.assertFalse(PlanPeriod.objects.get(ref=play.ref_for("tok1")).auto_renew)

    def test_grace_keeps_access_without_new_allowance(self):
        self.buy()
        self.g.subs["tok1"] = sub_body(self.u, state="SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
                                       expiry_days=3, ack=True,
                                       order="GPA.3300-0000-0000-00000..0")
        self.rtdn_push(self.sn("tok1", 6), mid="g")
        self.assertEqual(self.plan(), "premium")
        self.assertEqual(PaidOrder.objects.filter(kind="sub").count(), 1)
        self.assertEqual(self.bal(), self.prem)

    def test_on_hold_removes_access_and_recovered_restores(self):
        self.buy()
        self.g.subs["tok1"] = sub_body(self.u, state="SUBSCRIPTION_STATE_ON_HOLD",
                                       expiry_days=-1, ack=True)
        self.rtdn_push(self.sn("tok1", 5), mid="h")
        self.assertEqual(self.plan(), "free")
        self.assertEqual(self.bal(), 0)
        self.g.subs["tok1"] = sub_body(self.u, expiry_days=30, ack=True,
                                       order="GPA.3300-0000-0000-00000..1")
        self.rtdn_push(self.sn("tok1", 1), mid="rc")
        self.assertEqual(self.plan(), "premium")
        self.assertEqual(self.bal(), self.prem)

    def test_refund_cancels_plan_and_deducts_used_credits(self):
        self.buy()
        CR.spend(self.u, 10, note="test answers")
        self.g.void("tok1", "GPA.3300-0000-0000-00000")
        self.g.subs["tok1"]["subscriptionState"] = "SUBSCRIPTION_STATE_EXPIRED"
        self.rtdn_push(self.sn("tok1", 12), mid="v")
        self.assertEqual(self.plan(), "free")
        self.assertEqual(PlanPeriod.objects.get(ref=play.ref_for("tok1")).status, "revoked")
        st = CR.state(self.u)
        self.assertEqual(st["debt"], 10)                     # the used part is owed
        self.assertEqual(PaymentEvent.objects.filter(kind="play.refund").count(), 1)

    def test_status_carries_renewal_date_and_play_price(self):
        self.buy(price_units="449")
        s = play.sub_status(self.u)
        self.assertEqual(s["status"], "active")
        self.assertEqual(s["price"], 449.0)
        self.assertTrue(s["expires_at"])

    def test_receipt_numbers_come_from_the_order(self):
        self.buy()
        from core.payments import refunds as R
        rows = R.refundable(self.u, lang="en")["purchases"]
        self.assertEqual(rows[0]["receipt"]["title"], "Premium")
        self.assertEqual(rows[0]["receipt"]["currency"], "BDT")

    def test_cctv_extra_pack_play_product_once(self):
        body = {"purchaseState": 0, "consumptionState": 0, "orderId": "GPA.7777",
                "acknowledgementState": 0, "obfuscatedExternalAccountId": play.account_id(self.u)}
        self.g.products["ctok"] = body
        r = self.verify("ctok", kind="pack", product="cctv_extra_ai_100")
        self.assertEqual(r.status_code, 200, r.content)
        self.verify("ctok", kind="pack", product="cctv_extra_ai_100")
        from core import cctv_traffic as CT
        doc = CT.month_doc(self.u.pk)
        self.assertEqual(doc["extra"]["ai"], 100)
        self.assertEqual(self.g.consumed, ["ctok"])
        self.assertEqual(PaidOrder.objects.filter(sku="cctvx_ai").count(), 1)
        self.assertEqual(PlayPurchase.objects.filter(product_id="cctv_extra_ai_100").count(), 1)
