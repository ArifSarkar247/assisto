"""aibar (2 Nov) — launch group 6 "AI সহকারী ও ভয়েস" production guards.

Every provider call is MOCKED at the router seam (core.ai._call_*) — no real
AI call ever happens in CI.

  * idempotent turns: the same client_id (stream dropped -> /send fallback,
    "Send again") never answers / charges / logs an expense twice;
  * burst limit per user (429 + Retry-After + bn/en, Bangla digits), never
    for a crisis message (AF-3 runs first);
  * the user's text and the earlier turns are capped on the legacy path too;
  * credits shown per message = credits ACTUALLY charged, + balance after;
  * honest degrade: keys present but limit / cap / every provider down ->
    the reason, never "the owner hasn't added the key yet"; nothing charged;
  * no invented taka amounts (strict on own-data questions, estimate line
    on general ones);
  * home chat (/agent): history for follow-ups, credits, idempotency;
  * manage.py ai_live_smoke: --estimate makes no call, --confirm refused in
    tests/CI, run() budget + report with mocked providers, keys never printed.
"""
import unittest
import io
import json
from datetime import date
from decimal import Decimal
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import SimpleTestCase, TestCase, override_settings
from rest_framework.test import APIClient

from core import ai, ai_chat_guard as G, ai_guard
from core.models import (Account, AIUsage, ChatMessage, ChatSession, Transaction, User)

V = "/api/v1"
SECRET = "sk-test-SECRET-never-print"


class FakeProvider:
    """Scripted provider seam. Records every call (prompt + history)."""

    def __init__(self, reply="উত্তর", fail=None):
        self.reply = reply
        self.fail = fail
        self.calls = []

    def __call__(self, key, model, system, prompt, max_tokens, history=None):
        self.calls.append({"model": model, "prompt": prompt, "history": list(history or []),
                           "max_tokens": max_tokens})
        if self.fail is not None:
            raise self.fail
        r = self.reply(prompt) if callable(self.reply) else self.reply
        return r, 120, 40


class AiBase(TestCase):
    lang = "bn"

    def setUp(self):
        cache.clear()
        self.u = User.objects.create_user(name="Rahim", phone="01711300001", password="x",
                                          language=self.lang)
        User.objects.filter(pk=self.u.pk).update(ai_credits=50)
        self.c = APIClient(HTTP_ACCEPT_LANGUAGE=self.lang)
        self.c.force_authenticate(self.u)
        self.fake = FakeProvider()
        for target, val in (("core.ai._providers", lambda: [("anthropic", SECRET)]),
                            ("core.ai._call_anthropic", self.fake)):
            p = mock.patch(target, val)
            p.start()
            self.addCleanup(p.stop)

    def session(self):
        return ChatSession.objects.create(user=self.u, source="ai")

    def send(self, s, text, cid=None, path="send"):
        body = {"text": text}
        if cid:
            body["client_id"] = cid
        return self.c.post(f"{V}/chat/sessions/{s.id}/{path}", body, format="json")

    def balance(self):
        return User.objects.get(pk=self.u.pk).ai_credits


def _sse_events(resp):
    raw = b"".join(resp.streaming_content).decode()
    out = []
    for block in raw.strip().split("\n\n"):
        ev, data = None, ""
        for line in block.split("\n"):
            if line.startswith("event:"):
                ev = line[6:].strip()
            elif line.startswith("data:"):
                data += line[5:].strip()
        out.append((ev, json.loads(data)))
    return out


# ------------------------------------------------------------------ idempotency
class IdempotentChatTests(AiBase):
    def test_same_client_id_twice_answers_and_charges_once(self):
        s = self.session()
        r1 = self.send(s, "একটা ছোট কবিতা লিখুন", cid="cid-aaaa-0001")
        self.assertEqual(r1.status_code, 200)
        bal = self.balance()
        r2 = self.send(s, "একটা ছোট কবিতা লিখুন", cid="cid-aaaa-0001")
        self.assertEqual(r2.status_code, 200)
        self.assertTrue(r2.json()["replayed"])
        self.assertEqual(r2.json()["message"]["id"], r1.json()["message"]["id"])
        self.assertEqual(len(self.fake.calls), 1)
        self.assertEqual(self.balance(), bal)                 # not charged again
        self.assertEqual(ChatMessage.objects.filter(session=s).count(), 2)

    def test_stream_dropped_then_send_fallback_is_one_turn(self):
        s = self.session()
        r = self.send(s, "write a haiku", cid="cid-bbbb-0002", path="stream")
        evs = _sse_events(r)
        self.assertEqual(evs[-1][0], "done")
        # the app lost the stream and falls back to /send with the same id
        r2 = self.send(s, "write a haiku", cid="cid-bbbb-0002")
        self.assertTrue(r2.json()["replayed"])
        self.assertEqual(r2.json()["message"]["id"], evs[-1][1]["message_id"])
        self.assertEqual(len(self.fake.calls), 1)
        # and a second stream replay is a valid SSE stream with the same text
        evs2 = _sse_events(self.send(s, "write a haiku", cid="cid-bbbb-0002", path="stream"))
        self.assertTrue(evs2[-1][1]["replayed"])
        self.assertEqual(evs2[-1][1]["text"], evs[-1][1]["text"])

    def test_in_flight_turn_answers_409(self):
        s = self.session()
        ChatMessage.objects.create(session=s, role="user", text="q",
                                   meta={"client_id": "cid-cccc-0003"})
        r = self.send(s, "q", cid="cid-cccc-0003")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["code"], "in_progress")
        self.assertIn("মুহূর্ত", r.json()["detail"])
        self.assertEqual(self.fake.calls, [])

    def test_new_or_malformed_ids_are_new_turns(self):
        s = self.session()
        self.send(s, "one", cid="cid-dddd-0004")
        self.send(s, "two", cid="cid-dddd-0005")
        self.send(s, "three", cid="x")                 # too short -> ignored
        self.send(s, "three", cid="x")
        self.assertEqual(len(self.fake.calls), 4)
        self.assertEqual(ChatMessage.objects.filter(session=s, role="user").count(), 4)

    def test_client_id_from_another_session_is_not_replayed(self):
        a, b = self.session(), self.session()
        self.send(a, "hello", cid="cid-eeee-0006")
        r = self.send(b, "hello", cid="cid-eeee-0006")
        self.assertNotIn("replayed", r.json())
        self.assertEqual(len(self.fake.calls), 2)


# ------------------------------------------------------------------ burst limit
@override_settings(AI_CHAT_RATE_PER_MIN=3, AI_CHAT_RATE_PER_HOUR=100)
class BurstLimitTests(AiBase):
    def test_fourth_message_in_a_minute_is_429_bangla(self):
        s = self.session()
        for i in range(3):
            self.assertEqual(self.send(s, "প্রশ্ন %d" % i).status_code, 200)
        r = self.send(s, "আরেকটা প্রশ্ন")
        self.assertEqual(r.status_code, 429)
        j = r.json()
        self.assertEqual((j["code"], j["ok"]), ("rate_limited", False))
        self.assertGreaterEqual(int(r["Retry-After"]), 1)
        self.assertIn("সেকেন্ড", j["detail"])
        self.assertFalse(any(ch.isascii() and ch.isdigit() for ch in j["detail"]))
        self.assertEqual(len(self.fake.calls), 3)
        # nothing saved for the refused turn
        self.assertEqual(ChatMessage.objects.filter(session=s, role="user").count(), 3)

    def test_english_and_stream_limited_too(self):
        s = self.session()
        en = APIClient(HTTP_ACCEPT_LANGUAGE="en")
        en.force_authenticate(self.u)
        for i in range(3):
            self.send(s, "q%d" % i)
        r = en.post(f"{V}/chat/sessions/{s.id}/stream", {"text": "more"}, format="json")
        self.assertEqual(r.status_code, 429)
        self.assertIn("Slow down", r.json()["detail"])

    def test_crisis_message_is_never_rate_limited(self):
        s = self.session()
        for i in range(3):
            self.send(s, "q%d" % i)
        r = self.send(s, "আমি আর বাঁচতে চাই না, আত্মহত্যা করব")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["message"]["meta"]["source"], "crisis")
        self.assertIn("৯৯৯", r.json()["message"]["text"])

    def test_replay_is_not_counted(self):
        s = self.session()
        for i in range(3):
            self.send(s, "q%d" % i, cid="cid-rrrr-%04d" % i)
        r = self.send(s, "q0", cid="cid-rrrr-0000")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["replayed"])


# ------------------------------------------------------------------ caps
class InputCapTests(AiBase):
    def test_huge_paste_is_cut_on_the_legacy_path(self):
        s = self.session()
        r = self.send(s, "ক" * 20000)
        self.assertEqual(r.status_code, 200)
        prompt = self.fake.calls[0]["prompt"]
        self.assertLess(prompt.count("ক"), G.USER_TEXT_MAX + 50)
        self.assertTrue(r.json()["message"]["meta"]["text_cut"])

    def test_history_is_bounded(self):
        s = self.session()
        for i in range(15):
            ChatMessage.objects.create(session=s, role="user", text="u%d " % i + "x" * 5000)
            ChatMessage.objects.create(session=s, role="assistant", text="a%d " % i + "y" * 5000)
        self.send(s, "next")
        hist = self.fake.calls[0]["history"]
        self.assertLessEqual(len(hist), G.LEGACY_HISTORY_TURNS)
        self.assertTrue(all(len(h["content"]) <= G.HISTORY_TURN_CHARS for h in hist))


# ------------------------------------------------------------------ credits per message
class CreditsShownTests(AiBase):
    def test_meta_credits_equal_the_real_charge_and_balance(self):
        s = self.session()
        before = self.balance()
        r = self.send(s, "দুই লাইনের একটা গল্প")
        meta = r.json()["message"]["meta"]
        self.assertEqual(meta["source"], "ai")
        self.assertGreater(meta["credits"], 0)
        self.assertEqual(before - self.balance(), meta["credits"])
        self.assertEqual(meta["balance"], self.balance())

    def test_stream_done_carries_credit_meta(self):
        s = self.session()
        evs = _sse_events(self.send(s, "hello there", path="stream"))
        done = evs[-1][1]
        self.assertEqual(done["meta"]["source"], "ai")
        self.assertEqual(done["meta"]["balance"], self.balance())
        self.assertNotIn("cost_usd", done["meta"])          # internal cost stays server-side

    def test_brain_answer_is_free(self):
        with mock.patch("core.ai._providers", return_value=[]):
            s = self.session()
            r = self.send(s, "এ মাসে কত খরচ হলো?")
        meta = r.json()["message"]["meta"]
        self.assertEqual((meta["source"], meta["credits"]), ("brain", 0))


# ------------------------------------------------------------------ honest degrade
class HonestDegradeTests(AiBase):
    @override_settings(AI_USER_DAILY_LIMIT=1)
    def test_daily_limit_says_limit_not_no_key(self):
        AIUsage.objects.create(user=self.u, feature="chat", model="m", ok=True)
        s = self.session()
        before = self.balance()
        r = self.send(s, "ফ্রান্সের রাজধানী কী?")
        m = r.json()["message"]
        self.assertIn("দৈনিক সীমা", m["text"])
        self.assertNotIn("key", m["text"])
        self.assertEqual((m["meta"]["ai_unavailable"], m["meta"]["credits"]), ("user_limit", 0))
        self.assertEqual(self.balance(), before)

    def test_all_providers_down_refunds_and_says_so(self):
        self.fake.fail = ai.ProviderError("server")
        s = self.session()
        before = self.balance()
        # ailang: the reply follows the language of the message (Bangla here)
        r = self.send(s, "ফ্রান্সের রাজধানী কোথায়?")
        m = r.json()["message"]
        self.assertEqual(m["meta"]["ai_unavailable"], "queued")
        self.assertIn("ক্রেডিট কাটা হয়নি", m["text"])
        self.assertEqual(self.balance(), before)        # refunded

    def test_english_line(self):
        self.fake.fail = ai.ProviderError("timeout")
        en = APIClient(HTTP_ACCEPT_LANGUAGE="en")
        en.force_authenticate(self.u)
        s = self.session()
        r = en.post(f"{V}/chat/sessions/{s.id}/send", {"text": "capital of France?"},
                    format="json")
        self.assertIn("no credits were taken", r.json()["message"]["text"])


# ------------------------------------------------------------------ money grounding
class MoneyGroundingTests(AiBase):
    def setUp(self):
        super().setUp()
        acc = Account.objects.create(user=self.u, name="Cash", acc_type="cash")
        Transaction.objects.create(user=self.u, account=acc, kind="expense",
                                   amount=Decimal("850"), date=date.today())

    def test_own_data_question_invented_amount_is_cut(self):
        self.fake.reply = "এ মাসে আপনার খরচ ৳৯,৯৯৯। খাবারে বেশি গেছে।"
        r = self.send(self.session(), "এ মাসে কত খরচ হলো?")
        m = r.json()["message"]
        self.assertNotIn("৯,৯৯৯", m["text"])
        self.assertIn(ai_guard.UNGROUNDED_MONEY_LINE["bn"], m["text"])
        self.assertIn("খাবারে বেশি গেছে", m["text"])
        self.assertEqual(m["meta"]["money_grounding"], 1)

    def test_own_data_real_amount_is_kept(self):
        self.fake.reply = "এ মাসে আপনার খরচ ৳৮৫০।"
        r = self.send(self.session(), "এ মাসে কত খরচ হলো?")
        m = r.json()["message"]
        self.assertIn("৳৮৫০", m["text"])
        self.assertNotIn("money_grounding", m["meta"])


class MoneyGuardUnitTests(SimpleTestCase):
    def test_strict_removes_only_the_bad_sentence(self):
        out, n = ai_guard.scrub_ungrounded_money(
            "Your balance is ৳1,200. You also spent 4500 taka on rent. Good job.",
            "balance ৳1200", lang="en", strict=True)
        self.assertIn("৳1,200", out)
        self.assertNotIn("4500", out)
        self.assertIn("Good job", out)
        self.assertEqual(n, 1)

    def test_sum_of_grounded_amounts_is_allowed(self):
        out, n = ai_guard.scrub_ungrounded_money(
            "মোট ৳১,১২০ লাগবে।", "পণ্য ৳1000, ডেলিভারি ৳120", lang="bn")
        self.assertEqual(n, 0)

    def test_general_question_gets_estimate_line_once(self):
        out, n = ai_guard.scrub_ungrounded_money(
            "ঢাকা-চট্টগ্রাম বাসভাড়া সাধারণত ৳৮০০–১২০০ টাকা।", "বাসভাড়া কত?", strict=False)
        self.assertEqual(out.count(ai_guard.MONEY_ESTIMATE_LINE["bn"]), 1)
        self.assertIn("৮০০", out)
        again, _ = ai_guard.scrub_ungrounded_money(out, "বাসভাড়া কত?", strict=False)
        self.assertEqual(again.count(ai_guard.MONEY_ESTIMATE_LINE["bn"]), 1)

    def test_plain_text_untouched(self):
        self.assertEqual(ai_guard.scrub_ungrounded_money("হ্যালো!", "")[0], "হ্যালো!")

    def test_guard_helpers(self):
        self.assertEqual(G.cap_text("abc", 2), ("ab", True))
        self.assertEqual(G.unavailable_line("no_key", "bn"), None)
        self.assertIn("ক্রেডিট", G.unavailable_line("weird_new_reason", "bn"))


# ------------------------------------------------------------------ home chat (/agent)
class HomeAgentTests(AiBase):

    @unittest.skip("Owner AI chat rebuild 4 Nov 01:02: the regex intent parser no longer writes from chat; saving = model proposal + Yes (core/tests_ai_rebuild.py)")
    def test_retry_with_same_client_id_logs_the_expense_once(self):
        body = {"text": "৫০০ টাকা খরচ খাবার", "client_id": "cid-home-0001"}
        r1 = self.c.post(f"{V}/agent", body, format="json")
        r2 = self.c.post(f"{V}/agent", body, format="json")
        self.assertEqual(r1.status_code, 200)
        self.assertTrue(r2.json()["replayed"])
        self.assertEqual(r2.json()["message_id"], r1.json()["message_id"])
        self.assertEqual(Transaction.objects.filter(user=self.u).count(), 1)

    def test_ai_question_reports_credits_and_uses_history(self):
        r1 = self.c.post(f"{V}/agent", {"text": "what is the capital of France?"},
                         format="json")
        j1 = r1.json()
        self.assertTrue(j1["ai_used"])
        self.assertGreater(j1["credits"], 0)
        self.assertEqual(j1["balance"], self.balance())
        r2 = self.c.post(f"{V}/agent", {"text": "and of Japan?",
                                        "session_id": j1["session_id"]}, format="json")
        self.assertTrue(r2.json()["ai_used"])
        hist = self.fake.calls[-1]["history"]
        self.assertTrue(any("France" in h["content"] for h in hist))
        am = ChatMessage.objects.get(pk=r2.json()["message_id"])
        self.assertTrue(am.meta["ai_used"])
        self.assertGreater(am.meta["credits"], 0)

    @unittest.skip("Owner AI chat rebuild 4 Nov 01:02: the regex intent parser no longer writes from chat; saving = model proposal + Yes (core/tests_ai_rebuild.py)")
    def test_local_command_is_free(self):
        r = self.c.post(f"{V}/agent", {"text": "remind me to call mom tomorrow 9am"},
                        format="json")
        self.assertEqual(r.json()["credits"], 0)
        self.assertEqual(self.fake.calls, [])

    def test_provider_down_says_so_not_no_key(self):
        self.fake.fail = ai.ProviderError("connection")
        r = self.c.post(f"{V}/agent", {"text": "what is the capital of France?"},
                        format="json")
        j = r.json()
        self.assertEqual(j["ai_unavailable"], "queued")
        self.assertNotIn("key", j["reply"])

    @override_settings(AGENT_RATE_PER_MIN=2, AGENT_RATE_PER_HOUR=100)
    def test_home_burst_limit_and_crisis_exception(self):
        for t in ("note buy milk", "note buy rice"):
            self.assertEqual(self.c.post(f"{V}/agent", {"text": t}, format="json").status_code,
                             200)
        r = self.c.post(f"{V}/agent", {"text": "note buy eggs"}, format="json")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["code"], "rate_limited")
        r = self.c.post(f"{V}/agent", {"text": "I want to kill myself"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["intent"], "crisis")


# ------------------------------------------------------------------ home chat on the 40 % path
class HomeAgentPricing40Tests(AiBase):
    """With the owner's pricing-40 preset ON, the home question uses the same
    capped chat modes as the Assisto AI chat (smart = Sonnet, 2 credits;
    quick = free quota) — before it always ran the MAIN model for 1 credit."""

    def setUp(self):
        super().setUp()
        out = io.StringIO()
        call_command("apply_pricing_preset", "pricing_27oct", "--apply", "--backup-done",
                     stdout=out)
        self.assertIn("APPLIED", out.getvalue())

    def test_default_smart_mode_model_and_real_credits(self):
        before = self.balance()
        r = self.c.post(f"{V}/agent", {"text": "what is the capital of France?"},
                        format="json")
        j = r.json()
        self.assertTrue(j["ai_used"])
        self.assertEqual(self.fake.calls[-1]["model"], "claude-sonnet-5-5")
        self.assertEqual(j["credits"], before - self.balance())
        self.assertEqual(j["credits"], 2)
        u = AIUsage.objects.filter(user=self.u, ok=True).latest("id")
        self.assertEqual(u.feature, "chat.smart")

    def test_quick_mode_is_free_quota(self):
        before = self.balance()
        r = self.c.post(f"{V}/agent", {"text": "what is the capital of France?",
                                        "mode": "quick"}, format="json")
        j = r.json()
        self.assertEqual((j["credits"], j.get("free_quota")), (0, True))
        self.assertEqual(self.balance(), before)
        self.assertEqual(self.fake.calls[-1]["model"], "claude-haiku-5-5")


# ------------------------------------------------------------------ live smoke
class LiveSmokeTests(TestCase):
    def setUp(self):
        cache.clear()
        self.fake = FakeProvider(reply=lambda p: "ঢাকা বাংলাদেশের রাজধানী।" if "ঢাকা" in p
                                 else "Dhaka is the capital of Bangladesh.")
        for target, val in (("core.ai._providers",
                             lambda: [("anthropic", SECRET), ("openai", SECRET + "2")]),
                            ("core.ai._call_anthropic", self.fake),
                            ("core.ai._call_openai", self.fake)):
            p = mock.patch(target, val)
            p.start()
            self.addCleanup(p.stop)

    def test_estimate_makes_no_call_and_never_prints_keys(self):
        out = io.StringIO()
        call_command("ai_live_smoke", "--estimate", stdout=out)
        txt = out.getvalue()
        self.assertEqual(self.fake.calls, [])
        self.assertIn("anthropic.main.bn", txt)
        self.assertIn("openai.cheap.bn", txt)
        self.assertIn("worst-case total", txt)
        self.assertNotIn("SECRET", txt)

    def test_default_is_estimate_and_confirm_is_refused_in_tests(self):
        out = io.StringIO()
        call_command("ai_live_smoke", stdout=out)
        self.assertEqual(self.fake.calls, [])
        with self.assertRaises(CommandError):
            call_command("ai_live_smoke", "--confirm", "--budget-usd", "1", stdout=io.StringIO())
        self.assertEqual(self.fake.calls, [])
        with self.assertRaises(CommandError):
            call_command("ai_live_smoke", "--estimate", "--budget-usd", "50",
                         stdout=io.StringIO())

    def test_run_reports_latency_cost_bangla_and_stays_in_budget(self):
        from core import ai_live_smoke as S
        res = S.run(1.0)
        self.assertEqual(len(res["results"]), 6)         # 2 providers x 3 calls
        self.assertEqual(res["failed"], [])
        self.assertLessEqual(res["spent_usd"], 1.0)
        bn = [r for r in res["results"] if r["lang"] == "bn"]
        self.assertTrue(all(r["bangla"] and r["correct"] for r in bn))
        self.assertTrue(all("latency_ms" in r and "model" in r for r in res["results"]))
        self.assertFalse(AIUsage.objects.filter(feature="smoke", user__isnull=False).exists())

    def test_tiny_budget_skips_everything(self):
        from core import ai_live_smoke as S
        res = S.run(0.000001)
        self.assertEqual(res["results"], [])
        self.assertEqual(len(res["skipped"]), 6)
        self.assertEqual(self.fake.calls, [])

    def test_wrong_answer_is_reported_as_failed(self):
        from core import ai_live_smoke as S
        self.fake.reply = "Paris."
        res = S.run(1.0)
        self.assertEqual(len(res["failed"]), 6)

    def test_profit_line_warns_on_legacy_path(self):
        from core import ai_live_smoke as S
        ok, line = S.profit_line()
        self.assertFalse(ok)                      # credit_model is off by default
        self.assertIn("apply_pricing_preset", line)
