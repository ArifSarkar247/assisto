"""billing-v2 rule A — invariant check: for every user
User.ai_credits == sum(CreditLedger.delta) == sum(active CreditLot.remaining).
Prints every mismatch, saves a BillingReport (Owner Admin -> Payments ->
Billing reports). Exit code 1 when a mismatch is found (for cron mail).

    python manage.py credits_verify [--user N]
"""
import sys

from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Check balance == ledger sum == bucket lots for every user."

    def add_arguments(self, p):
        p.add_argument("--user", type=int, action="append")

    def handle(self, *a, **o):
        from core.payments import reconcile as RC
        out = RC.credits_verify(o.get("user"))
        for r in out["rows"]:
            self.stdout.write("MISMATCH user #%(user)s balance=%(balance)s ledger=%(ledger_sum)s lots=%(lots_sum)s" % r)
        self.stdout.write("credits_verify: %d users, %d mismatch(es)" % (out["users"], out["mismatches"]))
        if out["mismatches"]:
            sys.exit(1)
