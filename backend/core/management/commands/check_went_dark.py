"""
Went-dark watcher. For each armed protected phone that was reporting heartbeats
and then went silent for too long (and is either in lost mode or has a heartbeat
interval set), alert the owner + circle ONCE ("your phone went dark at <time>,
last seen <map link>") and latch went_dark_alerted so we never spam. A fresh
heartbeat clears the latch (see views_lost.HeartbeatView), so a later gap can
re-alert.

Idempotent: safe to run every few minutes from cron. Only touches Assisto's own
DB. Run e.g.:
  */5 * * * *  nice -n15 ionice -c3 <venv>/python manage.py check_went_dark
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.models import ProtectedPhone
from core.views_lost import _went_dark_since
from core.views_security import _notify_owner_and_circle


class Command(BaseCommand):
    help = "Alert owner+circle once when an armed phone goes dark (no heartbeat)."

    def handle(self, *args, **opts):
        now = timezone.now()
        alerted = 0
        qs = ProtectedPhone.objects.filter(armed=True, went_dark_alerted=False)
        for phone in qs:
            dark_since = _went_dark_since(phone, now)
            if dark_since is None:
                continue
            when = dark_since.strftime("%Y-%m-%d %H:%M")
            if phone.last_lat is not None and phone.last_lng is not None:
                maplink = (f"https://www.google.com/maps/search/?api=1&query="
                           f"{phone.last_lat},{phone.last_lng}")
                where = f"last seen near {maplink}"
            else:
                where = "last location unknown"
            _notify_owner_and_circle(
                phone.owner,
                "Your phone went dark",
                f"Your Assisto-protected phone stopped reporting its location "
                f"around {when} ({where}). If this was not expected, it may be "
                f"off, out of signal, or in someone else's hands. "
                f"Open Assisto > My lost phone.",
                route="security/lost-phone",
                meta={"went_dark_at": dark_since.isoformat(),
                      "lat": phone.last_lat, "lng": phone.last_lng})
            phone.went_dark_alerted = True
            phone.save(update_fields=["went_dark_alerted", "updated_at"])
            alerted += 1
        self.stdout.write(self.style.SUCCESS(f"went_dark: alerted={alerted}"))
