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
        html_ok = [p for p in rep["pages"] if p["status"] == 200 and p.get("html")]
        self.assertGreater(len(html_ok), 150, CC.summary(rep))
        self.assertIn("/owner/integrations", {p["url"] for p in html_ok})
        # the saved key never comes back on any page (only a mask / last 4)
        self.assertEqual(rep["findings"], 0, "\n" + CC.summary(rep))

    def test_checker_catches_each_problem(self):
        bad = ('<p>Total users 12</p><table></table>'
               '<form method="post" action="/owner/discover/3/delete"><button>x</button></form>'
               '<input name="api_key" value="sk-live-abcdef123456"><b style="color:red">!</b>')
        f, _, _ = CC.analyse(bad, "bn")
        for k in ("english_in_bn", "ascii_digits_in_bn", "table_not_scrollable",
                  "form_without_csrf", "destructive_without_confirm", "secret_value_shown",
                  "inline_style_or_handler_blocked_by_csp"):
            self.assertIn(k, f)
        good, _, _ = CC.analyse('<p>মোট ১২ <code>owner.login</code> <span lang="en">English</span></p>'
                                '<div class="tbl"><table></table></div>', "bn")
        self.assertEqual(good, {})

    def test_saved_secret_never_shown_anywhere(self):
        for path in ("/owner/integrations", "/owner/ai", "/owner/integrations?lang=en"):
            r = self.c.get(path)
            self.assertEqual(r.status_code, 200)
            self.assertNotContains(r, SAMPLE_KEY[:-4])
            self.assertNotContains(r, SAMPLE_KEY[8:20])


_CALLS = {"attempts": 40, "delivered": 38, "pct": 95, "below": False, "target": 95,
          "brands": [{"brand": "realme", "attempts": 25, "pct": 92, "below": True},
                     {"brand": "samsung", "attempts": 15, "pct": 100, "below": False}]}
_NGINX = {"ok": True, "requests": 1200, "errors_5xx": 3, "share_5xx": 0.0025}


class TodayCardTests(OwnerBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.ready()
        from core.models import ClientErrorReport, Device, User
        now = timezone.now()
        for i, v in enumerate(["1.0.378+10378", "1.0.379+10379", "1.0.300+10300", ""]):
            u = User.objects.create_user(name="নমুনা %d" % i, phone="0171666%04d" % i,
                                         password="x-pass-123")
            Device.objects.create(user=u, push_token="t-%d" % i, brand="realme", model="RMX3491",
                                  sdk_int=33, app_version=v)
        ClientErrorReport.objects.create(fingerprint="fp-a", day=timezone.localdate(), fatal=True,
                                         count=4, first_at=now, last_at=now)
        ClientErrorReport.objects.create(fingerprint="fp-b", day=timezone.localdate(), count=2,
                                         first_at=now, last_at=now)
        ClientErrorReport.objects.create(fingerprint="fp-old", day=timezone.localdate(), count=9,
                                         first_at=now - timedelta(days=3),
                                         last_at=now - timedelta(days=3))

    def _home(self, lang):
        with mock.patch("core.call_ack.delivery_stats", return_value=_CALLS), \
                mock.patch("core.live_monitor.nginx_stats", return_value=_NGINX), \
                mock.patch("web.owner.today._fetch_ci", return_value={"queued": 7, "running": 2}):
            r = self.c.get("/owner/?lang=" + lang)
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        i = html.index('id="today"')
        return html[i:html.index("</section>", i)]

    def test_counts_en(self):
        t = self._home("en")
        self.assertIn("67%", t)                     # 2 of 3 known builds are 10378+
        self.assertIn("2 / 3", t)
        self.assertIn("95%", t)                     # call delivery 24 h
        self.assertIn("realme", t)
        self.assertIn(">92%<", t)                   # below-goal brand
        self.assertIn(">3<", t)                     # 5xx
        self.assertIn(">6<", t)                     # crash reports in 24 h (4 + 2, not the old 9)
        self.assertIn("4 app closed", t)
        self.assertIn(">7<", t)                     # CI queued
        self.assertIn("2 running", t)
        self.assertIn('id="td-signups"><span>New signups (24 h)</span>\n      <b>5</b>', t)  # 4 + the owner

    def test_bangla_digits_and_no_pii(self):
        t = self._home("bn")
        self.assertIn("৬৭%", t)
        self.assertIn("৯৫%", t)
        self.assertNotIn("67%", t)
        for bad in ("নমুনা", "0171666", "RMX3491", "@"):
            self.assertNotIn(bad, t)

    def test_each_part_fails_soft(self):
        with mock.patch("core.call_ack.delivery_stats", side_effect=RuntimeError("x")), \
                mock.patch("core.live_monitor.nginx_stats", return_value={"ok": False}), \
                mock.patch("web.owner.today._fetch_ci", side_effect=OSError("net")):
            r = self.c.get("/owner/?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, 'id="td-calls"')
        self.assertContains(r, "Not measured yet", count=3)

    def test_prod_build_setting(self):
        from web.owner import today
        with self.settings(OWNER_PROD_BUILD=10379):
            self.assertEqual(today.build_share()["on"], 1)
        self.assertEqual(today.build_share()["pct"], 67)


class PanelBasicsTests(OwnerBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.ready()

    def test_bn_digits_keep_machine_tokens(self):
        from web.owner.base import bn_html
        out = bn_html('<p title="a1">মোট 12 · RMX3491 · 01711-111111 · 2026-11-18 '
                      '<code>v 5</code><span translate="no">b 7</span> 50%</p>')
        self.assertIn("মোট ১২", out)
        self.assertIn("RMX3491", out)
        self.assertIn("01711-111111", out)
        self.assertIn("২০২৬-১১-১৮", out)
        self.assertIn("<code>v 5</code>", out)
        self.assertIn("b 7", out)
        self.assertIn("৫০%", out)
        self.assertIn('title="a1"', out)

    def test_phone_menu_and_confirm_script(self):
        r = self.c.get("/owner/")
        self.assertContains(r, 'id="navtoggle"')
        self.assertContains(r, 'aria-controls="side-nav"')
        js = self.c.get("/owner/assets/owner.js").content.decode()
        self.assertIn("data-confirm", js)
        self.assertIn("window.confirm", js)

    def test_destructive_user_actions_ask_first(self):
        from core.models import User
        u = User.objects.create_user(name="নমুনা", phone="01716660099", password="x-pass-123")
        r = self.c.get("/owner/users/%d" % u.pk)
        f, _, _ = CC.analyse(r.content.decode(), "bn")
        self.assertNotIn("destructive_without_confirm", f)
        self.assertContains(r, "data-confirm=")
