"""booking-bot: send the booking reminders that are due (24 h + 2 h before,
max 2 per booking, never 22:00-08:00 Asia/Dhaka, never after STOP). Run every
5 minutes from cron, e.g.:
  */5 * * * *  cd /home/ubuntu/assisto/backend && nice -n15 \
      /home/ubuntu/assisto/.venv/bin/python manage.py booking_reminders \
      >> /home/ubuntu/assisto/backend/logs/booking_reminders.log 2>&1
Idempotent: each booking remembers which reminders it already got."""
from datetime import timedelta

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from core import booking_service as S
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Send due booking reminders (booking_bot)."

    def add_arguments(self, parser):
        # bizassist: the reality CI cannot wait 24 h. With --ci-24h-before
        # (refused unless settings.REALITY_CI, i.e. settings_ci only) each
        # confirmed future booking that got no reminder yet is swept AS IF it
        # were 23 h 55 min before its start — the same send path, guard and
        # channels as the real cron.
        parser.add_argument("--ci-24h-before", action="store_true")

    @track_job("booking_reminders")
    def handle(self, *args, **opts):
        if opts.get("ci_24h_before"):
            if not getattr(settings, "REALITY_CI", False):
                raise CommandError("--ci-24h-before is for the reality CI only")
            from core.models import Booking
            n = 0
            for b in Booking.objects.filter(status="confirmed", start__gt=timezone.now(),
                                            reminders_sent=0)[:20]:
                Booking.objects.filter(pk=b.pk).update(created_at=b.start - timedelta(days=3))
                n += S.send_due_reminders(now=b.start - timedelta(hours=23, minutes=55))
            self.stdout.write("booking_reminders (ci): sent=%d" % n)
            return
        n = S.send_due_reminders()
        self.stdout.write("booking_reminders: sent=%d" % n)
