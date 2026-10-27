"""o2-admin: web owner admin panel (/owner/) — auth, 2FA, sessions, CSRF,
lockout, headers, audit, and every section (bn/en) through the SAME service
functions as the /api/v1/admin/* endpoints."""
import io
import os
import re
import time
from datetime import timedelta
from unittest import mock

from django.core.management import call_command
from django.test import Client, TestCase, override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core.models import (CreditLedger, DiscoverCard, OwnerAudit, OwnerSession,
                         OwnerThrottle, OwnerTOTP, User)
from web.owner import security as S

OWNER_PHONE = "01710009904"
OWNER_PW = "owner-pass-123"


class SClient(Client):
    """Test client that talks HTTPS by default (the panel is HTTPS-only)."""
    def get(self, path, *a, **kw):
        kw.setdefault("secure", True)
        return super().get(path, *a, **kw)

    def post(self, path, *a, **kw):
        kw.setdefault("secure", True)
        return super().post(path, *a, **kw)


def _ot(client):
    """The session-bound CSRF token of the client's current owner session."""
    raw = client.cookies[S.COOKIE].value
    return OwnerSession.objects.get(key_hash=S.sha256(raw)).csrf


class OwnerBase(TestCase):
    def setUp(self):
        self.owner = User.objects.create_superuser(name="Owner", phone=OWNER_PHONE,
                                                   password=OWNER_PW)
        self.c = SClient()

    # -- flows
    def password_login(self, client=None, phone=OWNER_PHONE, pw=OWNER_PW):
        c = client or self.c
        return c.post("/owner/login", {"phone": phone, "password": pw})

    def enrol(self, client=None):
        """Password + first-time enrolment. Returns (secret, recovery_codes)."""
        c = client or self.c
        r = self.password_login(c)
        self.assertEqual(r.status_code, 302)
        self.assertEqual(r["Location"], "/owner/enrol")
        r = c.get("/owner/enrol")
        self.assertEqual(r.status_code, 200)
        sess = OwnerSession.objects.get(key_hash=S.sha256(c.cookies[S.COOKIE].value))
        secret = S.decrypt(sess.pending_secret_enc)
        r = c.post("/owner/enrol", {"code": S.totp(secret), "_ot": sess.csrf})
        self.assertEqual(r.status_code, 200)
        codes = re.findall(r"<code>([a-z0-9]{5}-[a-z0-9]{5})</code>", r.content.decode())
        self.assertEqual(len(codes), 10)
        return secret, codes

    def full_login(self, client=None):
        """Login of an ALREADY enrolled owner with a fresh (next-step) code."""
        c = client or self.c
        r = self.password_login(c)
        self.assertEqual(r["Location"], "/owner/2fa")
        t = OwnerTOTP.objects.get(user=self.owner)
        secret = S.decrypt(t.secret_enc)
        code = S.hotp(secret, max(S.counter_at(), t.last_counter + 1))
        if t.last_counter >= S.counter_at() + 1:
            self.fail("no fresh code available")
        r = c.post("/owner/2fa", {"code": code, "_ot": _ot(c)})
        self.assertEqual(r.status_code, 302, r.content[:300])
        return r

    def ready(self):
        self.secret, self.codes = self.enrol()
        return self.c

    def post(self, path, data=None, **kw):
        d = dict(data or {})
        d.setdefault("_ot", _ot(self.c))
        return self.c.post(path, d, **kw)


# ======================================================================= auth
class AuthTests(OwnerBase):
    def test_rfc6238_vector(self):
        secret = __import__("base64").b32encode(b"12345678901234567890").decode()
        self.assertEqual(S.totp(secret, 59), "287082")
        self.assertEqual(S.totp(secret, 1111111109), "081804")

    def test_unauthenticated_redirects_to_login(self):
        for url in ("/owner/", "/owner/discover", "/owner/pricing", "/owner/users"):
            r = self.c.get(url)
            self.assertEqual(r.status_code, 302, url)
            self.assertEqual(r["Location"], "/owner/login")

    def test_http_is_refused(self):
        r = self.c.get("/owner/login", secure=False)
        self.assertEqual(r.status_code, 301)
        self.assertTrue(r["Location"].startswith("https://"))
        r = self.c.post("/owner/login", {"phone": OWNER_PHONE, "password": OWNER_PW},
                        secure=False)
        self.assertEqual(r.status_code, 403)
        self.assertFalse(OwnerSession.objects.exists())

    @override_settings(OWNER_ADMIN_REQUIRE_HTTPS=False)
    def test_http_allowed_only_when_setting_off(self):
        r = self.c.get("/owner/login", secure=False)
        self.assertEqual(r.status_code, 200)

    def test_security_headers_and_noindex(self):
        r = self.c.get("/owner/login")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, 'name="robots" content="noindex')
        self.assertIn("noindex", r["X-Robots-Tag"])
        self.assertEqual(r["X-Frame-Options"], "DENY")
        self.assertEqual(r["Referrer-Policy"], "same-origin")
        csp = r["Content-Security-Policy"]
        self.assertIn("frame-ancestors 'none'", csp)
        self.assertNotIn("unsafe-eval", csp)
        self.assertNotIn("unsafe-inline", csp)
        self.assertIn("no-store", r["Cache-Control"])
        rb = self.c.get("/robots.txt")
        self.assertIn("Disallow: /owner/", rb.content.decode())
        self.assertIn("Disallow: /", self.c.get("/owner/robots.txt").content.decode())

    def test_non_superuser_cannot_login(self):
        User.objects.create_user(name="U", phone="01710009905", password="pw-user-1")
        r = self.password_login(phone="01710009905", pw="pw-user-1")
        self.assertEqual(r.status_code, 401)
        self.assertNotIn(S.COOKIE, r.cookies)
        self.assertTrue(OwnerAudit.objects.filter(action="login.fail", ok=False).exists())

    def test_wrong_password(self):
        r = self.password_login(pw="nope")
        self.assertEqual(r.status_code, 401)
        a = OwnerAudit.objects.get(action="login.fail")
        self.assertFalse(a.ok)
        self.assertEqual(a.actor, self.owner)

    def test_phone_any_format(self):
        r = self.password_login(phone="+880 1710-009904")
        self.assertEqual(r.status_code, 302)
        r = SClient().post("/owner/login", {"phone": "০১৭১০০০৯৯০৪", "password": OWNER_PW})
        self.assertEqual(r.status_code, 302)

    def test_2fa_required_before_any_page(self):
        self.password_login()
        for url in ("/owner/", "/owner/pricing", "/owner/users", "/owner/audit"):
            r = self.c.get(url)
            self.assertEqual(r.status_code, 302)
            self.assertEqual(r["Location"], "/owner/enrol")
        self.assertEqual(self.c.get("/owner/2fa").status_code, 302)

    def test_enrol_stores_secret_encrypted_and_codes_hashed(self):
        secret, codes = self.enrol()
        t = OwnerTOTP.objects.get(user=self.owner)
        self.assertIsNotNone(t.confirmed_at)
        self.assertNotIn(secret, t.secret_enc)
        self.assertEqual(S.decrypt(t.secret_enc), secret)
        blob = str(t.recovery_hashes)
        for code in codes:
            self.assertNotIn(code, blob)
        self.assertEqual(self.c.get("/owner/").status_code, 200)
        # enrolment page is gone once enrolled; the secret is never shown again
        r = self.c.get("/owner/enrol")
        self.assertEqual(r.status_code, 302)
        self.assertNotContains(self.c.get("/owner/security"), S.group_secret(secret))
        self.assertTrue(OwnerAudit.objects.filter(action="2fa.enrolled").exists())
        self.assertTrue(OwnerAudit.objects.filter(action="login.success").exists())

    def test_enrol_wrong_code(self):
        self.password_login()
        self.c.get("/owner/enrol")
        r = self.c.post("/owner/enrol", {"code": "000000", "_ot": _ot(self.c)})
        self.assertEqual(r.status_code, 401)
        self.assertFalse(OwnerTOTP.objects.exists())

    def test_session_rotated_after_2fa(self):
        self.password_login()
        before = self.c.cookies[S.COOKIE].value
        self.enrol(SClient())  # separate client just to enrol
        c2 = SClient()
        self.password_login(c2)
        pre = c2.cookies[S.COOKIE].value
        t = OwnerTOTP.objects.get(user=self.owner)
        code = S.hotp(S.decrypt(t.secret_enc), t.last_counter + 1)
        c2.post("/owner/2fa", {"code": code, "_ot": _ot(c2)})
        self.assertNotEqual(pre, c2.cookies[S.COOKIE].value)
        self.assertNotEqual(before, pre)

    def test_totp_verify_and_replay_rejected(self):
        self.ready()
        secret = self.secret
        c2 = SClient()
        self.password_login(c2)
        t = OwnerTOTP.objects.get(user=self.owner)
        used = S.hotp(secret, t.last_counter)          # the enrolment code
        r = c2.post("/owner/2fa", {"code": used, "_ot": _ot(c2)})
        self.assertEqual(r.status_code, 401)
        self.assertTrue(OwnerAudit.objects.filter(action="login.mfa_fail").exists())
        r = c2.post("/owner/2fa", {"code": S.hotp(secret, t.last_counter + 1),
                                   "_ot": _ot(c2)})
        self.assertEqual(r.status_code, 302)
        self.assertEqual(c2.get("/owner/").status_code, 200)

    def test_recovery_code_single_use(self):
        self.ready()
        codes = self.codes
        c2 = SClient()
        self.password_login(c2)
        r = c2.post("/owner/2fa", {"code": codes[0].upper(), "_ot": _ot(c2)})
        self.assertEqual(r.status_code, 302)
        self.assertIn("recovery_used", r["Location"])
        self.assertEqual(len(OwnerTOTP.objects.get(user=self.owner).recovery_hashes), 9)
        c3 = SClient()
        self.password_login(c3)
        r = c3.post("/owner/2fa", {"code": codes[0], "_ot": _ot(c3)})
        self.assertEqual(r.status_code, 401)
        a = OwnerAudit.objects.filter(action="login.success").first()
        self.assertEqual(a.after["method"], "recovery_code")

    def test_login_lockout_with_backoff(self):
        for _ in range(S.LOCK_AFTER):
            self.assertEqual(self.password_login(pw="bad").status_code, 401)
        r = self.password_login()                   # even the right password
        self.assertEqual(r.status_code, 429)
        t = OwnerThrottle.objects.get(key__startswith="acct:")
        first = (t.locked_until - t.last_fail_at).total_seconds()
        self.assertAlmostEqual(first, 60, delta=2)
        # lock expires -> one more failure doubles the lock
        OwnerThrottle.objects.update(locked_until=timezone.now() - timedelta(seconds=1))
        self.assertEqual(self.password_login(pw="bad").status_code, 401)
        t.refresh_from_db()
        self.assertAlmostEqual((t.locked_until - t.last_fail_at).total_seconds(), 120, delta=2)
        self.assertTrue(OwnerAudit.objects.filter(action="login.locked").exists())

    def test_2fa_lockout(self):
        self.ready()
        c2 = SClient()
        self.password_login(c2)
        for _ in range(S.LOCK_AFTER):
            c2.post("/owner/2fa", {"code": "111111", "_ot": _ot(c2)})
        t = OwnerTOTP.objects.get(user=self.owner)
        r = c2.post("/owner/2fa", {"code": S.hotp(S.decrypt(t.secret_enc), t.last_counter + 1),
                                   "_ot": _ot(c2)})
        self.assertEqual(r.status_code, 429)

    def test_cookie_flags(self):
        r = self.password_login()
        m = r.cookies[S.COOKIE]
        self.assertTrue(m["secure"])
        self.assertTrue(m["httponly"])
        self.assertEqual(m["samesite"], "Strict")
        self.assertEqual(m["path"], "/owner/")
        # only a hash of the cookie is stored
        self.assertFalse(OwnerSession.objects.filter(key_hash=m.value).exists())

    def test_idle_timeout(self):
        self.ready()
        OwnerSession.objects.update(last_seen=timezone.now() - timedelta(minutes=31))
        r = self.c.get("/owner/")
        self.assertEqual(r.status_code, 302)
        self.assertEqual(r["Location"], "/owner/login")
        self.assertFalse(OwnerSession.objects.exists())

    def test_not_idle_stays_in(self):
        self.ready()
        OwnerSession.objects.update(last_seen=timezone.now() - timedelta(minutes=29))
        self.assertEqual(self.c.get("/owner/").status_code, 200)

    def test_pre_2fa_session_short_lived(self):
        self.password_login()
        OwnerSession.objects.update(last_seen=timezone.now() - timedelta(minutes=11))
        self.assertEqual(self.c.get("/owner/enrol")["Location"], "/owner/login")

    def test_superuser_revoked_mid_session(self):
        self.ready()
        User.objects.filter(pk=self.owner.pk).update(is_superuser=False)
        r = self.c.get("/owner/")
        self.assertEqual(r["Location"], "/owner/login")

    def test_logout(self):
        self.ready()
        r = self.post("/owner/logout")
        self.assertEqual(r.status_code, 302)
        self.assertFalse(OwnerSession.objects.exists())
        self.assertTrue(OwnerAudit.objects.filter(action="logout").exists())
        self.assertEqual(self.c.get("/owner/")["Location"], "/owner/login")


class CsrfTests(OwnerBase):
    def test_session_token_required_on_every_post(self):
        self.ready()
        r = self.c.post("/owner/pricing", {"section": "scalars"})
        self.assertEqual(r.status_code, 403)
        r = self.c.post("/owner/pricing", {"section": "scalars", "_ot": "wrong"})
        self.assertEqual(r.status_code, 403)

    def test_django_csrf_enforced_on_login(self):
        c = Client(enforce_csrf_checks=True)
        r = c.post("/owner/login", {"phone": OWNER_PHONE, "password": OWNER_PW},
                   secure=True, HTTP_REFERER="https://testserver/owner/login")
        self.assertEqual(r.status_code, 403)
        # with the token from the form it works
        page = c.get("/owner/login", secure=True)
        tok = re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"',
                        page.content.decode()).group(1)
        r = c.post("/owner/login", {"phone": OWNER_PHONE, "password": OWNER_PW,
                                    "csrfmiddlewaretoken": tok},
                   secure=True, HTTP_ORIGIN="https://testserver")
        self.assertEqual(r.status_code, 302)


# =================================================================== sections
class SectionRenderTests(OwnerBase):
    URLS = ("/owner/", "/owner/discover", "/owner/discover/new", "/owner/pricing",
            "/owner/pnl", "/owner/ads", "/owner/integrations", "/owner/users",
            "/owner/reports", "/owner/audit", "/owner/security")

    def test_every_section_renders_bn_and_en(self):
        self.ready()
        for url in self.URLS:
            r = self.c.get(url + "?lang=en")
            self.assertEqual(r.status_code, 200, url)
            self.assertContains(r, "Log out")
            self.assertIn("noindex", r["X-Robots-Tag"])
            r = self.c.get(url + "?lang=bn")
            self.assertEqual(r.status_code, 200, url)
            self.assertContains(r, "লগআউট")

    def test_lang_sticks_to_session(self):
        self.ready()
        self.c.get("/owner/?lang=en")
        self.assertContains(self.c.get("/owner/pnl"), "Profit &amp; loss")

    def test_i18n_complete(self):
        from web.owner.i18n import BN, EN
        self.assertEqual(set(BN) - set(EN), set())
        self.assertEqual(set(EN) - set(BN), set())
        base = os.path.join(os.path.dirname(__file__), "templates", "owner")
        used = set()
        for f in os.listdir(base):
            used |= set(re.findall(r"T\.([a-z0-9_]+)", open(os.path.join(base, f)).read()))
        self.assertEqual(used - set(EN), set())

    def test_empty_states_not_fake(self):
        self.ready()
        r = self.c.get("/owner/pnl?lang=en")
        self.assertContains(r, "No ledger data recorded yet.")
        DiscoverCard.objects.all().delete()
        r = self.c.get("/owner/discover?lang=en")
        self.assertContains(r, "No Discover cards yet")


# =================================================================== discover
from core.logic import discover as _D

# Photo Studio's route only exists once that build is merged; any real route works.
ROUTE = "photo_studio" if "photo_studio" in _D.ROUTE_KEYS else "notes"

CARD = {"type": "FEATURE", "title_bn": "ছবি ঠিক করুন", "title_en": "Fix photos",
        "desc_bn": "এক চাপে", "desc_en": "One tap", "icon": "auto_fix_high",
        "route": ROUTE, "audience": "all", "enabled": "on"}


class DiscoverPanelTests(OwnerBase):
    def setUp(self):
        super().setUp()
        DiscoverCard.objects.all().delete()     # seeded starter cards (migration)
        self.ready()
        self.api = APIClient()
        self.api.force_authenticate(self.owner)

    def test_create_matches_api_rules(self):
        r = self.post("/owner/discover/new", CARD)
        self.assertEqual(r.status_code, 302)
        c = DiscoverCard.objects.get()
        self.assertEqual((c.type, c.title_en, c.route, c.enabled), ("FEATURE", "Fix photos",
                                                                    ROUTE, True))
        a = OwnerAudit.objects.get(action="discover.create")
        self.assertEqual(a.after["title_en"], "Fix photos")
        # unsafe copy: panel and API both refuse it, with the same safety codes
        bad = dict(CARD, title_en="Win cash at our casino")
        r = self.post("/owner/discover/new", bad)
        self.assertEqual(r.status_code, 400)
        api = self.api.post("/api/v1/admin/discover/cards",
                            {k: v for k, v in bad.items() if k != "enabled"}, format="json")
        self.assertEqual(api.status_code, 400)
        for s in api.json()["safety"]:
            self.assertContains(r, s, status_code=400)
        self.assertEqual(DiscoverCard.objects.count(), 1)
        # structural: route AND url -> same error as the API
        both = dict(CARD, url="https://example.com")
        r = self.post("/owner/discover/new", both)
        self.assertContains(r, "route_or_url", status_code=400)

    def test_sponsored_fields_and_non_sponsored_strip(self):
        r = self.post("/owner/discover/new", dict(CARD, type="SPONSORED", sponsor_name="Acme",
                                                  sponsor_revenue="1500.50"))
        self.assertEqual(r.status_code, 302)
        c = DiscoverCard.objects.get()
        self.assertEqual(float(c.sponsor_revenue), 1500.5)
        # sponsored cards reach every plan (premium preview shows it, labelled)
        r = self.c.get("/owner/discover?segment=premium&lang=en")
        self.assertContains(r, "Fix photos")
        self.assertContains(r, "Sponsored")
        r = self.post("/owner/discover/%d" % c.pk, dict(CARD, sponsor_name="Acme",
                                                       sponsor_revenue="99"))
        c.refresh_from_db()
        self.assertEqual((c.type, c.sponsor_name, float(c.sponsor_revenue)), ("FEATURE", "", 0.0))
        a = OwnerAudit.objects.get(action="discover.update")
        self.assertEqual(a.before["type"], "SPONSORED")
        self.assertEqual(a.after["type"], "FEATURE")

    def test_toggle_reorder_delete(self):
        for t in ("One", "Two", "Three"):
            self.post("/owner/discover/new", dict(CARD, title_en=t))
        ids = list(DiscoverCard.objects.values_list("id", flat=True))
        r = self.post("/owner/discover/%d/toggle" % ids[0])
        self.assertFalse(DiscoverCard.objects.get(pk=ids[0]).enabled)
        self.assertTrue(OwnerAudit.objects.filter(action="discover.toggle").exists())
        new = [ids[2], ids[0], ids[1]]
        self.post("/owner/discover/reorder", {"ids": ",".join(map(str, new))})
        self.assertEqual(list(DiscoverCard.objects.values_list("id", flat=True)), new)
        self.post("/owner/discover/reorder", {"move": "%d:up" % ids[1]})
        self.assertEqual(list(DiscoverCard.objects.values_list("id", flat=True)),
                         [ids[2], ids[1], ids[0]])
        # partial id list is refused
        r = self.post("/owner/discover/reorder", {"ids": str(ids[0])})
        self.assertIn("invalid", r["Location"])
        # delete needs the confirm box
        r = self.post("/owner/discover/%d/delete" % ids[0])
        self.assertTrue(DiscoverCard.objects.filter(pk=ids[0]).exists())
        r = self.post("/owner/discover/%d/delete" % ids[0], {"confirm": "on"})
        self.assertFalse(DiscoverCard.objects.filter(pk=ids[0]).exists())
        self.assertTrue(OwnerAudit.objects.filter(action="discover.delete").exists())
        self.assertEqual(OwnerAudit.objects.filter(action="discover.reorder").count(), 2)

    def test_image_upload_validated(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", (8, 8), (10, 20, 30)).save(buf, "PNG")
        self.post("/owner/discover/new", CARD)
        c = DiscoverCard.objects.get()
        r = self.post("/owner/discover/%d" % c.pk, dict(
            CARD, image=SimpleUploadedFile("x.txt", b"not an image", "text/plain")))
        self.assertContains(r, "not_an_image", status_code=400)
        r = self.post("/owner/discover/%d" % c.pk, dict(
            CARD, image=SimpleUploadedFile("a.png", buf.getvalue(), "image/png")))
        self.assertEqual(r.status_code, 302)
        c.refresh_from_db()
        self.assertTrue(c.image)
        c.image.delete(save=True)

    def test_report_range_csv_pdf(self):
        from core.views_discover import record_event
        self.post("/owner/discover/new", CARD)
        c = DiscoverCard.objects.get()
        u = User.objects.create_user(name="V", phone="01710009906", password="x")
        today = timezone.localdate()
        record_event(c, u, "impression", day=today)
        record_event(c, u, "click", day=today)
        record_event(c, u, "impression", day=today - timedelta(days=40))
        q = "from=%s&to=%s" % (today - timedelta(days=6), today)
        r = self.c.get("/owner/discover/%d/report?%s&lang=en" % (c.pk, q))
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "100.0%")       # 1 click / 1 impression in range
        self.assertContains(r, "<svg")
        r = self.c.get("/owner/discover/%d/report.csv?%s" % (c.pk, q))
        self.assertEqual(r["Content-Type"], "text/csv; charset=utf-8")
        body = r.content.decode()
        self.assertIn("total,1,1", body)
        r = self.c.get("/owner/discover/%d/report.pdf?%s" % (c.pk, q))
        self.assertEqual(r["Content-Type"], "application/pdf")
        self.assertTrue(r.content.startswith(b"%PDF"))
        r = self.c.get("/owner/discover/%d/report?from=%s&to=%s" % (
            c.pk, today - timedelta(days=45), today - timedelta(days=35)))
        self.assertContains(r, "1")
        self.assertTrue(OwnerAudit.objects.filter(action="discover.export").exists())


# ================================================================ pricing/ads
class PricingAdsTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_plan_price_edit_and_audit(self):
        from core import billing
        cfg = billing.cfg()
        data = {"section": "plans", "reason": "launch"}
        for pid, row in cfg["plans"].items():
            for k, v in row.items():
                if isinstance(v, bool):
                    if v:
                        data["plans.%s.%s" % (pid, k)] = "on"
                elif isinstance(v, (int, float)):
                    data["plans.%s.%s" % (pid, k)] = str(v)
        data["plans.premium.price"] = "249"
        r = self.post("/owner/pricing", data)
        self.assertEqual(r.status_code, 302, r.content[:400])
        self.assertEqual(billing.cfg()["plans"]["premium"]["price"], 249)
        a = OwnerAudit.objects.get(action="pricing.update")
        self.assertEqual(a.before, {"plans.premium.price": 199})
        self.assertEqual(a.after["plans.premium.price"], 249)
        self.assertEqual(a.after["_reason"], "launch")
        # the pricing engine's own audit trail is written too (same function)
        self.assertEqual(billing.get_config().audit[0]["reason"], "launch")

    def test_plans_v2_card_edits_limits_and_refuses_out_of_range(self):
        """plans-v2: the Owner Admin card (bn/en) edits every limit, bounded."""
        from core import billing
        r = self.c.get("/owner/pricing?lang=en")
        self.assertContains(r, 'id="plans_v2"')
        self.assertContains(r, 'name="plans_v2.free_crm_contacts"')
        self.assertContains(self.c.get("/owner/pricing?lang=bn"), 'id="plans_v2"')
        pv = billing.cfg()["plans_v2"]
        data = {"section": "plans_v2", "reason": "test"}
        for k, v in pv.items():
            if isinstance(v, bool):
                if v:
                    data["plans_v2.%s" % k] = "on"
            else:
                data["plans_v2.%s" % k] = str(v)
        data["plans_v2.free_crm_contacts"] = "25"
        data["plans_v2.business_crm_contacts"] = "60000"
        data.pop("plans_v2.premium_crm_followup_reminders", None)   # untick
        r = self.post("/owner/pricing", data)
        self.assertEqual(r.status_code, 302, r.content[:400])
        c = billing.cfg()["plans_v2"]
        self.assertEqual((c["free_crm_contacts"], c["business_crm_contacts"]), (25, 60000))
        self.assertFalse(c["premium_crm_followup_reminders"])
        self.assertTrue(OwnerAudit.objects.filter(action="pricing.update").exists())
        data["plans_v2.free_crm_contacts"] = "999999"                 # out of bounds
        r = self.post("/owner/pricing", data)
        self.assertEqual(r.status_code, 400)
        self.assertEqual(billing.cfg()["plans_v2"]["free_crm_contacts"], 25)

    def test_invalid_rejected_by_engine(self):
        from core import billing
        r = self.post("/owner/pricing", {"section": "scalars", "s.margin": "0.1"})
        self.assertEqual(r.status_code, 400)
        self.assertNotEqual(billing.cfg()["margin"], 0.1)
        r = self.post("/owner/pricing", {"section": "scalars", "s.margin": "abc"})
        self.assertEqual(r.status_code, 400)
        self.assertTrue(OwnerAudit.objects.filter(action="pricing.rejected").exists())

    def test_hero_and_caps_via_ads(self):
        from core import billing
        cfg = billing.cfg()
        data = {"action": "settings", "reason": "test"}
        has_ps = "photo_studio" in cfg
        for blk, keys in (("ad_rewards", cfg["ad_rewards"]), ("photo_studio", cfg.get("photo_studio") or {})):
            for k, v in keys.items():
                if isinstance(v, bool):
                    if v:
                        data["%s.%s" % (blk, k)] = "on"
                elif isinstance(v, (int, float)):
                    data["%s.%s" % (blk, k)] = str(v)
        # admob (owner 25 Oct): the home native card is ON by default
        self.assertTrue(cfg["ad_rewards"]["hero_enabled"])
        self.assertTrue(cfg["ad_rewards"]["hero_start_muted"])   # default ON
        data.pop("ad_rewards.hero_enabled", None)                 # owner turns it OFF
        if has_ps:
            data["photo_studio.entry_interstitial_gap_min"] = "45"
        r = self.post("/owner/ads", data)
        self.assertEqual(r.status_code, 302, r.content[:400])
        c = billing.cfg()
        self.assertFalse(c["ad_rewards"]["hero_enabled"])
        self.assertTrue(c["ad_rewards"]["hero_start_muted"])
        if has_ps:
            self.assertEqual(c["photo_studio"]["entry_interstitial_gap_min"], 45)
        a = OwnerAudit.objects.get(action="ads.update")
        self.assertEqual(a.after["ad_rewards.hero_enabled"], False)
        # the app's /ads/config carries it to Free users only
        free = User.objects.create_user(name="F", phone="01710009907", password="x")
        api = APIClient()
        api.force_authenticate(free)
        j = api.get("/api/v1/ads/config").json()
        self.assertFalse(j["hero_enabled"])
        self.assertTrue(j["hero_start_muted"])

    def _ads_form(self):
        from core import billing
        cfg = billing.cfg()
        data = {"action": "settings", "reason": "test"}
        for blk, keys in (("ad_rewards", cfg["ad_rewards"]),
                          ("photo_studio", cfg.get("photo_studio") or {})):
            for k, v in keys.items():
                if isinstance(v, bool):
                    if v:
                        data["%s.%s" % (blk, k)] = "on"
                elif isinstance(v, (int, float)):
                    data["%s.%s" % (blk, k)] = str(v)
        return data

    def test_home_native_size_switch(self):
        # owner 27 Oct: compact (default) | large, switchable without a build
        from core import billing
        self.assertEqual(billing.cfg()["ad_rewards"]["home_native_size"], "compact")
        page = self.c.get("/owner/ads")
        self.assertEqual(page.status_code, 200)
        self.assertContains(page, 'name="ad_rewards.home_native_size"')
        free = User.objects.create_user(name="F2", phone="01710009908", password="x")
        api = APIClient()
        api.force_authenticate(free)
        self.assertEqual(api.get("/api/v1/ads/config").json()["home_native_size"], "compact")
        r = self.post("/owner/ads", {**self._ads_form(), "ad_rewards.home_native_size": "large"})
        self.assertEqual(r.status_code, 302, r.content[:400])
        self.assertEqual(billing.cfg()["ad_rewards"]["home_native_size"], "large")
        self.assertEqual(api.get("/api/v1/ads/config").json()["home_native_size"], "large")
        # an unknown value is normalised to compact
        r = self.post("/owner/ads", {**self._ads_form(), "ad_rewards.home_native_size": "HUGE"})
        self.assertEqual(r.status_code, 302, r.content[:400])
        self.assertEqual(billing.cfg()["ad_rewards"]["home_native_size"], "compact")
        self.assertEqual(api.get("/api/v1/ads/config").json()["home_native_size"], "compact")

    def test_flag_flip_needs_reason(self):
        from core import billing
        r = self.post("/owner/ads", {"action": "flag", "flag": "ads_rewarded"})
        self.assertEqual(r.status_code, 400)
        self.assertTrue(billing.flag_on("ads_rewarded"))
        r = self.post("/owner/ads", {"action": "flag", "flag": "ads_rewarded",
                                     "reason": "fraud check"})
        self.assertEqual(r.status_code, 302)
        self.assertFalse(billing.flag_on("ads_rewarded"))
        a = OwnerAudit.objects.get(action="flag.flip")
        self.assertEqual((a.before, a.after["ads_rewarded"]), ({"ads_rewarded": True}, False))
        r = self.post("/owner/ads", {"action": "flag", "flag": "new_signups", "reason": "x"})
        self.assertEqual(r.status_code, 404)

    def test_pricing_api_unchanged(self):
        api = APIClient()
        api.force_authenticate(self.owner)
        r = api.post("/api/v1/admin/pricing", {"config": {"margin": 0.1}}, format="json")
        self.assertEqual(r.status_code, 400)
        r = api.post("/api/v1/admin/pricing", {"config": {"fixed_cost_per_day": 333}},
                     format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["config"]["fixed_cost_per_day"], 333)


# =============================================================== integrations
class IntegrationTests(OwnerBase):
    def setUp(self):
        super().setUp()
        from cryptography.fernet import Fernet
        from core import integrations as I
        self._env = mock.patch.dict(os.environ,
                                    {"INTEGRATIONS_FERNET_KEY": Fernet.generate_key().decode()})
        self._env.start()
        I._FERNET = None
        self.addCleanup(self._cleanup)
        self.ready()

    def _cleanup(self):
        from core import integrations as I
        self._env.stop()
        I._FERNET = None

    def test_key_write_only_masked(self):
        key = "sk-ant-TESTONLY-abcdefghijklmnop-WXYZ"
        r = self.post("/owner/integrations", {"slug": "anthropic", "action": "save",
                                              "api_key": key})
        self.assertEqual(r.status_code, 302)
        from core import integrations as I
        self.assertEqual(I.get("anthropic")["api_key"], key)
        page = self.c.get("/owner/integrations?lang=en").content.decode()
        self.assertNotIn(key, page)
        self.assertNotIn("abcdefghijklmnop", page)
        self.assertIn("WXYZ", page)
        a = OwnerAudit.objects.get(action="integration.save")
        self.assertEqual(a.after, {"api_key": "••••WXYZ"})
        self.assertNotIn("abcdefghijklmnop", str(a.after))
        # empty field keeps the stored key
        self.post("/owner/integrations", {"slug": "anthropic", "action": "save", "api_key": ""})
        self.assertEqual(I.get("anthropic")["api_key"], key)

    def test_test_button_audited(self):
        with mock.patch("core.integrations.test", return_value=("failing", "bad key")):
            r = self.post("/owner/integrations", {"slug": "anthropic", "action": "test"})
        self.assertEqual(r.status_code, 302)
        a = OwnerAudit.objects.get(action="integration.test")
        self.assertFalse(a.ok)

    def test_unknown_slug(self):
        r = self.post("/owner/integrations", {"slug": "nope", "action": "save"})
        self.assertEqual(r.status_code, 404)


# ====================================================================== users
class UserAdminTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()
        self.u = User.objects.create_user(name="Rahim", phone="01710009908", password="pw-r-123")

    def test_search_any_format(self):
        for q in ("+8801710009908", "01710 009908", "Rahim", "#%d" % self.u.pk, "০১৭১০০০৯৯০৮"):
            r = self.c.get("/owner/users", {"q": q})
            self.assertContains(r, "/owner/users/%d" % self.u.pk, msg_prefix=q)

    def test_credit_adjust(self):
        url = "/owner/users/%d" % self.u.pk
        r = self.post(url, {"action": "credits", "delta": "25"})
        self.assertEqual(r.status_code, 400)          # reason required
        r = self.post(url, {"action": "credits", "delta": "25", "reason": "goodwill"})
        self.assertEqual(r.status_code, 302)
        self.u.refresh_from_db()
        bal = self.u.ai_credits
        self.assertGreaterEqual(bal, 25)
        self.assertTrue(CreditLedger.objects.filter(user=self.u, delta=25, reason="adjust").exists())
        self.post(url, {"action": "credits", "delta": str(-(bal + 50)), "reason": "fix"})
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)        # never below zero
        a = OwnerAudit.objects.filter(action="user.credits").first()
        self.assertEqual(a.after["ai_credits"], 0)
        self.assertEqual(a.before["ai_credits"], bal)
        self.assertEqual(a.after["_reason"], "fix")

    def test_change_plan(self):
        url = "/owner/users/%d" % self.u.pk
        self.post(url, {"action": "plan", "plan": "business", "days": "30", "reason": "pilot"})
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "business")
        self.assertGreater(self.u.plan_until, timezone.now() + timedelta(days=29))
        r = self.post(url, {"action": "plan", "plan": "founder", "days": "30", "reason": "x"})
        self.assertEqual(r.status_code, 400)
        self.post(url, {"action": "plan", "plan": "free", "reason": "end pilot"})
        self.u.refresh_from_db()
        self.assertEqual((self.u.plan, self.u.plan_until), ("free", None))
        self.assertEqual(OwnerAudit.objects.filter(action="user.plan").count(), 2)

    def test_block_and_unblock(self):
        token = Token.objects.create(user=self.u)
        api = APIClient()
        api.credentials(HTTP_AUTHORIZATION="Token " + token.key)
        self.assertEqual(api.get("/api/v1/me").status_code, 200)
        url = "/owner/users/%d" % self.u.pk
        r = self.post(url, {"action": "block", "reason": "abuse report"})
        self.assertEqual(r.status_code, 302)
        self.u.refresh_from_db()
        self.assertEqual(self.u.account_status, "suspended")
        self.assertFalse(Token.objects.filter(user=self.u).exists())   # signed out
        self.assertEqual(api.get("/api/v1/me").status_code, 401)
        # a token minted any other way is refused too
        t2 = Token.objects.create(user=self.u)
        api.credentials(HTTP_AUTHORIZATION="Token " + t2.key)
        self.assertEqual(api.get("/api/v1/me").status_code, 401)
        login = APIClient().post("/api/v1/auth/login",
                                 {"identifier": "01710009908", "password": "pw-r-123"},
                                 format="json")
        self.assertEqual(login.status_code, 403)
        self.assertEqual(login.json()["reason"], "account_blocked")
        a = OwnerAudit.objects.get(action="user.block")
        self.assertEqual((a.before["status"], a.after["status"]), ("active", "suspended"))
        self.post(url, {"action": "unblock", "reason": "resolved"})
        login = APIClient().post("/api/v1/auth/login",
                                 {"identifier": "01710009908", "password": "pw-r-123"},
                                 format="json")
        self.assertEqual(login.status_code, 200)

    def test_owner_cannot_be_blocked(self):
        r = self.post("/owner/users/%d" % self.owner.pk, {"action": "block", "reason": "x"})
        self.assertEqual(r.status_code, 400)
        self.owner.refresh_from_db()
        self.assertEqual(self.owner.account_status, "active")


class BlockedApiTests(TestCase):
    def test_otp_login_refuses_blocked(self):
        from core.account_block import is_blocked
        u = User.objects.create_user(name="B", phone="01710009909", password="x",
                                     account_status="banned")
        self.assertTrue(is_blocked(u))
        with mock.patch("core.otp.consume_proof", return_value=True):
            r = APIClient().post("/api/v1/auth/otp/login",
                                 {"phone": "01710009909", "otp_proof": "p"}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertFalse(Token.objects.filter(user=u).exists())


# ============================================================ reports/audit/security
class ReportsSecurityTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_reports_real_counts(self):
        User.objects.create_user(name="N", phone="01710009910", password="x")
        r = self.c.get("/owner/reports?lang=en&days=7")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Sign-ups per day")
        self.assertContains(r, "No consented feature analytics in this period.")
        self.assertEqual(r.context["users_total"], 2)
        signups = [b for b in r.context["blocks"] if b["key"] == "r_signups"][0]
        self.assertEqual(signups["total"], 2)

    def test_audit_page_lists_entries(self):
        r = self.c.get("/owner/audit?action=login&lang=en")
        self.assertContains(r, "login.success")
        self.assertContains(r, "login.password_ok")

    def test_new_recovery_codes(self):
        t = OwnerTOTP.objects.get(user=self.owner)
        old = list(t.recovery_hashes)
        code = S.hotp(self.secret, t.last_counter + 1)
        r = self.post("/owner/security", {"action": "new_codes", "code": code})
        self.assertEqual(r.status_code, 200)
        t.refresh_from_db()
        self.assertEqual(len(t.recovery_hashes), 10)
        self.assertFalse(set(old) & set(t.recovery_hashes))
        r = self.post("/owner/security", {"action": "new_codes", "code": "000000"})
        self.assertEqual(r.status_code, 400)

    def test_reset_2fa_moves_to_new_phone(self):
        r = self.post("/owner/security", {"action": "reset_2fa", "code": self.codes[1],
                                          "password": "wrong"})
        self.assertEqual(r.status_code, 400)
        self.assertTrue(OwnerTOTP.objects.filter(user=self.owner).exists())
        r = self.post("/owner/security", {"action": "reset_2fa", "code": self.codes[2],
                                          "password": OWNER_PW})
        self.assertEqual(r["Location"], "/owner/enrol")
        self.assertFalse(OwnerTOTP.objects.filter(user=self.owner).exists())
        self.assertEqual(self.c.get("/owner/enrol").status_code, 200)

    def test_revoke_other_sessions(self):
        other = SClient()
        self.full_login(other)
        self.assertEqual(OwnerSession.objects.count(), 2)
        self.post("/owner/security", {"action": "revoke_others"})
        self.assertEqual(OwnerSession.objects.count(), 1)
        self.assertEqual(other.get("/owner/")["Location"], "/owner/login")

    def test_cli_reset(self):
        out = io.StringIO()
        call_command("owner_2fa_reset", "+8801710009904", stdout=out)
        self.assertFalse(OwnerTOTP.objects.exists())
        self.assertFalse(OwnerSession.objects.exists())
        self.assertTrue(OwnerAudit.objects.filter(action="security.reset_2fa_cli").exists())
