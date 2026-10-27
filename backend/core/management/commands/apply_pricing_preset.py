"""pricing-40: apply a NAMED pricing preset to the live PricingConfig — ONLY
after the owner's written approval (owner decision 27 Oct: "Do not change
any live price before my approval").

  manage.py apply_pricing_preset pricing_27oct            # = --dry-run
  manage.py apply_pricing_preset pricing_27oct --dry-run  # what would change
  manage.py apply_pricing_preset pricing_27oct --apply --backup-done \\
        --reason "owner approved 2026-10-xx"

--apply needs --backup-done (take the DB backup first). It goes through the
SAME validate + audit path as Owner Admin -> Pricing (views_build61.
pricing_apply), so a preset that breaks a guarantee is refused and every
applied change is in the pricing audit log. Presets live in
core/logic/pricing_40.PRESETS. After applying: do the Play Console steps in
owner_actions/PRICING_40PCT_BN.md §10 the same day.
"""
import json

from django.core.management.base import BaseCommand, CommandError


def _flat(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(_flat(v, "%s%s." % (prefix, k)))
    elif isinstance(d, list):
        out[prefix[:-1]] = json.dumps(d, ensure_ascii=False, sort_keys=True)
    else:
        out[prefix[:-1]] = d
    return out


def preview(name):
    """(changes [(path, old, new)], problems) — pure read, nothing saved."""
    from core import billing
    from core.logic import pricing as P, pricing_40 as P40
    if name not in P40.PRESETS:
        raise CommandError("Unknown preset %r (have: %s)" % (name, ", ".join(P40.PRESETS)))
    patch = P40.PRESETS[name]
    old = P.normalize(billing.get_config().data)
    merged = json.loads(json.dumps(old))
    for k, v in patch.items():
        if k == "topup_packs":
            merged[k] = v
        elif isinstance(v, dict) and isinstance(merged.get(k), dict):
            for kk, vv in v.items():
                if isinstance(vv, dict) and isinstance(merged[k].get(kk), dict):
                    merged[k][kk] = {**merged[k][kk], **vv}
                else:
                    merged[k][kk] = vv
        else:
            merged[k] = v
    problems = P.validate_edit(merged)
    new = P.normalize(merged)
    fo, fn = _flat(old), _flat(new)
    changes = [(p, fo.get(p), fn.get(p)) for p in sorted(set(fo) | set(fn))
               if fo.get(p) != fn.get(p)]
    return changes, problems, new


class Command(BaseCommand):
    help = "Preview (default) or --apply a pricing preset (owner approval + DB backup first)."

    def add_arguments(self, parser):
        parser.add_argument("name")
        parser.add_argument("--dry-run", action="store_true")
        parser.add_argument("--apply", action="store_true")
        parser.add_argument("--backup-done", action="store_true",
                            help="I took a DB backup just now.")
        parser.add_argument("--reason", default="")

    def handle(self, *a, **o):
        from core.logic import pricing_40 as P40
        name = o["name"]
        changes, problems, new = preview(name)
        self.stdout.write("Preset %s — %d change(s):" % (name, len(changes)))
        for path, before, after in changes:
            self.stdout.write("  %s: %s -> %s" % (path, before, after))
        safe = P40.safe_bdt_per_credit(new)
        self.stdout.write("Safe AI cost per credit after this preset: ৳%.4f" % safe)
        if problems:
            self.stdout.write("REFUSED by the pricing guarantees: %s" % ", ".join(problems))
        if not o["apply"] or o["dry_run"]:
            self.stdout.write("Dry run — nothing saved.")
            return
        if problems:
            raise CommandError("Not applied: %s" % ", ".join(problems))
        if not o["backup_done"]:
            raise CommandError("Take a DB backup first, then re-run with --backup-done.")
        from django.contrib.auth import get_user_model
        from core.views_build61 import pricing_apply
        owner = get_user_model().objects.filter(is_superuser=True).order_by("id").first()
        reason = ("preset %s: %s" % (name, o["reason"] or "owner approved"))[:200]
        ok, payload = pricing_apply(owner.id if owner else None,
                                    {"config": P40.PRESETS[name], "reason": reason})
        if not ok:
            raise CommandError("Refused: %s" % ", ".join(payload.get("problems") or []))
        self.stdout.write("APPLIED. Now do the Play Console steps (PRICING_40PCT_BN.md §10) today.")
