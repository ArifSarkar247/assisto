"""gap-aichat (owner order 17 Nov 10:10, feature gap sweep): AI chat gaps.

* a streamed Assisto AI answer carries `cut` / `follow` / `hint_better` /
  `actions` in its `done` meta (before: stripped -> no Continue button);
* a free Continue is a SHORT ask after a cut answer, at most
  MAX_FREE_CONTINUES in a row; a new question sent with follow=continue is a
  normal paid turn;
* regenerating a Continue turn continues again (Continue note), level kept;
* the system prompt never tells an English user to get a Bangla reply.
Fake providers only — no AI call, no money."""
import json
from types import SimpleNamespace
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from core import ai_prompt as AP
from core import views_chat as VC
from core.models import ChatMessage, ChatSession


def _u(phone):
    return get_user_model().objects.create_user(name="g", phone=phone, password="pw12345!")


def _req(**data):
    return SimpleNamespace(data=data, query_params={})


class FreeContinueRuleTests(TestCase):
    def setUp(self):
        self.u = _u("+8801311990001")
        self.s = ChatSession.objects.create(user=self.u)

    def _asst(self, **meta):
        return ChatMessage.objects.create(session=self.s, role="assistant", text="x", meta=meta)

    def test_short_continue_after_cut_is_free(self):
        self._asst(cut=True, credits=2)
        self.assertEqual(VC.follow_kind(_req(follow="continue"), "Continue", self.s),
                         ("continue", True))
        self.assertEqual(VC.follow_kind(_req(follow="continue"), "চালিয়ে যাও", self.s),
                         ("continue", True))

    def test_new_long_question_with_follow_flag_is_paid(self):
        self._asst(cut=True, credits=2)
        q = "Now write me a full 2000-word business plan for a tea stall in Mirpur " * 3
        self.assertEqual(VC.follow_kind(_req(follow="continue"), q, self.s), ("continue", False))

    def test_not_cut_is_paid(self):
        self._asst(cut=False, credits=2)
        self.assertEqual(VC.follow_kind(_req(follow="continue"), "Continue", self.s),
                         ("continue", False))

    def test_chain_of_free_continues_is_capped(self):
        self._asst(cut=True, credits=2)
        for _ in range(VC.MAX_FREE_CONTINUES - 1):
            self._asst(cut=True, credits=0, follow="continue")
        # 1 paid + (MAX-1) free continuations so far -> one more is still free
        self.assertTrue(VC.follow_kind(_req(follow="continue"), "Continue", self.s)[1])
        self._asst(cut=True, credits=0, follow="continue")
        # MAX free continuations in a row -> the next one is a normal turn
        self.assertFalse(VC.follow_kind(_req(follow="continue"), "Continue", self.s)[1])

    def test_paid_continue_starts_a_new_chain(self):
        self._asst(cut=True, credits=2)
        for _ in range(VC.MAX_FREE_CONTINUES):
            self._asst(cut=True, credits=0, follow="continue")
        self._asst(cut=True, credits=2, follow="continue")   # paid continuation
        self.assertTrue(VC.follow_kind(_req(follow="continue"), "Continue", self.s)[1])

    def test_continue_free_flag_shown_before_the_tap(self):
        self._asst(cut=True, credits=2)
        # a paid answer (or a paid Continue) starts a chain -> its Continue is free
        self.assertTrue(VC.next_continue_free(self.s, "", False))
        for _ in range(VC.MAX_FREE_CONTINUES - 2):
            self._asst(cut=True, credits=0, follow="continue")
        # this free continuation is number MAX-1 -> the next one is the last free
        self.assertTrue(VC.next_continue_free(self.s, "continue", True))
        self._asst(cut=True, credits=0, follow="continue")
        self.assertFalse(VC.next_continue_free(self.s, "continue", True))

    def test_cut_answer_meta_carries_continue_free(self):
        def fake(*a, **kw):
            kw["out_meta"].update(charged=1, truncated=True)
            return ("First part is complete. Second part is cu", 0.0)
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", side_effect=fake):
            _reply, meta, _ = VC._produce_reply(self.u, self.s, "explain", "en", [])
        self.assertTrue(meta["cut"])
        self.assertTrue(meta["continue_free"])


def _sse_done(resp):
    body = b"".join(resp.streaming_content).decode()
    for block in body.split("\n\n"):
        if block.startswith("event: done"):
            return json.loads(block.split("data: ", 1)[1])
    raise AssertionError("no done event")


class StreamMetaTests(TestCase):
    def test_streamed_cut_answer_carries_cut_and_hint(self):
        u = _u("+8801311990002")
        c = APIClient()
        c.force_authenticate(u)
        s = ChatSession.objects.create(user=u)
        meta = {"source": "ai", "credits": 2, "cut": True, "hint_better": True,
                "actions": ["reminders"], "ai_generated": True, "cost_usd": 0.01,
                "spend_ref": "secret"}
        with mock.patch.object(VC, "_produce_reply",
                               return_value=("First part is complete.", dict(meta), [])):
            r = c.post("/api/v1/chat/sessions/%d/stream" % s.id, {"text": "explain"},
                       format="json")
        done = _sse_done(r)
        m = done["meta"]
        self.assertTrue(m["cut"])
        self.assertTrue(m["hint_better"])
        self.assertEqual(m["actions"], ["reminders"])
        self.assertTrue(m["ai_generated"])
        self.assertNotIn("cost_usd", m)       # internals never leave the server
        self.assertNotIn("spend_ref", m)

    def test_stream_continue_after_cut_is_free(self):
        u = _u("+8801311990003")
        c = APIClient()
        c.force_authenticate(u)
        s = ChatSession.objects.create(user=u)
        ChatMessage.objects.create(session=s, role="user", text="explain")
        ChatMessage.objects.create(session=s, role="assistant", text="part one.",
                                   meta={"cut": True, "credits": 2, "source": "ai"})
        seen = {}

        def fake(*a, **kw):
            seen.update(kw)
            return ("And the rest.", {"source": "ai", "credits": 0, "follow": "continue"}, [])
        with mock.patch.object(VC, "_produce_reply", side_effect=fake):
            r = c.post("/api/v1/chat/sessions/%d/stream" % s.id,
                       {"text": "Continue", "follow": "continue"}, format="json")
        self.assertEqual(seen["follow"], "continue")
        self.assertTrue(seen["follow_free"])
        self.assertEqual(_sse_done(r)["meta"]["follow"], "continue")


class RegenerateContinueTests(TestCase):
    def test_regenerate_of_a_continue_turn_continues_with_the_level(self):
        u = _u("+8801311990004")
        c = APIClient()
        c.force_authenticate(u)
        s = ChatSession.objects.create(user=u)
        ChatMessage.objects.create(session=s, role="user", text="explain")
        ChatMessage.objects.create(session=s, role="assistant", text="part one.",
                                   meta={"cut": True, "credits": 2})
        ChatMessage.objects.create(session=s, role="user", text="Continue")
        ChatMessage.objects.create(session=s, role="assistant", text="rest",
                                   meta={"follow": "continue", "credits": 0})
        seen = {}

        def fake(*a, **kw):
            seen.update(kw)
            return ("Rest again.", {"source": "ai", "credits": 1}, [])
        with mock.patch.object(VC, "_produce_reply", side_effect=fake), \
                mock.patch.object(VC, "_chat_level", return_value="better"):
            r = c.post("/api/v1/chat/sessions/%d/regenerate" % s.id, {"level": "better"},
                       format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(seen["follow"], "continue")
        self.assertEqual(seen["level"], "better")
        self.assertFalse(seen.get("follow_free", False))   # a new version is a normal turn

    def test_regenerate_of_a_plain_turn_has_no_follow(self):
        u = _u("+8801311990005")
        c = APIClient()
        c.force_authenticate(u)
        s = ChatSession.objects.create(user=u)
        ChatMessage.objects.create(session=s, role="user", text="hello")
        ChatMessage.objects.create(session=s, role="assistant", text="hi", meta={"credits": 1})
        seen = {}

        def fake(*a, **kw):
            seen.update(kw)
            return ("Hi again.", {"source": "ai", "credits": 1}, [])
        with mock.patch.object(VC, "_produce_reply", side_effect=fake):
            c.post("/api/v1/chat/sessions/%d/regenerate" % s.id, {}, format="json")
        self.assertEqual(seen["follow"], "")


class PromptLanguageTests(TestCase):
    def test_guard_follows_the_users_language(self):
        s = AP.system_prompt()
        self.assertNotIn("Reply in Bangla unless asked otherwise", s)
        self.assertIn("language of the user's latest message", AP.INJECTION_GUARD)

    def test_english_task_and_guard_agree(self):
        t = VC.chat_task_text("en", None, minor=False, tools=False)
        self.assertIn("Reply in English", t)


class E2EFakeTests(TestCase):
    """The CI e2e fake behind flow e2e2c_ai_continue: a long plan is cut
    mid-word; the Continue turn (the product's Continue note) finishes it."""
    def test_long_plan_cut_then_continue(self):
        from ci_e2e import fakes
        first = fakes.answer_for("চায়ের দোকানের পুরো পরিকল্পনা লিখে দাও", "", [], "")
        self.assertTrue(first.endswith("কি"))                    # cut mid-word
        self.assertEqual(VC.end_at_sentence(first).splitlines()[-1],
                         "১. জায়গা বাছাই: অফিস বা স্কুলের কাছে ভাড়া নিন।")
        task = VC.chat_task_text("bn", None, minor=False, tools=False, follow="continue")
        nxt = fakes.answer_for("চালিয়ে যাও", "", [], task)
        self.assertTrue(nxt.startswith("২. সরঞ্জাম কিনুন"))


class HomeContinueTests(TestCase):
    def test_home_continue_gets_the_home_session_and_is_free(self):
        from core import views as V
        u = _u("+8801311990006")
        hs = ChatSession.objects.create(user=u, source="home")
        ChatMessage.objects.create(session=hs, role="user", text="explain")
        ChatMessage.objects.create(session=hs, role="assistant", text="part one.",
                                   meta={"cut": True, "credits": 2, "ad": True})
        c = APIClient()
        c.force_authenticate(u)
        with mock.patch.object(V.ai, "available", return_value=True), \
                mock.patch("core.views_chat._produce_reply",
                           return_value=("And the rest.", {"source": "ai", "credits": 0,
                                                            "follow": "continue"}, [])) as pr:
            r = c.post("/api/v1/agent", {"text": "Continue", "follow": "continue",
                                         "session_id": hs.id}, format="json")
        self.assertEqual(r.status_code, 200, r.content[:300])
        args, kw = pr.call_args
        self.assertEqual(args[1], hs)                 # session reaches the engine
        self.assertTrue(kw["follow_free"])
        self.assertEqual(r.json().get("follow"), "continue")


class CutBeforeGuardsTests(TestCase):
    """e2e run 44036417926 (flow e2e2c_ai_continue): a cut answer with a taka
    amount kept its mid-word end, because the money guard's note was added
    first and end_at_sentence then saw a full sentence at the end."""
    def test_cut_answer_with_money_ends_at_a_full_sentence(self):
        raw = ("ছোট চায়ের দোকান শুরু করতে প্রথম মাসে মোটামুটি ৩০,০০০ টাকা লাগে।\n"
               "১. জায়গা বাছাই: অফিস বা স্কুলের কাছে ভাড়া নিন।\n২. সরঞ্জাম কি")
        reply, _p, cut, _n = VC.finish_reply(raw, "চায়ের দোকানের পুরো পরিকল্পনা লিখে দাও",
                                             "bn", truncated=True)
        self.assertTrue(cut)
        self.assertNotIn("সরঞ্জাম কি", reply)
        self.assertIn("ভাড়া নিন।", reply)

    def test_not_cut_answer_is_untouched_by_the_cut_rule(self):
        reply, _p, cut, _n = VC.finish_reply("Step one is done. Step two is", "q", "en")
        self.assertFalse(cut)
        self.assertIn("Step two is", reply)


class FollowLanguageTests(TestCase):
    """e2e run 44056647414: in an English app the Continue tap sends
    "Continue" — the rest of a Bangla answer must stay Bangla."""
    def test_continue_label_follows_the_last_real_question(self):
        hist = [{"role": "user", "content": "চায়ের দোকানের পুরো পরিকল্পনা লিখে দাও"},
                {"role": "assistant", "content": "১. জায়গা বাছাই।"}]
        src = VC.follow_lang_source("Continue", hist, "continue")
        self.assertEqual(AP.reply_lang(src, "en"), "bn")
        self.assertEqual(AP.reply_lang(VC.follow_lang_source("More detail", hist, "more"), "en"),
                         "bn")
        # a normal turn keeps its own language
        self.assertEqual(VC.follow_lang_source("What about Chittagong?", hist, ""),
                         "What about Chittagong?")

    def test_engine_answers_continue_in_bangla(self):
        u = _u("+8801311990007")
        hist = [{"role": "user", "content": "চায়ের দোকানের পুরো পরিকল্পনা লিখে দাও"},
                {"role": "assistant", "content": "১. জায়গা বাছাই।"}]
        seen = {}

        def fake(*a, **kw):
            seen.update(kw)
            return ("২. সরঞ্জাম কিনুন।", 0.0)
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", side_effect=fake):
            VC._produce_reply(u, None, "Continue", "en", hist, follow="continue",
                              follow_free=True)
        task = seen.get("extra_system") or seen.get("task") or ""
        self.assertIn("ঠিক সেখান থেকে চালিয়ে যাও", task)

    def test_e2e_fake_continues_in_bangla_on_an_english_tap(self):
        from ci_e2e import fakes
        task = VC.chat_task_text("bn", None, minor=False, tools=False, follow="continue")
        self.assertTrue(fakes.answer_for("Continue", "", [], task).startswith("২."))
