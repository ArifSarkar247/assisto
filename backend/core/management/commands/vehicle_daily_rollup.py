"""veh100 — roll the last 2 COMPLETE Dhaka days of every tracker into
VehicleDailyStat (vehicle total + each driver's share), so monthly reports
never re-read a month of raw fixes and survive position pruning. Idempotent
upsert; a missed night is caught up the next night (and the monthly report
computes any un-rolled day inside retention live).

Crontab (daily 03:45):
    45 3 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py vehicle_daily_rollup >> /home/ubuntu/assisto/logs/vehicle_daily_rollup.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Roll up vehicle daily stats (last 2 complete Dhaka days)."

    def add_arguments(self, parser):
        parser.add_argument("--days", type=int, default=2)

    @track_job("vehicle_daily_rollup")
    def handle(self, *args, **opts):
        from core import vehicle100
        n = vehicle100.rollup(days_back=max(1, min(31, opts["days"])))
        self.stdout.write("%s vehicle_daily_rollup rows=%d" % (
            timezone.now().isoformat(timespec="seconds"), n))
