"""probashi-otp — login / sign-up / OTP / contacts for phone numbers abroad.

The Probashi plan's payers live in the 13 main expat countries. These tests
pin what works for them TODAY (no international SMS gateway exists):

  * every country's number is parsed into ONE canonical E.164 form, with
    +, 00, spaces, dashes and a stray trunk 0 after the country code;
  * sign-up + password login with a foreign number (and with email only);
  * one account per number, whatever spelling is typed later;
  * SMS OTP never goes abroad: an honest "SMS only reaches BD numbers — use
    email or password" reason, no SMS sent, no cost, no SMS-pumping surface;
  * contacts matching across countries (a family member in Bangladesh who
    saved the expat as +966… or 00966… finds them).

No network, no real SMS: the gateway HTTP seam is mocked and asserted unused.
Numbers are fictional (555 / 900123 style).
"""
import json
from unittest import mock

from django.test import TestCase
from rest_framework.test import APIClient, APITestCase

from core import otp, phone as P, sms_gateway
from core.models import AdminFlagState, Integration, OtpChallenge, User

# country -> (as an expat types it, canonical E.164)
COUNTRIES = {
    "SA": ("+966 50 123 4567", "+966501234567"),
    "AE": ("+971 50 123 4567", "+971501234567"),
    "QA": ("+974 3312 3456", "+97433123456"),
    "OM": ("+968 9212 3456", "+96892123456"),
    "KW": ("+965 5012 3456", "+96550123456"),
    "BH": ("+973 3612 3456", "+97336123456"),
    "MY": ("+60 12-345 6789", "+60123456789"),
    "SG": ("+65 8123 4567", "+6581234567"),
    "IT": ("+39 312 345 6789", "+393123456789"),
    "GB": ("+44 7700 900123", "+447700900123"),
    "US": ("+1 202 555 0143", "+12025550143"),
    "CA": ("+1 416 555 0143", "+14165550143"),
    "AU": ("+61 412 345 678", "+61412345678"),
}

# the same number typed the other ways people really type it
ALT_SPELLINGS = {
    "SA": ["00966501234567", "+966-50-123-4567", "+966 050 123 4567", "+৯৬৬৫০১২৩৪৫৬৭"],
    "AE": ["00971501234567", "+971 (0)50 123 4567"],
    "MY": ["+60 012-345 6789", "0060123456789"],
    "GB": ["0044 7700 900123", "+44 07700 900123", "+44 (0)7700 900123"],
    "AU": ["+61 0412 345 678", "0061412345678"],
    "US": ["001 202 555 0143", "+1 (202) 555-0143"],
    "QA": ["00974 3312 3456"],
    "IT": ["0039 312 345 6789"],
}


def enable_sms():
    from core import integrations
    integrations.save("sms", {"provider": "bulksmsbd", "api_key": "test-key-xyz",
                              "sender_id": "8809617000000"})
    Integration.objects.filter(slug="sms").update(status="working")


def set_flag(fid, value):
    from core.logic import admin_flags as AF
    st = AF.normalize_state({})
    st[fid] = value
    AdminFlagState.objects.update_or_create(key="global", defaults={"state": st})


class ForeignParsingTests(TestCase):
    def test_every_country_canonical(self):
        for cc, (raw, want) in COUNTRIES.items():
            self.assertEqual(P.canonical_phone(raw), want, cc)

    def test_alternate_spellings_same_number(self):
        for cc, raws in ALT_SPELLINGS.items():
            want = COUNTRIES[cc][1]
            for raw in raws:
                self.assertEqual(P.canonical_phone(raw), want, "%s %r" % (cc, raw))

    def test_italy_keeps_landline_zero(self):
        # Italian landlines keep the 0 inside E.164 — never stripped
        self.assertEqual(P.canonical_phone("+39 06 1234 5678"), "+390612345678")

    def test_never_mangled_into_bangladesh(self):
        for cc, (raw, want) in COUNTRIES.items():
            self.assertFalse(P.canonical_phone(raw).startswith("+880"), cc)
            self.assertIsNone(P.canonical_bd(raw), cc)
            self.assertIsNone(otp.normalize_bd_phone(raw), cc)

    def test_local_foreign_format_is_rejected_not_guessed(self):
        # without + / 00 a foreign local number can't be told from a BD one
        for raw in ("0501234567", "966501234567", "07700900123", "2025550143"):
            self.assertIsNone(P.canonical_phone(raw), raw)

    def test_us_and_canada_both_plus1(self):
        us = P.canonical_phone(COUNTRIES["US"][0])
        ca = P.canonical_phone(COUNTRIES["CA"][0])
        self.assertTrue(us.startswith("+1") and ca.startswith("+1"))
        self.assertNotEqual(us, ca)
        self.assertEqual(len(us), 12)
        self.assertEqual(P.local_form(us), us)      # shown as typed, not 0-form
        self.assertEqual(P.mask(us)[:3], "+12")

    def test_bd_still_works(self):
        self.assertEqual(P.canonical_phone("01712345678"), "+8801712345678")
        self.assertEqual(P.canonical_phone("+880 01712345678"), "+8801712345678")


class ForeignSignupLoginTests(APITestCase):
    def setUp(self):
        self.c = APIClient()

    def _register(self, **body):
        body.setdefault("password", "Str0ng-pass-99")
        return self.c.post("/api/v1/auth/register", body, format="json")

    def test_signup_and_password_login_every_country(self):
        for i, (cc, (raw, want)) in enumerate(COUNTRIES.items()):
            r = self._register(name="Expat %s" % cc, phone=raw)
            self.assertEqual(r.status_code, 201, (cc, r.content))
            u = User.objects.get(pk=r.json()["user"]["id"])
            self.assertEqual(u.phone, want, cc)
            # sign in with ANY spelling of the same number
            for ident in [raw, want] + ALT_SPELLINGS.get(cc, []):
                r2 = self.c.post("/api/v1/auth/login",
                                 {"identifier": ident, "password": "Str0ng-pass-99"},
                                 format="json")
                self.assertEqual(r2.status_code, 200, (cc, ident, r2.content))
                self.assertEqual(r2.json()["user"]["id"], u.pk)

    def test_one_account_per_number_any_spelling(self):
        self.assertEqual(self._register(phone="+966 50 123 4567").status_code, 201)
        for again in ("00966501234567", "+966 050 123 4567", "+966501234567"):
            r = self._register(phone=again)
            self.assertEqual(r.status_code, 400, again)
        self.assertEqual(User.objects.filter(phone="+966501234567").count(), 1)

    def test_email_only_signup_and_login(self):
        r = self._register(name="Expat mail", email="Expat.Rahim@Example.com")
        self.assertEqual(r.status_code, 201, r.content)
        r2 = self.c.post("/api/v1/auth/login",
                         {"identifier": "expat.rahim@example.com",
                          "password": "Str0ng-pass-99"}, format="json")
        self.assertEqual(r2.status_code, 200)

    def test_gate_closed_foreign_number_needs_a_bd_sms_proof(self):
        """OWNER DECISION (documented, not changed here): with the launch gate
        auth_password_only_signup OFF, sign-up needs an SMS proof, and SMS
        reaches BD numbers only — so an expat with no BD number cannot sign
        up. The answer is honest (403 phone_verification_required), never a
        crash and never a fake account."""
        set_flag("auth_password_only_signup", False)
        r = self._register(phone=COUNTRIES["SA"][0])
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "phone_verification_required")
        self.assertFalse(User.objects.filter(phone="+966501234567").exists())

    def test_profile_phone_change_to_foreign_number(self):
        r = self._register(name="BD then abroad", phone="01712345600")
        tok = r.json()["token"]
        self.c.credentials(HTTP_AUTHORIZATION="Token " + tok)
        r2 = self.c.patch("/api/v1/me", {"phone": "+44 07700 900123"}, format="json")
        self.assertEqual(r2.status_code, 200, r2.content)
        u = User.objects.get(pk=r.json()["user"]["id"])
        self.assertEqual(u.phone, "+447700900123")


class ForeignOtpTests(APITestCase):
    """SMS OTP never goes abroad: honest reason, nothing sent, nothing stored."""

    def setUp(self):
        self.c = APIClient()

    def test_sms_off_everyone_gets_the_honest_503(self):
        r = self.c.post("/api/v1/auth/otp/request",
                        {"phone": COUNTRIES["AE"][0], "purpose": "login"}, format="json")
        self.assertEqual(r.status_code, 503)
        self.assertEqual(r.json()["reason"], "sms_not_configured")

    def test_sms_on_foreign_number_is_refused_honestly_without_sending(self):
        enable_sms()
        with mock.patch.object(sms_gateway, "_http") as http:
            for cc, (raw, _want) in COUNTRIES.items():
                for purpose in ("login", "signup", "password_reset"):
                    r = self.c.post("/api/v1/auth/otp/request",
                                    {"phone": raw, "purpose": purpose}, format="json")
                    self.assertEqual(r.status_code, 400, (cc, purpose, r.content))
                    body = r.json()
                    self.assertEqual(body["reason"], "intl_sms_unavailable", cc)
                    self.assertTrue(body["use_email"])
                    self.assertIn("ইমেইল", self.c.post(
                        "/api/v1/auth/otp/request",
                        {"phone": raw, "purpose": purpose, "lang": "bn"},
                        format="json", HTTP_ACCEPT_LANGUAGE="bn").json()["message"])
            http.assert_not_called()
        self.assertEqual(OtpChallenge.objects.count(), 0)

    def test_sms_on_bd_number_still_gets_a_code(self):
        enable_sms()
        ok = (200, json.dumps({"response_code": 202,
                               "success_message": "SMS Submitted Successfully"}))
        with mock.patch.object(sms_gateway, "_http", return_value=ok) as http:
            r = self.c.post("/api/v1/auth/otp/request",
                            {"phone": "01712345678", "purpose": "signup"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(http.call_count, 1)

    def test_garbage_is_still_bad_phone(self):
        enable_sms()
        r = self.c.post("/api/v1/auth/otp/request",
                        {"phone": "12345", "purpose": "login"}, format="json")
        self.assertEqual(r.json()["reason"], "bad_phone")

    def test_foreign_account_sensitive_actions_degrade_to_password(self):
        enable_sms()
        u = User.objects.create_user(name="x", phone="+966501234567", password="Str0ng-pass-99")
        # no BD mobile -> delete-account / Section 8 don't demand an SMS proof
        self.assertFalse(otp.otp_required_for(u))


class ForeignContactMatchTests(TestCase):
    def test_bd_family_finds_expat_in_any_international_spelling(self):
        for cc, (raw, want) in COUNTRIES.items():
            h = P.hash_canonical(want)
            for typed in [raw, want] + ALT_SPELLINGS.get(cc, []):
                self.assertEqual(P.hash_raw(typed), h, (cc, typed))

    def test_registered_expat_is_matchable(self):
        u = User.objects.create_user(name="Expat", phone="+44 07700 900123",
                                     password="Str0ng-pass-99")
        self.assertEqual(u.phone, "+447700900123")
        self.assertEqual(P.sync_phone_hash(u), P.hash_raw("0044 7700 900123"))
        self.assertEqual(P.find_user("+44 (0)7700 900123"), u)

    def test_local_format_does_not_falsely_match(self):
        # "0501234567" saved without +966 must never hit a BD account or the expat
        self.assertEqual(P.hash_raw("0501234567"), "")
