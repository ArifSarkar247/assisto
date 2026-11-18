"""gap-recovery (board rows 52 + 58) — account recovery after a lost phone,
and the email the recovery depends on. Fake SMTP / IMAP / push only; every
name, number and address is made up.

  * lost phone -> new phone signs in with the EMAIL code -> My Circle,
    messages (ciphertext) and the sealed key backup are all there; the lost
    phone is listed and "sign out other phones" really cuts it off;
  * a sign-in on a NEW phone pushes + emails the owner (never on sign-up, on
    the same phone again, or for an older build without a device id);
  * no enumeration through verify: a code typed for an email / number with
    no account answers exactly like a wrong code for a real account (tries
    left -> lockout), never "no active code";
  * a code typed with Bangla digits works;
  * every email template: < 100 KB, no images / tracking pixels / remote
    CSS / scripts, light + dark colours defined for every class, WCAG AA
    contrast for small text in both modes;
  * bounce path end to end: code sent -> mailer-daemon report over IMAP ->
    address suppressed -> next code request says "email bouncing" (with the
    SMS / password way out) -> re-verifying the address clears it.
"""
import base64
import os
import re
from html.parser import HTMLParser
from unittest import mock

from django.test import TestCase, override_settings
from rest_framework.test import APIClient, APITestCase

from core import email_bounces, email_sender, email_templates, otp, signin_alert
from core.models import (CircleMember, CircleMessage, DeviceSession, EmailVerification,
                         OtpChallenge, User)
from core.tests_emailrel import FakeIMAP, dsn
from core.tests_smsotp import CODE, FakeSMTP, connect_email, mail_text

V = "/api/v1"
ADDR = "rahim.lost@example.com"
PW = "Lost#Phone2026"


def _b64(n):
    return base64.b64encode(os.urandom(n)).decode()


def _client(dev_id, name):
    c = APIClient()
    c.credentials(HTTP_X_SESSION_MODE="device", HTTP_X_DEVICE_ID=dev_id,
                  HTTP_X_DEVICE_NAME=name, HTTP_ACCEPT_LANGUAGE="en")
    return c


def _auth(c, token, dev_id, name):
    c.credentials(HTTP_AUTHORIZATION="Token " + token, HTTP_X_SESSION_MODE="device",
                  HTTP_X_DEVICE_ID=dev_id, HTTP_X_DEVICE_NAME=name,
                  HTTP_ACCEPT_LANGUAGE="en")
    return c


def _codes(msg):
    return re.findall(r"\b\d{6}\b", mail_text(msg))


@override_settings(PUSH_SYNC=True)
@mock.patch("smtplib.SMTP", FakeSMTP)
class LostPhoneRecoveryTests(APITestCase):
    """The scripted backend half of 'phone lost -> sign in on a new phone'."""

    def setUp(self):
        FakeSMTP.reset()
        connect_email()
        self.a = User.objects.create_user(name="Rahim Test", phone="+8801711000101",
                                          password=PW)
        self.b = User.objects.create_user(name="Karim Test", phone="+8801711000102",
                                          password=PW)
        EmailVerification.objects.create(user=self.a, email=ADDR)
        self.ab = CircleMember.objects.create(user=self.a, peer_user=self.b, name="Karim Test",
                                              state="accepted", phone=self.b.phone)
        self.ba = CircleMember.objects.create(user=self.b, peer_user=self.a, name="Rahim Test",
                                              state="accepted", phone=self.a.phone,
                                              direction="incoming")
        self.ct = _b64(64)
        CircleMessage.objects.create(member=self.ba, sender=self.b, recipient_ids=[self.a.pk],
                                     ciphertext=self.ct, nonce=_b64(24), sender_key_id="kA1",
                                     scheme="x25519-chacha20poly1305", client_msg_id="gr-1")
        # the OLD phone: signed in, sealed key backup uploaded
        c = _client("old-phone-1", "Realme 9i")
        r = c.post(V + "/auth/login", {"identifier": "01711000101", "password": PW},
                   format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.old = _auth(c, r.data["token"], "old-phone-1", "Realme 9i")
        r = self.old.post(V + "/e2/backup", {
            "salt": _b64(16), "kdf": {"alg": "scrypt", "n": 32768, "r": 8, "p": 1},
            "auth_key": _b64(32), "blob": _b64(200), "nonce": _b64(12),
            "key_ids": ["kA1"], "current_key_id": "kA1"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        FakeSMTP.reset()

    def _new_phone_login(self):
        new = _client("new-phone-2", "Samsung A15")
        r = new.post(V + "/auth/otp/email/request",
                     {"purpose": "login", "email": ADDR, "request_id": "gr-req-1"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(len(FakeSMTP.sent), 1)
        code = _codes(FakeSMTP.sent[0])[0]          # read from the captured mail
        bad = new.post(V + "/auth/otp/verify",
                       {"purpose": "login", "email": ADDR, "code": "000000"}, format="json")
        self.assertEqual(bad.status_code, 400)
        self.assertEqual(bad.data["reason"], "invalid_code")
        self.assertEqual(bad.data["attempts_left"], 4)
        r = new.post(V + "/auth/otp/verify",
                     {"purpose": "login", "email": ADDR, "code": code}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        with self.captureOnCommitCallbacks(execute=True):
            r = new.post(V + "/auth/otp/login",
                         {"email": ADDR, "otp_proof": r.data["otp_proof"]}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        return _auth(new, r.data["token"], "new-phone-2", "Samsung A15")

    @mock.patch("core.push.push_to_user", return_value=1)
    def test_lost_phone_email_code_restores_circle_history_and_backup(self, push):
        new = self._new_phone_login()
        # My Circle + history (ciphertext, opened on the phone with the
        # restored key) + the sealed key backup are all on the new phone
        mem = new.get(V + "/circle/members").json()
        rows = (mem.get("results") or mem.get("members") or []) if isinstance(mem, dict) else mem
        self.assertIn("Karim Test", [m.get("name") for m in rows])
        msgs = new.get(V + "/circle/%d/messages" % self.ab.pk).json()
        msgs = (msgs.get("results") or msgs.get("messages") or []) if isinstance(msgs, dict) else msgs
        self.assertIn(self.ct, [m.get("ciphertext") for m in msgs])
        bk = new.get(V + "/e2/backup").json()
        self.assertTrue(bk["exists"])
        self.assertNotIn("blob", str(bk))                # blob only after the PIN proof
        # the owner is told: push to the account + "new sign-in" mail
        self.assertTrue(any("Samsung A15" in str(c) for c in push.call_args_list))
        alert = FakeSMTP.sent[-1]
        self.assertIn("Samsung A15", mail_text(alert))
        self.assertIn("Account & security", mail_text(alert))
        # the lost phone is listed; "sign out other phones" really cuts it off
        sec = new.get(V + "/account/security").json()
        names = {d["name"]: d["current"] for d in sec["devices"]}
        self.assertEqual(names, {"Samsung A15": True, "Realme 9i": False})
        self.assertEqual(self.old.get(V + "/me").status_code, 200)
        r = new.post(V + "/account/security/devices/signout-others", format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(self.old.get(V + "/me").status_code, 401)
        self.assertEqual(new.get(V + "/me").status_code, 200)

    @mock.patch("core.push.push_to_user", return_value=1)
    def test_no_alert_on_signup_same_phone_or_old_build(self, push):
        # same phone signs in again -> quiet
        c = _client("old-phone-1", "Realme 9i")
        with self.captureOnCommitCallbacks(execute=True):
            r = c.post(V + "/auth/login", {"identifier": "01711000101", "password": PW},
                       format="json")
        self.assertEqual(r.status_code, 200)
        # older build (no device-session header) -> legacy token, quiet
        with self.captureOnCommitCallbacks(execute=True):
            r = APIClient().post(V + "/auth/login",
                                 {"identifier": "01711000101", "password": PW}, format="json")
        self.assertEqual(r.status_code, 200)
        push.assert_not_called()
        self.assertEqual(FakeSMTP.sent, [])
        # first ever sign-in of a brand-new account -> quiet
        u = User.objects.create_user(name="New Person", phone="+8801711000109", password=PW)
        s = DeviceSession.objects.create(user=u, key_hash="x" * 64, device_id="d9",
                                         device_name="Pixel")
        self.assertFalse(signin_alert.is_new_device(u, s))

    @mock.patch("core.push.push_to_user", return_value=1)
    def test_password_sign_in_on_new_phone_alerts_too(self, push):
        c = _client("thief-phone", "Unknown Android")
        with self.captureOnCommitCallbacks(execute=True):
            r = c.post(V + "/auth/login", {"identifier": "01711000101", "password": PW},
                       format="json")
        self.assertEqual(r.status_code, 200)
        push.assert_called_once()
        self.assertEqual(push.call_args[1]["data"]["reason"], "new_signin")
        self.assertEqual(len(FakeSMTP.sent), 1)
        self.assertIn("Unknown Android", mail_text(FakeSMTP.sent[0]))

    @mock.patch("core.push.push_to_user", side_effect=RuntimeError("fcm down"))
    def test_alert_failure_never_blocks_sign_in(self, _p):
        c = _client("other-phone", "Nokia G21")
        with mock.patch("core.email_sender.send_email", side_effect=RuntimeError("smtp down")):
            with self.captureOnCommitCallbacks(execute=True):
                r = c.post(V + "/auth/login", {"identifier": "01711000101", "password": PW},
                           format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["token"])

    def test_alert_texts_bangla_digits_and_no_pii(self):
        from django.utils import timezone
        tb, te, bb, be = signin_alert.texts("Realme 9i", "code", timezone.now())
        self.assertIn("Realme 9i", tb)
        when = bb.split(" (", 1)[0]               # the Bangla time: Bangla digits + month
        self.assertNotRegex(when, r"[0-9A-Za-z]")
        self.assertRegex(when, "[০-৯]")
        for t in (tb, te, bb, be):
            self.assertNotIn(ADDR, t)
            self.assertNotIn("01711000101", t)


@mock.patch("smtplib.SMTP", FakeSMTP)
class BanglaDigitCodeTests(APITestCase):
    """(The enumeration parity tests live in tests_otp_decoy — the hotfix.)"""

    def setUp(self):
        FakeSMTP.reset()
        connect_email()
        self.u = User.objects.create_user(name="Rahim Test", phone="+8801711000101",
                                          password=PW)
        EmailVerification.objects.create(user=self.u, email=ADDR)

    @mock.patch("core.otp._gen_code", return_value=CODE)
    def test_bangla_digit_code_works(self, _g):
        r = self.client.post(V + "/auth/otp/email/request", {"purpose": "login", "email": ADDR},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        bn = CODE.translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))
        r = self.client.post(V + "/auth/otp/verify",
                             {"purpose": "login", "email": ADDR, "code": bn}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["otp_proof"])


# ============================================================ email templates
class _Tags(HTMLParser):
    VOID = {"meta", "br", "img", "hr", "link", "input"}

    def __init__(self):
        super().__init__()
        self.stack, self.errors, self.classes, self.tags, self.attrs = [], [], set(), set(), []

    def handle_starttag(self, tag, attrs):
        self.tags.add(tag)
        self.attrs.extend(attrs)
        for k, v in attrs:
            if k == "class":
                self.classes.update((v or "").split())
        if tag not in self.VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in self.VOID:
            return
        if not self.stack or self.stack[-1] != tag:
            self.errors.append("unbalanced </%s>" % tag)
            return
        self.stack.pop()


def _lum(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def contrast(a, b):
    la, lb = _lum(a), _lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def _css_blocks():
    css = email_templates._CSS
    light, dark = css.split("@media (prefers-color-scheme: dark){", 1)
    dark = dark.split("\n}\n", 1)[0]

    def rules(txt):
        out = {}
        for sel, body in re.findall(r"([^{}]+)\{([^{}]*)\}", txt):
            for s in sel.split(","):
                out[s.strip()] = body
        return out
    return rules(light), rules(dark)


def _color(body, prop):
    m = re.search(r"(?<![-\w])%s:\s*(#[0-9A-Fa-f]{6})" % prop, body)
    return m.group(1) if m else None


def _all_templates():
    out = {}
    for lang in ("bn", "en"):
        out["otp_" + lang] = email_templates.render_otp("482913", lang, 300)
        out["notice_" + lang] = email_templates.render_notice(
            lang, "আপনার ইমেইল বদলানো হয়েছে", "Your email was changed",
            "আপনি না করলে নিচের বোতাম চাপুন।", "If not, tap the button below.",
            action_url="https://lifeassisto.com/api/v1/account/not-me/sample",
            action_bn="এটা আমি নই", action_en="This was not me")
        from django.utils import timezone
        tb, te, bb, be = signin_alert.texts("Realme 9i", "code", timezone.now(), lang)
        out["signin_" + lang] = email_templates.render_notice(lang, tb, te, bb, be)
        out["noacct_" + lang] = email_templates.render_notice(
            lang, otp.NOTICE_TEXTS["title"][0], otp.NOTICE_TEXTS["title"][1],
            otp.NOTICE_TEXTS["body"][0], otp.NOTICE_TEXTS["body"][1])
    return out


class EmailTemplateQualityTests(TestCase):
    def test_every_template_small_wellformed_and_pixel_free(self):
        for name, (subject, text, html) in _all_templates().items():
            with self.subTest(name):
                self.assertLess(len(html.encode("utf-8")), 100 * 1024)
                self.assertLess(len(text.encode("utf-8")), 100 * 1024)
                p = _Tags()
                p.feed(html)
                self.assertEqual(p.errors, [])
                self.assertEqual(p.stack, [])
                # no tracking: no images, remote CSS, scripts, frames, forms
                for tag in ("img", "link", "script", "iframe", "object", "form", "video"):
                    self.assertNotIn(tag, p.tags)
                low = html.lower()
                for bad in ("url(", "@import", "<img", "width=\"1\"", "height=\"1\"",
                            "pixel", "track", "utm_", "beacon"):
                    self.assertNotIn(bad, low)
                hrefs = [v for k, v in p.attrs if k in ("href", "src")]
                for h in hrefs:
                    self.assertTrue(h.startswith("https://lifeassisto.com/"), h)
                if name.startswith("otp_"):
                    self.assertEqual(hrefs, [])     # a code mail carries no link at all
                self.assertTrue(subject and "\n" not in subject)

    def test_light_and_dark_colours_for_every_class_used(self):
        light, dark = _css_blocks()
        used = set()
        for _n, (_s, _t, html) in _all_templates().items():
            p = _Tags()
            p.feed(html)
            used |= p.classes
            self.assertIn('name="color-scheme" content="light dark"', html)
            self.assertIn("prefers-color-scheme: dark", html)
        for cls in used:
            with self.subTest(cls):
                self.assertIn("." + cls, light)
                if cls != "btn":    # the button keeps its colours in dark mode
                    self.assertIn("." + cls, " ".join(dark.keys()))

    def test_wcag_contrast_light_and_dark(self):
        light, dark = _css_blocks()
        card_l, card_d = _color(light[".card"], "background"), _color(dark[".card"], "background")
        bg_l = _color(light[".bg"], "background")
        bg_d = _color(dark["body"], "background")
        pairs = [
            ("light text", _color(light[".card"], "color"), card_l),
            ("light muted", _color(light[".mut"], "color"), card_l),
            ("light code", _color(light[".code"], "color"), _color(light[".code"], "background")),
            ("light footer", _color(light[".foot"], "color"), bg_l),
            ("light link", _color(light["a"], "color"), card_l),
            ("button", _color(light[".btn"], "color"), _color(light[".btn"], "background")),
            ("dark text", _color(dark[".card"], "color"), card_d),
            ("dark muted", _color(dark[".mut"], "color"), card_d),
            ("dark code", _color(dark[".code"], "color"), _color(dark[".code"], "background")),
            ("dark footer", _color(dark[".foot"], "color"), bg_d),
            ("dark link", _color(dark["a"], "color"), card_d),
        ]
        for name, fg, bg in pairs:
            with self.subTest(name):
                self.assertTrue(fg and bg, name)
                self.assertGreaterEqual(contrast(fg, bg), 4.5, "%s %s on %s" % (name, fg, bg))
        # inline fallbacks (clients that drop <style>) match the light palette
        html = email_templates.render_notice("en", "t", "t", "b", "b",
                                             action_url="https://lifeassisto.com/x",
                                             action_bn="x", action_en="x")[2]
        self.assertIn("background:%s;color:#FFFFFF" % _color(light[".btn"], "background"), html)
        self.assertIn("color:%s" % _color(light[".foot"], "color"), html)


# ============================================================ bounce path
@mock.patch("smtplib.SMTP", FakeSMTP)
@mock.patch("core.otp._gen_code", return_value=CODE)
class BouncePathTests(APITestCase):
    DEAD = "rahim.typo@example.com"

    def setUp(self):
        FakeSMTP.reset()
        connect_email()
        self.u = User.objects.create_user(name="Rahim Test", phone="+8801711000101",
                                          password=PW)
        self.client.force_authenticate(self.u)

    def test_send_bounce_report_suppress_tell_user_reverify_clears(self, _g):
        EmailVerification.objects.create(user=self.u, email=self.DEAD)
        # 1. a code goes out to the (mistyped) address
        r = self.client.post(V + "/auth/otp/email/request",
                             {"purpose": "section8"}, format="json", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(len(FakeSMTP.sent), 1)
        # 2. Gmail's mailer-daemon report arrives; the 15-min IMAP tick reads it
        FakeIMAP.boxes, FakeIMAP.stored = [dsn(self.DEAD)], []
        res = email_bounces.tick(imap_cls=FakeIMAP)
        self.assertTrue(res["ok"])
        self.assertTrue(email_sender.is_bouncing(self.DEAD))
        # 3. the next code is NOT sent into the void: honest reason + way out
        FakeSMTP.reset()
        OtpChallenge.objects.all().delete()
        r = self.client.post(V + "/auth/otp/email/request",
                             {"purpose": "section8"}, format="json", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.data["reason"], "email_bouncing")
        self.assertTrue(r.data.get("prefer_sms"))
        self.assertEqual(FakeSMTP.sent, [])
        me = self.client.get(V + "/auth/otp/email/me").json()
        self.assertTrue(me.get("bouncing"), me)
        # 4. the person re-verifies the address (now fixed) -> clears it
        OtpChallenge.objects.all().delete()
        r = self.client.post(V + "/auth/otp/email/request",
                             {"purpose": "email_verify", "email": self.DEAD}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        r = self.client.post(V + "/auth/otp/email/confirm",
                             {"email": self.DEAD, "code": CODE}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertFalse(email_sender.is_bouncing(self.DEAD))
        # the IMAP poll log row never carries the address
        from core.models import EmailLog
        for row in EmailLog.objects.all():
            self.assertNotIn(self.DEAD, row.detail or "")
