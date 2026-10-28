"""veh100 — vehicle reminder pushes (core/vehicle100.sweep_reminders):
BRTA tax token / fitness / insurance / route permit expiry (30 / 7 / 1 days),
maintenance due by km (server odometer, or the owner's manual reading) or by
date, and driver licence expiry. 1 push per user per Dhaka day (several due
items share it); quiet hours 21:00-09:00; at-most-once per item + stage
(UNIQUE VehicleReminderClaim). Skips cleanly when push is not configured.

Crontab (hourly at :35):
    35 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-vehicle-reminders.lock nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py vehicle_reminders --quiet >> /home/ubuntu/assisto/logs/vehicle_reminders.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Vehicle papers / maintenance / licence reminder pushes (capped; quiet hours)."

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true",
                            help="print only when something happened")

    @track_job("vehicle_reminders")
    def handle(self, *args, **opts):
        from core import push, vehicle100
        if not push.is_available():
            if not opts.get("quiet"):
                self.stdout.write("vehicle_reminders: push unavailable (no key) - skipped")
            return
        stats = vehicle100.sweep_reminders()
        busy = {k: v for k, v in stats.items() if v}
        if busy or not opts.get("quiet"):
            self.stdout.write("%s vehicle_reminders %s" % (
                timezone.now().isoformat(timespec="seconds"),
                " ".join("%s=%s" % kv for kv in sorted(busy.items())) or "idle"))
