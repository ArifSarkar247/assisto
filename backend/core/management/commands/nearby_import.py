"""nearby (runs inside `manage.py minute_jobs`, no own cron line): pull the
small per-country emergency-place files the monthly GitHub Actions job
publishes (.github/workflows/nearby_data.yml) and upsert them, keeping every
owner override. Cheap when idle: one DB read; the manifest is checked at most
every 6 h and at most ONE country is imported per run. Never downloads or
filters OpenStreetMap itself (that runs only in GitHub Actions)."""
from django.core.management.base import BaseCommand

from core import nearby_list as NL
from core.ops_health import track_job


class Command(BaseCommand):
    help = "Import the published per-country Nearby emergency files (one per run)."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")
        parser.add_argument("--now", action="store_true", help="check the manifest now")
        parser.add_argument("--country", default="", help="import this country now")
        parser.add_argument("--file", default="", help="import a local nearby_<CC>.json.gz")
        parser.add_argument("--force", action="store_true",
                            help="accept a file much smaller than the current list")

    @track_job("nearby_import")
    def handle(self, *args, **opts):
        cc = (opts.get("country") or "").upper()
        if opts.get("file"):
            if not cc:
                self.stderr.write("--file needs --country")
                return
            with open(opts["file"], "rb") as fh:
                res = NL.import_blob(cc, fh.read(), force=opts.get("force"))
            self.stdout.write("imported %s" % res)
            return
        out = NL.tick(force_check=bool(opts.get("now")), only=cc or None)
        if not opts.get("quiet") or out not in ("idle", "up_to_date"):
            self.stdout.write("nearby_import: %s" % out)
