"""
shop_clip_purge — delete Smart Cash Guard clips past their 24 h window
(cashguard, owner 28 Oct). Clips are CIPHERTEXT only; this makes the "deleted
after 24 hours" promise real even when nobody opens the app (every clip
request also expires lazily). Hourly from cron:

  17 * * * *  nice -n15 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py shop_clip_purge >/dev/null 2>&1
"""
from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Delete encrypted cash-guard clips older than 24 hours."

    @track_job("shop_clip_purge")
    def handle(self, *args, **options):
        from core.cashguard_views import purge_clips
        n = purge_clips()
        self.stdout.write("shop_clip_purge: removed %d clip(s)" % n)
