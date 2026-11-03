"""aileft: home chat streaming (POST /agent/stream) + Stop that charges only
what was delivered (POST /chat/stop, core/chat_stop.py). Fake providers only."""
import json
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from core import billing
from core import chat_stop as CS
from core.models import ChatMessage, ChatSession


def _u(phone):
    return get_user_model().objects.create_user(name="Arif", phone=phone, password="pw12345!")


def _bal(u):
    u.refresh_from_db(fields=["ai_credits"])
    return int(u.ai_credits or 0)


class RuleTests(TestCase):
    def test_rule(self):
        self.assertEqual(CS.charge_for(10, 0, 1000), 0)          # nothing shown
        self.assertEqual(CS.charge_for(10, 100, 1000), 0)        # < 120 chars
        self.assertEqual(CS.charge_for(10, 140, 1000), 0)        # < 15 %
        self.assertEqual(CS.charge_for(10, 500, 1000), 5)        # delivered share
        self.assertEqual(CS.charge_for(10, 510, 1000), 6)        # rounded up
        self.assertEqual(CS.charge_for(10, 1000, 1000), 10)      # all shown = full
        self.assertEqual(CS.charge_for(10, 5000, 1000), 10)      # never more
        self.assertEqual(CS.charge_for(0, 500, 1000), 0)         # free answer stays free
        # abuse guard: after the daily free stops, a delivered bit costs 1
        self.assertEqual(CS.charge_for(10, 100, 1000, CS.FREE_STOPS_PER_DAY), 1)
        self.assertEqual(CS.charge_for(10, 0, 1000, CS.FREE_STOPS_PER_DAY), 0)


class StopTests(TestCase):
    def setUp(self):
        self.u = _u("+8801411000201")
        billing.credit(self.u, "topup", 50, note="pack:test")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def _answer(self, cid, text, credits=10, source="home"):
        res = billing.charge(self.u, "ai_level_better", exact=credits, paid_only=True,
                             note="chat.better")
        self.assertTrue(res["ok"], res)
        s = ChatSession.objects.create(user=self.u, source=source)
        ChatMessage.objects.create(session=s, role="user", text="q",
                                   meta={"client_id": cid})
        return ChatMessage.objects.create(
            session=s, role="assistant", text=text,
            meta={"source": "ai", "credits": credits, "level": "better",
                  "spend_ref": res.get("spend_ref", "")})

    def test_stop_before_anything_shown_refunds_all(self):
        a = self._answer("aileft-cid-1", "x " * 500)
        self.assertEqual(_bal(self.u), 40)
        r = self.c.post("/api/v1/chat/stop", {"client_id": "aileft-cid-1", "shown_chars": 0},
                        format="json")
        self.assertEqual(r.status_code, 200, r.content[:300])
        self.assertEqual((r.json()["credits"], r.json()["refunded"]), (0, 10))
        self.assertEqual(_bal(self.u), 50)
        a.refresh_from_db()
        self.assertTrue(a.meta["stopped"])
        self.assertEqual(a.text, "")
        # idempotent: a second Stop changes nothing
        self.c.post("/api/v1/chat/stop", {"client_id": "aileft-cid-1", "shown_chars": 0}, format="json")
        self.assertEqual(_bal(self.u), 50)

    def test_stop_half_way_pays_the_delivered_share(self):
        a = self._answer("aileft-cid-2", "word " * 200, source="ai")          # 1000 chars
        r = self.c.post("/api/v1/chat/stop", {"client_id": "aileft-cid-2", "shown_chars": 500},
                        format="json")
        self.assertEqual(r.json()["credits"], 5)
        self.assertEqual(_bal(self.u), 45)
        a.refresh_from_db()
        self.assertLessEqual(len(a.text), 500)          # history = what was seen
        self.assertEqual(a.meta["credits"], 5)          # bubble == ledger

    def test_stop_while_answer_in_flight_is_applied_when_saved(self):
        r = self.c.post("/api/v1/chat/stop", {"client_id": "aileft-cid-3", "shown_chars": 0},
                        format="json")
        self.assertTrue(r.json()["pending"])
        a = self._answer("aileft-cid-3", "y" * 800)
        out = CS.after_turn(self.u, "aileft-cid-3", a.id)
        self.assertEqual(out["refunded"], 10)
        self.assertEqual(_bal(self.u), 50)
        self.assertIsNone(CS.after_turn(self.u, "aileft-cid-3", a.id))   # parked row cleared

    def test_other_users_answer_is_never_touched(self):
        a = self._answer("aileft-cid-4", "z" * 800)
        other = APIClient()
        other.force_authenticate(_u("+8801411000202"))
        other.post("/api/v1/chat/stop", {"client_id": "aileft-cid-4", "shown_chars": 0}, format="json")
        a.refresh_from_db()
        self.assertFalse(a.meta.get("stopped"))
        self.assertEqual(_bal(self.u), 40)

    def test_client_id_required(self):
        r = self.c.post("/api/v1/chat/stop", {"shown_chars": 3}, format="json")
        self.assertEqual(r.status_code, 400)


class HomeStreamTests(TestCase):
    def test_agent_stream_sends_tokens_then_the_full_agent_body(self):
        u = _u("+8801411000210")
        c = APIClient()
        c.force_authenticate(u)
        answer = "সারাংশ: " + "ভালো উত্তর। " * 40
        with mock.patch("core.ai.available", return_value=True), \
                mock.patch("core.ai.generate", return_value=(answer, 0.0)):
            r = c.post("/api/v1/agent/stream", {"text": "ঢাকায় ভালো স্কুল কোনটা?",
                                                "client_id": "aileft-s-0001"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "text/event-stream")
        raw = b"".join(r.streaming_content).decode()
        events = [blk for blk in raw.split("\n\n") if blk.strip()]
        self.assertTrue(events[0].startswith("event: token"))
        self.assertGreater(len(events), 2)              # chunked, not one blob
        done = events[-1]
        self.assertTrue(done.startswith("event: done"))
        body = json.loads(done.split("data: ", 1)[1])
        self.assertEqual(body["text"], body["reply"])
        self.assertTrue(body["session_id"])
        self.assertTrue(body["message_id"])
        toks = "".join(json.loads(e.split("data: ", 1)[1])["chunk"] for e in events[:-1])
        self.assertEqual(toks, body["reply"])
        # the same client id replays (POST /agent fallback never answers twice)
        with mock.patch("core.ai.available", return_value=True), \
                mock.patch("core.ai.generate", side_effect=AssertionError("no 2nd call")):
            r2 = c.post("/api/v1/agent", {"text": "ঢাকায় ভালো স্কুল কোনটা?",
                                          "client_id": "aileft-s-0001"}, format="json")
        self.assertTrue(r2.json()["replayed"])

    def test_agent_stream_out_of_credits_is_plain_json(self):
        u = _u("+8801411000211")
        c = APIClient()
        c.force_authenticate(u)
        from core import credits_out
        with mock.patch("core.ai.available", return_value=True), \
                mock.patch("core.views_chat._produce_reply",
                           side_effect=credits_out.CreditsOut(4)):
            r = c.post("/api/v1/agent/stream", {"text": "hello"}, format="json",
                       HTTP_X_ASSISTO_CREDOUT="1")
        self.assertNotEqual(r.get("Content-Type"), "text/event-stream")
