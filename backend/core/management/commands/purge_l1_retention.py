"""l1-launch — make two privacy-policy retention promises real.

  * Safe Journey route points: deleted once the journey's privacy expiry
    (Journey.expires_at) has passed, and the journey's last_location cleared.
    Before this the points were only deleted lazily when someone opened the
    timeline after expiry.
  * Web data-deletion tickets (lifeassisto.com/delete-account) that are closed
    (scheduled / rejected / no_account) are removed 180 days after creation.
  * sc1: app crash/error reports (ClientErrorReport) are removed 30 days after
    they were last seen.
  * md1: My Circle E2E media ciphertext (CircleMediaBlob + its file) is
    removed `circle_media_keep_days` after every recipient downloaded it, at
    most `circle_media_max_days` after upload, once its last message was
    deleted for everyone, and 24 h after an unfinished / never-sent upload
    (owner-editable in admin pricing limits; core/circle_blobs.purge).
  * p3: My Circle stories (CircleStatus + views) and profile Notes are deleted
    once their 24 h life is over (views_p3_circle.purge_expired) — the reads
    already hide them; this removes the ciphertext from the database.

Idempotent, cheap, only touches Assisto's own DB. Crontab (hourly):
    25 * * * *  cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py purge_l1_retention >> /home/ubuntu/assisto/logs/purge_l1_retention.log 2>&1
"""
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

TICKET_KEEP_DAYS = 180
CRASH_KEEP_DAYS = 30   # sc1


class Command(BaseCommand):
    help = "Delete expired Safe Journey points + old closed web deletion tickets."

    def add_arguments(self, parser):
        parser.add_argument("--dry-run", action="store_true")

    def handle(self, *args, **opts):
        from core.models import ClientErrorReport, Journey, JourneyPoint, WebDeletionRequest
        now = timezone.now()
        dry = opts.get("dry_run")
        expired = Journey.objects.filter(expires_at__isnull=False, expires_at__lte=now)
        pts = JourneyPoint.objects.filter(journey__in=expired)
        closed = WebDeletionRequest.objects.filter(
            status__in=(WebDeletionRequest.STATUS_SCHEDULED,
                        WebDeletionRequest.STATUS_REJECTED,
                        WebDeletionRequest.STATUS_NO_ACCOUNT),
            created_at__lt=now - timedelta(days=TICKET_KEEP_DAYS))
        crashes = ClientErrorReport.objects.filter(
            last_at__lt=now - timedelta(days=CRASH_KEEP_DAYS))
        from core import circle_blobs
        from core.views_p3_circle import purge_expired
        if dry:
            self.stdout.write(f"[dry-run] stories/notes={purge_expired(now, dry=True)}")
            self.stdout.write(f"[dry-run] journey points={pts.count()} "
                              f"tickets={closed.count()} crash reports={crashes.count()} "
                              f"circle media={circle_blobs.purge(now, dry=True)}")
            return
        n_pts, _ = pts.delete()
        n_loc = expired.filter(last_location__isnull=False).update(last_location=None)
        n_t, _ = closed.delete()
        n_c, _ = crashes.delete()
        n_s = purge_expired(now)
        n_m = circle_blobs.purge(now)
        self.stdout.write(f"journey points deleted={n_pts} last_location cleared={n_loc} "
                          f"tickets deleted={n_t} crash reports deleted={n_c} "
                          f"circle media deleted={n_m} stories/notes deleted={n_s}")
