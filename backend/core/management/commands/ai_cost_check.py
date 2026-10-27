"""pricing-40: print the real AI cost per credit (trailing 1 and 7 days,
overall / per model / per tier) against the safe level, and alert the owner
when it is above (the same step billing_daily runs). `--no-alert` = report
only. Reads the DB only; no AI calls, no price or credit changes."""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "AI cost per credit vs the safe level (owner alert only)."

    def add_arguments(self, parser):
        parser.add_argument("--no-alert", action="store_true")

    def handle(self, *a, **o):
        from core import ai_cost_alert as A
        safe = A.safe_level()
        self.stdout.write("safe level: ৳%.4f per credit" % safe)
        for d in A.WINDOWS:
            r = A.compute(d)
            self.stdout.write("%dd: credits %s cost ৳%s cpc %s | free calls %s ৳%s" % (
                d, r["credits"], r["cost_bdt"], r["cpc"], r["free_calls"], r["free_cost_bdt"]))
            for g in r["groups"]:
                self.stdout.write("   %s=%s credits %s ৳%s cpc %s" % (
                    g["by"], g["key"], g["credits"], g["cost_bdt"], g["cpc"]))
        self.stdout.write("check: %s" % A.check(notify=not o["no_alert"]))
