"""missing (owner 2 Nov): Owner Admin -> Missing alerts (queue, hide /
restore / remove + ban, audit, bn/en, GD honesty line)."""
from django.utils import timezone

from core.models import MissingAlert, MissingEvent, MissingReport, OwnerAudit, User
from web.tests_o2_owner_admin import OwnerBase, SClient


class MissingOwnerTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.poster = User.objects.create_user(name="Poster", phone="01799000001", password="x")
        self.rep = User.objects.create_user(name="Rep", phone="01799000002", password="x")
        self.a = MissingAlert.objects.create(
            poster=self.poster, name="Karim", age=34, area_text="Mirpur 10", district="dhaka",
            last_seen_at=timezone.now(), state="hidden", hidden_from="active", basis="gd",
            gd_number="12", gd_thana="Mirpur")
        MissingReport.objects.create(alert=self.a, reporter=self.rep, reason="fake", note="liar")
        self.ready()

    def test_queue_lists_hidden_with_reports(self):
        r = self.c.get("/owner/missing?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Karim")
        self.assertContains(r, "liar")
        self.assertContains(r, "GD number not verified")
        r = self.c.get("/owner/missing?lang=bn&status=bogus")
        self.assertContains(r, "নিখোঁজ সতর্কতা")

    def test_restore_and_remove_ban_audited(self):
        r = self.post("/owner/missing/%d/act" % self.a.pk, {"action": "restore"})
        self.assertEqual(r.status_code, 302)
        self.a.refresh_from_db()
        self.assertEqual(self.a.state, "active")
        self.post("/owner/missing/%d/act" % self.a.pk, {"action": "remove_ban"})
        self.a.refresh_from_db()
        self.assertEqual(self.a.state, "removed")
        self.assertTrue(MissingEvent.objects.filter(kind="poster_banned", actor=self.poster).exists())
        self.assertTrue(OwnerAudit.objects.filter(action="missing_alert.remove_ban").exists())
        r = self.post("/owner/missing/%d/act" % self.a.pk, {"action": "bogus"})
        self.assertIn("m=invalid", r["Location"])
        self.assertEqual(self.post("/owner/missing/99999/act", {"action": "hide"}).status_code, 404)

    def test_requires_owner(self):
        r = SClient().get("/owner/missing")
        self.assertEqual((r.status_code, r["Location"]), (302, "/owner/login"))
