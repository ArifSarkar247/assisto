"""vault100 — forgotten-PIN recovery (server never sees the PIN), document
expiry pushes (60/30/7/1, caps, quiet hours, idempotent), per-doc opt-out.

Push HTTP is mocked (tests_push.FakeFCM); SMS HTTP is mocked; no network.
"""
import json
from datetime import date, datetime, timedelta
from io import StringIO
from unittest import mock
from zoneinfo import ZoneInfo

from django.core.management import call_command
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import ops_health, otp, push, vault_expiry as VE, vault_recovery as VR
from core.models import AuditLog, Device, DocExpiryPush, Document, OtpProof, User
from core.tests_o1_otp import CODE, enable_sms, http_ok
from core.tests_push import _PushBase

DHAKA = ZoneInfo("Asia/Dhaka")
PIN = "482173"          # a PIN the phone would hold — must never reach the server


def _noon(d=None):
    d = d or date(2026, 11, 2)
    return datetime(d.year, d.month, d.day, 11, 0, tzinfo=DHAKA)


def _user(phone="01712345678", pw="Secret-pass-1", lang="bn"):
    return User.objects.create_user(name="A", phone=phone, password=pw, language=lang)


def _client(u):
    c = APIClient()
    c.force_authenticate(u)
    return c


# ====================================================================== recovery
class RecoveryStatusTests(TestCase):
    def setUp(self):
        self.u = _user()
        self.c = _client(self.u)

    def test_status_is_honest_and_pin_free(self):
        r = self.c.get("/api/v1/vault/recovery/status")
        self.assertEqual(r.status_code, 200)
        j = r.json()
        self.assertIs(j["end_to_end_encrypted"], False)
        self.assertIs(j["pin_on_server"], False)
        self.assertTrue(j["password"])
        self.assertFalse(j["sms"])            # no gateway in tests
        self.assertTrue(j["any"])
        self.assertEqual(j["resets_left_today"], VR.MAX_RESETS_PER_DAY)
        self.assertNotIn("pin", json.dumps(j).lower().replace("pin_on_server", ""))

    def test_no_method_without_password_or_sms(self):
        self.u.set_unusable_password()
        self.u.save()
        j = self.c.get("/api/v1/vault/recovery/status").json()
        self.assertFalse(j["any"])

    def test_requires_login(self):
        self.assertEqual(APIClient().get("/api/v1/vault/recovery/status").status_code, 401)
        self.assertEqual(APIClient().post("/api/v1/vault/recovery/verify",
                                          {"method": "password"}).status_code, 401)


class RecoveryPasswordTests(TestCase):
    def setUp(self):
        self.u = _user()
        self.c = _client(self.u)
        p = mock.patch.object(VR, "_notify")
        self.notify = p.start()
        self.addCleanup(p.stop)

    def post(self, body):
        return self.c.post("/api/v1/vault/recovery/verify", body, format="json")

    def test_refuses_any_pin_or_key_field(self):
        for k in ("pin", "new_pin", "PIN", "recovery_code", "key", "offline_key"):
            r = self.post({"method": "password", "password": "Secret-pass-1", k: PIN})
            self.assertEqual(r.status_code, 400, k)
            self.assertEqual(r.json()["reason"], "never_send_pin")
        self.assertFalse(AuditLog.objects.filter(action=VR.A_RESET).exists())

    def test_right_password_resets_and_logs_without_secrets(self):
        r = self.post({"method": "password", "password": "Secret-pass-1"})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.json()["ok"])
        row = AuditLog.objects.get(action=VR.A_RESET)
        self.assertEqual(row.detail, {"method": "password"})
        self.notify.assert_called_once()
        blob = json.dumps(list(AuditLog.objects.values()), default=str)
        self.assertNotIn("Secret-pass-1", blob)
        self.assertNotIn(PIN, blob)

    def test_wrong_password_counts_down_then_locks(self):
        for i in range(VR.MAX_PASSWORD_FAILS):
            r = self.post({"method": "password", "password": "nope"})
            self.assertEqual(r.status_code, 403)
            self.assertEqual(r.json()["attempts_left"], VR.MAX_PASSWORD_FAILS - i - 1)
        r = self.post({"method": "password", "password": "Secret-pass-1"})
        self.assertEqual(r.status_code, 429)          # even the right one now
        self.assertEqual(r.json()["reason"], "locked")
        self.assertFalse(AuditLog.objects.filter(action=VR.A_RESET).exists())

    def test_lock_expires_after_an_hour(self):
        for _ in range(VR.MAX_PASSWORD_FAILS):
            self.post({"method": "password", "password": "nope"})
        AuditLog.objects.filter(action=VR.A_FAIL).update(
            created_at=datetime.now(DHAKA) - timedelta(hours=2))
        self.assertEqual(self.post({"method": "password",
                                    "password": "Secret-pass-1"}).status_code, 200)

    def test_daily_reset_cap(self):
        for _ in range(VR.MAX_RESETS_PER_DAY):
            self.assertEqual(self.post({"method": "password",
                                        "password": "Secret-pass-1"}).status_code, 200)
        r = self.post({"method": "password", "password": "Secret-pass-1"})
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["reason"], "reset_cap")

    def test_no_usable_password(self):
        self.u.set_unusable_password()
        self.u.save()
        r = self.post({"method": "password", "password": ""})
        self.assertEqual(r.json()["reason"], "no_password")

    def test_bad_method(self):
        self.assertEqual(self.post({"method": "pin"}).status_code, 400)


@mock.patch("core.sms_gateway._http", side_effect=http_ok)
@mock.patch("core.otp._gen_code", return_value=CODE)
class RecoveryOtpTests(TestCase):
    def setUp(self):
        enable_sms()
        self.u = _user()
        self.c = _client(self.u)
        p = mock.patch.object(VR, "_notify")
        p.start()
        self.addCleanup(p.stop)

    def _proof(self, purpose="vault_reset"):
        r = self.c.post("/api/v1/auth/otp/request", {"purpose": purpose}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        r = self.c.post("/api/v1/auth/otp/verify", {"purpose": purpose, "code": CODE},
                        format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()["otp_proof"]

    def test_code_goes_to_own_number_only(self, _gen, http):
        r = self.c.post("/api/v1/auth/otp/request",
                        {"purpose": "vault_reset", "phone": "01812345678"}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "phone_mismatch")
        r = APIClient().post("/api/v1/auth/otp/request", {"purpose": "vault_reset",
                                                         "phone": "01712345678"},
                             format="json")
        self.assertEqual(r.status_code, 401)

    def test_otp_reset_single_use(self, *_):
        proof = self._proof()
        r = self.c.post("/api/v1/vault/recovery/verify",
                        {"method": "otp", "otp_proof": proof}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["method"], "otp_sms")
        r = self.c.post("/api/v1/vault/recovery/verify",
                        {"method": "otp", "otp_proof": proof}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "bad_otp")
        # the proof is stored hashed only
        self.assertFalse(OtpProof.objects.filter(token_hash=proof).exists())

    def test_other_purpose_proof_refused(self, *_):
        self.c.force_authenticate(None)
        r = APIClient().post("/api/v1/auth/otp/request",
                             {"purpose": "login", "phone": "01712345678"}, format="json")
        self.assertEqual(r.status_code, 200)
        proof = APIClient().post("/api/v1/auth/otp/verify",
                                 {"purpose": "login", "phone": "01712345678",
                                  "code": CODE}, format="json").json()["otp_proof"]
        c = _client(self.u)
        r = c.post("/api/v1/vault/recovery/verify", {"method": "otp", "otp_proof": proof},
                   format="json")
        self.assertEqual(r.status_code, 403)

    def test_other_users_proof_refused(self, *_):
        proof = self._proof()
        other = _user(phone="01912345678")
        r = _client(other).post("/api/v1/vault/recovery/verify",
                                {"method": "otp", "otp_proof": proof}, format="json")
        self.assertEqual(r.status_code, 403)

    def test_wrong_codes_lock_the_purpose(self, *_):
        self.c.post("/api/v1/auth/otp/request", {"purpose": "vault_reset"}, format="json")
        last = None
        for _ in range(otp.limits()["max_attempts"] + 1):
            last = self.c.post("/api/v1/auth/otp/verify",
                               {"purpose": "vault_reset", "code": "000000"}, format="json")
        self.assertIn(last.json()["reason"], ("locked", "no_active_code"))
        r = self.c.post("/api/v1/auth/otp/verify",
                        {"purpose": "vault_reset", "code": CODE}, format="json")
        self.assertNotEqual(r.status_code, 200)

    def test_status_reports_sms(self, *_):
        j = self.c.get("/api/v1/vault/recovery/status").json()
        self.assertTrue(j["sms"])
        self.assertTrue(j["phone_masked"].startswith("017"))
        self.assertNotIn("12345", j["phone_masked"])

    def test_purpose_registered(self, *_):
        self.assertIn("vault_reset", otp.PURPOSES)
        self.assertIn("vault_reset", otp.AUTHED_PURPOSES)
        self.assertIn("vault_reset", otp.EMAIL_PURPOSES)


class RecoveryNotifyTests(_PushBase):
    def test_reset_pushes_a_security_notice(self):
        u = self.mkuser("01750000901")
        Device.objects.create(user=u, push_token="d1")
        r = _client(u).post("/api/v1/vault/recovery/verify",
                            {"method": "password", "password": "pw12345!"}, format="json")
        self.assertEqual(r.status_code, 200)
        m = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(m["data"]["event"], "vault_pin_reset")
        self.assertNotIn(PIN, json.dumps(m))


# ====================================================================== expiry
class ExpiryPureTests(SimpleTestCase):
    def test_due_stage(self):
        cases = {-1: None, 0: 1, 1: 1, 2: 7, 7: 7, 8: 30, 30: 30, 31: 60, 60: 60, 61: None}
        for days, st in cases.items():
            self.assertEqual(VE.due_stage(days), st, days)

    def test_message_type_only_bn_digits(self):
        m = VE.build_message([("passport", 30)])
        self.assertEqual(m["title"]["bn"], "পাসপোর্ট-এর মেয়াদ ৩০ দিনে শেষ")
        self.assertEqual(m["title"]["en"], "Passport expires in 30 days")
        self.assertIn("৬ মাস", m["body"]["bn"])
        m = VE.build_message([("insurance", 1), ("trade_licence", 7),
                              ("vehicle", 30), ("nid", 60)])
        self.assertEqual(m["title"]["bn"], "৪টি কাগজের মেয়াদ শিগগির শেষ")
        self.assertIn("বিমা (আগামীকাল)", m["body"]["bn"])
        self.assertIn("ট্রেড লাইসেন্স (৭ দিনে)", m["body"]["bn"])
        self.assertIn("1 more", m["body"]["en"])
        self.assertEqual(VE.build_message([("weird", 0)])["title"]["en"],
                         "A document expires today")


class ExpirySweepTests(TestCase):
    def setUp(self):
        self.u = _user()
        self.now = _noon()
        self.today = self.now.date()
        self.sent = []

    def fake_push(self, user, kind, tbn, ten, bbn, ben, data=None):
        self.sent.append({"user": user.id, "kind": kind, "title_bn": tbn, "title_en": ten,
                          "body_bn": bbn, "body_en": ben, "data": data})
        return 1

    def doc(self, days, doc_type="passport", user=None, **kw):
        return Document.objects.create(user=user or self.u, title="My secret AB1234567",
                                       doc_type=doc_type, details={"number": "AB1234567"},
                                       expiry_date=self.today + timedelta(days=days), **kw)

    def sweep(self, now=None):
        return VE.sweep(now=now or self.now, push_fn=self.fake_push)

    def test_stage_once_then_next_stage(self):
        self.doc(25)
        self.sweep()
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["kind"], "doc_expiry")
        self.assertEqual(self.sent[0]["data"]["route"], "vault")
        self.sweep()
        self.sweep(self.now + timedelta(hours=3))
        self.assertEqual(len(self.sent), 1)                   # idempotent
        self.sweep(self.now + timedelta(days=5))               # 20 days left: same stage 30
        self.assertEqual(len(self.sent), 1)
        self.sweep(self.now + timedelta(days=18))              # 7 days left
        self.assertEqual(len(self.sent), 2)
        self.sweep(self.now + timedelta(days=24))              # 1 day left
        self.assertEqual(len(self.sent), 3)
        self.sweep(self.now + timedelta(days=25))              # day 0: stage 1 already sent
        self.sweep(self.now + timedelta(days=26))              # expired
        self.assertEqual(len(self.sent), 3)
        self.assertEqual(sorted(DocExpiryPush.objects.values_list("stage", flat=True)),
                         [1, 7, 30])

    def test_never_leaks_title_or_numbers(self):
        self.doc(7)
        self.sweep()
        blob = json.dumps(self.sent, ensure_ascii=False)
        self.assertNotIn("secret", blob)
        self.assertNotIn("AB1234567", blob)

    def test_quiet_hours(self):
        self.doc(7)
        late = datetime(2026, 11, 2, 22, 30, tzinfo=DHAKA)
        early = datetime(2026, 11, 3, 8, 59, tzinfo=DHAKA)
        self.assertEqual(self.sweep(late).get("quiet_hours"), 1)
        self.sweep(early)
        self.assertEqual(self.sent, [])
        self.assertFalse(DocExpiryPush.objects.exists())
        self.sweep(datetime(2026, 11, 3, 9, 0, tzinfo=DHAKA))
        self.assertEqual(len(self.sent), 1)

    def test_one_push_per_user_per_day_combined(self):
        self.doc(7, "insurance")
        self.doc(30, "trade_licence")
        self.doc(55, "vehicle")
        self.sweep()
        self.assertEqual(len(self.sent), 1)
        self.assertIn("৩টি", self.sent[0]["title_bn"])
        self.assertEqual(self.sent[0]["data"]["days_left"], "7")
        # a new due document later the SAME day waits for tomorrow
        self.doc(1, "nid")
        self.sweep(self.now + timedelta(hours=2))
        self.assertEqual(len(self.sent), 1)
        self.sweep(self.now + timedelta(days=1))
        self.assertEqual(len(self.sent), 2)

    def test_other_users_not_capped_by_me(self):
        other = _user(phone="01812345678")
        self.doc(7)
        self.doc(7, user=other)
        self.sweep()
        self.assertEqual({s["user"] for s in self.sent}, {self.u.id, other.id})

    def test_opt_out_and_far_and_expired(self):
        self.doc(7, expiry_alerts=False)
        self.doc(61)
        self.doc(-3)
        self.sweep()
        self.assertEqual(self.sent, [])

    def test_inactive_user_skipped(self):
        self.doc(7)
        User.objects.filter(pk=self.u.pk).update(is_active=False)
        self.sweep()
        self.assertEqual(self.sent, [])

    def test_changed_expiry_starts_new_cycle(self):
        d = self.doc(7)
        self.sweep()
        d.expiry_date = self.today + timedelta(days=5 + 365)   # renewed (> 60: nothing)
        d.save()
        self.sweep(self.now + timedelta(days=1))
        self.assertEqual(len(self.sent), 1)
        d.expiry_date = self.today + timedelta(days=10)          # re-entered differently
        d.save()
        self.sweep(self.now + timedelta(days=1))
        self.assertEqual(len(self.sent), 2)

    def test_concurrent_claim_never_double_sends(self):
        d = self.doc(7)
        DocExpiryPush.objects.create(document=d, user=self.u, stage=7,
                                     expiry_date=d.expiry_date)
        self.sweep()
        self.assertEqual(self.sent, [])
        # and a planner that raced past the check still can't claim it
        self.assertIsNone(VE._claim(d, 7))

    def test_push_failure_does_not_crash(self):
        self.doc(7)

        def boom(*a, **k):
            raise RuntimeError("fcm down")
        st = VE.sweep(now=self.now, push_fn=boom)
        self.assertEqual(st["pushes"], 1)
        self.assertEqual(st["delivered"], 0)


class ExpiryCommandTests(_PushBase):
    def test_command_pushes_notification_kind(self):
        u = self.mkuser("01750000902", lang="en")
        Device.objects.create(user=u, push_token="dx")
        today = VE._dhaka_today(_noon())
        Document.objects.create(user=u, title="Secret", doc_type="passport",
                                expiry_date=today + timedelta(days=30))
        with mock.patch("core.vault_expiry.timezone.now", return_value=_noon()):
            out = StringIO()
            call_command("vault_expiry_alerts", stdout=out)
        self.assertIn("pushes=1", out.getvalue())
        m = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(m["data"]["kind"], "doc_expiry")
        self.assertEqual(m["notification"]["title"], "Passport expires in 30 days")
        self.assertNotIn("Secret", json.dumps(m))
        self.assertEqual(m["android"]["notification"]["channel_id"], "reminders")

    def test_kind_registered(self):
        self.assertIn("doc_expiry", push.KINDS)
        self.assertNotIn("doc_expiry", push.DATA_ONLY_KINDS)
        self.assertEqual(push.CHANNELS["doc_expiry"], "reminders")


class ExpiryNoPushTests(TestCase):
    def test_skips_without_push_key(self):
        with mock.patch("core.push.is_available", return_value=False):
            out = StringIO()
            call_command("vault_expiry_alerts", stdout=out)
        self.assertIn("skipped", out.getvalue())
        self.assertFalse(DocExpiryPush.objects.exists())

    def test_cron_line_uses_flock(self):
        job = [j for j in ops_health.JOBS if j.name == "vault_expiry_alerts"][0]
        line = job.cron_line()
        self.assertTrue(line.startswith("20 * * * * ubuntu cd /home/ubuntu/assisto/backend && "
                                        "flock -n /tmp/assisto-vault-expiry-alerts.lock "))
        self.assertIn("manage.py vault_expiry_alerts --quiet", line)


class DocumentOptOutApiTests(TestCase):
    def test_patch_expiry_alerts(self):
        u = _user()
        d = Document.objects.create(user=u, title="P", doc_type="passport")
        c = _client(u)
        self.assertTrue(c.get("/api/v1/documents/").json()[0]["expiry_alerts"])
        r = c.patch("/api/v1/documents/%d/" % d.id, {"expiry_alerts": False}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        d.refresh_from_db()
        self.assertFalse(d.expiry_alerts)
        # new vault types are accepted
        r = c.post("/api/v1/documents/", {"title": "T", "doc_type": "trade_licence"},
                   format="json")
        self.assertEqual(r.status_code, 201, r.content)
