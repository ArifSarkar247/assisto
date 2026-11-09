"""carecall (runs inside `manage.py minute_jobs`, no own cron line) — Care
Call ring ladder: materialise due slots, ring (push), retry after 10 min,
tell the setter after two unanswered rings (core.carecall.tick). Cheap:
indexed filters on next_at / due_at; idle = three empty queries."""
from django.core.management.base import BaseCommand

from core import carecall
from core.ops_health import track_job


class Command(BaseCommand):
    help = "Care Call: ring due slots, retry unanswered, tell the setter."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("carecall_tick")
    def handle(self, *args, **opts):
        out = carecall.tick()
        if not opts.get("quiet"):
            self.stdout.write("made %(made)d rang %(rang)d missed %(missed)d "
                              "escalated %(escalated)d skipped %(skipped)d" % out)
