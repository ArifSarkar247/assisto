"""aifinal round 3 item 7: the AI exam.
  manage.py ai_exam --tick      one minute_jobs slice (nightly 02-05 local, owner switch)
  manage.py ai_exam --status    last result
  manage.py ai_exam --gate      release gate: exit 1 when the last exam failed / is stale
  manage.py ai_exam --on [--budget 1.5] [--min-pass 0.85] [--min-win 0.6] --reason "..."
  manage.py ai_exam --off --reason "..."
                                aiqual: the owner's switch from a shell — ONLY the exam keys
                                of the ai_levels block change, through pricing_apply (the
                                same audited save as Owner Admin -> AI answer levels)
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
        p.add_argument("--on", action="store_true")
        p.add_argument("--off", action="store_true")
        p.add_argument("--budget", type=float)
        p.add_argument("--min-pass", type=float, dest="min_pass")
        p.add_argument("--min-win", type=float, dest="min_win")
        p.add_argument("--reason", default="")

    @track_job("ai_exam")
    def handle(self, *a, **o):
        if o["on"] or o["off"]:
            return self._switch(o)     # a settings change (heartbeat is harmless)
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

    def _switch(self, o):
        from django.core.management.base import CommandError
        from core.models import User
        from core.views_build61 import pricing_apply
        if o["on"] and o["off"]:
            raise CommandError("--on or --off, not both")
        if not (o["reason"] or "").strip():
            raise CommandError("--reason is required (it goes into the pricing audit)")
        patch = {"exam_on": bool(o["on"])}
        for k, key, lo, hi in (("budget", "exam_budget_usd", 0.1, 10.0),
                               ("min_pass", "exam_min_pass", 0.0, 1.0),
                               ("min_win", "exam_min_win", 0.0, 1.0)):
            if o.get(k) is not None:
                if not lo <= o[k] <= hi:
                    raise CommandError("%s must be between %s and %s" % (k, lo, hi))
                patch[key] = float(o[k])
        owner = User.objects.filter(is_superuser=True).order_by("id").first()
        if owner is None:
            raise CommandError("no owner account")
        ok, payload = pricing_apply(owner.id, {"config": {"ai_levels": patch},
                                               "reason": o["reason"].strip()[:200]})
        if not ok:
            raise CommandError("not saved: %s" % ", ".join(payload.get("problems") or ["error"]))
        c = AE.cfg()
        self.stdout.write("ai exam %s · budget $%.2f · pass >= %.2f · win >= %.2f"
                          % ("ON (02:00-05:00 Dhaka, inside minute_jobs)" if c["exam_on"] else "OFF",
                             c["budget_usd"], c["min_pass"], c["min_win"]))
