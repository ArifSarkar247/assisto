"""agentcore (18 Nov): proactive AGENT CARDS + the trust fixes of board row 16.

  * a bill / loan due tomorrow -> the nudge carries ONE proposed reminder that
    waits for the user's tap (never automatic, one push only);
  * approve -> the reminder exists + audit; reject / dismiss -> nothing;
  * NUMBER CHECKS: a card is re-checked against the real rows before it is
    shown and again at the tap (paid / changed bill -> nothing is done);
  * the approval queue expires (sweep audited, inbox never offers an expired one);
  * the user's own audit trail (GET agent-core/activity);
  * PII is redacted in audit details and in Agent Core logs.

No AI is ever called (asserted); pushes are counted at the module seams."""
import logging
from datetime import timedelta
from unittest import mock

from django.utils import timezone
from rest_framework.test import APIClient

from core.agentcore import proactive as P
from core.agentcore import runner as RN
from core.agentcore import suggest as SG
from core.agentcore import trust as T
from core.models import (AgentApproval, AgentAuditEvent, AgentNudge, AgentNudgePrefs, AgentRun,
                         Loan, Reminder)
from core.tests_agentpro import _Base, flags, mkuser


class _Cards(_Base):
    def setUp(self):
        super().setUp()
        flags(reminders=True)
        self.u.language = "en"
        self.u.save(update_fields=["language"])
        AgentNudgePrefs.objects.create(user=self.u, quiet_start="00:00", quiet_end="00:00")
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        sp = mock.patch("core.push.safe_push", return_value=True)
        self.safe_push = sp.start()
        self.addCleanup(sp.stop)
        self.tomorrow = timezone.localdate() + timedelta(days=1)

    def loan(self, person="Karim", amount=1500, due=None, **kw):
        return Loan.objects.create(user=self.u, kind="taken", person=person, amount=amount,
                                   due_date=due or self.tomorrow, **kw)

    def tick(self):
        return P.tick(now=timezone.now(), users=[self.u])

    def nudge(self, person="Karim"):
        return AgentNudge.objects.get(user=self.u, trigger="bill_due", title_en__contains=person)

    def card(self, person="Karim"):
        r = self.c.get("/api/v1/agent-core/nudges?lang=en")
        self.assertEqual(r.status_code, 200, r.content)
        rows = [x for x in r.json()["results"] if person in x["title"]]
        return rows[0] if rows else None

    def decide(self, apid, decision):
        return self.c.post("/api/v1/agent-core/approvals/%d?lang=en" % apid,
                           {"decision": decision}, format="json")

    def events(self, run_id):
        return list(AgentAuditEvent.objects.filter(run_id=run_id).order_by("id")
                    .values_list("event", flat=True))


class ProposalTests(_Cards):
    def test_bill_due_tomorrow_proposes_one_reminder_that_waits(self):
        self.loan()
        self.tick()
        n = self.nudge()
        ap = AgentApproval.objects.get(pk=n.data["approval"])
        self.assertEqual(ap.status, "pending")
        self.assertEqual(ap.step.tool, "reminders.create")
        self.assertEqual(ap.step.state, "waiting_approval")
        self.assertIn("Karim", ap.title_en)
        self.assertIn("1,500", ap.title_en)
        self.assertEqual(n.route, "agent")                      # the push opens the card
        self.assertFalse(Reminder.objects.filter(user=self.u).exists())   # never automatic
        self.assertEqual(len([x for x in self.sent if x[1] == "bill_due"]), 1)   # the nudge push ...
        self.safe_push.assert_not_called()                      # ... and no 2nd approval push
        # expires when the reminder would ring (tomorrow 09:00 local), not 48 h later
        due = timezone.localtime(ap.expires_at)
        self.assertEqual((due.date(), due.hour, due.minute), (self.tomorrow, 9, 0))
        # 0 credits, not counted against the daily run cap
        self.assertEqual(ap.run.credits_spent, 0)
        # a second tick (same stage) and a later stage never propose again
        self.tick()
        self.assertEqual(AgentApproval.objects.filter(user=self.u).count(), 1)

    def test_no_proposal_for_overdue_or_phone_reminder_bill(self):
        self.loan(person="Late", due=timezone.localdate() - timedelta(days=1))
        self.tick()
        self.assertFalse(AgentApproval.objects.filter(user=self.u).exists())
        self.assertNotIn("approval", self.nudge("Late").data)

    def test_card_shows_verified_numbers_and_pending_action(self):
        self.loan()
        self.tick()
        c = self.card()
        self.assertTrue(c["verified"])
        self.assertIn("1,500", c["body"])
        a = c["action"]
        self.assertEqual(a["status"], "pending")
        self.assertEqual(a["reminder_title"], "Repay loan: Karim — ৳1,500")
        # the same card is in the approval inbox (one queue)
        ids = [x["id"] for x in self.c.get("/api/v1/agent-core/approvals").json()["approvals"]]
        self.assertIn(a["approval_id"], ids)


class DecisionTests(_Cards):
    def test_approve_creates_the_reminder_with_audit(self):
        self.loan()
        self.tick()
        apid = self.card()["action"]["approval_id"]
        r = self.decide(apid, "approve")
        self.assertEqual(r.status_code, 200, r.content)
        rem = Reminder.objects.get(user=self.u)
        self.assertEqual(rem.title, "Repay loan: Karim — ৳1,500")
        local = timezone.localtime(rem.due_at)
        self.assertEqual((local.date(), local.hour), (self.tomorrow, 9))
        run = AgentApproval.objects.get(pk=apid).run
        run.refresh_from_db()
        self.assertEqual(run.state, "done")
        ev = self.events(run.pk)
        for e in ("run.created", "plan.ok", "approval.requested", "approval.approved", "tool.done",
                  "run.done"):
            self.assertIn(e, ev)
        a = self.card()["action"]
        self.assertEqual(a["status"], "approved")
        self.assertTrue(a["done"])
        self.assertIn("Reminder set", a["result"])
        # a second tap is idempotent: still one reminder
        self.decide(apid, "approve")
        self.assertEqual(Reminder.objects.filter(user=self.u).count(), 1)
        lines = [x["text"] for x in self.c.get("/api/v1/agent-core/activity?lang=en").json()["events"]]
        self.assertIn("You approved", lines)
        self.assertTrue(any(x.startswith("Done: Reminder set") for x in lines), lines)

    def test_reject_does_nothing_and_is_audited(self):
        self.loan(person="Sumon", amount=800)
        self.tick()
        apid = self.card("Sumon")["action"]["approval_id"]
        self.assertEqual(self.decide(apid, "reject").status_code, 200)
        self.assertFalse(Reminder.objects.filter(user=self.u).exists())
        run = AgentApproval.objects.get(pk=apid).run
        self.assertIn("approval.rejected", self.events(run.pk))
        self.assertEqual(self.card("Sumon")["action"]["status"], "rejected")
        lines = [x["text"] for x in self.c.get("/api/v1/agent-core/activity?lang=en").json()["events"]]
        self.assertIn("You rejected", lines)

    def test_dismissing_the_card_rejects_the_proposal(self):
        self.loan()
        self.tick()
        n = self.nudge()
        self.c.post("/api/v1/agent-core/nudges/%d/dismiss" % n.pk)
        self.assertEqual(AgentApproval.objects.get(pk=n.data["approval"]).status, "rejected")
        self.assertFalse(Reminder.objects.filter(user=self.u).exists())


class NumberCheckTests(_Cards):
    def test_bill_paid_before_the_tap_is_not_acted_on(self):
        ln = self.loan()
        self.tick()
        apid = self.nudge().data["approval"]
        ln.repayments = [{"amount": 1500}]
        ln.save(update_fields=["repayments"])
        self.decide(apid, "approve")
        self.assertFalse(Reminder.objects.filter(user=self.u).exists())
        ap = AgentApproval.objects.get(pk=apid)
        self.assertEqual(ap.step.error_code, "stale_data")
        self.assertIn("guard.stale", self.events(ap.run_id))

    def test_changed_amount_hides_the_card_and_expires_the_proposal(self):
        ln = self.loan()
        self.tick()
        apid = self.nudge().data["approval"]
        ln.amount = 2000
        ln.save(update_fields=["amount"])
        self.assertIsNone(self.card())                          # never shown with the old ৳1,500
        ap = AgentApproval.objects.get(pk=apid)
        self.assertEqual(ap.status, "expired")
        self.assertIn("guard.stale", self.events(ap.run_id))
        self.assertNotIn(apid, [x["id"] for x in
                                self.c.get("/api/v1/agent-core/approvals").json()["approvals"]])

    def test_still_true_needs_a_live_unpaid_row(self):
        self.assertFalse(SG.still_true(self.u, {}, timezone.now()))
        self.assertFalse(SG.still_true(self.u, {"ref": "loan:x:2026-01-01", "amount": 1}, timezone.now()))


class ExpiryTests(_Cards):
    def test_sweep_expires_audits_and_does_nothing(self):
        self.loan()
        self.tick()
        apid = self.nudge().data["approval"]
        AgentApproval.objects.filter(pk=apid).update(expires_at=timezone.now() - timedelta(minutes=1))
        # the inbox never offers it, even before the sweep
        self.assertEqual(self.c.get("/api/v1/agent-core/approvals").json()["approvals"], [])
        RN.tick()
        ap = AgentApproval.objects.get(pk=apid)
        self.assertEqual(ap.status, "expired")
        run = AgentRun.objects.get(pk=ap.run_id)
        self.assertEqual(run.state, "done")
        self.assertIn("approval.expired", self.events(run.pk))
        self.assertFalse(Reminder.objects.filter(user=self.u).exists())
        self.assertIn("nothing was done", RN.answer_of(run))
        # a late tap changes nothing
        self.decide(apid, "approve")
        self.assertFalse(Reminder.objects.filter(user=self.u).exists())


class GuardTests(_Cards):
    def test_proactive_client_id_is_reserved(self):
        self.loan()
        self.tick()
        n = self.nudge()
        run = RN.start(self.u, "hello", client_id="proactive:%d" % n.pk, inline=False)
        self.assertNotEqual(run.pk, n.data["run"])

    def test_activity_is_own_only_and_gated(self):
        self.loan()
        self.tick()
        other = mkuser(7)
        c2 = APIClient()
        c2.force_authenticate(other)
        self.assertEqual(c2.get("/api/v1/agent-core/activity").json()["events"], [])
        flags(agent_core=False)
        self.assertEqual(self.c.get("/api/v1/agent-core/activity").status_code, 403)

    def test_audit_detail_is_redacted_even_if_the_caller_forgot(self):
        self.loan()
        self.tick()
        run = AgentRun.objects.filter(user=self.u).first()
        e = T.audit(run, "test.raw", note="call 01712345678, NID 1234567890123, a@b.com")
        e.refresh_from_db()
        s = str(e.detail)
        for raw in ("01712345678", "1234567890123", "a@b.com"):
            self.assertNotIn(raw, s)
        self.assertIn("⟦PHONE⟧", s)

    def test_agent_core_logs_redact_pii_in_message_and_traceback(self):
        lg = logging.getLogger("core.agentcore.runner")
        with self.assertLogs("core.agentcore.runner", level="WARNING") as cm:
            RN.log.warning("user typed %s", "০১৭১২৩৪৫৬৭৮")
            try:
                raise ValueError("bad account 1234 5678 9012 3456")
            except ValueError:
                RN.log.exception("crash")
        self.assertIs(RN.log, lg)
        self.assertNotIn("০১৭১২৩৪৫৬৭৮", cm.output[0])
        self.assertIn("⟦PHONE⟧", cm.output[0])
        self.assertNotIn("1234 5678 9012 3456", cm.records[1].exc_text)
        self.assertIn("⟦ACCT⟧", cm.records[1].exc_text)
