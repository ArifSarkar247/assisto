"""Play reviewer demo login: one fixed number + one fixed login code, from the
server .env only. Any other number, purpose or code behaves exactly as before."""
import os
from unittest import mock

from rest_framework.test import APITestCase

from core import otp
from core.models import User, OtpChallenge
from core.tests_o1_otp import enable_sms, http_ok

# Test-only values (the real reviewer number/code live only in the server .env).
RV_PHONE = "01000000077"
RV_CANON = "+8801000000077"
RV_CODE = "314159"
ENV = {"PLAY_REVIEWER_PHONE": RV_PHONE, "PLAY_REVIEWER_OTP": RV_CODE}


@mock.patch.dict(os.environ, ENV)
@mock.patch("core.sms_gateway._http", side_effect=http_ok)
class PlayReviewerOtpTests(APITestCase):
    def setUp(self):
        enable_sms()
        self.u = User.objects.create_user(name="Play Reviewer", phone=RV_PHONE,
                                          password="pw-long-123456")

    def _request(self, phone=RV_PHONE, purpose="login"):
        return self.client.post("/api/v1/auth/otp/request",
                                {"phone": phone, "purpose": purpose}, format="json")

    def _verify(self, code, phone=RV_PHONE, purpose="login"):
        return self.client.post("/api/v1/auth/otp/verify",
                                {"phone": phone, "purpose": purpose, "code": code},
                                format="json")

    def test_normalises_only_the_reviewer_number(self, http):
        for raw in (RV_PHONE, RV_CANON, "8801000000077", "০১০০০০০০০৭৭"):
            self.assertEqual(otp.normalize_bd_phone(raw), RV_CANON, raw)
        self.assertIsNone(otp.normalize_bd_phone("01000000078"))

    def test_fixed_code_logs_in_without_sms(self, http):
        r = self._request()
        self.assertEqual(r.status_code, 200, r.data)
        http.assert_not_called()                      # no SMS sent
        ch = OtpChallenge.objects.get(phone=RV_CANON, purpose="login")
        self.assertTrue(ch.sent)
        self.assertNotIn(RV_CODE, ch.code_hash)       # still only a hash
        r = self._verify(RV_CODE)
        self.assertEqual(r.status_code, 200, r.data)
        r = self.client.post("/api/v1/auth/otp/login",
                             {"phone": RV_PHONE, "otp_proof": r.data["otp_proof"]},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["token"])

    def test_wrong_code_still_counts_and_locks(self, http):
        self._request()
        r = self._verify("000000")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["reason"], "invalid_code")

    def test_fixed_code_only_for_login(self, http):
        r = self._request(purpose="password_reset")
        self.assertEqual(r.status_code, 200, r.data)
        http.assert_called()                          # normal random code via SMS
        self.assertEqual(self._verify(RV_CODE, purpose="password_reset").status_code, 400)

    def test_other_numbers_never_accept_the_fixed_code(self, http):
        User.objects.create_user(name="X", phone="01712345678", password="pw-long-123456")
        with mock.patch("core.otp._gen_code", return_value="271828"):
            self._request(phone="01712345678")
        self.assertEqual(self._verify(RV_CODE, phone="01712345678").status_code, 400)

    def test_without_env_the_number_is_not_special(self, http):
        with mock.patch.dict(os.environ, {"PLAY_REVIEWER_PHONE": "", "PLAY_REVIEWER_OTP": ""}):
            self.assertIsNone(otp.normalize_bd_phone(RV_PHONE))
            self.assertEqual(self._request().status_code, 400)
