"""agent-core TESTING CENTER, WP-TOOLS-A/B: the >= 200-goal eval sets for
family, safety, documents, travel, health, learning and business
(core/agentcore/evals/<topic>.jsonl) run through the REAL agent loop with the
scripted brain at the AI router's provider seam, graded deterministically
(exact tool set, forbidden tools, seeded numbers in the answer, no raw PII to
the provider, credits = ledger, approvals required for external tools,
injection refused). Bar: goalsets.THRESHOLDS (CI mode 100%). Per-topic report
-> $AGENT_EVAL_REPORT's directory as agent_eval_<topic>.json."""
import json
import os
from collections import Counter
from unittest import mock

from django.core.cache import cache
from django.test import TestCase

from core import feature_flags as FF
from core.agentcore.contract import APPROVAL_RISKS
from core.agentcore.evals import build_goalsets as B
from core.agentcore.evals import goalsets as G
from core.agentcore.evals import harness
from core.models import FeatureFlag


class GoalSetShape(TestCase):
    def test_committed_jsonl_matches_the_builder(self):
        for t in G.TOPICS:
            with open(os.path.join(G.HERE, "%s.jsonl" % t), encoding="utf-8") as f:
                self.assertEqual(f.read(), B.render(t), "%s.jsonl is stale: run build_goalsets" % t)

    def test_each_set_is_big_mixed_and_adversarial(self):
        for t in G.TOPICS:
            cs = G.load(t)
            self.assertGreaterEqual(len(cs), 200, t)
            self.assertEqual(len({c["goal"] for c in cs}), len(cs), t)
            self.assertEqual(len({c["id"] for c in cs}), len(cs), t)
            src = Counter(c["src"] for c in cs)
            for lang in ("bn", "en", "bl"):
                self.assertGreaterEqual(src[lang], 14, (t, lang))
            intents = Counter(c["intent"] for c in cs)
            for need in ("injection", "pii"):
                self.assertGreater(intents[need], 0, (t, need))
            self.assertTrue(any(c["expect"].get("no_tools") for c in cs), t)
            self.assertTrue(all(not v.startswith("$") for c in cs for v in c["expect"]["answer_has"]))
        biz = G.load("business")
        for tool in ("khata.tagada", "orders.cod_confirm", "bizagent.reply"):
            self.assertTrue(any(c["expect"].get("approval") == tool for c in biz), tool)
        self.assertTrue(any(c["expect"].get("decide") == "reject" for c in biz))
        self.assertTrue(any(c["expect"].get("state") == "waiting_approval" for c in biz))


class _Eval(TestCase):
    def setUp(self):
        cache.clear()
        for k in ("agent_core", "budget_remittance"):
            FeatureFlag.objects.update_or_create(key=k, defaults={"enabled_all": True})
        FF.invalidate()

    def tearDown(self):
        FF.invalidate()

    def run_topic(self, topic):
        cs = G.load(topic)
        rep = harness.run_suite(cs)
        out = os.environ.get("AGENT_EVAL_REPORT")
        if out:
            path = os.path.join(os.path.dirname(out), "agent_eval_%s.json" % topic)
            with open(path, "w") as f:
                json.dump({"topic": topic, "cases": len(cs), "passed": len(rep["passed"]),
                           "threshold": G.THRESHOLDS[topic], "failed": rep["failed"]},
                          f, ensure_ascii=False, indent=1)
        rate = len(rep["passed"]) / float(len(cs))
        self.assertGreaterEqual(rate, G.THRESHOLDS[topic],
                                "%s: %d/%d failed, first: %s" % (topic, len(rep["failed"]), len(cs),
                                                                  rep["failed"][:5]))


class FamilyEval(_Eval):
    def test_family_ci_eval(self):
        self.run_topic("family")


class SafetyEval(_Eval):
    def test_safety_ci_eval(self):
        self.run_topic("safety")


class DocumentsEval(_Eval):
    def test_documents_ci_eval(self):
        self.run_topic("documents")


class TravelEval(_Eval):
    def test_travel_ci_eval(self):
        self.run_topic("travel")


class HealthEval(_Eval):
    def test_health_ci_eval(self):
        self.run_topic("health")


class LearningEval(_Eval):
    def test_learning_ci_eval(self):
        self.run_topic("learning")


class BusinessEval(_Eval):
    def test_business_ci_eval(self):
        self.run_topic("business")


class TopicGraderControls(_Eval):
    """Negative controls: the new graders must FAIL a bad agent."""
    def _case(self, topic, intent):
        return next(c for c in G.load(topic) if c["intent"] == intent)

    def test_external_tool_without_approval_is_caught(self):
        from core.agentcore import contract as C
        c = self._case("business", "tagada_wa")
        with mock.patch.object(C.Tool, "needs_approval", property(lambda self: False)):
            rep = harness.run_suite([dict(c, expect=dict(c["expect"], decide=None))])
        reasons = " ".join(r for _, rs in rep["failed"] for r in rs)
        self.assertIn("ran without an approved card", reasons)
        self.assertIn("external", APPROVAL_RISKS)

    def test_brain_that_ignores_the_doctor_rule_fails(self):
        c = self._case("health", "medical")
        lazy = {"v": 1, "steps": [], "done": True, "answer": "Take two tablets."}
        with mock.patch("core.agentcore.evals.topic_brain.think", return_value=lazy):
            rep = harness.run_suite([c])
        self.assertEqual(len(rep["failed"]), 1)
        self.assertIn("answer missing", " ".join(rep["failed"][0][1]))

    def test_effect_graders_check_the_database(self):
        c = self._case("business", "reply_ok")
        bad = dict(c, expect=dict(c["expect"], stock={"Tel 1L": 999}))
        rep = harness.run_suite([bad])
        self.assertIn("stock Tel 1L", " ".join(r for _, rs in rep["failed"] for r in rs))
