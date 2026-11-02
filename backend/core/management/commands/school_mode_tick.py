"""
school_mode_tick — Kids Watch + Child School Mode minute job (kidswatch,
owner idea 2). No WorkManager: the SERVER runs the clock-driven steps —
late-for-school / late-home checks (phone plans first ask the child
"ঠিক আছো?"), school-over (tracking on by itself), the watch battery plan
(UPLOAD interval by schedule), voice-note expiry, stale commands, position
prune and the monthly full-mode renewal. Bounded per run; never raises.
Every minute, run by `manage.py minute_jobs` (core.ops_health.MINUTE_JOBS);
the old stand-alone line below still works:

  * * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-school-mode-tick.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py school_mode_tick --quiet >> /home/ubuntu/assisto/logs/school_mode_tick.log 2>&1
"""
import json

from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "School mode: late checks, school-over, watch battery plan, voice expiry."
    requires_system_checks = []   # per-minute job (see minute_jobs)

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("school_mode_tick")
    def handle(self, *args, **options):
        from core.kidswatch_service import tick
        out = tick()
        if not options.get("quiet"):
            self.stdout.write("school_mode_tick: " + json.dumps(out, sort_keys=True))
