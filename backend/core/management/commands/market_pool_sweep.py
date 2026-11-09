"""bizai pillar 3: group-buys whose deadline (+ accept grace) passed with no
deal -> expired, and every joiner is told nothing was charged (COD).
Runs inside `manage.py minute_jobs` (owner: no new cron lines) with --tick:
does the sweep at most once per SWEEP_EVERY_S; plain `manage.py
market_pool_sweep` sweeps now.
"""
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from core import ops_health as H
from core.ops_health import track_job

SWEEP_EVERY_S = 30 * 60


class Command(BaseCommand):
    help = "Expire unfilled Market group-buys and tell the joiners (COD: nothing to refund)."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--tick", action="store_true",
                            help="minute_jobs slice: sweep only when 30 min have passed")

    @track_job("market_pool_sweep")
    def handle(self, *args, **opts):
        now = timezone.now()
        if opts.get("tick"):
            last = H.stamp_get("market_pool_sweep")
            if last and now - last < timedelta(seconds=SWEEP_EVERY_S):
                return
        from core import market as MK
        n = MK.pool_sweep()
        H.stamp_set("market_pool_sweep", now)
        self.stdout.write("market_pool_sweep expired=%d" % n)
