"""pricing-40: ask the Play Developer API (read-only) whether each NEW sku's
Play product / base plan exists and is ACTIVE; a gated sku is sold only while
verified. Also runs daily inside billing_daily and from Owner Admin ->
Payments -> "Re-check"."""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Verify NEW Play products/base plans are ACTIVE (gates their sale)."

    def handle(self, *a, **o):
        from core.payments import play_verify
        out = play_verify.check_all()
        for r in out["rows"]:
            self.stdout.write("%-24s %-22s %-8s %-5s %s %s" % (
                r["sku"], r["product_id"], r["base_plan"] or "-", "OK" if r["ok"] else "no",
                r["state"], r["detail"]))
        self.stdout.write("verified %d / %d" % (out["verified"], out["checked"]))
