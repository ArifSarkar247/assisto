"""citydata (owner 9 Nov 11:45): City Service upkeep, inside `manage.py
minute_jobs` (no own cron line). Idle minutes = two small DB reads.
  * every 6 h: check the transit-data release manifest; import a changed
    city file (small; built in GitHub Actions — the server never processes
    OpenStreetMap itself);
  * hourly: trip learning (consented, name-free traces -> stops / segment
    times / new routes), crowd fares + night ratings -> overrides, purge raw
    trip points older than 7 days and long-expired live reports."""
from django.core.management.base import BaseCommand

from core import city_service as CS
from core.ops_health import track_job


class Command(BaseCommand):
    help = "City Service: import new city data, learn from trips, aggregate crowd facts."
    requires_system_checks = []

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")
        parser.add_argument("--now", action="store_true", help="do everything now")
        parser.add_argument("--file", default="", help="import a local transit_<city>.json.gz")
        parser.add_argument("--dir-file", default="", help="with --file: directory_<city>.json.gz")
        parser.add_argument("--city", default="")

    @track_job("city_tick")
    def handle(self, *args, **opts):
        if opts.get("file"):
            city = opts.get("city") or ""
            with open(opts["file"], "rb") as fh:
                blob = fh.read()
            dblob = b""
            if opts.get("dir_file"):
                with open(opts["dir_file"], "rb") as fh:
                    dblob = fh.read()
            self.stdout.write("imported %s" % CS.import_city(city, blob, dblob))
            return
        out = CS.tick(force=bool(opts.get("now")))
        if not opts.get("quiet") or out not in ("idle", "up_to_date"):
            self.stdout.write("city_tick: %s" % out)
