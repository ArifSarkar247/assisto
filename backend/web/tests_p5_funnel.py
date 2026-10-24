"""p5-growth: Owner Admin → Growth funnel page (bn/en, Bangla digits, nav link)
and the automatic Founding seats card on /owner/founders."""
from datetime import timedelta

from django.utils import timezone

from core import growth as G
from core.models import ActiveDay, FoundingSeat, ReferralClaim, User
from web.tests_o2_owner_admin import OwnerBase


class FunnelPageTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()
        a = User.objects.create_user(name="Rina", phone="01711000601", password="x")
        b = User.objects.create_user(name="Karim", phone="01811000602", password="x")
        today = timezone.localdate()
        ActiveDay.objects.create(user=a, day=today, cohort_day=today, since_signup=0)
        ReferralClaim.objects.create(inviter=a, invitee=b, code=G.ensure_code(a),
                                     state="rewarded", inviter_credits=20,
                                     invitee_credits=10, cost_bdt=21.43,
                                     decided_at=timezone.now())
        FoundingSeat.objects.create(user=a, number=1, credits=20, cost_bdt=14.29)

    def test_renders_en_and_bn(self):
        r = self.c.get("/owner/funnel?lang=en")
        self.assertEqual(r.status_code, 200)
        for s in ("Growth funnel", "Installs", "Sign-ups", "Activated", "D1", "ARPU",
                  "ARPPU", "Paying users", "Reward cost", "21.43"):
            self.assertContains(r, s)
        self.assertContains(r, 'href="/owner/funnel"')
        r = self.c.get("/owner/funnel?lang=bn")
        self.assertContains(r, "গ্রোথ ফানেল")
        self.assertContains(r, "২১.৪৩")       # Bangla digits in the bn page
        self.assertNotContains(r, ">21.43<")

    def test_days_param_is_clamped(self):
        self.assertEqual(self.c.get("/owner/funnel?days=9999").status_code, 200)
        self.assertEqual(self.c.get("/owner/funnel?days=abc").status_code, 200)

    def test_requires_owner(self):
        from web.tests_o2_owner_admin import SClient
        r = SClient().get("/owner/funnel")
        self.assertIn(r.status_code, (302, 403))

    def test_founders_shows_seats(self):
        r = self.c.get("/owner/founders?lang=en")
        self.assertContains(r, "Automatic Founding seats")
        self.assertContains(r, "1 / 500")

    def test_pricing_referral_knobs_editable(self):
        r = self.c.get("/owner/pricing?lang=en")
        self.assertContains(r, "invite_credits_inviter")
        self.assertContains(r, "founding_auto_seats")
