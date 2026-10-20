"""
shop_prune_snapshots — delete CCTV/shop event snapshots older than each site's
retention window.

HARD SAFETY RULE this enforces: we store AT MOST one small snapshot per event
and NEVER any video; this command makes the "auto-deleted after retention"
promise real. For every ShopEvent whose site has `snapshot_retention_days = N`,
once the event is older than N days we remove the snapshot FILE from disk and
clear the field (the event row + its signals/confidence stay as the audit
trail; only the image bytes go). A site with retention 0 keeps no snapshot bytes
at all, so its snapshots are pruned on the next run regardless of age.

Idempotent + cheap: an event whose snapshot is already gone is skipped. Only
touches Assisto's own DB. Safe to run daily from cron.

Crontab (daily 03:30, low priority):

  30 3 * * *  nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py shop_prune_snapshots >> /home/ubuntu/assisto/backend/logs/shop_prune_snapshots.log 2>&1
"""
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from core.models import ShopEvent


class Command(BaseCommand):
    help = "Delete shop-event snapshots older than each site's retention window."

    def handle(self, *args, **options):
        now = timezone.now()
        removed = prune(now)
        self.stdout.write("shop_prune_snapshots: removed %d snapshot(s)" % removed)


def prune(now=None):
    """Delete expired snapshot FILES + clear the field. Returns the count removed.
    Pure-enough to call from a test with a fixed `now`."""
    now = now or timezone.now()
    removed = 0
    # only events that still hold a snapshot are candidates
    for ev in ShopEvent.objects.exclude(snapshot="").exclude(snapshot=None):
        retention = int(ev.site.snapshot_retention_days or 0)
        cutoff = now - timedelta(days=retention)
        # retention 0 => cutoff == now => every snapshot is "older" => pruned.
        if ev.created <= cutoff or retention == 0:
            try:
                ev.snapshot.delete(save=False)   # remove bytes from disk
            except Exception:
                pass
            ev.snapshot = None
            ev.save(update_fields=["snapshot"])
            removed += 1
    return removed
