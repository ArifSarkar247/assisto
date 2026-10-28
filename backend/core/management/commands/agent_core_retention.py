"""AF-7 — Agent Core retention (daily): wipe a finished run's vault + raw
sealed copies 30 days after it finished (the history stays readable in masked
form) and delete audit events older than 12 months. core/agentcore/retention.py

Crontab (/etc/cron.d/assisto, daily 03:50):
    50 3 * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-agent-core-retention.lock nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py agent_core_retention >> /home/ubuntu/assisto/backend/logs/agent_core_retention.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Agent Core retention: vault 30 days after a run, audit 12 months."

    @track_job("agent_core_retention")
    def handle(self, *args, **opts):
        from core.agentcore import retention
        st = retention.sweep()
        self.stdout.write("%s agent_core_retention %s" % (
            timezone.now().isoformat(timespec="seconds"),
            " ".join("%s=%s" % kv for kv in sorted(st.items()))))
