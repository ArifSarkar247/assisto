"""geminifix (live bug 4 Nov, build 309): the owner's new Google project
answers HTTP 404 "model ... no longer available to new users" for
gemini-2.5-flash and HTTP 402 (billing not enabled) for newer models.
Every owner-found failure becomes a test: fake providers return 404 / 402;
the user still gets a normal answer from a SAME-OR-CHEAPER provider (Claude
Haiku), the failed attempt costs nothing, Gemini is skipped for down_min
minutes, the real reason is kept (never the key), vision falls back to
Claude Haiku vision, voice keeps the phone's own words with no charge.
No real API call ever happens."""
import base64
from types import SimpleNamespace
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase

from core import ai, ai_config as C, ai_health as AH, gemini_models as GM
from core import ai_levels_service as ALS
from core import vision_providers as VP
from core import voice_transcribe as VT
from core.logic import ai_levels as AL
from core.models import AIUsage

MSG_404 = ("This model models/gemini-2.5-flash is no longer available to new users. "
           "Please update your code to use a newer model.")
FAKE_KEY = "AIzaSyFAKEFAKEFAKEFAKEFAKEFAKE12345"
LV = AL.defaults()["levels"]


def _u(phone="+8801900000077"):
    return get_user_model().objects.create_user(name="gf", phone=phone, password="pw12345!")


def _resp(code, msg=""):
    return SimpleNamespace(status_code=code,
                           json=lambda: {"error": {"code": code, "message": msg,
                                                   "status": "NOT_FOUND"}})


class ModelIdTests(TestCase):
    def test_defaults_are_current_stable_ids_not_retired(self):
        self.assertEqual(GM.DEFAULT_MODEL, "gemini-3.5-flash-lite")
        for kind in GM.KINDS:
            self.assertNotIn(GM.get(kind), GM.RETIRED)
        self.assertEqual(LV["normal"]["model"], "gemini-3.5-flash-lite")
        self.assertEqual(C.MODEL_SLOTS["gemini_cheap"][1], "gemini-3.5-flash-lite")
        self.assertEqual(VP.DEFAULT_MODELS["vision_gemini"], "gemini-3.5-flash-lite")
        self.assertEqual(VT.model(), "gemini-3.5-flash-lite")
        self.assertIn("gemini-2.5-flash", GM.RETIRED)

    def test_same_price_as_the_old_normal_so_credits_do_not_move(self):
        a, b = C.DEFAULT_PRICES["gemini-2.5-flash"], C.DEFAULT_PRICES["gemini-3.5-flash-lite"]
        self.assertEqual((a["in"], a["out"]), (b["in"], b["out"]))

    def test_retired_saved_id_is_served_with_the_current_one(self):
        self.assertEqual(GM.resolve("gemini-2.5-flash"), "gemini-3.5-flash-lite")
        self.assertEqual(GM.resolve("gemini-2.0-flash"), "gemini-3.5-flash-lite")
        self.assertEqual(GM.resolve("gemini-3.6-flash"), "gemini-3.6-flash")
        # never silently dearer: a cheap retired id keeps its id (health fallback)
        prices = dict(C.DEFAULT_PRICES, **{"gemini-2.0-flash": {"in": 0.1, "out": 0.4}})
        self.assertEqual(GM.resolve("gemini-2.0-flash", prices=prices), "gemini-2.0-flash")
        conf = C.normalize({"models": {"gemini_cheap": "gemini-2.5-flash"}})
        self.assertEqual(C.model_for(conf, "gemini", "cheap", "cheap"), "gemini-3.5-flash-lite")

    def test_owner_block_normalized(self):
        n = AL.normalize({"gemini_models": {"text": "gemini-3.6-flash", "vision": "bad id!",
                                            "voice": "claude-haiku-5-5"}})
        self.assertEqual(n["gemini_models"], {"text": "gemini-3.6-flash",
                                              "vision": "gemini-3.5-flash-lite",
                                              "voice": "gemini-3.5-flash-lite"})

    def test_no_thinking_budget_sent_to_3x_models(self):
        self.assertIsNone(GM.thinking_off_config("gemini-3.5-flash-lite"))
        self.assertEqual(GM.thinking_off_config("gemini-2.5-flash-lite"), {"thinkingBudget": 0})
        sent = {}

        def post(url, json=None, headers=None, timeout=None):
            sent.update(url=url, body=json)
            return SimpleNamespace(status_code=200, json=lambda: {
                "candidates": [{"content": {"parts": [{"text": "ঠিক"}]}}],
                "usageMetadata": {"promptTokenCount": 5, "candidatesTokenCount": 2}})
        with mock.patch.object(ai, "_http", return_value=SimpleNamespace(post=post)):
            tok = ai._CALL_OPTS.set({"klass": "cheap"})
            try:
                ai._call_gemini("k", "gemini-3.5-flash-lite", "s", "p", 50)
            finally:
                ai._CALL_OPTS.reset(tok)
        self.assertNotIn("thinkingConfig", sent["body"]["generationConfig"])
        self.assertIn("gemini-3.5-flash-lite:generateContent", sent["url"])


class HealthTests(TestCase):
    def test_404_marks_one_model_402_marks_the_whole_key(self):
        AH.mark_down("gemini", "gemini-2.5-flash", "not_found", "http_404", MSG_404)
        self.assertTrue(AH.is_down("gemini", "gemini-2.5-flash"))
        self.assertFalse(AH.is_down("gemini", "gemini-3.5-flash-lite"))
        AH.mark_down("gemini", "gemini-3.6-flash", "billing", "http_402", "Payment required")
        self.assertTrue(AH.is_down("gemini", "gemini-3.5-flash-lite"))
        self.assertFalse(AH.is_down("anthropic", "claude-haiku-5-5"))
        self.assertFalse(AH.mark_down("gemini", "x", "server", "http_500", ""))   # soft: circuit

    def test_reason_never_carries_a_key(self):
        AH.mark_down("gemini", "m1", "auth", "http_403", "bad key %s used" % FAKE_KEY)
        e = AH.last_error("gemini")
        self.assertNotIn("AIza", e["reason"])
        self.assertEqual((e["kind"], e["code"]), ("auth", "http_403"))

    def test_red_lines_bn_en_and_clear_after_a_success(self):
        from core import ai_router as R
        self.assertIsNone(AH.alert_lines("gemini"))
        AH.mark_down("gemini", "gemini-3.6-flash", "billing", "http_402", "")
        bn, en = AH.alert_lines("gemini")
        self.assertIn("billing not enabled (HTTP 402)", en)
        self.assertIn("Google AI Studio / Cloud", en)
        self.assertIn("বিলিং চালু নেই", bn)
        AH.mark_down("gemini", "gemini-2.5-flash", "not_found", "http_404", MSG_404)
        self.assertIn("retired", AH.alert_lines("gemini")[1])
        R.record("gemini", True)                     # a real answer later
        self.assertIsNone(AH.alert_lines("gemini"))
        self.assertEqual(AH.alerts(), [])


class RouterFallbackTests(TestCase):
    def setUp(self):
        cache.clear()
        self.u = _u()
        self.charges, self.refunds = [], []

        def charge(user, action, qty=1, note="", min_credits=0, exact=None, paid_only=False):
            self.charges.append((action, exact))
            return {"ok": True, "charged": exact or 1, "balance": 50, "spend_ref": "sp:x"}
        self.p = [mock.patch.object(ALS, "enabled", return_value=True),
                  mock.patch.object(ai, "_providers",
                                    return_value=[("anthropic", "a"), ("gemini", "g")]),
                  mock.patch("core.billing.charge", side_effect=charge),
                  mock.patch("core.billing.credit",
                             side_effect=lambda *a, **k: self.refunds.append(a))]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in self.p:
            p.stop()

    def test_normal_404_answers_from_haiku_charged_once_then_skips_gemini(self):
        gem = mock.Mock(side_effect=ai.ProviderError("not_found", "http_404: " + MSG_404))
        claude = mock.Mock(side_effect=lambda k, m, *a, **kw: ("উত্তর " + m, 10, 5))
        with mock.patch.object(ai, "_call_gemini", gem), \
                mock.patch.object(ai, "_call_anthropic", claude):
            text, _ = ai.generate("q", user=self.u, feature="chat.normal", level="normal")
            self.assertEqual(text, "উত্তর claude-haiku-5-5")
            self.assertEqual(len(self.charges), 1)       # the Normal price, once
            self.assertEqual(self.refunds, [])
            row = AIUsage.objects.latest("id")
            self.assertEqual((row.provider, row.attempts), ("anthropic",
                                                            "gemini:not_found|anthropic:ok"))
            self.assertTrue(AH.is_down("gemini", "gemini-3.5-flash-lite"))
            self.assertIn("no longer available", AH.last_error("gemini")["reason"])
            # second turn: no doomed Gemini call at all
            ai.generate("q2", user=self.u, feature="chat.normal", level="normal")
        self.assertEqual(gem.call_count, 1)
        self.assertEqual(AIUsage.objects.latest("id").attempts, "gemini:down|anthropic:ok")
        ok, why = ALS.available("normal")
        self.assertEqual((ok, why), (True, "fallback"))        # picker never says unavailable

    def test_402_over_http_cheap_task_goes_to_cheaper_haiku_not_queued(self):
        rq = SimpleNamespace(post=lambda *a, **k: _resp(402, "Payment required " + FAKE_KEY))
        with mock.patch.object(ai, "_http", return_value=rq), \
                mock.patch.object(ai, "_call_anthropic",
                                  side_effect=lambda k, m, *a, **kw: ("ঠিক আছে", 10, 5)):
            text, _ = ai.generate("q", user=None, feature="classify.x", tier="cheap")
        self.assertEqual(text, "ঠিক আছে")
        e = AH.last_error("gemini")
        self.assertEqual((e["kind"], e["code"]), ("billing", "http_402"))
        self.assertNotIn("AIza", e["reason"])
        self.assertTrue(AH.is_down("gemini", "any-model"))     # whole key

    def test_retired_saved_level_model_is_sent_as_the_current_id(self):
        # the live row may still hold gemini-2.5-flash (saved before) — the
        # config is NOT rewritten; the call goes out with the current id
        seen = []
        row = dict(LV["normal"], model="gemini-2.5-flash", id="normal", credits=4,
                   fallbacks=[("anthropic", "claude-haiku-5-5")], free_ok=True)
        with mock.patch.object(ALS, "spec", return_value=row), \
                mock.patch.object(ALS, "over_daily_limit", return_value=False), \
                mock.patch.object(ai, "_call_gemini",
                                  side_effect=lambda k, m, *a, **kw: seen.append(m) or ("ok", 1, 1)):
            text, _ = ai.generate("q", user=self.u, feature="chat.normal", level="normal")
        self.assertEqual((text, seen), ("ok", ["gemini-3.5-flash-lite"]))
        self.assertEqual(AIUsage.objects.latest("id").model, "gemini-3.5-flash-lite")

    def test_never_a_costlier_provider_and_failed_attempt_refunded(self):
        # Better = Haiku; Gemini (dearer) is never tried, the charge is refunded
        gem = mock.Mock(return_value=("x", 1, 1))
        with mock.patch.object(ai, "_call_anthropic",
                               side_effect=ai.ProviderError("billing", "http_402")), \
                mock.patch.object(ai, "_call_gemini", gem):
            with self.assertRaises(ai.AIUnavailable):
                ai.generate("q", user=self.u, feature="chat.better", level="better")
        gem.assert_not_called()
        self.assertEqual(len(self.refunds), 1)
        self.assertFalse(AIUsage.objects.latest("id").ok)


class VisionFallbackTests(TestCase):
    def test_gemini_404_marks_down_then_no_http_call(self):
        calls = []

        def post(*a, **k):
            calls.append(1)
            return _resp(404, MSG_404)
        with mock.patch.object(VP, "_http", return_value=SimpleNamespace(post=post)):
            for _ in range(2):
                with self.assertRaises(VP.VisionError):
                    VP.ask("vision_gemini", {"api_key": "k"}, image_bytes=b"\xff\xd8\xff1")
        self.assertEqual(len(calls), 1)
        self.assertTrue(AH.is_down("gemini", "gemini-3.5-flash-lite"))

    def test_gemini_vision_falls_back_to_claude_haiku_never_dearer(self):
        from core import chat_vision_service as CVS
        self.assertLessEqual(CVS._haiku_cost_usd(), CVS._DEFAULT_COST_USD["vision_gemini"])

        def resolve(slug):
            return (slug == "vision_claude"), ({"api_key": "k", "cost_per_image_usd": 0.02}
                                               if slug == "vision_claude" else {})
        with mock.patch.object(CVS, "_resolve", side_effect=resolve), \
                mock.patch.object(CVS, "_fallbacks", return_value=[]):
            cands = CVS._candidates("vision_gemini", {"api_key": "g", "cost_per_image_usd": 0.004})
            self.assertEqual([p for p, _ in cands], ["vision_gemini", "vision_claude"])
            self.assertEqual(cands[1][1]["model"], "claude-haiku-5-5")
            # a provider cheaper than Haiku per image never falls back to Claude
            cands = CVS._candidates("vision_gemini", {"api_key": "g", "cost_per_image_usd": 0.0001})
            self.assertEqual([p for p, _ in cands], ["vision_gemini"])


WAV = base64.b64encode(b"RIFF" + b"\0" * 8000).decode()


class VoiceTests(TestCase):
    def setUp(self):
        self.u = _u("+8801900000078")

    def test_402_refunds_then_next_request_is_free_unavailable(self):
        charge = mock.Mock(return_value={"ok": True, "charged": 1, "balance": 9,
                                         "spend_ref": "sp:1"})
        rq = SimpleNamespace(post=lambda *a, **k: _resp(402, "billing"))
        with mock.patch.object(VT, "_key", return_value="k"), \
                mock.patch("core.billing.charge", charge), \
                mock.patch("core.billing.credit") as credit, \
                mock.patch.object(ai, "_http", return_value=rq):
            code, body = VT.transcribe(self.u, {"audio_b64": WAV, "lang": "bn"})
            self.assertEqual(code, 502)
            credit.assert_called_once()                     # refunded at once
            code, body = VT.transcribe(self.u, {"audio_b64": WAV, "lang": "bn"})
        self.assertEqual((code, body["reason"]), (503, "unavailable"))
        self.assertEqual(charge.call_count, 1)              # nothing charged the 2nd time
