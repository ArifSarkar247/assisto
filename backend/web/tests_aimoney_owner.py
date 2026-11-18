"""aimoney (owner 10 Nov, part G): Owner Admin -> Money (daily) — free users'
profit / loss, AI cost per answer, ad income per type, credits sold and
today's ads-per-answer number. Totals only; owner login required."""
from django.utils import timezone

from core.models import AdPlacementStat
from web.tests_o2_owner_admin import OwnerBase


class MoneyPageTests(OwnerBase):
    def test_page_shows_table_and_number(self):
        AdPlacementStat.objects.create(date=timezone.localdate(), placement="home",
                                       fmt="native", currency="BDT", paid_events=4,
                                       revenue_micros=1_500_000)
        self.ready()
        r = self.c.get("/owner/money")
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        self.assertIn("টাকার হিসাব", html)
        self.assertIn('id="money-table"', html)
        self.assertIn('id="money-ads-per-answer"', html)
        self.assertIn("native ৳১.৫", html)   # owneradmin: Bangla digits in bn
        r = self.c.get("/owner/money?lang=en&days=3")
        self.assertContains(r, "Free users profit / loss")

    def test_needs_login(self):
        r = self.c.get("/owner/money")
        self.assertIn(r.status_code, (302, 403))
