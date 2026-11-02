"""Agent Core worker tick: resume queued runs whose lease is free and expire
runs past their deadline (core.agentcore.runner.tick).

Scheduled by `manage.py minute_jobs` (core.ops_health.MINUTE_JOBS, LAST in
the list with a 20 s budget so a slow agent run never delays the safety jobs
before it) — no cron line of its own (flagprep, 2 Nov). Manual use:

  cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py agent_core_run

Flag-gated: runs of users whose `agent_core` flag is off are never advanced;
with no open run at all it returns after one indexed query (no runner import).
"""
from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Advance queued Assisto agent runs (one tick, <= 50 s)."
    requires_system_checks = []   # per-minute job (runs inside minute_jobs)

    def add_arguments(self, p):
        p.add_argument("--limit", type=int, default=20)
        p.add_argument("--seconds", type=float, default=50.0)

    @track_job("agent_core_run")
    def handle(self, *a, **o):
        from core.models import AgentRun
        if not AgentRun.objects.filter(state__in=AgentRun.OPEN_STATES).exists():
            self.stdout.write("agent_core_run: idle")
            return
        from core.agentcore import runner
        n = runner.tick(limit=o["limit"], time_budget_s=o["seconds"])
        self.stdout.write("agent_core_run: advanced %d run(s)" % n)
