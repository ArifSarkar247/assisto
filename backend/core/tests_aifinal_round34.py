"""aifinal rounds 3 + 4 (owner 4 Nov 00:47 / 00:50): finished answers
(cut -> end at a sentence + free Continue), best-answer style rule, one AI
brain for every chat message, data cards only when asked, no internal
words, full conversation memory with a running summary. Fake providers."""
from types import SimpleNamespace
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase

from core import ai_prompt as AP
from core import views_chat as VC
from core.models import ChatMessage, ChatSession


def _u(phone="+8801311000001"):
    return get_user_model().objects.create_user(name="z", phone=phone, password="pw12345!")


class StyleTests(TestCase):
    def test_best_answer_rule_and_language_rule_in_every_prompt(self):
        s = AP.system_prompt()
        for k in ("BEST possible", "short summary", "Bangladesh context", "next step",
                  "language of the user's latest message", "Never mention internal terms"):
            self.assertIn(k, s)


class CutTests(TestCase):
    def test_end_at_sentence_never_mid_word(self):
        t = "১. দাম লেখা থাকলে কিনুন। ২. দা"
        self.assertEqual(VC.end_at_sentence(t), "১. দাম লেখা থাকলে কিনুন।")
        self.assertEqual(VC.end_at_sentence("Step one is done. Step two is"), "Step one is done.")

    def test_truncated_answer_is_cut_flagged(self):
        u = _u()

        def fake(*a, **kw):
            kw["out_meta"].update(charged=1, truncated=True)
            return ("First part is complete. Second part is cu", 0.0)
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", side_effect=fake):
            reply, meta, _ = VC._produce_reply(u, None, "explain", "en", [])
        self.assertTrue(meta["cut"])
        self.assertTrue(reply.endswith("complete."))

    def test_continue_after_a_cut_answer_is_free(self):
        u = _u("+8801311000002")
        s = ChatSession.objects.create(user=u)
        ChatMessage.objects.create(session=s, role="assistant", text="part", meta={"cut": True})
        req = SimpleNamespace(data={"follow": "continue"}, query_params={})
        self.assertEqual(VC.follow_kind(req, "Continue", s), ("continue", True))
        req2 = SimpleNamespace(data={}, query_params={})
        self.assertEqual(VC.follow_kind(req2, "that was incomplete", s), ("continue", True))
        seen = {}

        def fake(*a, **kw):
            seen.update(kw)
            return ("…and the rest.", 0.0)
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", side_effect=fake):
            VC._produce_reply(u, s, "Continue", "en", [], follow="continue", follow_free=True)
        self.assertIsNone(seen["user"])                      # no charge
        self.assertIn("do not repeat", seen["task"])


class OneBrainTests(TestCase):
    def test_internal_words_scrubbed(self):
        out = VC.scrub_internal("You asked about Gazipur. There is a memory item but I cannot see it. "
                                "It is 35 km away.")
        self.assertNotIn("memory item", out)
        self.assertIn("35 km", out)

    def test_data_cards_only_when_asked(self):
        ctx = {"level": "L1", "cards": [{"type": "summary", "title": "Balance ৳2200"}]}
        self.assertEqual(VC._data_cards(ctx, "you are a donkey"), [])
        self.assertEqual(len(VC._data_cards(ctx, "what is my balance?")), 1)
        self.assertEqual(VC._data_cards({"level": "L4", "cards": [{"type": "x"}]}, "hi"), [])

    def test_ambiguous_home_message_goes_to_the_ai(self):
        from core import views as V
        u = _u("+8801311000003")
        with mock.patch.object(V.ai, "available", return_value=True), \
                mock.patch("core.views_chat._produce_reply",
                           return_value=("ঠিক আছে, শান্ত থাকুন।", {"source": "ai", "credits": 1}, [])) as pr:
            from rest_framework.test import APIClient
            c = APIClient()
            c.force_authenticate(u)
            r = c.post("/api/v1/agent", {"text": "apnake j baniyece se akta gadha"}, format="json")
        self.assertEqual(r.status_code, 200, r.content[:300])
        body = r.json()
        self.assertTrue(pr.called)
        self.assertNotIn("owner", body["reply"])
        self.assertFalse(any(c.get("type") == "note" or "note" in str(c.get("app_action", ""))
                             for c in body["cards"]))


class MemoryTests(TestCase):
    def test_long_chat_keeps_a_running_summary(self):
        u = _u("+8801311000004")
        s = ChatSession.objects.create(user=u)
        ChatMessage.objects.create(session=s, role="user", text="My son Rafi is 9 years old.")
        for i in range(30):
            ChatMessage.objects.create(session=s, role="assistant" if i % 2 == 0 else "user",
                                       text="turn %d" % i)
        h = VC._history_for(s)
        self.assertIn("Rafi", h[0]["content"])
        self.assertIn("Summary", h[0]["content"])
