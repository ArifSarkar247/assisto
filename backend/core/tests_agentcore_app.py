"""agent-core WP-APP: push kind `agent_approval` (sent when a run asks for a
one-tap approval, no details on the lock screen), the approval card fields
(what / to whom partly hidden / cost) and the credit estimate shown before a
goal runs. The planner is scripted (no AI key, no spend); push is mocked at
push.safe_push."""
import json
from unittest import mock

from django.test import override_settings
from rest_framework.test import APIClient

from core import push
from core.agentcore import approval_push as AP
from core.agentcore import planner as PL
from core.agentcore import runner as RN
from core.agentcore import trust as T
from core.agentcore import views as V
from core.models import AgentApproval, Note
from core.tests_agentcore import _FlagOn, _Scripted


def _delete_plan(note_id):
    return {"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": note_id}}], "done": True}


class PushKindTests(_FlagOn):
    def test_kind_registered_with_channel_and_ttl(self):
        self.assertIn("agent_approval", push.KINDS)
        self.assertNotIn("agent_approval", push.DATA_ONLY_KINDS)   # tray draws it on any build
        self.assertEqual(push.CHANNELS["agent_approval"], "alerts")
        self.assertEqual(push.TTL_S["agent_approval"], 86400)

    def test_approval_creation_sends_one_push_without_details(self):
        n = Note.objects.create(user=self.u, title="bank pin 01712345678")
        PL.set_planner(_Scripted(_delete_plan(n.pk)))
        with mock.patch("core.push.safe_push", return_value=True) as sp:
            run = RN.start(self.u, "delete the bank pin note", topic="documents", lang="en")
            self.assertEqual(run.state, "waiting_approval")
            # resuming the same waiting run must not push again
            RN.advance(run, lang="en")
        self.assertEqual(sp.call_count, 1)
        args, kw = sp.call_args
        ap = AgentApproval.objects.get(run=run)
        self.assertEqual(args[0], self.u)
        self.assertEqual(args[1], "agent_approval")
        data = kw["data"]
        self.assertEqual(data, {"approval_id": str(ap.pk), "run_id": str(run.pk), "risk": "delete",
                                "expires_at": ap.expires_at.isoformat(),
                                "route": "agent/approval"})
        self.assertTrue(all(isinstance(v, str) for v in data.values()))
        blob = json.dumps([args, data], ensure_ascii=False, default=str)
        self.assertNotIn("bank pin", blob)          # no step details on the lock screen
        self.assertNotIn("01712345678", blob)
        self.assertEqual(args[3], "Approval needed")
        self.assertIn("Delete a note", args[5])      # the tool's generic label only
        self.assertTrue(kw["high_priority"])

    def test_push_failure_never_breaks_the_run(self):
        n = Note.objects.create(user=self.u, title="x")
        PL.set_planner(_Scripted(_delete_plan(n.pk)))
        with mock.patch("core.push.safe_push", side_effect=RuntimeError("fcm down")):
            run = RN.start(self.u, "delete x", topic="documents", lang="en")
        self.assertEqual(run.state, "waiting_approval")
        self.assertEqual(AgentApproval.objects.filter(run=run).count(), 1)

    def test_payload_per_risk_and_not_for_decided(self):
        n = Note.objects.create(user=self.u, title="y")
        PL.set_planner(_Scripted(_delete_plan(n.pk)))
        with mock.patch("core.push.safe_push", return_value=True):
            run = RN.start(self.u, "delete y", topic="documents", lang="en")
        ap = AgentApproval.objects.get(run=run)
        tbn, ten, bbn, ben, data = AP.payload(ap, mock.Mock(label_bn="নোট মুছুন", label_en="Delete a note"))
        self.assertEqual(ten, "Approval needed")
        self.assertIn("Delete a note", ben)
        self.assertIn("নোট মুছুন", bbn)
        ap.status = "approved"
        with mock.patch("core.push.safe_push") as sp:
            self.assertFalse(AP.notify(ap, None))
        sp.assert_not_called()

    @override_settings(PUSH_SYNC=True)
    def test_push_to_user_builds_alerts_notification_with_collapse(self):
        from core.models import Device
        Device.objects.create(user=self.u, push_token="tok-1")
        sent = {}

        def fake_send(tok, payload, notification, **kw):
            sent.update(payload=payload, notification=notification, **kw)
            return True
        with mock.patch("core.push.is_available", return_value=True), \
                mock.patch("core.push.send_to_token", side_effect=fake_send):
            n = push.push_to_user(self.u, "agent_approval", "অনুমোদন দরকার", "Approval needed",
                                  "b", "b", data={"approval_id": "7", "route": "agent/approval"},
                                  high_priority=True)
        self.assertEqual(n, 1)
        self.assertEqual(sent["payload"]["kind"], "agent_approval")
        self.assertEqual(sent["payload"]["channel"], "alerts")
        self.assertEqual(sent["android_channel"], "alerts")
        self.assertEqual(sent["collapse_key"], "agentap-7")
        self.assertIsNotNone(sent["notification"])            # tray-drawn, not data-only


class ApprovalCardApiTests(_FlagOn):
    def setUp(self):
        super().setUp()
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_card_shows_what_cost_goal_and_partly_hidden_numbers(self):
        n = Note.objects.create(user=self.u, title="groceries")
        PL.set_planner(_Scripted(_delete_plan(n.pk)))
        with mock.patch("core.push.safe_push", return_value=True):
            r = self.c.post("/api/v1/agent-core/goals?lang=en",
                            {"text": "delete groceries note", "topic": "documents"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        ap = self.c.get("/api/v1/agent-core/approvals?lang=en").json()["approvals"][0]
        self.assertEqual(ap["tool"], "notes.delete")
        self.assertTrue(ap["tool_label"])
        self.assertEqual(ap["credits"], 0)
        self.assertEqual(ap["goal"], "delete groceries note")
        self.assertEqual(ap["details"], [{"key": "id", "value": str(n.pk)}])
        self.assertIn("groceries", ap["title"])

    def test_partial_masking_helpers(self):
        self.assertEqual(V._partial("PHONE", "+8801712345678"), "880•••••678")
        self.assertEqual(V._partial("PHONE", "01712345678"), "017•••••678")
        self.assertEqual(V._partial("ACCT", "1234 5678 9012 3456"), "••••3456")
        self.assertEqual(V._partial("NID", "1234567890"), "••••7890")
        self.assertEqual(V._partial("EMAIL", "rahim@mail.com"), "r•••@mail.com")
        vault = T.Vault()
        masked = vault.mask("send to 01712345678")
        ap = mock.Mock()
        ap.step.args_sealed = T.seal({"a": {"to": masked, "amount": 500}})
        out = V._ap_details(ap, vault)
        self.assertEqual(out, [{"key": "to", "value": "send to 017•••••678"},
                               {"key": "amount", "value": "500"}])
        self.assertNotIn("12345", json.dumps(out))

    def test_estimate_before_running(self):
        d = self.c.get("/api/v1/agent-core/tools").json()
        e = d["estimate"]
        self.assertEqual(set(e), {"plan_credits", "typical_credits", "max_credits",
                                  "runs_per_day", "runs_left_today"})
        lim = RN.limits_for(self.u)
        self.assertEqual(e["max_credits"], lim["credits"])
        self.assertEqual(e["runs_left_today"], lim["runs_per_day"])
        self.assertGreaterEqual(e["plan_credits"], 1)
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "ok"}))
        self.c.post("/api/v1/agent-core/goals", {"text": "hi", "topic": "money"}, format="json")
        e2 = self.c.get("/api/v1/agent-core/tools").json()["estimate"]
        self.assertEqual(e2["runs_left_today"], lim["runs_per_day"] - 1)
