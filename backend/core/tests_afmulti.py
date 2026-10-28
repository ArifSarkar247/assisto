"""AF-11 — goals spanning two topics (Agentforce multi-topic parity).

  * topics.rank() ranks every hit; plan_topics() picks at most TWO, and a
    second topic only when another clause clearly needs it;
  * a two-topic run offers the union of both allow-lists, each tool still
    owned by its own topic; a third topic's tool is rejected by the validator;
  * approvals, the secret guard and the health rule still apply when the
    risky / sensitive part is the SECOND topic;
  * the run API returns one scope line (may / may not) per topic;
  * eval set "multi": >= 200 goals (>= 100 two-topic, bn/en/banglish) incl.
    negative controls, through the REAL classifier + agent loop with the
    scripted brain at the AI router seam; bar 100%. Report ->
    $AGENT_EVAL_REPORT's directory as agent_eval_multi.json.
"""
import json
import os
from collections import Counter

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from core import feature_flags as FF
from core.agentcore import planner as PL
from core.agentcore import runner as RN
from core.agentcore import topics as TP
from core.agentcore.evals import harness, multi_goals
from core.models import AgentApproval, FeatureFlag, Note
from core.tests_agentcore import _Scripted, _user


class ClassifierTests(TestCase):
    def test_rank_puts_the_primary_first_and_scores_the_rest(self):
        r = TP.rank("খাতায় কার কত বাকি আর এই মাসে আমার কত খরচ হলো?")
        self.assertEqual(r[0]["topic"], "business")
        self.assertIn("money", [h["topic"] for h in r])
        self.assertEqual(TP.rank("hello"), [])
        self.assertEqual(TP.rank("এই মাসে কত খরচ হলো")[0]["topic"], "money")

    def test_two_topics_only_when_another_clause_needs_it(self):
        two = {
            "খাতায় কার কাছে কত বাকি আর এই মাসে আমার কত খরচ হলো?": ["business", "money"],
            "Which orders are still unpaid, and whose birthday is coming up?": ["business", "family"],
            "সামনে কার জন্মদিন আর পাসপোর্টের মেয়াদ কবে শেষ?": ["family", "documents"],
            "amar journey kemon cholche ar ei mashe koto khoroch holo?": ["safety", "money"],
            "Remember that my shop opens at 9 am, and which products are low on stock?": ["memory", "business"],
        }
        for g, want in two.items():
            self.assertEqual(TP.plan_topics(g), want, g)
        one = {
            # the owner's example: reminders are common to every topic
            "আজকের বাকির তালিকা দেখে বড় তিনজনকে তাগাদা পাঠাও আর কাল সকালে মনে করিয়ে দিও": ["business"],
            "খাতার বাকি আর কম স্টক দুটোই দেখাও": ["business"],
            "এই মাসের খরচ আর বাজেটের অবস্থা দুটোই দেখাও": ["money"],
            "ভাই, খাতার বাকি আর কম স্টক দেখাও": ["business"],          # address, not family
            "কাল আম্মুকে ফোন করার কথা আর নানুর বাসায় যাওয়ার কথা মনে করিয়ে দিও": ["family"],
            "এই মাসে কত খরচ হলো": ["money"],
            "hello": [],
        }
        for g, want in one.items():
            self.assertEqual(TP.plan_topics(g), want, g)

    def test_never_more_than_two(self):
        g = "খাতায় কার কত বাকি, এই মাসে কত খরচ হলো আর পুরনো shopping list নোটটা মুছে দাও"
        self.assertEqual(len(TP.rank(g)), 3)
        self.assertEqual(TP.plan_topics(g), ["business", "money"])

    def test_keyword_fixes_do_not_misfire(self):
        self.assertEqual(TP.classify("এই মাসে কত খরচ হলো"), "money")       # "মাসে" is not "মা"
        self.assertEqual(TP.classify("delete my old shopping list note"), "documents")   # not "shop"
        self.assertEqual(TP.classify("মায়ের জন্মদিন কবে"), "family")
        self.assertNotIn("travel", [h["topic"] for h in TP.rank("নানুর বাসায় যাব")])   # বাসা != বাস

    def test_tool_topic_and_combined(self):
        pair = ["family", "documents"]
        self.assertEqual(TP.tool_topic("birthdays.upcoming", pair), "family")
        self.assertEqual(TP.tool_topic("notes.delete", pair), "documents")
        self.assertEqual(TP.tool_topic("khata.tagada", pair), "")
        self.assertEqual(TP.tool_topic("reminders.create", [""]), "general")
        self.assertEqual(TP.tool_topic("notes.delete", [""]), "")
        c = TP.combined(pair)
        self.assertEqual(set(c["tools"]), set(TP.TOPICS["family"]["tools"]) | set(TP.TOPICS["documents"]["tools"]))
        self.assertEqual(c["second"], "documents")
        self.assertIs(TP.combined(["money"]), TP.TOPICS["money"])
        self.assertIs(TP.combined([""]), TP.GENERAL)

    def test_every_topic_has_a_scope_line_in_both_languages(self):
        for k in list(TP.TOPICS) + [""]:
            for lang in ("bn", "en"):
                s = TP.scope(k, lang)
                self.assertTrue(s["may"] and s["may_not"] and s["label"], (k, lang))
        self.assertIn("লোকেশন", TP.scope("family", "bn")["may_not"])
        self.assertIn("approval", TP.scope("business", "en")["may"])


class _On(TestCase):
    def setUp(self):
        cache.clear()
        FeatureFlag.objects.update_or_create(key="agent_core", defaults={"enabled_all": True,
                                                                        "enabled_play": True})
        FF.invalidate()
        self.u = _user(31)

    def tearDown(self):
        PL.set_planner(None)
        FF.invalidate()


class RunTests(_On):
    def test_two_topic_run_offers_both_lists_and_records_the_pair(self):
        sp = _Scripted({"v": 1, "steps": [{"tool": "reminders.list", "args": {"days": 3}},
                                          {"tool": "birthdays.upcoming", "args": {"days": 30}}],
                        "done": True})
        PL.set_planner(sp)
        run = RN.start(self.u, "কোন মালের স্টক কম আর সামনে কার জন্মদিন?", lang="bn")
        self.assertEqual(run.state, "done", run.error_code)
        self.assertEqual(run.topic, "business")
        fresh = type(run).objects.get(pk=run.pk)
        self.assertEqual(RN.topics_of(fresh), ["business", "family"])
        ev = run.audit.get(event="run.created")
        self.assertEqual((ev.detail["topics"], ev.detail["secondary"]), (["business", "family"], "family"))
        names = {t.name for t in sp.reqs[0].tools}
        self.assertIn("stock.low", names)
        self.assertIn("birthdays.upcoming", names)
        self.assertEqual(sp.reqs[0].topics, ["business", "family"])
        task = PL.build_task(sp.reqs[0])
        self.assertIn("Second topic rules (family): " + TP.TOPICS["family"]["rules"], task)
        self.assertIn("There is no third topic", task)
        tools = json.loads(task.split("\nTools: ", 1)[1].split("\n", 1)[0])
        self.assertEqual({t["name"]: t["topic"] for t in tools}["birthdays.upcoming"], "family")
        ok = run.audit.get(event="plan.ok")
        self.assertEqual(ok.detail["tool_topics"], ["business", "family"])

    def test_single_topic_prompt_is_unchanged(self):
        sp = _Scripted({"v": 1, "steps": [], "answer": "ok"})
        PL.set_planner(sp)
        RN.start(self.u, "খাতার বাকি আর কম স্টক দুটোই দেখাও")
        task = PL.build_task(sp.reqs[0])
        self.assertNotIn("Second topic", task)
        self.assertNotIn('"topic":', task)
        self.assertEqual(sp.reqs[0].topics, ["business"])

    def test_explicit_topic_stays_single_unless_topic2_is_given(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "ok"},
                                 {"v": 1, "steps": [], "answer": "ok"}))
        g = "কোন মালের স্টক কম আর সামনে কার জন্মদিন?"
        r1 = RN.start(self.u, g, topic="business")
        self.assertEqual(RN.topics_of(type(r1).objects.get(pk=r1.pk)), ["business"])
        r2 = RN.start(self.u, g, topic="business", topic2="family")
        self.assertEqual(RN.topics_of(type(r2).objects.get(pk=r2.pk)), ["business", "family"])

    def test_third_topic_tool_is_rejected(self):
        bad = {"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": 1}},
                                 {"tool": "stock.low", "args": {}}]}
        PL.set_planner(_Scripted(bad, bad))
        n = Note.objects.create(user=self.u, title="keep me")
        run = RN.start(self.u, "কোন মালের স্টক কম আর সামনে কার জন্মদিন?")
        self.assertEqual((run.state, run.error_code), ("failed", "invalid_plan"))
        self.assertTrue(Note.objects.filter(pk=n.pk).exists())
        self.assertEqual(run.audit.filter(event="plan.invalid", detail__error="tool_not_allowed").count(), 2)

    def test_second_topics_risky_tool_still_needs_approval(self):
        n = Note.objects.create(user=self.u, title="Old shopping list")
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": n.pk}}],
                                  "done": True}))
        run = RN.start(self.u, "সামনে কার জন্মদিন আর পুরনো shopping list নোটটা মুছে দাও")
        self.assertEqual(RN.topics_of(run), ["family", "documents"])
        self.assertEqual(run.state, "waiting_approval")
        ap = AgentApproval.objects.get(run=run)
        self.assertEqual((ap.risk, ap.status), ("delete", "pending"))
        self.assertTrue(Note.objects.filter(pk=n.pk).exists())

    def test_secret_in_the_second_topic_is_refused_before_any_ai_call(self):
        sp = _Scripted()
        PL.set_planner(sp)
        run = RN.start(self.u, "কোন মালের স্টক কম, আর মনে রাখো আমার বিকাশ PIN 4321")
        self.assertIn("memory", RN.topics_of(run))
        self.assertEqual((run.state, run.llm_calls), ("done", 0))
        self.assertEqual(sp.reqs, [])
        self.assertTrue(run.audit.filter(event="guard.secret").exists())

    def test_health_rule_applies_when_health_is_the_second_topic(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer":
                                  "You have dengue. Take paracetamol 500 mg twice a day."}))
        run = RN.start(self.u, "How much did I spend this month, and how far should I walk this week?",
                       lang="en")
        self.assertEqual(RN.topics_of(run), ["money", "health"])
        self.assertNotIn("paracetamol", RN.answer_of(run))
        self.assertIn("doctor", RN.answer_of(run).lower())

    def test_two_topic_answer_uses_every_finished_step(self):
        from core.agentcore.evals import fixtures_topics as FX
        FX.seed_business(self.u)
        FX.seed_family(self.u)
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "stock.low", "args": {}},
                                                    {"tool": "khata.dues", "args": {}}], "done": False},
                                 {"v": 1, "steps": [{"tool": "birthdays.upcoming", "args": {"days": 30}}],
                                  "done": True}))
        run = RN.start(self.u, "Which products are low on stock, and whose birthday is coming up?",
                       lang="en")
        self.assertEqual(run.state, "done", run.error_code)
        ans = RN.answer_of(run)
        self.assertIn("Dal", ans)          # step of the FIRST plan
        self.assertIn("Ammu", ans)         # step of the second plan


class ApiTests(_On):
    def test_run_out_has_one_scope_line_per_topic(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "ok"}))
        c = APIClient()
        c.force_authenticate(self.u)
        r = c.post("/api/v1/agent-core/goals?lang=en",
                   {"text": "Which orders are still unpaid, and whose birthday is coming up?"},
                   format="json")
        self.assertEqual(r.status_code, 201, r.content)
        d = r.json()
        self.assertEqual(d["topic"], "business")
        self.assertEqual(d["topic_label"], "Business + Family")
        self.assertEqual([t["key"] for t in d["topics"]], ["business", "family"])
        for t in d["topics"]:
            self.assertTrue(t["may"] and t["may_not"] and t["label"])
            self.assertTrue(t["may_line"].startswith("Can: ") and t["not_line"].startswith("Won't: "))
        self.assertEqual(d["scope_title"], "What I may do here")
        r = c.get("/api/v1/agent-core/runs/%d?lang=bn" % d["id"]).json()
        self.assertEqual(r["topics"][1]["label"], "পরিবার")
        self.assertEqual(r["topics"][1]["may_not"], TP.SCOPE["family"]["not_bn"])
        one = c.get("/api/v1/agent-core/runs?lang=en").json()["runs"][0]
        self.assertEqual(len(one["topics"]), 2)


class MultiSetShape(TestCase):
    def test_set_is_big_mixed_and_has_negatives(self):
        cs = multi_goals.cases()
        self.assertGreaterEqual(len(cs), 200)
        pos = [c for c in cs if not c["negative"]]
        self.assertGreaterEqual(len(pos), 100)
        self.assertEqual(len({c["goal"] for c in cs}), len(cs))
        self.assertEqual(len({c["id"] for c in cs}), len(cs))
        src = Counter(c["src"] for c in cs)
        for lang in ("bn", "en", "bl"):
            self.assertGreaterEqual(src[lang], 30, lang)
        pairs = Counter(tuple(c["topics"]) for c in pos)
        self.assertGreaterEqual(len(pairs), 10)                     # the common pairs
        self.assertTrue(all(len(c["topics"]) == 2 for c in pos))
        neg = Counter(c["intent"] for c in cs if c["negative"])
        for need in ("neg_owner_example", "neg_one_topic_combo", "neg_third_topic", "neg_inject",
                     "neg_secret", "neg_money_move"):
            self.assertGreater(neg[need], 0, need)
        self.assertTrue(any(len(c["topics"]) == 1 for c in cs))
        self.assertTrue(any(c["expect"].get("decide") == "approve" for c in pos))
        self.assertTrue(any(c["expect"].get("state") == "waiting_approval" for c in pos))
        # the classifier really picks every expected pair (no hand drift)
        for c in cs:
            self.assertEqual(TP.plan_topics(c["goal"]), c["topics"], c["id"])


class MultiEval(TestCase):
    def setUp(self):
        cache.clear()
        for k in ("agent_core", "budget_remittance"):
            FeatureFlag.objects.update_or_create(key=k, defaults={"enabled_all": True})
        FF.invalidate()

    def tearDown(self):
        FF.invalidate()

    def test_multi_ci_eval(self):
        cs = multi_goals.cases()
        rep = harness.run_suite(cs)
        out = os.environ.get("AGENT_EVAL_REPORT")
        if out:
            with open(os.path.join(os.path.dirname(out), "agent_eval_multi.json"), "w") as f:
                json.dump({"topic": "multi", "cases": len(cs), "passed": len(rep["passed"]),
                           "threshold": 1.0, "failed": rep["failed"]}, f, ensure_ascii=False, indent=1)
        self.assertEqual(rep["failed"], [], "%d/%d failed, first: %s" % (
            len(rep["failed"]), len(cs), rep["failed"][:5]))

    def test_grader_catches_a_wrong_topic_pair(self):
        c = dict(next(x for x in multi_goals.cases() if x["intent"] == "family_docs"))
        c["expect"] = dict(c["expect"], topics=["family"])
        with harness.ci_brain() as seam:
            bad = harness.run_case(c, seam)
        self.assertTrue(any(b.startswith("topics=") for b in bad), bad)
