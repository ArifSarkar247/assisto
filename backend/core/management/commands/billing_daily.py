"""billing-v2 — the DAILY billing job (owner order 27 Oct, rules A, L, Q, R):

  1. Voided Purchases API poll (Google refunds whose RTDN was missed)
  2. reconciliation: re-fetch live / recent Play purchases and fix mismatches
     + the credits safety settle (staged unlocks, plan allowance whose paid
     period ended even when an RTDN was missed)
  3. credits_verify (balance == ledger == lots)
  4. per-user Profit Guard (cost this month > paid this month)
Each step saves a BillingReport (Owner Admin -> Payments -> Billing reports).

Cron (Asia/Dhaka), on the Assisto box — owner adds it to /etc/cron.d/assisto-app:
    40 3 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py billing_daily >> /home/ubuntu/assisto/backend/logs/billing_daily.log 2>&1
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Daily: voided poll, reconcile, credits verify, per-user profit guard."

    def handle(self, *a, **o):
        from core.payments import reconcile as RC, refunds as R
        steps = (("voided_poll", R.voided_poll), ("reconcile", RC.reconcile),
                 ("credits_verify", RC.credits_verify),
                 ("profit_guard", RC.profit_guard_users))
        for name, fn in steps:
            try:
                out = fn()
                short = {k: v for k, v in out.items() if not isinstance(v, (list, dict))}
                self.stdout.write("[billing_daily] %s %s" % (name, short))
            except Exception as e:      # one step never stops the others
                self.stdout.write("[billing_daily] %s FAILED %s" % (name, type(e).__name__))
