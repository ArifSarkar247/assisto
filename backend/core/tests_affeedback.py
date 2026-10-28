"""AF-12 — feedback -> test cases: a thumbs-down (masked note) on an agent run
becomes a candidate eval case in the Owner Admin review queue; the owner
approves with the expected behaviour; `manage.py agent_eval_export_feedback`
appends it (once) to evals/feedback/<topic>.jsonl; nothing un-masked is ever
stored or written; the exported case runs through the real eval harness."""
import json
import os
import tempfile
from io import StringIO

from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import views as CV
from core.agentcore import feedback_cases as FB
from core.agentcore import planner as PL
from core.agentcore import runner as RN
from core.agentcore import topics as TP
from core.agentcore import trust as T
from core.agentcore.evals import harness
from core.models import FeatureFlag, OwnerAudit, PaCollectionItem
from core.tests_agentcore import _Scripted, _user
from web.tests_o2_owner_admin import OwnerBase, SClient


class _On(TestCase):
    def setUp(self):
        cache.clear()
        for k in ("agent_core", "budget_remittance"):
            FeatureFlag.objects.update_or_create(key=k, defaults={"enabled_all": True,
                                                                "enabled_play": True})
        FF.invalidate()
        self.u = _user(41)
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def tearDown(self):
        PL.set_planner(None)
        FF.invalidate()

    def run_goal(self, text, raw=None):
        PL.set_planner(_Scripted(raw or {"v": 1, "steps": [], "answer": "ok"}))
        r = self.c.post("/api/v1/agent-core/goals?lang=bn", {"text": text}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["id"]

    def thumb(self, rid, value, note=""):
        r = self.c.post("/api/v1/agent-core/runs/%d/feedback" % rid, {"value": value, "note": note},
                        format="json")
        self.assertEqual(r.status_code, 200, r.content)


class CandidateTests(_On):
    def test_thumbs_down_creates_one_masked_candidate(self):
        rid = self.run_goal("Karim-এর নম্বর 01811223344, খাতায় কার কত বাকি?")
        self.thumb(rid, -1, "ভুল উত্তর, আমাকে 01712345678 নম্বরে জানাও, NID 1234567890123")
        self.thumb(rid, -1, "আবার ভুল, 01712345678")              # same run -> same row
        rows = list(PaCollectionItem.objects.filter(collection=FB.COLLECTION))
        self.assertEqual(len(rows), 1)
        d = rows[0].data
        blob = json.dumps(d, ensure_ascii=False)
        for raw in ("01811223344", "01712345678", "1234567890123"):
            self.assertNotIn(raw, blob)
        self.assertFalse(T.has_raw_pii(blob))
        self.assertIn("⟦PHONE_", d["goal"])
        self.assertIn("⟦PHONE_", d["note"])
        self.assertEqual((d["status"], d["run_id"], d["topic"], d["lang"]), ("pending", rid, "business", "bn"))
        self.assertEqual(rows[0].user_id, self.u.pk)

    def test_thumbs_up_withdraws_and_down_again_reopens(self):
        rid = self.run_goal("খাতায় কার কত বাকি?")
        self.thumb(rid, -1)
        self.thumb(rid, 1)
        row = PaCollectionItem.objects.get(collection=FB.COLLECTION)
        self.assertEqual(row.data["status"], "withdrawn")
        self.thumb(rid, -1, "still wrong")
        row.refresh_from_db()
        self.assertEqual(row.data["status"], "pending")

    def test_thumbs_up_alone_creates_nothing_and_crisis_never(self):
        rid = self.run_goal("খাতায় কার কত বাকি?")
        self.thumb(rid, 1)
        self.assertFalse(PaCollectionItem.objects.filter(collection=FB.COLLECTION).exists())
        rid = self.run_goal("আমি আত্মহত্যা করব")
        self.thumb(rid, -1, "bad")
        self.assertFalse(PaCollectionItem.objects.filter(collection=FB.COLLECTION).exists())

    def test_queue_is_not_reachable_through_any_user_collection_api(self):
        self.assertNotIn(FB.COLLECTION, CV.GENERIC_COLLECTIONS)
        self.assertLessEqual(len(FB.COLLECTION), 24)

    def test_decision_validation(self):
        cand = {"topic": "business", "topics": ["business"]}
        ok = {"tools": ["khata.dues"], "forbid": ["notes.delete"], "state": "done", "expected": "dues only"}
        clean, probs = FB.validate_decision(cand, ok)
        self.assertEqual(probs, [])
        self.assertEqual(clean["expect_tools"], ["khata.dues"])
        for bad, why in (({"tools": ["birthdays.upcoming"]}, "tool_not_in_topic"),
                         ({}, "no_expectation"),
                         ({"tools": ["khata.dues"], "no_tools": "1"}, "tools_and_none"),
                         ({"tools": ["khata.dues"], "forbid": ["khata.dues"]}, "tool_both"),
                         ({"no_tools": "1", "state": "weird"}, "bad_state"),
                         ({"no_tools": "1", "forbid": ["nope.tool"]}, "unknown_tool")):
            self.assertIn(why, FB.validate_decision(cand, bad)[1], bad)
        # a raw number in the owner's note is masked; the note is still kept
        clean, probs = FB.validate_decision(cand, dict(ok, expected="call 01711111111"))
        self.assertEqual(probs, [])
        self.assertNotIn("01711111111", clean["expected"])
        # two-topic candidates accept either topic's tools
        two = {"topic": "business", "topics": ["business", "family"]}
        self.assertEqual(FB.validate_decision(two, {"tools": ["birthdays.upcoming"]})[1], [])


class ExportTests(_On):
    def _approved(self, goal, tools, **kw):
        rid = self.run_goal(goal)
        self.thumb(rid, -1, "should have listed dues")
        row = PaCollectionItem.objects.get(collection=FB.COLLECTION, data__run_id=rid)
        clean, probs = FB.validate_decision(row.data, dict({"tools": tools, "state": "done"}, **kw))
        self.assertEqual(probs, [])
        FB.decide(row, "approve", clean)
        return rid

    def test_export_is_masked_idempotent_and_runs_in_the_harness(self):
        rid = self._approved("খাতায় কার কাছে কত বাকি?", ["khata.dues"])
        rejected = self.run_goal("কোন মালের স্টক কম?")
        self.thumb(rejected, -1)
        FB.decide(PaCollectionItem.objects.get(data__run_id=rejected), "reject")
        with tempfile.TemporaryDirectory() as d:
            out = StringIO()
            call_command("agent_eval_export_feedback", "--out", d, "--dry-run", stdout=out)
            self.assertIn("would write 1", out.getvalue())
            self.assertFalse(os.listdir(d))                     # dry run writes nothing
            call_command("agent_eval_export_feedback", "--out", d, stdout=StringIO())
            path = os.path.join(d, "business.jsonl")
            lines = open(path, encoding="utf-8").read().splitlines()
            self.assertEqual(len(lines), 1)
            case = json.loads(lines[0])
            self.assertEqual(case["id"], "fb-%d" % rid)
            self.assertEqual(case["expect"]["tools"], ["khata.dues"])
            self.assertFalse(T.has_raw_pii(lines[0]))
            # second export: nothing new, never duplicated
            self.assertEqual(FB.export(out_dir=d)["written"], 0)
            row = PaCollectionItem.objects.get(data__run_id=rid)
            row.data = dict(row.data, exported_at=None)            # even if re-marked
            row.save()
            r = FB.export(out_dir=d)
            self.assertEqual((r["written"], r["skipped_dupe"]), (0, 1))
            self.assertEqual(len(open(path, encoding="utf-8").read().splitlines()), 1)
            # the exported case joins the eval set: the real harness grades it
            cs = FB.load_committed("business", base=d)
            FeatureFlag.objects.update_or_create(key="agent_core", defaults={"enabled_all": True})
            FF.invalidate()
            PL.set_planner(None)
            rep = harness.run_suite(cs)
            self.assertEqual(rep["failed"], [], rep)

    def test_case_with_a_raw_number_is_never_written(self):
        rid = self._approved("খাতায় কার কাছে কত বাকি?", ["khata.dues"])
        row = PaCollectionItem.objects.get(data__run_id=rid)
        row.data = dict(row.data, goal="call 01811223344 now")     # tampered row
        row.save()
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(FB.export(out_dir=d)["written"], 0)
            self.assertFalse(os.path.exists(os.path.join(d, "business.jsonl")))


class CommittedFeedbackShape(TestCase):
    """CI: every committed feedback case is masked, unique and only expects
    tools its own topic(s) allow (it is graded for real by the live eval)."""
    def test_committed_files(self):
        base = FB.FEEDBACK_DIR
        files = [f for f in os.listdir(base) if f.endswith(".jsonl")] if os.path.isdir(base) else []
        ids = set()
        for f in files:
            for c in FB.load_committed(f[:-6]):
                self.assertNotIn(c["id"], ids)
                ids.add(c["id"])
                self.assertFalse(T.has_raw_pii(json.dumps(c, ensure_ascii=False)), c["id"])
                pair = c["expect"].get("topics") or [c["topic"] if c["topic"] != "general" else ""]
                ok = set(TP.combined(pair)["tools"])
                self.assertTrue(set(c["expect"]["tools"]) <= ok, c["id"])


class OwnerQueueTests(OwnerBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        FeatureFlag.objects.update_or_create(key="agent_core", defaults={"enabled_all": True})
        FF.invalidate()
        self.user = _user(42)
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "ok"}))
        self.run = RN.start(self.user, "খাতায় কার কাছে কত বাকি? নম্বর 01811223344")
        PL.set_planner(None)
        self.row = FB.on_feedback(self.run, -1, "wrong")
        self.ready()

    def test_queue_approve_reject_and_audit(self):
        r = self.c.get("/owner/agent-runs/feedback?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Feedback → test cases")
        self.assertContains(r, "fb-%d" % self.run.pk)
        self.assertNotContains(r, "01811223344")
        self.assertContains(r, "khata.dues")                       # the topic's tools to pick
        self.assertContains(self.c.get("/owner/agent-runs?lang=en"), "Feedback cases waiting")
        url = "/owner/agent-runs/feedback/%d" % self.row.pk
        r = self.post(url, {"action": "approve", "tools": ["birthdays.upcoming"], "state": "done"})
        self.assertIn("m=invalid", r["Location"])
        self.assertTrue(OwnerAudit.objects.filter(action="agent_feedback_case", ok=False).exists())
        r = self.post(url, {"action": "approve", "tools": ["khata.dues"], "forbid": ["khata.tagada"],
                            "state": "done", "expected": "list the dues, send nothing"})
        self.assertEqual(r.status_code, 302)
        self.row.refresh_from_db()
        self.assertEqual((self.row.data["status"], self.row.data["expect_tools"]), ("approved", ["khata.dues"]))
        self.assertTrue(OwnerAudit.objects.filter(action="agent_feedback_case", ok=True).exists())
        r = self.post(url, {"action": "reject"})
        self.row.refresh_from_db()
        self.assertEqual(self.row.data["status"], "rejected")
        self.assertIn("m=invalid", self.post(url, {"action": "bogus"})["Location"])
        self.assertEqual(self.post("/owner/agent-runs/feedback/999999", {"action": "reject"}).status_code, 404)
        self.assertContains(self.c.get("/owner/agent-runs/feedback?lang=bn"), "মতামত → টেস্ট কেস")

    def test_requires_owner(self):
        r = SClient().get("/owner/agent-runs/feedback")
        self.assertEqual((r.status_code, r["Location"]), (302, "/owner/login"))
        r = SClient().post("/owner/agent-runs/feedback/%d" % self.row.pk, {"action": "approve"})
        self.assertIn(r.status_code, (302, 403))
        self.row.refresh_from_db()
        self.assertEqual(self.row.data["status"], "pending")
