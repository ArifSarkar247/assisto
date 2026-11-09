"""bizai pillar 5: the weekly Bangla business report (core/bizai_prochar.run_weekly).
Once per shop per ISO week (idempotent). Runs inside `manage.py minute_jobs`
(owner: no new cron lines) with --tick: due from Friday 10:00 Asia/Dhaka
until the week ends (a missed Friday catches up on Saturday/Sunday), once per
ISO week. Plain `manage.py bizai_weekly` runs it now.
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core import ops_health as H
from core.ops_health import track_job

FRIDAY = 4          # date.weekday()
FROM_HOUR = 10      # Dhaka local


def is_due(now, last):
    """now/last: aware datetimes. Due in the Fri 10:00 .. Sun 23:59 local
    window when the last real run was not in this ISO week."""
    loc = timezone.localtime(now)
    if loc.weekday() < FRIDAY or (loc.weekday() == FRIDAY and loc.hour < FROM_HOUR):
        return False
    if last is None:
        return True
    return timezone.localtime(last).isocalendar()[:2] != loc.isocalendar()[:2]


class Command(BaseCommand):
    help = "Weekly business report per shop (saved + one push)."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--tick", action="store_true",
                            help="minute_jobs slice: run only when the weekly window is due")

    @track_job("bizai_weekly")
    def handle(self, *args, **opts):
        now = timezone.now()
        if opts.get("tick") and not is_due(now, H.stamp_get("bizai_weekly")):
            return
        from core import bizai_prochar as BP
        n = BP.run_weekly(now)
        H.stamp_set("bizai_weekly", now)
        self.stdout.write("%s bizai_weekly sent=%d" % (now.isoformat(timespec="seconds"), n))
