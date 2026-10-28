"""Agent Core worker tick (cron, every minute, like bizagent_process):
resume queued runs whose lease is free and expire runs past their deadline.

  * * * * * cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py agent_core_run

Does nothing for users whose `agent_core` flag is off.
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Advance queued Assisto agent runs (one tick, <= 50 s)."

    def add_arguments(self, p):
        p.add_argument("--limit", type=int, default=20)
        p.add_argument("--seconds", type=float, default=50.0)

    def handle(self, *a, **o):
        from core.agentcore import runner
        n = runner.tick(limit=o["limit"], time_budget_s=o["seconds"])
        self.stdout.write("agent_core_run: advanced %d run(s)" % n)
