"""bizai pillar 3: group-buys whose deadline (+ accept grace) passed with no
deal → expired, and every joiner is told nothing was charged (COD).
Crontab (hourly):
    25 * * * * ubuntu cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py market_pool_sweep >> /home/ubuntu/assisto/logs/market_pool_sweep.log 2>&1
"""
from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Expire unfilled Market group-buys and tell the joiners (COD: nothing to refund)."

    @track_job("market_pool_sweep")
    def handle(self, *args, **opts):
        from core import market as MK
        self.stdout.write("market_pool_sweep expired=%d" % MK.pool_sweep())
