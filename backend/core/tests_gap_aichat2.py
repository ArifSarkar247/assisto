"""gap-aichat2 (lead P0 from the release gate, 17 Nov):
1. live 10338: "চায়ে ৫০ টাকা খরচ লিখে রাখো" got no confirm card when the real
   model skipped the ACTION line -> server safety net builds the same
   proposal (still needs the user's Yes; nothing is written by itself);
2. the app's stream requests send `Accept: text/event-stream` and DRF
   answered 406 -> home chat / Assisto AI never streamed. Fake providers."""
import json
from io import StringIO
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase
from rest_framework.test import APIClient

from core import ai_tools as AT
from core import views_chat as VC
from core.models import ChatMessage, ChatSession, PaCollectionItem, Transaction

POSITIVE = [
    ("চায়ে ৫০ টাকা খরচ লিখে রাখো", "expense", "50"),
    ("50 tk khoroch likhe rakho", "expense", "50"),
    ("cha te 30 tk khoroch", "expense", "30"),
    ("spent 200 taka on lunch, note it", "expense", "200"),
    ("আজ বাজারে ১,২০০ টাকা খরচ হলো, হিসাবে যোগ করো", "expense", "1200"),
    ("রিকশা ভাড়া ৪০ টাকা দিলাম লিখে রাখো", "expense", "40"),
    ("বেতন ২০০০০ টাকা পেলাম লিখে রাখো", "income", "20000"),
    ("Log 1500 taka income from tuition", "income", "1500"),
    ("2k taka khoroch hoise bazar e, likhe rakho", "expense", "2000"),
]
NEGATIVE = [
    "এ মাসে কত খরচ হলো?",
    "৫০০ টাকা দিয়ে কী কিনব?",
    "কাল সকাল ৯টায় ৫০ টাকা দেওয়ার কথা মনে করিয়ে দিও",
    "how much did I spend?",
    "রহিমকে ৫০০ টাকা ধার দিলাম লিখে রাখো",
    "I spent 50 taka and earned 100 taka",
    "500 taka is a lot for tea",
    "ami 50 taka khoroch korbo naki?",
    "চায়ের দোকানের পুরো পরিকল্পনা লিখে দাও",
]


def _u(phone):
    return get_user_model().objects.create_user(name="g", phone=phone, password="pw12345!")


class SafetyNetRuleTests(TestCase):
    def test_unambiguous_money_logs_become_proposals(self):
        for text, kind, amount in POSITIVE:
            p = AT.money_safety_net(text)
            self.assertIsNotNone(p, text)
            self.assertEqual((p["type"], p["amount"].split(".")[0]), (kind, amount), text)

    def test_questions_reminders_loans_and_mixed_are_left_alone(self):
        for text in NEGATIVE:
            self.assertIsNone(AT.money_safety_net(text), text)

    def test_tool_rule_names_the_money_case(self):
        self.assertIn("চায়ে ৫০ টাকা খরচ লিখে রাখো", AT.TOOL_RULE)
        self.assertIn("MUST end with ONE line", AT.TOOL_RULE)


class SafetyNetEngineTests(TestCase):
    def _run(self, u, text, model_reply):
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", return_value=(model_reply, 0.0)):
            return VC._produce_reply(u, None, text, "bn", [])

    def test_model_without_action_line_still_gets_the_confirm_card(self):
        u = _u("+8801311991001")
        reply, meta, cards = self._run(u, "চায়ে ৫০ টাকা খরচ লিখে রাখো",
                                       "ঠিক আছে, চায়ের খরচটা হিসাবে রাখার জন্য নিচে নিশ্চিত করুন।")
        conf = [c for c in cards if c.get("type") == "confirm_action"]
        self.assertEqual(len(conf), 1)
        self.assertEqual(conf[0]["action"], "expense")
        self.assertIn("50", conf[0]["title"])
        self.assertEqual(Transaction.objects.filter(user=u).count(), 0)   # never written alone
        row = PaCollectionItem.objects.get(user=u, collection=AT.PENDING)
        self.assertTrue(row.data["p"]["safety_net"])
        # Yes writes it exactly once
        st, body = AT.confirm(u, conf[0]["pending_id"], True)
        self.assertEqual(st, 200)
        self.assertEqual(Transaction.objects.filter(user=u, kind="expense").count(), 1)

    def test_model_action_line_wins(self):
        u = _u("+8801311991002")
        _r, _m, cards = self._run(
            u, "চায়ে ৫০ টাকা খরচ লিখে রাখো",
            'নিশ্চিত করুন।\nACTION: {"type": "expense", "amount": 50, "category": "চা"}')
        conf = [c for c in cards if c.get("type") == "confirm_action"]
        self.assertEqual(len(conf), 1)
        row = PaCollectionItem.objects.get(user=u, collection=AT.PENDING)
        self.assertNotIn("safety_net", row.data["p"])

    def test_a_question_gets_no_card(self):
        u = _u("+8801311991003")
        _r, _m, cards = self._run(u, "এ মাসে কত খরচ হলো?", "এ মাসে আপনার খরচ…")
        self.assertFalse([c for c in cards if c.get("type") == "confirm_action"])


def _sse_done(resp):
    body = b"".join(resp.streaming_content).decode()
    for block in body.split("\n\n"):
        if block.startswith("event: done"):
            return json.loads(block.split("data: ", 1)[1])
    raise AssertionError("no done event: %r" % body[:200])


class StreamAcceptTests(TestCase):
    """The app sends Accept: text/event-stream — that must not be a 406."""
    SSE = {"HTTP_ACCEPT": "text/event-stream"}

    def setUp(self):
        self.u = _u("+8801311991004")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_chat_stream_accepts_event_stream(self):
        s = ChatSession.objects.create(user=self.u)
        with mock.patch.object(VC, "_produce_reply",
                               return_value=("Done.", {"source": "ai", "credits": 1}, [])):
            r = self.c.post("/api/v1/chat/sessions/%d/stream" % s.id, {"text": "hi"},
                            format="json", **self.SSE)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r["Content-Type"].startswith("text/event-stream"))
        self.assertEqual(_sse_done(r)["text"], "Done.")

    def test_agent_stream_accepts_event_stream_and_keeps_cut_meta(self):
        from core import views as V
        meta = {"source": "ai", "credits": 1, "cut": True, "continue_free": True}
        with mock.patch.object(V.ai, "available", return_value=True), \
                mock.patch("core.views_chat._produce_reply",
                           return_value=("First part is complete.", meta, [])):
            r = self.c.post("/api/v1/agent/stream", {"text": "explain the whole plan please"},
                            format="json", **self.SSE)
        self.assertEqual(r.status_code, 200, getattr(r, "content", b"")[:300])
        self.assertTrue(r["Content-Type"].startswith("text/event-stream"))
        done = _sse_done(r)
        self.assertTrue(done.get("cut"))

    def test_error_with_event_stream_accept_is_readable_json(self):
        r = self.c.post("/api/v1/chat/sessions/%d/stream" % 999999, {"text": "hi"},
                        format="json", **self.SSE)
        self.assertEqual(r.status_code, 404)          # not 406
        self.assertIn("detail", json.loads(r.content.decode()))

    def test_empty_text_400_is_json_text(self):
        s = ChatSession.objects.create(user=self.u)
        r = self.c.post("/api/v1/chat/sessions/%d/stream" % s.id, {"text": ""},
                        format="json", **self.SSE)
        self.assertEqual(r.status_code, 400)
        self.assertIn("detail", json.loads(r.content.decode()))


class GapCountTests(TestCase):
    def test_counts_only_and_read_only(self):
        u = _u("+8801311991005")
        s = ChatSession.objects.create(user=u)
        ChatMessage.objects.create(session=s, role="user", text="চায়ে ৫০ টাকা খরচ লিখে রাখো")
        ChatMessage.objects.create(session=s, role="user", text="hello")
        AT.propose(u, {"type": "expense", "amount": "50.00", "category": "চা"}, "bn")
        out = StringIO()
        call_command("ai_action_gap", "--days", "7", stdout=out)
        line = out.getvalue()
        self.assertIn("user_turns=2", line)
        self.assertIn("money_log_turns=1", line)
        self.assertIn("money_proposals=1", line)
        self.assertNotIn("চা", line)                  # numbers only
