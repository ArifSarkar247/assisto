"""gap-recovery hotfix — no account enumeration through auth/otp/verify.

A code typed for an email / number that got the neutral "sent" answer but no
code (no account, or no verified email) used to answer "no_active_code" at
once, while a real account answered "invalid_code, 4 tries left". Now both
answer the same: tries left -> lockout -> expired. Fake SMTP / SMS only;
made-up addresses and numbers.
"""
import logging
from datetime import timedelta
from unittest import mock

from django.utils import timezone
from rest_framework.test import APITestCase

from core.models import EmailVerification, OtpChallenge, User
from core.tests_smsotp import FakeSMTP, alpha_ok, connect, connect_email

V = "/api/v1"
ADDR = "rahim.decoy@example.com"
STRANGER = "no-account-here@example.com"
PW = "Decoy#Test2026"


@mock.patch("smtplib.SMTP", FakeSMTP)
class VerifyEnumerationTests(APITestCase):
    def setUp(self):
        FakeSMTP.reset()
        connect_email()
        self.u = User.objects.create_user(name="Rahim Test", phone="+8801711000101",
                                          password=PW)
        EmailVerification.objects.create(user=self.u, email=ADDR)

    def _ask(self, addr):
        r = self.client.post(V + "/auth/otp/email/request", {"purpose": "login", "email": addr},
                             format="json", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 200, r.data)
        return r

    def _try(self, addr, code="111111"):
        return self.client.post(V + "/auth/otp/verify",
                                {"purpose": "login", "email": addr, "code": code},
                                format="json", HTTP_ACCEPT_LANGUAGE="en")

    @staticmethod
    def _sig(r):
        return (r.status_code, r.data["reason"], r.data.get("attempts_left"))

    def test_unknown_email_answers_like_a_real_wrong_code(self):
        self._ask(ADDR)
        self._ask(STRANGER)
        seq_real = [self._sig(self._try(ADDR)) for _ in range(6)]
        seq_fake = [self._sig(self._try(STRANGER)) for _ in range(6)]
        self.assertEqual(seq_real, seq_fake)
        self.assertEqual(seq_fake[0], (400, "invalid_code", 4))
        self.assertEqual(seq_fake[4][1], "locked")
        self.assertEqual(seq_fake[5][1], "locked")
        self.assertFalse(OtpChallenge.objects.filter(email=STRANGER, sent=True).exists())

    def test_expired_answers_match(self):
        self._ask(ADDR)
        self._ask(STRANGER)
        OtpChallenge.objects.update(expires_at=timezone.now() - timedelta(seconds=1))
        real = [self._sig(self._try(ADDR)) for _ in range(2)]
        fake = [self._sig(self._try(STRANGER)) for _ in range(2)]
        self.assertEqual(real, fake)
        self.assertEqual([x[1] for x in fake], ["expired", "no_active_code"])

    def test_no_request_at_all_still_no_active_code(self):
        self.assertEqual(self._try(STRANGER).data["reason"], "no_active_code")
        self.assertEqual(self._try(ADDR).data["reason"], "no_active_code")

    def test_unknown_phone_answers_like_a_real_wrong_code(self):
        with mock.patch("core.sms_gateway._http", side_effect=alpha_ok):
            connect("sms_alpha", {"api_key": "AK-test-1"})
            for phone in ("01711000101", "01711000188"):
                r = self.client.post(V + "/auth/otp/request", {"purpose": "login", "phone": phone},
                                     format="json")
                self.assertEqual(r.status_code, 200, r.data)
        real = self.client.post(V + "/auth/otp/verify",
                                {"purpose": "login", "phone": "01711000101", "code": "000000"},
                                format="json")
        fake = self.client.post(V + "/auth/otp/verify",
                                {"purpose": "login", "phone": "01711000188", "code": "000000"},
                                format="json")
        self.assertEqual(self._sig(fake), self._sig(real))
        self.assertEqual(fake.data["reason"], "invalid_code")

    def test_logs_carry_no_address_or_code(self):
        with self.assertLogs("assisto.otp", level=logging.INFO) as cm:
            self._ask(ADDR)
            self._ask(STRANGER)
            self._try(STRANGER)
        joined = "\n".join(cm.output)
        for s in (ADDR, STRANGER, "111111"):
            self.assertNotIn(s, joined)
