"""pay1 — hourly payments sweep (cron; see .phaseB/proposals/pay1.md):
expiry downgrades / queued periods (entitlement recompute), renew reminders
for prepaid gateway periods (push + SMS when configured), and re-verification
of gateway orders whose browser return / IPN never arrived."""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Payments sweep: expiry, renew reminders, lost-callback re-verify."

    def handle(self, *args, **opts):
        from core.payments import service
        out = service.sweep()
        self.stdout.write("payments_sweep %s" % out)
