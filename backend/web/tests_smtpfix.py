"""smtpfix (owner 3 Nov): Owner Admin → Integrations → "Send test email"
shows a clear result line on the card (masked address + BD time, or the
SMTP error in Bangla + English), and every send attempt is logged to the
backend log without secrets. Fake SMTP only — no real mail."""
from unittest import mock

from core import email_sender, integrations
from core.tests_smsotp import APP_PW, FakeSMTP, connect_email
from web.tests_o2_owner_admin import OwnerBase

TO = "owner@example.com"
MASKED = email_sender.mask_email(TO)


@mock.patch("smtplib.SMTP", FakeSMTP)
class SendTestEmailResultTests(OwnerBase):
    def setUp(self):
        super().setUp()
        FakeSMTP.reset()
        connect_email()
        self.ready()

    def _send_test(self):
        r = self.post("/owner/integrations",
                      {"slug": "smtp_email", "action": "test", "test_to": TO})
        self.assertEqual(r.status_code, 302)
        return self.c.get("/owner/integrations").content.decode()

    def test_sent_line_with_masked_address_and_bd_time(self):
        page = self._send_test()
        self.assertEqual(len(FakeSMTP.sent), 1)               # exactly one real email
        self.assertEqual(FakeSMTP.sent[0]["To"], TO)
        self.assertIn('id="result-smtp_email"', page)
        self.assertIn("Sent to %s at " % MASKED, page)
        self.assertIn("BD time", page)
        self.assertNotIn(TO, page)                            # full address never shown

    def test_quota_error_in_bangla_and_english(self):
        FakeSMTP.fail_send = True                             # 550 5.4.5 daily quota
        page = self._send_test()
        self.assertIn("550", page)
        self.assertIn("দৈনিক পাঠানোর সীমা শেষ", page)
        self.assertIn("daily sending quota reached", page)
        self.assertIn("not sent", page)

    def test_bad_credentials_error_line(self):
        FakeSMTP.fail_login = True                            # 535
        page = self._send_test()
        self.assertIn("535", page)
        self.assertIn("bad credentials", page)
        self.assertNotIn("abcdefghijklmnop", page)


@mock.patch("smtplib.SMTP", FakeSMTP)
class SendAttemptLoggedTests(OwnerBase):
    def setUp(self):
        super().setUp()
        FakeSMTP.reset()
        connect_email()

    def test_every_attempt_logged_without_secrets(self):
        with self.assertLogs("assisto.email", level="INFO") as logs:
            email_sender.check(integrations.get("smtp_email"), test_to=TO)
            subject, body = email_sender.otp_email("482913", "bn", 300)
            email_sender.send_email(TO, subject, body, purpose="otp")
            FakeSMTP.fail_send = True
            email_sender.send_email(TO, subject, body, purpose="otp")
        out = "\n".join(logs.output)
        self.assertIn("purpose=test", out)
        self.assertIn("purpose=otp", out)
        self.assertIn("result=sent", out)
        self.assertIn("result=failed", out)
        self.assertIn(MASKED, out)
        for secret in (TO, "482913", APP_PW, "abcdefghijklmnop"):
            self.assertNotIn(secret, out)
