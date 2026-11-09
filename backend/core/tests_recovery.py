"""recovery (owner order Part 8) — Account & security + account recovery.

Every flow: per-device sessions (list, sign out one / others, legacy Token
still works), change password (signs out other devices), add/verify email
(10 min, resend 45 s, 5 tries), the gentle nudge (twice, never nag), forgot
password channel choice, email/phone change alerts + "This was not me",
the 24 h rule, support recovery (proof, family confirmation, 48 h hold,
Owner Admin review) and rate limits. Email/SMS are mocked at the seam."""
import secrets
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient, APITestCase

from core import account_recovery as AR
from core import otp
from core.models import (AccountSecurityState, CircleMember, DeviceSession,
                         EmailVerification, IdentityChange, OtpChallenge, OtpProof,
                         RecoveryRequest, User)

CODE = "482913"
PW = "oldpass123"


def make_proof(canon, purpose, email=""):
    raw = secrets.token_urlsafe(16)
    now = timezone.now()
    OtpProof.objects.create(token_hash=otp._sha(raw), phone=canon, purpose=purpose,
                            channel="sms", email=email, created_at=now,
                            expires_at=now + timedelta(minutes=10))
    return raw


class Mail:
    sent = []

    @classmethod
    def send(cls, to, subject, body, purpose="otp"):
        cls.sent.append({"to": to, "subject": subject, "body": body, "purpose": purpose})
        return {"ok": True, "reason": "ok", "provider": "smtp"}


class Base(APITestCase):
    def setUp(self):
        cache.clear()
        Mail.sent = []
        p = [mock.patch("core.otp._gen_code", return_value=CODE),
             mock.patch("core.email_sender.configured", return_value=True),
             mock.patch("core.email_sender.send_email", side_effect=Mail.send)]
        for x in p:
            x.start()
            self.addCleanup(x.stop)
        self.u = User.objects.create_user(name="Rahim Uddin", phone="+8801711000001",
                                          password=PW)

    def login(self, ident="+8801711000001", pw=PW, device=True, dev_id="dev-a",
              name="Realme 9i"):
        c = APIClient()
        hdr = {"HTTP_X_DEVICE_ID": dev_id, "HTTP_X_DEVICE_NAME": name}
        if device:
            hdr["HTTP_X_SESSION_MODE"] = "device"
        r = c.post("/api/v1/auth/login", {"identifier": ident, "password": pw},
                   format="json", **hdr)
        self.assertEqual(r.status_code, 200, r.data)
        c.credentials(HTTP_AUTHORIZATION="Token " + r.data["token"])
        return c, r.data["token"]

    def verify_email(self, c, addr):
        r = c.post("/api/v1/auth/otp/email/request", {"email": addr, "purpose": "email_verify"},
                   format="json")
        self.assertEqual(r.status_code, 200, r.data)
        r = c.post("/api/v1/auth/otp/email/confirm", {"email": addr, "code": CODE},
                   format="json")
        return r


class SessionTests(Base):
    def test_new_build_gets_device_session_old_build_legacy_token(self):
        c1, k1 = self.login()
        self.assertFalse(Token.objects.filter(key=k1).exists())
        self.assertEqual(DeviceSession.objects.filter(user=self.u).count(), 1)
        self.assertEqual(c1.get("/api/v1/account/security").status_code, 200)
        c2, k2 = self.login(device=False)                     # an older app build
        self.assertTrue(Token.objects.filter(key=k2, user=self.u).exists())
        d = c1.get("/api/v1/account/security").data
        kinds = sorted(x["kind"] for x in d["devices"])
        self.assertEqual(kinds, ["device", "legacy"])
        me = [x for x in d["devices"] if x["current"]]
        self.assertEqual((len(me), me[0]["name"]), (1, "Realme 9i"))
        self.assertEqual(c2.get("/api/v1/account/security").data["current_device"], "legacy")

    def test_sign_out_one_device_and_others(self):
        c1, _ = self.login(dev_id="a")
        c2, _ = self.login(dev_id="b", name="Samsung A15")
        c3, _ = self.login(dev_id="c", name="Xiaomi")
        sid2 = [x["id"] for x in c1.get("/api/v1/account/security").data["devices"]
                if x["name"] == "Samsung A15"][0]
        r = c1.post("/api/v1/account/security/devices/%s/signout" % sid2)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(c2.get("/api/v1/account/security").status_code, 401)
        self.assertEqual(c3.get("/api/v1/account/security").status_code, 200)
        # cannot remote-sign-out the current device
        cur = c1.get("/api/v1/account/security").data["current_device"]
        self.assertEqual(c1.post("/api/v1/account/security/devices/%s/signout" % cur)
                         .status_code, 400)
        r = c1.post("/api/v1/account/security/devices/signout-others")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(c3.get("/api/v1/account/security").status_code, 401)
        self.assertEqual(c1.get("/api/v1/account/security").status_code, 200)

    def test_same_device_login_replaces_its_session(self):
        self.login(dev_id="a")
        self.login(dev_id="a")
        self.assertEqual(DeviceSession.objects.filter(user=self.u, revoked_at__isnull=True)
                         .count(), 1)

    def test_logout_revokes_only_this_device(self):
        c1, _ = self.login(dev_id="a")
        c2, _ = self.login(dev_id="b")
        self.assertEqual(c1.post("/api/v1/auth/logout").status_code, 204)
        self.assertEqual(c1.get("/api/v1/account/security").status_code, 401)
        self.assertEqual(c2.get("/api/v1/account/security").status_code, 200)

    def test_blocked_account_refused_with_device_session(self):
        c1, _ = self.login()
        User.objects.filter(pk=self.u.pk).update(account_status="banned")
        self.assertEqual(c1.get("/api/v1/account/security").status_code, 401)

    def test_otp_login_issues_device_session(self):
        raw = make_proof("+8801711000001", "login")
        r = APIClient().post("/api/v1/auth/otp/login",
                             {"phone": "01711000001", "otp_proof": raw},
                             format="json", HTTP_X_SESSION_MODE="device")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertFalse(Token.objects.filter(key=r.data["token"]).exists())
        self.assertTrue(DeviceSession.objects.filter(user=self.u).exists())


class PasswordTests(Base):
    def test_change_password_signs_out_other_devices(self):
        c1, _ = self.login(dev_id="a")
        c2, _ = self.login(dev_id="b")
        r = c1.post("/api/v1/account/security/password",
                    {"current_password": "wrong", "new_password": "newpass456"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (400, "wrong_password"))
        r = c1.post("/api/v1/account/security/password",
                    {"current_password": PW, "new_password": "short"}, format="json")
        self.assertEqual(r.data["reason"], "weak_password")
        r = c1.post("/api/v1/account/security/password",
                    {"current_password": PW, "new_password": "newpass456"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(c2.get("/api/v1/account/security").status_code, 401)
        self.assertEqual(c1.get("/api/v1/account/security").status_code, 200)
        self.u.refresh_from_db()
        self.assertTrue(self.u.check_password("newpass456"))
        self.assertIsNotNone(AccountSecurityState.objects.get(user=self.u).password_changed_at)

    def test_legacy_token_caller_gets_a_new_device_token(self):
        c, k = self.login(device=False)
        r = c.post("/api/v1/account/security/password",
                   {"current_password": PW, "new_password": "newpass456"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(Token.objects.filter(key=k).exists())
        c.credentials(HTTP_AUTHORIZATION="Token " + r.data["token"])
        self.assertEqual(c.get("/api/v1/account/security").status_code, 200)

    def test_wrong_current_password_rate_limited(self):
        c, _ = self.login()
        for _ in range(5):
            c.post("/api/v1/account/security/password",
                   {"current_password": "bad", "new_password": "newpass456"}, format="json")
        r = c.post("/api/v1/account/security/password",
                   {"current_password": PW, "new_password": "newpass456"}, format="json")
        self.assertEqual(r.status_code, 429)

    def test_sms_reset_signs_out_device_sessions(self):
        c, _ = self.login()
        raw = make_proof("+8801711000001", "password_reset")
        r = APIClient().post("/api/v1/auth/otp/reset", {"phone": "01711000001", "otp_proof": raw,
                                                        "password": "brandnew789"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(c.get("/api/v1/account/security").status_code, 401)


class EmailTests(Base):
    def test_add_email_10_min_45_s_5_tries(self):
        c, _ = self.login()
        r = c.post("/api/v1/auth/otp/email/request", {"email": "rahim@example.com",
                                                     "purpose": "email_verify"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual((r.data["expires_in"], r.data["resend_in"]), (600, 45))
        self.assertIn(CODE, Mail.sent[-1]["body"])
        r = c.post("/api/v1/auth/otp/email/request", {"email": "rahim@example.com",
                                                     "purpose": "email_verify"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (429, "cooldown"))
        OtpChallenge.objects.update(created_at=timezone.now() - timedelta(seconds=46))
        r = c.post("/api/v1/auth/otp/email/request", {"email": "rahim@example.com",
                                                     "purpose": "email_verify"}, format="json")
        self.assertEqual(r.status_code, 200)
        ch = OtpChallenge.objects.filter(consumed_at__isnull=True).get()
        self.assertAlmostEqual((ch.expires_at - ch.created_at).total_seconds(), 600, delta=2)
        for i in range(4):
            r = c.post("/api/v1/auth/otp/email/confirm",
                       {"email": "rahim@example.com", "code": "000000"}, format="json")
            self.assertEqual(r.data.get("attempts_left"), 4 - i)
        r = c.post("/api/v1/auth/otp/email/confirm",
                   {"email": "rahim@example.com", "code": "000000"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (423, "locked"))
        r = c.post("/api/v1/auth/otp/email/confirm",
                   {"email": "rahim@example.com", "code": CODE}, format="json")
        self.assertEqual(r.data["reason"], "locked")

    def test_verified_email_shows_on_security_page(self):
        c, _ = self.login()
        d = c.get("/api/v1/account/security").data
        self.assertEqual((d["email"], d["email_verified"]), ("", False))
        self.assertFalse(d["google"]["available"])
        self.assertEqual(self.verify_email(c, "rahim@example.com").status_code, 200)
        d = c.get("/api/v1/account/security").data
        self.assertEqual((d["email"], d["email_verified"]), ("rahim@example.com", True))
        self.assertFalse(d["nudge"]["show"])

    def test_email_change_alerts_old_and_not_me_reverts_and_locks(self):
        c, _ = self.login(dev_id="a")
        c2, _ = self.login(dev_id="b")
        self.verify_email(c, "old@example.com")
        Mail.sent = []
        r = self.verify_email(c, "new@example.com")
        self.assertEqual(r.status_code, 200, r.data)
        alert = [m for m in Mail.sent if m["to"] == "old@example.com"]
        self.assertEqual(len(alert), 1)
        self.assertIn("/api/v1/account/not-me/", alert[0]["body"])
        self.assertEqual(alert[0]["purpose"], "security_alert")
        token = alert[0]["body"].split("/api/v1/account/not-me/")[1].split()[0]
        ch = IdentityChange.objects.get(user=self.u)
        self.assertEqual((ch.kind, ch.old_value, ch.new_value),
                         ("email", "old@example.com", "new@example.com"))
        # GET (a mail scanner / link preview) changes nothing
        g = APIClient().get("/api/v1/account/not-me/" + token)
        self.assertEqual(g.status_code, 200)
        self.assertContains(g, "<form method=\"post\">")
        self.assertEqual(EmailVerification.objects.get(user=self.u).email, "new@example.com")
        p = APIClient().post("/api/v1/account/not-me/" + token)
        self.assertEqual(p.status_code, 200)
        self.assertEqual(EmailVerification.objects.get(user=self.u).email, "old@example.com")
        self.u.refresh_from_db()
        self.assertEqual(self.u.email, "old@example.com")
        self.assertEqual(c.get("/api/v1/account/security").status_code, 401)
        self.assertEqual(c2.get("/api/v1/account/security").status_code, 401)
        st = AccountSecurityState.objects.get(user=self.u)
        self.assertGreater(st.identity_locked_until, timezone.now() + timedelta(days=6))
        # second tap: same "done" page, nothing else happens
        self.assertEqual(APIClient().post("/api/v1/account/not-me/" + token).status_code, 200)
        self.assertEqual(APIClient().get("/api/v1/account/not-me/bogus").status_code, 404)
        # locked: a new email change is refused before any code is sent
        c3, _ = self.login(dev_id="c")
        r = c3.post("/api/v1/auth/otp/email/request", {"email": "x@example.com",
                                                      "purpose": "email_verify"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "identity_locked"))

    def test_phone_and_email_cannot_both_change_within_24h(self):
        c, _ = self.login()
        self.verify_email(c, "old@example.com")
        self.verify_email(c, "new@example.com")            # email changed now
        r = c.post("/api/v1/circle/account/change-number/request",
                   {"new_phone": "01811000009"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "identity_cooldown"))
        AccountSecurityState.objects.filter(user=self.u).update(
            last_email_change_at=timezone.now() - timedelta(hours=25))
        r = c.post("/api/v1/circle/account/change-number/request",
                   {"new_phone": "01811000009"}, format="json")
        self.assertNotEqual(r.data.get("reason"), "identity_cooldown")
        # and the other way round
        AR.state(self.u)
        AccountSecurityState.objects.filter(user=self.u).update(
            last_phone_change_at=timezone.now() - timedelta(hours=2))
        r = c.post("/api/v1/auth/otp/email/request", {"email": "third@example.com",
                                                     "purpose": "email_verify"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "identity_cooldown"))

    def test_phone_change_alert_and_not_me_restores_number(self):
        EmailVerification.objects.create(user=self.u, email="rahim@example.com")
        old = self.u.phone
        User.objects.filter(pk=self.u.pk).update(phone="+8801811000009")
        self.u.refresh_from_db()
        with mock.patch("core.otp.sms_available", return_value=True), \
                mock.patch("core.sms_service.send_sms",
                           return_value={"ok": True, "reason": "ok", "provider": "x"}) as sms:
            ch, raw = AR.record_change(self.u, "phone", old, "+8801811000009")
        self.assertEqual(sms.call_args[0][0], old)
        self.assertIn("/api/v1/account/not-me/" + raw, sms.call_args[0][1])
        self.assertIn("sms", ch.alert_sent)
        self.assertIn("email", ch.alert_sent)
        self.assertEqual(APIClient().post("/api/v1/account/not-me/" + raw).status_code, 200)
        self.u.refresh_from_db()
        self.assertEqual(self.u.phone, old)


class NudgeTests(Base):
    def test_nudge_twice_then_never(self):
        c, _ = self.login()
        self.assertEqual(c.get("/api/v1/account/security").data["nudge"],
                         {"show": True, "stage": 0})
        r = c.post("/api/v1/account/security/nudge", {"action": "later"}, format="json")
        self.assertFalse(r.data["nudge"]["show"])
        AccountSecurityState.objects.filter(user=self.u).update(
            email_nudge_last_at=timezone.now() - timedelta(days=4))
        self.assertFalse(c.get("/api/v1/account/security").data["nudge"]["show"])
        AccountSecurityState.objects.filter(user=self.u).update(
            email_nudge_last_at=timezone.now() - timedelta(days=5, minutes=1))
        self.assertEqual(c.get("/api/v1/account/security").data["nudge"]["stage"], 1)
        c.post("/api/v1/account/security/nudge", {"action": "later"}, format="json")
        AccountSecurityState.objects.filter(user=self.u).update(
            email_nudge_last_at=timezone.now() - timedelta(days=60))
        self.assertFalse(c.get("/api/v1/account/security").data["nudge"]["show"])

    def test_no_nudge_with_email(self):
        c, _ = self.login()
        self.verify_email(c, "rahim@example.com")
        self.assertFalse(c.get("/api/v1/account/security").data["nudge"]["show"])


class ForgotPasswordTests(Base):
    def test_options_sms_only_without_verified_email(self):
        with mock.patch("core.otp.sms_available", return_value=True):
            r = self.client.post("/api/v1/auth/recovery/options", {"phone": "01711000001"},
                                 format="json")
        self.assertEqual((r.data["sms"], r.data["email"], r.data["email_masked"]),
                         (True, False, ""))

    def test_options_offer_masked_verified_email(self):
        EmailVerification.objects.create(user=self.u, email="rahim@example.com")
        r = self.client.post("/api/v1/auth/recovery/options", {"phone": "01711000001"},
                             format="json")
        self.assertTrue(r.data["email"])
        self.assertNotIn("rahim@", r.data["email_masked"])
        self.assertIn("@example.com", r.data["email_masked"])
        # unknown number: same shape, email False
        r = self.client.post("/api/v1/auth/recovery/options", {"phone": "01999999999"},
                             format="json")
        self.assertEqual((r.status_code, r.data["email"]), (200, False))
        r = self.client.post("/api/v1/auth/recovery/options", {"phone": "abc"}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_reset_by_chosen_email_channel(self):
        EmailVerification.objects.create(user=self.u, email="rahim@example.com")
        c, _ = self.login()
        r = self.client.post("/api/v1/auth/otp/email/request",
                             {"phone": "01711000001", "purpose": "password_reset"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(Mail.sent[-1]["to"], "rahim@example.com")
        r = self.client.post("/api/v1/auth/otp/verify",
                             {"phone": "01711000001", "purpose": "password_reset", "code": CODE},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        r = self.client.post("/api/v1/auth/otp/reset",
                             {"phone": "01711000001", "otp_proof": r.data["otp_proof"],
                              "password": "brandnew789"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(c.get("/api/v1/account/security").status_code, 401)

    def test_options_throttled(self):
        for _ in range(20):
            self.client.post("/api/v1/auth/recovery/options", {"phone": "01711000001"},
                             format="json")
        r = self.client.post("/api/v1/auth/recovery/options", {"phone": "01711000001"},
                             format="json")
        self.assertEqual(r.status_code, 429)


class SupportRecoveryTests(Base):
    def setUp(self):
        super().setUp()
        self.mom = User.objects.create_user(name="Amena Begum", phone="+8801911000002",
                                            password="x1234567")
        CircleMember.objects.create(user=self.u, peer_user=self.mom, name="Amma",
                                    relation="mother", phone="+8801911000002",
                                    state="accepted")
        CircleMember.objects.create(user=self.u, name="Karim Bhai", relation="friend",
                                    phone="+8801511000003", state="accepted")

    def start(self, **kw):
        body = {"account_phone": "01711000001", "contact_phone": "01611000004",
                "contact_otp_proof": make_proof("+8801611000004", "account_recovery"),
                "name": "rahim uddin", "signup_year": timezone.localtime().year,
                "signup_month": timezone.localtime().month,
                "circle_names": ["Amma", "Karim Bhai", "Nobody"],
                "old_password": PW, "family_phone": "01911000002"}
        body.update(kw)
        return self.client.post("/api/v1/auth/recovery/support/start", body, format="json")

    def test_needs_proven_new_number(self):
        r = self.start(contact_otp_proof="nope")
        self.assertEqual((r.status_code, r.data["reason"]), (403, "bad_otp"))
        r = self.start(contact_phone="01711000001")
        self.assertEqual(r.data["reason"], "same_phone")

    def test_full_flow_family_hold_review_complete(self):
        c_old, _ = self.login()
        r = self.start()
        self.assertEqual(r.status_code, 201, r.data)
        ref, secret = r.data["ref"], r.data["secret"]
        self.assertEqual(r.data["hold_hours"], 48)
        row = RecoveryRequest.objects.get(ref=ref)
        self.assertEqual(row.user, self.u)
        self.assertEqual(row.proof["name"], "exact")
        self.assertEqual(row.proof["password"], "yes")
        self.assertEqual(row.proof["circle"], "2/3")
        self.assertNotIn(PW, str(row.proof))                  # never the answers
        self.assertEqual(row.score, 90)     # name 25 + month 20 + 2 names 20 + password 25
        self.assertEqual((row.family_user, row.family_state), (self.mom, "pending"))
        self.assertGreaterEqual(row.hold_until, timezone.now() + timedelta(hours=47))
        # the account owner's signed-in phone sees it and could cancel
        d = c_old.get("/api/v1/account/security").data
        self.assertEqual(d["recovery_requests"][0]["id"], row.id)
        # family member confirms in their app
        cm = APIClient()
        cm.force_authenticate(self.mom)
        fr = cm.get("/api/v1/account/security").data["family_requests"]
        self.assertEqual(fr[0]["name"], "Rahim Uddin")
        self.assertEqual(cm.post("/api/v1/account/security/recovery/family/%d" % row.id,
                                 {"decision": "confirm"}, format="json").status_code, 200)
        st = self.client.post("/api/v1/auth/recovery/support/status",
                              {"ref": ref, "secret": secret}, format="json").data
        self.assertEqual((st["state"], st["family_state"]), ("pending", "confirmed"))
        self.assertEqual(self.client.post("/api/v1/auth/recovery/support/status",
                                          {"ref": ref, "secret": "x"}, format="json")
                         .status_code, 404)
        # admin approves — still NOT instant: the hold is running
        row.refresh_from_db()
        self.assertEqual(AR.admin_decide(row, "approve", self.mom), "")
        st = self.client.post("/api/v1/auth/recovery/support/status",
                              {"ref": ref, "secret": secret}, format="json").data
        self.assertEqual(st["state"], "approved_waiting")
        body = {"ref": ref, "secret": secret, "password": "fresh12345",
                "otp_proof": make_proof("+8801611000004", "account_recovery")}
        r = self.client.post("/api/v1/auth/recovery/support/complete", body, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "not_ready"))
        RecoveryRequest.objects.filter(pk=row.pk).update(
            hold_until=timezone.now() - timedelta(minutes=1))
        self.assertEqual(self.client.post("/api/v1/auth/recovery/support/status",
                                          {"ref": ref, "secret": secret}, format="json")
                         .data["state"], "ready")
        body["otp_proof"] = "bad"
        r = self.client.post("/api/v1/auth/recovery/support/complete", body, format="json")
        self.assertEqual(r.data["reason"], "bad_otp")
        body["otp_proof"] = make_proof("+8801611000004", "account_recovery")
        r = self.client.post("/api/v1/auth/recovery/support/complete", body, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.u.refresh_from_db()
        self.assertTrue(self.u.check_password("fresh12345"))
        self.assertEqual(self.u.phone, "+8801611000004")
        self.assertEqual(c_old.get("/api/v1/account/security").status_code, 401)
        c_new = APIClient()
        c_new.credentials(HTTP_AUTHORIZATION="Token " + r.data["token"])
        self.assertEqual(c_new.get("/api/v1/account/security").status_code, 200)
        self.assertEqual(IdentityChange.objects.filter(user=self.u, kind="phone").count(), 1)
        r = self.client.post("/api/v1/auth/recovery/support/complete", body, format="json")
        self.assertEqual(r.status_code, 409)               # single use

    def test_family_no_blocks_approval(self):
        r = self.start()
        row = RecoveryRequest.objects.get(ref=r.data["ref"])
        cm = APIClient()
        cm.force_authenticate(self.mom)
        cm.post("/api/v1/account/security/recovery/family/%d" % row.id,
                {"decision": "deny"}, format="json")
        row.refresh_from_db()
        self.assertEqual(AR.admin_decide(row, "approve", self.mom), "family_denied")

    def test_stranger_cannot_confirm(self):
        r = self.start()
        row = RecoveryRequest.objects.get(ref=r.data["ref"])
        other = User.objects.create_user(name="X", phone="+8801311000005", password="x1234567")
        c = APIClient()
        c.force_authenticate(other)
        self.assertEqual(c.post("/api/v1/account/security/recovery/family/%d" % row.id,
                                {"decision": "confirm"}, format="json").status_code, 404)

    def test_owner_cancels_from_signed_in_phone(self):
        c, _ = self.login()
        r = self.start()
        row = RecoveryRequest.objects.get(ref=r.data["ref"])
        self.assertEqual(c.post("/api/v1/account/security/recovery/%d/cancel" % row.id)
                         .status_code, 200)
        row.refresh_from_db()
        self.assertEqual(row.state, "cancelled")
        self.assertEqual(AR.admin_decide(row, "approve", self.mom), "invalid")

    def test_unknown_number_same_answer_nothing_to_review(self):
        r = self.start(account_phone="01999000111")
        self.assertEqual(r.status_code, 201)
        row = RecoveryRequest.objects.get(ref=r.data["ref"])
        self.assertIsNone(row.user)
        st = self.client.post("/api/v1/auth/recovery/support/status",
                              {"ref": r.data["ref"], "secret": r.data["secret"]},
                              format="json").data
        self.assertEqual(st["state"], "pending")

    def test_account_with_email_is_sent_to_email_reset(self):
        EmailVerification.objects.create(user=self.u, email="rahim@example.com")
        r = self.start()
        self.assertEqual((r.status_code, r.data["reason"]), (409, "use_email"))

    def test_one_open_request_and_ip_limit(self):
        self.assertEqual(self.start().status_code, 201)
        self.assertEqual(self.start().data["reason"], "already_open")
        self.assertEqual(self.start(account_phone="01999000111").status_code, 201)
        self.assertEqual(self.start(account_phone="01999000112").status_code, 201)
        r = self.start(account_phone="01999000113")
        self.assertEqual((r.status_code, r.data["reason"]), (429, "rate_limited"))

    def test_weak_proof_scores_low(self):
        r = self.start(name="someone else", circle_names=[], old_password="", signup_year="")
        row = RecoveryRequest.objects.get(ref=r.data["ref"])
        self.assertEqual(row.score, 0)
        self.assertEqual(row.proof["password"], "skipped")
