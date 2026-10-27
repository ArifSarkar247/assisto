"""invite-join — short invite codes + passwordless join (core/invite_join.py)."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import invite_join as IJ
from core.models import CircleInvite, CircleInviteJoin, CircleMember, User

API = "/api/v1"


def _auth(user, lang="en"):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.get_or_create(user=user)[0].key,
                  HTTP_ACCEPT_LANGUAGE=lang)
    return c


def _anon(lang="en", ip="10.0.0.9"):
    c = APIClient(REMOTE_ADDR=ip)
    c.credentials(HTTP_ACCEPT_LANGUAGE=lang)
    return c


SMS_OFF = mock.patch("core.otp.sms_available", return_value=False)
SMS_ON = mock.patch("core.otp.sms_available", return_value=True)


@override_settings(ASSISTO_BASE_URL="https://lifeassisto.com")
class InviteJoinBase(TestCase):
    def setUp(self):
        cache.clear()
        self.a = User.objects.create_user(name="Rahim Uddin", phone="01711000401", password="x1y2z3w4")
        self.ca = _auth(self.a)

    def make(self, **kw):
        r = self.ca.post(API + "/circle/invite/code", kw, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()


class Codes(InviteJoinBase):
    def test_code_shape_no_user_id_and_share_text(self):
        d = self.make(relation="brother")
        code = d["code"]
        self.assertEqual(len(code), IJ.CODE_LEN)
        self.assertTrue(all(c in IJ.CODE_ALPHABET for c in code))
        self.assertNotIn(str(self.a.id) + ".", code)
        self.assertEqual(d["link"], "https://lifeassisto.com/i/" + code)
        self.assertIn(d["link"], d["share_text"])
        self.assertIn("ci%3D" + code, d["play_link"])
        self.assertIn("Rahim", d["share_text"])
        self.assertNotIn("01711000401", d["share_text"])
        bn = _auth(self.a, "bn").post(API + "/circle/invite/code", {}, format="json").json()
        self.assertIn("আমার সার্কেল", bn["share_text"])

    def test_normalize(self):
        c = self.make()["code"]
        for raw in (c, c.lower(), "https://lifeassisto.com/i/%s" % c, "/i/%s?x=1" % c, " %s/ " % c):
            self.assertEqual(IJ.normalize_code(raw), c)
        for raw in ("", "ABC", c + "X", "O0I1O0I1O0", "12.ab.cd"):
            self.assertEqual(IJ.normalize_code(raw), "")

    def test_create_rate_limit(self):
        with mock.patch.object(IJ, "CREATE_PER_DAY", 3):
            for _ in range(3):
                self.make()
            r = self.ca.post(API + "/circle/invite/code", {}, format="json")
            self.assertEqual(r.status_code, 429)

    def test_max_uses_capped(self):
        d = self.make(max_uses=999)
        self.assertEqual(d["max_uses"], IJ.MAX_USES_CAP)


class Preview(InviteJoinBase):
    def test_preview_ok_never_leaks_phone_or_id(self):
        code = self.make()["code"]
        r = _anon().post(API + "/invite/preview", {"code": code}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertTrue(j["ok"])
        self.assertEqual(j["inviter_name"], "Rahim")
        body = r.content.decode()
        self.assertNotIn("01711000401", body)
        self.assertNotIn('"id"', body)

    def test_unknown_revoked_malformed_same_answer(self):
        d = self.make()
        self.ca.post(API + "/circle/invite/%d/revoke" % d["id"])
        shapes = set()
        for code in (d["code"], "ABCDEFGHJK", "bad"):
            r = _anon().post(API + "/invite/preview", {"code": code}, format="json")
            self.assertEqual(r.status_code, 404)
            shapes.add((r.json()["reason"], r.json()["detail"]))
        self.assertEqual(len(shapes), 1)

    def test_enumeration_lock(self):
        c = _anon(ip="10.9.9.9")
        with mock.patch.object(IJ, "BAD_PER_10MIN", 3):
            for _ in range(3):
                self.assertEqual(c.post(API + "/invite/preview", {"code": "ZZZZZZZZZZ"},
                                        format="json").status_code, 404)
            # even a REAL code is refused now from this IP
            code = self.make()["code"]
            r = c.post(API + "/invite/preview", {"code": code}, format="json")
            self.assertEqual(r.status_code, 429)
            # another IP is fine
            self.assertEqual(_anon(ip="10.1.1.1").post(
                API + "/invite/preview", {"code": code}, format="json").status_code, 200)

    def test_expired_and_used_states(self):
        d = self.make()
        CircleInvite.objects.filter(pk=d["id"]).update(expires_at=timezone.now() - timedelta(minutes=1))
        j = _anon().post(API + "/invite/preview", {"code": d["code"]}, format="json").json()
        self.assertEqual((j["ok"], j["state"]), (False, "expired"))
        d2 = self.make()
        CircleInvite.objects.filter(pk=d2["id"]).update(use_count=1)
        j = _anon().post(API + "/invite/preview", {"code": d2["code"]}, format="json").json()
        self.assertEqual(j["state"], "used")

    def test_preview_self_and_already(self):
        code = self.make()["code"]
        j = self.ca.post(API + "/invite/preview", {"code": code}, format="json").json()
        self.assertEqual(j["state"], "self")
        b = User.objects.create_user(name="B", phone="01711000402", password="x1y2z3w4")
        _auth(b).post(API + "/invite/join", {"code": code}, format="json")
        code2 = self.make()["code"]
        j = _auth(b).post(API + "/invite/preview", {"code": code2}, format="json").json()
        self.assertEqual((j["ok"], j["state"]), (True, "already"))


class Join(InviteJoinBase):
    def setUp(self):
        super().setUp()
        self.b = User.objects.create_user(name="Karim", phone="01711000403", password="x1y2z3w4")
        self.cb = _auth(self.b)

    def test_join_connects_both_and_burns_use(self):
        d = self.make(relation="brother", label="Karim bhai")
        r = self.cb.post(API + "/invite/join", {"code": d["code"], "via": "link"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["member"]["state"], "accepted")
        self.assertFalse(r.json()["already"])
        self.assertTrue(CircleMember.objects.filter(user=self.a, peer_user=self.b, state="accepted").exists())
        self.assertTrue(CircleMember.objects.filter(user=self.b, peer_user=self.a, state="accepted").exists())
        inv = CircleInvite.objects.get(pk=d["id"])
        self.assertEqual((inv.use_count, inv.used), (1, True))
        self.assertTrue(CircleInviteJoin.objects.filter(invite=inv, user=self.b, via="link").exists())
        # again: already a member -> ok, no use burnt
        r = self.cb.post(API + "/invite/join", {"code": d["code"]}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["already"])
        # a third person: used
        c = User.objects.create_user(name="C", phone="01711000404", password="x1y2z3w4")
        r = _auth(c).post(API + "/invite/join", {"code": d["code"]}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "used"))

    def test_multi_use(self):
        d = self.make(max_uses=2)
        for i, ph in enumerate(("01711000405", "01711000406")):
            u = User.objects.create_user(name="U%d" % i, phone=ph, password="x1y2z3w4")
            self.assertEqual(_auth(u).post(API + "/invite/join", {"code": d["code"]},
                                           format="json").status_code, 200)
        u = User.objects.create_user(name="U3", phone="01711000407", password="x1y2z3w4")
        self.assertEqual(_auth(u).post(API + "/invite/join", {"code": d["code"]},
                                       format="json").json()["reason"], "used")

    def test_expired_self_blocked_full(self):
        d = self.make()
        self.assertEqual(self.ca.post(API + "/invite/join", {"code": d["code"]},
                                      format="json").json()["reason"], "self")
        CircleInvite.objects.filter(pk=d["id"]).update(expires_at=timezone.now() - timedelta(seconds=1))
        r = self.cb.post(API + "/invite/join", {"code": d["code"]}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (410, "expired"))
        d = self.make()
        CircleMember.objects.create(user=self.a, peer_user=self.b, direction="outgoing",
                                    state="blocked", relation="friend")
        r = self.cb.post(API + "/invite/join", {"code": d["code"]}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "blocked"))
        CircleMember.objects.all().delete()
        d = self.make()
        with mock.patch.object(IJ, "circle_cap", return_value=0):
            r = self.cb.post(API + "/invite/join", {"code": d["code"]}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "circle_full"))
        self.assertEqual(CircleInvite.objects.get(pk=d["id"]).use_count, 0)

    def test_resend_extends_and_revoke(self):
        d = self.make()
        CircleInvite.objects.filter(pk=d["id"]).update(expires_at=timezone.now() - timedelta(days=1))
        r = self.ca.post(API + "/circle/invite/%d/resend" % d["id"])
        self.assertEqual(r.status_code, 200)
        self.assertGreater(CircleInvite.objects.get(pk=d["id"]).expires_at, timezone.now())
        # someone else can't touch my invite
        self.assertEqual(self.cb.post(API + "/circle/invite/%d/revoke" % d["id"]).status_code, 404)
        self.ca.post(API + "/circle/invite/%d/revoke" % d["id"])
        r = self.cb.post(API + "/invite/join", {"code": d["code"]}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_sent_list_statuses(self):
        d1 = self.make(label="Ammu")
        d2 = self.make(label="Abbu")
        self.cb.post(API + "/invite/join", {"code": d2["code"]}, format="json")
        d3 = self.make()
        CircleInvite.objects.filter(pk=d3["id"]).update(expires_at=timezone.now() - timedelta(days=1))
        rows = {x["id"]: x for x in self.ca.get(API + "/circle/invite/sent").json()["results"]}
        self.assertEqual(rows[d1["id"]]["status"], "waiting")
        self.assertEqual(rows[d1["id"]]["label"], "Ammu")
        self.assertEqual(rows[d2["id"]]["status"], "joined")
        self.assertEqual(rows[d2["id"]]["joined"][0]["name"], "Karim")
        self.assertEqual(rows[d3["id"]]["status"], "expired")
        # never another user's invites
        self.assertEqual(self.cb.get(API + "/circle/invite/sent").json()["results"], [])

    def test_join_rate_limit(self):
        with mock.patch.object(IJ, "JOIN_PER_HOUR", 2):
            d = self.make(max_uses=5)
            for _ in range(2):
                self.cb.post(API + "/invite/join", {"code": d["code"]}, format="json")
            r = self.cb.post(API + "/invite/join", {"code": d["code"]}, format="json")
            self.assertEqual(r.status_code, 429)

    def test_legacy_paste_path_accepts_code(self):
        d = self.make()
        r = self.cb.post(API + "/circle/invite/redeem", {"link": d["link"]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["member"]["state"], "accepted")
        self.assertEqual(CircleInviteJoin.objects.get(user=self.b).via, "paste")

    def test_two_racers_last_use_one_wins(self):
        d = self.make()
        inv = CircleInvite.objects.get(pk=d["id"])
        c = User.objects.create_user(name="C", phone="01711000408", password="x1y2z3w4")
        IJ.join(inv, self.b)
        with self.assertRaises(IJ.JoinError) as e:
            IJ.join(inv, c)      # stale in-memory row still says use_count 0
        self.assertEqual(e.exception.reason, "used")


class Signup(InviteJoinBase):
    def _signup(self, code, ip="10.0.0.50", **body):
        body.setdefault("name", "Nasima Akter")
        body["code"] = code
        return _anon(ip=ip).post(API + "/invite/signup", body, format="json",
                                 HTTP_X_DEVICE_ID="dev-%s" % ip)

    def test_sms_off_passwordless_signup_joins(self):
        code = self.make(relation="sister")["code"]
        with SMS_OFF:
            r = self._signup(code, phone="০১৭১১-০০০৪১০")
        self.assertEqual(r.status_code, 201, r.content)
        j = r.json()
        self.assertTrue(j["token"])
        self.assertFalse(j["has_password"])
        self.assertEqual(j["member"]["state"], "accepted")
        self.assertEqual(j["inviter"]["name"], "Rahim")
        u = User.objects.get(phone="+8801711000410")
        self.assertFalse(u.has_usable_password())
        self.assertTrue(CircleMember.objects.filter(user=self.a, peer_user=u, state="accepted").exists())
        self.assertTrue(CircleInviteJoin.objects.get(user=u).new_account)
        # the token works
        c = APIClient()
        c.credentials(HTTP_AUTHORIZATION="Token " + j["token"])
        self.assertEqual(c.get(API + "/auth/password-state").json(), {"has_password": False})
        # set a password once, then sign in with it
        self.assertEqual(c.post(API + "/auth/set-password", {"password": "Shapla-2026!"},
                                format="json").status_code, 200)
        self.assertEqual(c.post(API + "/auth/set-password", {"password": "Other-2026!"},
                                format="json").status_code, 409)
        r = APIClient().post(API + "/auth/login", {"identifier": "01711000410",
                                                   "password": "Shapla-2026!"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)

    def test_signup_attributes_referral_under_existing_rules(self):
        from core.models import ReferralClaim
        code = self.make()["code"]
        with SMS_OFF:
            r = self._signup(code, phone="01711000411")
        self.assertEqual(r.status_code, 201, r.content)
        u = User.objects.get(phone="+8801711000411")
        claim = ReferralClaim.objects.filter(invitee=u).first()
        self.assertIsNotNone(claim)
        self.assertEqual(claim.inviter_id, self.a.id)
        # nothing is granted at signup (only after activation)
        self.assertNotEqual(claim.state, "rewarded")

    def test_sms_on_requires_otp_proof(self):
        code = self.make()["code"]
        with SMS_ON:
            r = self._signup(code, phone="01711000412")
            self.assertEqual((r.status_code, r.json()["reason"]), (403, "need_otp"))
            with mock.patch("core.otp.consume_proof", return_value=None):
                r = self._signup(code, phone="01711000412", otp_proof="nope", ip="10.0.0.51")
            self.assertEqual(r.json()["reason"], "bad_otp")
            with mock.patch("core.otp.consume_proof", return_value="+8801711000412"):
                r = self._signup(code, phone="01711000412", otp_proof="good", ip="10.0.0.52")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertTrue(r.json()["phone_verified"])
        self.assertEqual(CircleInvite.objects.get(code=code).use_count, 1)

    def test_sms_failure_email_fallback(self):
        code = self.make()["code"]
        with SMS_ON:
            r = self._signup(code, email="fallback@example.com")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertFalse(r.json()["phone_verified"])
        code = self.make()["code"]
        with SMS_ON, mock.patch("core.otp.password_only_signup_allowed", return_value=False):
            r = self._signup(code, email="closed@example.com", ip="10.0.0.70")
        self.assertEqual(r.json()["reason"], "signup_closed")

    def test_signup_errors(self):
        code = self.make()["code"]
        with SMS_OFF:
            self.assertEqual(self._signup(code, name="", phone="01711000413").json()["reason"], "need_name")
            self.assertEqual(self._signup(code, phone="12345", ip="10.0.0.61").json()["reason"], "bad_phone")
            self.assertEqual(self._signup(code, ip="10.0.0.62").json()["reason"], "need_phone")
            r = self._signup(code, phone="01711000401", ip="10.0.0.63")   # the inviter's number
            self.assertEqual((r.status_code, r.json()["reason"]), (409, "has_account"))
            with mock.patch("core.otp.password_only_signup_allowed", return_value=False):
                r = self._signup(code, phone="01711000414", ip="10.0.0.64")
            self.assertEqual(r.json()["reason"], "signup_closed")
        # no account was created by any failure, and the use was not burnt
        self.assertFalse(User.objects.filter(phone="+8801711000413").exists())
        self.assertEqual(CircleInvite.objects.get(code=code).use_count, 0)

    def test_signup_email_only(self):
        code = self.make()["code"]
        with SMS_OFF:
            r = self._signup(code, email="Nasima@Example.com")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertTrue(User.objects.filter(email="nasima@example.com").exists())

    def test_signup_expired_invite_creates_nothing(self):
        d = self.make()
        CircleInvite.objects.filter(pk=d["id"]).update(expires_at=timezone.now() - timedelta(minutes=1))
        with SMS_OFF:
            r = self._signup(d["code"], phone="01711000415")
        self.assertEqual((r.status_code, r.json()["reason"]), (410, "expired"))
        self.assertFalse(User.objects.filter(phone="+8801711000415").exists())

    def test_signup_circle_full_rolls_back(self):
        code = self.make()["code"]
        with SMS_OFF, mock.patch.object(IJ, "circle_cap", return_value=0):
            r = self._signup(code, phone="01711000416")
        self.assertEqual(r.json()["reason"], "circle_full")
        self.assertFalse(User.objects.filter(phone="+8801711000416").exists())

    def test_signup_rate_limit_per_ip(self):
        code = self.make(max_uses=10)["code"]
        with SMS_OFF, mock.patch.object(IJ, "SIGNUP_PER_HOUR", 2):
            for i in range(2):
                self.assertEqual(self._signup(code, ip="10.7.7.7", phone="0171100042%d" % i).status_code, 201)
            r = self._signup(code, ip="10.7.7.7", phone="01711000429")
        self.assertEqual(r.status_code, 429)

    def test_bangla_messages(self):
        code = self.make()["code"]
        with SMS_OFF:
            r = _anon(lang="bn").post(API + "/invite/signup", {"code": code, "phone": "01711000417"},
                                      format="json")
        self.assertEqual(r.json()["reason"], "need_name")
        self.assertIn("নাম", r.json()["detail"])

    def test_existing_password_login_unchanged(self):
        r = APIClient().post(API + "/auth/login", {"identifier": "01711000401",
                                                   "password": "x1y2z3w4"}, format="json")
        self.assertEqual(r.status_code, 200)


@override_settings(ASSISTO_BASE_URL="https://lifeassisto.com")
class Landing(InviteJoinBase):
    def test_landing_ok_expired_and_referral_untouched(self):
        d = self.make()
        r = self.client.get("/i/%s" % d["code"])
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        self.assertIn("Rahim", html)
        self.assertNotIn("Uddin", html)          # first name only
        self.assertNotIn("01711000401", html)
        self.assertIn("ci%3D" + d["code"], html)
        self.assertIn("intent://", html)
        self.assertEqual(r["X-Robots-Tag"], "noindex")
        r = self.client.get("/i/%s?lang=en" % d["code"])
        self.assertIn("invited you", r.content.decode())
        CircleInvite.objects.filter(pk=d["id"]).update(expires_at=timezone.now() - timedelta(minutes=1))
        r = self.client.get("/i/%s" % d["code"])
        self.assertEqual(r.status_code, 410)
        # p5 referral codes still land on the referral page
        from core import growth
        ref = growth.ensure_code(self.a)
        self.assertEqual(self.client.get("/i/%s" % ref).status_code, 200)
