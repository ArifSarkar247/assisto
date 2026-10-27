"""billing-v2 rule Q — reconciliation alone (also part of billing_daily).
   python manage.py billing_reconcile [--days 7]"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Compare live / recent Play purchases with the DB and fix mismatches."

    def add_arguments(self, p):
        p.add_argument("--days", type=int, default=7)

    def handle(self, *a, **o):
        from core.payments import reconcile as RC
        out = RC.reconcile(days=max(1, min(60, o["days"])))
        self.stdout.write("billing_reconcile checked=%(checked)s changed=%(changed)s errors=%(errors)s settled=%(settled)s" % out)
