"""ai-router: failover order (main + cheap), every failure type, 400 never
fails over, circuit breaker open/half-open/close, spend caps (80% alert once,
100% skip, all capped -> honest state), cost maths, credits per tier whatever
the provider, provider names never reach the user, and the exact Opus 5.5
request body. Every provider call is mocked at the network seam (SDK client
factory / HTTP module / provider function) — no real AI call ever happens."""
import io
from datetime import timedelta
from types import SimpleNamespace
from unittest import mock

import httpx2 as httpx   # the anthropic 1.x SDK transport
from django.core.cache import cache
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase
from django.utils import timezone

from core import ai, ai_config as C, ai_prompt as P, ai_router as R
from core.models import AIProviderState, AIUsage, User

ALL = [("anthropic", "ka"), ("gemini", "kg"), ("openai", "ko")]


def _req():
    return httpx.Request("POST", "https://api.anthropic.com/v1/messages")


def sdk_error(status):
    import anthropic
    resp = httpx.Response(status, request=_req())
    cls = {400: anthropic.BadRequestError, 429: anthropic.RateLimitError,
           401: anthropic.AuthenticationError, 404: anthropic.NotFoundError,
           500: anthropic.InternalServerError}.get(status, anthropic.APIStatusError)
    return cls("err %d" % status, response=resp, body=None)


class Fakes:
    """Per-provider scripted outcomes: a str/tuple = answer, an Exception =
    raised. Records the call order."""

    def __init__(self, test, **script):
        self.calls = []
        self.script = script
        for name in ("anthropic", "gemini", "openai"):
            # stopped by RouterBase's mock.patch.stopall (LIFO-safe when a
            # test stacks another patch on the same seam)
            mock.patch("core.ai._call_" + name, side_effect=self._mk(name)).start()

    def _mk(self, name):
        def call(key, model, system, prompt, max_tokens, history=None):
            self.calls.append((name, model))
            out = self.script.get(name, "উত্তর")
            if isinstance(out, BaseException):
                raise out
            if isinstance(out, tuple):
                return out
            return out, 100, 50
        return call

    @property
    def order(self):
        return [c[0] for c in self.calls]


class RouterBase(TestCase):
    def setUp(self):
        cache.clear()
        p = mock.patch("core.ai._providers", return_value=list(ALL))
        p.start()
        self.addCleanup(p.stop)
        self.notify = mock.patch("core.push.notify_owner", return_value={}).start()
        self.addCleanup(mock.patch.stopall)

    def set_cfg(self, **block):
        conf = R.cfg()
        for k, v in block.items():
            if isinstance(v, dict) and isinstance(conf.get(k), dict):
                conf[k].update(v)
            else:
                conf[k] = v
        R.save_cfg(conf)

    def spend(self, provider, usd):
        AIUsage.objects.create(feature="x", model="m", provider=provider, cost_usd=usd)


# ------------------------------------------------------------------ order
class FailoverOrderTests(RouterBase):
    def test_main_order_anthropic_openai_gemini(self):
        f = Fakes(self, anthropic=ai.ProviderError("server"), openai=ai.ProviderError("timeout"))
        text, cost = ai.generate("t", tier="medium", feature="jobs.cv")
        self.assertEqual(f.order, ["anthropic", "openai", "gemini"])
        u = AIUsage.objects.get(ok=True)
        self.assertEqual((u.provider, u.task_class, u.hops), ("gemini", "main", 2))
        self.assertEqual(u.attempts, "anthropic:server|openai:timeout|gemini:ok")

    def test_cheap_order_gemini_openai_anthropic_haiku(self):
        f = Fakes(self, gemini=ai.ProviderError("rate_limit"), openai=ai.ProviderError("server"))
        ai.generate("classify", tier="cheap", feature="crm.sentiment")
        self.assertEqual(f.order, ["gemini", "openai", "anthropic"])
        self.assertEqual(f.calls[-1], ("anthropic", "claude-haiku-5-5"))

    def test_chat_is_main_class_on_opus_even_at_cheap_credit_tier(self):
        f = Fakes(self)
        ai.generate("hi", tier="cheap", feature="chat")
        self.assertEqual(f.calls, [("anthropic", "claude-opus-5-5")])
        self.assertEqual(AIUsage.objects.get().task_class, "main")

    def test_owner_can_pick_sonnet_for_main(self):
        self.set_cfg(models={"anthropic_medium": "claude-sonnet-5-5"})
        f = Fakes(self)
        ai.generate("hi", tier="medium")
        self.assertEqual(f.calls, [("anthropic", "claude-sonnet-5-5")])

    def test_success_first_try_has_no_hops(self):
        Fakes(self)
        ai.generate("x", tier="strong")
        self.assertEqual(AIUsage.objects.get().hops, 0)


# ------------------------------------------------------------------ failure types
class FailureTypeTests(RouterBase):
    def _fake_client(self, exc=None, stop_reason="end_turn"):
        captured = {}

        class Msgs:
            def create(self_inner, **kw):
                captured.update(kw)
                if exc is not None:
                    raise exc
                return SimpleNamespace(
                    stop_reason=stop_reason, model=kw["model"],
                    content=[SimpleNamespace(type="text", text="ঠিক আছে")],
                    usage=SimpleNamespace(input_tokens=10, output_tokens=5,
                                          cache_read_input_tokens=0,
                                          cache_creation_input_tokens=0))
        client = SimpleNamespace(messages=Msgs(), beta=SimpleNamespace(messages=Msgs()),
                                 models=SimpleNamespace(list=lambda **k: []))
        return client, captured

    def _sdk(self, exc=None, stop_reason="end_turn"):
        client, captured = self._fake_client(exc, stop_reason)
        mock.patch("core.ai._anthropic_client", return_value=client).start()
        return captured

    def _openai_ok(self):
        calls = []

        def post(url, json=None, headers=None, timeout=None):
            calls.append(url)
            return SimpleNamespace(status_code=200, json=lambda: {
                "choices": [{"message": {"content": "backup answer"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
        mock.patch("core.ai._http", return_value=SimpleNamespace(post=post)).start()
        return calls

    def _assert_failover(self, exc=None, stop_reason="end_turn", kind=""):
        self._sdk(exc, stop_reason)
        calls = self._openai_ok()
        text, _ = ai.generate("q", tier="medium")
        self.assertEqual(text, "backup answer")
        self.assertTrue(calls and "openai" in calls[0])
        u = AIUsage.objects.get(ok=True)
        self.assertEqual(u.provider, "openai")
        self.assertTrue(u.attempts.startswith("anthropic:" + kind), u.attempts)

    def test_connection_error(self):
        import anthropic
        self._assert_failover(anthropic.APIConnectionError(request=_req()), kind="connection")

    def test_timeout(self):
        import anthropic
        self._assert_failover(anthropic.APITimeoutError(request=_req()), kind="timeout")

    def test_429(self):
        self._assert_failover(sdk_error(429), kind="rate_limit")

    def test_5xx(self):
        self._assert_failover(sdk_error(500), kind="server")

    def test_529_overloaded(self):
        self._assert_failover(sdk_error(529), kind="server")

    def test_refusal_fails_over_but_does_not_trip_circuit(self):
        self._assert_failover(stop_reason="refusal", kind="refusal")
        st = AIProviderState.objects.filter(slug="anthropic").first()
        self.assertTrue(st is None or st.consecutive_failures == 0)

    def test_rest_429_and_5xx_and_timeout(self):
        import requests
        seq = [SimpleNamespace(status_code=429), requests.Timeout("slow"),
               requests.ConnectionError("down"), SimpleNamespace(status_code=503)]

        def post(url, json=None, headers=None, timeout=None):
            r = seq.pop(0)
            if isinstance(r, Exception):
                raise r
            return r
        mock.patch("core.ai._http", return_value=SimpleNamespace(post=post)).start()
        kinds = []
        for _ in range(4):
            with self.assertRaises(ai.ProviderError) as e:
                ai._post("https://x", {}, {})
            kinds.append(e.exception.kind)
        self.assertEqual(kinds, ["rate_limit", "timeout", "connection", "server"])
        self.assertEqual(ai._status_error(400).kind, "bad_request")
        self.assertFalse(ai._status_error(400).failover)

    def test_gemini_failover_to_openai_over_http(self):
        Fakes(self)
        mock.patch("core.ai._call_gemini", side_effect=ai.ProviderError("rate_limit")).start()
        f_open = mock.patch("core.ai._call_openai", return_value=("ok", 3, 3)).start()
        ai.generate("sum", tier="cheap", feature="briefing")
        f_open.assert_called_once()

    def test_400_does_not_fail_over_and_is_logged(self):
        self._sdk(sdk_error(400))
        calls = self._openai_ok()
        with self.assertLogs("core.ai", level="ERROR"):
            with self.assertRaises(ai.AIUnavailable) as e:
                ai.generate("q", tier="medium")
        self.assertEqual(e.exception.reason, "queued")
        self.assertEqual(calls, [])                   # OpenAI never called
        row = AIUsage.objects.get(ok=False)
        self.assertEqual(row.error_kind, "bad_request")
        st = AIProviderState.objects.filter(slug="anthropic").first()
        self.assertTrue(st is None or st.consecutive_failures == 0)

    def test_opus_request_body(self):
        cap = self._sdk()
        ai.generate("নমস্কার", tier="cheap", feature="chat", max_tokens=700,
                    history=[{"role": "user", "content": "আগে"},
                             {"role": "assistant", "content": "হ্যাঁ"}])
        self.assertEqual(cap["model"], "claude-opus-5-5")
        for banned in ("temperature", "top_p", "top_k"):
            self.assertNotIn(banned, cap)
        self.assertEqual(cap["thinking"], {"type": "adaptive"})
        self.assertNotEqual(cap.get("thinking", {}).get("type"), "disabled")
        self.assertEqual(cap["output_config"], {"effort": "low"})
        self.assertEqual(cap["messages"][-1]["role"], "user")      # no prefill
        self.assertGreater(cap["max_tokens"], 700)                 # thinking headroom
        self.assertIn("Assisto", cap["system"])
        cap.clear()
        ai.generate("plan", tier="strong")
        self.assertEqual(cap["output_config"], {"effort": "medium"})
        self.assertNotIn("temperature", cap)

    def test_request_builder_never_sends_sampling_params(self):
        for m in C.ANTHROPIC_MODELS:
            body = ai.anthropic_request(m, "s", [{"role": "user", "content": "x"}], 500, "high")
            self.assertFalse({"temperature", "top_p", "top_k"} & set(body))
            self.assertEqual(body["thinking"], {"type": "adaptive"})


# ------------------------------------------------------------------ circuit
class CircuitTests(RouterBase):
    def test_open_after_threshold_then_half_open_then_close(self):
        conf = R.cfg()
        for _ in range(conf["circuit"]["fail_threshold"]):
            self.assertTrue(R.allow("anthropic", conf))
            R.record("anthropic", False, conf, error="server")
        st = AIProviderState.objects.get(slug="anthropic")
        self.assertEqual(st.state, "open")
        self.assertFalse(R.allow("anthropic", conf))
        # after the cooldown exactly one probe is let through
        AIProviderState.objects.filter(slug="anthropic").update(
            opened_at=timezone.now() - timedelta(seconds=conf["circuit"]["cooldown_s"] + 1))
        self.assertTrue(R.allow("anthropic", conf))
        self.assertEqual(AIProviderState.objects.get(slug="anthropic").state, "half_open")
        self.assertFalse(R.allow("anthropic", conf))            # second worker waits
        R.record("anthropic", True, conf)
        st = AIProviderState.objects.get(slug="anthropic")
        self.assertEqual((st.state, st.consecutive_failures), ("closed", 0))

    def test_half_open_failure_reopens(self):
        conf = R.cfg()
        AIProviderState.objects.create(slug="openai", state="half_open")
        R.record("openai", False, conf, error="timeout")
        self.assertEqual(AIProviderState.objects.get(slug="openai").state, "open")

    def test_error_rate_window_opens(self):
        self.set_cfg(circuit={"fail_threshold": 50, "min_calls": 4, "error_rate_pct": 50})
        conf = R.cfg()
        for ok in (True, False, True, False):
            R.record("gemini", ok, conf)
        self.assertEqual(AIProviderState.objects.get(slug="gemini").state, "open")

    def test_slow_successes_count_against_rate(self):
        self.set_cfg(circuit={"fail_threshold": 50, "min_calls": 3, "error_rate_pct": 60})
        conf = R.cfg()
        for _ in range(3):
            R.record("gemini", True, conf, slow=True)
        self.assertEqual(AIProviderState.objects.get(slug="gemini").state, "open")

    def test_generate_skips_open_circuit(self):
        AIProviderState.objects.create(slug="anthropic", state="open", opened_at=timezone.now())
        f = Fakes(self)
        ai.generate("x", tier="medium")
        self.assertEqual(f.order, ["openai"])
        self.assertTrue(AIUsage.objects.get().attempts.startswith("anthropic:circuit"))

    def test_generate_failures_open_the_circuit(self):
        f = Fakes(self, anthropic=ai.ProviderError("server"))
        for _ in range(3):
            ai.generate("x", tier="medium")
        self.assertEqual(AIProviderState.objects.get(slug="anthropic").state, "open")
        n = len(f.calls)
        ai.generate("x", tier="medium")
        self.assertEqual(f.calls[n:], [("openai", "gpt-4o-mini")])   # skipped

    def test_health_check_command_uses_free_probe(self):
        AIProviderState.objects.create(slug="anthropic", state="open", opened_at=timezone.now())
        with mock.patch("core.ai.health_probe", side_effect=[(True, "ok"), (False, "auth"),
                                                             (True, "ok")]):
            call_command("ai_health_check", stdout=io.StringIO())
        self.assertEqual(AIProviderState.objects.get(slug="anthropic").state, "half_open")
        g = AIProviderState.objects.get(slug="gemini")
        self.assertEqual((g.last_health_ok, g.consecutive_failures), (False, 1))


# ------------------------------------------------------------------ caps
class CapTests(RouterBase):
    def test_80_percent_alerts_owner_once(self):
        self.spend("anthropic", 2.5)                  # 83% of $3
        f = Fakes(self)
        ai.generate("x", tier="medium")
        ai.generate("x", tier="medium")
        self.assertEqual(f.order, ["anthropic", "anthropic"])
        subjects = [c.args[0] for c in self.notify.call_args_list]
        self.assertEqual(len([s for s in subjects if "Anthropic" in s]), 1)
        self.assertEqual(AIProviderState.objects.get(slug="anthropic").alert_warn_day,
                         timezone.localdate())
        cache.clear()
        alert = R.owner_alert()
        self.assertEqual(alert[0]["slug"], "anthropic")

    def test_100_percent_skips_provider(self):
        self.spend("anthropic", 3.0)
        f = Fakes(self)
        text, _ = ai.generate("x", tier="medium")
        self.assertEqual(f.order, ["openai"])
        self.assertTrue(AIUsage.objects.get(provider="openai").attempts.startswith("anthropic:cap"))

    def test_all_capped_gives_honest_budget_state_and_refund(self):
        self.set_cfg(caps_usd={"total": 100.0})
        for p in ("anthropic", "openai", "gemini"):
            self.spend(p, 3.0)
        mock.patch("core.ai.daily_budget_usd", return_value=100.0).start()
        f = Fakes(self)
        with self.assertRaises(ai.AIUnavailable) as e:
            ai.generate("x", tier="medium")
        self.assertEqual(e.exception.reason, "budget")
        self.assertEqual(f.calls, [])

    def test_total_cap_blocks_before_any_call(self):
        self.spend("anthropic", 1.0)
        self.spend("openai", 1.0)
        self.set_cfg(caps_usd={"total": 2.0})
        f = Fakes(self)
        with self.assertRaises(ai.AIUnavailable) as e:
            ai.generate("x", tier="medium")
        self.assertEqual((e.exception.reason, f.calls), ("budget", []))
        self.assertFalse(ai.available())

    def test_total_cap_is_min_with_legacy_kill_switch(self):
        self.set_cfg(caps_usd={"total": 50.0})
        self.assertEqual(R.total_cap(), 5.0)            # env AI_DAILY_BUDGET_USD
        self.set_cfg(caps_usd={"total": 1.5})
        self.assertEqual(R.total_cap(), 1.5)

    def test_cap_zero_switches_provider_off(self):
        self.set_cfg(caps_usd={"anthropic": 0})
        f = Fakes(self)
        ai.generate("x", tier="medium")
        self.assertEqual(f.order, ["openai"])

    def test_legacy_rows_count_by_model_prefix(self):
        AIUsage.objects.create(feature="x", model="claude-haiku-4-5", cost_usd=1.25)
        self.assertAlmostEqual(R.spend_today("anthropic"), 1.25)
        self.assertAlmostEqual(R.spend_today("openai"), 0.0)


# ------------------------------------------------------------------ cost + credits
class CostAndCreditTests(RouterBase):
    def test_cost_maths(self):
        conf = R.cfg()
        self.assertAlmostEqual(C.cost_usd(conf, "claude-opus-5-5", 1000, 500, 2000, 0),
                               (1000 * 4 + 500 * 20 + 2000 * 0.20) / 1e6)
        self.assertAlmostEqual(C.cost_usd(conf, "claude-sonnet-5-5", 1_000_000, 0), 2.0)
        self.assertAlmostEqual(C.cost_usd(conf, "claude-haiku-5-5", 0, 1_000_000), 0.5)
        self.assertAlmostEqual(C.cost_usd(conf, "unknown-model", 1_000_000, 0), 4.0)  # highest

    def test_cost_logged_per_call(self):
        Fakes(self, anthropic=("ok", 1000, 500, {"cache_read": 2000, "cache_write": 0,
                                                 "model": "claude-opus-5-5"}))
        _, cost = ai.generate("x", tier="medium", feature="jobs.cv")
        u = AIUsage.objects.get()
        self.assertAlmostEqual(cost, 0.0144)
        self.assertAlmostEqual(u.cost_usd, 0.0144)
        self.assertEqual((u.input_tokens, u.output_tokens, u.cache_read_tokens),
                         (1000, 500, 2000))
        self.assertEqual((u.provider, u.model, u.tier, u.ok), ("anthropic", "claude-opus-5-5",
                                                               "medium", True))

    def test_profit_guard_booked(self):
        Fakes(self)
        with mock.patch("core.billing.record_ai_cost_usd") as rec:
            _, cost = ai.generate("x", tier="medium")
        rec.assert_called_once_with(cost)

    def test_credits_charged_per_tier_regardless_of_provider(self):
        u = User.objects.create_user(phone="+8801711000111", password="x")
        charged = []
        real_charge = __import__("core.billing", fromlist=["charge"]).charge

        def spy(user, action, qty=1, note=""):
            charged.append(action)
            return {"ok": True, "charged": 3, "spend_ref": ""}
        with mock.patch("core.billing.charge", side_effect=spy):
            Fakes(self)
            ai.generate("x", tier="medium", user=u)
            mock.patch("core.ai._call_anthropic", side_effect=ai.ProviderError("server")).start()
            mock.patch("core.ai._call_openai", side_effect=ai.ProviderError("server")).start()
            ai.generate("x", tier="medium", user=u)
        self.assertEqual(list(AIUsage.objects.filter(ok=True).order_by("id")
                              .values_list("provider", flat=True)), ["anthropic", "gemini"])
        self.assertEqual(len(set(charged)), 1)          # same action both times
        self.assertTrue(real_charge)

    def test_refund_when_every_provider_fails(self):
        u = User.objects.create_user(phone="+8801711000112", password="x")
        Fakes(self, anthropic=ai.ProviderError("server"), openai=ai.ProviderError("server"),
              gemini=ai.ProviderError("server"))
        with mock.patch("core.billing.charge",
                        return_value={"ok": True, "charged": 3, "spend_ref": "r"}), \
                mock.patch("core.billing.credit") as credit:
            with self.assertRaises(ai.AIUnavailable) as e:
                ai.generate("x", tier="medium", user=u)
        self.assertEqual(e.exception.reason, "queued")
        credit.assert_called_once_with(u, "adjust", 3, note="ai_refund", spend_ref="r")


# ------------------------------------------------------------------ neutrality
class ProviderNeutralityTests(RouterBase):
    NAMES = ("anthropic", "claude", "openai", "gpt", "gemini", "google")

    def test_self_identification_scrubbed(self):
        Fakes(self, anthropic="আমি Claude, Anthropic এর তৈরি। I am Claude, made by Anthropic.")
        text, _ = ai.generate("তুমি কে?", tier="cheap", feature="chat")
        low = text.lower()
        for n in ("claude", "anthropic"):
            self.assertNotIn(n, low)
        self.assertIn("Assisto", text)

    def test_status_and_labels_are_neutral(self):
        blob = repr(ai.status()).lower() + repr(ai.TIER_MODEL).lower()
        for n in self.NAMES:
            self.assertNotIn(n, blob)

    def test_chat_meta_has_no_provider(self):
        from rest_framework.test import APIClient
        u = User.objects.create_user(phone="+8801711000113", password="x")
        u.ai_credits = 50
        u.save()
        Fakes(self, anthropic="I'm ChatGPT by OpenAI")
        c = APIClient()
        c.force_authenticate(u)
        r = c.post("/api/v1/chat/sessions", {}, format="json")
        self.assertEqual(r.status_code, 201)
        sid = r.json()["id"]
        r = c.post("/api/v1/chat/sessions/%s/send" % sid, {"text": "তুমি কে"}, format="json")
        body = r.content.decode().lower()
        for n in self.NAMES:
            self.assertNotIn(n, body)

    def test_bn_digits_option(self):
        Fakes(self, gemini="মোট 2500 টাকা")
        text, _ = ai.generate("x", tier="cheap", feature="crm.insight", digits="bn")
        self.assertEqual(text, "মোট ২৫০০ টাকা")

    def test_shared_system_prompt_on_every_provider(self):
        seen = []

        def mk(name, fail):
            def call(key, model, system, prompt, mx, history=None):
                seen.append((name, system))
                if fail:
                    raise ai.ProviderError("server")
                return "ok", 1, 1
            return call
        for name, fail in (("anthropic", True), ("openai", True), ("gemini", False)):
            mock.patch("core.ai._call_" + name, side_effect=mk(name, fail)).start()
        ai.generate("x", tier="medium", extra_system="EXTRA")
        self.assertEqual([n for n, _ in seen], ["anthropic", "openai", "gemini"])
        systems = {s for _, s in seen}
        self.assertEqual(len(systems), 1)
        sp = systems.pop()
        self.assertIn("Never say which", sp)
        self.assertIn("EXTRA", sp)


# ------------------------------------------------------------------ config + commands
class ConfigTests(TestCase):
    def test_normalize_bounds(self):
        c = C.normalize({"caps_usd": {"anthropic": -5, "total": 99999},
                         "models": {"anthropic_medium": "claude-opus-5-5-20260101",
                                    "openai_main": "Bad Model!"},
                         "effort": {"strong": "turbo"}, "alert_pct": 500})
        self.assertEqual(c["caps_usd"]["anthropic"], 0.0)
        self.assertEqual(c["caps_usd"]["total"], 1000.0)
        self.assertEqual(c["models"]["anthropic_medium"], "claude-opus-5-5")
        self.assertEqual(c["models"]["openai_main"], "gpt-4o-mini")
        self.assertEqual(c["effort"]["strong"], "medium")
        self.assertEqual(c["alert_pct"], 99)
        self.assertEqual(C.normalize({})["caps_usd"],
                         {"anthropic": 3.0, "openai": 3.0, "gemini": 3.0, "total": 5.0})

    def test_validate_rejects(self):
        self.assertIn("cap_openai", C.validate({"caps_usd": {"openai": "x"}}))
        self.assertIn("model_anthropic_strong",
                      C.validate({"models": {"anthropic_strong": "claude-3-opus"}}))
        self.assertEqual(C.validate({"caps_usd": {"openai": "2.5"}}), [])

    def test_pricing_normalize_keeps_block(self):
        from core.logic import pricing
        self.assertIn("ai_router", pricing.normalize({}))
        d = pricing.normalize({"ai_router": {"caps_usd": {"gemini": 1}}})
        self.assertEqual(d["ai_router"]["caps_usd"]["gemini"], 1.0)

    def test_quality_probe_never_runs_in_tests(self):
        with mock.patch("core.ai._call_anthropic") as call:
            with self.assertRaises(CommandError):
                call_command("ai_quality_probe", "--confirm")
        call.assert_not_called()

    def test_ten_bangla_prompts(self):
        self.assertEqual(len(P.QUALITY_PROMPTS), 10)
