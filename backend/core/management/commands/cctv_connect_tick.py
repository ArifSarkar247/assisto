"""
cctv_connect_tick — CCTV Guard V3 (cctvconnect), rides minute_jobs:

  * brand-cloud sync (Hik-Connect account alarm queue, DoLynk alarm poll,
    cloud DVR / SD health every 3 h) — returns at once when no connector key
    exists or no site has a link;
  * the daily CCTV green check (09:00 Dhaka, once per site per day).
EZVIZ / Imou alarms keep their own proven paths (ezviz_poll_alarms, the
Imou callback) — never polled twice.
"""
from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Brand-cloud CCTV sync + daily DVR health check."
    requires_system_checks = []

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("cctv_connect_tick")
    def handle(self, *args, **options):
        from core import cctv_connect_views as V
        from core.models import CctvCloudLink, CctvDvrHealth
        out = {"links": 0, "events": 0, "health": 0}
        if CctvCloudLink.objects.filter(status="active").exists():
            out = V.sync_all()
        daily = 0
        if CctvDvrHealth.objects.exists():
            daily = V.daily_checks()
        if not options.get("quiet"):
            self.stdout.write("cctv_connect_tick: %(links)d link(s), %(events)d event(s), "
                              "%(health)d health" % out + ", %d daily card(s)" % daily)
