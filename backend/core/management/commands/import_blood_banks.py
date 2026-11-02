"""finish1: import the OFFICIAL blood bank list the owner supplies.

  manage.py import_blood_banks banks.csv \
      --source-name "DGHS blood transfusion centres" \
      --source-url https://... --source-date 2026-10-01 [--dry-run]
  manage.py import_blood_banks --clear      # back to "source pending"

No list without a named, linked, dated source; nothing is written when any
row is bad (every problem is printed with its row number). Columns: see
core/blood_banks.py. The app shows the source + date above the list.
"""
from django.core.management.base import BaseCommand, CommandError

from core import blood_banks as BB


class Command(BaseCommand):
    help = "Import an official blood bank list (CSV) with its source"

    def add_arguments(self, parser):
        parser.add_argument("csv_path", nargs="?")
        parser.add_argument("--source-name", default="")
        parser.add_argument("--source-url", default="")
        parser.add_argument("--source-date", default="")
        parser.add_argument("--dry-run", action="store_true")
        parser.add_argument("--clear", action="store_true")

    def handle(self, csv_path=None, source_name="", source_url="", source_date="",
               dry_run=False, clear=False, **_):
        if clear:
            BB.clear()
            self.stdout.write("cleared: the app shows 'source pending' again")
            return
        if not csv_path:
            raise CommandError("give the CSV file (or --clear)")
        src, errs = BB.check_source(source_name, source_url, source_date)
        try:
            with open(csv_path, encoding="utf-8-sig") as f:
                text = f.read()
        except (OSError, UnicodeDecodeError) as e:
            raise CommandError("cannot read %s as UTF-8 CSV: %s" % (csv_path, e))
        rows, row_errs = BB.parse_csv(text)
        errs += row_errs
        if errs:
            for e in errs[:200]:
                self.stderr.write(e)
            raise CommandError("%d problem(s); nothing imported" % len(errs))
        per = {}
        for r in rows:
            per[r["district"]] = per.get(r["district"], 0) + 1
        self.stdout.write("%d banks in %d districts from %s (%s)" % (
            len(rows), len(per), src["name"], src["date"]))
        if dry_run:
            self.stdout.write("dry run: nothing written")
            return
        BB.save(rows, src)
        self.stdout.write("saved to %s" % BB.store_path())
