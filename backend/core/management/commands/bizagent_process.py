"""p1-bizagent — every minute (cron, deploy/p1/bizagent.cron): process any
Meta/WhatsApp webhook event still pending (the web worker thread normally
handles them within a second; this sweep covers restarts/crashes)."""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Business AI Agent: process pending webhook events."

    def add_arguments(self, parser):
        parser.add_argument("--limit", type=int, default=200)

    def handle(self, *args, **opts):
        from core import bizagent_service as S
        n = S.process_pending(limit=opts["limit"])
        from core import bizagent_g1_service as G1S
        g = G1S.run_sweeps()          # g1: resume after human pause, follow-ups, morning summary
        self.stdout.write("bizagent_process %d %s" % (n, " ".join(
            "%s=%s" % kv for kv in sorted(g.items()))))
