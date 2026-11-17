"""signup-otp (owner P0, 17 Nov) — "a real new user said the sign-up code
did not arrive".

Found (live counts, 48 h): sign-up needs no code at all (SMS gateway off,
password sign-up on); every "missing code" was an email-code SIGN-IN typed
by a person with no account yet. The server answered the neutral "sent if
the account exists" and sent nothing — so the person waited forever.

Pinned here:
  * the typed unknown / unverified address now gets a short "no account
    uses this email yet — create one" note (no code), at most once per 24 h,
    with the SAME API answer as a real account (no enumeration);
  * resend is idempotent: the same request_id inside the cooldown replays
    the first answer (no second code / mail / SMS); a new id still gets 429;
  * every send logs channel / purpose / result / provider reason / ms — and
    never the phone, address or code.
"""
import re
from datetime import timedelta
from unittest import mock

from django.utils import timezone
from rest_framework.test import APITestCase

from core import otp
from core.models import EmailLog, EmailVerification, OtpChallenge, SmsLog, User
from core.tests_smsotp import (CANON, CODE, PHONE, FakeSMTP, alpha_ok, connect,
                               connect_email, mail_text)

REQ = "/api/v1/auth/otp/email/request"
SMS_REQ = "/api/v1/auth/otp/request"
REAL = "rahim@example.com"
NEW = "newperson@example.com"


def _codes(msg):
    return re.findall(r"\b\d{6}\b", mail_text(msg))


@mock.patch("smtplib.SMTP", FakeSMTP)
@mock.patch("core.otp._gen_code", return_value=CODE)
class NoAccountNoticeTests(APITestCase):
    def setUp(self):
        FakeSMTP.reset()
        connect_email()   # SMS gateway off, like production today
        self.u = User.objects.create_user(name="Rahim", phone=CANON, password="pw123456")
        EmailVerification.objects.create(user=self.u, email=REAL)

    def _req(self, email, **kw):
        return self.client.post(REQ, {"purpose": "login", "email": email, **kw},
                                format="json", HTTP_ACCEPT_LANGUAGE="en")

    def test_new_person_gets_a_no_account_note_not_silence(self, _g):
        r = self._req(NEW)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(len(FakeSMTP.sent), 1)
        msg = FakeSMTP.sent[0]
        self.assertEqual(msg["To"], NEW)
        body = mail_text(msg)
        self.assertIn("Create a profile", body)
        self.assertEqual(_codes(msg), [])          # never a code
        ch = OtpChallenge.objects.get()
        self.assertFalse(ch.sent)
        self.assertIn("notice sent", ch.detail)
        self.assertNotIn(NEW, ch.detail)
        self.assertEqual(EmailLog.objects.filter(purpose="otp_noacct", status="sent").count(), 1)

    def test_same_answer_as_a_real_account(self, _g):
        known = self._req(REAL)
        unknown = self._req(NEW)
        self.assertEqual(known.status_code, unknown.status_code)
        self.assertEqual(set(known.data), set(unknown.data))
        self.assertEqual(known.data["message"], unknown.data["message"])
        self.assertIn("Create a profile", unknown.data["message"])
        self.assertEqual([bool(_codes(m)) for m in FakeSMTP.sent], [True, False])

    def test_unverified_address_on_an_account_gets_the_note_too(self, _g):
        User.objects.create_user(name="B", phone="+8801811111111", password="pw123456",
                                 email="unverified@example.com")
        self._req("unverified@example.com")
        self.assertEqual(len(FakeSMTP.sent), 1)
        self.assertEqual(_codes(FakeSMTP.sent[0]), [])

    def test_note_at_most_once_per_day(self, _g):
        self._req(NEW)
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(minutes=5))
        r = self._req(NEW)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(FakeSMTP.sent), 1)
        self.assertIn("skipped_recent", OtpChallenge.objects.first().detail)

    def test_phone_identity_unknown_sends_nothing(self, _g):
        r = self.client.post(REQ, {"purpose": "login", "phone": "01811111111"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(FakeSMTP.sent, [])


@mock.patch("smtplib.SMTP", FakeSMTP)
@mock.patch("core.otp._gen_code", return_value=CODE)
class IdempotentResendTests(APITestCase):
    def setUp(self):
        FakeSMTP.reset()
        connect_email()
        self.u = User.objects.create_user(name="Rahim", phone=CANON, password="pw123456")
        EmailVerification.objects.create(user=self.u, email=REAL)

    def _req(self, rid=None):
        body = {"purpose": "login", "email": REAL}
        if rid:
            body["request_id"] = rid
        return self.client.post(REQ, body, format="json")

    def test_same_request_id_replays_without_a_second_mail(self, _g):
        a = self._req("r-1")
        b = self._req("r-1")
        self.assertEqual((a.status_code, b.status_code), (200, 200), b.data)
        self.assertTrue(b.data["already_sent"])
        self.assertGreater(b.data["resend_in"], 0)
        self.assertLessEqual(b.data["resend_in"], 60)
        self.assertEqual(len(FakeSMTP.sent), 1)
        self.assertEqual(OtpChallenge.objects.count(), 1)
        # the first code still verifies
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"purpose": "login", "email": REAL, "code": CODE}, format="json")
        self.assertEqual(v.status_code, 200, v.data)

    def test_new_request_id_inside_cooldown_is_rate_limited(self, _g):
        self._req("r-1")
        r = self._req("r-2")
        self.assertEqual((r.status_code, r.data["reason"]), (429, "cooldown"))
        r = self._req()   # old clients without an id: unchanged
        self.assertEqual(r.status_code, 429)

    def test_replay_ends_with_the_cooldown(self, _g):
        self._req("r-1")
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(seconds=61))
        r = self._req("r-1")
        self.assertEqual(r.status_code, 200)
        self.assertNotIn("already_sent", r.data)
        self.assertEqual(len(FakeSMTP.sent), 2)

    def test_failed_send_never_replays_as_success(self, _g):
        FakeSMTP.fail_send = True
        first = self._req("r-1")
        self.assertNotEqual(first.status_code, 200)
        FakeSMTP.fail_send = False
        r = self._req("r-1")
        self.assertNotIn("already_sent", r.data or {})


@mock.patch("core.otp._gen_code", return_value=CODE)
class SmsIdempotentAndLogTests(APITestCase):
    def setUp(self):
        connect("sms_alpha", {"api_key": "AK-secret-1"})
        self.u = User.objects.create_user(name="A", phone=CANON, password="pw123456")

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_sms_same_request_id_one_sms(self, http, _g):
        a = self.client.post(SMS_REQ, {"phone": PHONE, "purpose": "login",
                                       "request_id": "x"}, format="json")
        b = self.client.post(SMS_REQ, {"phone": PHONE, "purpose": "login",
                                       "request_id": "x"}, format="json")
        self.assertEqual((a.status_code, b.status_code), (200, 200), b.data)
        self.assertTrue(b.data["already_sent"])
        self.assertEqual(http.call_count, 1)
        self.assertEqual(SmsLog.objects.count(), 1)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_send_log_has_result_and_latency_but_no_pii(self, http, _g):
        with self.assertLogs("assisto.otp", level="INFO") as cm:
            self.client.post(SMS_REQ, {"phone": PHONE, "purpose": "login"}, format="json")
        out = "\n".join(cm.output)
        self.assertIn("channel=sms purpose=login result=sent", out)
        self.assertRegex(out, r"ms=\d+")
        for pii in (PHONE, CANON, CANON[-8:], CODE):
            self.assertNotIn(pii, out)
        self.assertNotIn(CODE, OtpChallenge.objects.get().detail)

    @mock.patch("core.sms_gateway._http", return_value=(500, "down"))
    def test_provider_failure_is_logged_without_pii(self, http, _g):
        with self.assertLogs("assisto.otp", level="INFO") as cm:
            self.client.post(SMS_REQ, {"phone": "01811111111", "purpose": "signup"},
                             format="json")
        out = "\n".join(cm.output)
        self.assertIn("result=failed", out)
        for pii in ("01811111111", "+8801811111111", CODE):
            self.assertNotIn(pii, out)


@mock.patch("smtplib.SMTP", FakeSMTP)
@mock.patch("core.otp._gen_code", return_value=CODE)
class EmailLogNoPiiTests(APITestCase):
    def setUp(self):
        FakeSMTP.reset()
        connect_email()
        self.u = User.objects.create_user(name="Rahim", phone=CANON, password="pw123456")
        EmailVerification.objects.create(user=self.u, email=REAL)

    def test_email_send_and_notice_logs_carry_no_pii(self, _g):
        with self.assertLogs("assisto.otp", level="INFO") as cm:
            self.client.post(REQ, {"purpose": "login", "email": REAL}, format="json")
            self.client.post(REQ, {"purpose": "login", "email": NEW}, format="json")
        out = "\n".join(cm.output)
        self.assertIn("channel=email purpose=login result=sent", out)
        self.assertIn("result=notice_sent", out)
        for pii in (REAL, NEW, "rahim", "newperson", CODE, CANON):
            self.assertNotIn(pii, out)
        self.assertEqual(otp.message("sent_email_neutral", "bn").count("Spam"), 1)
