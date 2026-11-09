"""recovery (owner order Part 8): Owner Admin -> Account recovery queue
(match results only, approve keeps the 48 h hold, family 'No' blocks
approval, audited, bn/en, staff role gate)."""
from datetime import timedelta

from django.utils import timezone

from core.models import OwnerAudit, RecoveryRequest, User
from web.tests_o2_owner_admin import OwnerBase, SClient


class RecoveryOwnerTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.acct = User.objects.create_user(name="Rahim", phone="01799000011", password="x")
        self.r = RecoveryRequest.objects.create(
            user=self.acct, ref="AB12CD34", secret_hash="0" * 64,
            account_phone="+8801799000011", contact_phone="+8801699000012",
            typed_name="rahim", proof={"name": "exact", "signup": "month", "circle": "2/3",
                                       "password": "no", "account_age_days": 40},
            score=65, family_state="confirmed",
            hold_until=timezone.now() + timedelta(hours=40))
        self.ready()

    def test_queue_shows_match_results_only(self):
        r = self.c.get("/owner/recovery?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "AB12CD34")
        self.assertContains(r, "65/100")
        self.assertContains(r, "never chats, photos or documents")
        self.assertNotContains(r, "+8801699000012")          # numbers masked
        r = self.c.get("/owner/recovery?lang=bn&status=bogus")
        self.assertContains(r, "অ্যাকাউন্ট রিকভারি")

    def test_approve_keeps_hold_and_is_audited(self):
        r = self.post("/owner/recovery/%d/act" % self.r.pk, {"action": "approve"})
        self.assertEqual(r.status_code, 302)
        self.r.refresh_from_db()
        self.assertEqual(self.r.state, "approved")
        self.assertGreater(self.r.hold_until, timezone.now())   # hold untouched
        self.assertTrue(OwnerAudit.objects.filter(action="recovery.approve").exists())
        r = self.post("/owner/recovery/%d/act" % self.r.pk, {"action": "reject"})
        self.assertIn("m=invalid", r["Location"])
        self.assertEqual(self.post("/owner/recovery/99999/act", {"action": "approve"})
                         .status_code, 404)

    def test_family_no_cannot_be_approved(self):
        RecoveryRequest.objects.filter(pk=self.r.pk).update(family_state="denied")
        r = self.post("/owner/recovery/%d/act" % self.r.pk, {"action": "approve"})
        self.assertIn("m=invalid", r["Location"])
        self.r.refresh_from_db()
        self.assertEqual(self.r.state, "pending")

    def test_requires_owner(self):
        r = SClient().get("/owner/recovery")
        self.assertEqual((r.status_code, r["Location"]), (302, "/owner/login"))
