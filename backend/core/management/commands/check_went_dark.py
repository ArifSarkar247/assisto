"""
Went-dark watcher. For each armed protected phone that was reporting heartbeats
and then went silent for too long (and is either in lost mode or has a heartbeat
interval set), alert the circle / approved family ONCE (never the owner about
his own phone — owner 24 Oct) ("your phone went dark at <time>,
last seen <map link>") and latch went_dark_alerted so we never spam. A fresh
heartbeat clears the latch (see views_lost.HeartbeatView), so a later gap can
re-alert.

Idempotent: safe to run every few minutes from cron. Only touches Assisto's own
DB. Run e.g.:
  */5 * * * *  nice -n15 ionice -c3 <venv>/python manage.py check_went_dark
"""
from django.core.management.base import BaseCommand
from django.db.models import Q
from django.utils import timezone

from core.models import ProtectedPhone
from core.views_lost import _went_dark_since
from core.views_security import _notify_owner_and_circle


class Command(BaseCommand):
    help = "Alert owner+circle once when an armed phone goes dark (no heartbeat)."

    def handle(self, *args, **opts):
        now = timezone.now()
        alerted = 0
        qs = ProtectedPhone.objects.filter(
            Q(armed=True) | Q(engine__enabled=True), went_dark_alerted=False).distinct()
        for phone in qs:
            dark_since = _went_dark_since(phone, now)
            if dark_since is None:
                continue
            # b6-antitheft: engine phones alert ONLY approved family (never
            # the owner — owner 24 Oct), bilingual, and the event lands on the
            # protection timeline. An engine phone NEVER falls through to the
            # legacy owner+circle path below, even on an error.
            from core.views_antitheft import (engine_enabled, notify, _owner_name,
                                              resolve_went_dark)
            if engine_enabled(phone):
                try:
                    from core.logic import antitheft as at
                    from core.models import AntiTheftEvent
                    last = phone.heartbeats.first()
                    te, be, tb, bb = at.went_dark_text(
                        _owner_name(phone.owner), dark_since, phone.last_lat, phone.last_lng,
                        last.battery if last else None)
                    # at-heartbeat: older went-dark alerts are closed first, so
                    # the family only ever has ONE open "stopped checking in".
                    resolve_went_dark(phone, now)
                    AntiTheftEvent.objects.get_or_create(
                        phone=phone, client_id="srv-dark-%d" % int(dark_since.timestamp()),
                        defaults={"kind": "went_dark", "at": dark_since,
                                  "lat": phone.last_lat, "lng": phone.last_lng,
                                  "alerted": True})
                    notify(phone, "went_dark", te, be, tb, bb, family_only=True,
                           meta={"went_dark_at": dark_since.isoformat(),
                                 "lat": phone.last_lat, "lng": phone.last_lng})
                    phone.went_dark_alerted = True
                    phone.save(update_fields=["went_dark_alerted", "updated_at"])
                    alerted += 1
                except Exception:
                    pass
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
                      "lat": phone.last_lat, "lng": phone.last_lng},
                # owner 24 Oct: never tell the owner his own phone went dark
                include_owner=False)
            phone.went_dark_alerted = True
            phone.save(update_fields=["went_dark_alerted", "updated_at"])
            alerted += 1
        self.stdout.write(self.style.SUCCESS(f"went_dark: alerted={alerted}"))
