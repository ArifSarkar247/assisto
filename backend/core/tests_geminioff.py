"""geminioff (owner 9 Nov 13:30): the Gemini prepaid credit is empty (HTTP
402). A 24 h provider breaker: opens on 402 (and billing-worded 403/404/429),
no Gemini call while open, ONE check a day (minute_jobs), every caller goes
to Claude / the phone, Better = Claude Haiku at 1 credit, Photo Studio AI
edit = honest "Coming soon" with no charge, caps hold on the photo path.
No real API call ever happens (fake HTTP everywhere)."""
import base64
from datetime import timedelta
from io import StringIO
from types import SimpleNamespace
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from core import ai, ai_health as AH, ai_levels_service as ALS
from core import gemini_breaker as GB
from core import ops_health as H
from core import photo_providers as PP
from core import vision_providers as VP
from core import voice_transcribe as VT
from core.ai_config import DEFAULT_PRICES
from core.logic import ai_levels as AL, plan_book as BOOK
from core.models import AIProviderState, AIUsage

FAKE_KEY = "AIzaSyFAKEFAKEFAKEFAKEFAKEFAKE12345"
WAV = base64.b64encode(b"RIFF" + b"\0" * 8000).decode()


def _u(phone="+8801900000091"):
    return get_user_model().objects.create_user(name="go", phone=phone, password="pw12345!")


def _resp(code, msg=""):
    return SimpleNamespace(status_code=code,
                           json=lambda: {"error": {"code": code, "message": msg}})


def _levels(**rows):
    """pricing_v2 on + the given ai_levels rows (as the apply command does)."""
    from core.tests_plansprep import v2_on
    v2_on({"ai_levels": {"enabled": True, "levels": rows}})
    cache.clear()


class BreakerTests(TestCase):
    def test_402_opens_for_24h_and_billing_words_trip(self):
        self.assertFalse(GB.is_open())
        self.assertTrue(GB.should_trip("http_402"))
        self.assertTrue(GB.should_trip(429, "Your prepayment credits are depleted"))
        self.assertTrue(GB.should_trip(403, "Billing account disabled"))
        self.assertFalse(GB.should_trip(404, "model is no longer available"))
        self.assertFalse(GB.should_trip(429, "Resource exhausted, retry later"))
        self.assertFalse(GB.should_trip(500, "billing"))
        AH.mark_down("gemini", "gemini-3.6-flash", "billing", "http_402", "Payment required " + FAKE_KEY)
        self.assertTrue(GB.is_open())
        r = AIProviderState.objects.get(slug=GB.SLUG)
        left = (r.probe_until - timezone.now()).total_seconds() / 3600
        self.assertTrue(23.9 < left <= 24.0, left)
        self.assertNotIn("AIza", r.last_error)
        self.assertTrue(AH.is_down("gemini", "any-model"))
        self.assertFalse(AH.is_down("anthropic", "claude-haiku-5-5"))

    def test_late_error_never_pushes_the_daily_check_back(self):
        t0 = timezone.now() - timedelta(hours=10)
        GB.trip("http_402", "", now=t0)
        until = AIProviderState.objects.get(slug=GB.SLUG).probe_until
        GB.trip("http_402", "")
        self.assertEqual(AIProviderState.objects.get(slug=GB.SLUG).probe_until, until)
        self.assertFalse(GB.note_failure("http_402", "gemini off (breaker)"))

    def test_gemini_is_not_a_provider_while_open(self):
        with mock.patch("core.integrations.is_enabled", return_value=True), \
                mock.patch("core.integrations.get", return_value={"api_key": "g"}), \
                mock.patch.object(ai, "active_api_key", return_value="a"):
            self.assertEqual([n for n, _ in ai._providers()], ["anthropic", "gemini", "openai"])
            GB.trip()
            self.assertEqual([n for n, _ in ai._providers()], ["anthropic", "openai"])
            self.assertEqual(ai.health_probe("gemini", "g"), (False, "billing_off"))

    def test_real_gemini_answer_closes_it(self):
        from core import ai_router as R
        GB.trip()
        R.record("gemini", True)
        self.assertFalse(GB.is_open())

    def test_owner_line(self):
        self.assertEqual(GB.state(), {"open": False})
        GB.trip("http_402", "")
        st = GB.state()
        self.assertTrue(st["open"])
        self.assertIn("Gemini: off (402) — last check", st["en"])
        self.assertIn("Gemini: বন্ধ (402)", st["bn"])
        lines = AH.alerts()
        self.assertEqual(len([a for a in lines if a["provider"] == "gemini"]), 1)


class ProbeTests(TestCase):
    def setUp(self):
        self.t0 = timezone.now()
        GB.trip("http_402", "", now=self.t0)
        self.calls = []

    def _call(self, code, msg=""):
        def run(key):
            self.calls.append(key)
            return code, msg
        return run

    def test_no_check_before_24h_one_check_after(self):
        with mock.patch.object(GB, "_key", return_value="g"):
            self.assertEqual(GB.daily_probe(now=self.t0 + timedelta(hours=23),
                                            call=self._call(402)), "waiting")
            self.assertEqual(self.calls, [])
            self.assertEqual(GB.daily_probe(now=self.t0 + timedelta(hours=24, minutes=1),
                                            call=self._call(402, "prepaid")), "still_off")
            self.assertEqual(len(self.calls), 1)
            # the next minute tick: nothing (next check 24 h later)
            self.assertEqual(GB.daily_probe(now=self.t0 + timedelta(hours=24, minutes=2),
                                            call=self._call(402)), "waiting")
            self.assertEqual(len(self.calls), 1)
        self.assertTrue(GB.is_open())

    def test_200_turns_gemini_back_on(self):
        with mock.patch.object(GB, "_key", return_value="g"):
            out = GB.daily_probe(now=self.t0 + timedelta(hours=25), call=self._call(200))
        self.assertEqual(out, "on")
        self.assertFalse(GB.is_open())

    def test_network_error_stays_off_one_more_day(self):
        with mock.patch.object(GB, "_key", return_value="g"):
            out = GB.daily_probe(now=self.t0 + timedelta(hours=25), call=self._call(0, "Timeout"))
        self.assertEqual(out, "error")
        self.assertTrue(GB.is_open())
        r = AIProviderState.objects.get(slug=GB.SLUG)
        self.assertGreater(r.probe_until, self.t0 + timedelta(hours=48))

    def test_minute_job_wiring(self):
        self.assertIn("gemini_probe", H.MINUTE_JOB_NAMES)
        self.assertEqual(H.MINUTE_JOB_NAMES[-1], "agent_core_run")
        with mock.patch.object(GB, "_probe_call") as pc:
            call_command("gemini_probe", stdout=StringIO())      # not due: no request
            pc.assert_not_called()


class CallerTests(TestCase):
    """Every Gemini caller: no HTTP while open, Claude / phone instead."""

    def setUp(self):
        GB.trip("http_402", "")
        self.http = mock.Mock(side_effect=AssertionError("Gemini HTTP while off"))

    def test_text_seam_refuses_without_http(self):
        with mock.patch.object(ai, "_http", self.http):
            with self.assertRaises(ai.ProviderError) as e:
                ai._call_gemini("g", "gemini-3.5-flash-lite", "s", "p", 10)
        self.assertEqual(e.exception.kind, "billing")
        self.http.assert_not_called()

    def test_cheap_task_runs_on_claude(self):
        with mock.patch.object(ai, "_providers", wraps=ai._providers), \
                mock.patch("core.integrations.is_enabled", return_value=True), \
                mock.patch("core.integrations.get", return_value={"api_key": "g"}), \
                mock.patch.object(ai, "active_api_key", return_value="a"), \
                mock.patch.object(ai, "_http", self.http), \
                mock.patch.object(ai, "_call_openai", side_effect=ai.ProviderError("auth", "x")), \
                mock.patch.object(ai, "_call_anthropic",
                                  side_effect=lambda k, m, *a, **kw: ("ঠিক আছে", 10, 5)):
            text, _ = ai.generate("q", user=None, feature="classify.x", tier="cheap")
        self.assertEqual(text, "ঠিক আছে")
        self.assertNotIn("gemini", AIUsage.objects.latest("id").attempts)

    def test_vision_gemini_not_resolved_and_seam_has_no_http(self):
        from core import chat_vision_service as CVS
        self.assertEqual(CVS._resolve("vision_gemini"), (False, {}))
        with mock.patch.object(VP, "_http", self.http):
            with self.assertRaises(VP.VisionError):
                VP.ask("vision_gemini", {"api_key": "k"}, image_bytes=b"\xff\xd8\xff1")
        self.http.assert_not_called()

    def test_photo_gemini_seam_has_no_http(self):
        with mock.patch.object(PP, "_http", self.http):
            with self.assertRaises(PP.ProviderError):
                PP.run("photo_gemini", {"api_key": "k"}, feature="prompt_edit",
                       image_bytes=b"x", prompt="white background")
        self.http.assert_not_called()

    def test_voice_honest_message_no_charge_no_http(self):
        u = _u()
        charge = mock.Mock()
        with mock.patch.object(VT, "_key", return_value="k"), \
                mock.patch("core.billing.charge", charge), \
                mock.patch.object(ai, "_http", self.http):
            code, body = VT.transcribe(u, {"audio_b64": WAV, "lang": "bn"})
        self.assertEqual((code, body["reason"], body["use_phone"]), (503, "unavailable", True))
        self.assertIn("Gboard", body["message"])
        charge.assert_not_called()
        self.http.assert_not_called()

    def test_voice_uses_the_non_gemini_stt_key_when_set(self):
        u = _u("+8801900000092")
        charge = mock.Mock(return_value={"ok": True, "charged": 1, "spend_ref": "sp:1"})
        with mock.patch.object(VT, "_key", return_value="k"), \
                mock.patch.object(VT, "_alt_stt", return_value={"api_key": "o"}), \
                mock.patch("core.bizagent_media._openai_transcribe", return_value="আমি ভালো আছি"), \
                mock.patch("core.billing.charge", charge), \
                mock.patch.object(ai, "_http", self.http):
            code, body = VT.transcribe(u, {"audio_b64": WAV, "lang": "bn"})
        self.assertEqual((code, body["text"]), (200, "আমি ভালো আছি"))
        self.assertEqual(AIUsage.objects.latest("id").provider, "openai")

    def test_web_search_is_claude_only(self):
        self.assertEqual(ALS.gemini_web_left(), 0)


class LevelTests(TestCase):
    def test_better_resolves_to_haiku_with_larger_budget_at_one_credit(self):
        _levels(**{k: dict(v) for k, v in BOOK.V2_LEVELS.items()})
        GB.trip()
        sp = ALS.spec("better")
        self.assertEqual((sp["provider"], sp["model"]), ("anthropic", "claude-haiku-5-5"))
        self.assertEqual(sp["out_cap"], 2500)
        self.assertGreaterEqual(sp["in_cap"], 8000)
        self.assertEqual(sp["credits"], 1)
        self.assertFalse(any(p == "gemini" for p, _ in sp["fallbacks"]))
        self.assertEqual(ALS.spec("normal")["model"], "claude-haiku-5-5")
        self.assertEqual(ALS.spec("best")["model"], "claude-sonnet-5-5")

    def test_default_gemini_normal_becomes_haiku_and_stays_available(self):
        GB.trip()
        sp = ALS.spec("normal")
        self.assertEqual((sp["provider"], sp["model"]), ("anthropic", "claude-haiku-5-5"))
        with mock.patch.object(ai, "_providers", return_value=[("anthropic", "a")]):
            self.assertEqual(ALS.available("normal"), (True, "ok"))

    def test_better_turn_charged_one_credit_answered_by_haiku(self):
        _levels(**{k: dict(v) for k, v in BOOK.V2_LEVELS.items()})
        GB.trip()
        u = _u("+8801900000093")
        seen, charges = [], []

        def charge(user, action, qty=1, note="", min_credits=0, exact=None, paid_only=False):
            charges.append(exact)
            return {"ok": True, "charged": exact, "balance": 9, "spend_ref": "sp:1"}
        gem = mock.Mock(side_effect=AssertionError("no Gemini"))
        with mock.patch.object(ALS, "enabled", return_value=True), \
                mock.patch.object(ai, "_providers", return_value=[("anthropic", "a")]), \
                mock.patch("core.billing.charge", side_effect=charge), \
                mock.patch.object(ai, "_call_gemini", gem), \
                mock.patch.object(ai, "_call_anthropic",
                                  side_effect=lambda k, m, s, p, mx, **kw: seen.append((m, mx))
                                  or ("উত্তর", 10, 5)):
            ai.generate("q", user=u, feature="chat.better", level="better")
        self.assertEqual(seen, [("claude-haiku-5-5", 2500)])
        self.assertEqual(charges, [1])
        gem.assert_not_called()

    def test_pricing_apply_patch_better_haiku_and_40pct(self):
        rows = BOOK.v2_settings_patch(gemini_off=True)["ai_levels"]["levels"]
        b = rows["better"]
        self.assertEqual((b["provider"], b["model"], b["in_cap"], b["out_cap"]),
                         ("anthropic", "claude-haiku-5-5", 8000, 2500))
        self.assertEqual(BOOK.level_credits(AL.worst_cost_usd(b, DEFAULT_PRICES)), 1)
        lr = {r["id"]: r for r in BOOK.level_rows(
            rows, DEFAULT_PRICES, AL.worst_cost_usd,
            lambda r: BOOK.level_credits(AL.worst_cost_usd(r, DEFAULT_PRICES)))}
        self.assertGreaterEqual(lr["better"]["profit_pct"], 40.0)
        self.assertLess(b["in_cap"], BOOK.HAIKU_PROMPT_MAX_TOKENS)
        # Gemini on: the approved Gemini Flash row is unchanged
        self.assertEqual(BOOK.v2_settings_patch()["ai_levels"]["levels"]["better"]["provider"],
                         "gemini")

    def test_apply_command_dry_run_shows_haiku_when_off(self):
        GB.trip()
        out = StringIO()
        call_command("pricing_v2_apply", "--dry-run", stdout=out)
        text = out.getvalue()
        self.assertIn("Gemini is OFF", text)
        self.assertNotIn("better.provider: anthropic -> gemini", text)
        self.assertNotIn("better.model: claude-haiku-5-5 -> gemini", text)
        self.assertIn("Dry run", text)


class PhotoStudioTests(TestCase):
    def setUp(self):
        GB.trip()
        self.u = _u("+8801900000094")

    def test_ai_edit_coming_soon_quote_and_config(self):
        from core import photo_studio_service as S
        self.assertEqual(S._resolve_photo("photo_gemini"), (False, {}))
        for f in ("prompt_edit", "generate", "enhance_cloud"):
            q = S.quote(self.u, f)
            self.assertEqual((q["ok"], q["reason"], q["options"]), (False, "coming_soon", []), f)
        cfg = S.client_config(self.u, "bn")
        self.assertTrue(cfg["ai_edit_coming_soon"])
        self.assertIn("শীঘ্রই আসছে", S.funding_message("coming_soon", "bn"))

    def test_create_job_charges_nothing(self):
        from core import photo_studio_service as S
        bal = int(self.u.ai_credits or 0)
        with mock.patch("core.billing.charge") as charge:
            code, body = S.create_job(self.u, {"feature": "prompt_edit",
                                               "prompt": "make the background white"}, "en")
        self.assertEqual((code, body["reason"]), (409, "coming_soon"))
        self.assertIn("No credits were used", body["message"])
        charge.assert_not_called()
        self.u.refresh_from_db()
        self.assertEqual(int(self.u.ai_credits or 0), bal)

    def test_not_coming_soon_when_gemini_on(self):
        from core import photo_studio_service as S
        GB.close()
        self.assertFalse(S.gemini_coming_soon())
        self.assertNotEqual(S.quote(self.u, "prompt_edit")["reason"], "coming_soon")


class CapTests(TestCase):
    def test_photo_path_obeys_the_owner_daily_caps(self):
        claude = mock.Mock(return_value="x")
        with mock.patch("core.ai_router.total_capped", return_value=True), \
                mock.patch.object(VP, "_claude", claude):
            with self.assertRaises(VP.VisionError) as e:
                VP.ask("vision_claude", {"api_key": "a"}, image_bytes=b"\xff\xd8\xff1")
        self.assertEqual(str(e.exception), "budget")
        claude.assert_not_called()
