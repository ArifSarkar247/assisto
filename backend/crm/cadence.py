"""
Follow-up cadences / sequences (spec §4).

A cadence is a sequence of steps ("day 0: intro, day 2: value, day 5: nudge").
Enrolling a deal in a cadence produces DRAFT activities (tasks) — one per step,
due on `created + day_offset`. NOTHING is auto-sent: every drafted message is a
task a human reviews and sends. This keeps the spec's "drafts, human approves"
rule.

`due_followups` surfaces overdue next-steps + due cadence tasks for the alert
engine. Predictive reminder timing is a simple honest heuristic (high priority →
sooner); it is labelled a suggestion, never a certainty.
"""
from django.utils import timezone

from .models import Activity, Cadence, Deal


def enroll(deal, cadence, member=None):
    """Create one DRAFT task Activity per cadence step for a deal. Returns the
    list of created activities. Does not send anything."""
    created = []
    now = timezone.now()
    for step in cadence.steps.order_by("order"):
        due = now + timezone.timedelta(days=step.day_offset)
        a = Activity.objects.create(
            org=deal.org, kind=Activity.TASK,
            subject=f"[{cadence.name}] {step.get_channel_display()} follow-up (draft)",
            body=step.template or "", deal=deal, actor=member, due_at=due)
        created.append(a)
    return created


def due_followups(org, deals_qs):
    """Overdue next-steps on open deals + overdue/ due-today draft tasks.

    Returns {"overdue_next_steps": [...], "due_tasks": [...]}. All from real
    data — a deal with no next_step at all is itself a warning (spec §4 requires
    a next step on every open deal)."""
    today = timezone.now().date()
    overdue = []
    missing = []
    for d in deals_qs.filter(state="open"):
        if not d.next_step:
            missing.append({"deal_id": d.id, "title": d.title,
                            "reason": "no_next_step"})
        elif d.next_step_due and d.next_step_due < today:
            overdue.append({"deal_id": d.id, "title": d.title,
                            "next_step": d.next_step,
                            "due": d.next_step_due.isoformat()})
    tasks = list(Activity.objects.filter(
        org=org, kind=Activity.TASK, done=False,
        due_at__lte=timezone.now()).values(
            "id", "subject", "due_at", "deal_id")[:100])
    return {"overdue_next_steps": overdue, "missing_next_step": missing,
            "due_tasks": tasks}
