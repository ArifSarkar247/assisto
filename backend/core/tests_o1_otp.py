"""o1-otp — OTP engine, SMS adapter, launch gate, and sensitive-action proofs."""
import json
from datetime import timedelta
from unittest import mock

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import otp, sms_gateway
from core.models import (User, OtpChallenge, OtpProof, PhoneVerification,
                         AdminFlagState, Integration)

PHONE = "01712345678"
CANON = "+8801712345678"
CODE = "482913"


def enable_sms(**cfg):
    from core import integrations
    base = {"provider": "bulksmsbd", "api_key": "test-key-xyz", "sender_id": "8809617000000"}
    base.update(cfg)
    integrations.save("sms", base)
    Integration.objects.filter(slug="sms").update(status="working")


def http_ok(*_a, **_k):
    return 200, json.dumps({"response_code": 202, "success_message": "SMS Submitted Successfully"})


def set_flag(fid, value):
    from core.logic import admin_flags as AF
    st = AF.normalize_state({})
    st[fid] = value
    AdminFlagState.objects.update_or_create(key="global", defaults={"state": st})


class PhoneNormaliseTests(TestCase):
    def test_bd_formats(self):
        for raw in ("01712345678", "+8801712345678", "8801712345678",
                    "008801712345678", "017-1234 5678", "+880 1712-345678"):
            self.assertEqual(otp.normalize_bd_phone(raw), CANON, raw)

    def test_rejects_non_bd(self):
        for raw in ("", "12345", "0171234567", "02123456789", "+14155550100",
                    "01212345678", "abc01712345678"):
            self.assertIsNone(otp.normalize_bd_phone(raw), raw)

    def test_variants_and_mask(self):
        self.assertEqual(otp.phone_variants(CANON),
                         ["01712345678", "+8801712345678", "8801712345678"])
        m = otp.mask(CANON)
        self.assertTrue(m.startswith("017") and m.endswith("678"))
        self.assertNotIn("12345", m)


@mock.patch("core.sms_gateway._http", side_effect=http_ok)
@mock.patch("core.otp._gen_code", return_value=CODE)
class OtpEngineTests(TestCase):
    def setUp(self):
        enable_sms()

    def test_sms_off_raises_not_configured(self, *_):
        Integration.objects.filter(slug="sms").update(status="not_set")
        with self.assertRaises(otp.OtpError) as cm:
            otp.issue(PHONE, "login")
        self.assertEqual(cm.exception.reason, "sms_not_configured")
        self.assertEqual(cm.exception.http_status, 503)

    def test_hashed_never_plaintext(self, _gen, http):
        otp.issue(PHONE, "login")
        ch = OtpChallenge.objects.get()
        self.assertNotIn(CODE, ch.code_hash)
        self.assertNotIn(CODE, ch.salt)
        self.assertNotIn(CODE, ch.detail)
        self.assertEqual(len(ch.code_hash), 64)
        for row in OtpChallenge.objects.values():
            self.assertNotIn(CODE, json.dumps(row, default=str))
        # but the SMS did carry it
        body = http.call_args[0][2].decode()
        self.assertIn(CODE, body)
        self.assertIn("Assisto", body)

    def test_verify_returns_proof_single_use(self, *_):
        otp.issue(PHONE, "login")
        proof = otp.verify("+8801712345678", "login", CODE)
        self.assertTrue(proof)
        self.assertFalse(OtpProof.objects.filter(token_hash=proof).exists())  # hashed
        self.assertEqual(otp.consume_proof(proof, "login", PHONE), CANON)
        self.assertIsNone(otp.consume_proof(proof, "login", PHONE))       # single use
        # the code itself is burned too
        with self.assertRaises(otp.OtpError) as cm:
            otp.verify(PHONE, "login", CODE)
        self.assertEqual(cm.exception.reason, "no_active_code")

    def test_wrong_purpose(self, *_):
        otp.issue(PHONE, "signup")
        with self.assertRaises(otp.OtpError) as cm:
            otp.verify(PHONE, "login", CODE)
        self.assertEqual(cm.exception.reason, "no_active_code")
        proof = otp.verify(PHONE, "signup", CODE)
        self.assertIsNone(otp.consume_proof(proof, "login"))
        self.assertIsNone(otp.consume_proof(proof, "section8"))
        self.assertIsNone(otp.consume_proof(proof, "signup", "01999999999"))  # other phone
        self.assertEqual(otp.consume_proof(proof, "signup"), CANON)

    def test_expiry(self, *_):
        otp.issue(PHONE, "login")
        OtpChallenge.objects.update(expires_at=timezone.now() - timedelta(seconds=1))
        with self.assertRaises(otp.OtpError) as cm:
            otp.verify(PHONE, "login", CODE)
        self.assertEqual(cm.exception.reason, "expired")
        # default TTL is 5 minutes
        OtpChallenge.objects.all().delete()
        otp.issue(PHONE, "signup")
        ch = OtpChallenge.objects.get()
        self.assertAlmostEqual((ch.expires_at - ch.created_at).total_seconds(), 300, delta=1)

    def test_proof_expiry(self, *_):
        otp.issue(PHONE, "login")
        proof = otp.verify(PHONE, "login", CODE)
        OtpProof.objects.update(expires_at=timezone.now() - timedelta(seconds=1))
        self.assertIsNone(otp.consume_proof(proof, "login"))

    def test_lockout_after_max_attempts(self, *_):
        otp.issue(PHONE, "login")
        for i in range(4):
            with self.assertRaises(otp.OtpError) as cm:
                otp.verify(PHONE, "login", "000000")
            self.assertEqual(cm.exception.reason, "invalid_code")
            self.assertEqual(cm.exception.extra["attempts_left"], 4 - i)
        with self.assertRaises(otp.OtpError) as cm:
            otp.verify(PHONE, "login", "000000")
        self.assertEqual(cm.exception.reason, "locked")
        self.assertEqual(cm.exception.http_status, 423)
        # even the right code no longer works, and no new code can be requested
        with self.assertRaises(otp.OtpError) as cm:
            otp.verify(PHONE, "login", CODE)
        self.assertEqual(cm.exception.reason, "locked")
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(minutes=5))
        with self.assertRaises(otp.OtpError) as cm:
            otp.issue(PHONE, "login")
        self.assertEqual(cm.exception.reason, "locked")
        # lock expires
        OtpChallenge.objects.update(locked_until=timezone.now() - timedelta(seconds=1))
        otp.issue(PHONE, "login")

    def test_resend_cooldown(self, *_):
        otp.issue(PHONE, "login")
        with self.assertRaises(otp.OtpError) as cm:
            otp.issue(PHONE, "login")
        self.assertEqual(cm.exception.reason, "cooldown")
        self.assertEqual(cm.exception.http_status, 429)
        self.assertGreater(cm.exception.extra["retry_after"], 0)
        # after the cooldown a resend works and supersedes the old code
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(seconds=61))
        otp.issue(PHONE, "login")
        self.assertEqual(OtpChallenge.objects.filter(consumed_at__isnull=True).count(), 1)

    def _age_all(self):
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(seconds=120))

    def test_rate_limit_per_phone(self, *_):
        for _i in range(5):
            otp.issue(PHONE, "login")
            self._age_all()
        with self.assertRaises(otp.OtpError) as cm:
            otp.issue(PHONE, "login")
        self.assertEqual(cm.exception.reason, "rate_limited")
        # an hour later it's fine again
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(hours=2))
        otp.issue(PHONE, "login")

    def _req(self, ip="203.0.113.9", dev=""):
        r = mock.Mock()
        r.META = {"REMOTE_ADDR": ip}
        if dev:
            r.META["HTTP_X_DEVICE_ID"] = dev
        r.data = {}
        return r

    def test_rate_limit_per_ip(self, *_):
        from core.models import OtpChallenge as C
        now = timezone.now()
        for i in range(20):
            C.objects.create(phone=f"+88017000000{i:02d}", purpose="login",
                             code_hash="x", salt="s", created_at=now - timedelta(minutes=5),
                             expires_at=now, ip="203.0.113.9")
        with self.assertRaises(otp.OtpError) as cm:
            otp.issue(PHONE, "login", request=self._req())
        self.assertEqual(cm.exception.reason, "rate_limited")
        otp.issue(PHONE, "login", request=self._req(ip="198.51.100.1"))

    def test_rate_limit_per_device(self, *_):
        from core.models import OtpChallenge as C
        now = timezone.now()
        for i in range(10):
            C.objects.create(phone=f"+88018000000{i:02d}", purpose="login",
                             code_hash="x", salt="s", created_at=now - timedelta(minutes=5),
                             expires_at=now, ip=f"10.0.0.{i}", device_id="DEV-A")
        with self.assertRaises(otp.OtpError) as cm:
            otp.issue(PHONE, "login", request=self._req(dev="DEV-A"))
        self.assertEqual(cm.exception.reason, "rate_limited")
        otp.issue(PHONE, "login", request=self._req(dev="DEV-B"))

    def test_proxy_ip(self, *_):
        r = self._req(ip="127.0.0.1")
        r.META["HTTP_X_FORWARDED_FOR"] = "198.51.100.7"
        self.assertEqual(otp.client_ip(r), "198.51.100.7")
        r2 = self._req(ip="203.0.113.5")
        r2.META["HTTP_X_FORWARDED_FOR"] = "1.2.3.4"            # spoof from outside
        self.assertEqual(otp.client_ip(r2), "203.0.113.5")

    def test_limits_admin_editable(self, *_):
        from core import billing
        row = billing.get_config()
        data = dict(row.data)
        data["otp"] = {"max_attempts": 2, "ttl_seconds": 120}
        row.data = data
        row.save()
        otp.issue(PHONE, "login")
        ch = OtpChallenge.objects.get()
        self.assertAlmostEqual((ch.expires_at - ch.created_at).total_seconds(), 120, delta=1)
        with self.assertRaises(otp.OtpError):
            otp.verify(PHONE, "login", "000000")
        with self.assertRaises(otp.OtpError) as cm:
            otp.verify(PHONE, "login", "000000")
        self.assertEqual(cm.exception.reason, "locked")

    def test_send_failure_is_honest(self, _gen, http):
        http.side_effect = lambda *a, **k: (200, json.dumps({"response_code": 1007,
                                                              "error_message": "Balance Insufficient " + CODE}))
        with self.assertRaises(otp.OtpError) as cm:
            otp.issue(PHONE, "login")
        self.assertEqual(cm.exception.reason, "send_failed")
        ch = OtpChallenge.objects.get()
        self.assertFalse(ch.sent)
        self.assertNotIn(CODE, ch.detail)       # scrubbed
        with self.assertRaises(otp.OtpError):
            otp.verify(PHONE, "login", CODE)    # an unsent code never verifies

    def test_code_never_logged(self, *_):
        with self.assertLogs(level="DEBUG") as logs:
            import logging
            logging.getLogger("probe").debug("start")
            otp.issue(PHONE, "login")
            otp.verify(PHONE, "login", CODE)
        self.assertFalse(any(CODE in line for line in logs.output))


class SmsAdapterTests(TestCase):
    def test_bulksmsbd_form(self):
        m, url, body, h = sms_gateway.build_request(
            {"provider": "bulksmsbd", "api_key": "K", "sender_id": "S"}, CANON, "hi")
        self.assertEqual(m, "POST")
        self.assertIn("bulksmsbd.net", url)
        b = body.decode()
        self.assertIn("number=8801712345678", b)
        self.assertIn("api_key=K", b)
        self.assertIn("senderid=S", b)
        self.assertIn("type=text", b)

    def test_ssl_wireless_json_template(self):
        m, url, body, h = sms_gateway.build_request(
            {"provider": "ssl_wireless", "api_key": "TOK", "sender_id": "ASSISTO"},
            CANON, 'quote " and বাংলা')
        j = json.loads(body.decode())
        self.assertEqual(j["api_token"], "TOK")
        self.assertEqual(j["msisdn"], "8801712345678")
        self.assertEqual(j["sms"], 'quote " and বাংলা')
        self.assertTrue(j["csms_id"])
        self.assertEqual(h["Content-Type"], "application/json")

    def test_infobip_header_and_nested(self):
        m, url, body, h = sms_gateway.build_request(
            {"provider": "infobip", "api_key": "IBK", "sender_id": "Assisto",
             "api_url": "https://abc.api.infobip.com/sms/2/text/advanced"}, CANON, "x")
        self.assertEqual(h["Authorization"], "App IBK")
        j = json.loads(body.decode())
        self.assertEqual(j["messages"][0]["destinations"][0]["to"], "8801712345678")

    def test_infobip_placeholder_url_refused(self):
        with self.assertRaises(sms_gateway.SmsError):
            sms_gateway.build_request({"provider": "infobip", "api_key": "k"}, CANON, "x")

    def test_custom_get_and_number_format(self):
        m, url, body, h = sms_gateway.build_request(
            {"provider": "custom", "api_url": "https://gw.example/send", "method": "GET",
             "api_key": "K", "param_to": "msisdn", "param_message": "txt",
             "param_api_key": "token", "number_format": "0"}, CANON, "hello")
        self.assertEqual(m, "GET")
        self.assertIn("msisdn=01712345678", url)
        self.assertIn("token=K", url)
        self.assertIsNone(body)

    def test_success_checks(self):
        cfg = sms_gateway.resolve_config({"provider": "alpha_sms"})
        self.assertTrue(sms_gateway.success(cfg, 200, '{"error": 0, "msg": "ok"}'))
        self.assertFalse(sms_gateway.success(cfg, 200, '{"error": 405}'))
        self.assertFalse(sms_gateway.success(cfg, 500, '{"error": 0}'))
        self.assertFalse(sms_gateway.success(cfg, 200, 'not json'))
        c2 = {"success_contains": "messageId"}
        self.assertTrue(sms_gateway.success(c2, 200, '{"messages":[{"messageId":"1"}]}'))
        self.assertFalse(sms_gateway.success(c2, 200, '{}'))

    @mock.patch("core.sms_gateway._http", side_effect=OSError("down"))
    def test_network_error_never_raises(self, _):
        ok, detail = sms_gateway.HttpSmsAdapter(
            {"provider": "bulksmsbd", "api_key": "K"}).send(CANON, "x")
        self.assertFalse(ok)
        self.assertIn("network", detail)

    def test_check_unverifiable_is_honest(self):
        ok, detail = sms_gateway.HttpSmsAdapter(
            {"provider": "ssl_wireless", "api_key": "K", "sender_id": "S"}).check()
        self.assertFalse(ok)
        self.assertIn("cannot verify", detail)

    def test_check_missing_key(self):
        ok, detail = sms_gateway.HttpSmsAdapter({"provider": "bulksmsbd"}).check()
        self.assertFalse(ok)

    @mock.patch("core.sms_gateway._http", return_value=(200, '{"balance": "123.45"}'))
    def test_check_balance(self, http):
        ok, detail = sms_gateway.HttpSmsAdapter(
            {"provider": "bulksmsbd", "api_key": "K"}).check()
        self.assertTrue(ok, detail)
        self.assertIn("getBalanceApi?api_key=K", http.call_args[0][1])

    @mock.patch("core.sms_gateway._http", return_value=(200, '{"error": 405, "msg":"invalid key"}'))
    def test_check_balance_bad_key(self, _):
        ok, _d = sms_gateway.HttpSmsAdapter({"provider": "alpha_sms", "api_key": "K"}).check()
        self.assertFalse(ok)

    @mock.patch("core.sms_gateway._http", side_effect=http_ok)
    def test_check_test_phone_sends_one_real_sms(self, http):
        ok, detail = sms_gateway.HttpSmsAdapter(
            {"provider": "custom", "api_url": "https://gw.example/send", "api_key": "K",
             "test_phone": "01811111111"}).check()
        self.assertTrue(ok, detail)
        self.assertEqual(http.call_count, 1)
        self.assertIn("8801811111111", http.call_args[0][2].decode())

    @mock.patch("core.sms_gateway._http", side_effect=http_ok)
    def test_integration_test_hook(self, _):
        from core import integrations
        integrations.save("sms", {"provider": "bulksmsbd", "api_key": "K"})
        st, detail = integrations.test("sms")
        self.assertEqual(st, "working", detail)
        self.assertTrue(otp.sms_available())

    def test_integration_test_hook_failing(self):
        from core import integrations
        integrations.save("sms", {"provider": "custom", "api_key": "K"})
        st, _d = integrations.test("sms")
        self.assertEqual(st, "failing")
        self.assertFalse(otp.sms_available())

    def test_sms_text_bn_en(self):
        bn = otp.sms_text(CODE, "bn", 300)
        en = otp.sms_text(CODE, "en", 300)
        self.assertIn(CODE, bn)
        self.assertIn("Assisto", bn)
        self.assertIn("মিনিটে", bn)
        self.assertIn("expires in 5 min", en)
        self.assertTrue(otp.sms_text(CODE, "en", 300, "AbCdEfGhIjK").endswith("AbCdEfGhIjK"))


@mock.patch("core.sms_gateway._http", side_effect=http_ok)
@mock.patch("core.otp._gen_code", return_value=CODE)
class OtpApiTests(APITestCase):
    def setUp(self):
        enable_sms()

    def _proof(self, purpose, phone=PHONE):
        r = self.client.post("/api/v1/auth/otp/request",
                             {"phone": phone, "purpose": purpose}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"phone": phone, "purpose": purpose, "code": CODE}, format="json")
        self.assertEqual(v.status_code, 200, v.data)
        return v.data["otp_proof"]

    def test_status(self, *_):
        r = self.client.get("/api/v1/auth/otp/status")
        self.assertTrue(r.data["sms_enabled"])
        self.assertTrue(r.data["password_only_signup"])
        self.assertEqual(r.data["code_length"], 6)
        v = self.client.get("/api/v1/version")
        self.assertTrue(v.data["features"]["sms_otp"])

    def test_sms_off_honest_503_not_501(self, *_):
        Integration.objects.filter(slug="sms").update(status="not_set")
        for path in ("/api/v1/auth/otp/request", "/api/v1/auth/otp/resend"):
            r = self.client.post(path, {"phone": PHONE, "purpose": "login"}, format="json",
                                 HTTP_ACCEPT_LANGUAGE="en")
            self.assertEqual(r.status_code, 503)
            self.assertFalse(r.data["sms_enabled"])
            self.assertIn("SMS", r.data["detail"])
        self.assertFalse(self.client.get("/api/v1/auth/otp/status").data["sms_enabled"])

    def test_bad_purpose_and_phone(self, *_):
        r = self.client.post("/api/v1/auth/otp/request", {"phone": PHONE, "purpose": "x"},
                             format="json")
        self.assertEqual(r.status_code, 400)
        r = self.client.post("/api/v1/auth/otp/request", {"phone": "123", "purpose": "signup"},
                             format="json")
        self.assertEqual(r.data["reason"], "bad_phone")

    def test_login_by_otp(self, _gen, http):
        u = User.objects.create_user(name="A", phone="+8801712345678", password="pw123456")
        proof = self._proof("login", "8801712345678")
        r = self.client.post("/api/v1/auth/otp/login", {"phone": PHONE, "otp_proof": proof},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["token"])
        self.assertTrue(PhoneVerification.objects.filter(user=u).exists())
        # proof is single use
        r2 = self.client.post("/api/v1/auth/otp/login", {"phone": PHONE, "otp_proof": proof},
                              format="json")
        self.assertEqual(r2.status_code, 401)
        # password login still works for existing users
        r3 = self.client.post("/api/v1/auth/login",
                              {"identifier": "+8801712345678", "password": "pw123456"},
                              format="json")
        self.assertEqual(r3.status_code, 200)

    def test_login_unknown_number_neutral_no_sms(self, _gen, http):
        r = self.client.post("/api/v1/auth/otp/request", {"phone": PHONE, "purpose": "login"},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["ok"])
        http.assert_not_called()
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"phone": PHONE, "purpose": "login", "code": CODE}, format="json")
        self.assertEqual(v.status_code, 400)

    def test_verify_errors_shape(self, *_):
        User.objects.create_user(name="A", phone=PHONE, password="pw123456")
        self.client.post("/api/v1/auth/otp/request", {"phone": PHONE, "purpose": "login"},
                         format="json")
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"phone": PHONE, "purpose": "login", "code": "111111"},
                             format="json", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(v.status_code, 400)
        self.assertEqual(v.data["reason"], "invalid_code")
        self.assertEqual(v.data["attempts_left"], 4)
        self.assertIn("didn't match", v.data["message"])
        r = self.client.post("/api/v1/auth/otp/resend", {"phone": PHONE, "purpose": "login"},
                             format="json")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.data["reason"], "cooldown")

    def test_password_reset_by_otp(self, *_):
        u = User.objects.create_user(name="A", phone=PHONE, password="oldpass123")
        from rest_framework.authtoken.models import Token
        Token.objects.create(user=u)
        proof = self._proof("password_reset")
        bad = self.client.post("/api/v1/auth/otp/reset",
                               {"phone": PHONE, "otp_proof": proof, "password": "short"},
                               format="json")
        self.assertEqual(bad.status_code, 400)
        r = self.client.post("/api/v1/auth/otp/reset",
                             {"phone": PHONE, "otp_proof": proof, "password": "newpass123"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        u.refresh_from_db()
        self.assertTrue(u.check_password("newpass123"))
        self.assertFalse(Token.objects.filter(user=u).exists())
        # a login proof can't reset a password
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(minutes=5))
        p2 = self._proof("login")
        r2 = self.client.post("/api/v1/auth/otp/reset",
                              {"phone": PHONE, "otp_proof": p2, "password": "another123"},
                              format="json")
        self.assertEqual(r2.status_code, 400)

    # ---- sign-up + launch gate ---------------------------------------------
    def test_signup_with_otp_proof(self, *_):
        proof = self._proof("signup", "+8801712345678")
        r = self.client.post("/api/v1/auth/register",
                             {"name": "N", "phone": PHONE, "password": "pw123456",
                              "otp_proof": proof}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        u = User.objects.get(phone=PHONE)
        self.assertEqual(PhoneVerification.objects.get(user=u).phone, CANON)

    def test_signup_proof_for_other_phone_rejected(self, *_):
        proof = self._proof("signup", "01811111111")
        r = self.client.post("/api/v1/auth/register",
                             {"name": "N", "phone": PHONE, "password": "pw123456",
                              "otp_proof": proof}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "bad_otp")

    def test_signup_already_registered(self, *_):
        User.objects.create_user(name="A", phone="+8801712345678", password="pw123456")
        r = self.client.post("/api/v1/auth/otp/request", {"phone": PHONE, "purpose": "signup"},
                             format="json")
        self.assertEqual(r.status_code, 409)

    def test_gate_on_password_only_signup_allowed(self, *_):
        r = self.client.post("/api/v1/auth/register",
                             {"name": "N", "email": "a@b.co", "password": "pw123456"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)

    def test_gate_off_requires_verified_phone(self, *_):
        set_flag("auth_password_only_signup", False)
        r = self.client.post("/api/v1/auth/register",
                             {"name": "N", "phone": PHONE, "password": "pw123456"},
                             format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "phone_verification_required")
        proof = self._proof("signup")
        r = self.client.post("/api/v1/auth/register",
                             {"name": "N", "phone": PHONE, "password": "pw123456",
                              "otp_proof": proof}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        # existing users keep password login with the gate OFF
        r = self.client.post("/api/v1/auth/login",
                             {"identifier": PHONE, "password": "pw123456"}, format="json")
        self.assertEqual(r.status_code, 200)

    def test_gate_flag_in_admin_catalog(self, *_):
        from core.logic import admin_flags as AF
        self.assertTrue(AF.is_known("auth_password_only_signup"))
        self.assertTrue(AF.default_of("auth_password_only_signup"))

    # ---- authed purposes -----------------------------------------------------
    def test_authed_purpose_requires_login_and_own_phone(self, *_):
        r = self.client.post("/api/v1/auth/otp/request",
                             {"phone": PHONE, "purpose": "delete_account"}, format="json")
        self.assertEqual(r.status_code, 401)
        u = User.objects.create_user(name="A", phone=PHONE, password="pw123456")
        self.client.force_authenticate(user=u)
        r = self.client.post("/api/v1/auth/otp/request",
                             {"phone": "01811111111", "purpose": "section8"}, format="json")
        self.assertEqual(r.status_code, 403)
        r = self.client.post("/api/v1/auth/otp/request", {"purpose": "section8"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)


@mock.patch("core.sms_gateway._http", side_effect=http_ok)
@mock.patch("core.otp._gen_code", return_value=CODE)
class SensitiveActionProofTests(APITestCase):
    PIN = "4321"
    PW = "x123456"

    def setUp(self):
        from django.contrib.auth.hashers import make_password
        from core.models import ProtectedPhone, SavedPlace
        self.user = User.objects.create_user(name="O", phone=PHONE, password=self.PW)
        self.client.force_authenticate(user=self.user)
        ProtectedPhone.objects.create(owner=self.user,
                                      security_pin_hash=make_password(self.PIN))
        SavedPlace.objects.create(user=self.user, label="Home", lat=23.80, lng=90.40)

    def _proof(self, purpose):
        r = self.client.post("/api/v1/auth/otp/request", {"purpose": purpose}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        v = self.client.post("/api/v1/auth/otp/verify", {"purpose": purpose, "code": CODE},
                             format="json")
        self.assertEqual(v.status_code, 200, v.data)
        return v.data["otp_proof"]

    def _delete(self, **over):
        body = {"password": self.PW, "security_pin": self.PIN, "lat": 23.80, "lng": 90.40}
        body.update(over)
        return self.client.post("/api/v1/account/delete/request", body, format="json")

    def test_delete_without_sms_needs_no_proof(self, *_):
        r = self._delete()
        self.assertEqual(r.status_code, 200, r.data)

    def test_delete_requires_proof_when_sms_on(self, *_):
        enable_sms()
        r = self._delete()
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "otp_required")
        r = self._delete(otp_proof="forged")
        self.assertEqual(r.data["reason"], "bad_otp")
        # a section8 proof can't delete the account
        p8 = self._proof("section8")
        self.assertEqual(self._delete(otp_proof=p8).data["reason"], "bad_otp")
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(minutes=5))
        proof = self._proof("delete_account")
        # wrong PIN does not burn the proof
        self.assertEqual(self._delete(otp_proof=proof, security_pin="0000").status_code, 403)
        ok = self._delete(otp_proof=proof)
        self.assertEqual(ok.status_code, 200, ok.data)

    def test_section8_requires_proof_when_sms_on(self, *_):
        enable_sms()
        body = {"action": "disarm", "pin": self.PIN, "lat": 23.80, "lng": 90.40}
        r = self.client.post("/api/v1/security/action", body, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "otp_required")
        proof = self._proof("section8")
        r = self.client.post("/api/v1/security/action", {**body, "otp_proof": proof},
                             format="json")
        self.assertIn(r.status_code, (200, 201), r.data)
        # single use
        r = self.client.post("/api/v1/security/action", {**body, "otp_proof": proof},
                             format="json")
        self.assertEqual(r.data["reason"], "bad_otp")

    def test_section8_without_sms_unchanged(self, *_):
        r = self.client.post("/api/v1/security/action",
                             {"action": "disarm", "pin": self.PIN, "lat": 23.80, "lng": 90.40},
                             format="json")
        self.assertIn(r.status_code, (200, 201), r.data)
