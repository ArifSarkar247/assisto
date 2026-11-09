"""plansprep (owner pricing decisions 9 Nov 10:20, PRICING_PLAN_BN.md §8):
turn the approved credit economy on in the LIVE PricingConfig.

  manage.py pricing_v2_apply --dry-run     # every before -> after, nothing saved
  manage.py pricing_v2_apply --apply       # idempotent; one pricing audit row

What it writes (core.logic.plan_book.v2_settings_patch): the pricing_v2
switch (every plan / pack / level / action credit number is then DERIVED by
the formula — never typed), the AI levels (Normal = Claude Haiku 5.5, Better =
Gemini Flash with the Haiku fallback — or, while Gemini is off (geminioff
breaker / active 402 / --gemini-off), Claude Haiku 5.5 with the larger
budget, Best = Claude Sonnet 5.5), welcome
credits 30 once for Normal + Better, rewarded ads 2 = 1 Normal answer (max 5
a day), web search ON. It changes NO price (owner item 12) and no Play
product. The LEAD runs it after deploy, with a DB backup first; a second
--apply finds nothing to change and writes nothing. Afterwards the owner does
owner_actions/PLAY_CONSOLE_CHANGES_BN.md.
"""
import json

from django.core.management.base import BaseCommand


def gemini_off(force=False):
    """geminioff: Gemini unusable right now? The 24 h breaker is open, or the
    last Gemini error is an active billing one (402 seen before this build),
    or the lead passed --gemini-off."""
    if force:
        return True
    try:
        from core import gemini_breaker as GB
        if GB.is_open():
            return True
        from core import ai_health as AH
        e = AH.last_error("gemini")
        return bool(e and e["active"] and e["kind"] == "billing")
    except Exception:  # noqa: BLE001
        return False


def preview(force_gemini_off=False):
    """(changes [(path, old, new)], problems, patch, new) — nothing saved."""
    from core import billing
    from core.logic import plan_book as BOOK, pricing as P
    old = P.normalize(billing.get_config().data)
    want = BOOK.v2_settings_patch(gemini_off=gemini_off(force_gemini_off))
    patch = {}
    for k, v in want.items():
        if isinstance(v, dict) and isinstance(old.get(k), dict):
            patch[k] = BOOK.deep_merge(old[k], v)
        else:
            patch[k] = v
    merged = json.loads(json.dumps(old))
    merged.update(patch)
    problems = P.validate_edit(merged)
    new = P.normalize(merged)
    return BOOK.flat_diff(old, new), problems, patch, new


class Command(BaseCommand):
    help = "Dry-run (default) or --apply the owner-approved pricing v2 (DB backup first)."

    def add_arguments(self, parser):
        parser.add_argument("--dry-run", action="store_true")
        parser.add_argument("--apply", action="store_true")
        # geminioff: Better = Claude Haiku even before the breaker has seen a 402
        parser.add_argument("--gemini-off", action="store_true")
        parser.add_argument("--reason", default="owner pricing decisions 9 Nov 10:20")

    def handle(self, *a, **o):
        from core.logic import plan_book as BOOK
        off = gemini_off(o.get("gemini_off"))
        if off:
            self.stdout.write("Gemini is OFF (402 / --gemini-off): Better = Claude Haiku 5.5 "
                              "(in 8000 / out 2500, 1 credit)")
        changes, problems, patch, new = preview(off)
        self.stdout.write("pricing_v2 — %d change(s):" % len(changes))
        for path, before, after in changes:
            self.stdout.write("  %s: %s -> %s" % (path, before, after))
        bad = [r for r in BOOK.worst_case_rows(new) if r["profit_pct"] < 40.0]
        for r in BOOK.worst_case_rows(new):
            self.stdout.write("  40%% check %-12s ৳%-6s %4d credits  profit %.1f%%"
                              % (r["id"], r["price"], r["credits"], r["profit_pct"]))
        if bad:
            problems = list(problems) + ["profit_below_40:%s" % ",".join(r["id"] for r in bad)]
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
                                    {"config": patch, "reason": ("pricing_v2: " + o["reason"])[:200]})
        if not ok:
            self.stdout.write("Refused: %s" % ", ".join(payload.get("problems") or []))
            raise SystemExit(1)
        self.stdout.write("APPLIED (%d changes, one audit row). Next: the owner's Play Console "
                          "list in owner_actions/PLAY_CONSOLE_CHANGES_BN.md." % len(changes))
