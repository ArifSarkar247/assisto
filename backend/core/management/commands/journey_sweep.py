"""journey100 — Safe Journey sweeper (core/journey_watch.sweep).

Every minute: overdue -> "Are you OK?" -> watchers alerted; undelivered
journey events re-sent; prolonged stop / off route / signal lost; wellness
checks; overdue safe-arrival check-ins (family100: via core/family_alerts —
consent, audit, quiet hours); held family alerts released after the
recipient's quiet hours; routine reminders; privacy purge of
expired journeys (points, last location, ride photo).

Idempotent (JourneyEvent is unique per journey+kind+key) and safe to overlap
with itself — flock in the cron line keeps it to one at a time anyway.

Crontab (every minute):
    * * * * *  cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-journey-sweep.lock /home/ubuntu/assisto/.venv/bin/python manage.py journey_sweep --quiet >> /home/ubuntu/assisto/logs/journey_sweep.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Safe Journey sweeper: overdue/wellness/stop/route/signal alerts + privacy purge."

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true",
                            help="print only when something happened")

    @track_job("journey_sweep")
    def handle(self, *args, **opts):
        from core import journey_watch
        stats = journey_watch.sweep()
        busy = {k: v for k, v in stats.items() if v}
        if busy or not opts.get("quiet"):
            self.stdout.write("%s journey_sweep %s" % (
                timezone.now().isoformat(timespec="seconds"),
                " ".join("%s=%s" % kv for kv in sorted(busy.items())) or "idle"))
