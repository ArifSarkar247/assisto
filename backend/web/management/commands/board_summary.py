"""adminboards: print the Quality board / Vision checklist counts for the
21:00 BD daily report. Reads owner_actions/*.md live (same parser as the
Owner Admin pages). Usage:

    python manage.py board_summary            # human lines
    python manage.py board_summary --json     # machine-readable
    python manage.py board_summary --below9   # also list below-9 features + what is missing
"""
import json

from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Print quality-board (>=9 / total) and vision-checklist counts."

    def add_arguments(self, parser):
        parser.add_argument("--json", action="store_true")
        parser.add_argument("--below9", action="store_true")

    def handle(self, *args, **opts):
        from web.owner import boards as B
        s = B.summary()
        if opts["json"]:
            self.stdout.write(json.dumps(s, ensure_ascii=False, sort_keys=True))
            return
        q, v = s.get("quality"), s.get("vision")
        if q:
            self.stdout.write("Quality board: %d / %d features at >= %d (below 9: %d) [%s]"
                              % (q["passed"], q["total"], B.PASS_SCORE, q["below"], q["date"]))
        else:
            self.stdout.write("Quality board: file not found (%s)" % B.QUALITY_FILE)
        if v:
            self.stdout.write("Vision checklist: %d items: done %d · partial %d · not built %d"
                              " · no status %d; launch-critical done %d / %d [%s]"
                              % (v["total"], v["done"], v["partial"], v["missing"], v["unknown"],
                                 v["launch_critical_done"], v["launch_critical_total"], v["date"]))
        else:
            self.stdout.write("Vision checklist: file not found (%s)" % B.VISION_FILE)
        if opts["below9"] and q:
            rows = sorted((r for r in B.quality()["rows"] if not r["ready"]),
                          key=lambda r: (r["total"] if r["total"] is not None else -1, r["n"]))
            for r in rows:
                self.stdout.write("  #%d %s — %s/10 — %s"
                                  % (r["n"], r["feature"], r["total"], r["missing"]))
