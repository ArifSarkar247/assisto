"""aivoice — GET /api/v1/chat/status: the honest no-key state of the AI chat.

The app shows a "no AI key yet — this still works free" banner ONLY when the
server says ai_available is False; it must never claim AI the server cannot
deliver, and a no-key chat must still answer (free Brain, never charged).

Run: manage.py test core.tests_aivoice --settings=assisto_backend.settings_test
"""
from unittest import mock

from django.test import TestCase
from rest_framework.test import APIClient

from core import ai
from core.models import ChatSession, User
from core.views_chat import FREE_WITHOUT_KEY, chat_status_payload

URL = "/api/v1/chat/status"


class ChatStatusTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Rina", phone="01710009001",
                                          password="pw12345!", language="bn")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_requires_login(self):
        self.assertIn(APIClient().get(URL).status_code, (401, 403))

    def test_no_key(self):
        with mock.patch.object(ai, "available", return_value=False), \
                mock.patch.object(ai, "key_present", return_value=False):
            r = self.c.get(URL)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json(), {"ai_available": False, "reason": "no_key",
                                    "free": list(FREE_WITHOUT_KEY)})

    def test_key_but_paused(self):
        # key present but daily cap / kill switch -> honest 'paused', not 'no_key'
        with mock.patch.object(ai, "available", return_value=False), \
                mock.patch.object(ai, "key_present", return_value=True):
            r = self.c.get(URL).json()
        self.assertFalse(r["ai_available"])
        self.assertEqual(r["reason"], "paused")

    def test_available(self):
        with mock.patch.object(ai, "available", return_value=True):
            r = self.c.get(URL).json()
        self.assertTrue(r["ai_available"])
        self.assertIsNone(r["reason"])

    def test_error_never_claims_ai(self):
        with mock.patch.object(ai, "available", side_effect=RuntimeError("x")):
            p = chat_status_payload()
        self.assertFalse(p["ai_available"])
        self.assertEqual(p["reason"], "paused")

    def test_free_codes_are_stable(self):
        # the app maps these codes to bn/en lines; renaming one breaks the banner
        self.assertEqual(set(FREE_WITHOUT_KEY),
                         {"own_data", "app_help", "phone_commands", "voice_input"})

    def test_live_default_matches_send(self):
        # the test settings have no AI key: status says no AI AND a real send
        # is answered by the free Brain (source 'brain', 0 credits) — the
        # banner and the reply chip can never disagree.
        st = self.c.get(URL).json()
        self.assertFalse(st["ai_available"])
        s = ChatSession.objects.create(user=self.u, title="")
        r = self.c.post("/api/v1/chat/sessions/%d/send" % s.id,
                        {"text": "আজ কত খরচ হলো?"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        msg = body["message"]
        self.assertTrue((msg.get("text") or "").strip())
        self.assertEqual(msg["meta"].get("source"), "brain")
        self.assertEqual(msg["meta"].get("credits", 0), 0)
        self.assertFalse(body["ai_used"])


class ChatStreamShapeTests(TestCase):
    """aivoice bug fix: the SSE token events carried only {"text"}, but the
    app reads "chunk" — every streamed reply in Assisto AI rendered EMPTY.
    Tokens now carry chunk (+ text), and done carries the full text."""

    def setUp(self):
        self.u = User.objects.create_user(name="Rina", phone="01710009002",
                                          password="pw12345!", language="bn")
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        self.s = ChatSession.objects.create(user=self.u, title="")

    def _events(self, text):
        import json
        r = self.c.post("/api/v1/chat/sessions/%d/stream" % self.s.id,
                        {"text": text}, format="json")
        self.assertEqual(r.status_code, 200)
        raw = b"".join(r.streaming_content).decode("utf-8")
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

    def test_tokens_have_chunk_and_join_to_reply(self):
        evs = self._events("আজ কত খরচ হলো?")
        toks = [d for e, d in evs if e == "token"]
        done = [d for e, d in evs if e == "done"]
        self.assertTrue(toks)
        self.assertEqual(len(done), 1)
        for d in toks:
            self.assertIn("chunk", d)
            self.assertEqual(d["chunk"], d["text"])
        joined = "".join(d["chunk"] for d in toks)
        self.assertTrue(joined.strip())
        self.assertEqual(done[0]["text"], joined)
        self.assertEqual(done[0]["source"], "brain")
        stored = self.s.messages.filter(role="assistant").get()
        self.assertEqual(stored.text, joined)
        self.assertEqual(done[0]["message_id"], stored.id)
