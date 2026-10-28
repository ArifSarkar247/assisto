"""Agentforce trust parity (owner order 28 Oct) — AF-2 PII masking on the live
sales-agent path, AF-1 checked answers + sources in Agent Core, AF-4 the
Bangla/Banglish/English toxicity guard (inbound + outbound, both agents),
AF-10 the seller handoff card. No real AI / Meta call: the AI router's
provider seam is recorded, the Graph transport is the FakeGraph."""
import json
import re
from unittest import mock

from django.test import SimpleTestCase, TestCase

from core import ai
from core import ai_guard as G
from core import bizagent_service as S
from core import feature_flags as FF
from core.agentcore import planner as PL
from core.agentcore import runner as RN
from core.agentcore import trust as T
from core.ai_evals import runner as ER
from core.logic import bizagent as BZ
from core.logic import bizagent_handoff as HC
from core.models import AgentAuditEvent, FeatureFlag, Message
from core.tests_agentcore import _FlagOn, _Scripted
from core.tests_p1_bizagent import Base, mpayload

Q_EMAIL = "Panjabi ta ki cotton? amar email rahim.test@example.com, NID 1990123456789"


class _Seam:
    """The AI router's provider seam: records every prompt, echoes a token."""
    def __init__(self, reply=None):
        self.calls = []
        self.reply = reply

    def __call__(self, key, model, system, prompt, max_tokens, history=None):
        self.calls.append({"system": system, "prompt": prompt, "history": history or []})
        if self.reply is not None:
            text = self.reply(prompt) if callable(self.reply) else self.reply
        else:
            tok = re.search(r"⟦EMAIL_\d+⟧", prompt)
            text = json.dumps({"reply": "Yes, Panjabi is cotton. We will mail %s."
                               % (tok.group(0) if tok else "you"), "confidence": 0.9})
        return text, 50, 20

    def sent(self):
        return "\n".join(c["system"] + c["prompt"] + json.dumps(c["history"], ensure_ascii=False)
                         for c in self.calls)


def _router(seam):
    return [mock.patch("core.ai._providers", return_value=[("anthropic", "test-key")]),
            mock.patch("core.ai.key_present", return_value=True),
            mock.patch("core.ai._call_anthropic", side_effect=seam)]


class _P:
    def __init__(self, patches):
        self.patches = patches

    def __enter__(self):
        for p in self.patches:
            p.start()

    def __exit__(self, *a):
        for p in self.patches:
            p.stop()


# ============================================================ AF-2 masking
class SalesMaskingTests(Base):
    def test_provider_prompt_has_no_raw_pii_and_reply_round_trips(self):
        seam = _Seam()
        with _P(_router(seam)):
            self.post_meta(mpayload(Q_EMAIL, "m.af2a"))
        self.assertEqual(len(seam.calls), 1)
        sent = seam.sent()
        self.assertFalse(T.has_raw_pii(sent), sent)
        self.assertNotIn("rahim.test@example.com", sent)
        self.assertNotIn("1990123456789", sent)
        self.assertIn("⟦EMAIL_1⟧", sent)
        out = "".join(self.fake.texts())
        self.assertIn("rahim.test@example.com", out)      # the customer's own value is back
        self.assertNotIn("⟦", out)
        m = Message.objects.filter(direction="out", is_ai=True, status="sent").last()
        self.assertEqual(m.meta.get("pii_masked"), 2)       # a count, never the values
        self.assertNotIn("rahim.test", json.dumps(m.meta))

    def test_router_masks_history_and_unmasks_bangla_digit_tokens(self):
        seam = _Seam(reply="call ⟦PHONE_1⟧ or ⟦PHONE_2⟧")
        with _P(_router(seam)):
            text, _ = ai.generate("task with shop phone 01911223344", data="my no ০১৭১২৩৪৫৬৭৮",
                                  history=[{"role": "user", "content": "earlier 01911223344"},
                                           {"role": "assistant", "content": "ok"}],
                                  pii=True, digits="bn", feature="bizagent.reply")
        self.assertFalse(T.has_raw_pii(seam.sent()))
        self.assertIn("01911223344", text)                  # ⟦PHONE_১⟧ came back as the value
        self.assertIn("০১৭১২৩৪৫৬৭৮", text)
        self.assertNotIn("⟦", text)

    def test_without_pii_flag_nothing_changes(self):
        seam = _Seam(reply="plain")
        with _P(_router(seam)):
            ai.generate("task", data="my no 01712345678", feature="chat")
        self.assertIn("01712345678", seam.sent())

    def test_broken_token_from_the_model_is_never_sent(self):
        with mock.patch.object(S, "_llm_draft",
                               return_value={"text": "We will call ⟦PHONE_7⟧ today", "confidence": 0.9}):
            self.post_meta(mpayload("Panjabi ta ki cotton?", "m.af2b"))
        self.assertNotIn("⟦", "".join(self.fake.texts()))
        m = Message.objects.get(status="pending_approval")
        self.assertEqual(m.risk_reason, BZ.RISK_UNSAFE)
        self.assertNotIn("⟦", m.text)

    def test_eval_negative_control_masking_off_fails(self):
        ok = ER.run_rule("sales_pii_mask")
        self.assertEqual(ok["must_pass"], 1.0, ok["failures"][:3])
        with mock.patch.object(T.Vault, "mask", lambda self, t: t):
            bad = ER.run_rule("sales_pii_mask")
        self.assertLess(bad["must_pass"], 0.5)


# ============================================================ AF-4 toxicity
class ToxicityGuardTests(SimpleTestCase):
    def test_lexicon_bn_banglish_en_with_obfuscation(self):
        for t, cat in (("তুই একটা হারামি", "abuse"), ("haramir baccha", "abuse"),
                       ("f.u.c.k off", "abuse"), ("b1tch", "abuse"), ("fuuuuck", "abuse"),
                       ("তোকে মেরে ফেলব", "threat"), ("i'll kill you", "threat"),
                       ("মালাউনের দোকান", "hate"), ("send nudes", "sexual"),
                       ("you idiot", "insult"), ("তুমি একটা বলদ", "insult")):
            r = G.toxicity(t)
            self.assertTrue(r["toxic"], t)
            self.assertEqual(r["category"], cat, t)
            self.assertGreater(r["score"], 0)
        for t in ("একটা বালতি দরকার", "মাগুর মাছ আছে?", "চোদ্দ তারিখে", "আমার শালা আসবে",
                  "বাল-বাচ্চা নিয়ে আসব", "Scunthorpe", "shiitake", "nude lipstick",
                  "fire retardant", "পণ্যটা দেখে নেব", "গরু জবাই করব", "এটা কি হারাম?", ""):
            self.assertFalse(G.toxicity(t)["toxic"], t)

    def test_log_has_no_words(self):
        log = G.tox_log(G.toxicity("tui ekta harami"))
        self.assertEqual(set(log), {"score", "sev", "cat"})
        self.assertNotIn("harami", json.dumps(log))

    def test_eval_accuracy_and_false_positive_rate(self):
        cases = ER.load_cases("toxicity")
        tox = [c for c in cases if c["expect"]["toxic"]]
        benign = [c for c in cases if not c["expect"]["toxic"]]
        self.assertGreaterEqual(len(tox), 100)
        self.assertGreaterEqual(len(benign), 60)
        hit = sum(G.toxicity(c["input"]["text"])["toxic"] for c in tox) / len(tox)
        fp = sum(G.toxicity(c["input"]["text"])["toxic"] for c in benign) / len(benign)
        self.assertGreaterEqual(hit, 0.98)
        self.assertLessEqual(fp, 0.02)


class SalesToxicityTests(Base):
    def test_abusive_customer_gets_calm_line_handoff_and_cooldown(self):
        with mock.patch.object(S, "_llm_draft", side_effect=AssertionError("AI called")), \
                mock.patch("core.push.safe_push") as push:
            self.post_meta(mpayload("tui ekta harami, uttor de", "m.af4a"))
        out = self.outs()
        self.assertEqual(len([m for m in out if m.status != "pending_approval"]), 1)
        self.assertEqual(out[0].text, BZ.holding_message("bn", BZ.RISK_ABUSE))
        self.assertNotIn("harami", "".join(self.fake.texts()).lower())     # never mirrored
        ap = Message.objects.get(status="pending_approval")
        self.assertEqual(ap.risk_reason, BZ.RISK_ABUSE)
        self.assertEqual(ap.meta["tox"]["cat"], "abuse")
        inbound = Message.objects.get(direction="in")
        self.assertEqual(inbound.meta["tox"]["sev"], 2)
        t = self.thread()
        self.assertEqual(t.paused_by, "abuse")
        self.assertIsNotNone(t.ai_paused_until)
        body = push.call_args_list[0][0][4]       # bn body of the approval push = card
        self.assertNotIn("harami", body.lower())
        # within the cool-down the AI stays quiet
        n = len(self.fake.texts())
        with mock.patch.object(S, "_llm_draft", side_effect=AssertionError("AI called")):
            self.post_meta(mpayload("hello?", "m.af4b"))
        self.assertEqual(len(self.fake.texts()), n)

    def test_toxic_ai_draft_is_never_sent(self):
        with mock.patch.object(S, "_llm_draft",
                               return_value={"text": "Panjabi is cotton, you idiot.", "confidence": 0.9}):
            self.post_meta(mpayload("Panjabi ta ki cotton?", "m.af4c"))
        self.assertNotIn("idiot", "".join(self.fake.texts()))
        ap = Message.objects.get(status="pending_approval")
        self.assertEqual((ap.risk_reason, ap.text), (BZ.RISK_UNSAFE, ""))    # not one-tap approvable

    def test_rude_insult_goes_the_complaint_way(self):
        with mock.patch.object(S, "_llm_draft", side_effect=AssertionError("AI called")):
            self.post_meta(mpayload("you are useless", "m.af4d"))
        self.assertEqual(Message.objects.get(status="pending_approval").risk_reason,
                         BZ.RISK_COMPLAINT)


class AgentToxicityTests(_FlagOn):
    def test_toxic_final_answer_is_replaced(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "You are an idiot."}))
        run = RN.start(self.u, "hello there", topic="family", lang="en")
        self.assertEqual(RN.answer_of(run), G.SAFE_FALLBACK_LINE["en"])
        ev = run.audit.get(event="guard.toxicity")
        self.assertEqual(ev.detail["cat"], "insult")
        self.assertNotIn("idiot", json.dumps(list(run.audit.values_list("detail", flat=True))))

    def test_toxic_outbound_message_is_blocked_before_approval(self):
        for k in ("business", "business_agent"):
            FeatureFlag.objects.update_or_create(key=k, defaults={"enabled_all": True,
                                                                  "enabled_play": True})
        FF.invalidate()
        PL.set_planner(_Scripted(
            {"v": 1, "steps": [{"tool": "bizagent.reply",
                                "args": {"thread_id": 7, "text": "tui ekta harami"}}], "done": True},
            {"v": 1, "steps": [], "answer": "Not sent."}))
        run = RN.start(self.u, "reply to the customer", topic="business", lang="en")
        st = run.steps.get(kind="tool")
        self.assertEqual((st.state, st.error_code), ("failed", "toxic_blocked"))
        self.assertFalse(run.approvals.exists())
        self.assertTrue(run.audit.filter(event="guard.toxicity").exists())

    def test_goal_toxicity_score_is_audited_not_refused(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "Okay."}))
        run = RN.start(self.u, "ei harami reminder ta dekhao", topic="family", lang="en")
        self.assertEqual(run.state, "done")
        self.assertEqual(run.audit.get(event="guard.toxicity_in").detail["cat"], "abuse")


# ============================================================ AF-1 grounding
class GroundedAnswerTests(_FlagOn):
    def _two_step(self, answer):
        PL.set_planner(_Scripted(
            {"v": 1, "steps": [{"tool": "reminders.list", "args": {"days": 3}}], "done": False},
            {"v": 1, "steps": [], "answer": answer}))
        return RN.start(self.u, "what is due?", topic="family", lang="en")

    def test_invented_amount_after_tools_is_rewritten_from_templates(self):
        run = self._two_step("You have 3 reminders and owe ৳98,765.")
        self.assertNotIn("98", RN.answer_of(run))
        self.assertIn("No reminders", RN.answer_of(run))       # the tool's own template
        ev = run.audit.get(event="guard.grounding")
        self.assertEqual((ev.detail["action"], ev.detail["kinds"]), ("template", ["money"]))
        self.assertEqual(RN.answer_check(run), "rewritten")

    def test_bangla_digit_invention_is_caught_too(self):
        run = self._two_step("আপনার বাকি ৳৯৮,৭৬৫।")
        self.assertNotIn("৯৮", RN.answer_of(run))
        self.assertTrue(run.audit.filter(event="guard.grounding").exists())

    def test_numbers_from_the_tools_and_goal_pass(self):
        PL.set_planner(_Scripted(
            {"v": 1, "steps": [{"tool": "reminders.list", "args": {"days": 3}}], "done": False},
            {"v": 1, "steps": [], "answer": "Nothing in the next 3 days. Call 999 in an emergency."}))
        run = RN.start(self.u, "what is due in 3 days?", topic="family", lang="en")
        self.assertIn("999", RN.answer_of(run))
        self.assertFalse(run.audit.filter(event="guard.grounding").exists())
        self.assertEqual(RN.answer_check(run), "checked")
        src = RN.answer_sources(run, "en")
        self.assertEqual([s["tool"] for s in src], ["reminders.list"])
        self.assertTrue(src[0]["label_bn"] and src[0]["label_en"])

    def test_free_answer_with_no_tools_and_a_made_up_number_is_honest(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "Your bill is ৳4,321."}))
        run = RN.start(self.u, "what is my bill?", topic="family", lang="bn")
        self.assertEqual(RN.answer_of(run), RN.NOT_SURE_LINE["bn"])

    def test_run_api_returns_sources_and_check(self):
        from rest_framework.test import APIClient
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "reminders.list", "args": {"days": 3}}],
                                  "done": True}))
        c = APIClient()
        c.force_authenticate(self.u)
        d = c.post("/api/v1/agent-core/goals?lang=en", {"text": "what is due?", "topic": "family"},
                   format="json").json()
        self.assertEqual(d["state"], "done")
        self.assertEqual(d["answer_check"], "checked")
        self.assertEqual(d["sources"][0]["tool"], "reminders.list")


# ============================================================ AF-10 handoff card
class HandoffCardTests(Base):
    def test_complaint_handoff_carries_a_masked_card_on_push_and_inbox(self):
        with mock.patch("core.push.safe_push") as push:
            self.post_meta(mpayload("worst service, Panjabi 2 ta order korechilam, call 01712345678",
                                    "m.af10"))
        ap = Message.objects.get(status="pending_approval")
        card = ap.meta["card"]
        self.assertEqual(card["sentiment"], "unhappy")
        self.assertEqual(card["reason"], BZ.RISK_COMPLAINT)
        self.assertEqual(len(card["lines"]["bn"]), 3)
        self.assertEqual(len(card["lines"]["en"]), 3)
        allt = json.dumps(card, ensure_ascii=False)
        self.assertNotIn("01712345678", allt)
        self.assertFalse(T.has_raw_pii(allt))
        self.assertIn("Panjabi", card["lines"]["en"][0])
        self.assertFalse(re.search(r"[0-9]", "\n".join(card["lines"]["bn"])))
        args = push.call_args_list[-1][0]
        self.assertEqual(args[4], "\n".join(card["lines"]["bn"]))
        self.assertEqual(args[5], "\n".join(card["lines"]["en"]))
        self.assertNotIn("01712345678", args[4] + args[5])
        # the Business inbox shows it on the approval row and the thread header
        self.c.force_authenticate(self.user)
        rows = self.c.get("/api/v1/bizagent/approvals").data["approvals"]
        self.assertEqual(rows[0]["handoff_card"]["reason"], BZ.RISK_COMPLAINT)

    def test_every_reason_builds_bn_and_en(self):
        msgs = [{"direction": "in", "text": "Panjabi dam koto? 01812345678"}]
        cat = [{"id": 1, "name": "Panjabi", "price": "1200"}]
        for r in BZ.RISKS + ("daily_ai_cap",):
            c = HC.build(msgs, cat, {}, r)
            for lang in ("bn", "en"):
                self.assertEqual(len(c["lines"][lang]), 3, (r, lang))
                self.assertFalse(T.has_raw_pii("\n".join(c["lines"][lang])), (r, lang))
            self.assertFalse(re.search(r"[0-9]", "\n".join(c["lines"]["bn"])), r)
            self.assertFalse(re.search(r"[০-৯]", "\n".join(c["lines"]["en"])), r)

    def test_card_failure_never_blocks_the_handoff(self):
        with mock.patch("core.logic.bizagent_handoff.build", side_effect=RuntimeError("x")):
            self.post_meta(mpayload("worst service ever", "m.af10b"))
        ap = Message.objects.get(status="pending_approval")
        self.assertNotIn("card", ap.meta)
