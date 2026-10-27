"""p1-bizagent — every 30 minutes: poll Pathao / Steadfast / RedX for every
shipped parcel; tell the customer on a change; delivered → a real Sale."""
from django.core.management.base import BaseCommand
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Business AI Agent: courier status polling."

    @track_job("bizagent_couriers")
    def handle(self, *args, **opts):
        from core import bizagent_service as S
        self.stdout.write("bizagent_couriers %d" % S.poll_couriers())
