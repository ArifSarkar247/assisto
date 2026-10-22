"""f1-founders: owner panel — Founding Members (preview → confirm → apply,
revoke, audit, any-format numbers) and Feedback (list/filter, detail with a
signed screenshot, status + owner note audited, CSV export)."""
import base64
import shutil
import tempfile

from django.core.files.base import ContentFile
from django.test import override_settings

from core.models import FeedbackReport, OwnerAudit, User
from web.tests_o2_owner_admin import OwnerBase, SClient, _ot


class FoundersPanelTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.a = User.objects.create_user(name="Rina", phone="01711000101", password="x")
        self.b = User.objects.create_user(name="Karim", phone="01811000102", password="x")
        self.ready()

    def test_pages_render_bn_en(self):
        for url in ("/owner/founders", "/owner/feedback"):
            r = self.c.get(url + "?lang=en")
            self.assertEqual(r.status_code, 200, url)
            self.assertContains(r, "Log out")
            r = self.c.get(url + "?lang=bn")
            self.assertContains(r, "লগআউট")
        self.assertContains(self.c.get("/owner/founders?lang=en"), "Free Premium (months)")

    def test_preview_changes_nothing_and_reports_unknown(self):
        r = self.post("/owner/founders?lang=en", {
            "action": "preview",
            "numbers": "+880 1711-000101\n8801811000102, 01999999999\nnot-a-number"})
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Rina")
        self.assertContains(r, "Karim")
        self.assertContains(r, "01999999999")
        self.assertContains(r, "not-a-number")
        self.assertContains(r, "No Assisto account uses these numbers yet")
        self.a.refresh_from_db()
        self.assertFalse(self.a.is_founder)
        self.assertFalse(OwnerAudit.objects.filter(action__startswith="founders").exists())

    def test_apply_needs_reason_and_confirm(self):
        r = self.post("/owner/founders?lang=en", {"action": "apply", "uid": [self.a.pk],
                                                  "confirm": "on"})
        self.assertEqual(r.status_code, 400)
        r = self.post("/owner/founders?lang=en", {"action": "apply", "uid": [self.a.pk],
                                                  "reason": "early"})
        self.assertEqual(r.status_code, 400)
        self.a.refresh_from_db()
        self.assertFalse(self.a.is_founder)

    def test_apply_grants_and_audits(self):
        r = self.post("/owner/founders", {"action": "apply", "uid": [self.a.pk, self.b.pk],
                                          "reason": "beta testers", "confirm": "on"})
        self.assertEqual(r.status_code, 302)
        for u in (self.a, self.b):
            u.refresh_from_db()
            self.assertTrue(u.is_founder)
            self.assertEqual(u.plan, "premium")
        rows = OwnerAudit.objects.filter(action="founders.grant")
        self.assertEqual(rows.count(), 2)
        row = rows.get(target="user:%d" % self.a.pk)
        self.assertEqual(row.before["is_founder"], False)
        self.assertEqual(row.after["is_founder"], True)
        self.assertEqual(row.after["_reason"], "beta testers")
        self.assertEqual(row.after["_months"], 12)
        self.assertTrue(OwnerAudit.objects.filter(action="founders.bulk").exists())
        # idempotent re-apply: no new per-user audit, no change
        until = User.objects.get(pk=self.a.pk).plan_until
        self.post("/owner/founders", {"action": "apply", "uid": [self.a.pk],
                                      "reason": "again", "confirm": "on"})
        self.assertEqual(OwnerAudit.objects.filter(action="founders.grant").count(), 2)
        self.assertEqual(User.objects.get(pk=self.a.pk).plan_until, until)
        # listed on the page + badge in the users list
        self.assertContains(self.c.get("/owner/founders?lang=en"), "Rina")
        self.assertContains(self.c.get("/owner/users?lang=en"), "Founding Member")

    def test_pick_from_users_list(self):
        r = self.post("/owner/founders?lang=en", {"action": "preview", "uid": [self.b.pk]})
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Karim")
        self.assertNotContains(r, "Rina")

    def test_revoke_audited(self):
        self.post("/owner/founders", {"action": "apply", "uid": [self.a.pk],
                                      "reason": "x", "confirm": "on"})
        r = self.post("/owner/founders", {"action": "revoke", "uid": self.a.pk, "reason": ""})
        self.assertEqual(r.status_code, 400)
        r = self.post("/owner/founders", {"action": "revoke", "uid": self.a.pk,
                                          "reason": "left", "back": str(self.a.pk)})
        self.assertEqual(r.status_code, 302)
        self.assertTrue(r["Location"].startswith("/owner/users/%d" % self.a.pk))
        self.a.refresh_from_db()
        self.assertFalse(self.a.is_founder)
        self.assertEqual(self.a.plan, "free")
        row = OwnerAudit.objects.get(action="founders.revoke")
        self.assertEqual(row.before["is_founder"], True)
        self.assertEqual(row.after["is_founder"], False)

    def test_user_detail_card(self):
        r = self.c.get("/owner/users/%d?lang=en" % self.a.pk)
        self.assertContains(r, "Founding Member")
        self.assertContains(r, "Preview")

    def test_needs_csrf_token(self):
        r = self.c.post("/owner/founders", {"action": "apply", "uid": [self.a.pk],
                                            "reason": "x", "confirm": "on"})
        self.assertEqual(r.status_code, 403)
        self.a.refresh_from_db()
        self.assertFalse(self.a.is_founder)


class NonOwnerTests(OwnerBase):
    def test_non_superuser_refused(self):
        User.objects.create_user(name="Staff", phone="01711000199", password="pw-12345678")
        c = SClient()
        r = c.post("/owner/login", {"phone": "01711000199", "password": "pw-12345678"})
        self.assertNotEqual(r.get("Location"), "/owner/2fa")
        for url in ("/owner/founders", "/owner/feedback", "/owner/feedback.csv",
                    "/owner/feedback/1"):
            r = c.get(url)
            self.assertEqual(r.status_code, 302, url)
            self.assertEqual(r["Location"], "/owner/login")
        # an authenticated app (API token) superuser-less user can't reach it either
        from rest_framework.test import APIClient
        from rest_framework.authtoken.models import Token
        u = User.objects.get(phone="+8801711000199")
        api = APIClient()
        api.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.create(user=u).key)
        r = api.get("/owner/founders", secure=True)
        self.assertEqual(r.status_code, 302)

    def test_superuser_revoked_mid_session_403s_post(self):
        self.ready()
        target = User.objects.create_user(name="T", phone="01711000198", password="x")
        self.owner.is_superuser = False
        self.owner.save()
        r = self.post("/owner/founders", {"action": "apply", "uid": [target.pk],
                                          "reason": "x", "confirm": "on"})
        self.assertEqual(r.status_code, 302)
        self.assertEqual(r["Location"], "/owner/login")
        target.refresh_from_db()
        self.assertFalse(target.is_founder)

    def test_api_admin_endpoints_need_superuser(self):
        """Feedback is never exposed through an API list of everyone's reports."""
        from rest_framework.test import APIClient
        from rest_framework.authtoken.models import Token
        u = User.objects.create_user(name="U", phone="01711000197", password="x")
        other = User.objects.create_user(name="O", phone="01711000196", password="x")
        fb = FeedbackReport.objects.create(user=other, note="secret")
        api = APIClient()
        api.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.create(user=u).key)
        self.assertEqual(api.get("/api/v1/feedback/%d" % fb.pk).status_code, 404)
        self.assertNotIn(b"secret", api.get("/api/v1/feedback").content)


class FeedbackPanelTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.media = tempfile.mkdtemp()
        self._o = override_settings(MEDIA_ROOT=self.media)
        self._o.enable()
        self.u = User.objects.create_user(name="Rina", phone="01711000201", password="x")
        self.bug = FeedbackReport.objects.create(
            user=self.u, category="bug", note="=HYPERLINK(evil) crash on money",
            app_version="1.0.0", app_build="151", device_model="realme RMX3491",
            os_version="Android 13", language="bn", route="money")
        self.bug.screenshot.save("s.png", ContentFile(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")))
        self.idea = FeedbackReport.objects.create(user=self.u, category="idea",
                                                  note="Dark mode for khata", status="fixed")
        self.ready()

    def tearDown(self):
        self._o.disable()
        shutil.rmtree(self.media, ignore_errors=True)

    def test_list_newest_first_and_filters(self):
        r = self.c.get("/owner/feedback?lang=en")
        body = r.content.decode()
        self.assertLess(body.index("Dark mode for khata"), body.index("crash on money"))
        r = self.c.get("/owner/feedback?lang=en&cat=bug")
        self.assertContains(r, "crash on money")
        self.assertNotContains(r, "Dark mode for khata")
        r = self.c.get("/owner/feedback?lang=en&status=fixed")
        self.assertContains(r, "Dark mode for khata")
        self.assertNotContains(r, "crash on money")
        r = self.c.get("/owner/feedback?lang=en&status=bogus")
        self.assertContains(r, "crash on money")

    def test_detail_shows_signed_screenshot(self):
        r = self.c.get("/owner/feedback/%d?lang=en" % self.bug.pk)
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "realme RMX3491")
        self.assertContains(r, "/api/v1/m/feedback/")
        self.assertNotContains(r, "/media/")
        self.assertEqual(self.c.get("/owner/feedback/99999").status_code, 404)

    def test_status_change_and_note_audited(self):
        r = self.post("/owner/feedback/%d" % self.bug.pk,
                      {"status": "triaged", "owner_note": "repro on build 151"})
        self.assertEqual(r.status_code, 302)
        self.bug.refresh_from_db()
        self.assertEqual((self.bug.status, self.bug.owner_note), ("triaged", "repro on build 151"))
        row = OwnerAudit.objects.get(action="feedback.update")
        self.assertEqual(row.target, "feedback:%d" % self.bug.pk)
        self.assertEqual(row.before["status"], "new")
        self.assertEqual(row.after["status"], "triaged")
        r = self.post("/owner/feedback/%d" % self.bug.pk, {"status": "nope"})
        self.assertEqual(r.status_code, 400)
        # unchanged save -> no audit row
        self.post("/owner/feedback/%d" % self.bug.pk,
                  {"status": "triaged", "owner_note": "repro on build 151"})
        self.assertEqual(OwnerAudit.objects.filter(action="feedback.update").count(), 1)

    def test_csv_export(self):
        r = self.c.get("/owner/feedback.csv?cat=bug")
        self.assertEqual(r.status_code, 200)
        self.assertIn("text/csv", r["Content-Type"])
        body = r.content.decode("utf-8-sig")
        self.assertIn("crash on money", body)
        self.assertNotIn("Dark mode", body)
        self.assertIn("'=HYPERLINK", body)          # formula injection neutralised
        self.assertIn("yes", body)
        self.assertTrue(OwnerAudit.objects.filter(action="feedback.export").exists())

    def test_csrf_required(self):
        r = self.c.post("/owner/feedback/%d" % self.bug.pk, {"status": "closed"})
        self.assertEqual(r.status_code, 403)
        self.bug.refresh_from_db()
        self.assertEqual(self.bug.status, "new")

    def test_ot_helper_still_works(self):
        self.assertTrue(_ot(self.c))
