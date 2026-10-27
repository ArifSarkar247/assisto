"""ai-router: OFFLINE Bangla quality probe — OWNER-RUN ONLY.

Sends the same 10 Bangla prompts (core/ai_prompt.QUALITY_PROMPTS) through the
shared system prompt to every connected provider's MAIN model, normalizes the
answers exactly like real traffic, and stores them (AIQualityProbe) for the
side-by-side review on Owner Admin → AI. Costs real money (a few cents) and
counts against the daily caps, so it needs --confirm and refuses to run under
tests / CI.

  cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py ai_quality_probe --confirm
"""
import os
import sys
import time

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError


def _in_tests_or_ci():
    return (os.environ.get("CI") or "test" in sys.argv[1:2]
            or "settings_test" in (os.environ.get("DJANGO_SETTINGS_MODULE") or "")
            or "settings_ci" in (os.environ.get("DJANGO_SETTINGS_MODULE") or "")
            or getattr(settings, "TESTING", False))


class Command(BaseCommand):
    help = "Owner-run: send 10 Bangla prompts to each AI provider for side-by-side review."

    def add_arguments(self, parser):
        parser.add_argument("--confirm", action="store_true",
                            help="I understand this makes real, paid AI calls.")
        parser.add_argument("--provider", choices=["anthropic", "openai", "gemini"])

    def handle(self, *args, **opts):
        if _in_tests_or_ci():
            raise CommandError("ai_quality_probe never runs in tests or CI.")
        if not opts.get("confirm"):
            raise CommandError("Real paid AI calls — re-run with --confirm.")
        from django.utils import timezone

        from core import ai, ai_config as C, ai_prompt as P, ai_router as R
        from core.models import AIQualityProbe, AIUsage
        conf = R.cfg()
        provs = [(n, k) for n, k in ai._providers()
                 if not opts.get("provider") or n == opts["provider"]]
        if not provs:
            raise CommandError("No AI keys configured.")
        run_id = timezone.localtime().strftime("%Y%m%d-%H%M%S")
        system = P.system_prompt()
        for name, key in provs:
            if R.provider_capped(name, conf):
                self.stdout.write("%s: over today's cap — skipped" % name)
                continue
            model = C.model_for(conf, name, "medium", "main")
            fn = getattr(ai, "_call_" + name)
            for i, prompt in enumerate(P.QUALITY_PROMPTS):
                token = ai._CALL_OPTS.set({"timeout": conf["timeouts_s"]["main"], "klass": "main",
                                           "effort": conf["effort"]["medium"],
                                           "server_fallback": conf["server_fallback"]})
                t0 = time.monotonic()
                row = AIQualityProbe(run_id=run_id, provider=name, model=model,
                                     prompt_no=i, prompt=prompt)
                try:
                    text, itok, otok, cr, cw, used = ai._unpack(
                        fn(key, model, system, prompt, 700), model)
                    row.answer = P.normalize_output(text)
                    row.ok = bool(row.answer)
                    row.cost_usd = C.cost_usd(conf, used, itok, otok, cr, cw)
                    AIUsage.objects.create(feature="quality_probe", model=used[:40],
                                           input_tokens=itok, output_tokens=otok,
                                           cost_usd=row.cost_usd, provider=name,
                                           tier="medium", task_class="main",
                                           cache_read_tokens=cr, cache_write_tokens=cw)
                except Exception as e:  # noqa: BLE001
                    row.ok, row.error = False, ai._classify(e).kind
                finally:
                    ai._CALL_OPTS.reset(token)
                row.latency_ms = int((time.monotonic() - t0) * 1000)
                row.save()
                self.stdout.write("%s #%d %s" % (name, i + 1, "ok" if row.ok else row.error))
        self.stdout.write("run %s saved — see Owner Admin → AI" % run_id)
