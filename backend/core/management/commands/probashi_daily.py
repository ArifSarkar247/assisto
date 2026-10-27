"""probashi-plan daily job (cron, once a day; suggested 04:10 UTC = 10:10
Asia/Dhaka — add at deploy, NOT in git crontab):

  * stale seat invites expire; seats of payers whose plan has been off for
    `lapse_close_days` close (no cooldown);
  * on the 1st (Asia/Dhaka) — or with --report — last month's family reports
    are built (idempotent: one per person per month), push + in-app card.

Does nothing while the probashi_plan flag is off for everyone."""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core import probashi_plan as PB


class Command(BaseCommand):
    help = "Probashi family plan: expire invites, close lapsed seats, monthly reports"

    def add_arguments(self, parser):
        parser.add_argument("--report", action="store_true",
                            help="build last month's reports now (idempotent)")

    def handle(self, *args, **opts):
        now = timezone.now()
        out = PB.close_lapsed(now)
        made = 0
        if opts.get("report") or timezone.localtime(now).day == 1:
            made = PB.build_all_reports(now)
        self.stdout.write("probashi_daily: expired %d invites, closed %d seats, %d reports"
                          % (out["expired"], out["closed"], made))
