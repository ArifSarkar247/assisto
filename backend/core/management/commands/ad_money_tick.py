"""aimoney (owner 10 Nov 03:45, part G; runs inside `manage.py minute_jobs`,
no own cron line): ONCE a local day, recompute ads per AI answer from the
real AI cost log and the AdMob paid events (core/ad_money_service.py).
Idle (already done today) = one indexed read. Plain `manage.py
ad_money_tick --now` recomputes at once."""
from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Daily: ads per AI answer = ceil(real cost x 1.2 / real ad income), min 2."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")
        parser.add_argument("--now", action="store_true", help="recompute now (ignore the daily stamp)")

    @track_job("ad_money_tick")
    def handle(self, *args, **opts):
        from core import ad_money_service as AMS
        row = AMS.recompute() if opts.get("now") else AMS.tick()
        if row is not None and not opts.get("quiet"):
            d = row.data or {}
            self.stdout.write("ad_money_tick: %s ads per answer (cost %s, income %s %s)"
                              % (row.ads_per_answer, d.get("real_cost_bdt"),
                                 d.get("income_bdt"), d.get("income_source")))
