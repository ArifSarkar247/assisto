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
        self.stdout.write("bizagent_process %d" % n)
