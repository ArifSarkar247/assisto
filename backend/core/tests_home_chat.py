"""Home agent chat persists as a 'home' ChatSession (sidebar history)."""
from rest_framework.test import APITestCase

from core.models import User, ChatSession, ChatMessage


class HomeChatPersistTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="A", phone="01710000501", password="pw")
        self.client.force_authenticate(self.u)

    def test_first_turn_creates_home_session_then_reuses(self):
        r = self.client.post("/api/v1/agent", {"text": "remind me to call mom tomorrow 9am"},
                             format="json")
        self.assertEqual(r.status_code, 200)
        sid = r.data["session_id"]
        s = ChatSession.objects.get(pk=sid)
        self.assertEqual((s.source, s.user_id), ("home", self.u.id))
        self.assertTrue(s.title)
        r2 = self.client.post("/api/v1/agent", {"text": "what is my balance",
                                                "session_id": sid}, format="json")
        self.assertEqual(r2.data["session_id"], sid)
        msgs = list(ChatMessage.objects.filter(session=s).values_list("role", flat=True))
        self.assertEqual(msgs, ["user", "assistant", "user", "assistant"])
        first_reply = ChatMessage.objects.filter(session=s, role="assistant").first()
        self.assertIn("cards", first_reply.meta)

    def test_foreign_or_ai_session_id_not_reused(self):
        other = User.objects.create_user(name="B", phone="01710000502", password="pw")
        theirs = ChatSession.objects.create(user=other, source="home")
        mine_ai = ChatSession.objects.create(user=self.u, source="ai")
        for sid in (theirs.id, mine_ai.id):
            r = self.client.post("/api/v1/agent", {"text": "note buy milk", "session_id": sid},
                                 format="json")
            self.assertNotIn(r.data["session_id"], (theirs.id, mine_ai.id))
        self.assertFalse(ChatMessage.objects.filter(session=theirs).exists())

    def test_sessions_list_source_filter(self):
        ChatSession.objects.create(user=self.u, source="ai", title="ai one")
        ChatSession.objects.create(user=self.u, source="home", title="home one")
        r = self.client.get("/api/v1/chat/sessions?source=home")
        self.assertEqual([x["title"] for x in r.data["sessions"]], ["home one"])
        r = self.client.get("/api/v1/chat/sessions")
        self.assertEqual({x["source"] for x in r.data["sessions"]}, {"ai", "home"})
