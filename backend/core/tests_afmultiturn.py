"""AF-18 — multi-turn conversations: follow_up links a goal to the user's
previous run (own, finished, recent, not a crisis); a goal with no topic of
its own keeps that run's topic; the planner sees up to two earlier turns,
MASKED, inside the DATA fence; "undo that" takes back the previous turn's
own-data writes with no AI call (a sent message is honestly NOT undone).
Eval set "multiturn": >= 50 three-turn conversations per topic, 100%."""
import json
import os
from collections import Counter
from datetime import timedelta

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import feature_flags as FF
from core.agentcore import planner as PL
from core.agentcore import runner as RN
from core.agentcore import undo as UN
from core.agentcore.evals import multiturn
from core.models import AgentRun, FeatureFlag, Reminder
from core.tests_agentcore import _Scripted, _user


def _rem(text):
    due = (timezone.localtime() + timedelta(days=1)).replace(hour=9, minute=0, second=0, microsecond=0)
    return {"v": 1, "steps": [{"tool": "reminders.create", "args": {"title": text, "due_at": due.isoformat()}}],
            "done": True}


class _On(TestCase):
    def setUp(self):
        cache.clear()
        FeatureFlag.objects.update_or_create(key="agent_core", defaults={"enabled_all": True,
                                                                        "enabled_play": True})
        FF.invalidate()
        self.u = _user(51, credits=200)
        self.other = _user(52)

    def tearDown(self):
        PL.set_planner(None)
        FF.invalidate()


class FollowUpTests(_On):
    def test_follow_up_links_inherits_topic_and_shows_masked_previous_turns(self):
        sp = _Scripted({"v": 1, "steps": [], "answer": "ok, noted"}, {"v": 1, "steps": [], "answer": "ok"})
        PL.set_planner(sp)
        r1 = RN.start(self.u, "এই মাসে কত খরচ হলো? আমার নম্বর 01711223344")
        r2 = RN.start(self.u, "আর গত মাসে?", follow_up=r1.pk)
        self.assertEqual(r2.topic, "money")                       # no topic of its own -> kept
        self.assertEqual(RN.follow_up_of(r2), r1.pk)
        req = sp.reqs[1]
        self.assertEqual(len(req.previous), 1)
        self.assertIn("⟦PHONE_", req.previous[0]["goal"])
        data = PL.build_data(req)
        self.assertNotIn("01711223344", data)
        self.assertIn("previous_turns", data)
        self.assertIn("data.previous_turns", PL.build_task(req))
        self.assertNotIn("previous_turns", PL.build_data(sp.reqs[0]))   # first turn: none
        self.assertNotIn("data.previous_turns", PL.build_task(sp.reqs[0]))

    def test_two_previous_turns_at_most_oldest_first(self):
        sp = _Scripted(*[{"v": 1, "steps": [], "answer": "a%d" % i} for i in range(4)])
        PL.set_planner(sp)
        prev = None
        for g in ("এই মাসে কত খরচ হলো?", "আর গত মাসে?", "আর বাজেট?", "আবার বলো"):
            prev = RN.start(self.u, g, follow_up=prev.pk if prev else None, channel="eval")
        p = sp.reqs[3].previous
        self.assertEqual([t["goal"] for t in p], ["আর গত মাসে?", "আর বাজেট?"])

    def test_follow_up_is_ignored_when_not_allowed(self):
        PL.set_planner(_Scripted(*[{"v": 1, "steps": [], "answer": "ok"}] * 5))
        theirs = RN.start(self.other, "এই মাসে কত খরচ হলো?")
        r = RN.start(self.u, "আর গত মাসে?", follow_up=theirs.pk)
        self.assertIsNone(RN.follow_up_of(r))                       # not your run
        mine = RN.start(self.u, "এই মাসে কত খরচ হলো?", channel="eval")
        AgentRun.objects.filter(pk=mine.pk).update(finished_at=timezone.now() - timedelta(hours=3))
        r = RN.start(self.u, "আর গত মাসে?", follow_up=mine.pk, channel="eval")
        self.assertIsNone(RN.follow_up_of(r))                       # too old
        crisis = RN.start(self.u, "আমি আত্মহত্যা করব", channel="eval")
        r = RN.start(self.u, "আর গত মাসে?", follow_up=crisis.pk, channel="eval")
        self.assertIsNone(RN.follow_up_of(r))                       # never continues a crisis
        r = RN.start(self.u, "x", follow_up="nope", channel="eval")
        self.assertIsNone(RN.follow_up_of(r))

    def test_api_follow_up(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "ok"}, {"v": 1, "steps": [], "answer": "ok"}))
        c = APIClient()
        c.force_authenticate(self.u)
        d1 = c.post("/api/v1/agent-core/goals", {"text": "এই মাসে কত খরচ হলো?"}, format="json").json()
        d2 = c.post("/api/v1/agent-core/goals", {"text": "আর গত মাসে?", "follow_up": d1["id"]},
                    format="json").json()
        self.assertEqual((d1["follow_up"], d2["follow_up"], d2["topic"]), (None, d1["id"], "money"))


class UndoTests(_On):
    def test_strict_undo_phrases(self):
        for t in ("undo that", "Undo that.", "ওটা বাতিল করো", "undo kore dao", "আগেরটা ফিরিয়ে নাও",
                  "please undo"):
            self.assertTrue(UN.is_undo(t), t)
        for t in ("COD অর্ডারটা বাতিল করো", "cancel my order", "undo the payment to Karim and send more",
                  "বাতিল", ""):
            self.assertFalse(UN.is_undo(t), t)

    def test_undo_a_reminder_no_ai_then_already_undone(self):
        sp = _Scripted(_rem("Pay rent"))
        PL.set_planner(sp)
        r1 = RN.start(self.u, "কাল বাসাভাড়া দিতে মনে করিয়ে দিও", topic="money", lang="en")
        self.assertTrue(Reminder.objects.filter(user=self.u, title="Pay rent").exists())
        r2 = RN.start(self.u, "undo that", follow_up=r1.pk, lang="en")
        self.assertEqual((r2.state, r2.llm_calls, r2.credits_spent), ("done", 0, 0))
        self.assertEqual(len(sp.reqs), 1)                            # no planner call for the undo
        self.assertFalse(Reminder.objects.filter(user=self.u, title="Pay rent").exists())
        self.assertIn("Undone", RN.answer_of(r2))
        self.assertTrue(r1.audit.filter(event="undo.done").exists())
        r3 = RN.start(self.u, "undo that", follow_up=r1.pk, lang="en")
        self.assertIn("already undone", RN.answer_of(r3))
        r4 = RN.start(self.u, "undo that", follow_up=r2.pk, lang="en")          # no redo
        self.assertIn("Nothing to undo", RN.answer_of(r4))

    def test_undo_only_touches_what_the_agent_made(self):
        mine = Reminder.objects.create(user=self.u, title="Pay rent", due_at=timezone.now() + timedelta(days=2))
        PL.set_planner(_Scripted(_rem("Pay rent")))
        r1 = RN.start(self.u, "remind me tomorrow to pay rent", topic="money", lang="en")
        RN.start(self.u, "undo that", follow_up=r1.pk, lang="en")
        self.assertTrue(Reminder.objects.filter(pk=mine.pk).exists())       # the user's own one stays
        self.assertEqual(Reminder.objects.filter(user=self.u).count(), 1)

    def test_undo_without_follow_up_is_a_normal_goal(self):
        sp = _Scripted({"v": 1, "steps": [], "answer": "What should I undo?"})
        PL.set_planner(sp)
        r = RN.start(self.u, "undo that", lang="en")
        self.assertEqual(len(sp.reqs), 1)
        self.assertFalse(r.audit.filter(event="undo.result").exists())


class MultiTurnShape(TestCase):
    def test_set_shape(self):
        cs = multiturn.cases()
        per = Counter(c["topic"] for c in cs)
        for t in multiturn.TOPICS:
            self.assertGreaterEqual(per[t], 50, t)
        self.assertTrue(all(len(c["turns"]) == 3 for c in cs))
        self.assertEqual(len({c["id"] for c in cs}), len(cs))
        langs = Counter(c["src"] for c in cs)
        for lang in ("bn", "en", "bl"):
            self.assertGreaterEqual(langs[lang], 100, lang)
        kinds = Counter(c["kind"] for c in cs)
        for k in ("follow_again", "correction", "undo_nothing", "undo_reminder", "undo_last_only",
                  "undo_money_log", "follow_last_month", "pronoun_tagada", "undo_stock", "sos_again"):
            self.assertGreater(kinds[k], 0, k)


class MultiTurnEval(TestCase):
    def setUp(self):
        cache.clear()
        for k in ("agent_core", "budget_remittance"):
            FeatureFlag.objects.update_or_create(key=k, defaults={"enabled_all": True})
        FF.invalidate()

    def tearDown(self):
        FF.invalidate()

    def test_multiturn_ci_eval(self):
        cs = multiturn.cases()
        rep = multiturn.run_suite(cs)
        out = os.environ.get("AGENT_EVAL_REPORT")
        if out:
            with open(os.path.join(os.path.dirname(out), "agent_eval_multiturn.json"), "w") as f:
                json.dump({"topic": "multiturn", "cases": len(cs), "passed": len(rep["passed"]),
                           "threshold": 1.0, "failed": rep["failed"]}, f, ensure_ascii=False, indent=1)
        self.assertEqual(rep["failed"], [], "%d/%d failed, first: %s" % (
            len(rep["failed"]), len(cs), rep["failed"][:5]))

    def test_end_state_grader_catches_a_missing_undo(self):
        c = next(x for x in multiturn.cases() if x["kind"] == "undo_reminder")
        c = dict(c, turns=[c["turns"][0], dict(c["turns"][2])])        # no undo turn
        from core.agentcore.evals.harness import ci_brain
        with ci_brain() as seam:
            bad = multiturn.run_conv(c, seam)
        self.assertTrue(any(b.startswith("end: reminder not undone") for b in bad), bad)
