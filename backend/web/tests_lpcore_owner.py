"""lpcore: Owner Admin -> Language content review queue (list, approve,
reject, re-check, edit as a new version; audited; bn/en). Sample data only."""
import json

from core import lp_service as LS
from core.models import LpItem, LpReviewLog, OwnerAudit
from web.tests_o2_owner_admin import OwnerBase


def _q(answer):
    return {"section": "reading", "q": {
        "n": 1, "type": "gap", "prompt": "The ferry leaves from the ____.", "answer": answer,
        "max_words": 2, "tag": "detail", "explain_en": "Line 3 names the ghat.",
        "explain_bn": "৩ নম্বর লাইনে ঘাটের নাম আছে।"}}


class LpReviewOwnerTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.good, _ = LS.upsert("question", "own-q-good", _q(["Sadarghat"]), "ielts_ac")
        self.bad, _ = LS.upsert("question", "own-q-bad", _q([]), "ielts_ac")
        self.ready()

    def test_queue_lists_items_with_check_results(self):
        r = self.c.get("/owner/lp?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "own-q-good")
        self.assertContains(r, "no answer key")
        self.assertContains(r, "Waiting for review")
        r = self.c.get("/owner/lp?lang=bn&status=bogus&kind=question")
        self.assertContains(r, "ভাষা কনটেন্ট")

    def test_approve_reject_audited(self):
        r = self.post("/owner/lp/%d/act" % self.good.pk, {"action": "approve"})
        self.assertEqual(r.status_code, 302)
        self.good.refresh_from_db()
        self.assertEqual(self.good.status, "human_approved")
        self.assertTrue(OwnerAudit.objects.filter(action="lp_item.approve").exists())
        self.assertTrue(LpReviewLog.objects.filter(item=self.good, action="approve").exists())
        r = self.post("/owner/lp/%d/act" % self.bad.pk, {"action": "approve"})
        self.assertIn("m=invalid", r["Location"])
        self.bad.refresh_from_db()
        self.assertEqual(self.bad.status, "draft")
        self.post("/owner/lp/%d/act" % self.bad.pk, {"action": "reject", "note": "no key"})
        self.bad.refresh_from_db()
        self.assertEqual(self.bad.status, "rejected")

    def test_edit_saves_new_version(self):
        r = self.post("/owner/lp/%d/act" % self.bad.pk,
                      {"action": "edit", "data": json.dumps(_q(["Sadarghat ghat"]))})
        self.assertEqual(r.status_code, 302)
        rows = LpItem.objects.filter(key="own-q-bad").order_by("version")
        self.assertEqual([x.version for x in rows], [1, 2])
        self.assertEqual(rows[1].status, "human_approved")
        r = self.post("/owner/lp/%d/act" % self.bad.pk, {"action": "edit", "data": "{not json"})
        self.assertIn("m=invalid", r["Location"])

    def test_needs_owner_session(self):
        from web.tests_o2_owner_admin import SClient
        r = SClient().get("/owner/lp")
        self.assertEqual(r.status_code, 302)
