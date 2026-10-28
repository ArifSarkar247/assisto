"""AF-7 — Agent Core retention sweeps (what AGENT_CORE_DESIGN_BN.md §৩.১/§৪
promises, now in code):

  * a run's VAULT (token -> real phone / NID / account / e-mail) is wiped 30
    days after the run finished;
  * the same day the run's raw sealed copies go too: the goal text, every
    step's args / result, and the answer is re-sealed in its MASKED form —
    the user's history stays readable (masked goal, masked step summaries,
    masked answer), but no raw personal value is kept;
  * the masked audit trail (AgentAuditEvent) is deleted after 12 months.

Run once a day: `manage.py agent_core_retention` (ops_health JOBS, so the
owner gets the exact cron line on System health). Idempotent and batched.
"""
from datetime import timedelta

from django.db.models import Q
from django.utils import timezone

from . import trust as T

VAULT_DAYS = 30
AUDIT_DAYS = 365
BATCH = 500


def sweep(now=None, batch=BATCH):
    """-> {"runs_wiped", "steps_wiped", "goals_wiped", "audit_deleted"}."""
    from ..models import AgentAuditEvent, AgentGoal, AgentRun, AgentStep
    now = now or timezone.now()
    cut = now - timedelta(days=VAULT_DAYS)
    out = {"runs_wiped": 0, "steps_wiped": 0, "goals_wiped": 0, "audit_deleted": 0}
    runs = list(AgentRun.objects.filter(finished_at__isnull=False, finished_at__lt=cut)
                .exclude(state__in=AgentRun.OPEN_STATES)
                .exclude(vault_sealed="")
                .select_related("goal").order_by("id")[:batch])
    for run in runs:
        vault = T.vault_of(run)
        if run.answer_sealed:
            ans = (T.unseal(run.answer_sealed) or {}).get("a") or ""
            run.answer_sealed = T.seal({"a": vault.mask(ans)}) if ans else ""
        run.vault_sealed = ""
        run.save(update_fields=["vault_sealed", "answer_sealed", "updated_at"])
        out["steps_wiped"] += AgentStep.objects.filter(run=run).filter(
            ~Q(args_sealed="") | ~Q(result_sealed="")).update(args_sealed="", result_sealed="")
        if run.goal_id and run.goal.text_sealed and not run.goal.runs.filter(
                Q(finished_at__isnull=True) | Q(finished_at__gte=cut)).exists():
            out["goals_wiped"] += AgentGoal.objects.filter(pk=run.goal_id).update(text_sealed="")
        out["runs_wiped"] += 1
    old = list(AgentAuditEvent.objects.filter(created_at__lt=now - timedelta(days=AUDIT_DAYS))
               .order_by("id").values_list("id", flat=True)[:batch * 10])
    if old:
        out["audit_deleted"] = AgentAuditEvent.objects.filter(id__in=old).delete()[0]
    return out
