"""l1-launch — Play/AdMob legal pages, app-ads.txt, sitemap/robots, and the
web data-deletion request form."""
import re
from unittest import mock

from django.test import TestCase, Client, override_settings

from core.models import AccountDeletionRequest, User, WebDeletionRequest
from web import legal_content as LC
from web import legal_deletion as LD

SITE = "https://lifeassisto.com"


class LegalPagesTests(TestCase):
    PAGES = [("/privacy", "গোপনীয়তা নীতি", "Privacy Policy"),
             ("/terms", "ব্যবহারের শর্তাবলী", "Terms of Service"),
             ("/delete-account", "অ্যাকাউন্ট ও ডেটা মুছে ফেলা", "Delete your account and data")]

    def setUp(self):
        self.c = Client()

    def test_pages_200_bn_and_en_with_seo_and_no_noindex(self):
        for path, bn, en in self.PAGES:
            for lang, title, q in (("bn", bn, ""), ("en", en, "?lang=en")):
                r = self.c.get(path + q)
                self.assertEqual(r.status_code, 200, path + q)
                html = r.content.decode()
                self.assertIn('<html lang="%s">' % lang, html)
                self.assertIn("<title>%s — Assisto</title>" % title, html)
                self.assertIn('<link rel="canonical" href="%s%s%s">' % (SITE, path, q), html)
                self.assertIn('hreflang="bn" href="%s%s"' % (SITE, path), html)
                self.assertIn('hreflang="en" href="%s%s?lang=en"' % (SITE, path), html)
                self.assertIn('<meta name="description"', html)
                self.assertNotIn("noindex", html)
                self.assertNotIn("X-Robots-Tag", r.headers)
                # language toggle present
                self.assertIn("?lang=en" if lang == "bn" else "?lang=bn", html)
                # no unrendered template/format placeholders leak
                self.assertNotRegex(html, r"\{[a-z_]+\}")

    def test_pages_are_strictly_single_language_headings(self):
        en = self.c.get("/privacy?lang=en").content.decode()
        bn = self.c.get("/privacy").content.decode()
        self.assertIn("Children&#x27;s privacy", en)
        self.assertIn("শিশুদের গোপনীয়তা", bn)
        self.assertNotIn("শিশুদের গোপনীয়তা", en)
        self.assertNotIn("Children&#x27;s privacy", bn)

    def test_privacy_has_required_sections(self):
        html = self.c.get("/privacy?lang=en").content.decode()
        for sid in ("summary", "who", "collect", "device_only", "permissions", "use",
                    "ai", "ads", "sharing", "retention", "security", "rights",
                    "children", "changes", "contact"):
            self.assertIn('id="%s"' % sid, html, sid)
        for needle in ("do not sell", "non-personalised", "AdMob", "Advertising ID",
                       "Firebase Cloud Messaging", "Anthropic", "OpenAI", "Gemini",
                       "SMS gateway", "TURN", "Picovoice", "end-to-end",
                       "1 hour", "7-day", "Disappearing messages", "under 13",
                       "/delete-account"):
            self.assertIn(needle, html, needle)

    def test_privacy_lists_every_manifest_permission(self):
        html = self.c.get("/privacy?lang=en").content.decode()
        for perm in ("CAMERA", "RECORD_AUDIO", "ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION",
                     "READ_CONTACTS", "POST_NOTIFICATIONS", "USE_FULL_SCREEN_INTENT",
                     "FOREGROUND_SERVICE_MICROPHONE", "FOREGROUND_SERVICE_LOCATION",
                     "CALL_PHONE", "SET_ALARM", "BLUETOOTH_CONNECT", "health.READ_STEPS",
                     "health.READ_HEART_RATE", "health.READ_SLEEP",
                     "health.READ_ACTIVE_CALORIES_BURNED", "ACTIVITY_RECOGNITION",
                     "Photo Picker", "BIND_DEVICE_ADMIN", "BIND_VOICE_INTERACTION",
                     "REQUEST_INSTALL_PACKAGES", "RECEIVE_BOOT_COMPLETED", "VIBRATE"):
            self.assertIn(perm, html, perm)
        # each permission card explains what / when / how to revoke
        self.assertEqual(html.count('class="perm"'), len(LC.PERMISSIONS))
        self.assertEqual(html.count("How to turn it off"), len(LC.PERMISSIONS))

    def test_permissions_match_the_ci_manifest_patch(self):
        """Every <uses-permission> the CI manifest patch adds must be explained."""
        import pathlib
        wf = pathlib.Path(__file__).resolve().parents[2] / ".github/workflows/android.yml"
        if not wf.exists():
            self.skipTest("workflow not in this checkout")
        # only REQUESTED permissions (<uses-permission ...>), not android:permission=
        # guards on components (e.g. START_VIEW_PERMISSION_USAGE on the Health
        # Connect alias, BIND_* on services), which the app never asks the user for
        # play-perm: lines marked tools:node="remove" take a permission AWAY
        declared = set(re.findall(r'uses-permission android:name="android\.permission\.([A-Za-z_.]+)"(?![^>]*tools:node="remove")',
                                  wf.read_text()))
        declared |= {"SET_ALARM"} if "alarm.permission.SET_ALARM" in wf.read_text() else set()
        explained = " ".join(p["perm"] for p in LC.PERMISSIONS)
        # BODY_SENSORS only appears in the emulator `pm grant` line, not the manifest
        declared.discard("BODY_SENSORS")
        for p in sorted(declared):
            self.assertIn(p, explained, "manifest permission %s not explained" % p)

    def test_terms_sections(self):
        html = self.c.get("/terms?lang=en").content.decode()
        for needle in ("at least 18", "never holds, transfers or processes your money",
                       "not medical advice", "999", "Acceptable use", "Governing law"):
            self.assertIn(needle, html, needle)

    def test_deletion_page_describes_both_paths(self):
        html = self.c.get("/delete-account?lang=en").content.decode()
        self.assertIn("Delete my account", html)
        self.assertIn("Settings", html)
        self.assertIn('<form method="post"', html)
        self.assertIn('name="contact"', html)
        self.assertIn("csrfmiddlewaretoken", html)
        bn = self.c.get("/delete-account").content.decode()
        self.assertIn("আমার অ্যাকাউন্ট মুছে ফেলুন", bn)
        self.assertIn("সেটিংস", bn)

    def test_owner_approved_facts_then_env_override(self):
        html = self.c.get("/privacy?lang=en").content.decode()
        self.assertIn("AXON Dynamic", html)
        self.assertIn("assistoaiagent@gmail.com", html)
        self.assertIn("Mumbai", html)
        self.assertNotIn("Singapore", html)
        self.assertIn("Uttar Badda", html)               # owner address (24 Oct)
        self.assertNotIn("[ADDRESS]", html)
        self.assertNotIn("to be added", html)
        self.assertEqual(LC.missing_facts(), [])
        dl = self.c.get("/delete-account?lang=en").content.decode()
        self.assertIn("Uttar Badda", dl)
        self.assertIn("AXON Dynamic", dl)
        self.assertNotIn("AXON ERP", dl)
        with mock.patch.dict("os.environ", {"LEGAL_ENTITY_NAME": "Example <Ltd>",
                                            "LEGAL_CONTACT_EMAIL": "privacy@example.com"}):
            html = self.c.get("/privacy?lang=en").content.decode()
            self.assertIn("Example &lt;Ltd&gt;", html)   # escaped
            self.assertIn("privacy@example.com", html)
            self.assertNotIn("LEGAL_ENTITY_NAME", LC.missing_facts())

    def test_footer_links_on_existing_pages(self):
        html = self.c.get("/").content.decode()
        for p in ('href="/privacy"', 'href="/terms"', 'href="/delete-account"'):
            self.assertIn(p, html)

    def test_in_app_legal_api_carries_web_url_and_no_false_tracker_claim(self):
        r = self.c.get("/api/v1/legal/privacy", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["web_url"].startswith(SITE + "/privacy"))
        body = r.json()["body"]
        self.assertNotIn("no advertising trackers", body)
        self.assertNotIn("no third-party ad trackers", body)
        r = self.c.get("/api/v1/legal/data_rights")
        self.assertTrue(r.json()["web_url"].startswith(SITE + "/delete-account"))
        self.assertIsNone(self.c.get("/api/v1/legal/age_note").json()["web_url"])


class AppAdsTxtTests(TestCase):
    def setUp(self):
        self.c = Client()

    def test_default_is_assisto_admob_publisher(self):
        # admob (owner 25 Oct): lifeassisto.com/app-ads.txt, text/plain
        r = self.c.get("/app-ads.txt")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r["Content-Type"].startswith("text/plain"))
        body = r.content.decode()
        self.assertIn("google.com, pub-2506398550427515, DIRECT, f08c47fec0942fa0\n", body)
        lines = [l for l in body.splitlines() if l.strip() and not l.startswith("#")]
        self.assertEqual(lines, ["google.com, pub-2506398550427515, DIRECT, f08c47fec0942fa0"])

    @override_settings(ADMOB_PUBLISHER_ID="pub-1234567890123456")
    def test_set_by_setting(self):
        body = self.c.get("/app-ads.txt").content.decode()
        self.assertIn("google.com, pub-1234567890123456, DIRECT, f08c47fec0942fa0\n", body)

    def test_set_via_env_accepts_full_line_or_ca_app_form(self):
        for raw in ("google.com, pub-1111222233334444, DIRECT, f08c47fec0942fa0",
                    "ca-app-pub-1111222233334444", " pub-1111222233334444 "):
            with mock.patch.dict("os.environ", {"ADMOB_PUBLISHER_ID": raw}):
                body = self.c.get("/app-ads.txt").content.decode()
                self.assertEqual(body.count("pub-1111222233334444"), 1, raw)

    def test_derived_from_owner_panel_admob_app_id(self):
        cfg = {"app_id": "ca-app-pub-5555666677778888~1234567890"}
        with mock.patch("core.integrations.get", return_value=cfg):
            body = self.c.get("/app-ads.txt").content.decode()
        self.assertIn("google.com, pub-5555666677778888, DIRECT, f08c47fec0942fa0", body)

    def test_google_test_publisher_and_garbage_never_served(self):
        for cfg in ({"app_id": "ca-app-pub-3940256099942544~3347511713"},
                    {"publisher_id": "pub-123"}, {"publisher_id": "hello"}):
            with mock.patch("core.integrations.get", return_value=cfg):
                body = self.c.get("/app-ads.txt").content.decode()
            self.assertIn("pub-2506398550427515", body, cfg)       # owner default
            self.assertNotIn("3940256099942544", body, cfg)

    def test_admob_registry_has_publisher_field(self):
        from core.integrations import REGISTRY
        keys = [f["key"] for f in REGISTRY["admob"]["fields"]]
        self.assertIn("publisher_id", keys)


class SitemapRobotsTests(TestCase):
    def test_robots_points_to_sitemap_and_keeps_owner_disallowed(self):
        body = Client().get("/robots.txt").content.decode()
        self.assertIn("Disallow: /owner/", body)
        self.assertIn("Sitemap: %s/sitemap.xml" % SITE, body)
        self.assertNotIn("Disallow: /privacy", body)

    def test_sitemap_lists_legal_pages(self):
        r = Client().get("/sitemap.xml")
        self.assertEqual(r.status_code, 200)
        body = r.content.decode()
        for p in ("/privacy", "/terms", "/delete-account"):
            self.assertIn("<loc>%s%s</loc>" % (SITE, p), body)
            self.assertIn("<loc>%s%s?lang=en</loc>" % (SITE, p), body)
        self.assertNotIn("/owner", body)


class WebDeletionRequestTests(TestCase):
    def setUp(self):
        self.c = Client()
        self.user = User.objects.create_user(username="+8801712345678", password="pw-12345678",
                                             phone="+8801712345678", email="a@example.com")

    def post(self, ip="10.0.0.1", **data):
        base = {"contact": "01712345678", "confirm": "1"}
        base.update(data)
        return self.c.post("/delete-account", base, REMOTE_ADDR=ip)

    def test_valid_request_creates_ticket_and_deletes_nothing(self):
        r = self.post()
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "এখনো কিছু মোছা হয়নি")
        t = WebDeletionRequest.objects.get()
        self.assertEqual(t.contact, "+8801712345678")
        self.assertEqual(t.contact_kind, "phone")
        self.assertEqual(t.matched_user, self.user)
        self.assertEqual(t.status, WebDeletionRequest.STATUS_NEW)
        self.assertTrue(User.objects.filter(pk=self.user.pk, is_active=True).exists())
        self.assertFalse(AccountDeletionRequest.objects.exists())

    def test_email_contact_and_english(self):
        r = self.c.post("/delete-account?lang=en", {"contact": "A@Example.com", "confirm": "1"},
                        REMOTE_ADDR="10.0.0.2")
        self.assertContains(r, "Nothing has been deleted yet")
        t = WebDeletionRequest.objects.get()
        self.assertEqual((t.contact_kind, t.contact, t.lang), ("email", "a@example.com", "en"))
        self.assertEqual(t.matched_user, self.user)

    def test_unknown_contact_gets_identical_answer_no_probing(self):
        known = self.post().content.decode()
        unknown = self.post(ip="10.0.0.9", contact="01812345678").content.decode()
        strip = lambda h: re.sub(r'name="csrfmiddlewaretoken" value="[^"]+"', "", h)
        self.assertEqual(strip(known), strip(unknown))
        t = WebDeletionRequest.objects.get(contact="+8801812345678")
        self.assertIsNone(t.matched_user)
        self.assertEqual(t.status, WebDeletionRequest.STATUS_NO_ACCOUNT)

    def test_validation_errors(self):
        r = self.post(contact="not a number")
        self.assertEqual(r.status_code, 400)
        self.assertContains(r, LD.ERR["bn"]["contact"], status_code=400)
        r = self.c.post("/delete-account?lang=en", {"contact": "01712345678"}, REMOTE_ADDR="10.0.0.3")
        self.assertContains(r, LD.ERR["en"]["confirm"], status_code=400)
        r = self.post(reason="x" * 1001)
        self.assertEqual(r.status_code, 400)
        self.assertFalse(WebDeletionRequest.objects.exists())

    def test_honeypot_creates_nothing_but_looks_successful(self):
        r = self.post(website="http://spam")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(WebDeletionRequest.objects.exists())

    def test_duplicate_open_request_reuses_ticket(self):
        self.post()
        self.post(ip="10.0.0.5")
        self.assertEqual(WebDeletionRequest.objects.count(), 1)

    def test_rate_limit_per_ip(self):
        for i in range(LD.RATE_PER_HOUR):
            self.assertEqual(self.post(contact="0171234560%d" % i).status_code, 200)
        r = self.post(contact="01912345678")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(WebDeletionRequest.objects.count(), LD.RATE_PER_HOUR)
        # another IP is not affected
        self.assertEqual(self.post(ip="10.9.9.9", contact="01912345678").status_code, 200)

    def test_csrf_enforced(self):
        c = Client(enforce_csrf_checks=True)
        r = c.post("/delete-account", {"contact": "01712345678", "confirm": "1"})
        self.assertEqual(r.status_code, 403)
        self.assertFalse(WebDeletionRequest.objects.exists())

    def test_schedule_requires_verification_then_uses_normal_grace_flow(self):
        self.post()
        qs = WebDeletionRequest.objects.all()
        done, skipped = LD.schedule_verified(qs)
        self.assertEqual((done, skipped), (0, 1))          # not verified -> nothing
        self.assertFalse(AccountDeletionRequest.objects.exists())
        qs.update(status=WebDeletionRequest.STATUS_VERIFIED)
        done, skipped = LD.schedule_verified(WebDeletionRequest.objects.all())
        self.assertEqual((done, skipped), (1, 0))
        req = AccountDeletionRequest.objects.get(user=self.user)
        self.assertEqual(req.state, AccountDeletionRequest.STATE_PENDING)
        self.assertGreaterEqual((req.effective_at - req.requested_at).days, 6)
        self.assertTrue(req.cancel_token)
        # the account itself is untouched until purge_deletions runs after the grace
        self.assertTrue(User.objects.filter(pk=self.user.pk).exists())
        self.assertEqual(WebDeletionRequest.objects.get().status,
                         WebDeletionRequest.STATUS_SCHEDULED)

    def test_schedule_skips_tickets_without_account(self):
        self.post(contact="01812345678")
        WebDeletionRequest.objects.update(status=WebDeletionRequest.STATUS_VERIFIED)
        self.assertEqual(LD.schedule_verified(WebDeletionRequest.objects.all()), (0, 1))


class RetentionPurgeTests(TestCase):
    def test_purge_expired_journey_points_and_old_closed_tickets(self):
        from datetime import timedelta
        from io import StringIO
        from django.core.management import call_command
        from django.utils import timezone
        from core.models import Journey, JourneyPoint
        u = User.objects.create_user(username="j@example.com", password="pw-12345678", email="j@example.com")
        now = timezone.now()
        old = Journey.objects.create(traveller=u, expires_at=now - timedelta(hours=1),
                                     last_location={"lat": 1, "lng": 2})
        live = Journey.objects.create(traveller=u, expires_at=now + timedelta(hours=5))
        JourneyPoint.objects.create(journey=old, lat=1, lng=2)
        JourneyPoint.objects.create(journey=live, lat=3, lng=4)
        t_old = WebDeletionRequest.objects.create(contact="+8801700000000",
                                                  status=WebDeletionRequest.STATUS_REJECTED)
        WebDeletionRequest.objects.filter(pk=t_old.pk).update(created_at=now - timedelta(days=200))
        t_open = WebDeletionRequest.objects.create(contact="+8801700000001")
        WebDeletionRequest.objects.filter(pk=t_open.pk).update(created_at=now - timedelta(days=200))
        call_command("purge_l1_retention", stdout=StringIO())
        self.assertFalse(JourneyPoint.objects.filter(journey=old).exists())
        self.assertTrue(JourneyPoint.objects.filter(journey=live).exists())
        old.refresh_from_db()
        self.assertIsNone(old.last_location)
        self.assertFalse(WebDeletionRequest.objects.filter(pk=t_old.pk).exists())
        self.assertTrue(WebDeletionRequest.objects.filter(pk=t_open.pk).exists())  # open: kept
