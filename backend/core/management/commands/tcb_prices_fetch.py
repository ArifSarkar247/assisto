"""moneybar — fetch TCB's official daily Dhaka retail price list (core.tcb_prices)
for the Market price radar. Once a day after TCB publishes (~12:30 Dhaka).
Idempotent: same file -> 'unchanged', nothing rewritten. Bounded: 25 s HTTP
timeout per request, 2 MB file cap, 400 items cap. A failure leaves the last
good list in place (the app shows its date; > 4 days old = "stale").

Crontab (/etc/cron.d/assisto-app, daily 13:40 Dhaka):
    40 13 * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-tcb-prices-fetch.lock nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py tcb_prices_fetch >> /home/ubuntu/assisto/backend/logs/tcb_prices_fetch.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Fetch TCB's official daily retail market prices (Dhaka)."

    @track_job("tcb_prices_fetch")
    def handle(self, *args, **opts):
        from core import tcb_prices
        status, payload = tcb_prices.fetch_and_store()
        n = len((payload or {}).get("items") or [])
        self.stdout.write("%s tcb_prices_fetch %s date=%s items=%d" % (
            timezone.now().isoformat(timespec="seconds"), status,
            (payload or {}).get("date", "-"), n))
        if status in ("no_link", "empty"):
            # nothing usable today: exit non-zero so ops_watch notices if it repeats
            raise SystemExit(1)
