"""ai-report: Owner Admin -> AI reports (list, filter, resolve/re-open, audit)."""
from core.models import AiAnswerReport, OwnerAudit, User
from web.tests_o2_owner_admin import OwnerBase, SClient


class AiReportsPanelTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.u = User.objects.create_user(name="Rina", phone="01711000311", password="x")
        self.a = AiAnswerReport.objects.create(user=self.u, reason="offensive",
                                               answer_text="very rude answer", note="rude")
        self.b = AiAnswerReport.objects.create(user=self.u, reason="wrong", surface="photo",
                                               answer_text="wrong medicine name",
                                               status="resolved")
        self.ready()

    def test_list_default_open_and_filters(self):
        r = self.c.get("/owner/ai-reports?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "AI reports")
        self.assertContains(r, "very rude answer")
        self.assertNotContains(r, "wrong medicine name")
        r = self.c.get("/owner/ai-reports?lang=en&status=all&reason=wrong")
        self.assertContains(r, "wrong medicine name")
        self.assertNotContains(r, "very rude answer")
        r = self.c.get("/owner/ai-reports?lang=bn&status=bogus")
        self.assertContains(r, "AI রিপোর্ট")
        self.assertContains(r, "very rude answer")

    def test_resolve_and_reopen_audited(self):
        r = self.post("/owner/ai-reports/%d/resolve" % self.a.pk,
                      {"next": "/owner/ai-reports?status=open"})
        self.assertEqual(r.status_code, 302)
        self.assertTrue(r["Location"].startswith("/owner/ai-reports?status=open"))
        self.a.refresh_from_db()
        self.assertEqual((self.a.status, self.a.resolved_by), ("resolved", self.owner))
        self.assertIsNotNone(self.a.resolved_at)
        row = OwnerAudit.objects.get(action="ai_report.resolve")
        self.assertEqual(row.target, "ai_report:%d" % self.a.pk)
        self.assertEqual((row.before["status"], row.after["status"]), ("open", "resolved"))
        self.post("/owner/ai-reports/%d/resolve" % self.a.pk, {"undo": "1"})
        self.a.refresh_from_db()
        self.assertEqual((self.a.status, self.a.resolved_at), ("open", None))
        # open redirect is refused
        r = self.post("/owner/ai-reports/%d/resolve" % self.a.pk, {"next": "https://evil"})
        self.assertTrue(r["Location"].startswith("/owner/ai-reports"))
        self.assertEqual(self.post("/owner/ai-reports/99999/resolve").status_code, 404)

    def test_requires_owner_and_csrf(self):
        anon = SClient()
        r = anon.get("/owner/ai-reports")
        self.assertEqual((r.status_code, r["Location"]), (302, "/owner/login"))
        r = self.c.post("/owner/ai-reports/%d/resolve" % self.a.pk, {})
        self.assertEqual(r.status_code, 403)
        self.assertEqual(self.c.get("/owner/ai-reports/%d/resolve" % self.a.pk).status_code, 405)
