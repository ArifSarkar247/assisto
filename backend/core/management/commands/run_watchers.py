"""
Run due server-side watchers (P4). Polite: plain-code change detection, AI only
on change. Cron (nice/ionice), e.g. hourly:
  0 * * * *  nice -n15 ionice -c3 <venv>/python manage.py run_watchers
Only touches Assisto's own DB + public sources.
"""
import time

from django.core.management.base import BaseCommand

from core import watcher
from core.models import ExamWatcher, Watcher
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Check all due watchers; record change hits."

    @track_job("run_watchers")
    def handle(self, *args, **opts):
        checked = hits = 0
        for w in Watcher.objects.filter(enabled=True).select_related("user"):
            if not watcher.due(w):
                continue
            checked += 1
            hit = watcher.check(w)
            if hit:
                hits += 1
                watcher.notify_hit(hit)   # lifebar: tell the user, once
            time.sleep(1)  # polite spacing between fetches
        # lifebar: exam-result pages (ExamWatcher) were saved but never polled
        exam_checked = exam_hits = 0
        for ew in ExamWatcher.objects.filter(result_ready=False).exclude(url="") \
                .select_related("user"):
            if not watcher.exam_due(ew):
                continue
            exam_checked += 1
            if watcher.check_exam(ew):
                exam_hits += 1
            time.sleep(1)
        self.stdout.write(self.style.SUCCESS(
            f"watchers: checked={checked} hits={hits} "
            f"exam_checked={exam_checked} exam_hits={exam_hits}"))
