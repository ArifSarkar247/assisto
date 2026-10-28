"""
shop_guard_tick — the CCTV extras' minute job (cctvx, owner 28 Oct). No
WorkManager: the SERVER runs the delayed steps —
  * due no-sale checks (a cash-zone touch with no sale / khata entry in the
    owner's window -> "Drawer opened with no sale"; else the touch is
    deleted with its clip and photo),
  * escalation steps (the owner has not opened the alert -> next person),
  * siren-off for an Imou siren,
  * the offline check (gateway / camera / vendor cloud silent >= 10 min)
    and the late-opening check.
Bounded per run; never raises. Every minute from cron
(core.ops_health JOB "shop_guard_tick"):

  * * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-shop-guard-tick.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py shop_guard_tick >> /home/ubuntu/assisto/logs/shop_guard_tick.log 2>&1
"""
import json

from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "CCTV guard: no-sale checks, escalation, offline and late-opening alerts."

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("shop_guard_tick")
    def handle(self, *args, **options):
        from core.cctvx_views import tick
        out = tick()
        if not options.get("quiet"):
            self.stdout.write("shop_guard_tick: " + json.dumps(out, sort_keys=True))
