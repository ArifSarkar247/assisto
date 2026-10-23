"""Daily Profit-Guard rollover + owner summary (Business Model, Build 2).

Run once per day (local midnight) to:
  * expire purchased credits that passed their 12-month validity,
  * grant each paid user's monthly included pool (once per month), and
  * print / alert the owner with the trailing-7-day profit-guard state.

The DailyLedger rows are append-only and written live by core.billing
(record_revenue / record_cost); this command does NOT fabricate any numbers —
it only sweeps expiries and reports the current guard state.

Crontab (Asia/Dhaka), add on the Assisto-owned box only:
    5 0 * * *  cd /home/ubuntu/assisto/backend && \
        /home/ubuntu/assisto/.venv/bin/python manage.py profit_guard_rollover
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Expire old credits + report the daily profit-guard state."

    def handle(self, *args, **opts):
        from core import billing
        expired = billing.expire_credits()
        # paid plans: this month's included pool (Premium 90 / Business 240),
        # once per month per user, unused last-month pool expired (no rollover)
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
