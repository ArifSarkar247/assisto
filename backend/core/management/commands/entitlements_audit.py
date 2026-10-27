"""Owner order 27 Oct (add-on) — list every user whose current plan or
credit buckets are NOT backed by a verified payment (Play / EPS) or a
recorded grant, with the reason, amounts and a suggested fix. The same list
is the Owner Admin page "Unverified plans and credits".

    python manage.py entitlements_audit                 # report only
    python manage.py entitlements_audit --fix --dry-run # what --fix would do
    python manage.py entitlements_audit --fix           # record KNOWN grants

--fix only records a missing grant when the source is known (the Play
reviewer, matched by PLAY_REVIEWER_PHONE); everything else is a PROPOSAL for
the owner (nothing is removed automatically). Do not run --fix on live
before the backup.
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Find plans / credits without a verified payment or recorded grant."

    def add_arguments(self, p):
        p.add_argument("--fix", action="store_true")
        p.add_argument("--dry-run", action="store_true")

    def handle(self, *a, **o):
        from core.payments import reconcile as RC
        out = RC.entitlements_audit(fix=o["fix"], dry_run=o["dry_run"] or not o["fix"])
        for r in out["rows"]:
            for it in r["items"]:
                self.stdout.write("user #%s %s: %s" % (r["user"], it.get("what"), it))
        for g in out.get("confirmed", []):
            self.stdout.write("user #%s OK: %s" % (g["user"], g["label"]))
        self.stdout.write("entitlements_audit: %d user(s) need attention%s" % (
            out["users"], " (dry run)" if out["dry_run"] and o["fix"] else ""))
