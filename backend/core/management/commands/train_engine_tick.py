"""train-engine (runs inside `manage.py minute_jobs`, no own cron line):
delete raw rider points, trips, observations and check-ins older than 24 h
(bounded batches) and refresh the live state of trains with fresh riders /
reports. Idle = two indexed reads. Idempotent."""
from django.core.management.base import BaseCommand

from core import train_engine
from core.ops_health import track_job


class Command(BaseCommand):
    help = "Train live engine: 24 h purge + live-state refresh."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("train_engine_tick")
    def handle(self, *args, **opts):
        out = train_engine.tick()
        if not opts.get("quiet"):
            self.stdout.write(" ".join("%s=%s" % kv for kv in sorted(out.items())))
