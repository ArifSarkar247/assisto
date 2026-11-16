"""emailrel (16 Nov; runs inside `manage.py minute_jobs`, no own cron line):
read Gmail bounce reports over IMAP and put dead addresses on the email
suppression list (core/email_bounces.py). `--tick` = at most every 15 min and
only when the email entry is connected; plain run = one pass now."""
from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Email bounce reports (IMAP) -> suppression list."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")
        parser.add_argument("--tick", action="store_true", help="gated: every 15 min")

    @track_job("email_bounces")
    def handle(self, *args, **opts):
        from core import email_bounces as EB
        res = EB.tick() if opts.get("tick") else EB.poll()
        if res is not None and not opts.get("quiet"):
            self.stdout.write("email_bounces: %s" % res.get("detail", ""))
