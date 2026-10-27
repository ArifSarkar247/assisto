"""billing-v2 rule V — split pre-v2 balances into real buckets (audit option
1) and write ONE adjust row per user for the difference.

NEVER run on the live DB before a backup. Always look at --dry-run first:

    python manage.py credits_rebuild_buckets --dry-run
    python manage.py credits_rebuild_buckets            # after review
    python manage.py credits_rebuild_buckets --user 3 --dry-run

Expected on live (27 Oct): user #3 130 -> 40 (plan 0, free 20, pack 20).
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Rebuild credit buckets from the ledger (billing v2). Use --dry-run first."

    def add_arguments(self, p):
        p.add_argument("--dry-run", action="store_true")
        p.add_argument("--user", type=int, action="append")

    def handle(self, *a, **o):
        from django.db.models import Q
        from core.models import CreditLedger, User
        from core import rebuild_buckets as RB
        qs = User.objects.all().order_by("pk")
        if o.get("user"):
            qs = qs.filter(pk__in=o["user"])
        else:
            ids = set(CreditLedger.objects.values_list("user_id", flat=True))
            qs = qs.filter(Q(pk__in=ids) | ~Q(ai_credits=0))
        changed = 0
        for u in qs:
            plan = RB.plan_for(u)
            b = plan["buckets"]
            line = ("user #%d: before %d (ledger %d) -> after %d  [plan %d, free %d, rewarded %d, "
                    "referral %d, pack %d, other v2 lots %d]  adjust %+d%s%s" % (
                        u.pk, plan["balance"], plan["ledger_sum"], plan["target"], b["plan"],
                        b["free"], b["rewarded"], b["referral"], b["pack"], plan["other_lots"],
                        plan["adjust"],
                        "  expired plan %d" % plan["expired_plan"] if plan["expired_plan"] else "",
                        "  (already rebuilt)" if plan["done"] else ""))
            self.stdout.write(line)
            if plan["done"] or o["dry_run"]:
                continue
            if RB.apply(u, plan):
                changed += 1
        self.stdout.write("%s: %d user(s) %s" % ("DRY RUN" if o["dry_run"] else "DONE", changed,
                                                "would change" if o["dry_run"] else "rebuilt"))
