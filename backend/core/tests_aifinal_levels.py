"""aifinal PART 3: answer levels chosen by the user (Normal = Gemini
Flash-Lite, Better = Claude Haiku, Best = Claude Sonnet). Fake providers
only — no real API call."""
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase

from core import ai
from core import billing
from core import ai_levels_service as ALS
from core import ai_config as C
from core.logic import ai_levels as AL
from core.models import AIUsage

PRICES = C.DEFAULT_PRICES
LV = AL.defaults()["levels"]


class LevelMathTests(TestCase):
    def test_official_prices_are_in_the_table(self):
        self.assertEqual(PRICES["gemini-2.5-flash-lite"]["in"], 0.10)
        self.assertEqual(PRICES["gemini-2.5-flash-lite"]["out"], 0.40)
        self.assertEqual((PRICES["claude-haiku-5-5"]["in"], PRICES["claude-haiku-5-5"]["out"]),
                         (0.10, 0.50))
        self.assertEqual((PRICES["claude-sonnet-5-5"]["in"], PRICES["claude-sonnet-5-5"]["out"]),
                         (2.00, 10.00))

    def test_worst_case_credit_table_with_shipped_defaults(self):
        # cheapest credit sold = p200 (৳200 / 240) -> 0.2 ৳ of AI per credit at 40 %
        safe = round(200 / 240 * 0.24, 4)
        got = {k: AL.min_credits(LV[k], PRICES, 120.0, safe) for k in AL.LEVEL_IDS}
        self.assertEqual(got, {"normal": 1, "better": 2, "best": 33})
        for k in AL.LEVEL_IDS:
            n = got[k]
            self.assertGreaterEqual(AL.profit_pct(LV[k], n, PRICES, 120.0, 200 / 240), 40.0, k)

    def test_owner_price_never_below_minimum(self):
        row = dict(LV["best"], credits=3)
        self.assertEqual(AL.credits_for(row, PRICES, 120.0, 0.2), 33)
        row["credits"] = 25
        self.assertEqual(AL.credits_for(row, PRICES, 120.0, 0.2), 25)

    def test_fallback_only_same_or_cheaper(self):
        self.assertEqual(AL.fallbacks(LV, "best", PRICES),
                         [("anthropic", "claude-haiku-5-5"), ("gemini", "gemini-2.5-flash-lite")])
        self.assertEqual(AL.fallbacks(LV, "better", PRICES), [("gemini", "gemini-2.5-flash-lite")])
        self.assertEqual(AL.fallbacks(LV, "normal", PRICES), [])

    def test_normalize_bounds_and_bad_values(self):
        n = AL.normalize({"enabled": "yes", "default": "x",
                          "levels": {"best": {"out_cap": 99999, "model": "bad model!",
                                              "provider": "evil"}}})
        self.assertFalse(n["enabled"])
        self.assertEqual(n["default"], "normal")
        self.assertEqual(n["levels"]["best"]["out_cap"], 4000)
        self.assertEqual(n["levels"]["best"]["model"], "claude-sonnet-5-5")
        self.assertEqual(n["levels"]["best"]["provider"], "anthropic")
        self.assertFalse(AL.defaults()["enabled"])          # ships OFF

    def test_hint_only_on_normal(self):
        long_q = "Compare these two loan offers and explain why? " * 10
        self.assertTrue(AL.hint_better(long_q, "normal"))
        self.assertFalse(AL.hint_better(long_q, "better"))


def _u():
    return get_user_model().objects.create_user(name="lv", phone="+8801900000001",
                                                password="pw12345!")


class GenerateLevelTests(TestCase):
    def setUp(self):
        self.u = _u()
        self.charges = []

        def charge(user, action, qty=1, note="", min_credits=0, exact=None, paid_only=False):
            self.charges.append((action, exact, paid_only))
            return {"ok": True, "charged": exact or 0, "balance": 50, "spend_ref": "sp:x"}
        self.p = [mock.patch.object(ALS, "enabled", return_value=True),
                  mock.patch.object(ai, "_providers",
                                    return_value=[("anthropic", "a"), ("gemini", "g")]),
                  mock.patch("core.billing.charge", side_effect=charge)]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in self.p:
            p.stop()

    def test_best_uses_sonnet_and_charges_its_price_paid_only(self):
        seen = []
        with mock.patch.object(ai, "_call_anthropic",
                               side_effect=lambda k, m, *a, **kw: seen.append(m) or ("ok", 10, 5)):
            text, _ = ai.generate("q", user=self.u, feature="chat.best", level="best")
        self.assertEqual(text, "ok")
        self.assertEqual(seen, ["claude-sonnet-5-5"])
        self.assertEqual(self.charges[0][2], True)        # bought credits only
        self.assertGreaterEqual(self.charges[0][1], 33)
        self.assertEqual(AIUsage.objects.latest("id").level, "best")

    def test_better_falls_back_to_cheaper_gemini_never_up(self):
        with mock.patch.object(ai, "_call_anthropic", side_effect=ai.ProviderError("server")), \
                mock.patch.object(ai, "_call_gemini",
                                  side_effect=lambda k, m, *a, **kw: ("g:" + m, 10, 5)):
            text, _ = ai.generate("q", user=self.u, feature="chat.better", level="better")
        self.assertEqual(text, "g:gemini-2.5-flash-lite")
        row = AIUsage.objects.latest("id")
        self.assertEqual((row.provider, row.hops), ("gemini", 1))

    def test_normal_never_upgrades_to_claude(self):
        called = mock.Mock()
        with mock.patch.object(ai, "_call_gemini", side_effect=ai.ProviderError("server")), \
                mock.patch.object(ai, "_call_anthropic", side_effect=called), \
                mock.patch("core.billing.credit"):
            with self.assertRaises(ai.AIUnavailable):
                ai.generate("q", user=self.u, feature="chat.normal", level="normal")
        called.assert_not_called()
        self.assertEqual(self.charges[0][2], False)        # free/ad credits OK on Normal

    def test_max_output_is_the_level_cap(self):
        got = {}

        def gem(k, m, system, prompt, max_tokens, history=None):
            got["max"] = max_tokens
            return ("ok", 1, 1)
        with mock.patch.object(ai, "_call_gemini", side_effect=gem):
            ai.generate("q", user=self.u, feature="chat.normal", level="normal", max_tokens=5000)
        self.assertEqual(got["max"], LV["normal"]["out_cap"])


class LevelPayloadTests(TestCase):
    def test_off_by_default(self):
        self.assertEqual(ALS.app_payload(_u())["enabled"], False)

    def test_capped_provider_shows_temporarily_unavailable(self):
        from core import ai_router as R
        with mock.patch.object(ALS, "enabled", return_value=True), \
                mock.patch.object(ALS, "cfg", return_value=(dict(AL.defaults(), enabled=True),
                                                              billing.cfg())), \
                mock.patch.object(ai, "_providers",
                                  return_value=[("anthropic", "a"), ("gemini", "g")]), \
                mock.patch.object(R, "provider_capped", side_effect=lambda p, c=None: p == "anthropic"):
            out = ALS.app_payload(_u(), "en")
        av = {r["id"]: r["available"] for r in out["levels"]}
        self.assertEqual(av, {"normal": True, "better": False, "best": False})
        self.assertEqual(out["levels"][1]["why"], "temporarily_unavailable")
        self.assertNotIn("anthropic", str(out))            # provider-neutral
        self.assertNotIn("claude", str(out).lower())
        self.assertEqual([r["credits"] for r in out["levels"]][0], 1)

    def test_chat_level_resolves_unknown_to_default(self):
        self.assertEqual(ALS.resolve("turbo"), "normal")
        self.assertEqual(ALS.resolve("BEST"), "best")
