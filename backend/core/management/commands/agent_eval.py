"""
manage.py agent_eval — AF-6: Agent Core eval sets, CI brain or the REAL model.

Scripted (default, free — the same brain CI uses at the AI router's seam;
everything rolled back, nothing booked):
    python manage.py agent_eval --topic business [--limit 20]

Live (OWNER ONLY, spends real money, never in CI):
    python manage.py agent_eval --live --topic business --estimate
        prints the expected cost per configured model, calls nothing
    python manage.py agent_eval --live --topic business --limit 50 --budget-usd 2
        real planner calls through the AI router; refuses without
        --budget-usd, above AGENT_EVAL_MAX_USD (default $10), in CI or with
        no key; checks the WORST case of every call against the budget
        before making it and stops there. One pass per configured planner
        model (--models anthropic,openai to choose) -> scorecard + model
        comparison; JSON + Markdown report in --out (default
        backend/agent_eval_reports/). Topics: money, family, safety,
        documents, travel, health, learning, business, multi (+ the topic's
        approved feedback cases, AF-12).
"""
import os

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

from core.agentcore.evals import live as L


class Command(BaseCommand):
    help = "Agent Core evals: scripted (free) or --live with a hard --budget-usd cap."

    def add_arguments(self, parser):
        parser.add_argument("--topic", required=True, help="one of: %s" % ", ".join(L.TOPICS))
        parser.add_argument("--limit", type=int, default=0, help="first N cases only")
        parser.add_argument("--live", action="store_true", help="REAL model calls (owner only)")
        parser.add_argument("--budget-usd", type=float, default=None, help="hard USD cap for --live")
        parser.add_argument("--estimate", action="store_true", help="--live: only print the estimate")
        parser.add_argument("--models", default="", help="--live: providers to compare, e.g. anthropic,openai")
        parser.add_argument("--out", default="", help="report directory")

    def handle(self, *args, **o):
        topic = o["topic"]
        try:
            cases = L.load_cases(topic)
        except L.Refused as e:
            raise CommandError(str(e))
        cases = cases[: o["limit"] or None]
        out_dir = o["out"] or os.path.join(settings.BASE_DIR, "agent_eval_reports")
        if not o["live"]:
            return self._scripted(topic, cases, out_dir)
        only = [m.strip() for m in o["models"].split(",") if m.strip()] or None
        if o["estimate"]:
            if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
                raise CommandError("live evals never run in CI")
            models = L.configured_models(only)
            if not models:
                raise CommandError("no AI provider key is configured — nothing to estimate")
            for m in models:
                self.stdout.write("estimate %s/%s: $%.4f for %d cases (expected, not the cap)"
                                  % (m[0], m[1], L.estimate(cases, [m]), len(cases)))
            return
        try:
            L.check_refusals(topic, o["budget_usd"])
        except L.Refused as e:
            raise CommandError(str(e))
        models = L.configured_models(only)
        if not models:
            raise CommandError("none of the chosen providers has a key: %s" % o["models"])
        est = L.estimate(cases, models)
        self.stdout.write("expected cost $%.4f, hard cap $%.2f" % (est, o["budget_usd"]))
        if est > o["budget_usd"]:
            self.stdout.write(self.style.WARNING("the estimate is above the budget — the run stops at the cap"))
        rep = L.run(topic, budget_usd=o["budget_usd"], models=models, out=self.stdout.write, cases=cases)
        self.stdout.write(L.scorecard_md(rep))
        path = L.write_report(rep, out_dir)
        self.stdout.write(self.style.SUCCESS("live eval done — spent $%.4f of $%.2f — report %s"
                                             % (rep["spent_usd"], rep["budget_usd"], path)))

    def _scripted(self, topic, cases, out_dir):
        """The CI brain (no key, no spend) inside a rolled-back transaction."""
        from django.db import transaction
        from core.agentcore.evals import harness

        class _Undo(Exception):
            pass
        box = {}
        try:
            with transaction.atomic():
                box["rep"] = harness.run_suite(cases)
                raise _Undo
        except _Undo:
            pass
        rep = box["rep"]
        n = len(cases)
        self.stdout.write("%s (scripted brain): %d/%d passed" % (topic, len(rep["passed"]), n))
        for cid, why in rep["failed"][:20]:
            self.stdout.write("  %s: %s" % (cid, "; ".join(why)[:300]))
        if rep["failed"]:
            raise CommandError("%d case(s) failed" % len(rep["failed"]))
