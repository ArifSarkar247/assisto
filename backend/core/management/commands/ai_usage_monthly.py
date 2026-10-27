"""pricing-40: the MONTHLY real-usage report (owner: "If real usage later
shows lower cost, tell me so we can give more messages"). Real tokens and
cost per chat mode over 30 days vs the caps the plan credits were sized on,
and — with >= 200 messages of data — the plan credits the real cost allows
at the same 40 % rule. Sends it to the owner once a month; changes nothing.

Cron (1st of the month, 04:10 Asia/Dhaka):
  10 4 1 * * ubuntu cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py ai_usage_monthly >> /home/ubuntu/assisto/backend/logs/ai_usage_monthly.log 2>&1
"""
import json

from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Monthly real AI usage per chat mode vs caps; owner report (no changes)."

    def add_arguments(self, parser):
        parser.add_argument("--no-alert", action="store_true")

    def handle(self, *a, **o):
        from core import ai_cost_alert as A
        out = A.monthly_report(notify=not o["no_alert"])
        self.stdout.write(json.dumps(out.get("report"), ensure_ascii=False, indent=1, default=str))
        self.stdout.write(out.get("body", ""))
        self.stdout.write("sent: %s" % out.get("sent"))
