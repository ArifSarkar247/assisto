"""geminioff (runs inside `manage.py minute_jobs`, no own cron line): the
Gemini breaker's daily check. Idle (breaker closed, or the 24 h not over) =
one indexed read, no request. See core/gemini_breaker.py."""
from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Gemini breaker: one check a day while Gemini is off (402)."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("gemini_probe")
    def handle(self, *args, **opts):
        from core import gemini_breaker as GB
        out = GB.daily_probe()
        if not opts.get("quiet") or out not in ("closed", "waiting"):
            self.stdout.write("gemini_probe: %s" % out)
