"""aifinal round 3 item 7: the AI exam.
  manage.py ai_exam --tick      one minute_jobs slice (nightly 02-05 local, owner switch)
  manage.py ai_exam --status    last result
  manage.py ai_exam --gate      release gate: exit 1 when the last exam failed / is stale
"""
import json
import sys

from django.core.management.base import BaseCommand

from core import ai_exam as AE
from core.ops_health import track_job


class Command(BaseCommand):
    help = "Nightly AI exam (tick / status / release gate)."
    requires_system_checks = []

    def add_arguments(self, p):
        p.add_argument("--tick", action="store_true")
        p.add_argument("--status", action="store_true")
        p.add_argument("--gate", action="store_true")
        p.add_argument("--quiet", action="store_true")

    @track_job("ai_exam")
    def handle(self, *a, **o):
        if o["gate"]:
            ok, why = AE.gate()
            self.stdout.write(("PASS" if ok else "FAIL") + " ai exam gate: " + why)
            if not ok:
                sys.exit(1)
            return
        if o["status"]:
            s = AE.last()
            s.pop("fails", None)
            self.stdout.write(json.dumps(s, ensure_ascii=False, indent=1))
            return
        n = AE.tick()
        if not o["quiet"]:
            self.stdout.write("graded %d" % n)
