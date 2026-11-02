"""
Run due server-side watchers (P4). Polite: plain-code change detection, AI only
on change. Cron (nice/ionice), e.g. hourly:
  0 * * * *  nice -n15 ionice -c3 <venv>/python manage.py run_watchers
Only touches Assisto's own DB + public sources.
"""
import time

from django.core.management.base import BaseCommand
from django.db.models import F

from core import watcher
from core.models import Watcher
from core.ops_health import track_job  # ops-watch heartbeat


# cronbar: the hourly run stops starting new checks after 50 min (its cron
# line also has a hard `timeout`); due watchers left over go first next hour.
MAX_SECONDS = 50 * 60


class Command(BaseCommand):
    help = "Check all due watchers; record change hits."

    def add_arguments(self, parser):
        parser.add_argument("--max-seconds", type=int, default=MAX_SECONDS,
                            help="stop starting new checks after N seconds (cronbar)")

    @track_job("run_watchers")
    def handle(self, *args, **opts):
        checked = hits = 0
        budget = max(0, int(opts.get("max_seconds", MAX_SECONDS)))
        t0 = time.monotonic()
        left = 0
        # oldest-checked first, so a run that hits the budget never starves
        # the same watchers twice in a row
        for w in (Watcher.objects.filter(enabled=True).select_related("user")
                  .order_by(F("last_checked").asc(nulls_first=True), "id")):
            if not watcher.due(w):
                continue
            if time.monotonic() - t0 >= budget:
                left += 1
                continue
            checked += 1
            hit = watcher.check(w)
            if hit:
                hits += 1
            time.sleep(1)  # polite spacing between fetches
        self.stdout.write(self.style.SUCCESS(
            f"watchers: checked={checked} hits={hits} left_for_next_run={left}"))
