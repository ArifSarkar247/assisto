"""family100 — quality bar D/৭: how fast family alerts reach the phone.

For every family alert the server pushed and the recipient's phone acked
(POST /family/alerts/received, sent by the app the moment the push arrives,
background isolate included): seconds from push to receipt, p50 / p95 and how
many arrived within 60 s. Real measurements only — prints "no receipts yet"
when nothing has been measured.

    python manage.py family_alerts_report [--hours 24]
"""
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone


class Command(BaseCommand):
    help = "Family alert delivery time (push -> phone receipt), p50/p95."

    def add_arguments(self, parser):
        parser.add_argument("--hours", type=int, default=24 * 7)

    def handle(self, *args, **opts):
        from core import family_alerts as FA
        st = FA.delivery_stats(since=timezone.now() - timedelta(hours=opts["hours"]))
        if not st["receipts"]:
            self.stdout.write("family_alerts_report sent=%d receipts=0 (no receipts yet)"
                              % st["sent"])
            return
        self.stdout.write(
            "family_alerts_report sent=%(sent)d receipts=%(receipts)d p50_s=%(p50_s)s "
            "p95_s=%(p95_s)s within_60s=%(within_60s)d" % st)
