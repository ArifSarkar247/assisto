"""emailrel (16 Nov) — email reliability: honest failures with the way out,
retry with backoff for temporary errors only, hard-bounce suppression (SMTP
5xx and mailer-daemon reports over IMAP), priority under the daily cap,
provider-quota pause + owner alert, unsubscribe for bulk mail, branded
templates, Owner Admin health card. Fake SMTP / IMAP only — no real mail;
sample addresses are made up."""
import json
import smtplib
import socket
from datetime import timedelta
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core import email_bounces, email_sender, email_templates, otp
from core.models import (EmailLog, EmailSuppression, EmailVerification, OtpChallenge,
                         User)
from core.tests_smsotp import APP_PW, CANON, CODE, PHONE, connect_email, set_cfg

ADDR = "rahim@example.com"
DEAD = "nobody-xyz@example.com"


class ScriptSMTP:
    """smtplib.SMTP stand-in: each send pops the next scripted outcome
    (None = accepted, or an exception to raise)."""
    script = []
    sent = []
    connects = 0

    def __init__(self, host, port, timeout=None):
        ScriptSMTP.connects += 1

    def ehlo(self):
        pass

    def starttls(self):
        pass

    def login(self, user, pw):
        pass

    def send_message(self, msg):
        nxt = ScriptSMTP.script.pop(0) if ScriptSMTP.script else None
        if nxt is not None:
            raise nxt
        ScriptSMTP.sent.append(msg)

    def quit(self):
        pass

    @classmethod
    def reset(cls, *script):
        cls.script, cls.sent, cls.connects = list(script), [], 0


def refused(code, text):
    return smtplib.SMTPRecipientsRefused({DEAD: (code, text.encode())})


class _Base(APITestCase):
    def setUp(self):
        ScriptSMTP.reset()
        connect_email()
        p = [mock.patch("smtplib.SMTP", ScriptSMTP),
             mock.patch.object(email_sender, "_sleep", lambda s: None),
             mock.patch("core.push.notify_owner", return_value={})]
        self.mocks = [x.start() for x in p]
        for x in p:
            self.addCleanup(x.stop)
        self.notify = self.mocks[2]


# ============================================================ classification
class ClassifyTests(TestCase):
    def test_reply_kinds(self):
        c = email_sender.classify_reply
        self.assertEqual(c(550, "5.4.5 Daily user sending quota exceeded"), "quota")
        self.assertEqual(c(550, "5.1.1 The email account that you tried to reach does not exist"), "bounce")
        self.assertEqual(c(553, "5.1.2 bad domain"), "bounce")
        self.assertEqual(c(552, "5.2.2 The email account that you tried to reach is over quota"), "rejected")
        self.assertEqual(c(550, "5.7.1 message rejected as spam"), "rejected")
        self.assertEqual(c(421, "4.7.0 Try again later"), "temp")
        self.assertEqual(c(451, "4.3.0 temporary"), "temp")
        self.assertEqual(c(535, "5.7.8 Username and Password not accepted"), "auth")

    def test_exception_kinds(self):
        k = lambda e: email_sender.classify(e)[0]  # noqa: E731
        self.assertEqual(k(socket.timeout()), "temp")
        self.assertEqual(k(smtplib.SMTPServerDisconnected("x")), "temp")
        self.assertEqual(k(ConnectionRefusedError()), "temp")
        self.assertEqual(k(smtplib.SMTPAuthenticationError(535, b"5.7.8 bad")), "auth")
        self.assertEqual(k(refused(550, "5.1.1 user unknown")), "bounce")
        self.assertEqual(k(refused(452, "4.2.2 mailbox full")), "temp")
        self.assertEqual(k(refused(552, "5.2.2 over quota")), "rejected")
        self.assertEqual(k(smtplib.SMTPDataError(550, b"5.4.5 Daily user sending quota exceeded")),
                         "quota")


# ============================================================ retry / backoff
class RetryTests(_Base):
    def test_temporary_error_is_retried_then_sent(self):
        ScriptSMTP.reset(smtplib.SMTPServerDisconnected("gone"))
        sleeps = []
        with mock.patch.object(email_sender, "_sleep", sleeps.append):
            r = email_sender.send_email(ADDR, "s", "b", purpose="otp")
        self.assertEqual((r["ok"], r["attempts"]), (True, 2))
        self.assertEqual(sleeps, [1.0])
        row = EmailLog.objects.get()
        self.assertEqual((row.status, row.attempts), ("sent", 2))

    def test_temporary_three_times_is_honest_failure(self):
        ScriptSMTP.reset(*[smtplib.SMTPDataError(451, b"4.3.0 try later")] * 3)
        sleeps = []
        with mock.patch.object(email_sender, "_sleep", sleeps.append):
            r = email_sender.send_email(ADDR, "s", "b", purpose="otp")
        self.assertEqual((r["ok"], r["reason"], r["attempts"]), (False, "send_failed", 3))
        self.assertEqual(sleeps, [1.0, 3.0])
        self.assertEqual(EmailLog.objects.get().error_kind, "temp")

    def test_permanent_errors_never_retried(self):
        for exc, reason in ((smtplib.SMTPAuthenticationError(535, b"5.7.8 bad"), "send_failed"),
                            (smtplib.SMTPDataError(550, b"5.7.1 spam"), "email_rejected")):
            ScriptSMTP.reset(exc, None, None)
            r = email_sender.send_email(ADDR, "s", "b", purpose="otp")
            self.assertEqual((r["ok"], r["reason"], r["attempts"]), (False, reason, 1))
            self.assertEqual(ScriptSMTP.connects, 1)
        self.assertFalse(EmailSuppression.objects.exists())     # not the address's fault


# ============================================================ bounces
@mock.patch("core.otp._gen_code", return_value=CODE)
class BounceTests(_Base):
    def setUp(self):
        super().setUp()
        self.u = User.objects.create_user(name="Rahim Uddin", phone=CANON, password="pw123456")
        self.client.force_authenticate(self.u)

    def _verify_req(self, email):
        return self.client.post("/api/v1/auth/otp/email/request",
                                {"purpose": "email_verify", "email": email}, format="json")

    def test_hard_bounce_suppresses_and_user_is_told(self, _g):
        ScriptSMTP.reset(refused(550, "5.1.1 The email account that you tried to reach does not exist"))
        r = self._verify_req(DEAD)
        self.assertEqual((r.status_code, r.data["reason"]), (400, "email_bouncing"))
        self.assertIn("check your email address", otp.message("email_bouncing", "en"))
        self.assertIn("ঠিকানাটি", r.data["message"])
        self.assertTrue(r.data["prefer_sms"])
        row = EmailSuppression.objects.get()
        self.assertEqual((row.reason, row.code), ("hard_bounce", "550"))
        self.assertNotIn(DEAD, row.to_masked + row.detail)
        # no more mail to it (no SMTP connection at all)
        ScriptSMTP.reset()
        r = email_sender.send_email(DEAD, "s", "b", purpose="security_alert")
        self.assertEqual((r["ok"], r["reason"]), (False, "email_bouncing"))
        self.assertEqual(ScriptSMTP.connects, 0)
        self.assertEqual(EmailLog.objects.filter(status="suppressed").count(), 1)

    def test_email_me_shows_bouncing_and_reverify_clears(self, _g):
        EmailVerification.objects.create(user=self.u, email=ADDR)
        email_sender.suppress(ADDR, "hard_bounce", "5.1.1", "DSN")
        me = self.client.get("/api/v1/auth/otp/email/me").data
        self.assertTrue(me["bouncing"])
        self.assertTrue(me["bouncing_message"])
        # the user re-verifies the SAME address: one try is allowed, proves it
        r = self._verify_req(ADDR)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(len(ScriptSMTP.sent), 1)
        c = self.client.post("/api/v1/auth/otp/email/confirm",
                             {"email": ADDR, "code": CODE}, format="json")
        self.assertEqual(c.status_code, 200, c.data)
        self.assertFalse(EmailSuppression.objects.exists())
        self.assertFalse(self.client.get("/api/v1/auth/otp/email/me").data["bouncing"])

    def test_email_failure_message_is_about_email_not_sms(self, _g):
        ScriptSMTP.reset(*[socket.timeout()] * 3)
        r = self._verify_req(ADDR)
        self.assertEqual((r.status_code, r.data["reason"]), (502, "email_send_failed"))
        self.assertTrue(r.data["retry_later"])
        self.assertIn("ইমেইল", r.data["message"])
        self.assertNotIn("SMS পাঠানো যায়নি", r.data["message"])
        ch = OtpChallenge.objects.get()
        self.assertFalse(ch.sent)                       # never a silent success
        self.assertIsNotNone(ch.consumed_at)

    def test_neutral_login_never_reveals_a_bounce(self, _g):
        EmailVerification.objects.create(user=self.u, email=ADDR)
        email_sender.suppress(ADDR, "hard_bounce")
        self.client.force_authenticate(None)
        known = self.client.post("/api/v1/auth/otp/email/request",
                                 {"phone": PHONE, "purpose": "login"}, format="json")
        unknown = self.client.post("/api/v1/auth/otp/email/request",
                                   {"phone": "01811111111", "purpose": "login"}, format="json")
        self.assertEqual(known.status_code, unknown.status_code)
        self.assertEqual(known.data["message"], unknown.data["message"])
        self.assertEqual(set(known.data), set(unknown.data))
        self.assertEqual(ScriptSMTP.connects, 0)             # suppressed: nothing sent
        # the neutral message itself names the way out
        self.assertIn("SMS", otp.message("sent_email_neutral", "en"))
        self.assertIn("SMS", otp.message("sent_email_neutral", "bn"))


# ============================================================ quota + priority
class CapTests(_Base):
    def test_provider_quota_pauses_and_tells_owner_once(self):
        ScriptSMTP.reset(smtplib.SMTPDataError(550, b"5.4.5 Daily user sending quota exceeded"))
        r = email_sender.send_email(ADDR, "s", "b", purpose="otp")
        self.assertEqual((r["reason"], r["attempts"]), ("email_daily_cap", 1))
        st = email_sender.cap_state()
        self.assertTrue(st["blocked"] and st["provider_quota"])
        self.assertEqual(self.notify.call_count, 1)
        ScriptSMTP.reset()
        r = email_sender.send_email(ADDR, "s", "b", purpose="otp")
        self.assertEqual(r["reason"], "email_daily_cap")
        self.assertEqual(ScriptSMTP.connects, 0)
        self.assertFalse(otp.public_status()["email_enabled"])
        # after the pause it tries again
        EmailLog.objects.update(created_at=timezone.now() - timedelta(minutes=61))
        self.assertTrue(email_sender.send_email(ADDR, "s", "b", purpose="otp")["ok"])

    def test_codes_and_security_first_reports_stop_first(self):
        set_cfg("email", daily_cap=10, near_cap_pct=90, bulk_cap_pct=70)
        for _ in range(7):
            EmailLog.objects.create(purpose="otp", to_hash="x", status="sent")
        self.assertEqual(email_sender.send_email(ADDR, "s", "b", purpose="report")["reason"],
                         "email_daily_cap")
        self.assertTrue(email_sender.send_email(ADDR, "s", "b", purpose="notice")["ok"])
        EmailLog.objects.create(purpose="otp", to_hash="x", status="sent")   # 9/10
        self.assertEqual(email_sender.send_email(ADDR, "s", "b", purpose="owner_alert")["reason"],
                         "email_daily_cap")
        self.assertTrue(email_sender.send_email(ADDR, "s", "b", purpose="otp")["ok"])  # 10th
        self.assertEqual(email_sender.send_email(ADDR, "s", "b", purpose="security_alert")["reason"],
                         "email_daily_cap")
        self.assertEqual(len(ScriptSMTP.sent), 2)


# ============================================================ templates
class TemplateTests(_Base):
    def test_otp_mail_is_multipart_dark_safe_and_linkless(self):
        s, text, html = email_sender.otp_email_html(CODE, "bn", 300)
        self.assertTrue(email_sender.send_email(ADDR, s, text, purpose="otp", html=html)["ok"])
        msg = ScriptSMTP.sent[0]
        self.assertEqual(msg.get_content_type(), "multipart/alternative")
        plain = msg.get_body(preferencelist=("plain",)).get_content()
        part = msg.get_body(preferencelist=("html",)).get_content()
        self.assertTrue(plain.startswith("আপনার Assisto যাচাই কোড"))
        self.assertIn('name="color-scheme" content="light dark"', part)
        self.assertIn("prefers-color-scheme: dark", part)
        self.assertIn("৫ মিনিট", part)                       # Bangla digits in Bangla
        self.assertNotIn("href", part)
        self.assertNotIn("<img", part)
        self.assertNotIn("List-Unsubscribe", msg)            # codes: no unsubscribe
        self.assertLess(part.index("আপনার যাচাই কোড"), part.index("Your verification code"))
        en = email_templates.render_otp(CODE, "en", 300)[2]
        self.assertLess(en.index("Your verification code"), en.index("আপনার যাচাই কোড"))

    def test_bulk_mail_has_unsubscribe(self):
        s, text, html = email_templates.render_notice(
            "bn", "সাপ্তাহিক হিসাব", "Weekly summary", "বিক্রি ৳১২,৪০০", "Sales ৳12,400",
            unsubscribe_url=email_sender.unsubscribe_url(ADDR))
        self.assertTrue(email_sender.send_email(ADDR, s, text, purpose="report", html=html)["ok"])
        msg = ScriptSMTP.sent[0]
        self.assertIn("/api/v1/email/unsubscribe?t=", msg["List-Unsubscribe"])
        self.assertEqual(msg["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click")
        self.assertIn("Unsubscribe", text)
        self.assertNotIn(ADDR, msg["List-Unsubscribe"])      # signed hash, not the address

    def test_escaping(self):
        html = email_templates.render_notice("en", "<b>x</b>", "<script>", "a & b", "c < d")[2]
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;script&gt;", html)

    def test_previews_render(self):
        self.assertEqual(len(email_templates._previews()), 6)


# ============================================================ unsubscribe
class UnsubscribeTests(_Base):
    def test_get_confirms_post_unsubscribes_bulk_only(self):
        url = email_sender.unsubscribe_url(ADDR).split("/api/v1", 1)[1]
        g = self.client.get("/api/v1" + url)
        self.assertEqual(g.status_code, 200)
        self.assertFalse(EmailSuppression.objects.exists())   # link scanners: no effect
        self.assertNotIn(ADDR, g.content.decode())
        p = self.client.post("/api/v1" + url)
        self.assertEqual(p.status_code, 200)
        self.assertEqual(EmailSuppression.objects.get().reason, "unsubscribed")
        self.assertEqual(email_sender.send_email(ADDR, "s", "b", purpose="report")["reason"],
                         "email_unsubscribed")
        self.assertTrue(email_sender.send_email(ADDR, "s", "b", purpose="otp")["ok"])
        self.assertFalse(email_sender.is_bouncing(ADDR))

    def test_bad_token(self):
        r = self.client.post("/api/v1/email/unsubscribe?t=forged")
        self.assertEqual(r.status_code, 400)
        self.assertFalse(EmailSuppression.objects.exists())


# ============================================================ DSN / IMAP
def dsn(rcpt, status="5.1.1", action="failed", frm="Mail Delivery Subsystem <mailer-daemon@googlemail.com>"):
    return ("From: %s\r\nTo: assisto-sender@example.com\r\nSubject: Delivery Status Notification (Failure)\r\n"
            "MIME-Version: 1.0\r\nContent-Type: multipart/report; report-type=delivery-status; boundary=\"b1\"\r\n\r\n"
            "--b1\r\nContent-Type: text/plain\r\n\r\nAddress not found\r\n"
            "--b1\r\nContent-Type: message/delivery-status\r\n\r\n"
            "Reporting-MTA: dns; googlemail.com\r\n\r\n"
            "Final-Recipient: rfc822; %s\r\nAction: %s\r\nStatus: %s\r\n"
            "Diagnostic-Code: smtp; 550-5.1.1 The email account that you tried to reach does not exist.\r\n\r\n"
            "--b1--\r\n" % (frm, rcpt, action, status)).encode()


GMAIL_TEXT = ("From: Mail Delivery Subsystem <mailer-daemon@googlemail.com>\r\n"
              "Subject: Delivery Status Notification (Failure)\r\nContent-Type: text/plain\r\n\r\n"
              "** Address not found **\r\n\r\nYour message wasn't delivered to %s because the "
              "address couldn't be found.\r\n" % DEAD).encode()


class FakeIMAP:
    boxes = []
    stored = []

    def __init__(self, host, port, timeout=None):
        self.host = host

    def login(self, u, p):
        pass

    def select(self, box):
        return "OK", [b"1"]

    def search(self, charset, crit):
        if "mailer-daemon" in crit:
            return "OK", [b" ".join(str(i + 1).encode() for i in range(len(FakeIMAP.boxes)))]
        return "OK", [b""]

    def fetch(self, i, what):
        return "OK", [(b"1 (BODY[] {1})", FakeIMAP.boxes[int(i) - 1])]

    def store(self, i, op, flag):
        FakeIMAP.stored.append(i)

    def logout(self):
        pass


class BounceReportTests(_Base):
    def _mailed(self, addr):
        EmailLog.objects.create(purpose="otp", to_hash=email_sender.email_hash(addr),
                                status="sent")

    def test_parse_dsn(self):
        self.assertEqual(email_bounces.parse_dsn(dsn(DEAD))[0][:3], (DEAD, "5.1.1", "failed"))
        self.assertEqual(email_bounces.parse_dsn(GMAIL_TEXT)[0][0], DEAD)

    def test_hard_bounce_from_report_suppresses_only_mailed_addresses(self):
        self._mailed(DEAD)
        self._mailed(ADDR)
        res = email_bounces.apply_reports([dsn(DEAD), dsn("stranger@example.com"),
                                           dsn(ADDR, "5.2.2"),
                                           dsn(DEAD, frm="Someone <x@example.com>")])
        self.assertEqual((res["hard"], res["soft"], res["ignored"]), (1, 1, 2))
        self.assertTrue(email_sender.is_bouncing(DEAD))
        self.assertFalse(EmailSuppression.objects.filter(
            to_hash=email_sender.email_hash("stranger@example.com")).exists())
        self.assertFalse(email_sender.is_bouncing(ADDR))     # mailbox full = soft

    def test_imap_poll_and_tick(self):
        self._mailed(DEAD)
        FakeIMAP.boxes, FakeIMAP.stored = [dsn(DEAD), GMAIL_TEXT], []
        res = email_bounces.tick(imap_cls=FakeIMAP)
        self.assertTrue(res["ok"])
        self.assertEqual(res["reports"], 2)
        self.assertEqual(len(FakeIMAP.stored), 2)              # marked read
        self.assertTrue(email_sender.is_bouncing(DEAD))
        self.assertIsNone(email_bounces.tick(imap_cls=FakeIMAP))   # gated 15 min
        poll = EmailLog.objects.get(status="poll")
        self.assertNotIn(DEAD, poll.detail)
        self.assertEqual(email_sender.cap_state()["used"], 1)  # a poll is not a send
        self.assertEqual(EmailSuppression.objects.get().hits, 2)

    def test_minute_job_registered(self):
        from core import ops_health as H
        names = [n for n, _ in H.MINUTE_JOBS]
        self.assertIn("email_bounces", names)
        self.assertEqual(names[-1], "agent_core_run")
        self.assertEqual(H.JOB_BY_NAME["email_bounces"].via, "minute_jobs")


# ============================================================ notices
class NoticeTests(TestCase):
    @override_settings(EMAIL_BACKEND="django.core.mail.backends.console.EmailBackend")
    def test_unconfigured_notice_is_logged_not_silent(self):
        r = email_sender.send_notice([ADDR], "s", "b", purpose="security_alert")
        self.assertEqual((r["sent"], r["failed"]), (0, 1))
        row = EmailLog.objects.get()
        self.assertEqual((row.status, row.error_kind), ("failed", "config"))
        self.assertNotIn(ADDR, json.dumps(r))

    @mock.patch("smtplib.SMTP", ScriptSMTP)
    def test_security_alert_goes_through_company_sender(self):
        ScriptSMTP.reset()
        connect_email()
        r = email_sender.send_notice([ADDR, ADDR.upper()], "Assisto: x", "body",
                                     html="<p>x</p>", purpose="security_alert")
        self.assertEqual(r["sent"], 1)                         # de-duplicated
        self.assertEqual(EmailLog.objects.get().category, "critical")


# ============================================================ owner admin
class LogPrivacyTests(_Base):
    def test_no_full_address_or_code_in_logs_or_rows(self):
        ScriptSMTP.reset(refused(550, "5.1.1 user unknown"))
        with self.assertLogs("assisto.email", level="INFO") as logs:
            s, t, h = email_sender.otp_email_html(CODE, "bn", 300)
            email_sender.send_email(DEAD, s, t, purpose="otp", html=h)
        out = "\n".join(logs.output)
        rows = json.dumps([list(EmailLog.objects.values()),
                           list(EmailSuppression.objects.values())], default=str)
        for secret in (DEAD, CODE, APP_PW, "abcdefghijklmnop"):
            self.assertNotIn(secret, out)
            self.assertNotIn(secret, rows)
        self.assertIn(email_sender.mask_email(DEAD), out)
