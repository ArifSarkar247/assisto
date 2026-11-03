"""aifinal PART 2 (runs inside `manage.py minute_jobs`, no own cron line):
delete AI usage log rows older than 90 days. Cheap: an indexed created_at
filter, at most 5000 rows per run. Idempotent."""
from django.core.management.base import BaseCommand

from core import ai_usage_log
from core.ops_health import track_job


class Command(BaseCommand):
    help = "Delete AI usage log rows older than 90 days."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("ai_usage_purge")
    def handle(self, *args, **opts):
        n = ai_usage_log.purge()
        if not opts.get("quiet"):
            self.stdout.write("deleted %d" % n)
