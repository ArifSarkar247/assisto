"""aifinal PART 4: credits, no loss — every AI caller pays or is on the
documented free list; 20 welcome credits ONCE per verified phone + device;
free + ad credits pay only for Normal; rewarded ads only for adults; per-user
daily limits. Fake providers only."""
import pathlib
import re
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from core import ai_levels_service as ALS
from core import billing
from core import credits as CR
from core.logic import ai_levels as AL
from core.models import AIUsage, OtpChallenge

ROOT = pathlib.Path(__file__).resolve().parent.parent
CALL = re.compile(r"\b(?:ai|AI|_ai|A)\.generate\(")


def _user(phone, verified=True):
    u = get_user_model().objects.create_user(name="c", phone=phone, password="pw12345!")
    if verified:
        from core.phone import canonical_phone
        OtpChallenge.objects.create(phone=canonical_phone(phone), purpose="login",
                                    code_hash="x", salt="y", expires_at=timezone.now(),
                                    consumed_at=timezone.now())
    return u


def _on(**extra):
    lv = dict(AL.defaults(), enabled=True, welcome_on=True)
    lv.update(extra)
    return mock.patch.object(ALS, "cfg", side_effect=lambda c=None: (AL.normalize(lv),
                                                                     billing.cfg()))


class EveryCallerPaysTests(TestCase):
    def test_every_generate_caller_has_a_payer_or_is_exempt(self):
        bad = []
        for path in list(ROOT.glob("core/**/*.py")) + list(ROOT.glob("crm/**/*.py")) + \
                list(ROOT.glob("web/**/*.py")) + list(ROOT.glob("tracker/**/*.py")):
            if "tests" in path.name or "migrations" in path.parts:
                continue
            src = path.read_text(encoding="utf-8")
            for m in CALL.finditer(src):
                depth, j = 0, m.end() - 1
                while j < len(src):
                    depth += {"(": 1, ")": -1}.get(src[j], 0)
                    if depth == 0:
                        break
                    j += 1
                call = src[m.start():j + 1]
                if "feature=" not in call:
                    continue        # prose in a docstring/comment (every real call names its feature)
                um = re.search(r"\buser=([^,)\n]+)", call)
                fm = re.search(r"\bfeature=(\"[^\"]*\"|f\"[^\"]*\"|[^,)\n]+)", call)
                payer = um and um.group(1).strip() != "None"
                feat = (fm.group(1).strip().strip('f"') if fm else "")
                if not payer and not ALS.exempt(feat) and not feat.startswith("tag"):
                    bad.append("%s: %s" % (path.relative_to(ROOT), call[:90]))
        self.assertEqual(bad, [], "AI call without a payer and not on FREE_EXEMPT")

    def test_free_list_is_documented(self):
        for k, why in ALS.FREE_EXEMPT.items():
            self.assertTrue(len(why) > 10, k)
        self.assertTrue(ALS.exempt("eval.chat_basic"))
        self.assertFalse(ALS.exempt("chat"))


class WelcomeCreditsTests(TestCase):
    def test_once_per_verified_phone_and_device(self):
        a = _user("+8801711000001")
        with _on():
            self.assertEqual(ALS.grant_welcome(a, "dev-1"), (20, "ok"))
            self.assertEqual(ALS.grant_welcome(a, "dev-1")[1], "already_claimed")
            b = _user("+8801711000002")
            self.assertEqual(ALS.grant_welcome(b, "dev-1")[1], "already_claimed")   # same phone handset
            c = _user("+8801711000003", verified=False)
            self.assertEqual(ALS.grant_welcome(c, "dev-3")[1], "phone_not_verified")
            self.assertEqual(ALS.grant_welcome(_user("+8801711000004"), "")[1], "no_device")
        a.refresh_from_db()
        self.assertEqual(a.ai_credits, 20)

    def test_off_by_default(self):
        self.assertEqual(ALS.grant_welcome(_user("+8801711000005"), "dev-5"), (0, "off"))

    def test_endpoint(self):
        u = _user("+8801711000006")
        from rest_framework.test import APIClient
        c = APIClient()
        c.force_authenticate(u)
        with _on():
            r = c.post("/api/v1/chat/welcome-credits", {}, HTTP_X_DEVICE_ID="dev-6",
                       HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.content[:200])
        self.assertEqual(r.json()["granted"], 20)
        self.assertIn("২০", r.json()["message"])


class FreeCreditsOnlyNormalTests(TestCase):
    def test_free_credits_cannot_pay_better_but_bought_can(self):
        u = _user("+8801711000010")
        CR.grant(u, CR.FREE, 30, reason="trial", note="t")
        r = billing.charge(u, "ai_level_better", exact=5, paid_only=True)
        self.assertFalse(r["ok"])
        self.assertTrue(billing.charge(u, "ai_level_normal", exact=1, paid_only=False)["ok"])
        CR.grant(u, CR.PACK, 10, reason="topup", note="p")
        self.assertTrue(billing.charge(u, "ai_level_best", exact=5, paid_only=True)["ok"])
        self.assertEqual(AL.defaults()["free_credit_levels"], ["normal"])

    def test_spec_marks_only_normal_free(self):
        with _on():
            self.assertTrue(ALS.spec("normal")["free_ok"])
            self.assertFalse(ALS.spec("better")["free_ok"])
            self.assertFalse(ALS.spec("best")["free_ok"])


class AdsTests(TestCase):
    def test_one_ad_buys_two_normal_answers(self):
        with _on():
            self.assertEqual(ALS.ad_credits(), 2 * ALS.credits("normal"))
        with _on(ad_answers_per_ad=3):
            self.assertEqual(ALS.ad_credits(), 3 * ALS.credits("normal"))
        self.assertIsNone(ALS.ad_credits())                 # levels off -> old rule

    def test_child_account_never_gets_ad_credits(self):
        u = _user("+8801711000020")
        with mock.patch("core.safe_plans.is_child_account", return_value=True), \
                mock.patch("core.integrations.is_enabled", return_value=True), \
                mock.patch.object(billing, "flag_on", return_value=True):
            r = billing.ad_event(u, "rewarded", ad_id="t1", verified=True)
        self.assertEqual(r["reason"], "child_account")
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 0)

    def test_safety_screens_never_offer_an_ad(self):
        src = (ROOT.parent / "app/lib/payments/credits_out_sheet.dart").read_text(encoding="utf-8")
        block = src[src.index("adScreens = {"):src.index("};", src.index("adScreens = {"))]
        for s in ("sos", "safety", "journey", "call", "family", "kids"):
            self.assertNotIn("'%s" % s, block)


class DailyLimitTests(TestCase):
    def test_per_level_daily_limit(self):
        u = _user("+8801711000030")
        lv = AL.defaults()
        lv["levels"]["best"]["per_day"] = 2
        with _on(levels=lv["levels"]):
            for _ in range(2):
                AIUsage.objects.create(user=u, feature="chat.best", model="m", level="best", ok=True)
            self.assertTrue(ALS.over_daily_limit(u, "best"))
            self.assertFalse(ALS.over_daily_limit(u, "normal"))
