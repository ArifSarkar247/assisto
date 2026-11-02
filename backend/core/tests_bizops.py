"""bizops: the BUSINESS AI AGENT for daily operations (owner order PART 1 i);
card owner_actions/FEATURE_CARD_BIZ_OPS_AGENT_BN.md).

Proves: the new tools' contracts + numbers from the shop's own rows only
(ownership, empty states, Bangla digits); GROUNDING (every number on the
morning card is a number in the shop's data payload); APPROVALS (supplier
reorder / tagada from a card tap never run before the owner's tap; reject =
nothing; the server never sends a reorder); the NO-KEY path (everyday
questions answered by one read tool at 0 credits, other goals still the
honest ai_no_key state); the card API (flags, cost math within the 40% rule).
No AI key, no network, no spend.
"""
import json
import re
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import credits as CR
from core import feature_flags as FF
from core.agentcore import bizops as BZ
from core.agentcore import contract as C
from core.agentcore import planner as PL
from core.agentcore import runner as RN
from core.agentcore import tools as TL
from core.agentcore import tools_bizops as BO
from core.agentcore import topics as TP
from core.agentcore.evals import fixtures_topics as FT
from core.models import (AgentApproval, AgentRun, AuditLog, BusinessProfile, CashboxDay,
                         Expense, FeatureFlag, KhataParty, Message, Product, Reminder, Sale,
                         SaleLine, SmsLog, TagadaSchedule, User)

NEW = [t.name for t in BO.TOOLS]


def _user(n, credits=100):
    u = User.objects.create(name="B%d" % n, phone="+8801900%06d" % n, username="+8801900%06d" % n)
    if credits:
        CR.grant(u, CR.FREE, credits, note="t")
    u.refresh_from_db()
    return u


def _flags(**kv):
    for k, v in kv.items():
        FeatureFlag.objects.update_or_create(key=k, defaults={"enabled_all": v, "enabled_play": v})
    FF.invalidate()


def _sale(user, when, total, profit, lines=(), method="cash"):
    biz = BusinessProfile.objects.filter(user=user).first()
    s = Sale.objects.create(user=user, business=biz, subtotal=total, total=total, paid=total,
                            profit=profit, payment_method=method)
    Sale.objects.filter(pk=s.pk).update(created_at=when)
    for prod, qty, cost in lines:
        SaleLine.objects.create(sale=s, product=prod, product_name=prod.name, qty=qty,
                                unit_price=total // max(1, qty), cost_price=cost)
    return s


class _Base(TestCase):
    def setUp(self):
        cache.clear()
        FF.invalidate()
        _flags(agent_core=True, business=True, crm=True)
        self.u = _user(1)
        self.other = _user(2)
        FT.seed_business(self.u)
        self.biz = BusinessProfile.objects.get(user=self.u)
        self.now = timezone.now()
        self.d0 = timezone.localtime(self.now).replace(hour=0, minute=0, second=0, microsecond=0)

    def tearDown(self):
        PL.set_planner(None)
        FF.invalidate()

    def ctx(self, user=None, key="k1", lang="en"):
        return RN.Ctx(user=user or self.u, now=self.now, lang=lang, idem_key=key)


# ------------------------------------------------------------------ contracts
class ContractTests(_Base):
    def test_tools_registered_on_business_topic_with_the_right_risk(self):
        for n in NEW:
            t = TL.get(n)
            self.assertIs(t, TL.REGISTRY[n])
            self.assertIn(n, TP.TOPICS["business"]["tools"], n)
            self.assertEqual(t.topics, ("business",))
            self.assertFalse(t.input_schema.get("additionalProperties", True), n)
            json.dumps(t.spec())
            if t.risk == "read":
                self.assertEqual(t.credits, 0, n)
            for k, tp in TP.TOPICS.items():
                if k != "business":
                    self.assertNotIn(n, tp["tools"])
        r = TL.get("supplier.reorder")
        self.assertEqual(r.risk, "external")
        self.assertTrue(r.needs_approval and r.approval_title and r.precheck)
        self.assertLessEqual(r.rate_per_hour, 10)
        self.assertEqual(TL.get("crm.followup_task").risk, "write_low")
        self.assertNotIn("supplier.reorder", TP.GENERAL["tools"])

    def test_profit_questions_classify_as_business(self):
        for g in ("আজ কত লাভ?", "what was my profit yesterday", "এই সপ্তাহে কত বিক্রি হলো"):
            self.assertEqual(TP.classify(g), "business", g)

    def test_read_tools_empty_state_and_ownership(self):
        lonely = _user(3)
        _sale(self.u, self.now - timedelta(hours=1), 50000, 9000)
        for n in NEW:
            t = TL.get(n)
            if t.risk != "read":
                continue
            out = t.run(self.ctx(user=lonely), {})
            C.validate(out, t.output_schema)
            dump = json.dumps(out, ensure_ascii=False)
            for leak in ("Karim", "Selim", "Chal", "Rahim Store", "500"):
                self.assertNotIn(leak, dump, n)
            self.assertTrue(t.summarize(out, "bn") and t.summarize(out, "en"), n)


# ------------------------------------------------------------------ numbers
class ProfitTests(_Base):
    def test_yesterday_vs_same_day_last_week_with_expenses_and_missing_cost(self):
        chal = Product.objects.get(user=self.u, name="Chal 5kg")
        y = self.d0 - timedelta(hours=10)                 # yesterday 14:00
        _sale(self.u, y, 120000, 30000, [(chal, 2, 50000)])
        _sale(self.u, y + timedelta(hours=1), 30000, 6000, [(chal, 1, 0)])   # no cost price
        _sale(self.u, y - timedelta(days=7), 100000, 24000)
        _sale(self.other, y, 999900, 99900)                                   # another shop
        v = _sale(self.u, y, 50000, 50000)
        Sale.objects.filter(pk=v.pk).update(voided_at=self.now)              # voided: ignored
        Expense.objects.create(user=self.u, business=self.biz, amount=5000,
                               date=(self.d0 - timedelta(days=1)).date())
        o = TL.get("biz.profit").run(self.ctx(), {"period": "yesterday"})
        C.validate(o, TL.get("biz.profit").output_schema)
        self.assertEqual((o["sales_count"], o["revenue"], o["profit"]), (2, 1500.0, 360.0))
        self.assertEqual((o["expenses"], o["net"], o["prev_profit"]), (50.0, 310.0, 240.0))
        self.assertEqual(o["profit_change_pct"], 50)
        self.assertEqual(o["missing_cost"], 1)
        bn = TL.get("biz.profit").summarize(o, "bn")
        self.assertIn("৳১,৫০০", bn)
        self.assertIn("৳৩৬০", bn)
        self.assertIn("৫০% বেশি", bn)
        self.assertIn("কেনা-দাম", bn)
        en = TL.get("biz.profit").summarize(o, "en")
        self.assertIn("৳360", en)
        self.assertNotIn("9,999", en)

    def test_bad_period_and_no_sales(self):
        with self.assertRaises(C.SchemaError):
            C.validate({"period": "decade"}, TL.get("biz.profit").input_schema)
        o = TL.get("biz.profit").run(self.ctx(), {"period": "today"})
        self.assertEqual(o["sales_count"], 0)
        self.assertIn("৳০", TL.get("biz.profit").summarize(o, "bn"))
        self.assertIsNone(o["profit_change_pct"])


class RunningOutTests(_Base):
    def test_speed_days_left_and_suggested_qty(self):
        tel = Product.objects.get(user=self.u, name="Tel 1L")       # stock 10, low 3
        Product.objects.filter(pk=tel.pk).update(stock=10)
        for d in range(7):                                           # 28 sold in 14 d = 2/day
            _sale(self.u, self.now - timedelta(days=d + 1), 72000, 8000, [(tel, 4, 15000)])
        o = TL.get("stock.running_out").run(self.ctx(), {})
        C.validate(o, TL.get("stock.running_out").output_schema)
        by = {i["name"]: i for i in o["items"]}
        self.assertEqual(by["Tel 1L"]["per_day"], 2.0)
        self.assertEqual(by["Tel 1L"]["days_left"], 5)
        self.assertEqual(by["Tel 1L"]["suggest_qty"], 18)           # 14 d x 2 - 10
        self.assertEqual(by["Dal"]["stock"], 0)                     # out now first
        self.assertEqual(o["items"][0]["name"], "Dal")
        self.assertIn("Chal 5kg", by)                               # at its low level
        self.assertEqual(o["out_now"], 1)
        self.assertIn("শেষ", TL.get("stock.running_out").summarize(o, "bn"))

    def test_slow_product_above_low_level_is_not_flagged(self):
        Product.objects.create(user=self.u, business=self.biz, name="Sabun", stock=50, low_stock_at=3)
        names = [i["name"] for i in TL.get("stock.running_out").run(self.ctx(), {"limit": 20})["items"]]
        self.assertNotIn("Sabun", names)


class CashCheckTests(_Base):
    def test_not_closed_is_honest_then_shortage_after_close(self):
        y = (self.d0 - timedelta(days=1))
        _sale(self.u, y + timedelta(hours=11), 80000, 10000)
        o = TL.get("biz.cash_check").run(self.ctx(), {})
        self.assertFalse(o["closed"])
        self.assertEqual(o["expected"], 800.0)
        self.assertIn("গোনা", TL.get("biz.cash_check").summarize(o, "bn"))
        CashboxDay.objects.create(business=self.biz, day=y.date(), opening_poisha=20000,
                                  counted_poisha=90000, reconciled_at=self.now)
        o = TL.get("biz.cash_check").run(self.ctx(), {})
        C.validate(o, TL.get("biz.cash_check").output_schema)
        self.assertEqual((o["closed"], o["expected"], o["counted"], o["variance"], o["state"]),
                         (True, 1000.0, 900.0, -100.0, "shortage"))
        self.assertIn("৳১০০ কম", TL.get("biz.cash_check").summarize(o, "bn"))


# ------------------------------------------------------------------ the brief + grounding
def _strings(obj, acc):
    if isinstance(obj, str):
        acc.add(obj)
    elif isinstance(obj, dict):
        for v in obj.values():
            _strings(v, acc)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            _strings(v, acc)
    return acc


def _no_names(text, names):
    for n in sorted(names, key=len, reverse=True):
        if len(n) > 1:
            text = text.replace(n, " ")
    return text


def _numbers(obj, acc):
    if isinstance(obj, bool) or obj is None:
        return acc
    if isinstance(obj, (int, float)):
        acc.add(round(abs(float(obj)), 2))
    elif isinstance(obj, dict):
        for v in obj.values():
            _numbers(v, acc)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            _numbers(v, acc)
    return acc


class BriefTests(_Base):
    def _seed_day(self):
        tel = Product.objects.get(user=self.u, name="Tel 1L")
        y = self.d0 - timedelta(hours=10)
        _sale(self.u, y, 120000, 30000, [(tel, 6, 15000)])
        _sale(self.u, y - timedelta(days=7), 100000, 20000)
        karim = KhataParty.objects.get(business=self.biz, name="Karim")
        TagadaSchedule.objects.create(party=karim, next_at=self.now - timedelta(hours=1))
        from crm.models import CrmMember, CrmOrg, Lead
        org = CrmOrg.objects.create(name="Rahim Store", owner=self.u)
        CrmMember.objects.update_or_create(org=org, user=self.u, defaults={"role": "owner"})
        Lead.objects.create(org=org, name="Nasir Traders", next_follow_up=self.d0.date() - timedelta(days=2))
        Lead.objects.create(org=org, name="Done Co", status="won", next_follow_up=self.d0.date())
        CashboxDay.objects.create(business=self.biz, day=(self.d0 - timedelta(days=1)).date(),
                                  opening_poisha=0, counted_poisha=120000, reconciled_at=self.now)

    def test_brief_sections_and_one_tap_actions(self):
        self._seed_day()
        o = TL.get("biz.daily_brief").run(self.ctx(), {})
        C.validate(o, TL.get("biz.daily_brief").output_schema)
        self.assertFalse(o["empty"])
        self.assertEqual(o["yesterday"]["profit"], 300.0)
        self.assertEqual(o["yesterday"]["profit_change_pct"], 50)
        # Karim's reminder is due today -> first, even though Selim owes more
        self.assertEqual([i["name"] for i in o["dues"]["items"]][:2], ["Karim", "Selim"])
        self.assertTrue(o["dues"]["items"][0]["scheduled"])
        self.assertEqual(o["followups"]["count"], 1)
        self.assertEqual(o["cash"]["state"], "balanced")
        kinds = [(a["kind"], a["target"]) for a in o["actions"]]
        self.assertIn(("tagada", "Karim"), kinds)
        self.assertIn(("followup", "Nasir Traders"), kinds)
        self.assertIn("reorder", [k for k, _ in kinds])
        for a in o["actions"]:                       # every suggested action is a valid plan step
            C.validate(a["args"] if a["kind"] != "reorder" else dict(a["args"], supplier="X"),
                       TL.get(a["tool"]).input_schema)
            self.assertEqual(a["approval"], TL.get(a["tool"]).needs_approval)
        text = TL.get("biz.daily_brief").summarize(o, "bn")
        for want in ("গতকাল", "তাগাদা", "Nasir Traders", "ক্যাশ মিলে গেছে"):
            self.assertIn(want, text)

    def test_grounding_every_number_on_the_card_is_in_the_shop_data(self):
        self._seed_day()
        card = BZ.card(self.u, "en", now=self.now)
        allowed = _numbers(card["numbers"], set())
        allowed |= {14.0, 7.0}                       # the fixed window lines ("last 14 days")
        names = _strings(card["numbers"], set())     # product / customer names may hold digits
        for ln in card["lines"]:
            for m in re.finditer(r"\d[\d,]*(?:\.\d+)?", _no_names(ln["text"], names)):
                v = round(float(m.group(0).replace(",", "")), 2)
                self.assertIn(v, allowed, "%r in %r" % (m.group(0), ln["text"]))
        bn = BZ.card(self.u, "bn", now=self.now)
        self.assertFalse(any(re.search(r"[0-9]", _no_names(ln["text"], names))
                             for ln in bn["lines"]), bn["lines"])
        self.assertEqual((card["ai_used"], card["credits"]), (False, 0))

    def test_cost_block_shows_the_40_percent_math(self):
        c = BZ.cost_block("bn")
        self.assertEqual(c["card_credits"], 0)
        self.assertTrue(c["rule_ok"])
        self.assertGreaterEqual(c["plan"]["margin_pct"], 40)
        self.assertGreater(c["plan"]["price_bdt"], c["plan"]["cost_bdt"])
        self.assertEqual(len(c["lines"]), 3)
        # launchsweep: the user-facing lines never show our cost or margin.
        for ln in c["lines"] + BZ.cost_block("en")["lines"]:
            for word in ("লাভ", "খরচ ~", "margin", "our cost"):
                self.assertNotIn(word, ln)

    def test_empty_shop_card(self):
        u = _user(5)
        BusinessProfile.objects.create(user=u, shop_name="New Shop")
        card = BZ.card(u, "bn", now=self.now)
        self.assertTrue(card["empty"])
        self.assertEqual(card["actions"], [])
        self.assertTrue(card["questions"])


# ------------------------------------------------------------------ no-key path
class NoKeyTests(_Base):
    def _start(self, text):
        with mock.patch("core.ai._providers", return_value=[]):
            return RN.start(self.u, text, lang="bn")

    def test_owner_questions_match_one_read_tool(self):
        cases = {"আজ কত লাভ?": ("biz.profit", {"period": "today"}),
                 "গতকাল কত লাভ হলো": ("biz.profit", {"period": "yesterday"}),
                 "koto bikri hoyeche ei soptahe": ("biz.profit", {"period": "week"}),
                 "কার কাছে সবচেয়ে বেশি বাকি?": ("khata.dues", {"limit": 5}),
                 "who owes me the most": ("khata.dues", {"limit": 5}),
                 "কোন পণ্য শেষ হচ্ছে?": ("stock.running_out", {"limit": 10}),
                 "what is running out": ("stock.running_out", {"limit": 10}),
                 "কাল ক্যাশ মিলেছে?": ("biz.cash_check", {"day": "yesterday"}),
                 "আজকের ব্যবসা": ("biz.daily_brief", {})}
        for text, want in cases.items():
            self.assertEqual(BZ.match_intent(text), want, text)
        for text in ("করিমকে তাগাদা দাও", "send Karim a reminder", "সেলিমকে SMS পাঠাও",
                     "x", "", "আমার মায়ের জন্মদিন কবে"):
            self.assertIsNone(BZ.match_intent(text), text)

    def test_profit_question_answers_without_a_key_at_zero_credits(self):
        _sale(self.u, self.now - min(timedelta(minutes=30), (self.now - self.d0) / 2), 45000, 9000)
        bal = User.objects.get(pk=self.u.pk).ai_credits
        run = self._start("আজ কত লাভ?")
        self.assertEqual(run.state, "done", run.error_code)
        self.assertEqual((run.llm_calls, run.credits_spent, run.topic), (0, 0, "business"))
        ans = RN.answer_of(run)
        self.assertIn("৳৯০", ans)
        self.assertIn("৳৪৫০", ans)
        self.assertEqual(User.objects.get(pk=self.u.pk).ai_credits, bal)
        self.assertTrue(run.audit.filter(event="plan.ok", detail__preplanned="no_ai").exists())

    def test_top_due_and_running_out_without_a_key(self):
        ans = RN.answer_of(self._start("কার কাছে সবচেয়ে বেশি বাকি?"))
        self.assertIn("Selim", ans)
        self.assertIn("৳৩,৫০০", ans)
        ans = RN.answer_of(self._start("কোন পণ্য শেষ হচ্ছে?"))
        self.assertIn("Dal", ans)

    def test_other_goals_keep_the_honest_no_key_state(self):
        run = self._start("করিমকে তাগাদা দাও")
        self.assertEqual((run.state, run.error_code), ("failed", "ai_no_key"))

    def test_with_a_key_the_planner_still_plans(self):
        class P:
            n = 0

            def plan(self, req):
                P.n += 1
                return PL.PlanResult(raw=json.dumps({"v": 1, "steps": [
                    {"tool": "biz.profit", "args": {"period": "today"}}], "done": True}))
        PL.set_planner(P())
        run = RN.start(self.u, "আজ কত লাভ?", lang="bn")
        self.assertEqual(P.n, 1)
        self.assertEqual(run.state, "done")

    def test_business_flag_off_is_not_answered(self):
        _flags(business=False)
        run = self._start("আজ কত লাভ?")
        self.assertEqual((run.state, run.error_code), ("failed", "ai_no_key"))


# ------------------------------------------------------------------ approvals
class ApprovalTests(_Base):
    def setUp(self):
        super().setUp()
        self.sup = KhataParty.objects.create(business=self.biz, book="supplier", name="Mondol Traders",
                                             phone="01711000222")

    def _out(self):
        return (SmsLog.objects.filter(user=self.u).count(),
                Message.objects.filter(thread__user=self.u, direction="out").count())

    def test_reorder_from_card_waits_reject_does_nothing_approve_prepares_only(self):
        text, steps = BZ.action_steps("reorder", {"supplier": "Mondol Traders",
                                                  "items": [{"product": "Tel 1L", "qty": 12}]})
        run = BZ.start_action(self.u, text, steps, lang="bn")
        self.assertEqual(run.state, "waiting_approval")
        ap = AgentApproval.objects.get(run=run)
        self.assertEqual((ap.risk, ap.status), ("external", "pending"))
        self.assertIn("Mondol Traders", ap.title_bn)
        self.assertIn("Tel 1L ১২", ap.title_bn)
        self.assertFalse(AuditLog.objects.filter(user=self.u, action="agent.reorder_draft").exists())
        ap, run = RN.decide(self.u, ap.pk, "reject", lang="bn")
        self.assertFalse(AuditLog.objects.filter(user=self.u, action="agent.reorder_draft").exists())
        self.assertIn("বাতিল", RN.answer_of(run))
        # approve path
        run = BZ.start_action(self.u, text, steps, lang="bn")
        ap = AgentApproval.objects.get(run=run)
        ap, run = RN.decide(self.u, ap.pk, "approve", lang="bn")
        self.assertEqual(run.state, "done")
        self.assertIn("WhatsApp", RN.answer_of(run))
        self.assertEqual(self._out(), (0, 0))       # the server never sends a reorder
        self.assertEqual(run.credits_spent, 0)
        from core.agentcore import views as V
        sh = V._shares(run)
        self.assertEqual(len(sh), 1)
        self.assertIn("Tel 1L — ১২", sh[0]["text"])
        self.assertTrue(sh[0]["url"].startswith("https://wa.me/8801711000222?text="))

    def test_reorder_to_a_stranger_or_unknown_product_never_shows_a_card(self):
        for b in ({"supplier": "Unknown Co"},
                  {"supplier": "Mondol Traders", "items": [{"product": "Gold bar", "qty": 1}]},
                  {"supplier": "Karim"}):                     # a CUSTOMER, not a supplier
            text, steps = BZ.action_steps("reorder", b)
            run = BZ.start_action(self.u, text, steps, lang="en")
            self.assertNotEqual(run.state, "waiting_approval", b)
            self.assertFalse(AgentApproval.objects.filter(run=run).exists(), b)
            self.assertEqual(run.llm_calls, 0, b)              # never a paid re-plan
        text, steps = BZ.action_steps("reorder", {"supplier": "Unknown Co"})
        run = BZ.start_action(self.u, text, steps, lang="en", client_id="u1")
        self.assertEqual((run.state, run.error_code), ("done", "supplier_not_found"))
        self.assertIn("No supplier with this name", RN.answer_of(run))

    def test_reorder_without_items_uses_the_running_out_list(self):
        ctx = self.ctx()
        out = BO.reorder(ctx, {"supplier": "Mondol Traders"})
        names = [i["product"] for i in out["items"]]
        self.assertIn("Dal", names)
        self.assertFalse(out["sent"])

    def test_tagada_from_card_waits_then_prepares_whatsapp_with_share_url(self):
        text, steps = BZ.action_steps("tagada", {"customer": "Karim"})
        run = BZ.start_action(self.u, text, steps, lang="bn")
        self.assertEqual(run.state, "waiting_approval")
        self.assertEqual(self._out(), (0, 0))
        ap = AgentApproval.objects.get(run=run)
        ap, run = RN.decide(self.u, ap.pk, "approve", lang="bn")
        self.assertEqual(self._out(), (0, 0))
        from core.agentcore import views as V
        sh = V._shares(run)
        self.assertEqual(sh[0]["tool"], "khata.tagada")
        self.assertTrue(sh[0]["url"].startswith("https://wa.me/8801811223344"))

    def test_sms_tagada_from_card_is_charged_only_after_approval(self):
        text, steps = BZ.action_steps("tagada", {"customer": "Karim", "channel": "sms"})
        with mock.patch("core.sms_service.send_sms") as send:
            run = BZ.start_action(self.u, text, steps, lang="bn")
            send.assert_not_called()
            ap = AgentApproval.objects.get(run=run)
            ap, run = RN.decide(self.u, ap.pk, "reject", lang="bn")
            send.assert_not_called()
        self.assertEqual(run.state, "done")
        self.assertEqual(SmsLog.objects.filter(user=self.u).count(), 0)

    def test_card_runs_cost_nothing_and_skip_the_ai_run_cap(self):
        for i in range(RN.LIMITS["free"]["runs_per_day"] + 2):
            text, steps = BZ.action_steps("question", {"key": "profit_today"})
            run = BZ.start_action(self.u, text, steps, lang="en", client_id="q%d" % i)
            self.assertEqual((run.state, run.credits_spent, run.llm_calls), ("done", 0, 0))

    def test_unknown_or_disallowed_steps_are_refused(self):
        with self.assertRaises(ValueError):
            BZ.action_steps("pay", {})
        with self.assertRaises(ValueError):
            BZ.check_steps(self.u, [{"tool": "memory.forget", "args": {"id": 1}}])
        with self.assertRaises(ValueError):
            BZ.check_steps(self.u, [{"tool": "biz.profit", "args": {"period": "x"}}])


class FollowupTests(_Base):
    def setUp(self):
        super().setUp()
        from crm.models import CrmMember, CrmOrg, Lead
        org = CrmOrg.objects.create(name="Mine", owner=self.u)
        CrmMember.objects.update_or_create(org=org, user=self.u, defaults={"role": "owner"})
        self.lead = Lead.objects.create(org=org, name="Nasir Traders")
        o2 = CrmOrg.objects.create(name="Theirs", owner=self.other)
        Lead.objects.create(org=o2, name="Secret Lead")

    def test_creates_task_reminder_and_is_idempotent(self):
        from crm.models import Activity
        t = TL.get("crm.followup_task")
        a = t.run(self.ctx(key="s1"), {"lead": "nasir traders", "when": "tomorrow"})
        b = t.run(self.ctx(key="s1"), {"lead": "nasir traders", "when": "tomorrow"})
        C.validate(a, t.output_schema)
        self.assertTrue(a["created"])
        self.assertFalse(b["created"])
        self.assertEqual(Activity.objects.filter(lead=self.lead, kind="task").count(), 1)
        self.assertEqual(Reminder.objects.filter(user=self.u, source="ai").count(), 1)
        self.lead.refresh_from_db()
        self.assertEqual(self.lead.next_follow_up, (self.d0 + timedelta(days=1)).date())
        self.assertIn("Nasir Traders", t.summarize(a, "bn"))

    def test_other_orgs_lead_and_bad_dates(self):
        t = TL.get("crm.followup_task")
        with self.assertRaises(C.ToolError):
            t.run(self.ctx(key="s2"), {"lead": "Secret Lead"})
        with self.assertRaises(C.ToolError):
            t.run(self.ctx(key="s3"), {"lead": "Nasir Traders", "when": "2001-01-01"})
        with self.assertRaises(C.ToolError):
            t.run(self.ctx(key="s4"), {"lead": "Nasir Traders", "when": "soon"})

    def test_from_the_card_runs_at_once(self):
        text, steps = BZ.action_steps("followup", {"lead": "Nasir Traders"})
        run = BZ.start_action(self.u, text, steps, lang="bn")
        self.assertEqual(run.state, "done")
        self.assertIn("ফলো-আপ", RN.answer_of(run))


# ------------------------------------------------------------------ API
class ApiTests(_Base):
    def setUp(self):
        super().setUp()
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        self.c.credentials(HTTP_ACCEPT_LANGUAGE="bn")

    def test_card_and_act(self):
        r = self.c.get("/api/v1/agent-core/biz-brief")
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        for k in ("lines", "actions", "questions", "cost", "numbers", "suppliers", "ai_ready"):
            self.assertIn(k, j)
        self.assertEqual(j["credits"], 0)
        r = self.c.post("/api/v1/agent-core/biz-brief/act",
                        {"kind": "question", "key": "top_due", "client_id": "c1"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["state"], "done")
        self.assertIn("Selim", r.json()["answer"])
        self.assertEqual(r.json()["shares"], [])
        r2 = self.c.post("/api/v1/agent-core/biz-brief/act",
                         {"kind": "question", "key": "top_due", "client_id": "c1"}, format="json")
        self.assertEqual(r2.json()["id"], r.json()["id"])           # idempotent per client_id
        r = self.c.post("/api/v1/agent-core/biz-brief/act", {"kind": "tagada", "customer": "Karim"},
                        format="json")
        self.assertEqual(r.json()["state"], "waiting_approval")
        self.assertEqual(len(r.json()["approvals"]), 1)
        r = self.c.post("/api/v1/agent-core/biz-brief/act", {"kind": "nope"}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_flags_gate_the_card(self):
        _flags(business=False)
        self.assertEqual(self.c.get("/api/v1/agent-core/biz-brief").status_code, 403)
        _flags(business=True, agent_core=False)
        self.assertEqual(self.c.get("/api/v1/agent-core/biz-brief").status_code, 403)
        self.assertEqual(self.c.post("/api/v1/agent-core/biz-brief/act",
                                     {"kind": "question", "key": "cash"}, format="json").status_code, 403)

    def test_another_user_cannot_see_my_shares(self):
        text, steps = BZ.action_steps("tagada", {"customer": "Karim"})
        run = BZ.start_action(self.u, text, steps, lang="bn")
        ap = AgentApproval.objects.get(run=run)
        RN.decide(self.u, ap.pk, "approve", lang="bn")
        c2 = APIClient()
        c2.force_authenticate(self.other)
        self.assertEqual(c2.get("/api/v1/agent-core/runs/%d" % run.pk).status_code, 404)
        mine = self.c.get("/api/v1/agent-core/runs/%d" % run.pk).json()
        self.assertEqual(len(mine["shares"]), 1)
