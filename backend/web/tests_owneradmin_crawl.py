"""owneradmin (18 Nov): crawl EVERY Owner Admin page as a signed-in superuser,
in Bangla and English, and check each one (web/owner/crawlcheck.py): status
200, time, size < 300 KB, no English words / ASCII digits in Bangla mode,
mobile-safe tables, CSRF on every POST form, a confirm on destructive actions,
no secret echoed back after save, no dead links. Plus the home "Today" card."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.utils import timezone

from web.owner import crawlcheck as CC
from web.tests_o2_owner_admin import OwnerBase

SAMPLE_KEY = "sk-ant-crawl-SAMPLE-9f8e7d6c5b4a39281706"   # made-up, never a real key


def seed_sample(owner):
    """Made-up sample data (Bangla names) so list pages have rows and detail
    pages are reachable by links. Never real user data."""
    from core import integrations as I
    from core.models import (ClientErrorReport, Device, DiscoverCard, FeedbackReport,
                             SupportTicket, User)
    now = timezone.now()
    people = []
    for i, n in enumerate(["রহিম উদ্দিন", "সালমা বেগম", "করিম মিয়া"]):
        u = User.objects.create_user(name=n, phone="0171555%04d" % i, password="x-pass-123")
        people.append(u)
        Device.objects.create(user=u, push_token="crawl-token-%d" % i,
                              brand="realme" if i % 2 else "samsung",
                              model="RMX3491" if i % 2 else "SM-A146", sdk_int=33,
                              app_version="1.0.%d+%d" % (378 - i, 10378 - i))
    SupportTicket.objects.create(user=people[0], message="ক্রেডিট কেটে গেছে, দেখবেন?")
    FeedbackReport.objects.create(user=people[1], category="bug", note="ম্যাপ খুলছে না")
    ClientErrorReport.objects.create(fingerprint="crawlfp0001", day=timezone.localdate(),
                                     user=people[2], error_type="StateError", build="10377",
                                     brand="realme", model="RMX3491", android="13", sdk=33,
                                     first_at=now - timedelta(hours=3), last_at=now)
    DiscoverCard.objects.create(key="crawl-card", title_bn="নতুন ফিচার", title_en="New feature",
                                desc_bn="দেখুন", desc_en="Have a look")
    try:
        I.save("anthropic", {"api_key": SAMPLE_KEY})
    except Exception:
        pass
    return people


class OwnerAdminCrawlTests(OwnerBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.ready()
        self.people = seed_sample(self.owner)

    def test_every_page_passes_every_check(self):
        with mock.patch("web.owner.today._fetch_ci", return_value={"queued": 3, "running": 2}):
            rep = CC.crawl(self.c, extra=["/owner/users/%d" % self.people[0].pk])
        self.assertGreater(len(rep["pages"]), 150, CC.summary(rep))
        # the saved key never comes back on any page (only a mask / last 4)
        self.assertEqual(rep["findings"], 0, "\n" + CC.summary(rep))

    def test_saved_secret_never_shown_anywhere(self):
        for path in ("/owner/integrations", "/owner/ai", "/owner/integrations?lang=en"):
            r = self.c.get(path)
            self.assertEqual(r.status_code, 200)
            self.assertNotContains(r, SAMPLE_KEY[:-4])
            self.assertNotContains(r, SAMPLE_KEY[8:20])
