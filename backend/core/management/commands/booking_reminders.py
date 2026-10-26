"""booking-bot: send the booking reminders that are due (24 h + 2 h before,
max 2 per booking, never 22:00-08:00 Asia/Dhaka, never after STOP). Run every
5 minutes from cron, e.g.:
  */5 * * * *  cd /home/ubuntu/assisto/backend && nice -n15 \
      /home/ubuntu/assisto/.venv/bin/python manage.py booking_reminders \
      >> /home/ubuntu/assisto/backend/logs/booking_reminders.log 2>&1
Idempotent: each booking remembers which reminders it already got."""
from django.core.management.base import BaseCommand

from core import booking_service as S


class Command(BaseCommand):
    help = "Send due booking reminders (booking_bot)."

    def handle(self, *args, **opts):
        n = S.send_due_reminders()
        self.stdout.write("booking_reminders: sent=%d" % n)
