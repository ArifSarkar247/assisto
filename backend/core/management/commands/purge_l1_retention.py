"""l1-launch — make two privacy-policy retention promises real.

  * Safe Journey route points: deleted once the journey's privacy expiry
    (Journey.expires_at) has passed, and the journey's last_location cleared.
    Before this the points were only deleted lazily when someone opened the
    timeline after expiry.
  * Web data-deletion tickets (lifeassisto.com/delete-account) that are closed
    (scheduled / rejected / no_account) are removed 180 days after creation.

Idempotent, cheap, only touches Assisto's own DB. Crontab (hourly):
    25 * * * *  cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py purge_l1_retention >> /home/ubuntu/assisto/logs/purge_l1_retention.log 2>&1
"""
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

TICKET_KEEP_DAYS = 180


class Command(BaseCommand):
    help = "Delete expired Safe Journey points + old closed web deletion tickets."

    def add_arguments(self, parser):
        parser.add_argument("--dry-run", action="store_true")

    def handle(self, *args, **opts):
        from core.models import Journey, JourneyPoint, WebDeletionRequest
        now = timezone.now()
        dry = opts.get("dry_run")
        expired = Journey.objects.filter(expires_at__isnull=False, expires_at__lte=now)
        pts = JourneyPoint.objects.filter(journey__in=expired)
        closed = WebDeletionRequest.objects.filter(
            status__in=(WebDeletionRequest.STATUS_SCHEDULED,
                        WebDeletionRequest.STATUS_REJECTED,
                        WebDeletionRequest.STATUS_NO_ACCOUNT),
            created_at__lt=now - timedelta(days=TICKET_KEEP_DAYS))
        if dry:
            self.stdout.write(f"[dry-run] journey points={pts.count()} "
                              f"tickets={closed.count()}")
            return
        n_pts, _ = pts.delete()
        n_loc = expired.filter(last_location__isnull=False).update(last_location=None)
        n_t, _ = closed.delete()
        self.stdout.write(f"journey points deleted={n_pts} last_location cleared={n_loc} "
                          f"tickets deleted={n_t}")
