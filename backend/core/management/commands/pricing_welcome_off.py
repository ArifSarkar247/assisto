"""aimoney (owner final order 10 Nov 03:45, part G): NO free welcome AI
credits for NEW users from now on, in the LIVE PricingConfig.

  manage.py pricing_welcome_off --dry-run     # every before -> after, nothing saved
  manage.py pricing_welcome_off --apply       # idempotent; ONE pricing audit row

What it writes (core.logic.plan_book.WELCOME_OFF_PATCH): ai_levels.welcome_on
= False, plus the daily dynamic ads-per-answer switch (ad_dynamic) and the
shorter ad-funded answer (ad_out_cap 900). Credits already granted stay — no
balance is touched, no ledger row is written. The LEAD runs it after deploy,
with a DB backup first; a second --apply finds nothing to change and writes
nothing.
"""
import json

from django.core.management.base import BaseCommand


def preview():
    """(changes [(path, old, new)], problems, patch) — nothing saved."""
    from core import billing
    from core.logic import plan_book as BOOK, pricing as P
    old = P.normalize(billing.get_config().data)
    patch = {k: BOOK.deep_merge(old.get(k) or {}, v)
             for k, v in BOOK.WELCOME_OFF_PATCH.items()}
    merged = json.loads(json.dumps(old))
    merged.update(patch)
    problems = P.validate_edit(merged)
    new = P.normalize(merged)
    return BOOK.flat_diff(old, new), problems, patch


class Command(BaseCommand):
    help = "Dry-run (default) or --apply: no welcome AI credits for new users (DB backup first)."

    def add_arguments(self, parser):
        parser.add_argument("--dry-run", action="store_true")
        parser.add_argument("--apply", action="store_true")
        parser.add_argument("--reason", default="owner final order 10 Nov 03:45 part G")

    def handle(self, *a, **o):
        changes, problems, patch = preview()
        self.stdout.write("pricing_welcome_off — %d change(s):" % len(changes))
        for path, before, after in changes:
            self.stdout.write("  %s: %s -> %s" % (path, before, after))
        self.stdout.write("Existing balances stay: no credit is taken back, no ledger row.")
        if problems:
            self.stdout.write("REFUSED: %s" % ", ".join(problems))
        if not o["apply"] or o["dry_run"]:
            self.stdout.write("Dry run — nothing saved.")
            return
        if problems:
            self.stdout.write("Not applied.")
            raise SystemExit(1)
        if not changes:
            self.stdout.write("Already applied — nothing to change, nothing written.")
            return
        from django.contrib.auth import get_user_model
        from core.views_build61 import pricing_apply
        owner = get_user_model().objects.filter(is_superuser=True).order_by("id").first()
        ok, payload = pricing_apply(owner.id if owner else None,
                                    {"config": patch,
                                     "reason": ("welcome_off: " + o["reason"])[:200]})
        if not ok:
            self.stdout.write("Refused: %s" % ", ".join(payload.get("problems") or []))
            raise SystemExit(1)
        self.stdout.write("APPLIED (%d changes, one audit row). New users get no welcome "
                          "AI credits; ads per answer is recomputed daily." % len(changes))
