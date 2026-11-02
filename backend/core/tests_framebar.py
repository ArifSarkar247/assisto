"""framebar (2 Nov) — the server contract the launch login screen relies on.

At launch the SMS gateway is OFF and email codes are ON. The app reads
GET /auth/otp/status to decide which one-time-code button to show:
  sms on            -> "Sign in with an SMS code"
  sms off, email on -> "Sign in with a code by email" (phone OR email)
  both off          -> no button (never a dead end)
and the email-code flow must work end to end with SMS off, for both a phone
identity and an email identity, without leaking which accounts exist.
"""
from unittest import mock

from rest_framework.test import APITestCase

from core.models import EmailVerification, Integration, User
from core.tests_smsotp import CANON, CODE, PHONE, FakeSMTP, connect_email

STATUS = "/api/v1/auth/otp/status"


@mock.patch("smtplib.SMTP", FakeSMTP)
@mock.patch("core.otp._gen_code", return_value=CODE)
class LaunchLoginContractTests(APITestCase):
    def setUp(self):
        FakeSMTP.reset()
        connect_email()  # SMS gateway is never connected in this class
        self.u = User.objects.create_user(name="Rahim", phone=CANON, password="pw123456")
        EmailVerification.objects.create(user=self.u, email="rahim@example.com")

    def test_status_says_sms_off_email_on(self, _g):
        r = self.client.get(STATUS)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["sms_enabled"])
        self.assertTrue(r.data["email_enabled"])

    def test_status_both_off_when_email_not_connected(self, _g):
        Integration.objects.filter(slug="smtp_email").update(status="not_set")
        r = self.client.get(STATUS)
        self.assertFalse(r.data["sms_enabled"])
        self.assertFalse(r.data["email_enabled"])

    def test_sms_request_is_honest_and_points_to_email(self, _g):
        r = self.client.post("/api/v1/auth/otp/request",
                             {"phone": PHONE, "purpose": "login"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (503, "sms_not_configured"))
        self.assertTrue(r.data["email_enabled"])

    def _email_login(self, ident):
        r = self.client.post("/api/v1/auth/otp/email/request",
                             {"purpose": "login", **ident}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"purpose": "login", "code": CODE, **ident}, format="json")
        self.assertEqual(v.status_code, 200, v.data)
        return self.client.post("/api/v1/auth/otp/login",
                                {"otp_proof": v.data["otp_proof"], **ident},
                                format="json")

    def test_email_identity_signs_in_with_sms_off(self, _g):
        r = self._email_login({"email": "rahim@example.com"})
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["user"]["id"], self.u.pk)
        self.assertTrue(r.data["token"])

    def test_phone_identity_gets_email_code_with_sms_off(self, _g):
        r = self._email_login({"phone": PHONE})
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(FakeSMTP.sent[0]["To"], "rahim@example.com")

    def test_unknown_email_gets_the_same_neutral_answer(self, _g):
        known = self.client.post("/api/v1/auth/otp/email/request",
                                 {"purpose": "login", "email": "rahim@example.com"},
                                 format="json")
        unknown = self.client.post("/api/v1/auth/otp/email/request",
                                   {"purpose": "login", "email": "nobody@example.com"},
                                   format="json")
        self.assertEqual(known.status_code, unknown.status_code)
        self.assertEqual(set(known.data), set(unknown.data))
        self.assertEqual(len(FakeSMTP.sent), 1)  # only the real account got mail
