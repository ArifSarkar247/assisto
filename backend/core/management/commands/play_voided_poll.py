"""billing-v2 rule L — Voided Purchases API poll alone (also part of
billing_daily).   python manage.py play_voided_poll [--days 3]"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Process Google Play voided purchases (refunds) of the last N days."

    def add_arguments(self, p):
        p.add_argument("--days", type=int, default=3)

    def handle(self, *a, **o):
        from core.payments import refunds as R
        self.stdout.write("play_voided_poll %s" % R.voided_poll(days=max(1, min(30, o["days"]))))
