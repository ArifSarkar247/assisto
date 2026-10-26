"""calls95: store the daily ring-delivery trend row(s) (core.call_ack).

Cron (daily, as the app user, from backend/), e.g. 00:10:
  10 0 * * * ubuntu cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py calls_delivery_snapshot >/dev/null 2>&1

Owner Admin -> Calls also refreshes today + yesterday on every open, so the
trend works without the cron; the cron keeps it complete on days nobody
opens the page. Read-only on calls; writes only CallDeliveryDaily.
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Upsert the daily call ring-delivery snapshot (last N days)."

    def add_arguments(self, parser):
        parser.add_argument("--days", type=int, default=30)

    def handle(self, *args, **opts):
        from core import call_ack
        n = call_ack.snapshot_days(max(1, min(int(opts["days"]), 90)))
        self.stdout.write("calls_delivery_snapshot: %d day row(s)" % n)
