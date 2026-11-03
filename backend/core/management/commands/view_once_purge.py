"""viewonce (runs inside `manage.py minute_jobs`, no own cron line) — delete
the server copy of view-once photos / videos / voice messages:
  * 15 min after the LAST recipient opened (the signed link handed out at
    the open can finish), and
  * unopened ones after `circle_media_view_once_days` (default 14, Owner
    Admin pricing limits).
Cheap: an indexed filter on view_once with a server copy left. Idempotent."""
from django.core.management.base import BaseCommand

from core import e_gaps
from core.ops_health import track_job


class Command(BaseCommand):
    help = "Delete the server copy of opened / 14-day-old view-once media."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("view_once_purge")
    def handle(self, *args, **opts):
        out = e_gaps.purge_view_once()
        if not opts.get("quiet"):
            self.stdout.write("opened %(opened)d expired %(expired)d" % out)
