"""aibar: ONE live AI smoke after the owner adds the provider keys.

  cd /home/ubuntu/assisto/backend
  ../.venv/bin/python manage.py ai_live_smoke --estimate
  ../.venv/bin/python manage.py ai_live_smoke --confirm --budget-usd 1

--estimate (the default) makes NO AI call: it lists the planned calls, the
worst-case cost of each and the 40 % rule line. --confirm makes the real
calls (tiny bn + en prompts, no user, no credits), never more than
--budget-usd in worst case, and prints latency / tokens / cost per call.
Refuses to make real calls without --confirm, and always in tests / CI.
Keys are never printed. Logic: core/ai_live_smoke.py.
"""
import json
import os
import sys

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError


def _in_tests_or_ci():
    return bool(os.environ.get("CI") or "test" in sys.argv[1:2]
                or "settings_test" in (os.environ.get("DJANGO_SETTINGS_MODULE") or "")
                or getattr(settings, "TESTING", False))


class Command(BaseCommand):
    help = "Live AI smoke after keys land: --estimate (free) or --confirm --budget-usd 1"

    def add_arguments(self, parser):
        parser.add_argument("--estimate", action="store_true",
                            help="plan + worst-case cost only (default; no AI call)")
        parser.add_argument("--confirm", action="store_true",
                            help="make the real provider calls (costs money)")
        parser.add_argument("--budget-usd", type=float, default=1.0,
                            help="hard ceiling for the whole run (worst case), default 1")
        parser.add_argument("--json", action="store_true", help="machine-readable output")

    def handle(self, *args, **o):
        from core import ai_live_smoke as S
        budget = float(o["budget_usd"])
        if budget <= 0 or budget > 5:
            raise CommandError("--budget-usd must be > 0 and <= 5")
        est = S.estimate(budget)
        if o["confirm"] and o["estimate"]:
            raise CommandError("pick one: --estimate or --confirm")
        if not o["confirm"]:
            return self._print_estimate(est, o["json"])
        if _in_tests_or_ci():
            raise CommandError("refused: ai_live_smoke never makes real AI calls in tests / CI")
        if not est["calls"]:
            raise CommandError("no AI provider key is configured (Owner Admin -> Integrations)")
        self._print_estimate(est, o["json"])
        out = S.run(budget, log=None if o["json"] else self.stdout.write)
        if o["json"]:
            self.stdout.write(json.dumps({"estimate": est, "run": out}, ensure_ascii=False,
                                         indent=1, default=str))
            return
        self.stdout.write("")
        self.stdout.write("spent $%.5f of $%.2f · passed %d · failed %d · skipped %d"
                          % (out["spent_usd"], budget, len(out["passed"]),
                             len(out["failed"]), len(out["skipped"])))
        lat = sorted(r["latency_ms"] for r in out["results"] if r.get("ok"))
        if lat:
            self.stdout.write("latency ms: min %d · median %d · max %d"
                              % (lat[0], lat[len(lat) // 2], lat[-1]))
        if out["failed"]:
            self.stdout.write("FAILED: " + ", ".join(out["failed"]))

    def _print_estimate(self, est, as_json):
        if as_json:
            self.stdout.write(json.dumps({"estimate": est}, ensure_ascii=False, indent=1,
                                         default=str))
            return
        w = self.stdout.write
        w("AI available now: %s · providers: %s" % (est["available"],
                                                    ", ".join(est["providers"]) or "none"))
        for c in est["calls"]:
            w("  plan %-28s model=%-20s worst $%.5f" % (c["name"], c["model"], c["worst_usd"]))
        w("worst-case total $%.5f · budget $%.2f · %s"
          % (est["worst_total_usd"], est["budget_usd"],
             "fits" if est["fits_budget"] else "calls past the budget will be SKIPPED"))
        w(est["pricing_line"])
        if not est["calls"]:
            w("no provider key configured — nothing to run.")
