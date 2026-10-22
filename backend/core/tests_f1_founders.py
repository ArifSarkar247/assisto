"""f1-founders: Founding Member grants (core.founders + plans consistency +
/me badge) and the in-app feedback API (create, validation, rate limit,
privacy, signed screenshot)."""
import base64
import io
import shutil
import tempfile
from datetime import timedelta

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import founders as F
from core import plans
from core.models import FeedbackReport, FounderGrant, User


def _png(w=40, h=60, color=(30, 120, 220)):
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, "PNG")
    return buf.getvalue()


def _client(user):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.create(user=user).key)
    return c


class FounderLogicTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Rina", phone="01711000001", password="x")

    def test_add_months_calendar(self):
        tz = timezone.get_current_timezone()
        d = timezone.datetime(2026, 1, 31, 10, 0, tzinfo=tz)
        self.assertEqual(F.add_months(d, 1).day, 28)
        self.assertEqual(F.add_months(d, 12).year, 2027)
        self.assertEqual(F.add_months(d, 13).month, 2)

    def test_months_default_and_admin_editable(self):
        from core import billing
        self.assertEqual(F.months(), 12)
        row = billing.get_config()
        data = dict(row.data)
        data["limits"] = {**data["limits"], "founding_member_months": 6}
        row.data = data
        row.save()
        self.assertEqual(F.months(), 6)
        data["limits"]["founding_member_months"] = 9999   # clamped
        row.data = data
        row.save()
        self.assertEqual(F.months(), 120)

    def test_grant_free_user_premium_n_months(self):
        now = timezone.now()
        outcome, before, after = F.grant(self.u, reason="early", now=now)
        self.u.refresh_from_db()
        self.assertEqual(outcome, "grant")
        self.assertTrue(self.u.is_founder)
        self.assertEqual(self.u.plan, "premium")
        self.assertEqual(self.u.plan_until, F.add_months(now, 12))
        self.assertEqual(self.u.founder_until, F.add_months(now, 12))
        # consistent with plans: Premium (NOT the lifetime "founder" plan)
        self.assertEqual(plans.effective_plan(self.u), "premium")
        self.assertFalse(plans.lifetime_founder(self.u))
        self.assertEqual(before["effective"], "free")
        self.assertEqual(after["effective"], "premium")
        self.assertEqual(FounderGrant.objects.filter(user=self.u).count(), 1)

    def test_premium_ends_after_n_months_badge_stays(self):
        past = timezone.now() - timedelta(days=400)
        F.grant(self.u, now=past)
        self.u.refresh_from_db()
        self.assertEqual(plans.effective_plan(self.u), "free")
        self.assertTrue(plans.founding_member(self.u)["active"])

    def test_idempotent_regrant(self):
        F.grant(self.u)
        self.u.refresh_from_db()
        until = self.u.plan_until
        outcome, b, a = F.grant(self.u, now=timezone.now() + timedelta(days=30))
        self.u.refresh_from_db()
        self.assertEqual(outcome, "already")
        self.assertEqual(b, a)
        self.assertEqual(self.u.plan_until, until)
        self.assertEqual(FounderGrant.objects.filter(user=self.u).count(), 1)

    def test_never_shortens_longer_premium(self):
        long = timezone.now() + timedelta(days=900)
        self.u.plan, self.u.plan_until = "premium", long
        self.u.save()
        outcome, _, _ = F.grant(self.u)
        self.u.refresh_from_db()
        self.assertEqual(outcome, "keep_longer")
        self.assertEqual(self.u.plan_until, long)
        self.assertTrue(self.u.is_founder)

    def test_extends_shorter_paid_plan(self):
        self.u.plan, self.u.plan_until = "premium", timezone.now() + timedelta(days=20)
        self.u.save()
        now = timezone.now()
        outcome, _, _ = F.grant(self.u, now=now)
        self.u.refresh_from_db()
        self.assertEqual(outcome, "extend")
        self.assertEqual(self.u.plan_until, F.add_months(now, 12))

    def test_business_never_downgraded(self):
        until = timezone.now() + timedelta(days=30)
        self.u.plan, self.u.plan_until = "business", until
        self.u.save()
        outcome, _, _ = F.grant(self.u)
        self.u.refresh_from_db()
        self.assertEqual(outcome, "keep_business")
        self.assertEqual((self.u.plan, self.u.plan_until), ("business", until))
        self.assertTrue(self.u.is_founder)

    def test_lifetime_founder_untouched(self):
        self.u.is_founder = True
        self.u.save()
        self.assertEqual(plans.effective_plan(self.u), "founder")
        outcome, b, a = F.grant(self.u)
        self.assertEqual(outcome, "lifetime")
        self.assertEqual(b, a)
        self.assertEqual(plans.effective_plan(self.u), "founder")

    def test_revoke_restores_previous_plan(self):
        F.grant(self.u)
        changed, before, after = F.revoke(self.u, reason="mistake")
        self.u.refresh_from_db()
        self.assertTrue(changed)
        self.assertFalse(self.u.is_founder)
        self.assertEqual(self.u.plan, "free")
        self.assertIsNone(self.u.plan_until)
        self.assertEqual(plans.effective_plan(self.u), "free")
        self.assertIsNotNone(FounderGrant.objects.get(user=self.u).revoked_at)
        # revoke again: no-op
        self.assertFalse(F.revoke(self.u)[0])

    def test_revoke_keeps_plan_changed_since(self):
        F.grant(self.u)
        self.u.refresh_from_db()
        paid = self.u.plan_until + timedelta(days=30)    # they paid on top
        self.u.plan_until = paid
        self.u.save()
        F.revoke(self.u)
        self.u.refresh_from_db()
        self.assertEqual((self.u.plan, self.u.plan_until), ("premium", paid))
        self.assertFalse(self.u.is_founder)

    def test_resolve_any_format_unknown_invalid(self):
        other = User.objects.create_user(name="Karim", phone="+8801811000002", password="x")
        text = ("+880 1711-000001\n8801811000002, 01811000002 ; ০১৭১১০০০০০১\n"
                "01999999999\nhello\n")
        res = F.resolve(text, user_ids=[str(self.u.pk), "bad"])
        self.assertEqual([u.pk for u in res["users"]], [self.u.pk, other.pk])
        self.assertEqual(res["unknown"], ["01999999999"])
        self.assertEqual(res["invalid"], ["hello"])


class MeBadgeTests(TestCase):
    def test_me_has_founding_member_field(self):
        u = User.objects.create_user(name="A", phone="01711000003", password="x")
        c = _client(u)
        j = c.get("/api/v1/me").json()
        self.assertFalse(j["is_founder"])
        self.assertEqual(j["founding_member"]["active"], False)
        F.grant(u)
        j = c.get("/api/v1/me").json()
        self.assertTrue(j["is_founder"])
        fm = j["founding_member"]
        self.assertTrue(fm["active"])
        self.assertFalse(fm["lifetime"])
        self.assertTrue(fm["since"])
        self.assertTrue(fm["premium_until"])

    def test_badge_cannot_be_self_set(self):
        u = User.objects.create_user(name="A", phone="01711000004", password="x")
        c = _client(u)
        c.patch("/api/v1/me", {"is_founder": True, "name": "B"}, format="json")
        u.refresh_from_db()
        self.assertFalse(u.is_founder)
        self.assertEqual(u.name, "B")


# ==================================================================== feedback
class FeedbackApiTests(TestCase):
    def setUp(self):
        self.media = tempfile.mkdtemp()
        self._o = override_settings(MEDIA_ROOT=self.media)
        self._o.enable()
        self.u = User.objects.create_user(name="Rina", phone="01711000010", password="x")
        self.c = _client(self.u)

    def tearDown(self):
        self._o.disable()
        shutil.rmtree(self.media, ignore_errors=True)

    def post(self, **kw):
        body = {"note": "The send button does nothing", "category": "bug",
                "app_version": "1.0.0", "app_build": "151", "device_model": "realme RMX3491",
                "os_version": "Android 13", "language": "bn", "route": "money"}
        body.update(kw)
        return self.c.post("/api/v1/feedback", body, format="json")

    def test_create_with_meta(self):
        r = self.post()
        self.assertEqual(r.status_code, 201, r.content)
        fb = FeedbackReport.objects.get(pk=r.json()["id"])
        self.assertEqual(fb.user, self.u)
        self.assertEqual(fb.status, "new")
        self.assertEqual((fb.app_build, fb.device_model, fb.route, fb.language),
                         ("151", "realme RMX3491", "money", "bn"))
        self.assertFalse(fb.screenshot)

    def test_create_with_screenshot_signed_private(self):
        r = self.post(screenshot_b64=base64.b64encode(_png()).decode())
        self.assertEqual(r.status_code, 201, r.content)
        fb = FeedbackReport.objects.get(pk=r.json()["id"])
        self.assertTrue(fb.screenshot.name.startswith("feedback/"))
        self.assertGreater(fb.screenshot_bytes, 0)
        url = fb.screenshot.url
        self.assertTrue(url.startswith("/api/v1/m/feedback/"))
        self.assertNotIn("/media/", url)
        base = url.split("?")[0]
        self.assertEqual(self.client.get(base).status_code, 404)   # unsigned = 404
        self.assertEqual(self.client.get(url).status_code, 200)

    def test_jpeg_reencoded_and_data_uri(self):
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", (20, 20), (1, 2, 3)).save(buf, "JPEG")
        b64 = "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()
        r = self.post(screenshot_b64=b64)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertTrue(FeedbackReport.objects.get().screenshot.name.endswith(".jpg"))

    def test_validation(self):
        r = self.post(note="   ")
        self.assertEqual((r.status_code, r.json()["code"]), (400, "note_required"))
        r = self.post(note="x" * 2001)
        self.assertEqual(r.json()["code"], "note_too_long")
        r = self.post(category="spam")
        self.assertEqual(r.json()["code"], "bad_category")
        r = self.post(screenshot_b64=base64.b64encode(b"GIF89a-not-allowed").decode())
        self.assertEqual(r.json()["code"], "bad_image")
        r = self.post(screenshot_b64="%%%not base64%%%")
        self.assertEqual(r.json()["code"], "bad_image")
        fake_png = b"\x89PNG\r\n\x1a\n" + b"0" * 100      # magic only, not an image
        r = self.post(screenshot_b64=base64.b64encode(fake_png).decode())
        self.assertEqual(r.json()["code"], "bad_image")
        big = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"0" * (4 * 1024 * 1024 + 10)).decode()
        r = self.post(screenshot_b64=big)
        self.assertEqual(r.json()["code"], "image_too_large")
        self.assertEqual(FeedbackReport.objects.count(), 0)

    def test_localised_error(self):
        r = self.c.post("/api/v1/feedback", {"note": ""}, format="json",
                        HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.json()["detail"], "Please write a short note.")

    def test_meta_truncated(self):
        r = self.post(device_model="x" * 500)
        self.assertEqual(r.status_code, 201)
        self.assertEqual(len(FeedbackReport.objects.get().device_model), 80)

    def test_rate_limit_per_hour(self):
        for i in range(5):
            self.assertEqual(self.post(note="n%d" % i).status_code, 201)
        r = self.post(note="sixth")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["code"], "rate_limited")
        # another user is not affected
        other = User.objects.create_user(name="B", phone="01711000011", password="x")
        r = _client(other).post("/api/v1/feedback", {"note": "hi"}, format="json")
        self.assertEqual(r.status_code, 201)
        # older reports fall out of the window
        FeedbackReport.objects.filter(user=self.u).update(
            created_at=timezone.now() - timedelta(hours=2))
        self.assertEqual(self.post(note="later").status_code, 201)

    def test_auth_required(self):
        r = APIClient().post("/api/v1/feedback", {"note": "x"}, format="json")
        self.assertIn(r.status_code, (401, 403))

    def test_privacy_other_users_cannot_read(self):
        pk = self.post(screenshot_b64=base64.b64encode(_png()).decode()).json()["id"]
        mine = self.c.get("/api/v1/feedback/%d" % pk)
        self.assertEqual(mine.status_code, 200)
        self.assertTrue(mine.json()["screenshot_url"].startswith("/api/v1/m/"))
        other = User.objects.create_user(name="B", phone="01711000012", password="x")
        oc = _client(other)
        self.assertEqual(oc.get("/api/v1/feedback/%d" % pk).status_code, 404)
        self.assertEqual(oc.get("/api/v1/feedback").json()["results"], [])
        self.assertEqual(len(self.c.get("/api/v1/feedback").json()["results"]), 1)
        # the list never carries screenshot links
        self.assertNotIn("screenshot_url", self.c.get("/api/v1/feedback").json()["results"][0])


class FeedbackRouteTests(TestCase):
    def test_chat_commands_resolve_to_feedback(self):
        from core import screen_synonyms as SS
        for t in ("feedback", "Send feedback", "report a problem", "please report a bug",
                  "মতামত", "মতামত দিন", "সমস্যা জানান", "আমার মতামত"):
            self.assertEqual(SS.resolve_command(t), "feedback", t)
        self.assertEqual(SS.resolve("ফিডব্যাক দিতে চাই"), "feedback")
        self.assertIsNone(SS.resolve_command("what is the weather"))
        self.assertEqual(SS.resolve_command("my circle"), "circle_add")
