"""ai-report: users can report / flag an AI answer from inside the app (Google
Play AI-Generated Content policy). POST/GET /api/v1/chat/report."""
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient
from django.test import TestCase

from core import views_chat
from core.models import AiAnswerReport, ChatMessage, ChatSession, User


def _api(u, lang="en"):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.get_or_create(user=u)[0].key,
                  HTTP_ACCEPT_LANGUAGE=lang)
    return c


class AiReportApiTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Rina", phone="01711000301", password="x")
        self.other = User.objects.create_user(name="Karim", phone="01711000302", password="x")
        self.c = _api(self.u)
        s = ChatSession.objects.create(user=self.u, source="ai")
        ChatMessage.objects.create(session=s, role="user", text="hi")
        self.ans = ChatMessage.objects.create(session=s, role="assistant",
                                              text="A rude AI answer")
        os_ = ChatSession.objects.create(user=self.other, source="ai")
        self.foreign = ChatMessage.objects.create(session=os_, role="assistant",
                                                  text="someone else's answer")

    def test_create_from_stored_message_uses_server_snapshot(self):
        r = self.c.post("/api/v1/chat/report", {
            "message_id": self.ans.id, "reason": "offensive", "note": "bad words",
            "text": "the app could send anything here"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["reason"], "offensive")
        row = AiAnswerReport.objects.get()
        self.assertEqual((row.user, row.message, row.answer_text, row.note, row.status),
                         (self.u, self.ans, "A rude AI answer", "bad words", "open"))
        self.assertEqual(row.session_id_ref, str(self.ans.session_id))
        self.assertIsNotNone(row.created_at)

    def test_duplicate_report_of_same_message_is_idempotent(self):
        body = {"message_id": self.ans.id, "reason": "wrong"}
        self.assertEqual(self.c.post("/api/v1/chat/report", body, format="json").status_code, 201)
        r = self.c.post("/api/v1/chat/report", body, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["duplicate"])
        self.assertEqual(AiAnswerReport.objects.count(), 1)

    def test_text_snapshot_for_unsaved_answers(self):
        r = self.c.post("/api/v1/chat/report", {
            "surface": "photo", "reason": "harmful", "text": "x" * 9000}, format="json")
        self.assertEqual(r.status_code, 201)
        row = AiAnswerReport.objects.get()
        self.assertEqual(row.surface, "photo")
        self.assertIsNone(row.message)
        self.assertEqual(len(row.answer_text), 4000)
        # unknown surface is stored as "other", never rejected
        r = self.c.post("/api/v1/chat/report", {
            "surface": "weird", "reason": "other", "text": "t"}, format="json")
        self.assertEqual(AiAnswerReport.objects.get(pk=r.json()["id"]).surface, "other")

    def test_validation(self):
        r = self.c.post("/api/v1/chat/report", {"message_id": self.ans.id,
                                                "reason": "spam"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["code"], "bad_reason")
        r = self.c.post("/api/v1/chat/report", {"reason": "other"}, format="json")
        self.assertEqual((r.status_code, r.json()["code"]), (400, "no_text"))
        r = self.c.post("/api/v1/chat/report", {"message_id": "abc", "reason": "other"},
                        format="json")
        self.assertEqual(r.status_code, 404)
        bn = _api(self.u, "bn").post("/api/v1/chat/report", {"reason": "x"}, format="json")
        self.assertEqual(bn.json()["detail"], "একটি কারণ বেছে নিন।")

    def test_cannot_report_or_read_other_users_messages(self):
        r = self.c.post("/api/v1/chat/report", {"message_id": self.foreign.id,
                                                "reason": "offensive"}, format="json")
        self.assertEqual(r.status_code, 404)
        # a user-role message is not an AI answer
        um = ChatMessage.objects.filter(role="user").first()
        r = self.c.post("/api/v1/chat/report", {"message_id": um.id,
                                                "reason": "offensive"}, format="json")
        self.assertEqual(r.status_code, 404)
        AiAnswerReport.objects.create(user=self.other, reason="harmful",
                                      answer_text="karim's secret report")
        self.c.post("/api/v1/chat/report", {"message_id": self.ans.id,
                                            "reason": "wrong"}, format="json")
        r = self.c.get("/api/v1/chat/report")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.json()["results"]), 1)
        self.assertNotIn(b"karim", r.content)
        self.assertNotIn(b"answer_text", r.content)   # list never echoes text

    def test_requires_login(self):
        self.assertIn(APIClient().post("/api/v1/chat/report", {"reason": "other",
                                                               "text": "t"}).status_code,
                      (401, 403))

    def test_rate_limit_per_hour(self):
        for i in range(views_chat.AI_REPORT_PER_HOUR):
            r = self.c.post("/api/v1/chat/report", {"reason": "other", "text": "a%d" % i},
                            format="json")
            self.assertEqual(r.status_code, 201)
        r = self.c.post("/api/v1/chat/report", {"reason": "other", "text": "one more"},
                        format="json")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["code"], "rate_limited")
        self.assertEqual(r["Retry-After"], "3600")
        self.assertEqual(AiAnswerReport.objects.count(), views_chat.AI_REPORT_PER_HOUR)
        # another user is not affected
        r = _api(self.other).post("/api/v1/chat/report", {"reason": "other", "text": "z"},
                                  format="json")
        self.assertEqual(r.status_code, 201)

    def test_home_agent_reply_carries_reportable_message_id(self):
        r = self.c.post("/api/v1/agent", {"text": "hello there"}, format="json")
        self.assertEqual(r.status_code, 200)
        mid = r.json().get("message_id")
        self.assertIsNotNone(mid)
        m = ChatMessage.objects.get(pk=mid)
        self.assertEqual((m.role, m.session.user, m.session.source), ("assistant", self.u, "home"))
        r = self.c.post("/api/v1/chat/report", {"message_id": mid, "reason": "wrong"},
                        format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(AiAnswerReport.objects.get().answer_text, m.text)

    def test_privacy_policy_mentions_review(self):
        from core import legal
        _, en = legal._privacy("en")
        _, bn = legal._privacy("bn")
        self.assertTrue(any("reviews reported answers" in x["body"] for x in en))
        self.assertTrue(any("পর্যালোচনা" in x["body"] for x in bn))
        r = self.client.get("/privacy?lang=en", secure=True)
        if r.status_code == 200:
            self.assertContains(r, "reviews reported answers")
