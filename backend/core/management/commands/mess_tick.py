"""messv2: Mess and bachelor V2 upkeep inside `manage.py minute_jobs` (no own
cron line). From 20:00 Dhaka it reminds tomorrow's bazar-turn holder once
(push inside Assisto; free, no SMS). Idle minutes = one indexed query."""
from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Mess V2: night-before bazar turn reminders."
    requires_system_checks = []

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("mess_tick")
    def handle(self, *args, **opts):
        from core.views_mess import turn_reminders
        n = turn_reminders()
        if not opts.get("quiet") or n:
            self.stdout.write("mess_tick: %d reminder(s)" % n)
