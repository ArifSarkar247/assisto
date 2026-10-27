"""p4-world: send job alerts (title + link only) from the Careerjet publisher
API to users who switched alerts on for chosen job types. Capped per user per
day (admin-editable world.job_alerts_per_day, default 1). Does nothing until
the owner connects Integrations → jobs_careerjet.

Crontab (deploy/p4-world/world.cron):
    30 9 * * * cd /home/ubuntu/assisto/backend && \
        /home/ubuntu/assisto/.venv/bin/python manage.py world_job_alerts
"""
from django.core.management.base import BaseCommand
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Send capped Unseen World job alerts."

    @track_job("world_job_alerts")
    def handle(self, *args, **opts):
        from core import world_service
        n = world_service.run_job_alerts()
        self.stdout.write("[world_job_alerts] sent=%d ready=%s" % (n, world_service.careerjet_ready()))
