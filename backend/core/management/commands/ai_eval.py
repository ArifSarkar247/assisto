"""
manage.py ai_eval — AI quality evaluations (owner MASTER QUALITY ORDER G).

Replay (default, free, what CI runs — never calls a provider):
    python manage.py ai_eval                       all features, check thresholds
    python manage.py ai_eval --feature bizagent_reply --feature reminders_nlp
    python manage.py ai_eval --out /tmp/scorecard  writes scorecard.json + .md

Live (OWNER ONLY, spends real money — never in CI):
    python manage.py ai_eval --live --feature home_chat --estimate
        prints the estimated USD cost, calls nothing
    python manage.py ai_eval --live --feature home_chat --confirm --budget-usd 2
        real calls through the AI router (feature "eval.<id>" in the usage
        log), stops BEFORE the call that would pass the budget; the budget is
        checked against the router's own AIUsage cost log. --limit N runs only
        the first N cases. --record saves the real answers as the new
        recorded outputs so CI replays them from then on.
"""
import json
import os

from django.core.management.base import BaseCommand, CommandError

from core.ai_evals import registry as REG
from core.ai_evals import runner as R


class Command(BaseCommand):
    help = "Run the AI evaluation sets (replay by default; --live needs --confirm --budget-usd)."

    def add_arguments(self, parser):
        parser.add_argument("--feature", action="append", default=[],
                            help="feature id (repeatable); default: all")
        parser.add_argument("--out", default="", help="directory for scorecard.json / scorecard.md")
        parser.add_argument("--live", action="store_true", help="REAL provider calls (owner only)")
        parser.add_argument("--confirm", action="store_true", help="required with --live")
        parser.add_argument("--budget-usd", type=float, default=0.0, help="hard USD cap for --live")
        parser.add_argument("--estimate", action="store_true", help="--live: only print the estimate")
        parser.add_argument("--limit", type=int, default=0, help="--live: first N cases only")
        parser.add_argument("--record", action="store_true",
                            help="--live: save real answers as recorded outputs")
        parser.add_argument("--no-fail", action="store_true", help="exit 0 even on threshold problems")

    def handle(self, *args, **o):
        feats = o["feature"] or [f["id"] for f in REG.FEATURES]
        unknown = [f for f in feats if f not in REG.BY_ID]
        if unknown:
            raise CommandError("unknown feature(s): %s" % ", ".join(unknown))
        if o["live"]:
            return self._live(feats, o)
        results, problems = R.run_all(feats)
        md = R.scorecard_md(results, problems)
        self.stdout.write(md)
        if o["out"]:
            os.makedirs(o["out"], exist_ok=True)
            with open(os.path.join(o["out"], "scorecard.json"), "w", encoding="utf-8") as f:
                json.dump({"results": results, "problems": problems}, f, ensure_ascii=False,
                          indent=1, default=str)
            with open(os.path.join(o["out"], "scorecard.md"), "w", encoding="utf-8") as f:
                f.write(md)
        if problems and not o["no_fail"]:
            raise CommandError("%d threshold problem(s)" % len(problems))

    # ------------------------------------------------------------------ live
    def _live(self, feats, o):
        if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
            raise CommandError("live evals never run in CI")
        llm = [f for f in feats if REG.BY_ID[f]["kind"] == REG.LLM]
        if not llm:
            raise CommandError("--live needs a model feature (rule features have no live mode)")
        est = {f: R.estimate_live(f) for f in llm}
        lim = o["limit"]
        if lim:
            est = {f: round(v * min(1.0, lim / max(1, len(R.load_cases(f)))), 4) for f, v in est.items()}
        total = round(sum(est.values()), 4)
        self.stdout.write("Estimated cost (primary model of each class, default prices):")
        for f, v in est.items():
            self.stdout.write("  %-20s $%.4f" % (f, v))
        self.stdout.write("  %-20s $%.4f" % ("TOTAL", total))
        if o["estimate"]:
            return
        if not o["confirm"]:
            raise CommandError("refusing: add --confirm --budget-usd N to spend real money")
        budget = float(o["budget_usd"] or 0)
        if budget <= 0:
            raise CommandError("refusing: --budget-usd must be > 0")
        from core import ai
        if not ai._providers():
            raise CommandError("no AI provider key is configured — nothing to run")
        if total > budget:
            self.stdout.write(self.style.WARNING(
                "estimate $%.4f is above the budget $%.2f — the run will stop at the budget"
                % (total, budget)))
        left = budget
        out = []
        for f in llm:
            if left <= 0:
                break
            r = R.run_llm_live(f, left, limit=lim or None, record=o["record"],
                               out=self.stdout.write)
            out.append(r)
            left -= float(r.get("spent_usd") or 0)
            self.stdout.write(json.dumps({k: v for k, v in r.items()
                                          if k not in ("failures", "missed_negatives",
                                                       "guard_misses")},
                                         ensure_ascii=False, default=str))
        if o["out"]:
            os.makedirs(o["out"], exist_ok=True)
            with open(os.path.join(o["out"], "live_scorecard.json"), "w", encoding="utf-8") as fh:
                json.dump(out, fh, ensure_ascii=False, indent=1, default=str)
        self.stdout.write(self.style.SUCCESS("live eval done — spent $%.4f of $%.2f"
                                             % (budget - left, budget)))
