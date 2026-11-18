"""seed_career — the career-lane E2E seed (career-proof.yml), AFTER seed_e2e.

    python manage.py seed_career --settings=assisto_backend.settings_e2eproof --out seed_career.json

1. allow-lists demo user A (the phone under test) for the two hidden
   switches the flow proves: career_plus (CV PDF + mock interview) and
   learning_certificate (the owner's tester allow-list mechanism);
2. self-checks that Bangla PDF shaping is really on (uharfbuzz) and that the
   fake AI provider answers, so a red check fails the job before the
   emulator boots.
Only the throw-away CI database (ci_e2e.apps refuses anything else).
"""
import json

from django.core.management.base import BaseCommand

FLAGS = ("career_plus", "learning_certificate")


class Command(BaseCommand):
    help = "Seed the career-lane E2E (CI only)."

    def add_arguments(self, parser):
        parser.add_argument("--out", default="seed_career.json")

    def handle(self, *args, **opts):
        from core import ai, pdf_bn
        from core import feature_flags as FF
        from core.models import FeatureFlag
        from core.phone import find_user

        a = find_user("01700000001")
        checks = []

        def check(name, ok, detail=""):
            checks.append({"check": name, "ok": bool(ok), "detail": detail})

        FF.ensure_seeded()
        for key in FLAGS:
            row = FeatureFlag.objects.filter(key=key).first()
            if row is not None and a.id not in (row.allow_user_ids or []):
                row.allow_user_ids = list(row.allow_user_ids or []) + [a.id]
                row.save(update_fields=["allow_user_ids", "updated_at"])
            FF.invalidate()
            check("flag_" + key, row is not None and FF.is_on(key, a, False), key)
        check("bangla_shaping", pdf_bn.shaping_ok(), "uharfbuzz")
        check("ai_fake_ready", ai.available(), "ci_e2e fake provider")
        out = {"user_a": a.id, "checks": checks,
               "failed_critical": [x["check"] for x in checks if not x["ok"]]}
        with open(opts["out"], "w", encoding="utf-8") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1, default=str)
        for x in checks:
            self.stdout.write("%s %s %s" % ("OK " if x["ok"] else "BAD", x["check"], x["detail"]))
