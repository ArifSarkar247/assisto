"""AF-6 — `manage.py agent_eval --live` is BUILT, never run here: no key, no
spend. These tests drive the live code path with the scripted brain at the
AI router's provider seam (core.ai._call_anthropic / _call_openai) to prove:
the refusals (no budget, budget <= 0, above the configured max, CI, no key,
unknown topic), the estimate makes no call, the hard cap (the worst case of
every call is checked BEFORE it is made; it stops at the cap and never
spends past it), the rollback (no eval user / run survives) with the real
spend booked again as eval.agent.<topic>, nothing sent, the per-model
scorecard + comparison and the report files."""
import json
import os
import tempfile
from io import StringIO
from unittest import mock

from django.core.cache import cache
from django.core.management import CommandError, call_command
from django.test import TestCase, override_settings

from core import feature_flags as FF
from core.agentcore import planner as PL
from core.agentcore.evals import live as L
from core.agentcore.evals.scripted_brain import ProviderSeam
from core.models import AgentRun, AIUsage, FeatureFlag, SmsLog, User


class _Seam(ProviderSeam):
    """Scripted brain that reports token counts like a real provider."""
    def __init__(self, scale=1):
        super().__init__()
        self.scale = scale

    def __call__(self, key, model, system, prompt, max_tokens, history=None):
        from core.ai_evals.runner import est_tokens
        text, _, _ = super().__call__(key, model, system, prompt, max_tokens, history)
        return text, est_tokens(system + prompt) * self.scale, 120 * self.scale


def _no_ci():
    p = mock.patch.dict(os.environ, {})
    p.start()
    os.environ.pop("CI", None)
    os.environ.pop("GITHUB_ACTIONS", None)
    return p


class _Base(TestCase):
    def setUp(self):
        cache.clear()
        for k in ("agent_core", "budget_remittance"):
            FeatureFlag.objects.update_or_create(key=k, defaults={"enabled_all": True})
        FF.invalidate()
        self.env = _no_ci()
        self.addCleanup(self.env.stop)
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        PL.set_planner(None)
        FF.invalidate()

    def seam(self, providers=(("anthropic", "test-key"),), scale=1):
        s = _Seam(scale)
        for p in (mock.patch("core.ai._providers", return_value=list(providers)),
                  mock.patch("core.ai._call_anthropic", side_effect=s),
                  mock.patch("core.ai._call_openai", side_effect=s)):
            p.start()
            self.addCleanup(p.stop)
        return s

    def cmd(self, *args):
        out = StringIO()
        call_command("agent_eval", *args, stdout=out)
        return out.getvalue()


class Refusals(_Base):
    def test_refuses_without_an_explicit_budget(self):
        s = self.seam()
        for args in ((), ("--budget-usd", "0"), ("--budget-usd", "-1")):
            with self.assertRaisesRegex(CommandError, "budget-usd"):
                self.cmd("--live", "--topic", "business", *args)
        self.assertEqual(s.prompts, [])

    @override_settings(AGENT_EVAL_MAX_USD=5)
    def test_refuses_above_the_configured_max(self):
        s = self.seam()
        with self.assertRaisesRegex(CommandError, "above the configured maximum"):
            self.cmd("--live", "--topic", "business", "--budget-usd", "6")
        self.assertEqual(s.prompts, [])
        self.assertEqual(L.max_budget(), 5.0)

    def test_default_max_is_ten_dollars(self):
        self.assertEqual(L.max_budget(), L.DEFAULT_MAX_USD)
        with self.assertRaisesRegex(CommandError, "above the configured maximum"):
            self.seam()
            self.cmd("--live", "--topic", "business", "--budget-usd", "10.01")

    def test_refuses_in_ci(self):
        s = self.seam()
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            with self.assertRaisesRegex(CommandError, "never run in CI"):
                self.cmd("--live", "--topic", "business", "--budget-usd", "1")
            with self.assertRaisesRegex(CommandError, "never run in CI"):
                self.cmd("--live", "--topic", "business", "--estimate")
        self.assertEqual(s.prompts, [])

    def test_refuses_without_a_key_and_unknown_topic(self):
        with mock.patch("core.ai._providers", return_value=[]):
            with self.assertRaisesRegex(CommandError, "no AI provider key"):
                self.cmd("--live", "--topic", "business", "--budget-usd", "1")
        with self.assertRaisesRegex(CommandError, "unknown topic"):
            self.cmd("--live", "--topic", "weather", "--budget-usd", "1")

    def test_estimate_calls_nothing(self):
        s = self.seam(providers=(("anthropic", "k"), ("openai", "k")))
        out = self.cmd("--live", "--topic", "business", "--limit", "10", "--estimate")
        self.assertIn("estimate anthropic/", out)
        self.assertIn("estimate openai/", out)
        self.assertEqual(s.prompts, [])
        self.assertFalse(AIUsage.objects.exists())


class LiveRun(_Base):
    def test_scorecard_rollback_booking_and_report(self):
        s = self.seam()
        users0, runs0 = User.objects.count(), AgentRun.objects.count()
        out = self.cmd("--live", "--topic", "business", "--limit", "6", "--budget-usd", "5",
                       "--out", self.tmp)
        self.assertIn("6/6 passed", out)
        self.assertGreater(len(s.prompts), 0)
        # every case was rolled back: no eval user, run or seed data stays
        self.assertEqual((User.objects.count(), AgentRun.objects.count()), (users0, runs0))
        self.assertFalse(SmsLog.objects.exists())
        files = sorted(os.listdir(self.tmp))
        self.assertEqual(len(files), 2)
        rep = json.load(open(os.path.join(self.tmp, [f for f in files if f.endswith(".json")][0])))
        m = rep["models"][0]
        self.assertEqual((rep["topic"], m["provider"], m["ran"], m["passed"]), ("business", "anthropic", 6, 6))
        self.assertFalse(rep["stopped"])
        self.assertLessEqual(rep["spent_usd"], 5)
        self.assertGreater(rep["spent_usd"], 0)
        # the real spend is booked again (router caps / owner cost pages see it)
        booked = AIUsage.objects.filter(feature="eval.agent.business", user=None)
        self.assertEqual(booked.count(), rep["llm_calls"])
        self.assertAlmostEqual(sum(u.cost_usd for u in booked), rep["spent_usd"], places=5)
        md = open(os.path.join(self.tmp, [f for f in files if f.endswith(".md")][0])).read()
        self.assertIn("| anthropic/", md)

    def test_hard_cap_stops_before_the_call_that_could_pass_it(self):
        self.seam(scale=3)
        worst = L.worst_call_usd("x" * 4000, "anthropic")
        budget = round(worst * 3, 6)
        rep = L.run("business", budget_usd=budget, models=[("anthropic", "m")])
        self.assertTrue(rep["stopped"])
        self.assertGreater(rep["spent_usd"], 0)
        self.assertLessEqual(rep["spent_usd"], budget)            # never past the cap
        self.assertLess(rep["models"][0]["ran"], len(L.load_cases("business")))
        self.assertIsNotNone(rep["models"][0]["stopped_at"])

    def test_budget_below_one_worst_call_makes_no_call(self):
        s = self.seam()
        rep = L.run("business", budget_usd=1e-9, models=[("anthropic", "m")], cases=L.load_cases("business")[:3])
        self.assertEqual((rep["llm_calls"], rep["spent_usd"], rep["stopped"]), (0, 0.0, True))
        self.assertEqual(s.prompts, [])

    def test_each_call_is_checked_against_the_worst_case(self):
        self.seam()
        seen = []
        real = L.worst_call_usd

        def spy(prompt, provider=None):
            seen.append(provider)
            return real(prompt, provider)
        with mock.patch.object(L, "worst_call_usd", side_effect=spy):
            rep = L.run("business", budget_usd=1.0, models=[("anthropic", "m")],
                        cases=L.load_cases("business")[:4])
        self.assertEqual(len(seen), rep["llm_calls"])           # one check per call, before it
        self.assertTrue(all(p == "anthropic" for p in seen))

    def test_two_models_scorecard_and_comparison(self):
        s = self.seam(providers=(("anthropic", "k"), ("openai", "k")))
        out = self.cmd("--live", "--topic", "money", "--limit", "3", "--budget-usd", "3", "--out", self.tmp)
        self.assertIn("Model comparison", out)
        rep = json.load(open(os.path.join(self.tmp, [f for f in os.listdir(self.tmp)
                                                     if f.endswith(".json")][0])))
        self.assertEqual([m["provider"] for m in rep["models"]], ["anthropic", "openai"])
        self.assertTrue(all(m["ran"] == 3 for m in rep["models"]))
        used = set(AIUsage.objects.filter(feature="eval.agent.money").values_list("provider", flat=True))
        self.assertEqual(used, {"anthropic", "openai"})        # each pass pinned to its provider
        self.assertGreater(len(s.prompts), 0)
        self.assertEqual([m[0] for m in L.configured_models(["openai"])], ["openai"])
        out = self.cmd("--live", "--topic", "money", "--limit", "2", "--budget-usd", "1",
                       "--models", "openai", "--out", self.tmp)
        self.assertIn("openai/", out)
        self.assertNotIn("Model comparison", out)

    def test_nothing_is_sent_even_when_a_case_approves_an_sms(self):
        self.seam()
        cs = [c for c in L.load_cases("business") if c["intent"] == "tagada_sms_approve"][:1]
        with mock.patch("core.sms_gateway.active", return_value=["fake"]):
            rep = L.run("business", budget_usd=2, models=[("anthropic", "m")], cases=cs)
        self.assertEqual(rep["models"][0]["passed"], 1, rep["models"][0]["failed"])
        self.assertFalse(SmsLog.objects.filter(status="sent").exists())


class ScriptedMode(_Base):
    def test_scripted_mode_is_free_and_rolled_back(self):
        users0 = User.objects.count()
        out = self.cmd("--topic", "multi", "--limit", "8")
        self.assertIn("8/8 passed", out)
        self.assertEqual(User.objects.count(), users0)
        self.assertFalse(AIUsage.objects.filter(feature__startswith="eval.agent").exists())
