"""smsotp — SMS gateway adapters, segments, failover, per-purpose caps, cost
logging, tagada credits, safety SMS, email OTP backup (Gmail SMTP), rate
limits, no enumeration, secrets never logged. Everything is mocked at the
network seam (core.sms_gateway._http / smtplib.SMTP): no real SMS or email."""
import base64
import json
import smtplib
import urllib.parse
from datetime import timedelta
from unittest import mock

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import (billing, email_sender, integrations, otp, sms_gateway,
                  sms_segments, sms_service)
from core.models import (BusinessProfile, EmailLog, EmailVerification, Integration,
                         KhataEntry, KhataParty, OtpChallenge, PhoneVerification,
                         SmsLog, User)

PHONE = "01712345678"
CANON = "+8801712345678"
CODE = "482913"
APP_PW = "abcd efgh ijkl mnop"


def connect(slug, cfg):
    integrations.save(slug, cfg)
    Integration.objects.filter(slug=slug).update(status="working")


def set_cfg(section, **kw):
    row = billing.get_config()
    data = dict(row.data or {})
    sec = dict(data.get(section) or {})
    sec.update(kw)
    data[section] = sec
    row.data = data
    row.save()


def alpha_ok(*_a, **_k):
    return 200, json.dumps({"error": 0, "msg": "Request successfully submitted",
                            "data": {"request_id": 777}})


def bulk_ok(*_a, **_k):
    return 200, json.dumps({"response_code": 202, "message_id": 555,
                            "success_message": "SMS Submitted Successfully"})


class FakeSMTP:
    """smtplib.SMTP stand-in: records messages, can refuse the login."""
    sent = []
    logins = []
    fail_login = False
    fail_send = False

    def __init__(self, host, port, timeout=None):
        self.host, self.port = host, port

    def ehlo(self):
        pass

    def starttls(self):
        pass

    def login(self, user, pw):
        FakeSMTP.logins.append((user, pw))
        if FakeSMTP.fail_login:
            raise smtplib.SMTPAuthenticationError(535, b"5.7.8 bad")

    def send_message(self, msg):
        if FakeSMTP.fail_send:
            raise smtplib.SMTPDataError(550, b"5.4.5 Daily user sending quota exceeded")
        FakeSMTP.sent.append(msg)

    def quit(self):
        pass

    @classmethod
    def reset(cls):
        cls.sent, cls.logins, cls.fail_login, cls.fail_send = [], [], False, False


def connect_email():
    connect("smtp_email", {"host": "smtp.gmail.com", "port": "587",
                           "username": "assistoaiagent@gmail.com",
                           "app_password": APP_PW, "from_name": "Assisto"})


def mail_text(msg):
    return msg.get_content()


# ======================================================================= segments
class SegmentTests(TestCase):
    def test_gsm7(self):
        self.assertEqual(sms_segments.info("hello")["encoding"], "gsm7")
        self.assertEqual(sms_segments.segments("a" * 160), 1)
        self.assertEqual(sms_segments.segments("a" * 161), 2)
        self.assertEqual(sms_segments.segments("a" * 306), 2)
        self.assertEqual(sms_segments.segments("a" * 307), 3)
        # extension characters cost two septets
        self.assertEqual(sms_segments.info("{}")["units"], 4)
        self.assertEqual(sms_segments.segments("€" * 80), 1)
        self.assertEqual(sms_segments.segments("€" * 81), 2)

    def test_bangla_is_ucs2(self):
        i = sms_segments.info("আ" * 70)
        self.assertEqual((i["encoding"], i["segments"], i["per_segment"]), ("ucs2", 1, 70))
        self.assertEqual(sms_segments.segments("আ" * 71), 2)
        self.assertEqual(sms_segments.info("আ" * 71)["per_segment"], 67)
        self.assertEqual(sms_segments.segments("আ" * 134), 2)
        self.assertEqual(sms_segments.segments("আ" * 135), 3)
        # one Bangla letter turns a Latin text into UCS-2
        self.assertEqual(sms_segments.info("a" * 69 + "আ")["segments"], 1)
        self.assertEqual(sms_segments.info("a" * 70 + "আ")["segments"], 2)

    def test_emoji_counts_two_units(self):
        self.assertEqual(sms_segments.info("😀")["units"], 2)

    def test_otp_texts_fit(self):
        self.assertLessEqual(sms_segments.segments(otp.sms_text(CODE, "bn", 300)), 2)
        self.assertEqual(sms_segments.segments(otp.sms_text(CODE, "en", 300)), 1)


# ======================================================================= adapters
class AdapterFormatTests(TestCase):
    def test_ssl_wireless(self):
        ad = sms_gateway.make("sms_ssl_wireless", {"api_token": "TOK", "sid": "ASSISTO"})
        m, url, body, h = ad.request(CANON, "আপনার কোড")
        self.assertEqual((m, url), ("POST", "https://smsplus.sslwireless.com/api/v3/send-sms"))
        j = json.loads(body.decode())
        self.assertEqual(j["api_token"], "TOK")
        self.assertEqual(j["sid"], "ASSISTO")
        self.assertEqual(j["msisdn"], "8801712345678")
        self.assertEqual(j["sms"], "আপনার কোড")
        self.assertTrue(1 <= len(j["csms_id"]) <= 20)
        self.assertEqual(h["Content-Type"], "application/json")
        ok, mid = ad.parse(200, json.dumps({"status": "SUCCESS", "status_code": 200,
                                            "smsinfo": [{"sms_status": "SUCCESS",
                                                         "reference_id": "R1"}]}))
        self.assertEqual((ok, mid), (True, "R1"))
        self.assertFalse(ad.parse(200, json.dumps({"status": "FAILED",
                                                   "error_message": "Invalid SID"}))[0])

    def test_bulksmsbd(self):
        ad = sms_gateway.make("sms_bulksmsbd", {"api_key": "K", "senderid": "8809617"})
        m, url, body, h = ad.request(CANON, "hi")
        self.assertEqual((m, url), ("POST", "https://bulksmsbd.net/api/smsapi"))
        q = urllib.parse.parse_qs(body.decode())
        self.assertEqual(q["api_key"], ["K"])
        self.assertEqual(q["number"], ["8801712345678"])
        self.assertEqual(q["senderid"], ["8809617"])
        self.assertEqual(q["type"], ["text"])
        self.assertEqual(q["message"], ["hi"])
        self.assertEqual(ad.parse(*bulk_ok()), (True, "555"))
        self.assertFalse(ad.parse(200, json.dumps({"response_code": 1007}))[0])
        bm, burl, _b, _h = ad.balance()
        self.assertIn("getBalanceApi?api_key=K", burl)

    def test_alpha_sms(self):
        ad = sms_gateway.make("sms_alpha", {"api_key": "K"})
        m, url, body, _h = ad.request(CANON, "hi")
        self.assertEqual(url, "https://api.sms.net.bd/sendsms")
        q = urllib.parse.parse_qs(body.decode())
        self.assertEqual((q["api_key"], q["to"], q["msg"]), (["K"], ["8801712345678"], ["hi"]))
        self.assertNotIn("sender_id", q)          # optional — only when approved
        ad2 = sms_gateway.make("sms_alpha", {"api_key": "K", "sender_id": "Assisto"})
        self.assertIn("sender_id=Assisto", ad2.request(CANON, "x")[2].decode())
        self.assertEqual(ad.parse(*alpha_ok()), (True, "777"))
        self.assertFalse(ad.parse(200, json.dumps({"error": 405, "msg": "bad"}))[0])

    def test_infobip(self):
        ad = sms_gateway.make("sms_infobip", {"base_url": "abc12.api.infobip.com",
                                              "api_key": "IBK", "sender": "Assisto"})
        m, url, body, h = ad.request(CANON, "hi")
        self.assertEqual(url, "https://abc12.api.infobip.com/sms/2/text/advanced")
        self.assertEqual(h["Authorization"], "App IBK")
        j = json.loads(body.decode())
        self.assertEqual(j["messages"][0]["destinations"][0]["to"], "8801712345678")
        self.assertEqual(j["messages"][0]["from"], "Assisto")
        ok, mid = ad.parse(200, json.dumps({"messages": [
            {"messageId": "M9", "status": {"groupId": 1, "groupName": "PENDING"}}]}))
        self.assertEqual((ok, mid), (True, "M9"))
        self.assertFalse(ad.parse(200, json.dumps({"messages": [
            {"messageId": "M9", "status": {"groupName": "REJECTED"}}]}))[0])
        insecure = sms_gateway.make("sms_infobip", {"base_url": "http://x.api.infobip.com",
                                                    "api_key": "K", "sender": "S"})
        self.assertFalse(insecure.send(CANON, "x")[0])

    def test_twilio(self):
        ad = sms_gateway.make("sms_twilio", {"account_sid": "AC123", "auth_token": "TT",
                                             "from_number": "+15005550006"})
        m, url, body, h = ad.request(CANON, "hi")
        self.assertEqual(url, "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json")
        self.assertEqual(h["Authorization"],
                         "Basic " + base64.b64encode(b"AC123:TT").decode())
        q = urllib.parse.parse_qs(body.decode())
        self.assertEqual((q["To"], q["From"], q["Body"]),
                         (["+8801712345678"], ["+15005550006"], ["hi"]))
        mg = sms_gateway.make("sms_twilio", {"account_sid": "AC1", "auth_token": "T",
                                             "from_number": "MG42"})
        self.assertIn("MessagingServiceSid=MG42", mg.request(CANON, "x")[2].decode())
        self.assertEqual(ad.parse(201, json.dumps({"sid": "SMabc", "status": "queued",
                                                   "num_segments": "1"})), (True, "SMabc"))
        self.assertFalse(ad.parse(400, json.dumps({"code": 21211}))[0])

    def test_generic_url_template_and_regex(self):
        cfg = {"provider": "custom", "api_key": "K", "sender_id": "Shop",
               "api_url": "https://gw.example/send?u=me&key={api_key}&to={to}&msg={text}&from={sender}",
               "method": "GET", "success_regex": r"^OK\b"}
        m, url, body, _h = sms_gateway.build_request(cfg, CANON, "আজ ১০০ টাকা")
        self.assertEqual(m, "GET")
        self.assertIsNone(body)
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        self.assertEqual(q["msg"], ["আজ ১০০ টাকা"])           # UTF-8, URL-encoded
        self.assertEqual(q["to"], ["8801712345678"])
        self.assertEqual(q["from"], ["Shop"])
        c = sms_gateway.resolve_config(cfg)
        self.assertTrue(sms_gateway.success(c, 200, "OK 12345"))
        self.assertFalse(sms_gateway.success(c, 200, "ERR 1"))

    def test_generic_post_form_template(self):
        cfg = {"provider": "custom", "api_key": "K", "api_url": "https://gw.example/send",
               "method": "POST", "body_template": "token={api_key}&dest={to}&sms={text}"}
        m, url, body, h = sms_gateway.build_request(cfg, CANON, "a&b")
        self.assertEqual(h["Content-Type"], "application/x-www-form-urlencoded")
        self.assertEqual(urllib.parse.parse_qs(body.decode())["sms"], ["a&b"])

    def test_missing_fields_are_config_errors(self):
        for slug, cfg in (("sms_ssl_wireless", {"api_token": "T"}),
                          ("sms_bulksmsbd", {"api_key": "K"}),
                          ("sms_infobip", {"api_key": "K", "sender": "S"}),
                          ("sms_twilio", {"account_sid": "AC"})):
            ok, detail = sms_gateway.make(slug, cfg).check()
            self.assertFalse(ok, slug)
            self.assertIn("missing", detail)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_send_test_sms_to_typed_number(self, http):
        integrations.save("sms_alpha", {"api_key": "K"})
        st, detail = integrations.test("sms_alpha", test_to="01811111111")
        self.assertEqual(st, "working", detail)
        self.assertEqual(http.call_count, 1)
        self.assertIn("8801811111111", http.call_args[0][2].decode())
        self.assertTrue(otp.sms_available())

    @mock.patch("core.sms_gateway._http", return_value=(200, '{"error": 0, "data": {"balance": "50"}}'))
    def test_balance_check_without_number(self, http):
        integrations.save("sms_alpha", {"api_key": "K"})
        st, _d = integrations.test("sms_alpha")
        self.assertEqual(st, "working")
        self.assertIn("/user/balance/", http.call_args[0][1])

    def test_unverifiable_is_honest(self):
        # Twilio without a typed number still checks the account; a gateway
        # with no balance API and no number is never marked working.
        class NoBal(sms_gateway._Dedicated):
            required = ("k",)

            def request(self, to, text):
                return "POST", "https://x", b"", {}
        ok, detail = NoBal({"k": "v"}).check()
        self.assertFalse(ok)
        self.assertIn("cannot verify", detail)

    def test_owner_admin_entries_and_fields(self):
        rows = {r["slug"]: r for r in integrations.list_all("en")}
        want = {"sms_ssl_wireless": {"api_token", "sid"},
                "sms_bulksmsbd": {"api_key", "senderid"},
                "sms_alpha": {"api_key", "sender_id"},
                "sms_infobip": {"base_url", "api_key", "sender"},
                "sms_twilio": {"account_sid", "auth_token", "from_number"},
                "sms": {"api_url", "method", "success_regex"},
                "smtp_email": {"host", "port", "username", "app_password", "from_name"}}
        for slug, keys in want.items():
            self.assertIn(slug, rows)
            self.assertTrue(keys <= {f["key"] for f in rows[slug]["fields"]}, slug)
            self.assertTrue(rows[slug]["test_to_kind"], slug)
        self.assertEqual(rows["smtp_email"]["test_to_kind"], "email")
        secret = {f["key"] for f in rows["smtp_email"]["fields"] if f["secret"]}
        self.assertEqual(secret, {"app_password"})


# ======================================================================= service
@mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False)
class SmsServiceTests(TestCase):
    def setUp(self):
        connect("sms_alpha", {"api_key": "AK-secret-1", "cost_per_segment_bdt": "0.30"})
        self.u = User.objects.create_user(name="A", phone=CANON, password="pw123456")

    def test_marketing_is_refused(self, _q):
        r = sms_service.send_sms(PHONE, "SALE!", "marketing")
        self.assertEqual(r["reason"], "bad_purpose")
        self.assertFalse(SmsLog.objects.exists())

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_cost_logging(self, http, _q):
        r = sms_service.send_sms(PHONE, "আ" * 100, "safety", user=self.u)   # 2 segments
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["segments"], r["encoding"], r["provider"]), (2, "ucs2", "sms_alpha"))
        self.assertAlmostEqual(r["cost_bdt"], 0.60)
        row = SmsLog.objects.get()
        self.assertEqual((row.purpose, row.status, row.message_id), ("safety", "sent", "777"))
        self.assertAlmostEqual(row.cost_bdt, 0.60)
        from core.models import DailyLedger
        led = DailyLedger.objects.order_by("-id").first()
        self.assertAlmostEqual(float(led.variable_cost_by_type["sms"]), 0.60)
        self.assertEqual(sms_service.usage_today()["safety"]["segments"], 2)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_default_cost_when_gateway_has_none(self, http, _q):
        integrations.save("sms_alpha", {"cost_per_segment_bdt": ""})
        Integration.objects.filter(slug="sms_alpha").update(status="working")
        connect("sms_bulksmsbd", {"api_key": "B", "senderid": "S"})
        set_cfg("sms", primary="sms_bulksmsbd", default_cost_per_segment_bdt=0.5)
        with mock.patch("core.sms_gateway._http", side_effect=bulk_ok):
            r = sms_service.send_sms(PHONE, "hello", "otp")
        self.assertEqual(r["provider"], "sms_bulksmsbd")
        self.assertAlmostEqual(r["cost_bdt"], 0.5)

    def test_failover_to_secondary(self, _q):
        connect("sms_bulksmsbd", {"api_key": "B", "senderid": "S"})
        set_cfg("sms", primary="sms_bulksmsbd", secondary="sms_alpha")

        def http(method, url, data=None, headers=None):
            if "bulksmsbd" in url:
                return 500, "gateway down"
            return alpha_ok()
        with mock.patch("core.sms_gateway._http", side_effect=http) as h:
            r = sms_service.send_sms(PHONE, "hello", "otp")
        self.assertTrue(r["ok"], r)
        self.assertTrue(r["failover"])
        self.assertEqual(r["provider"], "sms_alpha")
        self.assertEqual(h.call_count, 2)
        self.assertTrue(SmsLog.objects.get().failover)

    def test_no_secondary_means_no_failover(self, _q):
        connect("sms_bulksmsbd", {"api_key": "B", "senderid": "S"})
        set_cfg("sms", primary="sms_bulksmsbd", secondary="")
        with mock.patch("core.sms_gateway._http", return_value=(500, "down")) as h:
            r = sms_service.send_sms(PHONE, "hello", "otp")
        self.assertEqual(r["reason"], "send_failed")
        self.assertEqual(h.call_count, 1)
        self.assertEqual(SmsLog.objects.get().status, "failed")

    def test_both_fail(self, _q):
        connect("sms_bulksmsbd", {"api_key": "B", "senderid": "S"})
        set_cfg("sms", primary="sms_alpha", secondary="sms_bulksmsbd")
        with mock.patch("core.sms_gateway._http", side_effect=OSError("down")) as h:
            r = sms_service.send_sms(PHONE, "hello", "otp")
        self.assertEqual(r["reason"], "send_failed")
        self.assertEqual(h.call_count, 2)

    def test_failing_gateway_is_never_used(self, _q):
        connect("sms_bulksmsbd", {"api_key": "B", "senderid": "S"})
        Integration.objects.filter(slug="sms_bulksmsbd").update(status="failing")
        set_cfg("sms", primary="sms_bulksmsbd")
        self.assertEqual([a.slug for a in sms_gateway.chain()], ["sms_alpha"])
        Integration.objects.filter(slug="sms_alpha").update(status="failing")
        self.assertFalse(otp.sms_available())
        self.assertEqual(sms_service.send_sms(PHONE, "x", "otp")["reason"], "sms_not_configured")

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_safety_caps(self, http, _q):
        set_cfg("sms", safety_per_phone_day=2, safety_per_user_day=3, safety_global_day=100)
        self.assertTrue(sms_service.send_safety_sms(self.u, PHONE, "SOS")["ok"])
        self.assertTrue(sms_service.send_safety_sms(self.u, PHONE, "SOS")["ok"])
        r = sms_service.send_safety_sms(self.u, PHONE, "SOS")
        self.assertEqual(r["reason"], "phone_daily_cap")
        self.assertTrue(sms_service.send_safety_sms(self.u, "01811111111", "SOS")["ok"])
        self.assertEqual(sms_service.send_safety_sms(self.u, "01911111111", "SOS")["reason"],
                         "user_daily_cap")
        self.assertEqual(http.call_count, 3)
        self.assertEqual(SmsLog.objects.filter(status="blocked").count(), 2)
        # safety is free to the user: no credits ever taken
        self.assertEqual(SmsLog.objects.filter(credits__gt=0).count(), 0)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_global_cap_and_purpose_off(self, http, _q):
        set_cfg("sms", otp_global_day=1)
        self.assertTrue(sms_service.send_sms(PHONE, "x", "otp")["ok"])
        self.assertEqual(sms_service.send_sms("01811111111", "x", "otp")["reason"],
                         "global_daily_cap")
        set_cfg("sms", safety_global_day=0)
        self.assertEqual(sms_service.send_sms(PHONE, "x", "safety")["reason"], "purpose_off")

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_too_long_refused(self, http, _q):
        set_cfg("sms", max_segments=2)
        self.assertEqual(sms_service.send_sms(PHONE, "আ" * 200, "safety")["reason"], "too_long")
        self.assertEqual(http.call_count, 0)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_legacy_adapter_facade_uses_chain(self, http, _q):
        ad = sms_gateway.adapter()
        self.assertIsNotNone(ad)
        self.assertEqual(ad.send(CANON, "x"), (True, "HTTP 200 accepted"))
        Integration.objects.update(status="not_set")
        self.assertIsNone(sms_gateway.adapter())


# ======================================================================= tagada
@mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False)
class TagadaSmsTests(APITestCase):
    def setUp(self):
        connect("sms_alpha", {"api_key": "AK", "cost_per_segment_bdt": "0.30"})
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000111",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.party = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712345678")
        KhataEntry.objects.create(party=self.party, direction="gave", amount_poisha=50000,
                                  at=timezone.now())
        self.client.force_authenticate(self.owner)
        self.url = "/api/v1/business/khata/tagada/sms/%d" % self.party.pk

    def _credits(self):
        return User.objects.get(pk=self.owner.pk).ai_credits

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_charged_as_credits_per_segment(self, http, _q):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        r = self.client.post(self.url, {}, format="json", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.data)
        segs = r.data["segments"]
        self.assertGreaterEqual(segs, 1)
        self.assertEqual(r.data["credits"], segs)          # 1 credit per segment
        self.assertEqual(self._credits(), 10 - segs)
        row = SmsLog.objects.get()
        self.assertEqual((row.purpose, row.business_id, row.credits), ("tagada", self.biz.pk, segs))
        self.assertGreater(row.cost_bdt, 0)                 # company cost logged too

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_refused_at_zero_credits(self, http, _q):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=0)
        r = self.client.post(self.url, {}, format="json")
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.data["reason"], "insufficient_credits")
        self.assertEqual(http.call_count, 0)

    @mock.patch("core.sms_gateway._http", return_value=(500, "down"))
    def test_refund_on_gateway_failure(self, http, _q):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        r = self.client.post(self.url, {}, format="json")
        self.assertEqual(r.status_code, 502)
        self.assertEqual(self._credits(), 10)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_opt_out_and_per_customer_cap(self, http, _q):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=50)
        self.assertEqual(self.client.post(self.url, {}, format="json").status_code, 200)
        r = self.client.post(self.url, {}, format="json")     # 1 per customer per day
        self.assertEqual((r.status_code, r.data["reason"]), (429, "phone_daily_cap"))
        from core.logic import msg_guard as MG
        from core.logic.business_selling import normalize_phone
        MG.record_opt_out(self.biz.pk, normalize_phone(CANON))
        r = self.client.post(self.url, {}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "opted_out"))

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_business_daily_cap(self, http, _q):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=50)
        set_cfg("sms", tagada_per_business_day=1)
        p2 = KhataParty.objects.create(business=self.biz, book="customer", name="B",
                                       phone="01811111111")
        KhataEntry.objects.create(party=p2, direction="gave", amount_poisha=100,
                                  at=timezone.now())
        self.assertEqual(self.client.post(self.url, {}, format="json").status_code, 200)
        r = self.client.post("/api/v1/business/khata/tagada/sms/%d" % p2.pk, {}, format="json")
        self.assertEqual(r.data["reason"], "business_daily_cap")

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_quiet_hours(self, http, q):
        q.return_value = True
        User.objects.filter(pk=self.owner.pk).update(ai_credits=50)
        r = self.client.post(self.url, {}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "quiet_hours"))
        self.assertEqual(self._credits(), 50)

    def test_no_gateway_is_honest(self, _q):
        Integration.objects.update(status="not_set")
        r = self.client.post(self.url, {}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (503, "sms_not_configured"))
        r = self.client.post("/api/v1/business/khata/tagada/single/%d" % self.party.pk,
                             {"channel": "sms"}, format="json")
        self.assertFalse(r.data["plan"]["share"]["available"])


# ======================================================================= OTP (SMS)
@mock.patch("core.otp._gen_code", return_value=CODE)
class SmsOtpFlowTests(APITestCase):
    def setUp(self):
        connect("sms_alpha", {"api_key": "AK-secret-1"})
        self.u = User.objects.create_user(name="A", phone=CANON, password="pw123456")

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_login_through_dedicated_gateway(self, http, _g):
        r = self.client.post("/api/v1/auth/otp/request", {"phone": PHONE, "purpose": "login"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIn(CODE, urllib.parse.parse_qs(http.call_args[0][2].decode())["msg"][0])
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"phone": PHONE, "purpose": "login", "code": CODE}, format="json")
        r = self.client.post("/api/v1/auth/otp/login",
                             {"phone": PHONE, "otp_proof": v.data["otp_proof"]}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(PhoneVerification.objects.filter(user=self.u).exists())
        self.assertEqual(SmsLog.objects.get().purpose, "otp")

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_signup_counts_as_phone_verify(self, http, _g):
        r = self.client.post("/api/v1/auth/otp/request",
                             {"phone": "01811111111", "purpose": "signup"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(SmsLog.objects.get().purpose, "phone_verify")

    @mock.patch("core.sms_gateway._http", return_value=(500, "down"))
    def test_gateway_failure_on_login_is_neutral(self, http, _g):
        known = self.client.post("/api/v1/auth/otp/request",
                                 {"phone": PHONE, "purpose": "login"}, format="json")
        unknown = self.client.post("/api/v1/auth/otp/request",
                                   {"phone": "01811111111", "purpose": "login"}, format="json")
        self.assertEqual(known.status_code, unknown.status_code)
        self.assertEqual(known.data["message"], unknown.data["message"])
        self.assertEqual(set(known.data), set(unknown.data))

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_daily_phone_cap_same_for_known_and_unknown(self, http, _g):
        set_cfg("sms", otp_per_phone_day=1)
        set_cfg("otp", resend_cooldown_seconds=15)
        for ph in (PHONE, "01811111111"):
            self.assertEqual(self.client.post("/api/v1/auth/otp/request",
                                              {"phone": ph, "purpose": "login"},
                                              format="json").status_code, 200)
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(minutes=5))
        for ph in (PHONE, "01811111111"):
            r = self.client.post("/api/v1/auth/otp/request", {"phone": ph, "purpose": "login"},
                                 format="json")
            self.assertEqual((r.status_code, r.data["reason"]), (429, "rate_limited"), ph)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_global_sms_cap_offers_email(self, http, _g):
        set_cfg("sms", verify_global_day=0)        # sign-up = the phone_verify bucket
        r = self.client.post("/api/v1/auth/otp/request",
                             {"phone": "01811111111", "purpose": "signup"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (503, "sms_daily_cap"))
        self.assertIn("email_fallback", r.data)


# ======================================================================= email OTP
@mock.patch("smtplib.SMTP", FakeSMTP)
@mock.patch("core.otp._gen_code", return_value=CODE)
class EmailOtpTests(APITestCase):
    def setUp(self):
        FakeSMTP.reset()
        connect_email()
        self.u = User.objects.create_user(name="Rahim Uddin", phone=CANON, password="pw123456")
        EmailVerification.objects.create(user=self.u, email="rahim@example.com")

    def _req(self, **body):
        return self.client.post("/api/v1/auth/otp/email/request", body, format="json")

    def test_login_by_email_when_sms_fails(self, _g):
        r = self._req(phone=PHONE, purpose="login")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertNotIn("email_masked", r.data)            # neutral for login
        self.assertEqual(len(FakeSMTP.sent), 1)
        msg = FakeSMTP.sent[0]
        self.assertEqual(msg["To"], "rahim@example.com")
        self.assertIn("assistoaiagent@gmail.com", msg["From"])
        body = mail_text(msg)
        self.assertIn(CODE, body)
        self.assertIn("AXON Dynamic", body)
        self.assertNotIn("Rahim", body)                      # no personal names
        self.assertNotIn("<img", body)
        self.assertNotIn("http", body)                       # no links / tracking
        self.assertEqual(msg.get_content_type(), "text/plain")
        self.assertEqual(FakeSMTP.logins, [("assistoaiagent@gmail.com", "abcdefghijklmnop")])
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"phone": PHONE, "purpose": "login", "code": CODE}, format="json")
        self.assertEqual(v.status_code, 200, v.data)
        r = self.client.post("/api/v1/auth/otp/login",
                             {"phone": PHONE, "otp_proof": v.data["otp_proof"]}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        # an email code never proves the phone
        self.assertFalse(PhoneVerification.objects.filter(user=self.u).exists())
        ch = OtpChallenge.objects.get()
        self.assertEqual((ch.channel, ch.email), ("email", "rahim@example.com"))
        self.assertNotIn(CODE, ch.code_hash + ch.detail)
        self.assertEqual(EmailLog.objects.get().status, "sent")

    def test_email_identity_login(self, _g):
        r = self._req(email="Rahim@Example.com", purpose="login")
        self.assertEqual(r.status_code, 200)
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"email": "rahim@example.com", "purpose": "login", "code": CODE},
                             format="json")
        self.assertEqual(v.status_code, 200, v.data)
        r = self.client.post("/api/v1/auth/otp/login",
                             {"email": "rahim@example.com", "otp_proof": v.data["otp_proof"]},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["user"]["id"], self.u.pk)

    def test_email_proof_cannot_login_another_phone(self, _g):
        self._req(email="rahim@example.com", purpose="login")
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"email": "rahim@example.com", "purpose": "login", "code": CODE},
                             format="json")
        r = self.client.post("/api/v1/auth/otp/login",
                             {"phone": PHONE, "otp_proof": v.data["otp_proof"]}, format="json")
        self.assertEqual(r.status_code, 401)
        self.assertIsNone(otp.consume_proof(v.data["otp_proof"], "login"))

    def test_password_reset_by_email(self, _g):
        self._req(phone=PHONE, purpose="password_reset")
        v = self.client.post("/api/v1/auth/otp/verify",
                             {"phone": PHONE, "purpose": "password_reset", "code": CODE},
                             format="json")
        r = self.client.post("/api/v1/auth/otp/reset",
                             {"phone": PHONE, "otp_proof": v.data["otp_proof"],
                              "password": "newpass123"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(User.objects.get(pk=self.u.pk).check_password("newpass123"))

    def test_no_enumeration(self, _g):
        known = self._req(phone=PHONE, purpose="login")
        OtpChallenge.objects.all().delete()
        unknown = self._req(phone="01811111111", purpose="login")
        nomail_user = User.objects.create_user(name="B", phone="+8801911111111", password="pw123456")
        no_verified = self._req(phone="01911111111", purpose="login")
        by_email = self._req(email="nobody@example.com", purpose="login")
        for r in (unknown, no_verified, by_email):
            self.assertEqual(r.status_code, known.status_code)
            self.assertEqual(r.data["message"], known.data["message"])
            self.assertEqual(set(r.data), set(known.data))
        self.assertEqual(len(FakeSMTP.sent), 1)               # only the real one
        self.assertTrue(nomail_user.pk)

    def test_signup_by_email_refused(self, _g):
        r = self._req(phone="01811111111", purpose="signup")
        self.assertEqual((r.status_code, r.data["reason"]), (400, "email_purpose_not_allowed"))
        r = self._req(phone="01811111111", purpose="change_number")
        self.assertEqual(r.status_code, 400)

    def test_email_not_configured_is_honest(self, _g):
        Integration.objects.filter(slug="smtp_email").update(status="not_set")
        r = self._req(phone=PHONE, purpose="login")
        self.assertEqual((r.status_code, r.data["reason"]), (503, "email_not_configured"))
        self.assertFalse(otp.public_status()["email_enabled"])

    def test_gmail_daily_cap(self, _g):
        set_cfg("email", daily_cap=3, near_cap_pct=60)
        for _ in range(2):
            EmailLog.objects.create(purpose="otp", to_hash="x", status="sent")
        st = otp.public_status()
        self.assertTrue(st["email_enabled"])
        self.assertTrue(st["email_prefer_sms"])               # 2/3 >= 60 %
        r = self._req(phone=PHONE, purpose="login")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["prefer_sms"])
        OtpChallenge.objects.all().delete()
        r = self._req(phone=PHONE, purpose="login")           # 3/3 → refused honestly
        self.assertEqual((r.status_code, r.data["reason"]), (503, "email_daily_cap"))
        self.assertFalse(otp.public_status()["email_enabled"])
        self.assertEqual(len(FakeSMTP.sent), 1)
        # only the last 24 hours count
        EmailLog.objects.update(created_at=timezone.now() - timedelta(hours=25))
        self.assertTrue(otp.email_available())

    def test_gmail_quota_error_is_send_failed(self, _g):
        FakeSMTP.fail_send = True
        self.client.force_authenticate(self.u)
        r = self._req(purpose="delete_account")
        self.assertEqual((r.status_code, r.data["reason"]), (502, "send_failed"))
        self.assertEqual(EmailLog.objects.get().status, "failed")

    def test_rate_limit_per_email(self, _g):
        set_cfg("otp", per_email_per_hour=2, resend_cooldown_seconds=15)
        for i in range(2):
            self.assertEqual(self._req(email="rahim@example.com", purpose="login").status_code, 200)
            OtpChallenge.objects.update(created_at=timezone.now() - timedelta(minutes=1 + i))
        r = self._req(email="rahim@example.com", purpose="login")
        self.assertEqual((r.status_code, r.data["reason"]), (429, "rate_limited"))

    def test_rate_limit_per_phone_shared_with_sms(self, _g):
        set_cfg("otp", per_phone_per_hour=1)
        OtpChallenge.objects.create(phone=CANON, purpose="login", code_hash="", salt="s",
                                    expires_at=timezone.now(), consumed_at=timezone.now())
        r = self._req(phone=PHONE, purpose="login")
        self.assertEqual((r.status_code, r.data["reason"]), (429, "rate_limited"))

    def test_rate_limit_per_ip_and_device(self, _g):
        set_cfg("otp", per_ip_per_hour=1, per_device_per_hour=1)
        self.assertEqual(self.client.post("/api/v1/auth/otp/email/request",
                                          {"email": "a@example.com", "purpose": "login"},
                                          format="json", REMOTE_ADDR="10.0.0.9").status_code, 200)
        r = self.client.post("/api/v1/auth/otp/email/request",
                             {"email": "b@example.com", "purpose": "login"},
                             format="json", REMOTE_ADDR="10.0.0.9")
        self.assertEqual(r.data["reason"], "rate_limited")
        self.assertEqual(self.client.post("/api/v1/auth/otp/email/request",
                                          {"email": "c@example.com", "purpose": "login"},
                                          format="json", REMOTE_ADDR="10.0.0.10",
                                          HTTP_X_DEVICE_ID="dev-1").status_code, 200)
        r = self.client.post("/api/v1/auth/otp/email/request",
                             {"email": "d@example.com", "purpose": "login"},
                             format="json", REMOTE_ADDR="10.0.0.11", HTTP_X_DEVICE_ID="dev-1")
        self.assertEqual(r.data["reason"], "rate_limited")

    def test_lockout_after_wrong_codes(self, _g):
        set_cfg("otp", max_attempts=2)
        self._req(email="rahim@example.com", purpose="login")
        for _ in range(2):
            r = self.client.post("/api/v1/auth/otp/verify",
                                 {"email": "rahim@example.com", "purpose": "login",
                                  "code": "000000"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (423, "locked"))
        r = self.client.post("/api/v1/auth/otp/verify",
                             {"email": "rahim@example.com", "purpose": "login", "code": CODE},
                             format="json")
        self.assertEqual(r.data["reason"], "locked")

    def test_verify_email_in_profile(self, _g):
        other = User.objects.create_user(name="C", phone="+8801811111111", password="pw123456")
        self.client.force_authenticate(other)
        me = self.client.get("/api/v1/auth/otp/email/me")
        self.assertEqual(me.data["verified"], False)
        r = self._req(email="New@Example.com", purpose="email_verify")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIn("@example.com", r.data["email_masked"])
        r = self.client.post("/api/v1/auth/otp/email/confirm",
                             {"email": "new@example.com", "code": CODE}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        other.refresh_from_db()
        self.assertEqual(other.email, "new@example.com")
        self.assertEqual(EmailVerification.objects.get(user=other).email, "new@example.com")
        self.assertTrue(self.client.get("/api/v1/auth/otp/email/me").data["verified"])

    def test_cannot_claim_someone_elses_email(self, _g):
        other = User.objects.create_user(name="C", phone="+8801811111111", password="pw123456")
        self.client.force_authenticate(other)
        r = self._req(email="rahim@example.com", purpose="email_verify")
        self.assertEqual(r.status_code, 200)                  # same answer...
        self.assertEqual(len(FakeSMTP.sent), 0)               # ...nothing sent
        r = self.client.post("/api/v1/auth/otp/email/confirm",
                             {"email": "rahim@example.com", "code": CODE}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_email_verify_needs_login(self, _g):
        r = self._req(email="x@example.com", purpose="email_verify")
        self.assertEqual(r.status_code, 401)

    def test_sms_request_cannot_use_email_verify(self, _g):
        r = self.client.post("/api/v1/auth/otp/request",
                             {"phone": PHONE, "purpose": "email_verify"}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_smtp_test_button(self, _g):
        st, detail = integrations.test("smtp_email", test_to="owner@example.com")
        self.assertEqual(st, "working", detail)
        self.assertEqual(FakeSMTP.sent[-1]["To"], "owner@example.com")
        FakeSMTP.fail_login = True
        st, detail = integrations.test("smtp_email")
        self.assertEqual(st, "failing")
        self.assertIn("app password", detail)
        self.assertNotIn("abcd", detail)

    def test_template_bilingual(self, _g):
        s_bn, b_bn = email_sender.otp_email(CODE, "bn", 300)
        s_en, b_en = email_sender.otp_email(CODE, "en", 300)
        self.assertTrue(b_bn.startswith("আপনার"))
        self.assertTrue(b_en.startswith("Your Assisto"))
        for b in (b_bn, b_en):
            self.assertIn("Your Assisto verification code", b)
            self.assertIn("যাচাই কোড", b)
            self.assertIn("AXON Dynamic", b)


# ======================================================================= secrets
@mock.patch("smtplib.SMTP", FakeSMTP)
@mock.patch("core.otp._gen_code", return_value=CODE)
class SecretsNeverLoggedTests(APITestCase):
    def setUp(self):
        FakeSMTP.reset()
        connect_email()
        connect("sms_alpha", {"api_key": "AK-very-secret-9"})
        self.u = User.objects.create_user(name="A", phone=CANON, password="pw123456")
        EmailVerification.objects.create(user=self.u, email="a@example.com")

    @mock.patch("core.sms_gateway._http",
                return_value=(200, json.dumps({"error": 7, "msg": "fail 482913 AK-very-secret-9"})))
    def test_nothing_secret_in_logs_or_rows(self, http, _g):
        with self.assertLogs(level="DEBUG") as logs:
            import logging
            logging.getLogger("probe").debug("start")
            self.client.post("/api/v1/auth/otp/request", {"phone": PHONE, "purpose": "login"},
                             format="json")
            self.client.post("/api/v1/auth/otp/email/request",
                             {"phone": PHONE, "purpose": "login"}, format="json")
            sms_service.send_safety_sms(self.u, PHONE, "SOS " + CODE)
        out = "\n".join(logs.output)
        for secret in (CODE, "AK-very-secret-9", APP_PW, "abcdefghijklmnop"):
            self.assertNotIn(secret, out)
        rows = json.dumps([list(SmsLog.objects.values()), list(EmailLog.objects.values()),
                           list(OtpChallenge.objects.values())], default=str)
        for secret in (CODE, "AK-very-secret-9", "abcdefghijklmnop"):
            self.assertNotIn(secret, rows)
        listed = json.dumps(integrations.list_all("en"), default=str)
        self.assertNotIn("AK-very-secret-9", listed)
        self.assertNotIn("abcdefghijklmnop", listed)
        self.assertNotIn(APP_PW, listed)
        # SendResult repr never carries the text
        r = sms_gateway.make("sms_alpha", {"api_key": "K"}).send_result(CANON, "x " + CODE,
                                                                        secret=CODE)
        self.assertNotIn(CODE, repr(r) + r.detail)


class PricingCfgTests(TestCase):
    def test_defaults_and_clamps(self):
        from core.logic import pricing as P
        c = P.sms_cfg({})
        self.assertEqual(c["primary"], "")
        self.assertGreater(c["otp_global_day"], 0)
        c = P.sms_cfg({"sms": {"primary": "evil", "tagada_per_phone_day": 99,
                               "safety_global_day": -5}})
        self.assertEqual(c["primary"], "")
        self.assertEqual(c["tagada_per_phone_day"], 5)
        self.assertEqual(c["safety_global_day"], 0)
        e = P.email_cfg({})
        self.assertEqual((e["daily_cap"], e["provider"]), (400, "smtp"))
        self.assertEqual(P.email_cfg({"email": {"daily_cap": 9999}})["daily_cap"], 2000)
        self.assertEqual(P.otp_limits({})["per_email_per_hour"], 5)
