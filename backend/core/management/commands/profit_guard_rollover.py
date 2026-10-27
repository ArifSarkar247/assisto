"""Daily Profit-Guard rollover + owner summary.

billing-v2 (owner order 27 Oct, audit #5): pack credits NEVER expire any
more, so this no longer expires packs. It now runs the credits safety settle
(staged unlocks, plan allowance whose paid period ended, annual months, base
plan months) and reports the trailing-7-day guard. Safe to run any time;
billing_daily covers the rest (voided poll, reconcile, per-user guard).

Crontab (Asia/Dhaka), on the Assisto box:
    5 0 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py profit_guard_rollover >> /home/ubuntu/assisto/backend/logs/profit_guard_rollover.log 2>&1
"""
from django.core.management.base import BaseCommand
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Settle credit buckets + report the daily profit-guard state."

    @track_job("profit_guard_rollover")
    def handle(self, *args, **opts):
        from core import billing
        expired = billing.expire_credits()
        pooled = billing.grant_all_monthly_pools()
        st = billing.guard_state()
        self.stdout.write(
            f"[profit_guard] expired={expired} pools_granted={pooled} state={st['state']} "
            f"rev7d={st['rev7d']} cost7d={st['cost7d']} cap={st['cap']}")
        if st["over"]:
            billing._owner_alert(
                "Profit guard OVER — free-tier costly actions paused",
                f"Trailing-7d cost ৳{st['cost7d']} exceeds 60% of NET revenue "
                f"(cap ৳{st['cap']}). Paid users + safety unaffected.")
