"""retention1 — the retention-automation scheduler tick. Cron every 15 min
(deploy/retention1/retention.cron). Does nothing in quiet hours (21:00-09:00
Asia/Dhaka); every send goes through core/logic/msg_guard."""
from django.core.management.base import BaseCommand
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Retention automation: send the due automated messages (capped)."

    @track_job("retention_run")
    def handle(self, *args, **opts):
        from core import retention_service as S
        st = S.run_all()
        self.stdout.write("retention_run automations=%(automations)d sent=%(sent)d "
                          "blocked=%(blocked)d" % st)
