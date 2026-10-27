"""play-vitals: daily pull of Google Play Vitals (crash / ANR rates by day,
device model, Android API level and app version; Google's error issues with a
sample stack) into Owner Admin → Play Vitals. Key-gated: without the Play
service-account key it logs one line and exits 0. Never raises.

Cron (daily, after Google's overnight refresh):
  40 6 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py play_vitals_pull >> /home/ubuntu/assisto/backend/logs/play_vitals.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Pull Google Play Vitals (Play Developer Reporting API) into Owner Admin."

    def add_arguments(self, parser):
        parser.add_argument("--no-alerts", action="store_true",
                            help="Do not send owner alerts this run.")

    @track_job("play_vitals_pull")
    def handle(self, *args, **opts):
        from core import play_vitals as PV

        def log(msg):
            self.stdout.write("%s %s" % (timezone.now().isoformat(timespec="seconds"), msg))

        s = PV.run(log=log, alerts=not opts.get("no_alerts"))
        log("play_vitals: done ok=%s rows=%s issues=%s new=%s errors=%s fresh=%s%s"
            % (s.get("ok"), s.get("rows"), s.get("issues"), s.get("new"),
               s.get("errors"), s.get("fresh", {}),
               (" skipped=" + s["skipped"]) if s.get("skipped") else ""))
