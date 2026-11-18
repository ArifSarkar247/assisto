"""Load / refresh every Bangladesh Railway train (official timetable) and the
OSM rail geometry into PostgreSQL. Idempotent — the lead runs it once after a
deploy and again whenever the committed data changes.

    python manage.py load_bd_trains            # load, then check completeness
    python manage.py load_bd_trains --check    # only check (exit 1 if a train is missing)
    python manage.py load_bd_trains --bundle-size   # print the offline bundle size
"""
from django.core.management.base import BaseCommand, CommandError

from core import train_data


class Command(BaseCommand):
    help = "Load the official Bangladesh Railway timetable (all trains) + rail geometry."

    def add_arguments(self, parser):
        parser.add_argument("--check", action="store_true", help="only verify completeness")
        parser.add_argument("--bundle-size", action="store_true", help="print the offline bundle size")

    def handle(self, *args, **opts):
        if opts["bundle_size"]:
            raw, gz, ver = train_data.offline_bundle()
            self.stdout.write("offline bundle %s: %d bytes json, %d bytes gzip" % (ver, len(raw), len(gz)))
            return
        if not opts["check"]:
            train_data.load(stdout=self.stdout)
        problems = train_data.check()
        if problems:
            raise CommandError("train data incomplete: " + "; ".join(problems[:20]))
        self.stdout.write(self.style.SUCCESS(
            "all %d official trains present (Rangpur Express 771/772 OK)" % len(train_data.official_numbers())))
